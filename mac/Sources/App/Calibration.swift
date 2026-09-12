// Manual gyro recalibration: put the controller down, sample its resting rate for ~2 s,
// and adopt that as the new zero. Useful when the pointer drifts on its own.
import AppKit
import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if case .collecting(let progress) = model.calibration {
                ProgressView(value: progress).frame(width: 240)
            }
            HStack {
                switch model.calibration {
                case .collecting:
                    Button("Cancel") { model.cancelCalibration() }
                case .finished(let ok, _, _):
                    Button(ok ? "Done" : "Close") { close() }
                        .keyboardShortcut(ok ? .defaultAction : .cancelAction)
                    Button("Calibrate again") { model.startCalibration() }
                case .idle:
                    Button("Cancel") { close() }
                    Button("Start") { model.startCalibration() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isStreaming)
                }
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 460)
    }

    private var symbol: String {
        switch model.calibration {
        case .idle: return "gyroscope"
        case .collecting: return "hourglass"
        case .finished(let ok, _, _): return ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch model.calibration {
        case .finished(let ok, _, _): return ok ? .green : .orange
        default: return .accentColor
        }
    }

    private var title: String {
        switch model.calibration {
        case .idle: return "Recalibrate the gyro"
        case .collecting: return "Hold still…"
        case .finished(let ok, _, _): return ok ? "Calibrated" : "It moved"
        }
    }

    private var detail: String {
        switch model.calibration {
        case .idle:
            return model.isStreaming
                ? "Put the controller down on a steady surface, then press Start and leave it alone for two seconds.\n\nDo this if the pointer creeps on its own while your hand is still."
                : "Connect the controller first — press Home to wake it."
        case .collecting:
            return "Measuring how the controller reads while it isn't moving."
        case .finished(let ok, let drift, let wobble):
            return ok
                ? String(format: "The gyro was reading %.1f°/s while sitting still; that drift is now cancelled out.", drift)
                : String(format: "The controller wobbled by %.1f°/s while measuring, so the old calibration was kept. Rest it on a table and try again.", wobble)
        }
    }
}

/// Owns the recalibration window (plain AppKit, so it never opens by itself at launch).
final class CalibrationWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onClose: (() -> Void)?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Recalibrate"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: CalibrationView(model: model) { [weak self] in self?.window?.close() })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
