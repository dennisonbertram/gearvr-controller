import AppKit

/// Menu-bar template glyph: the Gear VR Controller's silhouette (round touchpad
/// head, slim handle), tilted like it's being held.
enum ControllerGlyph {
    enum Style { case active, paused, disconnected }

    static func image(_ style: Style, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -.pi / 4.5)
            let s = size / 18
            ctx.scaleBy(x: s, y: s)

            let headR: CGFloat = 4.4, headY: CGFloat = 4.1, halfW: CGFloat = 2.9
            let head = CGPath(ellipseIn: CGRect(x: -headR, y: headY - headR, width: headR * 2, height: headR * 2),
                              transform: nil)
            let handle = CGPath(roundedRect: CGRect(x: -halfW, y: -8.6, width: halfW * 2, height: 8.6 + headY),
                                cornerWidth: halfW, cornerHeight: halfW, transform: nil)
            let body = head.union(handle)
            let pad = CGRect(x: -2.9, y: headY - 2.9, width: 5.8, height: 5.8)

            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch style {
            case .active, .paused:
                ctx.setAlpha(style == .paused ? 0.45 : 1)
                ctx.addPath(body)
                ctx.fillPath()
                // knock out the touchpad ring and the two face buttons
                ctx.setBlendMode(.clear)
                ctx.setLineWidth(1.0)
                ctx.strokeEllipse(in: pad)
                for x: CGFloat in [-1.3, 1.3] {
                    ctx.fillEllipse(in: CGRect(x: x - 0.75, y: -1.9, width: 1.5, height: 1.5))
                }
            case .disconnected:
                ctx.setLineWidth(1.2)
                ctx.addPath(body)
                ctx.strokePath()
                ctx.setLineWidth(1.0)
                ctx.strokeEllipse(in: pad)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
