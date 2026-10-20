import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import simd

struct LiveState: Equatable {
    var buttons: Set<ControllerButton> = []
    var touch = Touch.none
    var packetRate = 0.0
    var gyroCalibrated = false
    var temperature: Int?
}

/// Owns the Bluetooth link, the mapper and the event output, and exposes state to SwiftUI.
/// Everything runs on the main thread (CoreBluetooth is created with the main queue).
final class AppModel: ObservableObject {
    @Published private(set) var linkState = ControllerLink.State.searching
    @Published private(set) var deviceName: String?
    @Published private(set) var battery: Int?
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var clutched = false
    @Published private(set) var live = LiveState()
    @Published private(set) var calibration = GyroBias.Calibration.idle
    /// Follows the gyro bias even while the menu (and so `live`) isn't on screen.
    @Published private(set) var gyroCalibrated = false
    /// The menu-bar icon is invisible (behind the notch on a full menu bar).
    @Published private(set) var menuBarIconHidden = false
    @Published var enabled = true {
        didSet {
            if !enabled { mapper.reset() }
            updateMagnet()
            updatePower()
        }
    }
    @Published var pointerOn: Bool {
        didSet {
            mapper.pointerOn = pointerOn
            updateMagnet()
            updatePower()
        }
    }
    @Published var config: RemoteConfig {
        didSet {
            mapper.config = config
            sink.magnet.settings = config.magnet
            updateMagnet()
            save()
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Why launch at login isn't on although it was asked for (needs approval, or an error).
    @Published private(set) var launchAtLoginNote: String?
    @Published var settingsTab = SettingsTab.welcome

    /// Opens the Settings window; installed by a view that has the SwiftUI openSettings action.
    var openSettingsAction: (() -> Void)? {
        didSet { if pendingSettings, openSettingsAction != nil { pendingSettings = false; presentSettings(settingsTab) } }
    }
    private var pendingSettings = false
    private static let welcomedKey = "didShowWelcome"

    /// Set by the menu while it's open; live state is only published then.
    var liveVisible = false {
        didSet { if liveVisible { publishLive() } }
    }

    let dryRun = CommandLine.arguments.contains("--dry-run")
    let verbose = CommandLine.arguments.contains("--verbose")
    private let link = ControllerLink()
    private let sink = EventSink()
    private let scanner = TargetScanner()
    let training = TrainingWindow()
    let calibrationWindow = CalibrationWindow()
    private var magnetTimer: Timer?
    private let mapper: InputMapper
    private var latest: Packet?
    private var packets = 0
    private var packetRate = 0.0
    private var timers: [Timer] = []
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var movingPackets = 0 // consecutive packets with real hand motion
    private var macAsleep = false // the Mac or its display is asleep
    private var screenLocked = false // locked, or switched to another user
    private var macAway: Bool { macAsleep || screenLocked }
    /// Nothing has happened on the controller for a while, so the magnet's scanner rests.
    private var controllerIdle = false
    private static let magnetIdleAfter: TimeInterval = 30
    private static let configKey = "config.v1"

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(RemoteConfig.self, from: $0) }
        let cfg = saved?.migrated() ?? RemoteConfig()
        config = cfg
        pointerOn = cfg.pointerEnabledAtLaunch
        mapper = InputMapper(config: cfg, sink: sink)
    }

    func start() {
        sink.postEvents = !dryRun
        link.turnOffOnDisconnect = !dryRun
        if verbose || dryRun {
            link.log = { [weak self] in self?.log("link: \($0)") }
            sink.log = { [weak self] in self?.log("out: \($0)") }
        }
        mapper.onPointerToggle = { [weak self] on in
            self?.pointerOn = on
            self?.log("air-mouse \(on ? "on" : "off")")
        }
        mapper.bias.onCalibration = { [weak self] state in
            self?.calibration = state
            if case .finished(let ok, let drift, _) = state {
                self?.log(ok ? String(format: "recalibrated, drift was %.2f dps", drift) : "recalibration rejected: it moved")
            }
        }
        calibrationWindow.onClose = { [weak self] in
            self?.mapper.bias.cancelManualCalibration()
            self?.calibration = .idle
        }
        mapper.onClutch = { [weak self] on in
            self?.clutched = on
            self?.log(on ? "clutch engaged" : "clutch released")
        }
        link.onState = { [weak self] state in
            guard let self else { return }
            let wasActive = [.handshaking, .streaming, .lowPower].contains(self.linkState)
            self.linkState = state
            self.deviceName = self.link.deviceName
            self.log("state: \(state)")
            // a (re)connection, e.g. woken with Home, restarts the idle countdown, or the stale
            // clock would put it straight back to sleep; a pending connect can take any time
            if state == .connecting || (!wasActive && [.handshaking, .streaming].contains(state)) {
                self.lastActivity = ProcessInfo.processInfo.systemUptime
            }
            self.updateMagnet()
        }
        link.onDisconnect = { [weak self] in
            self?.mapper.reset()
            self?.mapper.bias.reset() // the zero-rate bias belongs to the connection, not the stream mode
        }
        link.onPacket = { [weak self] in self?.handle($0) }
        link.wantsHighRate = pointerOn && enabled // before the first handshake, not at the first tick
        link.start()

        save() // persist any migration of older settings
        sink.magnet.settings = config.magnet
        scanner.onTargets = { [weak self] targets in self?.sink.magnet.targets = targets }
        updateMagnet()

        log("accessibility trusted: \(accessibilityTrusted)")
        if !accessibilityTrusted && !dryRun {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !UserDefaults.standard.bool(forKey: Self.welcomedKey) && Snapshot.directory == nil {
            UserDefaults.standard.set(true, forKey: Self.welcomedKey)
            presentSettings(.welcome)
        }
        // battery care: the controller can't sleep by itself while we hold it awake with
        // keep-alives, so sleep it when the Mac does and when nothing has happened for a while
        let workspace = NSWorkspace.shared.notificationCenter
        let observe = { (center: NotificationCenter, names: [Notification.Name], update: @escaping (AppModel) -> Void) in
            for name in names {
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    update(self)
                    self.macAwayChanged()
                }
            }
        }
        observe(workspace, [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification]) { $0.macAsleep = true }
        observe(workspace, [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]) { $0.macAsleep = false }
        // the display waking up to the lock screen doesn't count; only unlocking does
        observe(DistributedNotificationCenter.default(), [Notification.Name("com.apple.screenIsLocked")]) { $0.screenLocked = true }
        observe(DistributedNotificationCenter.default(), [Notification.Name("com.apple.screenIsUnlocked")]) { $0.screenLocked = false }
        observe(workspace, [NSWorkspace.sessionDidResignActiveNotification]) { $0.screenLocked = true }
        observe(workspace, [NSWorkspace.sessionDidBecomeActiveNotification]) { $0.screenLocked = false }

        // the status item needs a moment to be placed before we can tell where it landed, and
        // other apps' items or a display change can push it behind the notch later
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkMenuBarIcon() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.checkMenuBarIcon() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkMenuBarIcon() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            if self?.liveVisible == true { self?.publishLive() }
        })
    }

    func shutdown() {
        mapper.reset()
        link.stop()
    }

    /// Magnetic targets run only while the controller is actually driving the pointer.
    private func updateMagnet() {
        let steering = pointerOn || config.touchModePointerOff == .cursor
        let active = config.magnetEnabled && enabled && linkState == .streaming && steering && !controllerIdle
        guard active != sink.magnetEnabled || active != (magnetTimer != nil) else { return }
        sink.magnetEnabled = active
        if active {
            scanner.start()
            if magnetTimer == nil {
                let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sink.magnetTick() }
                RunLoop.main.add(t, forMode: .common) // keep running while menus are open
                magnetTimer = t
            }
        } else {
            scanner.stop()
            magnetTimer?.invalidate()
            magnetTimer = nil
        }
        log("magnet \(active ? "on" : "off")")
    }

    private func handle(_ p: Packet) {
        latest = p
        packets += 1
        if battery != p.battery { battery = p.battery }
        if enabled { mapper.handle(p) }
        // any button, touch or real movement counts as being in use. A controller lying still
        // throws single-sample gyro spikes of up to ~10°/s, so movement has to last a few packets
        // (~45 ms), or it would never fall asleep on the table.
        let rates = p.samples.map { simd_length($0.gyro - mapper.bias.bias) }.sorted()
        movingPackets = rates[rates.count / 2] > 6 ? movingPackets + 1 : 0
        if !p.buttons.isEmpty || p.touch.touching || movingPackets >= 3 { noteActivity() }
        if training.isRecording && mapper.bias.calibrated {
            // raw hand motion for the training's tremor measurement
            let b = mapper.bias.bias
            let mean = p.samples.map { simd_length($0.gyro - b) }.reduce(0, +) / Double(p.samples.count)
            training.session.recordTremor(mean)
        }
    }

    /// The menu's Wake button: works even before the controller has powered down.
    func wakeController() {
        lastActivity = ProcessInfo.processInfo.systemUptime
        link.wake()
    }

    /// Wake the controller and restart the idle countdown.
    func noteActivity() {
        lastActivity = ProcessInfo.processInfo.systemUptime
        if controllerIdle { controllerIdle = false; updateMagnet() }
        if link.isAsleep { return } // it wakes on its own advertisement, nothing to do here
        updatePower()
    }

    private func macAwayChanged() {
        log("mac \(macAsleep ? "asleep" : "awake"), \(screenLocked ? "locked" : "unlocked")")
        link.wakeOnHome = !macAway
        if macAway { updatePower() } else { link.wake(); noteActivity() } // back at the Mac: pick it up again
    }

    /// Decides how hard the controller should be working right now.
    private func updatePower() {
        link.wantsHighRate = pointerOn && enabled
        guard !link.isAsleep else { return }
        let idleFor = ProcessInfo.processInfo.systemUptime - lastActivity
        let limit = config.sleepAfterMinutes * 60
        // idle only counts once it's connected: a wake with Home takes a moment to stream
        let connected = linkState == .streaming || linkState == .lowPower
        if macAway || (connected && limit > 0 && idleFor > limit) {
            link.sleepNow()
        } else {
            link.setLowPower(!enabled)
        }
    }

    private func tick() {
        updatePower()
        let idle = ProcessInfo.processInfo.systemUptime - lastActivity > Self.magnetIdleAfter
        if idle != controllerIdle { controllerIdle = idle; updateMagnet() }
        packetRate = Double(packets)
        packets = 0
        if mapper.bias.calibrated != gyroCalibrated { gyroCalibrated = mapper.bias.calibrated }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            log("accessibility trusted: \(trusted)")
        }
        if verbose, linkState == .streaming, let p = latest {
            log(String(format: "%.0f pkt/s  battery %d%%  gyro %@  buttons %@  magnet %@", packetRate, p.battery,
                       mapper.bias.calibrated ? "calibrated" : "calibrating",
                       p.buttons.map(\.rawValue).sorted().joined(separator: ","),
                       sink.magnetEnabled ? "\(sink.magnet.targets.count) targets\(sink.magnet.locked != nil ? ", SNAPPED" : "")" : "off"))
        }
    }

    private func publishLive() {
        let next = LiveState(buttons: latest?.buttons ?? [], touch: latest?.touch ?? .none,
                             packetRate: packetRate, gyroCalibrated: mapper.bias.calibrated,
                             temperature: latest?.temperatureC)
        if next != live { live = next }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    func resetConfig() { config = RemoteConfig() }

    /// Warn once if the icon landed somewhere invisible, otherwise the app looks like it
    /// never launched. The flag itself follows the icon, so the warning clears once it's fixed.
    func checkMenuBarIcon() {
        let hidden = MenuBarVisibility.iconIsHidden()
        if hidden != menuBarIconHidden {
            menuBarIconHidden = hidden
            log("menu bar icon hidden: \(hidden)")
        }
        guard hidden, !UserDefaults.standard.bool(forKey: "warnedMenuBarHidden") else { return }
        UserDefaults.standard.set(true, forKey: "warnedMenuBarHidden")
        presentSettings(.welcome)
    }

    func showTraining() { training.show(model: self) }

    func showCalibration() {
        calibration = .idle
        calibrationWindow.show(model: self)
    }

    func startCalibration() { mapper.bias.startManualCalibration() }

    func cancelCalibration() {
        mapper.bias.cancelManualCalibration()
        calibration = .idle
    }

    func presentSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        refreshLaunchAtLogin()
        if settingsTab == .welcome { checkMenuBarIcon() }
        guard let open = openSettingsAction else { pendingSettings = true; return }
        NSApp.activate(ignoringOtherApps: true)
        open()
        log("settings opened (\(settingsTab))")
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginNote = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("launch at login: \(error.localizedDescription)")
            launchAtLoginNote = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    /// Follows changes made in System Settings → Login Items.
    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        if launchAtLogin != (status == .enabled) { launchAtLogin = status == .enabled }
        if status == .requiresApproval {
            launchAtLoginNote = "Allow GearVR Remote under System Settings → General → Login Items."
        } else if status == .enabled {
            launchAtLoginNote = nil
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func log(_ message: String) {
        guard verbose || dryRun else { return }
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    }

    // MARK: presentation

    var isStreaming: Bool { linkState == .streaming }
    /// Connected, including while paused with the sensors off or restarting the stream.
    var isConnected: Bool { [.handshaking, .streaming, .lowPower].contains(linkState) }

    var statusText: String {
        switch linkState {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Allow Bluetooth access in System Settings"
        case .searching: return "Searching — press Home to wake the controller"
        case .connecting: return "Connecting…"
        case .handshaking: return "Starting sensors…"
        case .lowPower: return "Connected · paused, sensors off"
        case .asleep: return "Asleep to save batteries — press Home or Wake"
        case .streaming:
            if case .collecting = calibration { return "Recalibrating — keep it still" }
            if !enabled { return "Connected · paused" }
            if clutched { return "Clutch held — release the trigger to resume" }
            return mapper.bias.calibrated || live.gyroCalibrated ? "Connected" : "Connected · hold still to calibrate"
        }
    }

    var glyphStyle: ControllerGlyph.Style {
        guard isConnected else { return .disconnected }
        return enabled && linkState != .lowPower ? .active : .paused
    }
}
