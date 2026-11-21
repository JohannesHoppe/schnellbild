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

    /// The picture formats Schnellbild shows through this path or as a PDF
    /// that `BrowserModel.mediaKind` decides by the file's first bytes.
    /// Inside an archive (no first bytes without unpacking) the name
    /// decides, except for ".ps" (mostly print jobs without a preview) and
    /// the ZIP documents (libarchive reads them from a file only).
    nonisolated static func isPicture(_ url: URL, ext: String) -> Bool {
        if ArchivePath.isInside(url) { return ext == "ai" || (postScriptExtensions.contains(ext) && ext != "ps") }
        return probes.shows(url, ext: ext)
    }

    /// Shown through `picture(_:)` (its preview), not by ImageIO from the
    /// file itself: PostScript, the ZIP documents, a Netpbm bitmap.
    nonisolated static func showsPreview(_ url: URL) -> Bool {
        let ext = DownloadName.finalExtension(of: url)
        return (postScriptExtensions.contains(ext) || zipEntries[ext] != nil) || ext == "pbm"
    }

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
            bytes = ext == "pbm" ? (netpbmBitmap(data) ?? data) : previewData(in: data)
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

    /// What a file's first bytes say about showing it, read once and kept by
    /// path, size and date (as `ContentSniffer` does).
    nonisolated private static let probes = Probes()

    final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: (stamp: String, shows: Bool)] = [:]

        /// How much of a PostScript file is looked through for its preview:
        /// an EPSI preview follows the header comments, the XMP packet of
        /// Illustrator's EPS and AI files lies near their start.
        static let lookedAt = 256 << 10

        func shows(_ url: URL, ext: String) -> Bool {
            var info = stat()
            guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
            let stamp = "\(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            let path = BrowserModel.canonicalPath(url)
            if let known = lock.withLock({ answers[path] }), known.stamp == stamp { return known.shows }
            let shows = Self.probe(url, ext: ext, size: Int(info.st_size))
            lock.withLock {
                if answers.count >= 20_000 { answers.removeAll(keepingCapacity: true) }
                answers[path] = (stamp, shows)
            }
            return shows
        }

        /// An Illustrator file with a PDF inside (shown as a PDF), a ZIP
        /// document, or a PostScript file with a preview.
        private static func probe(_ url: URL, ext: String, size: Int) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 512), head.count >= 4 else { return false }
            if zipEntries[ext] != nil { return head.starts(with: [0x50, 0x4B, 0x03, 0x04]) }
            if ext == "ai", head.starts(with: Data("%PDF".utf8)) { return true }
            if let dos = dosHeader(head, size: size) { return dos.tiff != nil }
            guard head.starts(with: Data("%!PS".utf8)) else { return false }
            let rest = (try? handle.read(upToCount: lookedAt - head.count)) ?? Data()
            let start = head + rest
            return start.range(of: Data("%%BeginPreview:".utf8)) != nil || start.range(of: Data("xmpGImg:image".utf8)) != nil
        }
    }
}
