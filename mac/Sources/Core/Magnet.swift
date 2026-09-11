// "Magnetic" pointer assist for clickable targets, in two strengths:
//  * assist (default, subtle): the pointer never moves on its own. Over a target your
//    motion is scaled down (more so when nearly still, which damps tremor), and while
//    you move toward a target your direction bends slightly toward its centre.
//  * snap (strong): when the pointer slows near a target it glides onto the centre and
//    holds; a push toward a neighbour hops to it, a push into empty space pops it free.
//
// Pure logic in global display coordinates (top-left origin, like Quartz and AX).
import CoreGraphics
import Foundation

public struct MagnetSettings: Equatable {
    public var snap = true // glide onto targets and hold (strong mode)
    public var radius = 40.0 // px from a target's edge: reach for steering / snapping
    public var breakaway = 45.0 // snap: px of hand motion needed to pull free
    public var stickiness = 0.25 // snap: fraction of hand motion the pointer shows while held
    public var slowSpeed = 350.0 // snap: engages only below this pointer speed (px/s)
    public var friction = 1.0 // assist: motion scale over a target
    public var stillFriction = 1.0 // assist: motion scale over a target when nearly still (tremor)
    public var steer = 0.0 // assist: how much motion toward a target bends toward its centre

    static let snapThreshold = 0.55

    public init() {}

    /// One knob from subtle (0) to strong (1). Up to `snapThreshold` it only assists your
    /// own motion; above it the pointer snaps onto targets.
    public init(strength s: Double) {
        let k = min(max(s, 0), 1)
        let assist = min(k / Self.snapThreshold, 1)
        snap = k > Self.snapThreshold
        radius = 12 + 30 * k
        friction = 1 - 0.55 * assist
        stillFriction = friction * 0.6
        steer = 0.6 * assist
        let t = max(0, (k - Self.snapThreshold) / (1 - Self.snapThreshold))
        breakaway = 14 + 40 * t
        stickiness = 0.5 - 0.3 * t
    }

    public var describes: String { snap ? "snaps onto buttons" : "helps you stop on buttons" }
}

public final class Magnet {
    public var settings: MagnetSettings
    public private(set) var locked: CGRect?

    /// Current clickable targets near the pointer (from the accessibility scanner).
    public var targets: [CGRect] = [] {
        didSet {
            // UI frames jitter between scans (hover effects, animations): follow the snapped
            // target to its new frame; drop the lock only if it's really gone.
            if let l = locked {
                if let moved = targets.first(where: { Self.similar($0, l) }) {
                    locked = moved
                } else {
                    locked = nil
                    escape = .zero
                }
            }
            if let r = released { released = targets.first(where: { Self.similar($0, r) }) ?? r }
        }
    }

    private var released: CGRect? // just broke free from this one: ignore it until the pointer leaves
    private var escape = CGVector.zero // hand motion accumulated while snapped
    private var speed = 0.0 // smoothed pointer speed, px/s
    private var lastMove: TimeInterval = 0
    private var lastTick: TimeInterval?

    static let glide = 0.3 // fraction of the remaining distance covered per tick
    static let fastFactor = 2.5 // moving this many times slowSpeed releases immediately
    static let springTime = 0.5 // s; accumulated hand motion fades with this time constant, so
                                // tremor and slow drift stay snapped while a steady push escapes

    public init(settings: MagnetSettings = MagnetSettings()) {
        self.settings = settings
    }

    public var speedPxPerSec: Double { speed }

    public func release() {
        if let l = locked { released = l }
        locked = nil
        escape = .zero
    }

    public func reset() {
        locked = nil
        released = nil
        escape = .zero
        speed = 0
    }

    /// The hand moved the pointer by `d` from `p`. Returns where the pointer should go.
    public func userMove(from p: CGPoint, by d: CGVector, at t: TimeInterval) -> CGPoint {
        let dt = min(max(t - lastMove, 0.002), 0.05)
        lastMove = t
        speed = 0.85 * speed + 0.15 * (hypot(d.dx, d.dy) / dt)

        guard let l = locked else {
            let m = assisted(d, at: p)
            let q = CGPoint(x: p.x + m.dx, y: p.y + m.dy)
            if let r = released, !r.insetBy(dx: -settings.radius, dy: -settings.radius).contains(q) { released = nil }
            return q
        }
        escape.dx += d.dx
        escape.dy += d.dy
        // A push toward a neighbouring target hops straight to it (traffic lights, toolbars,
        // menus), so stepping between close targets doesn't need a full breakaway.
        if let next = neighbour(of: l, toward: escape) {
            locked = next
            escape = .zero
            return CGPoint(x: p.x + d.dx * settings.stickiness, y: p.y + d.dy * settings.stickiness)
        }
        if hypot(escape.dx, escape.dy) > breakaway(for: l) || speed > settings.slowSpeed * Self.fastFactor {
            let out = CGPoint(x: l.midX + escape.dx, y: l.midY + escape.dy)
            release()
            return out
        }
        return CGPoint(x: p.x + d.dx * settings.stickiness, y: p.y + d.dy * settings.stickiness)
    }

    /// Called at a steady rate (~120 Hz). Returns a new pointer position, or nil to leave it.
    public func tick(cursor p: CGPoint, at t: TimeInterval) -> CGPoint? {
        let dt = min(max(t - (lastTick ?? t), 0), 0.1)
        lastTick = t
        if t - lastMove > 0.06 { speed *= 0.8 } // no hand motion: the pointer is at rest

        if let l = locked {
            // pointer moved away by other means (real mouse, trackpad): let go
            if !l.insetBy(dx: -settings.radius * 2, dy: -settings.radius * 2).contains(p) {
                release()
                return nil
            }
            let fade = exp(-dt / Self.springTime) // spring back toward the centre
            escape.dx *= fade
            escape.dy *= fade
            let goal = CGPoint(x: l.midX + escape.dx * settings.stickiness, y: l.midY + escape.dy * settings.stickiness)
            return step(p, toward: goal)
        }

        guard settings.snap, speed < settings.slowSpeed, let target = nearest(to: p) else { return nil }
        locked = target
        escape = .zero
        return step(p, toward: CGPoint(x: target.midX, y: target.midY))
    }

    /// Assist mode: shape the hand's own motion near a target. Never adds motion of its own.
    func assisted(_ d: CGVector, at p: CGPoint) -> CGVector {
        let len = hypot(d.dx, d.dy)
        guard len > 0, let t = nearest(to: p) else { return d }
        var m = d
        // steer: bend the direction toward the centre while approaching, keeping your speed
        let cx = Double(t.midX - p.x), cy = Double(t.midY - p.y)
        let cd = hypot(cx, cy)
        if settings.steer > 0, cd > 1, Double(d.dx) * cx + Double(d.dy) * cy > 0 {
            let edge = hypot(max(t.minX - p.x, 0, p.x - t.maxX), max(t.minY - p.y, 0, p.y - t.maxY))
            let w = settings.steer * max(0, 1 - Double(edge) / settings.radius)
            let ux = Double(d.dx) / len + w * cx / cd, uy = Double(d.dy) / len + w * cy / cd
            let un = hypot(ux, uy)
            if un > 0 { m = CGVector(dx: ux / un * len, dy: uy / un * len) }
        }
        // friction: slower over the target, more so when nearly still (damps tremor)
        if t.insetBy(dx: -3, dy: -3).contains(p) {
            let f = speed < 80 ? settings.stillFriction : settings.friction
            m = CGVector(dx: m.dx * f, dy: m.dy * f)
        }
        return m
    }

    /// Small targets hold less firmly: leaving a 14 px button shouldn't take a 45 px push.
    func breakaway(for r: CGRect) -> Double {
        min(settings.breakaway, max(12, 1.25 * Double(max(r.width, r.height))))
    }

    /// The closest target roughly in the direction of the push `e`, once the push covers
    /// enough of the gap between the two centres.
    func neighbour(of l: CGRect, toward e: CGVector) -> CGRect? {
        let push = hypot(e.dx, e.dy)
        guard push > 4 else { return nil }
        var best: (rect: CGRect, gap: Double)?
        for t in targets where !Self.similar(t, l) {
            let vx = Double(t.midX - l.midX), vy = Double(t.midY - l.midY)
            let gap = hypot(vx, vy)
            guard gap > 1, gap < 140 else { continue }
            let along = (Double(e.dx) * vx + Double(e.dy) * vy) / gap // push component toward t
            guard along / push > 0.8, along >= min(max(0.4 * gap, 6), breakaway(for: l)) else { continue }
            if best == nil || gap < best!.gap { best = (t, gap) }
        }
        return best?.rect
    }

    func nearest(to p: CGPoint) -> CGRect? {
        var best: (rect: CGRect, dist: Double, area: Double)?
        for r in targets {
            if let rel = released, Self.similar(r, rel) { continue }
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            let dist = Double(hypot(dx, dy))
            guard dist <= settings.radius else { continue }
            let area = Double(r.width * r.height)
            // nearest edge wins; among targets under the pointer, the smallest (innermost)
            if best == nil || dist < best!.dist - 0.5 || (abs(dist - best!.dist) <= 0.5 && area < best!.area) {
                best = (r, dist, area)
            }
        }
        return best?.rect
    }

    private func step(_ p: CGPoint, toward goal: CGPoint) -> CGPoint? {
        let dx = goal.x - p.x, dy = goal.y - p.y
        if hypot(dx, dy) < 0.35 { return nil }
        let k = hypot(dx, dy) < 1.5 ? 1.0 : Self.glide
        return CGPoint(x: p.x + dx * k, y: p.y + dy * k)
    }

    /// The same element after a small move or resize.
    static func similar(_ a: CGRect, _ b: CGRect) -> Bool {
        let tolerance = max(6, 0.3 * min(b.width, b.height))
        return hypot(a.midX - b.midX, a.midY - b.midY) < tolerance
            && abs(a.width - b.width) < max(6, 0.25 * b.width) && abs(a.height - b.height) < max(6, 0.25 * b.height)
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
