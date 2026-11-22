import Foundation
import CoreGraphics

/// The one picture every format's sample is made from (`FormatFixtures`
/// for the pictures, `Scripts/make_video_fixtures.sh visual` for the videos,
/// which compiles this file with `Scripts/reference_frames.swift`), and
/// what the decoded samples are compared with (`FormatVisualTests`).
/// 384 × 240, drawn from rectangles, one circle and one triangle, so every
/// pixel is the same on every Mac (no fonts):
/// - colour bars at the top (white, yellow, cyan, green, magenta, red, blue,
///   black): channels swapped or a wrong palette show there;
/// - a grey ramp (0 … 255 by column) and a red-to-blue ramp: gamma and
///   levels;
/// - an "F" (white, top left of the middle), an orange circle, a green
///   triangle pointing right: a flip or a turn shows by the F;
/// - thin strokes (1 px black lines, 2 px white lines): sharpness and
///   scaling, as a text's strokes;
/// - a dark strip at the bottom where a video's frame `n` carries a yellow
///   marker moving right (6 px a frame), its number in white seven-segment
///   digits and as eight blocks (bit 0 left, white 1), which
///   `frameNumber(in:)` reads back.
enum ReferencePicture {
    static let width = 384, height = 240
    /// The bottom strip with a video frame's marker and number.
    static let stripTop = 200

    struct RGB: Equatable { var r, g, b: UInt8 }

    enum Shape {
        case rect(x: Int, y: Int, w: Int, h: Int, RGB)
        case ellipse(cx: Double, cy: Double, r: Double, RGB)
        case polygon([(Double, Double)], RGB)
    }

    /// What is drawn, from the top left, in order.
    static func shapes(frame: Int? = nil) -> [Shape] {
        var shapes: [Shape] = []
        let bars: [RGB] = [RGB(r: 255, g: 255, b: 255), RGB(r: 255, g: 255, b: 0), RGB(r: 0, g: 255, b: 255), RGB(r: 0, g: 255, b: 0),
                           RGB(r: 255, g: 0, b: 255), RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 0, b: 255), RGB(r: 0, g: 0, b: 0)]
        for (i, colour) in bars.enumerated() { shapes.append(.rect(x: i * 48, y: 0, w: 48, h: 48, colour)) }
        for x in 0..<width {
            let v = UInt8((x * 255 + (width - 1) / 2) / (width - 1))
            shapes.append(.rect(x: x, y: 48, w: 1, h: 32, RGB(r: v, g: v, b: v)))
            shapes.append(.rect(x: x, y: 80, w: 1, h: 24, RGB(r: 255 - v, g: 0, b: v)))
        }
        shapes.append(.rect(x: 0, y: 104, w: width, h: stripTop - 104, RGB(r: 128, g: 128, b: 128)))
        let white = RGB(r: 255, g: 255, b: 255), black = RGB(r: 0, g: 0, b: 0)
        // F
        shapes += [.rect(x: 16, y: 112, w: 12, h: 80, white), .rect(x: 16, y: 112, w: 48, h: 12, white),
                   .rect(x: 16, y: 146, w: 36, h: 12, white)]
        shapes.append(.ellipse(cx: 112, cy: 152, r: 36, RGB(r: 255, g: 128, b: 0)))
        shapes.append(.polygon([(160, 116), (160, 188), (224, 152)], RGB(r: 0, g: 200, b: 0)))
        for k in 0..<16 { shapes.append(.rect(x: 240 + 4 * k, y: 112, w: 1, h: 80, black)) }
        for k in 0..<13 { shapes.append(.rect(x: 312, y: 112 + 6 * k, w: 64, h: 2, white)) }
        shapes.append(.rect(x: 0, y: stripTop, w: width, h: height - stripTop, RGB(r: 32, g: 32, b: 32)))
        guard let frame else { return shapes }
        shapes.append(.rect(x: 176 + 6 * frame, y: 206, w: 16, h: 16, RGB(r: 255, g: 255, b: 0)))
        for bit in 0..<8 {
            shapes.append(.rect(x: 8 + 20 * bit, y: 212, w: 16, h: 22, frame >> bit & 1 == 1 ? white : black))
        }
        for (i, digit) in [frame / 10 % 10, frame % 10].enumerated() {
            shapes += sevenSegments(digit, x: 336 + 22 * i, y: 206, colour: white)
        }
        return shapes
    }

    /// A digit 14 × 28 with strokes 3 wide.
    private static func sevenSegments(_ digit: Int, x: Int, y: Int, colour: RGB) -> [Shape] {
        // a top, b top right, c bottom right, d bottom, e bottom left, f top left, g middle
        let on = ["abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc", "abcdefg", "abcdfg"][digit]
        let segments: [Character: (Int, Int, Int, Int)] = [
            "a": (0, 0, 14, 3), "b": (11, 0, 3, 15), "c": (11, 13, 3, 15), "d": (0, 25, 14, 3),
            "e": (0, 13, 3, 15), "f": (0, 0, 3, 15), "g": (0, 13, 14, 3),
        ]
        return on.compactMap { segments[$0] }.map { .rect(x: x + $0.0, y: y + $0.1, w: $0.2, h: $0.3, colour) }
    }

    /// The picture (frame nil) or a video's frame, 8-bit sRGB, opaque.
    static func image(frame: Int? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        draw(in: context, frame: frame)
        return context.makeImage()!
    }

    /// Drawn into a context of `width` × `height` (pixels or a PDF page's
    /// points) whose origin is its bottom left.
    static func draw(in context: CGContext, frame: Int? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        // Drawn from the top left
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for shape in shapes(frame: frame) {
            switch shape {
            case .rect(let x, let y, let w, let h, let c):
                context.setFillColor(cgColor(c))
                context.fill(CGRect(x: x, y: y, width: w, height: h))
            case .ellipse(let cx, let cy, let r, let c):
                context.setFillColor(cgColor(c))
                context.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            case .polygon(let points, let c):
                context.setFillColor(cgColor(c))
                context.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
                context.closePath()
                context.fillPath()
            }
        }
    }

    /// The picture resampled to `width` × `height` (formats of square sides).
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func cgColor(_ c: RGB) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// The picture as SVG, shape for shape.
    static func svg() -> String {
        func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
        var body = ""
        for shape in shapes() {
            switch shape {
            case .rect(let x, let y, let w, let h, let c):
                body += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" fill=\"\(hex(c))\"/>\n"
            case .ellipse(let cx, let cy, let r, let c):
                body += "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(r)\" fill=\"\(hex(c))\"/>\n"
            case .polygon(let points, let c):
                let list = points.map { "\($0.0),\($0.1)" }.joined(separator: " ")
                body += "<polygon points=\"\(list)\" fill=\"\(hex(c))\"/>\n"
            }
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)" shape-rendering="crispEdges">
        \(body)</svg>

        """
    }

    /// The frame number a video's picture carries (its eight blocks), read
    /// at the blocks' middles in a picture of any size; nil when a block is
    /// neither clearly light nor clearly dark.
    static func frameNumber(in image: CGImage) -> Int? {
        let pixels = RGBAPixels(image)
        var number = 0
        for bit in 0..<8 {
            let x = (Double(8 + 20 * bit) + 8) / Double(width) * Double(image.width)
            let y = (212.0 + 11) / Double(height) * Double(image.height)
            let p = pixels.at(Int(x), Int(y))
            let luma = (Int(p.r) * 299 + Int(p.g) * 587 + Int(p.b) * 114) / 1000
            if luma > 160 { number |= 1 << bit } else if luma > 96 { return nil }
        }
        return number
    }
}

/// A picture's pixels as 8-bit sRGB RGBA, rows from the top.
struct RGBAPixels {
    let width: Int, height: Int
    let bytes: [UInt8]

    init(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let w = width ?? image.width, h = height ?? image.height
        self.width = w
        self.height = h
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Transparent parts lie on white, as on a page
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.bytes = bytes
    }

    func at(_ x: Int, _ y: Int) -> ReferencePicture.RGB {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return ReferencePicture.RGB(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2])
    }

    /// Each row's red, green and blue, from the top.
    func rgbRows() -> [[UInt8]] {
        (0..<height).map { (y: Int) -> [UInt8] in
            var row = [UInt8]()
            row.reserveCapacity(width * 3)
            for x in 0..<width {
                let i = (y * width + x) * 4
                row += [bytes[i], bytes[i + 1], bytes[i + 2]]
            }
            return row
        }
    }
}
