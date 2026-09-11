// Synthesizes mouse, keyboard and media-key events with Quartz.
// Requires Accessibility permission (System Settings > Privacy & Security).
import AppKit
import CoreGraphics

enum KeyCombo {
    static let keycodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "f5": 96, "f6": 97,
        "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111,
        "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119,
        "f2": 120, "pagedown": 121, "f1": 122, "left": 123, "right": 124, "down": 125,
        "up": 126,
    ]
    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
    ]

    /// "cmd+shift+[" -> (keycode, flags). A literal plus is written "shift+=".
    static func parse(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = keycodes[key] else { return nil }
        var flags = CGEventFlags()
        for m in parts.dropLast() {
            guard let f = modifiers[m] else { return nil }
            flags.insert(f)
        }
        return (code, flags)
    }
}

enum MediaKey {
    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    static let codes: [String: Int] = [
        "volume_up": 0, "volume_down": 1, "brightness_up": 2, "brightness_down": 3,
        "mute": 7, "play": 16, "next": 17, "previous": 18, "fast": 19, "rewind": 20,
    ]
    static let names = ["volume_up", "volume_down", "mute", "play", "next", "previous",
                        "brightness_up", "brightness_down"]
}

final class EventSink: InputSink {
    /// When false, events are logged instead of posted (debugging next to another client).
    var postEvents = true
    var log: ((String) -> Void)?

    private var held: Set<MouseButton> = []
    private var frac = CGPoint.zero
    private var bounds = CGRect.zero
    private var lastClick: (button: MouseButton, time: TimeInterval, count: Int64)?

    init() {
        refreshBounds()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.refreshBounds() }
    }

    private func refreshBounds() {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    private var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func post(_ event: CGEvent?) {
        guard postEvents else { return }
        event?.post(tap: .cghidEventTap)
    }

    private static func types(_ b: MouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType, button: CGMouseButton) {
        switch b {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        }
    }

    func move(dx: Double, dy: Double) {
        frac.x += dx
        frac.y += dy
        let ix = frac.x.rounded(.towardZero), iy = frac.y.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        frac.x -= ix
        frac.y -= iy
        var p = location
        p.x = min(max(p.x + ix, bounds.minX), bounds.maxX - 1)
        p.y = min(max(p.y + iy, bounds.minY), bounds.maxY - 1)
        var type = CGEventType.mouseMoved, button = CGMouseButton.left
        if let h = [MouseButton.left, .right, .middle].first(where: held.contains) {
            (_, _, type, button) = Self.types(h)
        }
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        post(e)
    }

    func mouseButton(_ b: MouseButton, down: Bool) {
        let t = Self.types(b)
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastClick, last.button == b, now - last.time < NSEvent.doubleClickInterval {
                lastClick = (b, now, last.count + 1)
            } else {
                lastClick = (b, now, 1)
            }
            held.insert(b)
        } else {
            held.remove(b)
        }
        let e = CGEvent(mouseEventSource: nil, mouseType: down ? t.down : t.up, mouseCursorPosition: location,
                        mouseButton: t.button)
        e?.setIntegerValueField(.mouseEventClickState, value: lastClick?.count ?? 1)
        log?("\(b.rawValue) \(down ? "down" : "up")")
        post(e)
    }

    func scroll(dy: Int) {
        post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                     wheel1: Int32(dy), wheel2: 0, wheel3: 0))
    }

    func key(_ combo: String, down: Bool) {
        guard let (code, flags) = KeyCombo.parse(combo) else { return }
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        if !flags.isEmpty { e?.flags = flags }
        log?("key \(combo) \(down ? "down" : "up")")
        post(e)
    }

    func media(_ name: String, down: Bool) {
        guard let code = MediaKey.codes[name] else { return }
        let state = down ? 0xA : 0xB
        let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                   timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                   data1: (code << 16) | (state << 8), data2: -1)
        log?("media \(name) \(down ? "down" : "up")")
        post(e?.cgEvent)
    }

    func shell(_ command: String) {
        log?("shell \(command)")
        guard postEvents else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        try? p.run()
    }

    func sound(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    func releaseAll() {
        for b in held { mouseButton(b, down: false) }
    }
}
