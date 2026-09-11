import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

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
    @Published var enabled = true {
        didSet { if !enabled { mapper.reset() } }
    }
    @Published var pointerOn: Bool {
        didSet { mapper.pointerOn = pointerOn }
    }
    @Published var config: RemoteConfig {
        didSet {
            mapper.config = config
            save()
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
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
    private let mapper: InputMapper
    private var latest: Packet?
    private var packets = 0
    private var packetRate = 0.0
    private var timers: [Timer] = []
    private static let configKey = "config.v1"

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(RemoteConfig.self, from: $0) }
        let cfg = saved ?? RemoteConfig()
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
        mapper.onClutch = { [weak self] on in
            self?.clutched = on
            self?.log(on ? "clutch engaged" : "clutch released")
        }
        link.onState = { [weak self] state in
            guard let self else { return }
            self.linkState = state
            self.deviceName = self.link.deviceName
            self.log("state: \(state)")
            if state != .streaming { self.mapper.bias.reset() }
        }
        link.onDisconnect = { [weak self] in self?.mapper.reset() }
        link.onPacket = { [weak self] in self?.handle($0) }
        link.start()

        log("accessibility trusted: \(accessibilityTrusted)")
        if !accessibilityTrusted && !dryRun {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !UserDefaults.standard.bool(forKey: Self.welcomedKey) && Snapshot.directory == nil {
            UserDefaults.standard.set(true, forKey: Self.welcomedKey)
            presentSettings(.welcome)
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            if self?.liveVisible == true { self?.publishLive() }
        })
    }

    func shutdown() {
        mapper.reset()
        link.stop()
    }

    private func handle(_ p: Packet) {
        latest = p
        packets += 1
        if battery != p.battery { battery = p.battery }
        if enabled { mapper.handle(p) }
    }

    private func tick() {
        packetRate = Double(packets)
        packets = 0
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            log("accessibility trusted: \(trusted)")
        }
        if verbose, linkState == .streaming, let p = latest {
            log(String(format: "%.0f pkt/s  battery %d%%  gyro %@  buttons %@", packetRate, p.battery,
                       mapper.bias.calibrated ? "calibrated" : "calibrating",
                       p.buttons.map(\.rawValue).sorted().joined(separator: ",")))
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

    func presentSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        guard let open = openSettingsAction else { pendingSettings = true; return }
        NSApp.activate(ignoringOtherApps: true)
        open()
        log("settings opened (\(settingsTab))")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

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

    var statusText: String {
        switch linkState {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Allow Bluetooth access in System Settings"
        case .searching: return "Searching — press Home to wake the controller"
        case .connecting: return "Connecting…"
        case .handshaking: return "Starting sensors…"
        case .streaming:
            if !enabled { return "Connected · paused" }
            if clutched { return "Clutch held — release the trigger to resume" }
            return mapper.bias.calibrated || live.gyroCalibrated ? "Connected" : "Connected · hold still to calibrate"
        }
    }

    var glyphStyle: ControllerGlyph.Style {
        guard isStreaming else { return .disconnected }
        return enabled ? .active : .paused
    }
}
