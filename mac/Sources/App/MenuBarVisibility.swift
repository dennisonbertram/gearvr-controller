import AppKit

/// On Macs with a notch, a full menu bar can leave our status item in the gap behind it,
/// where it simply can't be seen. Detect that so the app can say so instead of looking broken.
enum MenuBarVisibility {
    static var statusItemFrame: CGRect? {
        NSApp.windows.first { $0.className.contains("StatusBarWindow") && $0.isVisible }?.frame
    }

    /// True when the status item sits behind the notch or off the screen entirely.
    static func iconIsHidden() -> Bool {
        guard let frame = statusItemFrame, let screen = NSScreen.main else { return false }
        if frame.maxX < screen.frame.minX || frame.minX > screen.frame.maxX { return true }
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
        return frame.maxX > left.maxX && frame.minX < right.minX // inside the notch
    }
}
