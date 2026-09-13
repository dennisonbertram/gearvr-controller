// CoreBluetooth connection to the Gear VR Controller: find, connect, run the
// VR-mode handshake, keep the stream alive, and reconnect when it wakes up.
import CoreBluetooth
import Foundation

final class ControllerLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum State: Equatable {
        case bluetoothOff, unauthorized, searching, connecting, handshaking, streaming, lowPower, asleep
    }

    var onState: ((State) -> Void)?
    var onPacket: ((Packet) -> Void)?
    var onDisconnect: (() -> Void)?
    var log: ((String) -> Void)?
    /// Send `0000` (sensors off) when disconnecting, to save the controller's battery.
    var turnOffOnDisconnect = true
    /// High rate (~68 pkt/s) for pointing; the plain sensor stream (~30 pkt/s) is enough
    /// for buttons and scrolling and asks less of the controller's batteries.
    var wantsHighRate = true {
        didSet { if wantsHighRate != oldValue, state == .streaming { beginHandshake() } }
    }

    private(set) var state = State.searching { didSet { if state != oldValue { onState?(state) } } }
    private(set) var deviceName: String?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var cmdChar: CBCharacteristic?
    private var keepAlive: Timer?
    private var ackTimeout: Timer?
    private var watchdog: Timer?
    private var awaitingAck = false
    private var lastPacket = Date.distantPast

    private let serviceUUID = CBUUID(string: GearVR.serviceUUID)
    private let dataUUID = CBUUID(string: GearVR.dataUUID)
    private let cmdUUID = CBUUID(string: GearVR.commandUUID)
    private let savedIDKey = "controllerPeripheralID"

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: finding the controller

    private func findController() {
        guard central.state == .poweredOn else { return }
        state = .searching
        // 1. Already connected at the system level (bonded, or held by another app).
        if let p = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            log?("found system-connected controller")
            connect(p)
            return
        }
        // 2. Known from before: a pending connect completes as soon as it wakes up.
        if let id = UserDefaults.standard.string(forKey: savedIDKey).flatMap(UUID.init(uuidString:)),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            log?("waiting for known controller \(id)")
            connect(p)
        }
        // 3. Scan. The controller doesn't advertise its service UUID, so match by name.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        if peripheral !== p { peripheral = p }
        p.delegate = self
        if state == .searching { state = .connecting }
        central.connect(p, options: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log?("bluetooth state \(c.state.rawValue), authorization \(CBManager.authorization.rawValue)")
        switch c.state {
        case .poweredOn: findController()
        case .unauthorized: state = .unauthorized
        default:
            teardown()
            state = .bluetoothOff
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        guard name.hasPrefix(GearVR.namePrefix) else { return }
        log?("discovered \(name) rssi \(rssi)")
        central.stopScan()
        deviceName = name
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log?("connected")
        central.stopScan()
        deviceName = p.name ?? deviceName
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedIDKey)
        state = .connecting
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log?("failed to connect: \(error?.localizedDescription ?? "?")")
        retryLater()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log?("disconnected: \(error?.localizedDescription ?? "-")")
        let sleeping = state == .asleep
        teardown()
        onDisconnect?()
        if sleeping {
            state = .asleep
            central.connect(p, options: nil) // wake on the next advertisement
        } else {
            retryLater()
        }
    }

    private func retryLater() {
        state = .searching
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.findController() }
    }

    private func teardown() {
        keepAlive?.invalidate()
        ackTimeout?.invalidate()
        watchdog?.invalidate()
        keepAlive = nil
        ackTimeout = nil
        watchdog = nil
        dataChar = nil
        cmdChar = nil
        awaitingAck = false
    }

    // MARK: GATT setup + handshake

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            log?("controller service missing")
            return
        }
        p.discoverCharacteristics([dataUUID, cmdUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        dataChar = s.characteristics?.first { $0.uuid == dataUUID }
        cmdChar = s.characteristics?.first { $0.uuid == cmdUUID }
        guard let data = dataChar, cmdChar != nil else {
            log?("controller characteristics missing")
            return
        }
        p.setNotifyValue(true, for: data)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == dataUUID, c.isNotifying else { return }
        beginHandshake()
    }

    /// 0800 (VR mode, ~1.5 s to ack) -> wait for the 2-byte echo -> 0100 (start streaming).
    /// Without the VR-mode step the controller streams at the slower sensor rate.
    private func beginHandshake() {
        guard wantsHighRate else {
            // VR mode sticks until the sensors are switched off, so drop it first
            send(.off)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.startStream() }
            return
        }
        state = .handshaking
        awaitingAck = true
        send(.vrMode)
        ackTimeout?.invalidate()
        ackTimeout = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.log?("no VR-mode ack; starting anyway")
            self?.startStream()
        }
    }

    private func startStream() {
        awaitingAck = false
        ackTimeout?.invalidate()
        send(.sensor)
        state = .streaming
        lastPacket = Date()
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.send(.keepAlive)
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.state == .streaming, Date().timeIntervalSince(self.lastPacket) > 3 else { return }
            self.log?("stream stalled; redoing handshake")
            self.keepAlive?.invalidate()
            self.beginHandshake()
        }
    }

    private func send(_ cmd: GearVR.Command) {
        guard let p = peripheral, let c = cmdChar else { return }
        p.writeValue(cmd.bytes, for: c, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == dataUUID, let value = c.value else { return }
        if value.count == 2 {
            log?("ack \(value.map { String(format: "%02x", $0) }.joined())")
            if awaitingAck { startStream() }
        } else if let packet = Packet.parse(value) {
            lastPacket = Date()
            onPacket?(packet)
        }
    }

    // MARK: power

    /// Sensors off but still connected: resuming is instant (no handshake).
    func setLowPower(_ on: Bool) {
        guard peripheral != nil, cmdChar != nil else { return }
        if on {
            guard state == .streaming else { return }
            keepAlive?.invalidate()
            watchdog?.invalidate()
            send(.off)
            state = .lowPower
            log?("low power mode")
        } else {
            guard state == .lowPower else { return }
            beginHandshake()
        }
    }

    /// Sensors off and disconnected, so the controller can fall asleep on its own.
    /// A pending connect brings it back the moment it advertises again (press Home).
    func sleepNow() {
        guard let p = peripheral, state != .asleep else { return }
        log?("putting the controller to sleep")
        if cmdChar != nil { send(.off) }
        teardown()
        central.cancelPeripheralConnection(p)
        state = .asleep
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.state == .asleep, let p = self.peripheral else { return }
            self.central.connect(p, options: nil) // completes when it wakes up
        }
    }

    var isAsleep: Bool { state == .asleep }

    // MARK: shutdown

    func stop() {
        guard let p = peripheral else { return }
        if turnOffOnDisconnect, state == .streaming { send(.off) }
        teardown()
        // give the write a moment to leave before cancelling
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        central.cancelPeripheralConnection(p)
    }
}
