import Foundation
import ImageIO
import UniformTypeIdentifiers
import VLCFrames

/// Pictures macOS doesn't draw that carry a picture of themselves, shown
/// through ImageIO like any picture, never by running them:
/// - PostScript (EPS, PS, Illustrator files without PDF content): macOS 14
///   and later convert no PostScript, and a PostScript interpreter is a
///   program run on the file, so the preview the file carries is shown: a
///   DOS EPS's TIFF (Adobe TN 5002, "DOS EPS Binary File Header"), an XMP
///   thumbnail (`xmpGImg:image`, a base64 JPEG, as Illustrator writes it)
///   or an EPSI preview (TN 5002, "Device-Independent Screen Preview":
///   hexadecimal rows in comments, 0 white). A WMF preview isn't shown:
///   nothing in macOS draws WMF.
/// - ZIP documents that hold a picture of their content (Krita, OpenRaster,
///   Procreate, Sketch), read from the ZIP with the system's libarchive.
/// - Netpbm's binary bitmap (P4), which ImageIO doesn't read: its bits
///   become a grey Netpbm picture (P5), which ImageIO reads.
/// Everything is read with checked offsets and lengths, at most
/// `ArchiveStore.largestRead` bytes of a file.
enum EmbeddedPreview {
    /// PostScript files: shown by the preview they carry.
    nonisolated static let postScriptExtensions: Set<String> = ["eps", "epsf", "epsi", "epi", "ps"]
    /// ZIP documents and the entries that hold their picture, the first one
    /// there wins: Krita's `mergedimage.png` (the whole picture) before its
    /// `preview.png`; OpenRaster's (the format Krita, GIMP and MyPaint
    /// exchange) `mergedimage.png` before `Thumbnails/thumbnail.png`;
    /// Procreate's `QuickLook/Thumbnail.png`; Sketch's `previews/preview.png`.
    nonisolated static let zipEntries: [String: [String]] = [
        "kra": ["mergedimage.png", "preview.png"],
        "ora": ["mergedimage.png", "Thumbnails/thumbnail.png"],
        "procreate": ["QuickLook/Thumbnail.png"],
        "sketch": ["previews/preview.png"],
    ]
    /// Every extension shown by a preview or (Illustrator) as a PDF.
    nonisolated static let extensions: Set<String> = postScriptExtensions.union(zipEntries.keys).union(["ai"])

    /// Whether such a file is a picture, without touching the disk (asked
    /// by `BrowserModel.mediaKind` on the main thread too). On disk by what
    /// its first bytes showed, read off the main thread by the listing
    /// (`ContentSniffer`, `sniffOtherFiles`: until then it is another file,
    /// then the folder is listed again) and kept by path, size and date.
    /// Inside an archive (no first bytes without unpacking) the name
    /// decides, except for ".ps" (mostly print jobs without a preview) and
    /// the ZIP documents (libarchive reads them from a file only).
    nonisolated static func isPicture(_ url: URL, ext: String) -> Bool {
        if ArchivePath.isInside(url) { return ext == "ai" || (postScriptExtensions.contains(ext) && ext != "ps") }
        return ContentSniffer.shared.known(url)?.mediaKind == .image
    }

    /// Shown through `picture(_:)` (its preview), not by ImageIO from the
    /// file itself: PostScript, the ZIP documents, a Netpbm bitmap.
    nonisolated static func showsPreview(_ url: URL) -> Bool {
        let ext = DownloadName.finalExtension(of: url)
        return (postScriptExtensions.contains(ext) || zipEntries[ext] != nil) || ext == "pbm" || codeStreamExtensions.contains(ext)
            || (ext == "astc" && ASTCRows.imageIOReadsFromTheBottom)
    }

    /// JPEG 2000 code streams without the JP2 file around them: macOS 15's
    /// ImageIO reads none (macOS 26's does), so they are wrapped in one.
    nonisolated static let codeStreamExtensions: Set<String> = ["j2c", "j2k"]

    /// Whether the Inspector names the picture shown a preview (not the
    /// Netpbm bitmap, which is shown whole).
    nonisolated static func isPreview(_ url: URL) -> Bool {
        let ext = DownloadName.finalExtension(of: url)
        return postScriptExtensions.contains(ext) || zipEntries[ext] != nil
    }

    /// The image source of the picture shown for such a file, and the bytes
    /// it holds in memory.
    static func picture(_ url: URL) async -> (source: CGImageSource, inMemory: Int)? {
        let ext = DownloadName.finalExtension(of: url)
        let bytes: Data?
        if let entries = zipEntries[ext] {
            guard !ArchivePath.isInside(url) else { return nil }
            bytes = await Blocking.run(.userInitiated) { zipEntry(entries, of: url) }
        } else {
            guard let data = try? await MediaData.read(url) else { return nil }
            if ext == "pbm" {
                bytes = netpbmBitmap(data) ?? data
            } else if ext == "astc" {
                bytes = ASTCRows.upright(data) ?? data
            } else if codeStreamExtensions.contains(ext) {
                bytes = jpeg2000File(around: data) ?? data   // a JP2 file under such a name stays as it is
            } else {
                bytes = previewData(in: data)
            }
        }
        guard let bytes, !Task.isCancelled, let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        return (source, bytes.count)
    }

    // MARK: PostScript

    /// The picture a PostScript file (or an Illustrator file without PDF
    /// content) carries, as bytes ImageIO reads: a DOS EPS's TIFF, else the
    /// XMP thumbnail (in colour), else the EPSI preview (grey).
    static func previewData(in data: Data) -> Data? {
        if let tiff = dosTIFF(in: data) { return tiff }
        if let jpeg = xmpThumbnail(in: data) { return jpeg }
        return epsiPreview(in: data)
    }

    /// The 30-byte header of a DOS EPS file: C5D0D3C6, then the PostScript's,
    /// the WMF's and the TIFF's offset and length (little endian). `size`:
    /// the file's, when `data` is only its start.
    static func dosHeader(_ data: Data, size: Int? = nil) -> (tiff: Range<Int>?, wmf: Range<Int>?)? {
        let size = size ?? data.count
        let b = data.startIndex
        guard data.count >= 30, data[b] == 0xC5, data[b + 1] == 0xD0, data[b + 2] == 0xD3, data[b + 3] == 0xC6 else { return nil }
        func le32(_ at: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(data[b + at + $1]) << (8 * $1) }
        }
        func range(_ offset: Int, _ length: Int) -> Range<Int>? {
            // Inside the file and after the header, else none
            guard length > 0, offset >= 30, offset <= size, length <= size - offset else { return nil }
            return offset..<offset + length
        }
        return (range(le32(20), le32(24)), range(le32(12), le32(16)))
    }

    static func dosTIFF(in data: Data) -> Data? {
        guard let range = dosHeader(data)?.tiff else { return nil }
        let start = data.startIndex
        return data.subdata(in: start + range.lowerBound..<start + range.upperBound)
    }

    /// The largest XMP thumbnail looked at (base64 characters).
    static let largestThumbnail = 16 << 20

    /// The first XMP thumbnail (`xmpGImg:image`, as an element or an
    /// attribute) that ImageIO reads as a picture.
    static func xmpThumbnail(in data: Data) -> Data? {
        let marker = Data("xmpGImg:image".utf8)
        var from = data.startIndex
        while let found = data.range(of: marker, in: from..<data.endIndex) {
            from = found.upperBound
            // `<xmpGImg:image>…<` or `xmpGImg:image="…"`; the closing tag's
            // own name (`</xmpGImg:image>`) is passed over
            guard found.upperBound < data.endIndex else { break }
            let opener = data[found.upperBound]
            let end: UInt8
            var start = found.upperBound + 1
            if opener == UInt8(ascii: ">") {
                end = UInt8(ascii: "<")
            } else if opener == UInt8(ascii: "="), start < data.endIndex, data[start] == UInt8(ascii: "\"") || data[start] == UInt8(ascii: "'") {
                end = data[start]
                start += 1
            } else { continue }
            let limit = min(data.endIndex, start + largestThumbnail)
            guard let close = data[start..<limit].firstIndex(of: end) else { continue }
            let text = String(decoding: data[start..<close], as: UTF8.self)
                .replacingOccurrences(of: "&#xA;", with: "").replacingOccurrences(of: "&#xD;", with: "")
                .replacingOccurrences(of: "&#10;", with: "").replacingOccurrences(of: "&#13;", with: "")
            guard let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters), !decoded.isEmpty,
                  let source = CGImageSourceCreateWithData(decoded as CFData, nil), CGImageSourceGetCount(source) > 0 else { continue }
            return decoded
        }
        return nil
    }

    /// The largest EPSI preview decoded (pixels).
    static let largestPreviewPixels = 64_000_000

    /// An EPSI preview (`%%BeginPreview: width height depth lines`, then
    /// hexadecimal in comment lines up to `%%EndPreview`, rows from the
    /// top, 0 white) as a grey Netpbm picture.
    static func epsiPreview(in data: Data) -> Data? {
        guard let found = data.range(of: Data("%%BeginPreview:".utf8)) else { return nil }
        guard let lineEnd = data[found.upperBound...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return nil }
        let numbers = String(decoding: data[found.upperBound..<lineEnd], as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        let width = numbers[0], height = numbers[1], depth = numbers[2]
        guard width > 0, height > 0, [1, 2, 4, 8].contains(depth),
              width <= largestPreviewPixels / height else { return nil }
        let bytesPerRow = (width * depth + 7) / 8
        let needed = bytesPerRow * height
        var bits = [UInt8]()
        bits.reserveCapacity(needed)
        var high: UInt8?
        var atLineStart = true, inComment = false
        scan: for byte in data[lineEnd...] {
            if byte == 0x0A || byte == 0x0D { atLineStart = true; inComment = false; continue }
            if atLineStart {
                atLineStart = false
                // "%%EndPreview" ends it; every line of data begins with "%"
                if byte != UInt8(ascii: "%") { break scan }
                inComment = true
                continue
            }
            guard inComment else { continue }
            if byte == UInt8(ascii: "%") { break scan }
            guard let nibble = hexValue(byte) else { continue }
            if let h = high {
                bits.append(h << 4 | nibble)
                high = nil
                if bits.count == needed { break scan }
            } else {
                high = nibble
            }
        }
        guard bits.count == needed else { return nil }
        let maximum = (1 << depth) - 1
        var grey = [UInt8]()
        grey.reserveCapacity(width * height)
        for row in 0..<height {
            for x in 0..<width {
                let bit = x * depth
                let byte = bits[row * bytesPerRow + bit / 8]
                let value = Int(byte >> (8 - depth - bit % 8)) & maximum
                grey.append(UInt8(255 - value * 255 / maximum))
            }
        }
        return Data("P5\n\(width) \(height)\n255\n".utf8) + Data(grey)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: Netpbm

    /// A binary Netpbm bitmap (P4: width and height, then each row's bits
    /// padded to whole bytes, 1 black) as a grey Netpbm picture (P5); nil
    /// for any other Netpbm picture (ImageIO reads those itself).
    static func netpbmBitmap(_ data: Data) -> Data? {
        let b = data.startIndex
        guard data.count > 2, data[b] == UInt8(ascii: "P"), data[b + 1] == UInt8(ascii: "4") else { return nil }
        // The two numbers after the magic, with comments ("#" to the line's end) between
        var at = b + 2
        var numbers: [Int] = []
        while numbers.count < 2, at < data.endIndex {
            let byte = data[at]
            if byte == UInt8(ascii: "#") {
                while at < data.endIndex, data[at] != 0x0A, data[at] != 0x0D { at += 1 }
            } else if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                var value = 0
                while at < data.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(data[at]) {
                    value = value * 10 + Int(data[at] - UInt8(ascii: "0"))
                    guard value <= 1_000_000 else { return nil }
                    at += 1
                }
                numbers.append(value)
                continue
            } else if ![0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C].contains(byte) {
                return nil
            }
            at += 1
        }
        // One whitespace character before the bits
        guard numbers.count == 2, at < data.endIndex else { return nil }
        at += 1
        let width = numbers[0], height = numbers[1]
        guard width > 0, height > 0, width <= largestPreviewPixels / height else { return nil }
        let bytesPerRow = (width + 7) / 8
        guard data.endIndex - at >= bytesPerRow * height else { return nil }
        var grey = [UInt8]()
        grey.reserveCapacity(width * height)
        for row in 0..<height {
            let start = at + row * bytesPerRow
            for x in 0..<width {
                grey.append(data[start + x / 8] & (0x80 >> UInt8(x % 8)) != 0 ? 0 : 255)
            }
        }
        return Data("P5\n\(width) \(height)\n255\n".utf8) + Data(grey)
    }

    // MARK: ASTC

    /// ASTC textures (".astc", as ARM's astcenc writes them: the blocks row
    /// by row from the top). ImageIO on macOS 15 and 26 reads the rows from
    /// the bottom (its own writer writes them so), macOS 27's from the top;
    /// which one this Mac's does is tried once on a texture of two blocks,
    /// white over black, and where it reads them from the bottom the
    /// picture is turned upright here.
    enum ASTCRows {
        static let imageIOReadsFromTheBottom: Bool = {
            // 4 × 8 pixels, blocks of 4 × 4: void-extent blocks (one colour each, UNORM16)
            var bytes: [UInt8] = [0x13, 0xAB, 0xA1, 0x5C, 4, 4, 1, 4, 0, 0, 8, 0, 0, 1, 0, 0]
            for grey: UInt8 in [0xFF, 0x00] {
                bytes += [0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: grey, count: 6) + [0xFF, 0xFF]
            }
            guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: 4, height: 8, bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 8))
            guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
            // The context's memory runs from the top: the first block white there when read from the top
            return pixels[0] < 128 && pixels[16 * 7] > 128
        }()

        /// The texture decoded and turned upright, as PNG; nil when ImageIO
        /// doesn't read it.
        static func upright(_ data: Data) -> Data? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let space = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let output = NSMutableData()
            guard let turned = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, turned, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
    }

    // MARK: JPEG 2000

    /// A JPEG 2000 code stream (ISO/IEC 15444-1 annex A: SOC FF4F, then the
    /// SIZ marker FF51 with the picture's size and components) inside the
    /// boxes of a JP2 file (annex I): signature, file type, header (image
    /// header, colour: sRGB or grey), the code stream. nil when the data
    /// isn't a code stream or its SIZ marker is short.
    static func jpeg2000File(around data: Data) -> Data? {
        let bytes = [UInt8](data.prefix(64))
        guard bytes.count >= 42, bytes[0] == 0xFF, bytes[1] == 0x4F, bytes[2] == 0xFF, bytes[3] == 0x51 else { return nil }
        func be32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        // After SIZ's marker: Lsiz, Rsiz, Xsiz, Ysiz, XOsiz, YOsiz, the tiles' four, Csiz, then each component's Ssiz
        let width = be32(8) - be32(16), height = be32(12) - be32(20)
        let components = Int(bytes[40]) << 8 | Int(bytes[41])
        guard width > 0, height > 0, components > 0, components < 16_384, bytes.count > 42 else { return nil }
        let depth = bytes[42]   // bits less one, high bit: signed
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = 8 + payload.count
            return [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + Array(type.utf8) + payload
        }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let header = box("ihdr", u32(height) + u32(width) + [UInt8(components >> 8), UInt8(components & 0xFF), depth, 7, 0, 0])
            + box("colr", [1, 0, 0] + u32(components >= 3 ? 16 : 17))
        var file = box("jP  ", [0x0D, 0x0A, 0x87, 0x0A]) + box("ftyp", Array("jp2 ".utf8) + u32(0) + Array("jp2 ".utf8))
        file += box("jp2h", header)
        let length = 8 + data.count
        guard length <= Int(UInt32.max) else { return nil }
        file += u32(length) + Array("jp2c".utf8)
        return Data(file) + data
    }

    // MARK: ZIP documents

    /// The first of `entries` the ZIP holds, read whole (at most
    /// `ArchiveStore.largestRead` bytes). Off the main thread: it reads the disk.
    nonisolated static func zipEntry(_ entries: [String], of url: URL) -> Data? {
        let reader = LibArchiveReader(volumes: [url], format: .zip)
        for entry in entries {
            var data = Data()
            var tooLarge = false
            let failure: ArchiveError?
            do {
                // nil: read whole
                failure = try reader.readEntry(entry, password: nil) { chunk in
                    guard data.count + chunk.count <= ArchiveStore.largestRead else { tooLarge = true; return false }
                    data.append(contentsOf: chunk)
                    return true
                }
            } catch { continue }
            if failure == nil, !tooLarge, !data.isEmpty { return data }
        }
        return nil
    }

    // MARK: First bytes

    /// How much of a PostScript file is looked through for its preview: an
    /// EPSI preview follows the header comments, the XMP packet of
    /// Illustrator's EPS and AI files lies near their start.
    static let lookedAt = 256 << 10

    /// What such a file (`extensions`) holds for the app, by its first
    /// bytes: a picture (an Illustrator file with a PDF inside, a ZIP
    /// document, a PostScript file with a preview) or nil (another file).
    /// Reads the disk: only `ContentSniffer.content(of:)` asks, off the main
    /// thread.
    static func content(of url: URL, ext: String, size: Int) -> FileFacts.Content? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512), head.count >= 4 else { return nil }
        let picture = FileFacts.Content(kind: .picture, fileExtension: ext, name: FileFacts.formatName(ofExtension: ext))
        if zipEntries[ext] != nil { return head.starts(with: [0x50, 0x4B, 0x03, 0x04]) ? picture : nil }
        if ext == "ai", head.starts(with: Data("%PDF".utf8)) { return picture }
        if let dos = dosHeader(head, size: size) { return dos.tiff != nil ? picture : nil }
        guard head.starts(with: Data("%!PS".utf8)) else { return nil }
        let rest = (try? handle.read(upToCount: lookedAt - head.count)) ?? Data()
        let start = head + rest
        let carries = start.range(of: Data("%%BeginPreview:".utf8)) != nil || start.range(of: Data("xmpGImg:image".utf8)) != nil
        return carries ? picture : nil
    }
}
