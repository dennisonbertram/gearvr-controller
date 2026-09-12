// Turns controller packets into pointer / button / key actions.
// Platform-free: output goes through InputSink so it can be tested headlessly.
import Foundation
import simd

public protocol InputSink: AnyObject {
    func move(dx: Double, dy: Double)
    func mouseButton(_ button: MouseButton, down: Bool)
    func scroll(dy: Int)
    func key(_ combo: String, down: Bool)
    func media(_ name: String, down: Bool)
    func shell(_ command: String)
    func sound(_ name: String)
    func releaseAll()
}

/// Adaptive low-pass for pointer rates (a "1€ filter" variant): the cutoff rises with speed,
/// so slow movement and holding still are smoothed while fast moves stay responsive.
public struct AdaptiveSmoother {
    public var minCutoff: Double // Hz at rest
    public var speedGain: Double // extra Hz per deg/s of motion
    private var value: Double?

    public init(minCutoff: Double, speedGain: Double) {
        self.minCutoff = minCutoff
        self.speedGain = speedGain
    }

    /// `amount` 0 (off) ... 1 (strong).
    public init(amount: Double) {
        let a = min(max(amount, 0), 1)
        self.init(minCutoff: 12 * pow(0.1, a), speedGain: 0.12)
    }

    public mutating func filter(_ x: Double, dt: Double) -> Double {
        guard let prev = value, dt > 0 else { value = x; return x }
        let cutoff = minCutoff + speedGain * abs(x)
        let tau = 1 / (2 * Double.pi * cutoff)
        let alpha = 1 / (1 + tau / dt)
        let y = prev + alpha * (x - prev)
        value = y
        return y
    }

    public mutating func reset() { value = nil }
}

/// Tracks the gyro zero-offset, re-estimating it whenever the controller is still.
/// A manual recalibration can also be requested: it collects a fixed run of samples and
/// only accepts them if the controller really was still.
public final class GyroBias {
    public enum Calibration: Equatable {
        case idle
        case collecting(progress: Double)
        case finished(ok: Bool, driftDPS: Double, wobbleDPS: Double)
    }

    public private(set) var bias = SIMD3<Double>.zero
    public var calibrated = false
    /// Progress and result of a manual recalibration (also reported through `onCalibration`).
    public private(set) var manual = Calibration.idle
    public var onCalibration: ((Calibration) -> Void)?
    public var isCollecting: Bool { if case .collecting = manual { return true }; return false }

    private var window: [SIMD3<Double>] = []
    private let size: Int
    private var manualSamples: [SIMD3<Double>] = []
    private var manualTarget = 0
    /// Hand-held stillness: a bit looser than the automatic detector, which needs certainty.
    static let manualWobbleLimit = 1.5

    public init(window size: Int = 100) { self.size = size }

    /// Collects `sampleCount` samples (~2 s at 206 Hz) and adopts their mean if steady enough.
    public func startManualCalibration(sampleCount: Int = 412) {
        manualSamples.removeAll(keepingCapacity: true)
        manualTarget = sampleCount
        setManual(.collecting(progress: 0))
    }

    public func cancelManualCalibration() {
        manualSamples.removeAll(keepingCapacity: true)
        manualTarget = 0
        setManual(.idle)
    }

    private func setManual(_ state: Calibration) {
        manual = state
        onCalibration?(state)
    }

    private func collectManual(_ g: SIMD3<Double>) {
        manualSamples.append(g)
        if manualSamples.count < manualTarget {
            if manualSamples.count % 20 == 0 {
                setManual(.collecting(progress: Double(manualSamples.count) / Double(manualTarget)))
            }
            return
        }
        let mean = manualSamples.reduce(.zero, +) / Double(manualSamples.count)
        let variance = manualSamples.reduce(SIMD3<Double>.zero) { $0 + ($1 - mean) * ($1 - mean) } / Double(manualSamples.count)
        let wobble = variance.squareRoot().max()
        let ok = wobble < Self.manualWobbleLimit
        if ok {
            bias = mean
            calibrated = true
            window.removeAll(keepingCapacity: true)
        }
        manualSamples.removeAll(keepingCapacity: true)
        manualTarget = 0
        setManual(.finished(ok: ok, driftDPS: simd_length(mean), wobbleDPS: wobble))
    }

    public func update(_ g: SIMD3<Double>) {
        if isCollecting {
            collectManual(g)
            return
        }
        window.append(g)
        guard window.count >= size else { return }
        let mean = window.reduce(.zero, +) / Double(window.count)
        let variance = window.reduce(SIMD3<Double>.zero) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)
        window.removeAll(keepingCapacity: true)
        let sd = variance.squareRoot()
        guard sd.max() < 0.8 else { return }
        if !calibrated {
            bias = mean
            calibrated = true
        } else if abs(mean - bias).max() < 3 {
            // small drift correction; the guard avoids absorbing a slow deliberate turn
            bias += 0.2 * (mean - bias)
        }
    }

    public func reset() {
        window.removeAll()
        calibrated = false
        cancelManualCalibration()
    }
}

public final class InputMapper {
    public var config: RemoteConfig
    public var pointerOn: Bool
    /// Called when a button toggles the air-mouse, so the UI can follow.
    public var onPointerToggle: ((Bool) -> Void)?
    /// Called when the clutch engages / releases.
    public var onClutch: ((Bool) -> Void)?
    public let bias = GyroBias()
    public private(set) var clutched = false

    private let sink: InputSink
    private let now: () -> TimeInterval
    private var prevButtons: Set<ControllerButton> = []
    private var freezeUntil: TimeInterval = 0
    private var up = SIMD3<Double>(0, 0, 1)
    private var lastTimestamp: UInt32?
    private var touchPrev: (x: Int, y: Int)?
    private var touchStart: (t: TimeInterval, x: Int, y: Int)?
    private var scrollFrac = 0.0
    private var smoothYaw = AdaptiveSmoother(amount: 0)
    private var smoothPitch = AdaptiveSmoother(amount: 0)
    private var smoothingAmount = -1.0
    private var pending: SIMD2<Double>? // deferred clutch-button press: buffered pointer motion
    private var suppressed: Set<ControllerButton> = [] // pressed during the clutch: ignored until released

    static let swipeMaxS = 0.45
    static let swipeMinDist = 70
    static let tapMaxDist = 20

    public init(config: RemoteConfig, sink: InputSink, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.sink = sink
        self.now = now
        self.pointerOn = config.pointerEnabledAtLaunch
    }

    public func handle(_ p: Packet) {
        checkClutch(p.touch)
        handleButtons(p)
        handleMotion(p)
        handleTouch(p)
    }

    public func reset() {
        sink.releaseAll()
        pending = nil
        if clutched { clutched = false; onClutch?(false) }
        suppressed.removeAll()
        prevButtons = []
        lastTimestamp = nil
        touchPrev = nil
        touchStart = nil
        smoothYaw.reset()
        smoothPitch.reset()
    }

    // MARK: actions

    private func run(_ action: Action, down: Bool) {
        switch action {
        case .click(let b): sink.mouseButton(b, down: down)
        case .key(let combo): sink.key(combo, down: down)
        case .media(let name): sink.media(name, down: down)
        case .shell(let cmd): if down { sink.shell(cmd) }
        case .togglePointer:
            if down {
                pointerOn.toggle()
                onPointerToggle?(pointerOn)
            }
        case .none: break
        }
    }

    private func tap(_ action: Action) {
        run(action, down: true)
        run(action, down: false)
    }

    // MARK: clutch / deferred press

    func inClutchZone(_ t: Touch) -> Bool {
        let edge = Int(GearVR.touchMax * config.clutchZoneSize)
        let maxV = Int(GearVR.touchMax)
        switch config.clutchZone {
        case .bottom: return t.y >= maxV - edge
        case .top: return t.y <= edge
        case .left: return t.x <= edge
        case .right: return t.x >= maxV - edge
        case .any: return true
        }
    }

    /// Engage when a fresh touch lands in the zone while the clutch button is held.
    private func checkClutch(_ t: Touch) {
        guard pending != nil, t.touching, touchPrev == nil, inClutchZone(t) else { return }
        pending = nil // the click never happens
        clutched = true
        if config.clutchSound { sink.sound("Tink") }
        onClutch?(true)
    }

    private func clutchButton(down: Bool) {
        let action = config.action(for: config.clutchButton)
        if down {
            if config.clutchEnabled && pointerOn {
                pending = .zero // decide on release, movement, or clutch
            } else {
                run(action, down: true)
            }
        } else if clutched {
            clutched = false
            if config.clutchSound { sink.sound("Pop") }
            onClutch?(false)
        } else if pending != nil {
            pending = nil
            tap(action) // released without moving: a plain click
        } else {
            run(action, down: false) // end of a drag / immediate press
        }
    }

    private func pointerMove(_ dx: Double, _ dy: Double) {
        if clutched || (dx == 0 && dy == 0) { return }
        var d = SIMD2(dx, dy)
        if var buffered = pending {
            buffered += d
            if simd_length(buffered) < config.dragThresholdPX {
                pending = buffered // cursor stays put: steadier clicks
                return
            }
            pending = nil
            run(config.action(for: config.clutchButton), down: true) // start the drag here
            d = buffered
        }
        sink.move(dx: d.x, dy: d.y)
    }

    // MARK: buttons

    private func handleButtons(_ p: Packet) {
        guard p.buttons != prevButtons else { return }
        for name in ControllerButton.allCases {
            let was = prevButtons.contains(name), isDown = p.buttons.contains(name)
            if was == isDown { continue }
            if isDown { freezeUntil = now() + config.clickFreezeMS / 1000 }
            if name == config.clutchButton {
                clutchButton(down: isDown)
            } else if isDown && clutched {
                suppressed.insert(name)
            } else if !isDown && suppressed.contains(name) {
                suppressed.remove(name)
            } else {
                run(config.action(for: name), down: isDown)
            }
        }
        prevButtons = p.buttons
    }

    // MARK: gyro air-mouse

    private func handleMotion(_ p: Packet) {
        for s in p.samples {
            bias.update(s.gyro)
            // low-pass the accelerometer to track which way is up (body frame)
            let n = simd_length(s.accel)
            if n > 0.7 && n < 1.3 { up = 0.97 * up + 0.03 * (s.accel / n) }
            guard let last = lastTimestamp else { lastTimestamp = s.timestampUS; continue }
            let dt = Double(s.timestampUS &- last) / 1e6
            lastTimestamp = s.timestampUS
            guard dt > 0, dt < 0.1, pointerOn, bias.calibrated, !bias.isCollecting,
                  now() >= freezeUntil else { continue }

            let w = s.gyro - bias.bias
            let u = simd_normalize(up)
            // right = forward(+Y) x up; falls back to +X when pointing straight up
            var right = SIMD3(u.z, 0, -u.x)
            let rn = simd_length(right)
            right = rn > 0.2 ? right / rn : SIMD3(1, 0, 0)
            var yaw = simd_dot(w, u) // + = turning left
            var pitch = simd_dot(w, right) // + = nose up
            if config.smoothing > 0 {
                if smoothingAmount != config.smoothing {
                    smoothingAmount = config.smoothing
                    smoothYaw = AdaptiveSmoother(amount: config.smoothing)
                    smoothPitch = AdaptiveSmoother(amount: config.smoothing)
                }
                yaw = smoothYaw.filter(yaw, dt: dt)
                pitch = smoothPitch.filter(pitch, dt: dt)
            }
            let dz = config.deadzoneDPS
            yaw = copysign(max(abs(yaw) - dz, 0), yaw)
            pitch = copysign(max(abs(pitch) - dz, 0), pitch)
            let gain = config.sensitivity * dt
            pointerMove(-yaw * gain, -pitch * gain)
        }
    }

    // MARK: touchpad

    private func handleTouch(_ p: Packet) {
        let mode = pointerOn ? config.touchModePointerOn : config.touchModePointerOff
        let t = p.touch
        let tnow = now()
        if clutched { // the clutch touch never scrolls
            touchPrev = nil
            touchStart = nil
            return
        }
        if mode == .off {
            touchPrev = t.touching ? (t.x, t.y) : nil
            touchStart = nil
            return
        }
        if t.touching {
            if touchStart == nil { touchStart = (tnow, t.x, t.y) }
            if let prev = touchPrev {
                let dx = Double(t.x - prev.x), dy = Double(t.y - prev.y)
                switch mode {
                case .cursor:
                    pointerMove(dx * config.cursorSpeed, dy * config.cursorSpeed)
                case .scroll:
                    scrollFrac += (config.invertScroll ? -1 : 1) * dy * config.scrollSpeed * 4
                    let step = Int(scrollFrac)
                    if step != 0 {
                        sink.scroll(dy: step)
                        scrollFrac -= Double(step)
                    }
                case .gestures, .off:
                    break
                }
            }
            touchPrev = (t.x, t.y)
            return
        }
        if let start = touchStart, mode == .gestures {
            let end = touchPrev ?? (start.x, start.y)
            let dx = end.x - start.x, dy = end.y - start.y, dur = tnow - start.t
            if dur < Self.swipeMaxS && max(abs(dx), abs(dy)) >= Self.swipeMinDist {
                let name = abs(dx) > abs(dy) ? (dx > 0 ? "swipe_right" : "swipe_left")
                                             : (dy > 0 ? "swipe_down" : "swipe_up")
                tap(Action(config.gestures[name] ?? "none"))
            } else if dur < Self.swipeMaxS && max(abs(dx), abs(dy)) < Self.tapMaxDist
                        && !prevButtons.contains(.touchpad) {
                tap(Action(config.gestures["tap"] ?? "none"))
            }
        }
        touchPrev = nil
        touchStart = nil
    }
}
