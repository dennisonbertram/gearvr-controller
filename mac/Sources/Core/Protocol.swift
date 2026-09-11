// Samsung Gear VR Controller (ET-YO324 / SM-R324) BLE protocol.
// See ../../../PROTOCOL.md for the hardware-verified description.
import Foundation
import simd

public enum GearVR {
    public static let namePrefix = "Gear VR Controller"
    public static let serviceUUID = "4F63756C-7573-2054-6872-65656D6F7465" // "Oculus Three Remote"
    public static let dataUUID = "C8C51726-81BC-483B-A052-F7A14EA3D281"
    public static let commandUUID = "C8C51726-81BC-483B-A052-F7A14EA3D282"

    public static let accelLSBPerG = 2048.0 // +/-16 g
    public static let gyroLSBPerDPS = 14.285 // +/-2000 dps, 70 mdps/LSB
    public static let touchMax = 315.0 // circular pad, both axes ~0...315

    /// Commands are acknowledged by a 2-byte notification echoing them.
    /// `vrMode` takes ~1.5 s to ack and must be acked before `sensor`.
    public enum Command: UInt16 {
        case off = 0x0000, sensor = 0x0100, keepAlive = 0x0400, vrMode = 0x0800
        public var bytes: Data { Data([UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)]) }
    }
}

public enum ControllerButton: String, CaseIterable, Codable, Hashable {
    case trigger, home, back, touchpad
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"

    /// Bit in byte 58 of the data packet.
    public var mask: UInt8 {
        switch self {
        case .trigger: return 0x01
        case .home: return 0x02
        case .back: return 0x04
        case .touchpad: return 0x08
        case .volumeUp: return 0x10
        case .volumeDown: return 0x20
        }
    }

    public var title: String {
        switch self {
        case .trigger: return "Trigger"
        case .home: return "Home"
        case .back: return "Back"
        case .touchpad: return "Touchpad click"
        case .volumeUp: return "Volume +"
        case .volumeDown: return "Volume −"
        }
    }
}

public struct IMUSample: Equatable {
    public var timestampUS: UInt32 // device clock, wraps at 2^32
    public var accel: SIMD3<Double> // g;   +X right, +Y forward (touchpad end), +Z out of the touchpad
    public var gyro: SIMD3<Double> // deg/s, same axes, right-hand rule

    public init(timestampUS: UInt32, accel: SIMD3<Double>, gyro: SIMD3<Double>) {
        self.timestampUS = timestampUS
        self.accel = accel
        self.gyro = gyro
    }
}

public struct Touch: Equatable {
    public var touching: Bool
    public var lifted: Bool // true for exactly one packet when the finger leaves the pad
    public var x: Int // 0 (left) ... ~315 (right)
    public var y: Int // 0 (far edge) ... ~315 (near edge)

    public init(touching: Bool, lifted: Bool = false, x: Int = 0, y: Int = 0) {
        self.touching = touching
        self.lifted = lifted
        self.x = x
        self.y = y
    }

    public static let none = Touch(touching: false)
}

public struct Packet {
    public var samples: [IMUSample] // three per packet, ~206 Hz
    public var magRaw: SIMD3<Int16>
    public var touch: Touch
    public var temperatureC: Int
    public var buttons: Set<ControllerButton>
    public var battery: Int

    public init(samples: [IMUSample], magRaw: SIMD3<Int16> = .zero, touch: Touch, temperatureC: Int = 25,
                buttons: Set<ControllerButton>, battery: Int = 100) {
        self.samples = samples
        self.magRaw = magRaw
        self.touch = touch
        self.temperatureC = temperatureC
        self.buttons = buttons
        self.battery = battery
    }

    /// Decodes a 60-byte notification from the data characteristic.
    public static func parse(_ data: Data) -> Packet? {
        guard data.count == 60 else { return nil }
        let b = [UInt8](data)
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        let samples = [0, 16, 32].map { o in
            IMUSample(
                timestampUS: u32(o),
                accel: SIMD3(Double(i16(o + 4)), Double(i16(o + 6)), Double(i16(o + 8))) / GearVR.accelLSBPerG,
                gyro: SIMD3(Double(i16(o + 10)), Double(i16(o + 12)), Double(i16(o + 14))) / GearVR.gyroLSBPerDPS
            )
        }
        let b54 = b[54], b55 = b[55], b56 = b[56]
        let touch = Touch(
            touching: b54 & 0x10 != 0,
            lifted: b54 & 0x30 == 0,
            x: Int(b54 & 0x0F) << 6 | Int(b55 >> 2),
            y: Int(b55 & 0x03) << 8 | Int(b56)
        )
        let buttons = Set(ControllerButton.allCases.filter { b[58] & $0.mask != 0 })
        return Packet(samples: samples, magRaw: SIMD3(i16(48), i16(50), i16(52)), touch: touch,
                      temperatureC: Int(b[57]), buttons: buttons, battery: Int(b[59]))
    }
}
