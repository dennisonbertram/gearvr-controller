// Debug aid: `GearVRRemote --dry-run --snapshot <dir>` renders the menu and each
// settings tab to PNG (no Screen Recording permission needed), then quits.
import AppKit
import SwiftUI

enum Snapshot {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(model: AppModel, into dir: String, after delay: TimeInterval = 5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            model.liveVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                render(MenuView(), model: model, to: "\(dir)/menu.png")
                render(HStack(spacing: 16) {
                    ForEach([ControllerGlyph.Style.active, .paused, .disconnected], id: \.self) {
                        Image(nsImage: ControllerGlyph.image($0, size: 36)).renderingMode(.template).foregroundStyle(.primary)
                    }
                }.padding(10), model: model, to: "\(dir)/glyphs.png")
                render(WelcomeTab().frame(width: 540), model: model, to: "\(dir)/settings-welcome.png")
                render(Form { ButtonsTab() }.formStyle(.grouped).frame(width: 520), model: model, to: "\(dir)/settings-buttons.png")
                render(PointerTab().frame(width: 520), model: model, to: "\(dir)/settings-pointer.png")
                render(TouchpadTab().frame(width: 520), model: model, to: "\(dir)/settings-touchpad.png")
                render(ClutchTab().frame(width: 520), model: model, to: "\(dir)/settings-clutch.png")
                render(GeneralTab().frame(width: 520), model: model, to: "\(dir)/settings-general.png")
                let session = TrainingSession()
                session.canvas = CGSize(width: 1000, height: 640)
                let view = { TrainingView(session: session, model: model, close: {}).frame(width: 1000, height: 640) }
                render(view(), model: model, to: "\(dir)/training-intro.png")
                session.begin()
                session.hover(CGPoint(x: 500, y: 320))
                session.miss(at: CGPoint(x: 520, y: 300))
                render(view(), model: model, to: "\(dir)/training-running.png")
                for i in 0..<TrainingSession.sizes.count {
                    guard let t = session.target else { break }
                    session.hover(CGPoint(x: t.center.x - 200, y: t.center.y))
                    session.hover(CGPoint(x: t.center.x + 30, y: t.center.y + 10)) // overshoot
                    session.hover(t.center)
                    session.recordTremor(2.4)
                    if i % 4 == 3 { session.miss(at: .zero) }
                    session.hit()
                }
                render(view(), model: model, to: "\(dir)/training-results.png")
                NSApp.terminate(nil)
            }
        }
    }

    private static func render<V: View>(_ view: V, model: AppModel, to path: String) {
        let host = NSHostingView(rootView: view.environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
