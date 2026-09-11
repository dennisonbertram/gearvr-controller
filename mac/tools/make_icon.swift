// Renders the app icon (a top-down Gear VR Controller) into an .iconset folder.
// usage: make_icon <out.iconset>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon tile
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x151922))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2c3445), rgb(0x0e1117)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x4aa3ff, 0.35), rgb(0x4aa3ff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 600, y: 620), startRadius: 0,
                           endCenter: CGPoint(x: 600, y: 620), endRadius: 420, options: [])
    ctx.restoreGState()

    // controller, in millimetres, tilted like the product photos
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: -.pi / 5)
    let k: CGFloat = 6.6
    ctx.scaleBy(x: k, y: k)
    let headY: CGFloat = 34.9
    let body = CGMutablePath()
    body.addEllipse(in: CGRect(x: -19.1, y: headY - 19.1, width: 38.2, height: 38.2))
    body.addPath(CGPath(roundedRect: CGRect(x: -13.6, y: -54.1, width: 27.2, height: 54.1 + headY),
                        cornerWidth: 13.6, cornerHeight: 13.6, transform: nil))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 1.5, height: -3), blur: 6, color: rgb(0x000000, 0.55))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x3a4050))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let shade = CGGradient(colorsSpace: cs, colors: [rgb(0x4a5163), rgb(0x2a2f3a)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: -14, y: 50), end: CGPoint(x: 14, y: -50), options: [])
    ctx.restoreGState()

    // touchpad with accent ring
    ctx.setFillColor(rgb(0x1a1d24))
    ctx.fillEllipse(in: CGRect(x: -15, y: headY - 15, width: 30, height: 30))
    ctx.setStrokeColor(rgb(0x4aa3ff))
    ctx.setLineWidth(1.3)
    ctx.strokeEllipse(in: CGRect(x: -15, y: headY - 15, width: 30, height: 30))
    ctx.setFillColor(rgb(0x4aa3ff, 0.9))
    ctx.fillEllipse(in: CGRect(x: 3, y: headY + 3, width: 5, height: 5))

    // buttons, volume pill, LED
    ctx.setFillColor(rgb(0x262b35))
    for x: CGFloat in [-6, 6] { ctx.fillEllipse(in: CGRect(x: x - 4.3, y: 11 - 4.3, width: 8.6, height: 8.6)) }
    ctx.addPath(CGPath(roundedRect: CGRect(x: -3.8, y: -14.75, width: 6.4, height: 16.5),
                       cornerWidth: 3.2, cornerHeight: 3.2, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(rgb(0x4aa3ff))
    ctx.fillEllipse(in: CGRect(x: -0.9, y: -29.5, width: 1.8, height: 1.8))
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
