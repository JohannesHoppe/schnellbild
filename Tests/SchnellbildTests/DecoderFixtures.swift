import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Files in the formats the app decodes itself (QOI, PCX / DCX) and RAW
/// files LibRaw reads, made from one known reference picture: colour bars,
/// letters and a gradient (with alpha, a ramp and a hole). Encoded here by
/// the formats' specifications, so the tests compare what the app decodes
/// with what went in. `Scripts/make_decoder_samples.sh` writes them as
/// sample files.
enum DecoderFixtures {
    /// RGBA, 8 bits, not premultiplied, rows from the top.
    struct RGBA: Equatable {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int, pixels: [UInt8]? = nil) {
            self.width = width
            self.height = height
            self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height * 4)
        }

        subscript(x: Int, y: Int) -> [UInt8] {
            get { let o = (y * width + x) * 4; return Array(pixels[o..<o + 4]) }
            set { let o = (y * width + x) * 4; pixels.replaceSubrange(o..<o + 4, with: newValue) }
        }

        var image: CGImage {
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                           decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }

        /// The picture drawn into sRGB RGBA at `width` × `height` (over
        /// `background` where it is transparent).
        static func of(_ image: CGImage, width: Int, height: Int, background: CGColor? = nil) -> RGBA {
            var out = RGBA(width: width, height: height)
            out.pixels.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                if let background {
                    context.setFillColor(background)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return out
        }

        /// Mean and largest difference per colour sample (alpha left out).
        func difference(to other: RGBA) -> (mean: Double, max: Int) {
            precondition(width == other.width && height == other.height)
            var sum = 0, largest = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                for c in 0..<3 {
                    let d = abs(Int(pixels[i + c]) - Int(other.pixels[i + c]))
                    sum += d
                    largest = max(largest, d)
                }
            }
            return (Double(sum) / Double(width * height * 3), largest)
        }

        var png: Data {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return data as Data
        }
    }

    // MARK: The reference picture

    /// 5 × 7 letters, a row of 5 bits each, top row first.
    private static let font: [Character: [UInt8]] = [
        "Q": [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D], "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        "I": [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E], "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        "C": [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E], "X": [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        "R": [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11], "A": [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        "W": [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A], "D": [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
        "N": [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11], "G": [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
        "B": [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E], "Y": [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
        " ": [0, 0, 0, 0, 0, 0, 0],
    ]

    /// The colour bars: white, yellow, cyan, green, magenta, red, blue, black.
    static let bars: [[UInt8]] = [[255, 255, 255], [255, 255, 0], [0, 255, 255], [0, 255, 0],
                                  [255, 0, 255], [255, 0, 0], [0, 0, 255], [0, 0, 0]]

    /// The reference: colour bars in the top 40 %, white letters (`text`)
    /// on dark grey in the middle 30 %, a gradient in the bottom 30 %
    /// (red across, green down, blue against red). With `alpha`, the
    /// gradient fades out from left to right and a hole in the bars is
    /// transparent.
    static func reference(width: Int = 160, height: Int = 100, text: String = "QOI PCX", alpha: Bool = false) -> RGBA {
        var picture = RGBA(width: width, height: height)
        let barsEnd = height * 4 / 10, textEnd = height * 7 / 10
        for y in 0..<height {
            for x in 0..<width {
                let pixel: [UInt8]
                if y < barsEnd {
                    pixel = bars[x * bars.count / width] + [255]
                } else if y < textEnd {
                    pixel = [48, 48, 48, 255]
                } else {
                    let fx = Double(x) / Double(width - 1), fy = Double(y - textEnd) / Double(max(1, height - textEnd - 1))
                    let a = alpha ? UInt8(255 - fx * 200) : 255
                    pixel = [UInt8(fx * 255), UInt8(fy * 255), UInt8((1 - fx) * 255), a]
                }
                picture[x, y] = pixel
            }
        }
        // The letters, as large as fit the band
        let scale = max(1, min((textEnd - barsEnd - 4) / 7, (width - 4) / max(1, text.count * 6)))
        let left = (width - text.count * 6 * scale) / 2, top = barsEnd + (textEnd - barsEnd - 7 * scale) / 2
        for (i, character) in text.enumerated() {
            guard let rows = font[character] else { continue }
            for (row, bits) in rows.enumerated() {
                for column in 0..<5 where bits & (0x10 >> column) != 0 {
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            picture[left + (i * 6 + column) * scale + dx, top + row * scale + dy] = [255, 255, 255, 255]
                        }
                    }
                }
            }
        }
        if alpha {
            for y in barsEnd / 4..<barsEnd * 3 / 4 {
                for x in width / 3..<width / 2 { picture[x, y] = [0, 0, 0, 0] }
            }
        }
        return picture
    }

    // MARK: QOI

    /// The picture as QOI, encoded as the specification's reference
    /// encoder does (runs, index, diff, luma, RGB / RGBA).
    static func qoi(_ picture: RGBA, channels: Int, linear: Bool = false) -> Data {
        var out = Data("qoif".utf8)
        func be32(_ v: Int) { out.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        be32(picture.width)
        be32(picture.height)
        out.append(UInt8(channels))
        out.append(linear ? 1 : 0)
        var index = [[UInt8]](repeating: [0, 0, 0, 0], count: 64)
        var previous: [UInt8] = [0, 0, 0, 255]
        var run = 0
        let count = picture.width * picture.height
        for i in 0..<count {
            var px = Array(picture.pixels[i * 4..<i * 4 + 4])
            if channels == 3 { px[3] = 255 }
            if px == previous {
                run += 1
                if run == 62 || i == count - 1 { out.append(0xC0 | UInt8(run - 1)); run = 0 }
                continue
            }
            if run > 0 { out.append(0xC0 | UInt8(run - 1)); run = 0 }
            let hash = (Int(px[0]) * 3 + Int(px[1]) * 5 + Int(px[2]) * 7 + Int(px[3]) * 11) % 64
            if index[hash] == px {
                out.append(UInt8(hash))
            } else {
                index[hash] = px
                if px[3] == previous[3] {
                    let dr = Int(Int8(bitPattern: px[0] &- previous[0]))
                    let dg = Int(Int8(bitPattern: px[1] &- previous[1]))
                    let db = Int(Int8(bitPattern: px[2] &- previous[2]))
                    let drdg = dr - dg, dbdg = db - dg
                    if (-2...1).contains(dr), (-2...1).contains(dg), (-2...1).contains(db) {
                        out.append(0x40 | UInt8(dr + 2) << 4 | UInt8(dg + 2) << 2 | UInt8(db + 2))
                    } else if (-32...31).contains(dg), (-8...7).contains(drdg), (-8...7).contains(dbdg) {
                        out.append(0x80 | UInt8(dg + 32))
                        out.append(UInt8(drdg + 8) << 4 | UInt8(dbdg + 8))
                    } else {
                        out.append(contentsOf: [0xFE, px[0], px[1], px[2]])
                    }
                } else {
                    out.append(contentsOf: [0xFF, px[0], px[1], px[2], px[3]])
                }
            }
            previous = px
        }
        out.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        return out
    }

    // MARK: PCX

    enum PCXKind: String, CaseIterable {
        /// 1 bit, 1 plane: black and white.
        case mono = "1-bit"
        /// 2 bits, 1 plane: 4 colours of the header's palette.
        case cga = "2-bit"
        /// 1 bit in 4 planes: 16 colours of the header's palette (EGA).
        case ega = "4-bit-planes"
        /// 4 bits, 1 plane: 16 colours of the header's palette.
        case nibble = "4-bit"
        /// 8 bits, 1 plane: 256 colours of the palette at the end (VGA).
        case vga = "8-bit"
        /// 8 bits in 3 planes: red, green, blue.
        case rgb = "24-bit"
        /// 8 bits in 4 planes: red, green, blue, alpha.
        case rgba = "32-bit"

        var bitsPerPlane: Int {
            switch self {
            case .mono, .ega: return 1
            case .cga: return 2
            case .nibble: return 4
            case .vga, .rgb, .rgba: return 8
            }
        }

        var planes: Int {
            switch self {
            case .ega, .rgba: return 4
            case .rgb: return 3
            default: return 1
            }
        }
    }

    /// The palette a kind's picture is drawn with (red, green, blue each).
    static func palette(_ kind: PCXKind) -> [[UInt8]] {
        switch kind {
        case .mono: return [[0, 0, 0], [255, 255, 255]]
        case .cga: return [[0, 0, 0], [255, 255, 255], [255, 0, 0], [0, 0, 255]]
        case .ega, .nibble:
            return bars + [[48, 48, 48], [128, 128, 128], [128, 0, 0], [0, 128, 0], [0, 0, 128], [128, 128, 0], [0, 128, 128], [128, 0, 128]]
        case .vga:
            // A 6 × 6 × 6 cube and a grey ramp
            var colours: [[UInt8]] = []
            for r in 0..<6 { for g in 0..<6 { for b in 0..<6 { colours.append([UInt8(r * 51), UInt8(g * 51), UInt8(b * 51)]) } } }
            for i in 0..<40 { colours.append([UInt8(i * 255 / 39), UInt8(i * 255 / 39), UInt8(i * 255 / 39)]) }
            return colours
        case .rgb, .rgba: return []
        }
    }

    /// The nearest colour's number.
    private static func nearest(_ pixel: [UInt8], in palette: [[UInt8]]) -> Int {
        var best = 0, bestDistance = Int.max
        for (i, c) in palette.enumerated() {
            var d = 0
            for k in 0..<3 {
                let delta = Int(pixel[k]) - Int(c[k])
                d += delta * delta
            }
            if d < bestDistance { best = i; bestDistance = d }
        }
        return best
    }

    /// The picture as PCX of `kind` (version 5, run-length encoded unless
    /// `encoded` is false, `extraBytes` of padding per plane line), and the
    /// picture it holds (the reference in its colours: what a decoder must
    /// give back exactly).
    static func pcx(_ picture: RGBA, kind: PCXKind, encoded: Bool = true, extraBytes: Int = 0) -> (data: Data, expected: RGBA) {
        let w = picture.width, h = picture.height
        let bits = kind.bitsPerPlane, planes = kind.planes
        var bytesPerLine = (w * bits + 7) / 8 + extraBytes
        bytesPerLine += bytesPerLine % 2   // even, as ZSoft asks
        let colours = palette(kind)
        var expected = RGBA(width: w, height: h)
        var header = [UInt8](repeating: 0, count: 128)
        header[0] = 0x0A; header[1] = 5; header[2] = encoded ? 1 : 0; header[3] = UInt8(bits)
        func le16(_ at: Int, _ v: Int) { header[at] = UInt8(v & 0xFF); header[at + 1] = UInt8(v >> 8) }
        le16(4, 0); le16(6, 0); le16(8, w - 1); le16(10, h - 1); le16(12, 72); le16(14, 72)
        if kind.bitsPerPlane * kind.planes <= 4, kind != .mono {
            for (i, c) in colours.prefix(16).enumerated() { header[16 + i * 3] = c[0]; header[17 + i * 3] = c[1]; header[18 + i * 3] = c[2] }
        }
        header[65] = UInt8(planes)
        le16(66, bytesPerLine)
        le16(68, 1)
        var body: [UInt8] = []
        for y in 0..<h {
            var line = [UInt8](repeating: 0, count: bytesPerLine * planes)
            for x in 0..<w {
                let px = picture[x, y]
                if kind == .rgb || kind == .rgba {
                    for p in 0..<planes { line[p * bytesPerLine + x] = px[p] }
                    expected[x, y] = [px[0], px[1], px[2], kind == .rgba ? px[3] : 255]
                    continue
                }
                let number = nearest(px, in: colours)
                let c = colours[number]
                expected[x, y] = [c[0], c[1], c[2], 255]
                for p in 0..<planes {
                    let value = (number >> (p * bits)) & ((1 << bits) - 1)
                    let bit = x * bits
                    line[p * bytesPerLine + bit / 8] |= UInt8(value << (8 - bits - bit % 8))
                }
            }
            if encoded {
                // Runs within the row, at most 63
                var i = 0
                while i < line.count {
                    var n = 1
                    while i + n < line.count, line[i + n] == line[i], n < 63 { n += 1 }
                    if n > 1 || line[i] & 0xC0 == 0xC0 { body.append(0xC0 | UInt8(n)) }
                    body.append(line[i])
                    i += n
                }
            } else {
                body += line
            }
        }
        var data = Data(header + body)
        if kind == .vga {
            data.append(12)
            for i in 0..<256 { data.append(contentsOf: i < colours.count ? colours[i] : [0, 0, 0]) }
        }
        return (data, expected)
    }

    /// PCX pages as one DCX.
    static func dcx(_ pages: [Data]) -> Data {
        var out = Data()
        func le32(_ v: Int) { out.append(contentsOf: (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) }) }
        le32(987_654_321)
        var offset = 4 + 4 * (pages.count + 1)
        for page in pages { le32(offset); offset += page.count }
        le32(0)
        for page in pages { out.append(page) }
        return out
    }

    // MARK: RAW

    /// sRGB to linear light, 0 … 1.
    static func linear(_ v: UInt8) -> Double {
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// A Casio QV-2000UX's raw file: no header, 1632 × 1211 samples of 8
    /// bits in a Bayer mosaic, known by its size (1 976 352 bytes; LibRaw's
    /// table of headerless files, "Casio QV-2000UX"), the picture's light
    /// linear. LibRaw shows 1632 × 1208 of it (2 rows on top, 1 below
    /// left out).
    static func casioBay(_ picture: RGBA) -> Data {
        let rw = 1632, rh = 1211, top = 2, height = 1208
        // LibRaw's filters 0x94949494: the colour of row, column
        let filters: UInt32 = 0x9494_9494
        func colour(_ row: Int, _ col: Int) -> Int { Int(filters >> UInt32(((row << 1 & 14) | (col & 1)) << 1) & 3) }
        var data = Data(count: rw * rh)
        for row in 0..<rh {
            let y = min(height - 1, max(0, row - top)) * picture.height / height
            for col in 0..<rw {
                let x = col * picture.width / rw
                let c = colour(row, col)
                let sample = linear(picture[x, y][c == 3 ? 1 : c])
                data[row * rw + col] = UInt8((sample * 255).rounded())
            }
        }
        return data
    }

    /// A DNG of the picture `scale` times as large: 16-bit samples of linear
    /// light in an RGGB Bayer mosaic, the camera's colours sRGB's (its
    /// ColorMatrix1 is the inverse of sRGB's to XYZ), as shot neutral; with
    /// `preview` its first IFD is the picture at its own size in 8-bit RGB
    /// and the raw data a sub-IFD, as cameras write them.
    static func dng(_ picture: RGBA, scale: Int = 2, preview: Bool, make: String = "Schnellbild", model: String = "Test Camera") -> Data {
        let w = picture.width * scale, h = picture.height * scale
        var raw = Data(count: w * h * 2)
        for y in 0..<h {
            for x in 0..<w {
                let px = picture[x / scale, y / scale]
                let c = (y & 1) * 2 + (x & 1)   // R G / G B
                let channel = c == 0 ? 0 : c == 3 ? 2 : 1
                let v = UInt16((linear(px[channel]) * 65535).rounded())
                raw[(y * w + x) * 2] = UInt8(v & 0xFF)
                raw[(y * w + x) * 2 + 1] = UInt8(v >> 8)
            }
        }
        let inverse: [Double] = [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252]
        var tiff = TIFFWriter()
        let modelName = make + " " + model
        let dngTags: [TIFFWriter.Entry] = [
            .ascii(271, make), .ascii(272, model), .short(274, [1]),
            .bytes(50706, [1, 4, 0, 0]), .ascii(50708, modelName),
            .srational(50721, inverse.map { (Int32(($0 * 10000).rounded()), 10000) }),
            .rational(50728, [(1, 1), (1, 1), (1, 1)]), .short(50778, [21]),
        ]
        let rawTags: [TIFFWriter.Entry] = [
            .long(254, [0]), .long(256, [w]), .long(257, [h]), .short(258, [16]), .short(259, [1]), .short(262, [32803]),
            .short(277, [1]), .long(278, [h]), .short(284, [1]), .short(33421, [2, 2]), .bytes(33422, [0, 1, 1, 2]),
            .long(50714, [0]), .long(50717, [65535]),
        ]
        if preview {
            var rgb = Data(count: picture.width * picture.height * 3)
            for i in 0..<picture.width * picture.height {
                for c in 0..<3 { rgb[i * 3 + c] = picture.pixels[i * 4 + c] }
            }
            let previewTags: [TIFFWriter.Entry] = [
                .long(254, [1]), .long(256, [picture.width]), .long(257, [picture.height]), .short(258, [8, 8, 8]), .short(259, [1]),
                .short(262, [2]), .short(277, [3]), .long(278, [picture.height]), .short(284, [1]),
            ]
            tiff.add(ifd: previewTags + dngTags, strip: rgb, subIFDs: [(rawTags, raw)])
        } else {
            tiff.add(ifd: rawTags + dngTags, strip: raw, subIFDs: [])
        }
        return tiff.data
    }

    /// A little-endian TIFF of one IFD (and its sub-IFDs), each with one
    /// strip; entries sorted by tag as TIFF asks.
    struct TIFFWriter {
        enum Entry {
            case bytes(UInt16, [UInt8])
            case ascii(UInt16, String)
            case short(UInt16, [Int])
            case long(UInt16, [Int])
            case rational(UInt16, [(UInt32, UInt32)])
            case srational(UInt16, [(Int32, Int32)])

            var tag: UInt16 {
                switch self {
                case .bytes(let t, _), .ascii(let t, _), .short(let t, _), .long(let t, _), .rational(let t, _), .srational(let t, _): return t
                }
            }

            /// Type, count and value bytes.
            var encoded: (type: UInt16, count: Int, bytes: [UInt8]) {
                func le(_ v: UInt32, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(v >> (8 * UInt32($0)) & 0xFF) } }
                switch self {
                case .bytes(_, let v): return (1, v.count, v)
                case .ascii(_, let s): let b = Array(s.utf8) + [0]; return (2, b.count, b)
                case .short(_, let v): return (3, v.count, v.flatMap { le(UInt32($0), 2) })
                case .long(_, let v): return (4, v.count, v.flatMap { le(UInt32($0), 4) })
                case .rational(_, let v): return (5, v.count, v.flatMap { le($0.0, 4) + le($0.1, 4) })
                case .srational(_, let v): return (10, v.count, v.flatMap { le(UInt32(bitPattern: $0.0), 4) + le(UInt32(bitPattern: $0.1), 4) })
                }
            }
        }

        private(set) var data = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])

        private mutating func le32(_ v: Int, at: Int) {
            for i in 0..<4 { data[at + i] = UInt8(v >> (8 * i) & 0xFF) }
        }

        /// Appends the IFD at the end, its strip and sub-IFDs after it;
        /// returns its offset.
        @discardableResult
        mutating func add(ifd entries: [Entry], strip: Data, subIFDs: [([Entry], Data)], first: Bool = true) -> Int {
            var all = entries
            all.append(.long(273, [0]))
            all.append(.long(279, [strip.count]))
            if !subIFDs.isEmpty { all.append(.long(330, [0])) }
            all.sort { $0.tag < $1.tag }
            if data.count % 2 == 1 { data.append(0) }
            let start = data.count
            if first { le32(start, at: 4) }
            data.append(contentsOf: [UInt8(all.count & 0xFF), UInt8(all.count >> 8)])
            var fixups: [(at: Int, bytes: [UInt8])] = []
            var stripAt = 0, subAt = 0
            for entry in all {
                let e = entry.encoded
                data.append(contentsOf: [UInt8(entry.tag & 0xFF), UInt8(entry.tag >> 8), UInt8(e.type & 0xFF), UInt8(e.type >> 8)])
                data.append(contentsOf: (0..<4).map { UInt8(e.count >> (8 * $0) & 0xFF) })
                let valueAt = data.count
                if entry.tag == 273 { stripAt = valueAt }
                if entry.tag == 330 { subAt = valueAt }
                if e.bytes.count <= 4 {
                    data.append(contentsOf: e.bytes + [UInt8](repeating: 0, count: 4 - e.bytes.count))
                } else {
                    data.append(contentsOf: [0, 0, 0, 0])
                    fixups.append((valueAt, e.bytes))
                }
            }
            data.append(contentsOf: [0, 0, 0, 0])   // no next IFD
            for fixup in fixups {
                if data.count % 2 == 1 { data.append(0) }
                le32(data.count, at: fixup.at)
                data.append(contentsOf: fixup.bytes)
            }
            if data.count % 2 == 1 { data.append(0) }
            le32(data.count, at: stripAt)
            data.append(strip)
            for (subEntries, subStrip) in subIFDs {
                let offset = add(ifd: subEntries, strip: subStrip, subIFDs: [], first: false)
                le32(offset, at: subAt)
            }
            return start
        }
    }

    // MARK: Contact sheet

    /// Rows of pictures with a label each, on a light grey ground: what the
    /// tests decoded beside the reference, to look at.
    static func contactSheet(_ rows: [(label: String, pictures: [(caption: String, image: CGImage)])], cell: Int = 220) -> CGImage {
        let labelWidth = 200, pad = 12, caption = 16
        let columns = rows.map(\.pictures.count).max() ?? 1
        let width = labelWidth + columns * (cell + pad) + pad
        let rowHeight = cell + caption + pad
        let height = rows.count * rowHeight + pad
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ string: String, at point: CGPoint, size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        for (r, row) in rows.enumerated() {
            let top = height - pad - r * rowHeight
            text(row.label, at: CGPoint(x: pad, y: top - cell / 2), size: 13)
            for (c, picture) in row.pictures.enumerated() {
                let x = labelWidth + c * (cell + pad)
                // A checkerboard behind, so transparency shows
                let box = CGRect(x: x, y: top - cell, width: cell, height: cell)
                for i in 0..<(cell / 10) {
                    for j in 0..<(cell / 10) where (i + j) % 2 == 0 {
                        context.setFillColor(CGColor(gray: 0.75, alpha: 1))
                        context.fill(CGRect(x: x + i * 10, y: top - cell + j * 10, width: 10, height: 10))
                    }
                }
                let image = picture.image
                let fit = min(CGFloat(cell) / CGFloat(image.width), CGFloat(cell) / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
                text(picture.caption, at: CGPoint(x: x, y: top - cell - caption + 3), size: 11)
            }
        }
        return context.makeImage()!
    }
}
