import Foundation

public enum MouseButton: String, Codable {
    case left, right, middle
}

/// What a button or gesture does. Stored as a string so configs stay readable:
/// "left_click", "right_click", "middle_click", "key:cmd+[", "media:volume_up",
/// "shell:open -a Safari", "toggle_pointer", "none".
public enum Action: Equatable {
    case click(MouseButton)
    case key(String)
    case media(String)
    case shell(String)
    case togglePointer
    case none

    public init(_ string: String) {
        let (kind, arg): (Substring, String) = {
            guard let i = string.firstIndex(of: ":") else { return (Substring(string), "") }
            return (string[..<i], String(string[string.index(after: i)...]))
        }()
        switch kind {
        case "left_click": self = .click(.left)
        case "right_click": self = .click(.right)
        case "middle_click": self = .click(.middle)
        case "key": self = .key(arg)
        case "media": self = .media(arg)
        case "shell": self = .shell(arg)
        case "toggle_pointer": self = .togglePointer
        default: self = .none
        }
    }

    public var string: String {
        switch self {
        case .click(let b): return "\(b.rawValue)_click"
        case .key(let k): return "key:\(k)"
        case .media(let m): return "media:\(m)"
        case .shell(let s): return "shell:\(s)"
        case .togglePointer: return "toggle_pointer"
        case .none: return "none"
        }
    }
}

public enum TouchMode: String, Codable, CaseIterable {
    case scroll, cursor, gestures, off
}

public enum ClutchZone: String, Codable, CaseIterable {
    case bottom, top, left, right, any
}

public struct RemoteConfig: Codable, Equatable {
    public var buttons: [String: String] = [
        "trigger": "left_click",
        "touchpad": "right_click",
        "back": "key:escape",
        "home": "toggle_pointer",
        "volume_up": "media:volume_up",
        "volume_down": "media:volume_down",
    ]

    // gyro air-mouse
    public var pointerEnabledAtLaunch = true
    public var sensitivity = 22.0 // pixels per degree
    public var deadzoneDPS = 1.2
    public var clickFreezeMS = 150.0

    // touchpad
    public var touchModePointerOn = TouchMode.scroll
    public var touchModePointerOff = TouchMode.cursor
    public var cursorSpeed = 3.0
    public var scrollSpeed = 0.6
    public var invertScroll = false

    // clutch: hold the clutch button, touch the zone, reposition, release
    public var clutchEnabled = true
    public var clutchButton = ControllerButton.trigger
    public var clutchZone = ClutchZone.bottom
    public var clutchZoneSize = 0.35
    public var dragThresholdPX = 12.0
    public var clutchSound = true

    // magnetic targets: snap onto nearby buttons when the pointer slows down
    public var magnetEnabled = true
    public var magnetStrength = 0.25 // 0 subtle ... 1 strong; above 0.55 it snaps

    public var magnet: MagnetSettings { MagnetSettings(strength: magnetStrength) }

    public var gestures: [String: String] = [
        "swipe_left": "key:left",
        "swipe_right": "key:right",
        "swipe_up": "key:up",
        "swipe_down": "key:down",
        "tap": "none",
    ]

    public init() {}

    public func action(for button: ControllerButton) -> Action { Action(buttons[button.rawValue] ?? "none") }

    // Decode leniently so settings saved by older versions keep working.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { value = v }
        }
        take(.buttons, &buttons); take(.pointerEnabledAtLaunch, &pointerEnabledAtLaunch)
        take(.sensitivity, &sensitivity); take(.deadzoneDPS, &deadzoneDPS); take(.clickFreezeMS, &clickFreezeMS)
        take(.touchModePointerOn, &touchModePointerOn); take(.touchModePointerOff, &touchModePointerOff)
        take(.cursorSpeed, &cursorSpeed); take(.scrollSpeed, &scrollSpeed); take(.invertScroll, &invertScroll)
        take(.clutchEnabled, &clutchEnabled); take(.clutchButton, &clutchButton); take(.clutchZone, &clutchZone)
        take(.clutchZoneSize, &clutchZoneSize); take(.dragThresholdPX, &dragThresholdPX)
        take(.clutchSound, &clutchSound); take(.gestures, &gestures)
        take(.magnetEnabled, &magnetEnabled); take(.magnetStrength, &magnetStrength)
    }
}
