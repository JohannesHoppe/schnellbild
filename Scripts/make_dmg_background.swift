// Renders the background of the DMG window: an arrow from the app to the
// Applications folder and a one-line hint below. The positions match
// Installer/dmg-settings.py.
// Usage: swift Scripts/make_dmg_background.swift
// Result: Resources/dmg-background.png and Resources/dmg-background@2x.png (Retina)
import AppKit
import CoreGraphics

let W: CGFloat = 600, H: CGFloat = 380
let appX: CGFloat = 160, targetX: CGFloat = 440, iconY: CGFloat = 170   // from the top
let hint = "Drag Schnellbild to Applications to install"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

func render(scale s: CGFloat, to path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: Int(W * s), height: Int(H * s), bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("no context") }
    ctx.scaleBy(x: s, y: s)
    // Flip, so y counts from the top like the icon positions in Finder
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)

    // Soft gradient from white to a light blue
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(252, 253, 255), rgb(236, 242, 255)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: H), options: [])

    // Arrow between the icons, in the blue → purple of the app icon
    let x0 = appX + 78, x1 = targetX - 78, y = iconY, head: CGFloat = 22, half: CGFloat = 14
    // One outline (round tail, shaft, head), so no seam where the parts meet
    let arrow = CGMutablePath()
    arrow.addArc(center: CGPoint(x: x0, y: y), radius: 3, startAngle: .pi / 2, endAngle: 3 * .pi / 2,
                 clockwise: false)
    arrow.addLine(to: CGPoint(x: x1 - head, y: y - 3))
    arrow.addLine(to: CGPoint(x: x1 - head, y: y - half))
    arrow.addLine(to: CGPoint(x: x1, y: y))
    arrow.addLine(to: CGPoint(x: x1 - head, y: y + half))
    arrow.addLine(to: CGPoint(x: x1 - head, y: y + 3))
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    let fill = CGGradient(colorsSpace: cs, colors: [rgb(46, 139, 255), rgb(138, 79, 255)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
    ctx.restoreGState()

    // Hint, centered below the icon labels
    let text = NSAttributedString(string: hint, attributes: [
        .font: NSFont.systemFont(ofSize: 17),
        .foregroundColor: NSColor(red: 60/255, green: 64/255, blue: 72/255, alpha: 1),
    ])
    let line = CTLineCreateWithAttributedString(text)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // undo the flip for glyphs
    ctx.textPosition = CGPoint(x: (W - CGFloat(width)) / 2, y: 316)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: W, height: H)   // 72 dpi at 1x, 144 dpi at 2x
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

render(scale: 1, to: "Resources/dmg-background.png")
render(scale: 2, to: "Resources/dmg-background@2x.png")
