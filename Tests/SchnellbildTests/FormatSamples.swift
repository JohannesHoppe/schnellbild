import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The visual check's samples: the reference picture (`ReferencePicture`)
/// written in each format the app shows, with what its decoded picture is
/// compared with and how closely.
extension FormatFixtures {
    struct Sample {
        /// What the contact sheet and the results call it ("ppm P3").
        let name: String
        /// The file, written by `samples(in:)`.
        let url: URL
        /// What the decoded picture must look like: the reference picture,
        /// its grey (formats without colour), black and white (bitmaps), or
        /// the page a document shows.
        let reference: CGImage
        let tolerance: Tolerance
    }

    /// How far a decoded picture may lie from its reference, per channel on
    /// 0 … 255: the mean over the picture, and at the probes (the middles of
    /// even areas: the bars, the ramps, the shapes, `probePoints`), where a
    /// swapped channel, a wrong palette or gamma shows at once.
    struct Tolerance {
        let mean: Double
        let probe: Int

        /// Kept exactly (only rounding, scaling for a tile).
        static let lossless = Tolerance(mean: 2, probe: 4)
        /// A JPEG's 8 × 8 blocks and halved colour.
        static let jpeg = Tolerance(mean: 6, probe: 10)
        /// Lossy textures and still codecs (ASTC, PVRTC, AVIF, JPEG 2000).
        static let lossy = Tolerance(mean: 9, probe: 16)
        /// Video codecs at a high quality, the colour halved.
        static let video = Tolerance(mean: 10, probe: 20)
        /// A page drawn by its own renderer (antialiased edges).
        static let drawn = Tolerance(mean: 4, probe: 6)

        /// A tile is the picture scaled down: its edges blend, the probes
        /// stay (they lie inside even areas).
        var scaled: Tolerance { Tolerance(mean: mean + 5, probe: probe + 4) }
    }

    /// The middles of the reference picture's even areas (x, y from the top left).
    static let probePoints: [(String, Int, Int)] = {
        var points: [(String, Int, Int)] = []
        for bar in 0..<8 { points.append(("bar \(bar + 1)", 24 + 48 * bar, 24)) }
        for x in [48, 144, 240, 336] { points.append(("grey ramp \(x)", x, 64)) }
        for x in [48, 192, 336] { points.append(("red-blue ramp \(x)", x, 92)) }
        points += [("F", 22, 170), ("circle", 112, 152), ("triangle", 180, 152), ("background", 232, 130), ("strip", 322, 228)]
        return points
    }()

    /// The reference's grey (Rec. 601, as the grey formats are written).
    static func grey(of image: CGImage) -> CGImage { remapped(image) { r, g, b in let v = grey(r, g, b); return (v, v, v) } }

    /// The reference in black and white (grey below the middle black).
    static func bitmap(of image: CGImage) -> CGImage {
        remapped(image) { r, g, b in let v: UInt8 = grey(r, g, b) < 128 ? 0 : 255; return (v, v, v) }
    }

    private static func remapped(_ image: CGImage, _ map: (UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let pixels = RGBAPixels(image)
        var bytes = pixels.bytes
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let (r, g, b) = map(bytes[i], bytes[i + 1], bytes[i + 2])
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A PDF page drawn by Core Graphics (not PDFKit, which the app uses)
    /// at its size in points, on white.
    static func drawnPage(_ pdf: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: box.size))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Writes every picture sample into `dir`; the names of formats this
    /// macOS can't write a sample of (ImageIO's writer missing) go to
    /// `missing`.
    static func samples(in dir: URL, missing: inout [String]) throws -> [Sample] {
        let reference = ReferencePicture.image()
        let square = ReferencePicture.scaled(reference, width: 256, height: 256)
        var samples: [Sample] = []
        func add(_ name: String, _ file: String, _ data: Data?, _ expected: CGImage = reference, _ tolerance: Tolerance = .lossless) throws {
            guard let data else { missing.append(name); return }
            let url = dir.appendingPathComponent(file)
            try data.write(to: url)
            samples.append(Sample(name: name, url: url, reference: expected, tolerance: tolerance))
        }
        let apng = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]]
        try add("png (control)", "control.png", written(UTType.png.identifier, picture: reference))
        try add("apng", "animated.apng", written(UTType.png.identifier, frames: 2, properties: apng, picture: reference))
        try add("jpf (JPEG 2000)", "picture.jpf", written("public.jpeg-2000", picture: reference), reference, .lossy)
        try add("jpx (JPEG 2000)", "picture.jpx", written("public.jpeg-2000", picture: reference), reference, .lossy)
        try add("j2c (code stream)", "picture.j2c", jpeg2000CodeStream(picture: reference), reference, .lossy)
        try add("psb", "large.psb", photoshop(large: true, picture: reference))
        try add("dib", "picture.dib", written(UTType.bmp.identifier, picture: reference))
        try add("cur", "pointer.cur", cursor(picture: square), square)
        try add("sgi", "picture.sgi", sgi(picture: reference))
        try add("pbm P1", "text-bitmap.pbm", netpbm("P1", picture: reference), bitmap(of: reference))
        try add("pbm P4", "bitmap.pbm", netpbm("P4", picture: reference), bitmap(of: reference))
        try add("pgm P2", "text-grey.pgm", netpbm("P2", picture: reference), grey(of: reference))
        try add("pgm P5", "grey.pgm", netpbm("P5", picture: reference), grey(of: reference))
        try add("ppm P3", "text-colour.ppm", netpbm("P3", picture: reference))
        try add("ppm P6", "colour.ppm", netpbm("P6", picture: reference))
        try add("pnm P6", "colour.pnm", netpbm("P6", picture: reference))
        try add("pfm", "float.pfm", netpbm("PF", picture: reference))
        try add("pict", "picture.pict", pict(picture: reference))
        let astc = astc(picture: reference)
        try add("astc (void-extent blocks)", "texture.astc", astc.data, astc.expected)
        try add("ktx (RGBA8)", "texture.ktx", ktx(picture: reference))
        try add("ktx2", "texture.ktx2", written("org.khronos.ktx2", picture: reference), reference, .lossy)
        try add("pvr", "texture.pvr", written("public.pvr", picture: square), square, .lossy)
        try add("atx", "texture.atx", written("com.apple.atx", picture: reference), reference, .lossy)
        try add("dcm (RGB)", "colour.dcm", dicom(picture: reference, colour: true))
        try add("dcm (grey)", "grey.dcm", dicom(picture: reference), grey(of: reference))
        return samples
    }

    /// Writes every document sample (vector pictures and files shown by a
    /// picture they carry) into `dir`.
    static func documentSamples(in dir: URL, missing: inout [String]) throws -> [Sample] {
        let reference = ReferencePicture.image()
        var samples: [Sample] = []
        func add(_ name: String, _ file: String, _ data: Data?, _ expected: CGImage = reference, _ tolerance: Tolerance = .lossless) throws {
            guard let data else { missing.append(name); return }
            let url = dir.appendingPathComponent(file)
            try data.write(to: url)
            samples.append(Sample(name: name, url: url, reference: expected, tolerance: tolerance))
        }
        // SVG compressed with gzip, without a name or time in its header
        let svg = dir.appendingPathComponent("drawing.svg")
        try Data(ReferencePicture.svg().utf8).write(to: svg)
        try run("/usr/bin/gzip", ["-n", "-S", "z", svg.path], in: dir)
        samples.append(Sample(name: "svgz", url: dir.appendingPathComponent("drawing.svgz"), reference: reference, tolerance: .drawn))

        let size = CGSize(width: ReferencePicture.width, height: ReferencePicture.height)
        try add("ai (PDF content)", "vector.ai", pdf(size: size) { ReferencePicture.draw(in: $0, vector: true) }, reference, .drawn)
        try add("ai (XMP thumbnail)", "thumbnail.ai", illustratorWithoutPDF(picture: reference), reference, .jpeg)
        let placeholder = pdf(size: size, text: placeholderText) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        try add("ai (placeholder only)", "placeholder.ai", placeholder, try required(drawnPage(placeholder), "the placeholder page"), .drawn)
        try add("eps (DOS, TIFF)", "dos.eps", dosEPS(picture: reference))
        try add("eps (XMP thumbnail)", "xmp.eps", epsWithXMP(picture: reference), reference, .jpeg)
        try add("epsf (DOS, TIFF)", "dos.epsf", dosEPS(picture: reference))
        try add("epsi (hex preview)", "preview.epsi", epsi(picture: reference), grey(of: reference))
        try add("epi (hex preview)", "preview.epi", epsi(picture: reference), grey(of: reference))
        try add("ps (hex preview)", "preview.ps", epsi(picture: reference), grey(of: reference))

        // ZIP documents: the picture inside as PNG
        let png = try required(written(UTType.png.identifier, picture: reference), "a PNG")
        for (ext, entries) in [("kra", "mergedimage.png"), ("ora", "mergedimage.png"),
                               ("procreate", "QuickLook/Thumbnail.png"), ("sketch", "previews/preview.png")] {
            let source = dir.appendingPathComponent("zip-\(ext)")
            let inside = source.appendingPathComponent(entries)
            try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: inside)
            try Data("<doc/>".utf8).write(to: source.appendingPathComponent("maindoc.xml"))
            let url = dir.appendingPathComponent("document.\(ext)")
            try run("/usr/bin/zip", ["-q", "-X", "-r", url.path, "."], in: source)
            samples.append(Sample(name: ext, url: url, reference: reference, tolerance: .lossless))
        }
        return samples
    }

    private static func run(_ tool: String, _ arguments: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SampleError.toolFailed(tool) }
    }

    enum SampleError: Error { case toolFailed(String), missing(String) }

    private static func required<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw SampleError.missing(what) }
        return value
    }
}
