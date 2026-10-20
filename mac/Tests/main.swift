// Headless tests for GearVRCore. Built and run by `./build.sh test`.
// usage: core-tests <path to tests_fixtures.json>
import Foundation
import simd

var failures = 0
var passed = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("  FAIL (line \(line)): \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch { failures += 1; print("  FAIL: threw \(error)") }
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

// MARK: fixtures recorded from a real ET-YO324 (see ../tests_fixtures.json)

let fixturePath = CommandLine.arguments.dropFirst().first ?? "../tests_fixtures.json"
let fixtures: [String: String] = {
    guard let data = FileManager.default.contents(atPath: fixturePath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        print("cannot read fixtures at \(fixturePath)")
        exit(2)
    }
    return obj
}()

func hexData(_ hex: String) -> Data {
    var d = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        d.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return d
}

func fixture(_ name: String) -> Packet { Packet.parse(hexData(fixtures[name]!))! }

// MARK: protocol

test("each button decodes alone") {
    let expected: [String: ControllerButton] = [
        "trigger": .trigger, "home": .home, "back": .back, "touchpad": .touchpad,
        "volume_up": .volumeUp, "volume_down": .volumeDown,
    ]
    for (name, button) in expected {
        check(fixture(name).buttons == [button], "\(name) -> \(fixture(name).buttons)")
    }
}

test("idle packet") {
    let p = fixture("idle")
    check(p.buttons.isEmpty, "no buttons")
    check(!p.touch.touching && !p.touch.lifted, "no touch")
    check(p.battery == 100, "battery \(p.battery)")
    check((15...40).contains(p.temperatureC), "temperature \(p.temperatureC)")
}

test("touch center and lift marker") {
    let c = fixture("touch_center").touch
    check(c.touching && (120..<190).contains(c.x) && (120..<200).contains(c.y), "center \(c)")
    let l = fixture("touch_lift").touch
    check(l.lifted && !l.touching, "lift \(l)")
}

test("three samples, microsecond timestamps") {
    let s = fixture("idle").samples
    check(s.count == 3, "count")
    for (a, b) in zip(s, s.dropFirst()) {
        let d = b.timestampUS &- a.timestampUS
        check((4000..<6000).contains(d), "delta \(d)")
    }
}

test("gravity axes: flat +Z, pointing up +Y, rolled left +X") {
    for (pose, axis) in [("idle", 2), ("point_up", 1), ("roll_left", 0)] {
        let a = fixture(pose).samples[2].accel
        check(a[axis] > 0.9, "\(pose) axis \(axis): \(a)")
        check(abs(simd_length(a) - 1) < 0.1, "\(pose) |a| = \(simd_length(a))")
    }
}

test("rejects wrong length") {
    check(Packet.parse(Data([0x08, 0x00])) == nil, "2-byte ack is not a packet")
}

// Expected values from gearvr.py's parse() on the same fixtures (it matches on every captured packet).
func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { simd_length(a - b) < 1e-6 }

test("exact IMU decode: timestamps, accel (g) and gyro (deg/s)") {
    let expected: [String: [(UInt32, SIMD3<Double>, SIMD3<Double>)]] = [
        "idle": [
            (53247950, SIMD3(-0.068359375, 0.2421875, 0.99365234375), SIMD3(-1.1900595029751488, -5.460273013650682, 1.960098004900245)),
            (53252800, SIMD3(-0.0693359375, 0.24169921875, 0.99462890625), SIMD3(-1.1900595029751488, -5.180259012950647, 1.960098004900245)),
            (53257650, SIMD3(-0.06884765625, 0.24267578125, 0.994140625), SIMD3(-1.12005600280014, -4.760238011900595, 1.7500875043752186)),
        ],
        "touch_center": [
            (139834200, SIMD3(0.0908203125, 0.79443359375, 0.6298828125), SIMD3(-2.1001050052502626, -4.200210010500525, 2.5901295064753236)),
            (139839050, SIMD3(0.09423828125, 0.79541015625, 0.62890625), SIMD3(-1.68008400420021, -4.690234511725587, 2.24011200560028)),
            (139843900, SIMD3(0.09375, 0.79736328125, 0.62451171875), SIMD3(-1.3300665033251662, -4.830241512075604, 2.0301015050752538)),
        ],
        "point_up": [ // turning while held up: big, distinct values on every axis
            (221945450, SIMD3(-0.0185546875, 0.97314453125, -0.06298828125), SIMD3(25.691284564228212, -21.351067553377668, 12.95064753237662)),
            (221950300, SIMD3(-0.01171875, 0.97314453125, -0.072265625), SIMD3(23.101155057752887, -21.071053552677633, 11.130556527826391)),
            (221955150, SIMD3(-0.015625, 0.970703125, -0.07177734375), SIMD3(22.051102555127756, -19.810990549527475, 9.660483024151208)),
        ],
    ]
    for (name, samples) in expected {
        let got = fixture(name).samples
        check(got.count == 3, "\(name) count")
        for (i, (g, e)) in zip(got, samples).enumerated() {
            check(g.timestampUS == e.0, "\(name)[\(i)] timestamp \(g.timestampUS)")
            check(near(g.accel, e.1), "\(name)[\(i)] accel \(g.accel)")
            check(near(g.gyro, e.2), "\(name)[\(i)] gyro \(g.gyro)")
        }
    }
}

test("exact magnetometer and touch decode") {
    check(fixture("idle").magRaw == SIMD3(5713, -1155, -187), "idle mag \(fixture("idle").magRaw)")
    check(fixture("touch_center").magRaw == SIMD3(6002, 245, 71), "touch_center mag \(fixture("touch_center").magRaw)")
    check(fixture("point_up").magRaw == SIMD3(6301, -632, 163), "point_up mag \(fixture("point_up").magRaw)")
    let c = fixture("touch_center")
    check(c.touch == Touch(touching: true, lifted: false, x: 140, y: 179), "touch \(c.touch)")
    check(c.temperatureC == 26 && c.battery == 100, "temperature \(c.temperatureC), battery \(c.battery)")
}

test("recorded pitch up moves the cursor up (gyro sign through the mapper)") {
    let path = (fixturePath as NSString).deletingLastPathComponent + "/caps/guided.jsonl"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("  skip: \(path) not present")
        return
    }
    final class DY: InputSink {
        var dy = 0.0
        func move(dx: Double, dy: Double) { self.dy += dy }
        func mouseButton(_ b: MouseButton, down: Bool) {}
        func scroll(dy: Int) {}
        func key(_ combo: String, down: Bool) {}
        func media(_ name: String, down: Bool) {}
        func shell(_ command: String) {}
        func sound(_ name: String) {}
        func adjustVolume(by delta: Double) {}
        func recenter() {}
        func releaseAll() {}
    }
    let sink = DY()
    var cfg = RemoteConfig()
    cfg.sensitivity = 20
    cfg.deadzoneDPS = 1
    cfg.clickFreezeMS = 0
    cfg.smoothing = 0
    let m = InputMapper(config: cfg, sink: sink, now: { 0 })
    var packets = 0
    for line in text.split(separator: "\n") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["src"] as? String == "data", let hex = obj["hex"] as? String, hex.count == 120,
              ["rotate_yaw", "point_up:prompt"].contains(obj["label"] as? String ?? "") else { continue }
        m.handle(Packet(samples: Packet.parse(hexData(hex))!.samples, touch: .none, buttons: []))
        packets += 1
    }
    check(packets > 100, "replayed \(packets) packets")
    check(sink.dy < -500, "cursor went up: dy \(sink.dy)")
}

// MARK: mapper

final class FakeSink: InputSink {
    var events: [String] = []
    func move(dx: Double, dy: Double) { events.append("move") }
    func mouseButton(_ b: MouseButton, down: Bool) { events.append("\(b.rawValue) \(down ? "down" : "up")") }
    func scroll(dy: Int) { events.append("scroll") }
    func key(_ combo: String, down: Bool) { events.append("key \(combo) \(down)") }
    func media(_ name: String, down: Bool) { events.append("media \(name) \(down)") }
    func shell(_ command: String) { events.append("shell") }
    func sound(_ name: String) { events.append("sound \(name)") }
    func adjustVolume(by delta: Double) { events.append(String(format: "volume %+.3f", delta)) }
    func recenter() { events.append("recenter") }
    func releaseAll() {}
    var nonMoves: [String] { events.filter { $0 != "move" } }
}

final class Clock { var t = 0.0 }

final class Rig {
    let sink = FakeSink()
    let clock = Clock() // stays at 0 unless a test moves it
    let mapper: InputMapper
    var t: UInt32 = 1000

    init(_ tweak: (inout RemoteConfig) -> Void = { _ in }) {
        var cfg = RemoteConfig()
        cfg.clickFreezeMS = 0
        cfg.deadzoneDPS = 0
        cfg.sensitivity = 20
        cfg.clutchSound = false
        cfg.smoothing = 0 // these tests check event logic; smoothing has its own test
        tweak(&cfg)
        let clock = self.clock
        mapper = InputMapper(config: cfg, sink: sink, now: { clock.t })
        mapper.bias.calibrated = true
    }

    func feed(_ buttons: Set<ControllerButton> = [], touch: Touch = .none, yaw: Double = 0, n: Int = 1) {
        for _ in 0..<n {
            var samples: [IMUSample] = []
            for _ in 0..<3 {
                t &+= 4850
                samples.append(IMUSample(timestampUS: t, accel: SIMD3(0, 0, 1), gyro: SIMD3(0, 0, yaw)))
            }
            mapper.handle(Packet(samples: samples, touch: touch, buttons: buttons))
        }
    }
}

func touchAt(_ x: Int, _ y: Int) -> Touch { Touch(touching: true, x: x, y: y) }

test("trigger tap clicks on release") {
    let r = Rig()
    r.feed()
    r.feed([.trigger], n: 5)
    check(r.sink.events.isEmpty, "nothing while held: \(r.sink.events)")
    r.feed()
    check(r.sink.events == ["left down", "left up"], "\(r.sink.events)")
}

test("small jitter while pressed neither moves nor drags") {
    let r = Rig()
    r.feed()
    r.feed([.trigger], yaw: 5, n: 4)
    r.feed()
    check(r.sink.events == ["left down", "left up"], "\(r.sink.events)")
}

test("moving while pressed starts a drag") {
    let r = Rig()
    r.feed()
    r.feed([.trigger], yaw: -60, n: 10)
    r.feed()
    check(r.sink.events.first == "left down", "\(r.sink.events)")
    check(r.sink.events.contains("move") && r.sink.events.last == "left up", "\(r.sink.events)")
}

test("clutch freezes the cursor and never clicks") {
    let r = Rig()
    var clutchEvents: [Bool] = []
    r.mapper.onClutch = { clutchEvents.append($0) }
    r.feed()
    r.feed([.trigger], n: 3)
    r.feed([.trigger], touch: touchAt(157, 290), n: 3)
    check(r.mapper.clutched, "engaged")
    r.feed([.trigger], touch: touchAt(157, 200), n: 3)
    r.feed([.trigger], yaw: 90, n: 20)
    check(r.sink.events.isEmpty, "frozen: \(r.sink.events)")
    r.feed()
    check(!r.mapper.clutched && r.sink.events.isEmpty, "released quietly: \(r.sink.events)")
    r.feed(yaw: 90, n: 3)
    check(!r.sink.events.isEmpty && Set(r.sink.events) == ["move"], "pointer resumes: \(r.sink.events)")
    check(clutchEvents == [true, false], "callbacks \(clutchEvents)")
}

test("touching elsewhere while pressed does not clutch") {
    let r = Rig()
    r.feed()
    r.feed([.trigger], touch: touchAt(157, 60), n: 3)
    check(!r.mapper.clutched, "not engaged")
    r.feed()
    check(r.sink.nonMoves == ["left down", "left up"], "\(r.sink.events)")
}

test("touchpad click during the clutch is suppressed") {
    let r = Rig()
    r.feed()
    r.feed([.trigger], n: 2)
    r.feed([.trigger], touch: touchAt(150, 300), n: 2)
    r.feed([.trigger, .touchpad], touch: touchAt(150, 300), n: 2)
    r.feed([.trigger], n: 2)
    r.feed()
    check(r.sink.events.isEmpty, "\(r.sink.events)")
}

test("clutch disabled keeps the immediate press") {
    let r = Rig { $0.clutchEnabled = false }
    r.feed()
    r.feed([.trigger])
    check(r.sink.events == ["left down"], "\(r.sink.events)")
}

test("clutch: thumb already resting in the zone engages once the hand moves") {
    let r = Rig()
    r.feed(touch: touchAt(157, 290), n: 3) // resting on the bottom of the pad
    r.feed([.trigger], touch: touchAt(157, 290), n: 2)
    check(!r.mapper.clutched, "not yet: could still be a click")
    r.feed([.trigger], touch: touchAt(157, 290), yaw: 90, n: 20)
    check(r.mapper.clutched, "engaged instead of dragging")
    r.feed(touch: touchAt(157, 290))
    check(r.sink.nonMoves.isEmpty, "never clicked or dragged: \(r.sink.events)")
}

test("clutch: a still press with the thumb resting in the zone is a plain click") {
    let r = Rig()
    r.feed(touch: touchAt(157, 290), n: 3)
    r.feed([.trigger], touch: touchAt(157, 290), n: 3)
    r.feed(touch: touchAt(157, 290))
    check(!r.mapper.clutched && r.sink.nonMoves == ["left down", "left up"], "\(r.sink.events)")
}

test("clutch: touch landing in the same packet as the press engages") {
    let r = Rig()
    r.feed()
    r.feed([.trigger], touch: touchAt(157, 290))
    check(r.mapper.clutched, "engaged")
    r.feed([.trigger], touch: touchAt(157, 290), yaw: 90, n: 10)
    r.feed()
    check(r.sink.events.isEmpty, "\(r.sink.events)")
}

test("clutch: works with the touchpad click as the clutch button") {
    let r = Rig { $0.clutchButton = .touchpad; $0.buttons["touchpad"] = "left_click" }
    r.feed(touch: touchAt(157, 290))
    r.feed([.touchpad], touch: touchAt(157, 290), yaw: 90, n: 10)
    check(r.mapper.clutched, "engaged")
    r.feed()
    check(r.sink.nonMoves.isEmpty, "\(r.sink.events)")
}

test("reset releases held keys and media keys") {
    let r = Rig()
    r.feed()
    r.feed([.back, .volumeUp])
    r.mapper.reset()
    check(r.sink.events.suffix(2).sorted() == ["key escape false", "media volume_up false"], "\(r.sink.events)")
    r.feed() // the physical release after reconnecting sends nothing more
    check(r.sink.events.count == 4, "\(r.sink.events)")
    r.mapper.reset()
    check(r.sink.events.count == 4, "nothing held, nothing released: \(r.sink.events)")
}

test("recenter: a quick second click is an ordinary double-click") {
    let r = Rig()
    r.feed()
    r.feed([.trigger], n: 2)
    r.clock.t = 0.1; r.feed()
    r.clock.t = 0.2; r.feed([.trigger], n: 2)
    check(r.sink.nonMoves == ["left down", "left up"], "second press held back: \(r.sink.nonMoves)")
    r.clock.t = 0.3; r.feed()
    check(r.sink.nonMoves == ["left down", "left up", "left down", "left up"], "\(r.sink.nonMoves)")
}

test("recenter: double-click and hold the second click recenters without clicking") {
    let r = Rig()
    r.feed()
    r.feed([.trigger])
    r.clock.t = 0.1; r.feed()
    r.clock.t = 0.2; r.feed([.trigger])
    r.clock.t = 0.75; r.feed([.trigger], n: 3)
    r.clock.t = 1.0; r.feed()
    check(r.sink.nonMoves == ["left down", "left up", "recenter"], "\(r.sink.nonMoves)")
}

test("recenter: moving during the second press is a double-click-drag") {
    let r = Rig()
    r.feed()
    r.feed([.trigger])
    r.clock.t = 0.1; r.feed()
    r.clock.t = 0.2; r.feed([.trigger], yaw: -60, n: 10)
    r.clock.t = 0.4; r.feed()
    check(r.sink.nonMoves == ["left down", "left up", "left down", "left up"], "\(r.sink.nonMoves)")
    check(!r.sink.events.contains("recenter"), "no recenter")
}

test("recenter: a slow second click is just a click, and the setting turns it off") {
    let r = Rig()
    r.feed()
    r.feed([.trigger])
    r.clock.t = 0.1; r.feed()
    r.clock.t = 0.8; r.feed([.trigger])
    r.clock.t = 1.5; r.feed([.trigger]); r.feed()
    check(r.sink.nonMoves == ["left down", "left up", "left down", "left up"], "plain click: \(r.sink.nonMoves)")
    let off = Rig { $0.recenterGesture = false }
    off.feed()
    off.feed([.trigger])
    off.clock.t = 0.1; off.feed()
    off.clock.t = 0.2; off.feed([.trigger])
    off.clock.t = 1.0; off.feed([.trigger]); off.feed()
    check(off.sink.nonMoves == ["left down", "left up", "left down", "left up"], "\(off.sink.nonMoves)")
}

test("pad holds: spots on the circular pad") {
    check(InputMapper.padSpot(touchAt(157, 20)) == "top", "top")
    check(InputMapper.padSpot(touchAt(157, 300)) == "bottom", "bottom")
    check(InputMapper.padSpot(touchAt(15, 160)) == "left", "left")
    check(InputMapper.padSpot(touchAt(300, 150)) == "right", "right")
    check(InputMapper.padSpot(touchAt(170, 140)) == "center", "center")
}

test("pad holds: holding a spot runs its action instead of the click") {
    let r = Rig { $0.padHolds["top"] = "key:cmd+shift+4" }
    r.feed()
    r.feed([.touchpad], touch: touchAt(157, 20))
    check(r.sink.nonMoves.isEmpty, "click held back: \(r.sink.nonMoves)")
    r.clock.t = 0.6; r.feed([.touchpad], touch: touchAt(157, 20))
    r.clock.t = 1.0; r.feed()
    check(r.sink.nonMoves == ["key cmd+shift+4 true", "key cmd+shift+4 false"], "\(r.sink.nonMoves)")
}

test("pad holds: a quick click is still the touchpad click; an unset spot holds normally") {
    let r = Rig { $0.padHolds["top"] = "key:cmd+shift+4" }
    r.feed()
    r.feed([.touchpad], touch: touchAt(157, 20))
    r.clock.t = 0.2; r.feed()
    check(r.sink.nonMoves == ["right down", "right up"], "quick click: \(r.sink.nonMoves)")
    r.clock.t = 1.0; r.feed([.touchpad], touch: touchAt(300, 150))
    r.clock.t = 1.6; r.feed([.touchpad], touch: touchAt(300, 150))
    check(r.sink.nonMoves.suffix(1) == ["right down"], "unset spot: \(r.sink.nonMoves)")
    r.clock.t = 2.0; r.feed()
    check(r.sink.nonMoves.suffix(2) == ["right down", "right up"], "\(r.sink.nonMoves)")
}

test("pad holds: with none set, the touchpad click is immediate as before") {
    let r = Rig()
    r.feed()
    r.feed([.touchpad], touch: touchAt(157, 20))
    check(r.sink.nonMoves == ["right down"], "\(r.sink.nonMoves)")
}

test("home toggles the air-mouse; no motion when off") {
    let r = Rig()
    var toggles: [Bool] = []
    r.mapper.onPointerToggle = { toggles.append($0) }
    r.feed()
    r.feed([.home])
    r.feed()
    check(toggles == [false] && !r.mapper.pointerOn, "toggled off")
    r.feed(yaw: 90, n: 5)
    check(r.sink.events.isEmpty, "no motion: \(r.sink.events)")
}

test("yaw left moves the cursor left, pitch up moves it up") {
    final class MoveSink: InputSink {
        var dx = 0.0, dy = 0.0
        func move(dx: Double, dy: Double) { self.dx += dx; self.dy += dy }
        func mouseButton(_ b: MouseButton, down: Bool) {}
        func scroll(dy: Int) {}
        func key(_ combo: String, down: Bool) {}
        func media(_ name: String, down: Bool) {}
        func shell(_ command: String) {}
        func sound(_ name: String) {}
        func adjustVolume(by delta: Double) {}
        func recenter() {}
        func releaseAll() {}
    }
    let sink = MoveSink()
    var cfg = RemoteConfig()
    cfg.clickFreezeMS = 0
    cfg.smoothing = 0
    let m = InputMapper(config: cfg, sink: sink, now: { 0 })
    m.bias.calibrated = true
    var t: UInt32 = 0
    func feed(_ gyro: SIMD3<Double>) {
        let samples = (0..<3).map { _ -> IMUSample in
            t &+= 4850
            return IMUSample(timestampUS: t, accel: SIMD3(0, 0, 1), gyro: gyro)
        }
        m.handle(Packet(samples: samples, touch: .none, buttons: []))
    }
    for _ in 0..<20 { feed(SIMD3(0, 0, 30)) } // +Z = turning left
    check(sink.dx < -50 && abs(sink.dy) < 1, "left: \(sink.dx), \(sink.dy)")
    sink.dx = 0
    for _ in 0..<20 { feed(SIMD3(30, 0, 0)) } // +X = nose up
    check(sink.dy < -50 && abs(sink.dx) < 1, "up: \(sink.dx), \(sink.dy)")
}

test("smoothing: calms jitter at rest, keeps up with fast moves") {
    var s = AdaptiveSmoother(amount: 0.3)
    var jitterIn = 0.0, jitterOut = 0.0
    for i in 0..<400 { // +/-3 deg/s tremor at ~10 Hz around zero, sampled at 206 Hz
        let x = 3 * sin(Double(i) * 2 * .pi * 10 / 206)
        let y = s.filter(x, dt: 1 / 206)
        if i > 100 { jitterIn += x * x; jitterOut += y * y }
    }
    check(jitterOut < jitterIn * 0.5, "tremor reduced: \(jitterOut / jitterIn)")
    var f = AdaptiveSmoother(amount: 0.3)
    var y = 0.0
    for _ in 0..<10 { y = f.filter(200, dt: 1 / 206) } // sudden 200 deg/s flick, ~50 ms
    check(y > 190, "fast move barely delayed: \(y)")
}

test("smoothing: applied by the mapper, and fully bypassed at 0") {
    final class Sum: InputSink {
        var dx = 0.0, moves = 0
        func move(dx: Double, dy: Double) { self.dx += dx; moves += 1 }
        func mouseButton(_ b: MouseButton, down: Bool) {}
        func scroll(dy: Int) {}
        func key(_ combo: String, down: Bool) {}
        func media(_ name: String, down: Bool) {}
        func shell(_ command: String) {}
        func sound(_ name: String) {}
        func adjustVolume(by delta: Double) {}
        func recenter() {}
        func releaseAll() {}
    }
    func run(_ smoothing: Double) -> (first: Double, total: Double) {
        let sink = Sum()
        var cfg = RemoteConfig()
        cfg.clickFreezeMS = 0
        cfg.deadzoneDPS = 0
        cfg.smoothing = smoothing
        let m = InputMapper(config: cfg, sink: sink, now: { 0 })
        m.bias.calibrated = true
        var t: UInt32 = 0
        var first = 0.0
        for i in 0..<60 {
            let gyro = SIMD3<Double>(0, 0, i >= 5 && i < 25 ? 20 : 0) // rest, turn, rest
            let samples = (0..<3).map { _ -> IMUSample in t &+= 4850; return IMUSample(timestampUS: t, accel: SIMD3(0, 0, 1), gyro: gyro) }
            m.handle(Packet(samples: samples, touch: .none, buttons: []))
            if i == 6 { first = sink.dx }
        }
        return (first, sink.dx)
    }
    let raw = run(0), smooth = run(0.5)
    check(abs(smooth.first) < abs(raw.first), "smoothed start is gentler: \(smooth.first) vs \(raw.first)")
    check(abs(smooth.total - raw.total) / abs(raw.total) < 0.1, "same distance overall: \(smooth.total) vs \(raw.total)")
}

test("smoothing: restarts after the air-mouse was off, not from the old rate") {
    final class Sum: InputSink {
        var dx = 0.0
        func move(dx: Double, dy: Double) { self.dx += dx }
        func mouseButton(_ b: MouseButton, down: Bool) {}
        func scroll(dy: Int) {}
        func key(_ combo: String, down: Bool) {}
        func media(_ name: String, down: Bool) {}
        func shell(_ command: String) {}
        func sound(_ name: String) {}
        func adjustVolume(by delta: Double) {}
        func recenter() {}
        func releaseAll() {}
    }
    let sink = Sum()
    var cfg = RemoteConfig()
    cfg.clickFreezeMS = 0
    cfg.deadzoneDPS = 0
    cfg.smoothing = 0.3
    let m = InputMapper(config: cfg, sink: sink, now: { 0 })
    m.bias.calibrated = true
    var t: UInt32 = 0
    func feed(_ yaw: Double, n: Int) {
        for _ in 0..<n {
            let samples = (0..<3).map { _ -> IMUSample in t &+= 4850; return IMUSample(timestampUS: t, accel: SIMD3(0, 0, 1), gyro: SIMD3(0, 0, yaw)) }
            m.handle(Packet(samples: samples, touch: .none, buttons: []))
        }
    }
    feed(60, n: 20) // turning at 60 deg/s
    m.pointerOn = false
    feed(0, n: 20) // stopped while off
    m.pointerOn = true
    sink.dx = 0
    feed(0, n: 20) // still
    check(abs(sink.dx) < 0.5, "no drift on resume: \(sink.dx) px")
    // turning smoothing off and back on to the same value starts fresh too
    feed(60, n: 20)
    m.config.smoothing = 0
    feed(0, n: 1)
    m.config.smoothing = 0.3
    sink.dx = 0
    feed(0, n: 20)
    check(abs(sink.dx) < 0.5, "no drift after re-enabling: \(sink.dx) px")
}

test("config: v1 settings on the old default speed move to the new default") {
    let old = try JSONDecoder().decode(RemoteConfig.self, from: Data(#"{"sensitivity": 22}"#.utf8))
    check(old.version == 1 && old.migrated().sensitivity == 18, "22 -> 18")
    let custom = try JSONDecoder().decode(RemoteConfig.self, from: Data(#"{"sensitivity": 30}"#.utf8))
    check(custom.migrated().sensitivity == 30, "custom speed kept")
    check(RemoteConfig().version == RemoteConfig.currentVersion && RemoteConfig().sensitivity == 18, "new default")
}

test("manual recalibration: adopts the zero point when the controller is still") {
    let b = GyroBias()
    var states: [GyroBias.Calibration] = []
    b.onCalibration = { states.append($0) }
    b.startManualCalibration(sampleCount: 200)
    check(b.isCollecting, "collecting")
    for i in 0..<200 { b.update(SIMD3(-1.1, -4.5, 1.8) + SIMD3(0.1 * sin(Double(i)), 0, 0)) }
    check(!b.isCollecting, "finished")
    if case .finished(let ok, let drift, let wobble) = b.manual {
        check(ok, "accepted (wobble \(wobble))")
        check(abs(drift - simd_length(SIMD3<Double>(-1.1, -4.5, 1.8))) < 0.1, "reports the drift it removed")
    } else {
        check(false, "state \(b.manual)")
    }
    check(b.calibrated && simd_length(b.bias - SIMD3(-1.1, -4.5, 1.8)) < 0.2, "bias set: \(b.bias)")
    check(states.contains { if case .collecting = $0 { return true }; return false }, "reported progress")
}

test("manual recalibration: rejects a moving controller and keeps the old zero") {
    let b = GyroBias()
    for _ in 0..<100 { b.update(SIMD3(1, 1, 1)) } // settle an automatic bias first
    let before = b.bias
    b.startManualCalibration(sampleCount: 200)
    for i in 0..<200 { b.update(SIMD3(20 * sin(Double(i) / 5), 0, 0)) } // waving it around
    if case .finished(let ok, _, let wobble) = b.manual {
        check(!ok && wobble > GyroBias.manualWobbleLimit, "rejected (wobble \(wobble))")
    } else {
        check(false, "state \(b.manual)")
    }
    check(b.bias == before, "old zero kept")
}

test("manual recalibration: a slow steady turn is not adopted as the zero") {
    let b = GyroBias()
    for _ in 0..<100 { b.update(SIMD3(-1.1, -4.5, 1.8)) }
    let before = b.bias
    b.startManualCalibration(sampleCount: 200)
    for _ in 0..<200 { b.update(SIMD3(-1.1, -4.5 + 3, 1.8)) } // arm sagging at 3 deg/s: no wobble
    if case .finished(let ok, _, let wobble) = b.manual {
        check(!ok && wobble > 2, "rejected as motion (\(wobble))")
    } else {
        check(false, "state \(b.manual)")
    }
    check(b.bias == before, "old zero kept")
    // a real shift shows up the same way twice: the second measurement confirms it
    b.startManualCalibration(sampleCount: 200)
    for _ in 0..<200 { b.update(SIMD3(-1.1, -4.5 + 3, 1.8)) }
    if case .finished(let ok, _, _) = b.manual { check(ok, "confirmed on repeat") }
    check(simd_length(b.bias - SIMD3(-1.1, -1.5, 1.8)) < 1e-9, "bias \(b.bias)")
    // a small correction is accepted straight away
    b.startManualCalibration(sampleCount: 200)
    for _ in 0..<200 { b.update(SIMD3(-1.1, -1.0, 1.8)) }
    if case .finished(let ok, _, _) = b.manual { check(ok, "small shift accepted") }
}

test("gyro bias calibrates when still") {
    let b = GyroBias()
    for _ in 0..<100 { b.update(SIMD3(-1.1, -4.5, 1.8)) }
    check(b.calibrated && simd_length(b.bias - SIMD3(-1.1, -4.5, 1.8)) < 1e-9, "\(b.bias)")
}

test("volume: holding a media button repeats it like a keyboard") {
    var clock = 0.0
    let sink = FakeSink()
    var cfg = RemoteConfig()
    cfg.clickFreezeMS = 0
    cfg.smoothing = 0
    cfg.repeatDelayMS = 300
    cfg.repeatIntervalMS = 100
    let m = InputMapper(config: cfg, sink: sink, now: { clock })
    m.bias.calibrated = true
    var t: UInt32 = 0
    func feed(_ buttons: Set<ControllerButton>, seconds: Double) {
        let steps = Int(seconds / 0.0147)
        for _ in 0..<steps {
            clock += 0.0147
            let samples = (0..<3).map { _ -> IMUSample in t &+= 4850; return IMUSample(timestampUS: t, accel: SIMD3(0, 0, 1), gyro: .zero) }
            m.handle(Packet(samples: samples, touch: .none, buttons: buttons))
        }
    }
    feed([], seconds: 0.1)
    feed([.volumeDown], seconds: 0.2) // still inside the initial delay
    let early = sink.events.filter { $0.hasPrefix("media") }.count
    check(early == 1, "one press, no repeat yet: \(early / 2) presses")
    feed([.volumeDown], seconds: 1.0) // held for another second: ~10 repeats
    let held = sink.events.filter { $0 == "media volume_down true" }.count
    check(held >= 8 && held <= 13, "repeats about every 100 ms: \(held)")
    feed([], seconds: 0.3)
    let after = sink.events.filter { $0 == "media volume_down true" }.count
    check(after == held, "stops on release")
}

test("volume: touchpad volume mode slides the system volume") {
    let r = Rig { $0.touchModePointerOn = .volume }
    r.feed(touch: touchAt(150, 200))
    r.feed(touch: touchAt(150, 100)) // thumb slides up the pad
    let ups = r.sink.events.filter { $0.hasPrefix("volume +") }
    check(ups.count == 1, "one change: \(r.sink.events)")
    check(ups.first == "volume +0.254", "a third of the pad is about a quarter of full scale: \(ups)")
    r.feed(touch: touchAt(150, 260)) // and back down
    check(r.sink.events.last?.hasPrefix("volume -") == true, "down lowers it: \(r.sink.events.last ?? "-")")
}

test("scroll mode scrolls, gestures mode swipes") {
    let r = Rig()
    r.feed(touch: touchAt(150, 100))
    r.feed(touch: touchAt(150, 140))
    check(r.sink.events.contains("scroll"), "scrolled: \(r.sink.events)")
    let g = Rig { $0.touchModePointerOn = .gestures }
    g.feed(touch: touchAt(40, 150))
    g.feed(touch: touchAt(200, 150))
    g.feed()
    check(g.sink.events == ["key right true", "key right false"], "swipe: \(g.sink.events)")
}

test("gestures: a touchpad click is not also a tap") {
    let r = Rig { $0.touchModePointerOn = .gestures; $0.gestures["tap"] = "key:space" }
    r.feed(touch: touchAt(150, 150))
    r.feed([.touchpad], touch: touchAt(150, 150))
    r.feed(touch: touchAt(150, 150)) // click released before the finger lifts
    r.feed()
    check(r.sink.events == ["right down", "right up"], "click only: \(r.sink.events)")
    r.sink.events = []
    r.feed(touch: touchAt(150, 150))
    r.feed()
    check(r.sink.events == ["key space true", "key space false"], "a plain tap still taps: \(r.sink.events)")
}

test("config round-trips and tolerates missing keys") {
    var c = RemoteConfig()
    c.sensitivity = 33
    c.buttons["back"] = "key:cmd+["
    let data = try JSONEncoder().encode(c)
    check(try JSONDecoder().decode(RemoteConfig.self, from: data) == c, "round trip")
    let partial = try JSONDecoder().decode(RemoteConfig.self, from: Data(#"{"sensitivity": 9}"#.utf8))
    check(partial.sensitivity == 9 && partial.clutchEnabled, "partial decode")
    check(Action("key:cmd+[") == .key("cmd+[") && Action("key:cmd+[").string == "key:cmd+[", "action strings")
}

// MARK: magnet

final class MagnetRig {
    let m = Magnet()
    var p = CGPoint(x: 100, y: 100)
    var t: TimeInterval = 10

    /// hand motion of `d` per 5 ms step
    func move(_ d: CGVector, steps: Int = 1) {
        for _ in 0..<steps {
            t += 0.005
            p = m.userMove(from: p, by: d, at: t)
            if let q = m.tick(cursor: p, at: t) { p = q }
        }
    }

    /// hand held still for `seconds`
    func rest(_ seconds: Double) {
        let steps = Int(seconds / 0.008)
        for _ in 0..<steps {
            t += 0.008
            if let q = m.tick(cursor: p, at: t) { p = q }
        }
    }
}

test("magnet: resting near a button snaps onto its centre") {
    let r = MagnetRig()
    r.m.targets = [CGRect(x: 120, y: 90, width: 40, height: 20)] // 20 px to the right
    r.rest(0.4)
    check(r.m.locked != nil, "locked")
    check(abs(r.p.x - 140) < 1 && abs(r.p.y - 100) < 1, "centred at \(r.p)")
}

test("magnet: far targets are ignored") {
    let r = MagnetRig()
    r.m.targets = [CGRect(x: 300, y: 300, width: 40, height: 20)]
    r.rest(0.4)
    check(r.m.locked == nil && r.p == CGPoint(x: 100, y: 100), "untouched \(r.p)")
}

test("magnet: moving fast past a button does not grab") {
    let r = MagnetRig()
    r.m.targets = [CGRect(x: 110, y: 90, width: 30, height: 20)]
    r.move(CGVector(dx: 6, dy: 0), steps: 30) // 1200 px/s
    check(r.m.locked == nil, "not locked while fast")
    check(r.p.x > 270, "kept going: \(r.p)")
}

test("magnet: tremor while snapped stays on the button") {
    let r = MagnetRig()
    let button = CGRect(x: 120, y: 90, width: 40, height: 20)
    r.m.targets = [button]
    r.rest(0.4)
    for i in 0..<200 { r.move(CGVector(dx: i % 2 == 0 ? 1.5 : -1.5, dy: i % 3 == 0 ? 1 : -0.5)) }
    check(r.m.locked != nil && button.contains(r.p), "still on button: \(r.p)")
}

test("magnet: a deliberate push breaks free in that direction") {
    let r = MagnetRig()
    r.m.targets = [CGRect(x: 120, y: 90, width: 40, height: 20)]
    r.rest(0.4)
    r.move(CGVector(dx: 1.2, dy: 0), steps: 60) // steady push right: 72 px of hand motion at 240 px/s
    check(r.m.locked == nil, "released")
    check(r.p.x > 180, "popped out to the right: \(r.p)")
    r.rest(0.3)
    check(r.m.locked == nil, "doesn't re-grab the button it just left")
}

test("magnet (subtle): never moves the pointer on its own") {
    let r = MagnetRig()
    r.m.settings = MagnetSettings(strength: 0.25)
    r.m.targets = [CGRect(x: 110, y: 95, width: 20, height: 14)]
    r.rest(0.5)
    check(r.p == CGPoint(x: 100, y: 100) && r.m.locked == nil, "untouched: \(r.p)")
}

test("magnet (subtle): motion is damped over a button, strongly when nearly still") {
    let button = CGRect(x: 100, y: 100, width: 40, height: 20)
    func travel(start: CGPoint, step: CGVector, targets: [CGRect]) -> Double {
        let r = MagnetRig()
        r.m.settings = MagnetSettings(strength: 0.25)
        r.m.targets = targets
        r.p = start
        r.move(step, steps: 20)
        return hypot(r.p.x - start.x, r.p.y - start.y)
    }
    let inside = CGPoint(x: 120, y: 110)
    let freeMoving = travel(start: inside, step: CGVector(dx: 1, dy: 0), targets: [])
    let onButtonMoving = travel(start: inside, step: CGVector(dx: 1, dy: 0), targets: [button])
    let onButtonTremor = travel(start: inside, step: CGVector(dx: 0.2, dy: 0), targets: [button])
    check(onButtonMoving < freeMoving * 0.9 && onButtonMoving > freeMoving * 0.5, "moderate friction: \(onButtonMoving) vs \(freeMoving)")
    check(onButtonTremor < 4 * 0.6, "tremor damped harder: \(onButtonTremor)")
}

test("magnet (subtle): approaching bends toward the centre, leaving is not pulled back") {
    let button = CGRect(x: 150, y: 100, width: 30, height: 20) // centre (165, 110)
    let r = MagnetRig()
    r.m.settings = MagnetSettings(strength: 0.25)
    r.m.targets = [button]
    r.p = CGPoint(x: 135, y: 97) // above-left, heading right
    r.move(CGVector(dx: 2, dy: 0), steps: 6)
    check(r.p.y > 97.5, "bent down toward the button: \(r.p)")
    let away = MagnetRig()
    away.m.settings = MagnetSettings(strength: 0.25)
    away.m.targets = [button]
    away.p = CGPoint(x: 190, y: 97) // right of the button, heading further right
    away.move(CGVector(dx: 2, dy: 0), steps: 6)
    check(abs(away.p.y - 97) < 0.01, "no pull when leaving: \(away.p)")
}

test("magnet: step across the traffic lights with small pushes") {
    let r = MagnetRig()
    r.m.settings = MagnetSettings(strength: 0.8)
    // close, minimise, zoom: 14 px buttons, 20 px apart
    let lights = [0, 20, 40].map { CGRect(x: 200 + $0, y: 100, width: 14, height: 14) }
    r.m.targets = lights
    r.p = CGPoint(x: 204, y: 118) // just below the close button
    r.rest(0.3)
    check(r.m.locked == lights[0], "on close")
    r.move(CGVector(dx: 0.5, dy: 0), steps: 20) // ~10 px push right at 100 px/s
    r.rest(0.3)
    check(r.m.locked == lights[1], "hopped to minimise: \(String(describing: r.m.locked))")
    check(abs(r.p.x - lights[1].midX) < 1, "centred on minimise: \(r.p)")
    r.move(CGVector(dx: 0.5, dy: 0), steps: 20)
    r.rest(0.3)
    check(r.m.locked == lights[2], "hopped to zoom")
    r.move(CGVector(dx: -0.5, dy: 0), steps: 20)
    r.rest(0.3)
    check(r.m.locked == lights[1], "and back to minimise")
}

test("magnet: leaving a small button into empty space takes a short push") {
    let r = MagnetRig()
    r.m.settings = MagnetSettings(strength: 0.8)
    let close = CGRect(x: 200, y: 100, width: 14, height: 14)
    r.m.targets = [close]
    r.p = CGPoint(x: 207, y: 120)
    r.rest(0.3)
    check(r.m.locked == close, "snapped")
    r.move(CGVector(dx: 0, dy: 0.8), steps: 30) // ~24 px push down
    check(r.m.locked == nil && r.p.y > 125, "free below the button: \(r.p)")
}

test("magnet: strength knob goes from subtle assist to snapping") {
    let subtle = MagnetSettings(strength: 0.25), strong = MagnetSettings(strength: 1)
    check(!subtle.snap && strong.snap, "only the strong end snaps")
    check(subtle.friction > 0.6 && subtle.friction < 1, "subtle friction \(subtle.friction)")
    check(subtle.radius < strong.radius && strong.stickiness < 0.5, "reach grows, hold firms up")
    check(!MagnetSettings(strength: 0).snap && MagnetSettings(strength: 0).friction == 1, "zero does nothing")
    check(RemoteConfig().magnetStrength == 0.25, "default is subtle")
}

test("magnet: innermost target wins when nested") {
    let r = MagnetRig()
    r.p = CGPoint(x: 150, y: 150)
    r.m.targets = [CGRect(x: 100, y: 100, width: 200, height: 100), CGRect(x: 140, y: 140, width: 30, height: 20)]
    check(r.m.nearest(to: r.p) == CGRect(x: 140, y: 140, width: 30, height: 20), "smallest under the pointer")
}

test("magnet: target vanishing releases the lock") {
    let r = MagnetRig()
    r.m.targets = [CGRect(x: 120, y: 90, width: 40, height: 20)]
    r.rest(0.3)
    r.m.targets = []
    check(r.m.locked == nil, "released")
}

test("magnet: a target that shifts a few pixels between scans stays locked") {
    let r = MagnetRig()
    let a = CGRect(x: 120, y: 90, width: 44, height: 56), neighbour = CGRect(x: 76, y: 90, width: 44, height: 56)
    r.p = CGPoint(x: 150, y: 80) // 10 px above `a`, ~32 px from the neighbour
    r.m.targets = [neighbour, a]
    r.rest(0.3)
    check(r.m.locked == a, "locked on the nearest")
    let shifted = a.offsetBy(dx: 3, dy: -2)
    r.m.targets = [neighbour.offsetBy(dx: 3, dy: -2), shifted]
    r.rest(0.3)
    check(r.m.locked == shifted, "followed the shifted target, not the neighbour: \(String(describing: r.m.locked))")
    check(abs(r.p.x - shifted.midX) < 1 && abs(r.p.y - shifted.midY) < 1, "centred on it")
}

test("magnet: a target that blinks out and back is grabbed again") {
    let r = MagnetRig()
    let a = CGRect(x: 120, y: 90, width: 40, height: 20)
    r.m.targets = [a]
    r.rest(0.3)
    r.m.targets = []
    r.m.targets = [a]
    r.rest(0.2)
    check(r.m.locked == a, "relocked")
}

test("magnet: speed counts a packet's three moves over the packet's time") {
    let m = Magnet()
    var t = 10.0
    // 100 px/s at 68 packets/s, each packet's motion split over three moves microseconds apart
    for _ in 0..<200 {
        t += 1 / 68.0
        for i in 0..<3 { _ = m.userMove(from: .zero, by: CGVector(dx: 100 / 68.0 / 3, dy: 0), at: t + Double(i) * 1e-5) }
    }
    check(abs(m.speedPxPerSec - 100) < 3, "speed \(m.speedPxPerSec)")
}

print("\n\(passed) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
