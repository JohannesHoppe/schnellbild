import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

/// Pictures of every format the app shows, made in the test: by ImageIO
/// where it writes the format, else by hand from the format's published
/// layout. No sample files from elsewhere. Each writer takes the picture
/// to write: the small one here for the decode tests, `ReferencePicture`
/// for the visual check (`FormatVisualTests`, `samples()`).
enum FormatFixtures {
    /// A 4 × 2 picture: left half red, right half blue.
    static let width = 4, height = 2

    /// `blackAndWhite`: left half black, right half white (for bitmaps).
    static func cgImage(width: Int = width, height: Int = height, blackAndWhite: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(blackAndWhite ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(blackAndWhite ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    /// Written by ImageIO as `type` (`frames` pictures; more than one: an
    /// animation); nil where ImageIO doesn't write it on this system.
    /// `square`: a 16 × 16 picture, for formats of square sides (icons,
    /// textures). `picture`: written in place of the small one.
    static func written(_ type: String, frames: Int = 1, square: Bool = false, properties: [CFString: Any] = [:],
                        picture: CGImage? = nil) -> Data? {
        let data = NSMutableData()
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type),
              let destination = CGImageDestinationCreateWithData(data, type as CFString, frames, nil) else { return nil }
        let image = picture ?? (square ? cgImage(width: 16, height: 16) : cgImage())
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A picture for each extension of a format ImageIO reads (nil where
    /// it can't be made on this system).
    static func all() -> [(String, Data?)] {
        let apng = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]]
        let jp2 = written(UTType("public.jpeg-2000")!.identifier)
        return [
            ("pbm", netpbm("P1")), ("pgm", netpbm("P5")), ("ppm", netpbm("P6")), ("pnm", netpbm("P6")), ("pfm", netpbm("PF")),
            ("sgi", sgi()), ("psd", photoshop(large: false)), ("psb", photoshop(large: true)),
            ("pict", pict()), ("pct", pict()), ("dcm", dicom()), ("dicom", dicom()),
            ("cur", cursor()), ("dib", written(UTType.bmp.identifier)), ("bmp", written(UTType.bmp.identifier)),
            ("tga", written("com.truevision.tga-image")), ("ico", written(UTType.ico.identifier, square: true)),
            ("icns", written(UTType.icns.identifier, square: true)), ("exr", written("com.ilm.openexr-image")),
            ("dds", dds()), ("astc", written("org.khronos.astc")), ("ktx", written("org.khronos.ktx")),
            ("ktx2", written("org.khronos.ktx2")), ("pvr", written("public.pvr", square: true)), ("atx", written("com.apple.atx")),
            ("jp2", jp2), ("jpf", jp2), ("jpx", jp2), ("j2k", jp2),
            ("avif", written("public.avif")), ("avifs", written("public.avif", frames: 2)),
            ("heic", written(UTType.heic.identifier)), ("heics", written("public.heics", frames: 2)),
            ("apng", written(UTType.png.identifier, frames: 2, properties: apng)),
            ("gif", written(UTType.gif.identifier, frames: 2)), ("webp", written(UTType.webP.identifier)),
            ("jxl", written("public.jpeg-xl")), ("tif", written(UTType.tiff.identifier)),
        ]
    }

    // MARK: By hand

    private static func join(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }
    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func be32(_ v: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) } }
    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] { [0, 8, 16, 24].map { UInt8((v >> $0) & 0xFF) } }

    /// A picture's pixels for the writers by hand: RGB rows from the top.
    struct Pixels {
        let width: Int, height: Int
        let rows: [[UInt8]]

        init(_ image: CGImage) {
            let pixels = RGBAPixels(image)
            width = pixels.width
            height = pixels.height
            rows = pixels.rgbRows()
        }

        /// The grey of each pixel (Rec. 601's weights, as Netpbm's ppmtopgm),
        /// rows from the top.
        var grey: [[UInt8]] { rows.map { row in (0..<width).map { FormatFixtures.grey(row[$0 * 3], row[$0 * 3 + 1], row[$0 * 3 + 2]) } } }
        /// Black (true) where the grey is below the middle.
        var bits: [[Bool]] { grey.map { $0.map { $0 < 128 } } }
    }

    static func grey(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
        UInt8((299 * Int(r) + 587 * Int(g) + 114 * Int(b) + 500) / 1000)
    }

    /// Netpbm (netpbm.sourceforge.net/doc): P1 bitmap as text, P2 grey as
    /// text, P3 colour as text, P4 bitmap, P5 grey, P6 colour, PF float colour.
    static func netpbm(_ kind: String, picture: CGImage? = nil) -> Data {
        let p = Pixels(picture ?? cgImage(blackAndWhite: kind == "P1" || kind == "P4"))
        var head = "\(kind)\n\(p.width) \(p.height)\n"
        var body: [UInt8] = []
        func text(_ rows: [[String]]) -> String {
            // Lines of at most 70 characters, as the format asks
            rows.map { row in
                var lines: [String] = [], line = ""
                for value in row {
                    if !line.isEmpty, line.count + value.count + 1 > 70 { lines.append(line); line = "" }
                    line += line.isEmpty ? value : " " + value
                }
                return (lines + [line]).joined(separator: "\n")
            }.joined(separator: "\n") + "\n"
        }
        switch kind {
        case "P1":   // 1 is black
            head += text(p.bits.map { $0.map { $0 ? "1" : "0" } })
        case "P2":
            head += "255\n" + text(p.grey.map { $0.map(String.init) })
        case "P3":
            head += "255\n" + text(p.rows.map { $0.map(String.init) })
        case "P4":   // one bit a pixel, 1 is black, rows padded to bytes
            for row in p.bits {
                var byte: UInt8 = 0
                for (x, black) in row.enumerated() {
                    if black { byte |= 0x80 >> UInt8(x % 8) }
                    if x % 8 == 7 || x == row.count - 1 { body.append(byte); byte = 0 }
                }
            }
        case "P5":
            head += "255\n"
            body = p.grey.flatMap { $0 }
        case "P6":
            head += "255\n"
            body = p.rows.flatMap { $0 }
        default:     // "PF": little-endian floats (a negative scale), rows from the bottom, linear light
            head += "-1.0\n"
            for row in p.rows.reversed() {
                for value in row {
                    body += withUnsafeBytes(of: linear(value).bitPattern.littleEndian) { Array($0) }
                }
            }
        }
        return Data(head.utf8) + Data(body)
    }

    /// An sRGB value as linear light (IEC 61966-2-1), as HDR formats store it.
    static func linear(_ value: UInt8) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    /// ASTC (Khronos Data Format Specification, "ASTC Compressed Texture
    /// Image Formats"; the .astc file as ARM's astcenc writes it: magic
    /// 5CA1AB13, block 4 × 4 × 1, the sides in 24 bits, then the blocks
    /// row by row from the top). Every block a void-extent block: one
    /// colour (UNORM16), the mean of its 4 × 4 pixels. Made by hand, since
    /// ImageIO's ASTC writer puts the rows from the bottom while its reader
    /// (as astcenc) reads them from the top. `expected`: the picture of
    /// those block colours.
    static func astc(picture: CGImage) -> (data: Data, expected: CGImage) {
        let p = Pixels(picture)
        var bytes: [UInt8] = [0x13, 0xAB, 0xA1, 0x5C, 4, 4, 1]
        bytes += [UInt8(p.width & 0xFF), UInt8(p.width >> 8 & 0xFF), 0, UInt8(p.height & 0xFF), UInt8(p.height >> 8 & 0xFF), 0, 1, 0, 0]
        var blocky = p.rows
        for by in stride(from: 0, to: p.height, by: 4) {
            for bx in stride(from: 0, to: p.width, by: 4) {
                var sum = [0, 0, 0], count = 0
                for y in by..<min(by + 4, p.height) {
                    for x in bx..<min(bx + 4, p.width) {
                        for c in 0..<3 { sum[c] += Int(p.rows[y][x * 3 + c]) }
                        count += 1
                    }
                }
                let mean = sum.map { UInt8(($0 + count / 2) / count) }
                for y in by..<min(by + 4, p.height) {
                    for x in bx..<min(bx + 4, p.width) { for c in 0..<3 { blocky[y][x * 3 + c] = mean[c] } }
                }
                // Void extent: block mode 1FC, LDR, the extent's coordinates all ones
                bytes += [0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
                for value in mean + [255] { bytes += le16(Int(value) * 257) }
            }
        }
        return (Data(bytes), image(width: p.width, height: p.height, rows: blocky))
    }

    /// KTX 1 (Khronos' "KTX File Format Specification" 1.1): RGBA8
    /// uncompressed, its rows from the top as its KTXorientation key says
    /// ("S=r,T=d"). Made by hand, since ImageIO's KTX writer states half
    /// floats and writes each 8-bit value twice (255 becomes FFFF, a NaN).
    static func ktx(picture: CGImage) -> Data {
        let p = Pixels(picture)
        var bytes: [UInt8] = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]
        var pair = Array("KTXorientation".utf8) + [0] + Array("S=r,T=d".utf8) + [0]
        let pairSize = pair.count
        while pair.count % 4 != 0 { pair.append(0) }
        // endianness, glType UNSIGNED_BYTE, size 1, glFormat RGBA, RGBA8, base RGBA, sides, no depth or array, 1 face, 1 level
        bytes += join(le32(0x0403_0201), le32(0x1401), le32(1), le32(0x1908), le32(0x8058), le32(0x1908),
                      le32(p.width), le32(p.height), le32(0), le32(0), le32(1), le32(1), le32(4 + pair.count))
        bytes += join(le32(pairSize), pair)
        bytes += le32(p.width * p.height * 4)
        for row in p.rows {
            for x in 0..<p.width { bytes += [row[x * 3], row[x * 3 + 1], row[x * 3 + 2], 255] }
        }
        return Data(bytes)
    }

    /// An sRGB picture of RGB rows from the top.
    static func image(width: Int, height: Int, rows: [[UInt8]]) -> CGImage {
        let rgba = rows.flatMap { row in (0..<width).flatMap { [row[$0 * 3], row[$0 * 3 + 1], row[$0 * 3 + 2], UInt8(255)] } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// SGI image (Paul Haeberli's "The SGI Image File Format" 1.00):
    /// uncompressed, 8 bits, three channels one after the other, rows from the bottom.
    static func sgi(picture: CGImage? = nil) -> Data {
        let p = Pixels(picture ?? cgImage())
        var bytes = join(be16(474), [0, 1], be16(3), be16(p.width), be16(p.height), be16(3))
        bytes += join(be32(0), be32(255), [0, 0, 0, 0], [UInt8](repeating: 0, count: 80), be32(0))
        bytes += [UInt8](repeating: 0, count: 512 - bytes.count)
        for channel in 0..<3 {
            for row in p.rows.reversed() {
                bytes += (0..<p.width).map { row[$0 * 3 + channel] }
            }
        }
        return Data(bytes)
    }

    /// Photoshop (Adobe's "Photoshop File Formats Specification"): version
    /// 1 (PSD) or 2 (PSB, the large document format: 8-byte layer and mask
    /// length), RGB, 8 bits, the composite image uncompressed.
    static func photoshop(large: Bool, picture: CGImage? = nil) -> Data {
        let p = Pixels(picture ?? cgImage())
        let version = be16(large ? 2 : 1)
        var bytes = join(Array("8BPS".utf8), version, [UInt8](repeating: 0, count: 6))
        bytes += join(be16(3), be32(p.height), be32(p.width), be16(8), be16(3))
        bytes += be32(0)                                  // colour mode data
        bytes += be32(0)                                  // image resources
        bytes += be32(0)                                  // layer and mask information (8 bytes in a PSB)
        if large { bytes += be32(0) }
        bytes += be16(0)                                  // raw image data
        for channel in 0..<3 {
            for row in p.rows { bytes += (0..<p.width).map { row[$0 * 3 + channel] } }
        }
        return Data(bytes)
    }

    /// DirectDraw Surface (Microsoft's "DDS Programming Guide": "DDS ", the
    /// 124-byte header with its pixel format): 32-bit BGRA, uncompressed.
    /// ImageIO's own DDS writer gives nothing readable back.
    static func dds() -> Data {
        var bytes = Array("DDS ".utf8)
        // caps, height, width, pitch, pixel format flags
        bytes += join(le32(124), le32(0x1 | 0x2 | 0x4 | 0x8 | 0x1000), le32(height), le32(width), le32(width * 4), le32(0), le32(0))
        bytes += [UInt8](repeating: 0, count: 44)
        bytes += join(le32(32), le32(0x41), le32(0), le32(32), le32(0x00FF_0000), le32(0x0000_FF00), le32(0x0000_00FF), le32(0xFF00_0000))
        bytes += join(le32(0x1000), le32(0), le32(0), le32(0), le32(0))
        for row in Pixels(cgImage()).rows {
            for x in 0..<width { bytes += [row[x * 3 + 2], row[x * 3 + 1], row[x * 3], 255] }
        }
        return Data(bytes)
    }

    /// A Windows cursor: an icon written by ImageIO with the type field 2
    /// and its hot spot (in place of planes and bit count) at 0, 0.
    static func cursor(picture: CGImage? = nil) -> Data? {
        guard var bytes = written(UTType.ico.identifier, square: true, picture: picture).map(Array.init) else { return nil }
        bytes[2] = 2; bytes[3] = 0
        let count = Int(bytes[4]) | Int(bytes[5]) << 8
        for entry in 0..<count {
            let at = 6 + entry * 16
            for i in 4..<8 { bytes[at + i] = 0 }
        }
        return Data(bytes)
    }

    /// QuickDraw PICT version 2 (Inside Macintosh: Imaging With QuickDraw,
    /// appendix A): the 512-byte file header, the frame, then a red
    /// rectangle painted over a 10 × 10 frame, or the picture given as
    /// DirectBitsRect (opcode 009A: a 32-bit pixel map, each row's red,
    /// green and blue one after the other packed with PackBits, packType 4,
    /// as Photoshop writes them).
    static func pict(picture: CGImage? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        let p = picture.map(Pixels.init)
        let frame = join(be16(0), be16(0), be16(p?.height ?? 10), be16(p?.width ?? 10))
        bytes += join(be16(0), frame)
        bytes += join(be16(0x0011), be16(0x02FF))                                // version 2
        bytes += join(be16(0x0C00), be16(0xFFFE), be16(0), be32(0x0048_0000), be32(0x0048_0000), frame, be32(0))
        if let p {
            let rowBytes = p.width * 4
            bytes += join(be16(0x009A), be32(0x0000_00FF), be16(rowBytes | 0x8000), frame)
            bytes += join(be16(0), be16(4), be32(0), be32(0x0048_0000), be32(0x0048_0000))   // version, packType, packSize, resolution
            bytes += join(be16(16), be16(32), be16(3), be16(8), be32(0), be32(0), be32(0))   // RGBDirect, 32 bits, 3 × 8
            bytes += join(frame, frame, be16(0))                                              // source, destination, srcCopy
            for row in p.rows {
                let planes = (0..<3).flatMap { channel in (0..<p.width).map { row[$0 * 3 + channel] } }
                var packed: [UInt8] = []
                // PackBits: literal runs of at most 128 bytes, each after its length less one
                var at = 0
                while at < planes.count {
                    let run = min(128, planes.count - at)
                    packed.append(UInt8(run - 1))
                    packed += planes[at..<at + run]
                    at += run
                }
                // The packed length as a word when rowBytes exceeds 250
                bytes += rowBytes > 250 ? be16(packed.count) : [UInt8(packed.count)]
                bytes += packed
            }
            if bytes.count % 2 == 1 { bytes.append(0) }                             // opcodes on even offsets
        } else {
            bytes += join(be16(0x001A), be16(0xFFFF), be16(0), be16(0))            // foreground colour red
            bytes += join(be16(0x0031), frame)                                       // paint rect
        }
        bytes += be16(0x00FF)                                               // end of picture
        return Data(bytes)
    }

    /// DICOM (PS3.10 file format: preamble, "DICM", the file meta group in
    /// explicit VR little endian; the data set in the same transfer syntax):
    /// an 8-bit grey picture, or with `colour` RGB (PS3.3 C.7.6.3: three
    /// samples a pixel, interleaved).
    static func dicom(picture: CGImage? = nil, colour: Bool = false) -> Data {
        func element(_ group: Int, _ item: Int, _ vr: String, _ value: [UInt8]) -> [UInt8] {
            var value = value
            if value.count % 2 == 1 { value.append(vr == "UI" ? 0 : 0x20) }
            let long = ["OB", "OW", "UN", "SQ", "UT"].contains(vr)
            let length: [UInt8] = long ? join([0, 0], le32(value.count)) : le16(value.count)
            return join(le16(group), le16(item), Array(vr.utf8), length, value)
        }
        let p = Pixels(picture ?? cgImage())
        let syntax = Array("1.2.840.10008.1.2.1".utf8)
        let mediaClass = Array("1.2.840.10008.5.1.4.1.1.7".utf8)   // secondary capture
        let instance = Array("1.2.3.4".utf8)
        var meta = element(0x0002, 0x0001, "OB", [0, 1])
        meta += join(element(0x0002, 0x0002, "UI", mediaClass), element(0x0002, 0x0003, "UI", instance))
        meta += element(0x0002, 0x0010, "UI", syntax)
        var bytes = join([UInt8](repeating: 0, count: 128), Array("DICM".utf8))
        bytes += join(element(0x0002, 0x0000, "UL", le32(meta.count)), meta)
        bytes += join(element(0x0008, 0x0016, "UI", mediaClass), element(0x0008, 0x0018, "UI", instance))
        bytes += element(0x0028, 0x0002, "US", le16(colour ? 3 : 1))
        bytes += element(0x0028, 0x0004, "CS", Array((colour ? "RGB" : "MONOCHROME2").utf8))
        if colour { bytes += element(0x0028, 0x0006, "US", le16(0)) }
        bytes += join(element(0x0028, 0x0010, "US", le16(p.height)), element(0x0028, 0x0011, "US", le16(p.width)))
        bytes += join(element(0x0028, 0x0100, "US", le16(8)), element(0x0028, 0x0101, "US", le16(8)))
        bytes += join(element(0x0028, 0x0102, "US", le16(7)), element(0x0028, 0x0103, "US", le16(0)))
        bytes += element(0x7FE0, 0x0010, "OB", colour ? p.rows.flatMap { $0 } : p.grey.flatMap { $0 })
        return Data(bytes)
    }

    /// A JPEG 2000 code stream (".j2c", ISO 15444-1 annex A) without the
    /// JP2 file around it: the contents of the JP2's "jp2c" box.
    static func jpeg2000CodeStream(picture: CGImage? = nil) -> Data? {
        guard let jp2 = written("public.jpeg-2000", picture: picture) else { return nil }
        let bytes = [UInt8](jp2)
        var at = 0
        while at + 8 <= bytes.count {
            var length = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            let type = String(decoding: bytes[at + 4..<at + 8], as: UTF8.self)
            var header = 8
            if length == 1, at + 16 <= bytes.count {   // an 8-byte length follows
                length = (0..<8).reduce(0) { $0 << 8 | Int(bytes[at + 8 + $1]) }
                header = 16
            } else if length == 0 {
                length = bytes.count - at
            }
            guard length >= header, at + length <= bytes.count else { return nil }
            if type == "jp2c" { return Data(bytes[at + header..<at + length]) }
            at += length
        }
        return nil
    }

    // MARK: Vector documents

    /// A one-page PDF of `size` points through Core Graphics: filled red, or
    /// drawn by `drawing` (in the page's points, from the bottom left).
    static func pdf(size: CGSize = CGSize(width: 200, height: 100), text: String? = nil,
                    drawing: ((CGContext) -> Void)? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        if let drawing {
            drawing(context)
        } else {
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(box)
        }
        if let text {
            // Text as a page carries it (PDFKit reads it back with `string`), small enough to fit the page
            let attributes = [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 3, nil)] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
            context.textPosition = CGPoint(x: 4, y: size.height / 2)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// An XMP packet with Illustrator's thumbnail (`xmpGImg:image`, base64
    /// with "&#xA;" for its line breaks, as Illustrator writes it; XMP
    /// Specification Part 2, "Thumbnail" in the xmpGImg namespace).
    static func xmpThumbnail(_ jpeg: Data, width: Int = width, height: Int = height) -> Data {
        let base64 = jpeg.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            .replacingOccurrences(of: "\n", with: "&#xA;")
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:xmpGImg="http://ns.adobe.com/xap/1.0/g/img/">
           <xmp:Thumbnails>
            <rdf:Alt>
             <rdf:li rdf:parseType="Resource">
              <xmpGImg:width>\(width)</xmpGImg:width>
              <xmpGImg:height>\(height)</xmpGImg:height>
              <xmpGImg:format>JPEG</xmpGImg:format>
              <xmpGImg:image>\(base64)</xmpGImg:image>
             </rdf:li>
            </rdf:Alt>
           </xmp:Thumbnails>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(packet.utf8)
    }

    /// Illustrator's placeholder page of a file saved without PDF content.
    static let placeholderText = "This is an Adobe Illustrator File that was saved without PDF Content."

    /// An Illustrator file saved with PDF content: a PDF (Illustrator's own
    /// data rides in it as private streams, which viewers pass over).
    static func illustratorWithPDF() -> Data { pdf() }

    /// An Illustrator file saved without PDF content: a PDF whose page is
    /// Illustrator's placeholder text, its XMP thumbnail (a JPEG of
    /// `picture`) beside it.
    static func illustratorWithoutPDF(picture: CGImage? = nil) -> Data? {
        let image = picture ?? cgImage()
        guard let jpeg = written(UTType.jpeg.identifier, picture: image) else { return nil }
        return pdf(text: placeholderText) + Data("\n%".utf8) + xmpThumbnail(jpeg, width: image.width, height: image.height)
    }

    /// A PostScript program with a red square.
    static let postScript = Data("""
    %!PS-Adobe-3.0 EPSF-3.0
    %%BoundingBox: 0 0 4 2
    %%EndComments
    1 0 0 setrgbcolor 0 0 4 2 rectfill
    showpage
    %%EOF

    """.utf8)

    /// DOS EPS (Adobe TN 5002, "Encapsulated PostScript File Format
    /// Specification" 3.0, "DOS EPS Binary File Header"): the 30-byte header
    /// (C5D0D3C6, then little-endian offsets and lengths of the PostScript,
    /// a WMF and a TIFF preview; checksum FFFF), the PostScript, the TIFF.
    static func dosEPS(picture: CGImage? = nil) -> Data? {
        guard let tiff = written(UTType.tiff.identifier, picture: picture) else { return nil }
        let ps = [UInt8](postScript)
        let header = 30
        var bytes: [UInt8] = [0xC5, 0xD0, 0xD3, 0xC6]
        bytes += join(le32(header), le32(ps.count), le32(0), le32(0), le32(header + ps.count), le32(tiff.count), [0xFF, 0xFF])
        return Data(bytes + ps) + tiff
    }

    /// EPSI (TN 5002, "Device-Independent Screen Preview"): the preview in
    /// comments between %%BeginPreview: width height depth lines and
    /// %%EndPreview, hexadecimal, rows from the top, 0 white. Of the small
    /// picture one bit a pixel, left half black, right half white; of a
    /// picture given its grey, 8 bits a pixel, 32 bytes a line.
    static func epsi(picture: CGImage? = nil) -> Data {
        var lines: [String]
        let w: Int, h: Int, depth: Int
        if let picture {
            let p = Pixels(picture)
            (w, h, depth) = (p.width, p.height, 8)
            let hex = p.grey.flatMap { $0 }.map { String(format: "%02X", 255 - Int($0)) }
            lines = stride(from: 0, to: hex.count, by: 32).map { hex[$0..<min($0 + 32, hex.count)].joined() }
        } else {
            (w, h, depth) = (width, height, 1)
            lines = Array(repeating: String(format: "%02X", 0b1100_0000), count: height)
        }
        let text = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 \(w) \(h)
        %%EndComments
        %%BeginPreview: \(w) \(h) \(depth) \(lines.count)
        \(lines.map { "%" + $0 }.joined(separator: "\n"))
        %%EndPreview
        0 setgray 0 0 2 2 rectfill
        showpage
        %%EOF

        """
        return Data(text.utf8)
    }

    /// EPS with only an XMP thumbnail (as Illustrator writes into its EPS).
    static func epsWithXMP(picture: CGImage? = nil) -> Data? {
        let image = picture ?? cgImage()
        guard let jpeg = written(UTType.jpeg.identifier, picture: image) else { return nil }
        return Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 \(image.width) \(image.height)\n%%EndComments\n%%BeginMetadata\n".utf8)
            + xmpThumbnail(jpeg, width: image.width, height: image.height) + Data("\n%%EndMetadata\nshowpage\n%%EOF\n".utf8)
    }
}
