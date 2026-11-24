// Renders the Schnellbild app icon at 1024×1024 as a PNG.
// Usage: swift Scripts/make_icon.swift [output.png]
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
let S = CGFloat(size)

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: Background squircle + gradient
let corner = S * 0.2237
let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [rgb(46, 139, 255), rgb(138, 79, 255)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
// soft top highlight
let hl = CGGradient(colorsSpace: cs,
                    colors: [rgb(255, 255, 255, 0.22), rgb(255, 255, 255, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S * 0.45), options: [])
ctx.restoreGState()

// MARK: Photo card
let inset = S * 0.215
let card = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let cardRadius = card.width * 0.13
let cardPath = CGPath(roundedRect: card, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.04, color: rgb(20, 20, 60, 0.35))
ctx.addPath(cardPath)
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

// content clipped to the card
ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()

// sun
let sunR = card.width * 0.105
let sun = CGPoint(x: card.minX + card.width * 0.30, y: card.maxY - card.height * 0.29)
ctx.setFillColor(rgb(255, 196, 61))
ctx.addEllipse(in: CGRect(x: sun.x - sunR, y: sun.y - sunR, width: 2*sunR, height: 2*sunR))
ctx.fillPath()

// back mountain (purple)
ctx.setFillColor(rgb(150, 110, 246))
ctx.beginPath()
ctx.move(to: CGPoint(x: card.minX + card.width * 0.40, y: card.minY))
ctx.addLine(to: CGPoint(x: card.minX + card.width * 0.66, y: card.minY + card.height * 0.42))
ctx.addLine(to: CGPoint(x: card.maxX + 2,             y: card.minY))
ctx.closePath()
ctx.fillPath()

// front mountain (blue)
ctx.setFillColor(rgb(46, 139, 255))
ctx.beginPath()
ctx.move(to: CGPoint(x: card.minX - 2,                y: card.minY))
ctx.addLine(to: CGPoint(x: card.minX + card.width * 0.34, y: card.minY + card.height * 0.50))
ctx.addLine(to: CGPoint(x: card.minX + card.width * 0.70, y: card.minY))
ctx.closePath()
ctx.fillPath()

ctx.restoreGState()

// MARK: Lightning bolt (bottom-right, "fast") — straddles the card corner
let bw = S * 0.235
let bh = bw * 1.22
let ar = bh / bw
// normalized bolt polygon (y up)
let boltPts: [CGPoint] = [
    CGPoint(x: 0.58, y: 1.00),
    CGPoint(x: 0.10, y: 0.46),
    CGPoint(x: 0.45, y: 0.46),
    CGPoint(x: 0.30, y: 0.00),
    CGPoint(x: 0.92, y: 0.62),
    CGPoint(x: 0.55, y: 0.62),
]
func boltPath(originX: CGFloat, originY: CGFloat, w: CGFloat, h: CGFloat) -> CGMutablePath {
    let p = CGMutablePath()
    for (i, pt) in boltPts.enumerated() {
        let q = CGPoint(x: originX + pt.x * w, y: originY + pt.y * h)
        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
    }
    p.closeSubpath()
    return p
}
let originX = card.maxX - bw * 0.86
let originY = card.minY - bh * 0.10
// crisp white outline (a slightly larger bolt) + subtle drop shadow
let outline = bw * 0.10
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006), blur: S * 0.016, color: rgb(20, 20, 60, 0.30))
ctx.addPath(boltPath(originX: originX - outline, originY: originY - outline * ar,
                     w: bw + 2*outline, h: bh + 2*outline * ar))
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()
// golden bolt
ctx.addPath(boltPath(originX: originX, originY: originY, w: bw, h: bh))
ctx.setFillColor(rgb(255, 186, 33))
ctx.fillPath()

// MARK: write PNG
guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
