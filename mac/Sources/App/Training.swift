// Pointer training: 15 targets that shrink from large to traffic-light size. While you
// aim and click with the controller it records the pointer path, how steady the pointer
// is just before each click, and your raw hand tremor from the gyro, then suggests
// pointer speed, smoothing and magnet strength.
import AppKit
import SwiftUI

final class TrainingSession: ObservableObject {
    enum Phase { case intro, running, done }

    struct Trial {
        let size: CGFloat
        let center: CGPoint
        let start: TimeInterval
        var startPointer: CGPoint?
        var path = 0.0
        var lastPointer: CGPoint?
        var pointer: [(t: TimeInterval, p: CGPoint)] = []
        var misses = 0
        var end: TimeInterval?
    }

    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let current: String
        let suggested: String
        let reason: String
        let changed: Bool
    }

    struct Summary {
        var hitRate: Double // first-click hits / targets
        var smallHitRate: Double // same, for targets 24 px and smaller
        var medianTime: Double
        var pathRatio: Double // pointer travel / straight-line distance (1 = perfect)
        var jitterPX: Double // pointer wobble just before clicking
        var tremorDPS: Double // hand tremor from the gyro just before clicking
        var suggestions: [Suggestion]
        var config: RemoteConfig // current settings with the suggestions applied
    }

    static let sizes: [CGFloat] = [72, 72, 60, 52, 48, 40, 36, 32, 28, 24, 24, 20, 18, 16, 16]

    @Published var phase = Phase.intro
    @Published var index = 0
    @Published var target: Trial?
    @Published var missMarker: CGPoint?
    @Published var summary: Summary?

    var canvas = CGSize(width: 1000, height: 640)
    private var trials: [Trial] = []
    private var tremor: [(t: TimeInterval, dps: Double)] = []
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func begin() {
        trials = []
        tremor = []
        index = 0
        summary = nil
        phase = .running
        placeTarget(after: CGPoint(x: canvas.width / 2, y: canvas.height / 2))
    }

    private func placeTarget(after previous: CGPoint) {
        let size = Self.sizes[index]
        let margin = 70.0
        var c = previous
        for _ in 0..<50 {
            c = CGPoint(x: .random(in: margin...(canvas.width - margin)), y: .random(in: (margin + 30)...(canvas.height - margin)))
            if hypot(c.x - previous.x, c.y - previous.y) > 240 { break }
        }
        target = Trial(size: size, center: c, start: now)
    }

    /// Pointer position over the canvas (view coordinates).
    func hover(_ p: CGPoint) {
        guard phase == .running, var t = target else { return }
        if t.startPointer == nil { t.startPointer = p }
        if let last = t.lastPointer { t.path += hypot(p.x - last.x, p.y - last.y) }
        t.lastPointer = p
        t.pointer.append((now, p))
        target = t
    }

    /// Raw hand motion from the controller (deg/s, gyro bias removed).
    func recordTremor(_ dps: Double) {
        guard phase == .running else { return }
        tremor.append((now, dps))
    }

    func hit() {
        guard phase == .running, var t = target else { return }
        t.end = now
        trials.append(t)
        missMarker = nil
        index += 1
        if index < Self.sizes.count {
            placeTarget(after: t.center)
        } else {
            target = nil
            phase = .done
        }
    }

    func miss(at p: CGPoint) {
        guard phase == .running, target != nil else { return }
        target!.misses += 1
        missMarker = p
    }

    func summarize(current cfg: RemoteConfig) -> Summary {
        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        func rms(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : (xs.map { $0 * $0 }.reduce(0, +) / Double(xs.count)).squareRoot() }

        let firstHits = trials.map { $0.misses == 0 ? 1.0 : 0.0 }
        let small = trials.filter { $0.size <= 24 }
        var ratios: [Double] = [], jitters: [Double] = [], tremors: [Double] = [], times: [Double] = []
        for t in trials {
            guard let end = t.end else { continue }
            times.append(end - t.start)
            if let s = t.startPointer {
                let straight = max(hypot(t.center.x - s.x, t.center.y - s.y) - t.size / 2, 40)
                ratios.append(t.path / straight)
            }
            // wobble while on the target just before the click (not the approach)
            let reach = t.size / 2 + 12
            let dwell = t.pointer.filter { end - $0.t < 0.35 && hypot($0.p.x - t.center.x, $0.p.y - t.center.y) <= reach }
                .map(\.p)
            if dwell.count > 2 {
                let mx = dwell.map(\.x).reduce(0, +) / Double(dwell.count)
                let my = dwell.map(\.y).reduce(0, +) / Double(dwell.count)
                jitters.append(rms(dwell.map { hypot($0.x - mx, $0.y - my) }))
            }
            let hand = tremor.filter { $0.t <= end && end - $0.t < 0.25 }.map(\.dps)
            if !hand.isEmpty { tremors.append(rms(hand)) }
        }

        var s = Summary(hitRate: firstHits.reduce(0, +) / Double(max(trials.count, 1)),
                        smallHitRate: small.isEmpty ? 1 : Double(small.filter { $0.misses == 0 }.count) / Double(small.count),
                        medianTime: median(times), pathRatio: median(ratios), jitterPX: median(jitters),
                        tremorDPS: median(tremors), suggestions: [], config: cfg)

        // pointer speed: overshooting and zig-zagging means too fast; long straight trips mean too slow
        var speed = cfg.sensitivity
        var speedReason = "Your paths to the targets were direct, so the speed suits you."
        if s.pathRatio > 1.6 {
            speed = (cfg.sensitivity * 0.85).rounded()
            speedReason = String(format: "The pointer travelled %.1f× the straight distance, so you tended to overshoot. A little slower should help.", s.pathRatio)
        } else if s.pathRatio < 1.2 && s.medianTime > 1.4 {
            speed = (cfg.sensitivity * 1.15).rounded()
            speedReason = String(format: "Paths were direct but took %.1f s on average; a little faster saves arm movement.", s.medianTime)
        }
        speed = min(max(speed, 8), 50)

        // smoothing follows your measured hand tremor while aiming
        var smooth: Double
        switch s.tremorDPS {
        case ..<1.0: smooth = 0.15
        case ..<2.0: smooth = 0.3
        case ..<3.5: smooth = 0.45
        case ..<6.0: smooth = 0.6
        default: smooth = 0.75
        }
        if s.jitterPX > 5 { smooth = min(smooth + 0.1, 0.9) }
        let smoothReason = String(format: "While aiming your hand moved %.1f°/s on average and the pointer wobbled about %.0f px.",
                                  s.tremorDPS, s.jitterPX)

        // magnet: more help if small targets were hard to hit first time
        var magnet = cfg.magnetStrength
        switch s.smallHitRate {
        case ..<0.4: magnet = max(magnet, 0.7)
        case ..<0.6: magnet = max(magnet, 0.5)
        case ..<0.85: magnet = max(magnet, 0.4)
        default: break
        }
        let magnetReason = String(format: "You hit %.0f%% of the small targets on the first click.", s.smallHitRate * 100)

        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
        s.suggestions = [
            Suggestion(id: "speed", title: "Pointer speed", current: String(format: "%.0f", cfg.sensitivity),
                       suggested: String(format: "%.0f", speed), reason: speedReason, changed: speed != cfg.sensitivity),
            Suggestion(id: "smooth", title: "Smoothing", current: pct(cfg.smoothing), suggested: pct(smooth),
                       reason: smoothReason, changed: abs(smooth - cfg.smoothing) > 0.01),
            Suggestion(id: "magnet", title: "Magnet strength", current: pct(cfg.magnetStrength), suggested: pct(magnet),
                       reason: magnetReason + (magnet > MagnetSettings.snapThreshold ? " Above the middle it snaps onto buttons." : ""),
                       changed: abs(magnet - cfg.magnetStrength) > 0.01 || (!cfg.magnetEnabled && magnet > 0)),
        ]
        s.config.sensitivity = speed
        s.config.smoothing = smooth
        s.config.magnetStrength = magnet
        if magnet > cfg.magnetStrength { s.config.magnetEnabled = true }
        return s
    }
}

struct TrainingView: View {
    @ObservedObject var session: TrainingSession
    @ObservedObject var model: AppModel
    var close: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                switch session.phase {
                case .intro: intro
                case .running: running
                case .done: results
                }
            }
            .onAppear { session.canvas = geo.size }
            .onChange(of: geo.size) { _, size in session.canvas = size }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "scope").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Pointer training").font(.largeTitle.weight(.semibold))
            Text("Point with the controller and click each target with the trigger. There are \(TrainingSession.sizes.count) targets, getting smaller, down to the size of a window's close button. It takes about a minute.\n\nGearVR Remote measures how steady your hand is and how directly you reach each target, then suggests pointer speed, smoothing and magnet strength for you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if !model.isStreaming {
                Label("Connect the controller first (press Home).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Start") { session.begin() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isStreaming)
        }
        .padding(40)
    }

    private var running: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { session.miss(at: $0) }
            if let t = session.target {
                Button(action: { session.hit() }) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.85))
                        Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: max(1.5, t.size / 24))
                        Circle().fill(Color.white).frame(width: max(3, t.size / 8), height: max(3, t.size / 8))
                    }
                    .frame(width: t.size, height: t.size)
                }
                .buttonStyle(.plain)
                .position(t.center)
                .accessibilityLabel("Training target")
            }
            if let m = session.missMarker {
                Circle().strokeBorder(Color.red.opacity(0.8), lineWidth: 2).frame(width: 18, height: 18).position(m)
                    .allowsHitTesting(false)
            }
            HStack {
                Text("Target \(min(session.index + 1, TrainingSession.sizes.count)) of \(TrainingSession.sizes.count)")
                    .font(.headline)
                ProgressView(value: Double(session.index), total: Double(TrainingSession.sizes.count))
                    .frame(width: 160)
                Spacer()
                Button("Stop") { session.phase = .intro }
            }
            .padding(14)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase { session.hover(p) }
        }
    }

    private var results: some View {
        let s = session.summary ?? session.summarize(current: model.config)
        return VStack(alignment: .leading, spacing: 18) {
            Text("Your results").font(.largeTitle.weight(.semibold))
            HStack(spacing: 14) {
                stat("First-click hits", String(format: "%.0f%%", s.hitRate * 100))
                stat("Small targets", String(format: "%.0f%%", s.smallHitRate * 100))
                stat("Time per target", String(format: "%.1f s", s.medianTime))
                stat("Path directness", String(format: "%.1f×", s.pathRatio))
                stat("Hand tremor", String(format: "%.1f°/s", s.tremorDPS))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Suggested settings").font(.title3.weight(.semibold))
                ForEach(s.suggestions) { g in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: g.changed ? "arrow.right.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(g.changed ? Color.accentColor : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.changed ? "\(g.title): \(g.current) → \(g.suggested)" : "\(g.title): \(g.current) (keep)")
                                .font(.headline)
                            Text(g.reason).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button("Apply suggestions") {
                    model.config = s.config
                    close()
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!s.suggestions.contains(where: \.changed))
                Button("Train again") { session.begin() }
                Spacer()
                Button("Close") { close() }
            }
        }
        .padding(40)
        .frame(maxWidth: 760)
        .onAppear { if session.summary == nil { session.summary = s } }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

/// Owns the training window (plain AppKit, so it never opens by itself at launch).
final class TrainingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let session = TrainingSession()

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "GearVR Remote — Pointer Training"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: TrainingView(session: session, model: model) { [weak self] in
                self?.window?.close()
            })
            w.center()
            window = w
        }
        session.phase = .intro
        session.summary = nil
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isRecording: Bool { window?.isVisible == true && session.phase == .running }

    func windowWillClose(_ notification: Notification) {
        session.phase = .intro
    }
}
