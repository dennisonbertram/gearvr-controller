// GearVR Remote: a menu-bar app that turns a Samsung Gear VR Controller into
// a gyro air-mouse, trackpad and media remote.
//
//   --verbose   log connection state and packet stats to stderr
//   --dry-run   connect and decode, but log actions instead of posting events
import AppKit
import SwiftUI

@main
struct GearVRRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(delegate.model)
        } label: {
            MenuBarLabel().environmentObject(delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(delegate.model)
        }
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: ControllerGlyph.image(model.glyphStyle))
            .accessibilityLabel("GearVR Remote: \(model.statusText)")
            .onAppear { model.openSettingsAction = { openSettings() } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var dock: DockPresence?

    func applicationDidFinishLaunching(_ notification: Notification) {
        warnIfNotInstalled()
        model.start()
        dock = DockPresence(model: model)
        if let dir = Snapshot.directory { Snapshot.run(model: model, into: dir) }
    }

    /// Opened straight from the disk image, macOS runs a temporary copy (App Translocation), so
    /// launch at login would point at something that disappears when the image is ejected.
    private func warnIfNotInstalled() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/"),
              !model.dryRun, Snapshot.directory == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Move GearVR Remote to Applications"
        alert.informativeText = "It's running from the disk image. Drag it into your Applications folder and open it from there, so it can start when you log in and keeps working after the disk image is ejected."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Run Anyway")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    /// Launching the app again (Finder, Spotlight, Launchpad) while it runs opens its window,
    /// so it never looks like nothing happened.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.presentSettings(.welcome)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
