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

    var body: some View {
        Image(nsImage: ControllerGlyph.image(model.glyphStyle))
            .accessibilityLabel("GearVR Remote: \(model.statusText)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        if let dir = Snapshot.directory { Snapshot.run(model: model, into: dir) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
