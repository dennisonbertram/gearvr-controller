import AppKit
import Combine

/// The app lives in the menu bar, so it normally has no Dock icon. It shows one while a
/// window is open (so it behaves like a normal app while you're using it), and can be told
/// to keep one permanently.
final class DockPresence {
    private let model: AppModel
    private var observers: [Any] = []
    private var cancellable: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.update() }
            })
        }
        cancellable = model.$config.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        update()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized }
    }

    private func update() {
        let wanted: NSApplication.ActivationPolicy = (model.config.alwaysShowInDock || hasVisibleWindow)
            ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        model.log("dock icon \(wanted == .regular ? "shown" : "hidden")")
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}
