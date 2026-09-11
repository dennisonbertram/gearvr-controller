// "Magnetic" pointer assist: when the pointer slows down near a clickable target it
// glides onto the target's centre and holds there, absorbing hand tremor. Pushing
// past `breakaway` pixels of hand motion (or moving fast) pops it free.
//
// Pure logic in global display coordinates (top-left origin, like Quartz and AX).
import CoreGraphics
import Foundation

public struct MagnetSettings: Equatable {
    public var radius = 40.0 // px from a target's edge at which snapping starts
    public var breakaway = 45.0 // px of hand motion needed to pull free
    public var stickiness = 0.25 // fraction of hand motion the pointer shows while snapped
    public var slowSpeed = 350.0 // px/s; snapping only engages below this pointer speed

    public init() {}
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
            let q = CGPoint(x: p.x + d.dx, y: p.y + d.dy)
            if let r = released, !r.insetBy(dx: -settings.radius, dy: -settings.radius).contains(q) { released = nil }
            return q
        }
        escape.dx += d.dx
        escape.dy += d.dy
        if hypot(escape.dx, escape.dy) > settings.breakaway || speed > settings.slowSpeed * Self.fastFactor {
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

        guard speed < settings.slowSpeed, let target = nearest(to: p) else { return nil }
        locked = target
        escape = .zero
        return step(p, toward: CGPoint(x: target.midX, y: target.midY))
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
