import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CRaw

/// Pictures the app decodes itself, for formats macOS doesn't read: QOI and
/// PCX / DCX (`QOIDecoder`, `PCXDecoder`) and camera RAW formats ImageIO
/// doesn't read, through LibRaw (`RawDecoder`). Each comes back as an image
/// source of an uncompressed TIFF in memory, so every path that shows a
/// picture (tiles, full view, Inspector, slideshow, Atlas) takes it as it
/// takes any other. The bytes are read as any picture's (`MediaData.read`:
/// from disk or an archive, at most `ArchiveStore.largestRead`).
enum PictureDecoders {
    enum Format: Equatable {
        case qoi, pcx, dcx, raw
    }

    /// What the Inspector names: the format and its bits per sample.
    struct Facts: Equatable, Sendable {
        let format: String
        let depth: Int?
    }

    /// Extensions the app's own decoders read.
    nonisolated static let ownExtensions: Set<String> = ["qoi", "pcx", "dcx"]

    /// Every extension shown through `picture(_:)`: the app's own formats
    /// and the RAW formats LibRaw reads where ImageIO doesn't.
    nonisolated static let extensions: Set<String> = ownExtensions.union(RawDecoder.extensions)

    /// The format a file is decoded as: by its name, or by what its
    /// first bytes showed (a QOI file without an extension).
    nonisolated static func format(of url: URL) -> Format? {
        switch BrowserModel.shownExtension(of: url) {
        case "qoi": return .qoi
        case "pcx": return .pcx
        case "dcx": return .dcx
        case let ext where RawDecoder.extensions.contains(ext): return .raw
        default: return nil
        }
    }

    nonisolated static func decodes(_ url: URL) -> Bool { format(of: url) != nil }

    /// The picture as an image source, and the bytes it holds in memory.
    /// Kept for the last few files (`Kept`): the tile, the full view and
    /// the Inspector of one file decode it once.
    static func picture(_ url: URL) async -> (source: CGImageSource, inMemory: Int)? {
        guard let format = format(of: url) else { return nil }
        let stamp = await Blocking.run(.userInitiated) { Kept.stamp(of: url) }
        if let kept = Kept.shared.find(url, stamp: stamp) { return (kept.source, kept.bytes) }
        guard let data = try? await MediaData.read(url), !Task.isCancelled else { return nil }
        let decoded: Decoded?
        switch format {
        case .qoi:
            decoded = await Blocking.run(.userInitiated) { ownDecoded(QOIDecoder.decode(data), format: "QOI (Quite OK Image)", depth: 8) }
        case .pcx, .dcx:
            decoded = await Blocking.run(.userInitiated) { () -> Decoded? in
                guard let page = format == .dcx ? PCXDecoder.firstDCXPage(data) : data, let header = PCXDecoder.header(page) else { return nil }
                let name = format == .dcx ? "DCX (ZSoft, multi-page PCX)" : "PCX (ZSoft)"
                return ownDecoded(PCXDecoder.decode(page), format: name, depth: header.isDirectColour ? 8 : header.bitsPerPixel)
            }
        case .raw:
            decoded = await RawDecoder.developed(data, named: url, half: false)
        }
        guard let decoded, !Task.isCancelled else { return nil }
        Kept.shared.keep(url, stamp: stamp, decoded)
        return (decoded.source, decoded.bytes)
    }

    /// The decoder's facts of a file decoded lately (the Inspector reads
    /// them after the picture).
    nonisolated static func facts(of url: URL) -> Facts? {
        Kept.shared.facts(of: url)
    }

    /// A picture decoded and its facts.
    struct Decoded: @unchecked Sendable {
        let source: CGImageSource
        let bytes: Int
        let facts: Facts
    }

    private static func ownDecoded(_ picture: DecodedPicture?, format: String, depth: Int) -> Decoded? {
        guard let picture, let image = picture.image(),
              let wrapped = source(of: image, properties: [:]) else { return nil }
        return Decoded(source: wrapped.source, bytes: wrapped.bytes, facts: Facts(format: format, depth: depth))
    }

    /// `image` as the image source of an uncompressed TIFF in memory, with
    /// `properties` (orientation, EXIF, TIFF, GPS) written into it.
    static func source(of image: CGImage, properties: [CFString: Any]) -> (source: CGImageSource, bytes: Int)? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return (source, data.length)
    }

    /// The last pictures decoded, by file (path, size and date; inside an
    /// archive the archive's), at most `limit` of them and `largestBytes`
    /// in all.
    final class Kept: @unchecked Sendable {
        static let shared = Kept()
        private let lock = NSLock()
        private var items: [(path: String, stamp: String, decoded: Decoded)] = []
        let limit = 4
        let largestBytes = 512 << 20

        static func stamp(of url: URL) -> String {
            let file = ArchivePath.split(url)?.archive ?? url
            var info = stat()
            guard stat(file.path, &info) == 0 else { return "" }
            return "\(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }

        func find(_ url: URL, stamp: String) -> Decoded? {
            let path = BrowserModel.canonicalPath(url)
            return lock.withLock { items.first { $0.path == path && $0.stamp == stamp }?.decoded }
        }

        func facts(of url: URL) -> Facts? {
            let path = BrowserModel.canonicalPath(url)
            return lock.withLock { items.first { $0.path == path }?.decoded.facts }
        }

        func keep(_ url: URL, stamp: String, _ decoded: Decoded) {
            let path = BrowserModel.canonicalPath(url)
            lock.withLock {
                items.removeAll { $0.path == path }
                items.insert((path, stamp, decoded), at: 0)
                var total = 0
                items = Array(items.prefix(limit)).filter { item in
                    total += item.decoded.bytes
                    return total <= largestBytes || item.path == path
                }
            }
        }
    }
}

/// Camera RAW formats ImageIO doesn't read, read with LibRaw (`Native/CRaw`,
/// the source vendored by `Scripts/fetch_libraw.sh`): tiles from the
/// preview the file carries, the full view from the raw data developed
/// (camera white balance, sRGB). LibRaw reads files from others in the
/// app's process, so it gets only bytes already in memory (at most
/// `ArchiveStore.largestRead`), its own memory limit (`limits`), pictures
/// of at most `DecodedPicture.largestPixels` (larger ones developed at half
/// size), two developed at a time, each cancelled with its task. Files
/// ImageIO reads (its RAW formats) go to LibRaw only when ImageIO decodes
/// no picture of them (a camera newer than this macOS): `fallback`.
enum RawDecoder {
    /// RAW formats LibRaw reads that ImageIO names no type for (on macOS 15
    /// and 26, `SystemFormatsTests`): Casio, Phase One's older captures,
    /// Kodak, Minolta's RD175, Mamiya, Pentax's Optio, Logitech's Fotoman,
    /// Apple's QuickTake, Sinar, and Olympus' ".ori" where ImageIO doesn't
    /// read it (macOS 15).
    nonisolated static let librawOnly: Set<String> = [
        "bay", "cap", "dcs", "drf", "k25", "kdc", "mdc", "mef", "ptx", "pxn", "qtk", "sti", "ori",
    ]

    /// Those of them this macOS's ImageIO doesn't read.
    nonisolated static let extensions: Set<String> = librawOnly.filter { !BrowserModel.imageIOReads($0) }

    /// The camera RAW formats ImageIO reads: LibRaw is asked for them only
    /// when ImageIO gives no picture.
    nonisolated static let imageIOExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nefx", "nrw", "arw", "axr", "sr2", "srf", "dng", "raf", "orf",
        "rw2", "rwl", "raw", "pef", "srw", "3fr", "fff", "erf", "dcr", "mos", "mrw", "iiq", "dxo",
    ]

    nonisolated static let limits = SBRawLimits(max_raw_memory_mb: 1024, max_pixels: Int64(DecodedPicture.largestPixels))

    /// At most two files developed at once (each may take hundreds of MB).
    private static let developing: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LibRaw"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// A flag LibRaw polls; set when the task waiting for it is cancelled.
    private final class Cancel: @unchecked Sendable {
        let flag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        init() { flag.initialize(to: 0) }
        deinit { flag.deallocate() }
    }

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable (UnsafePointer<Int32>) -> T) async -> T {
        let cancel = Cancel()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { answer in
                developing.addOperation { answer.resume(returning: work(UnsafePointer(cancel.flag))) }
            }
        } onCancel: {
            cancel.flag.pointee = 1
        }
    }

    /// LibRaw's facts of a file's headers.
    static func facts(_ data: Data) -> SBRawFacts? {
        var facts = SBRawFacts()
        let status = data.withUnsafeBytes { sb_raw_facts($0.baseAddress, $0.count, limits, &facts) }
        return status == 0 ? facts : nil
    }

    /// The raw data developed (at half size with `half`, or when the full
    /// size has more pixels than allowed), as an image source with the
    /// file's facts (camera, exposure, time, place) written in.
    static func developed(_ data: Data, named url: URL, half: Bool) async -> PictureDecoders.Decoded? {
        await onQueue { cancel -> PictureDecoders.Decoded? in
            guard let info = facts(data) else { return nil }
            let pixels = Int64(info.width) * Int64(info.height)
            let halfSize = half || pixels > limits.max_pixels
            var picture = SBRawPicture()
            let status = data.withUnsafeBytes { sb_raw_develop($0.baseAddress, $0.count, limits, halfSize ? 1 : 0, cancel, &picture) }
            guard status == 0 else { return nil }
            defer { sb_raw_free(&picture) }
            // Developed upright: no orientation of its own
            guard let image = bitmap(picture),
                  let wrapped = PictureDecoders.source(of: image, properties: properties(info, orientation: 1)) else { return nil }
            return PictureDecoders.Decoded(source: wrapped.source, bytes: wrapped.bytes, facts: Self.facts(of: url, info))
        }
    }

    /// The preview the file carries, at most about `maxPixel` on its
    /// longest side, upright; nil without one, or with one that wouldn't
    /// make a good tile, where developing the raw data at half size gives a
    /// better one: less than half as large as asked (an old camera's 80 × 60
    /// thumbnail), grey (Kodak's P712 carries a grey JPEG), or a bitmap
    /// outside a DNG (a Sinarback's comes out green; a DNG's bitmap preview
    /// is the picture rendered, as the DNG specification has it).
    static func preview(_ data: Data, maxPixel: Int, allowBitmap: Bool) async -> CGImage? {
        await onQueue { _ -> CGImage? in
            guard let info = facts(data) else { return nil }
            var picture = SBRawPicture()
            let status = data.withUnsafeBytes { sb_raw_thumbnail($0.baseAddress, $0.count, limits, 0, &picture) }
            guard status == 0 else { return nil }
            defer { sb_raw_free(&picture) }
            let image: CGImage?
            if picture.kind == 1 {
                // JPEG or JPEG XL, read by ImageIO
                let bytes = Data(bytes: picture.data, count: picture.size)
                image = CGImageSourceCreateWithData(bytes as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            } else {
                image = allowBitmap ? bitmap(picture) : nil
            }
            // The preview lies as the sensor does: turned by the file's flip
            guard let image, max(image.width, image.height) * 2 >= maxPixel, !isGrey(image),
                  let wrapped = PictureDecoders.source(of: image, properties: properties(info, orientation: orientation(flip: info.flip))) else { return nil }
            return MediaInfo.scaledDown(wrapped.source, at: 0, maxPixel: maxPixel, now: true)
        }
    }

    /// A RAW file's tile: its preview, else (none, or one ImageIO can't
    /// read) the raw data developed at half size.
    static func thumbnail(of url: URL, maxPixel: Int) async -> CGImage? {
        guard let data = try? await MediaData.read(url), !Task.isCancelled else { return nil }
        if let preview = await preview(data, maxPixel: maxPixel, allowBitmap: BrowserModel.shownExtension(of: url) == "dng") { return preview }
        guard !Task.isCancelled, let developed = await developed(data, named: url, half: true) else { return nil }
        return MediaInfo.scaledDown(developed.source, at: 0, maxPixel: maxPixel, now: true)
    }

    /// For a file of ImageIO's RAW formats: the raw data developed by
    /// LibRaw (nil for other files), kept like the app's own decodes.
    static func fallback(_ url: URL) async -> (source: CGImageSource, inMemory: Int)? {
        guard imageIOExtensions.contains(BrowserModel.shownExtension(of: url)) else { return nil }
        let stamp = await Blocking.run(.userInitiated) { PictureDecoders.Kept.stamp(of: url) }
        if let kept = PictureDecoders.Kept.shared.find(url, stamp: stamp) { return (kept.source, kept.bytes) }
        guard let data = try? await MediaData.read(url), !Task.isCancelled,
              let developed = await developed(data, named: url, half: false) else { return nil }
        PictureDecoders.Kept.shared.keep(url, stamp: stamp, developed)
        return (developed.source, developed.bytes)
    }

    /// Whether the file is one of ImageIO's RAW formats (by its name or content).
    nonisolated static func isImageIORaw(_ url: URL) -> Bool {
        imageIOExtensions.contains(BrowserModel.shownExtension(of: url))
    }

    /// How a picture came out: nearly all black, or blown out (much of it
    /// white, bright overall), else fine.
    enum Exposure: Equatable {
        case fine, black, blownOut
    }

    /// Looked at in 32 × 32 (a cheap histogram of its luminance): black
    /// when 97 % of it lies at 8 of 255 or below, blown out when 40 % lies
    /// at 250 or above and its mean above 200. A snow field or a night sky
    /// shows more than that; ImageIO's picture of a Blackmagic Micro Cinema
    /// Camera DNG is all black on macOS 15 and half white at a mean of 229
    /// on macOS 26 (`FormatVisualTests`' RAW samples).
    static func exposure(of image: CGImage) -> Exposure {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .fine }
        var dark = 0, bright = 0, sum = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let luma = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
            if luma <= 8 { dark += 1 }
            if luma >= 250 { bright += 1 }
            sum += luma
        }
        let count = side * side
        if dark * 100 >= count * 97 { return .black }
        if bright * 100 >= count * 40, sum > 200 * count { return .blownOut }
        return .fine
    }

    /// For one of ImageIO's RAW formats whose picture by ImageIO is missing,
    /// black or blown out: LibRaw's development at up to `maxPixel`, when it
    /// comes out fine itself (a picture really that dark stays ImageIO's).
    static func replacement(of image: CGImage?, for url: URL, maxPixel: Int) async -> (source: CGImageSource, inMemory: Int, image: CGImage)? {
        guard isImageIORaw(url), image.map({ exposure(of: $0) != .fine }) ?? true,
              let developed = await fallback(url), !Task.isCancelled,
              let picture = MediaInfo.scaledDown(developed.source, at: 0, maxPixel: maxPixel, now: true),
              exposure(of: picture) == .fine else { return nil }
        return (developed.source, developed.inMemory, picture)
    }

    /// The same for a tile (QuickLook's or ImageIO's): LibRaw's tile.
    static func thumbnailReplacement(of image: CGImage?, for url: URL, maxPixel: Int) async -> CGImage? {
        guard isImageIORaw(url), image.map({ exposure(of: $0) != .fine }) ?? true, !Task.isCancelled,
              let tile = await thumbnail(of: url, maxPixel: maxPixel), exposure(of: tile) == .fine else { return nil }
        return tile
    }

    static func facts(of url: URL, _ facts: SBRawFacts) -> PictureDecoders.Facts {
        PictureDecoders.Facts(format: FileFacts.formatName(ofExtension: BrowserModel.shownExtension(of: url)) + " (LibRaw)",
                              depth: facts.bits > 0 ? Int(facts.bits) : nil)
    }

    /// Whether a picture holds no colour: one component, or red, green and
    /// blue alike everywhere (a grey JPEG in YCbCr), looked at in 32 × 32.
    static func isGrey(_ image: CGImage) -> Bool {
        guard (image.colorSpace?.numberOfComponents ?? 0) >= 3 else { return true }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy { i in
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            return abs(r - g) <= 6 && abs(g - b) <= 6 && abs(r - b) <= 6
        }
    }

    /// EXIF orientation of LibRaw's flip.
    static func orientation(flip: Int32) -> Int {
        switch flip {
        case 3: return 3
        case 5: return 8
        case 6: return 6
        default: return 1
        }
    }

    /// LibRaw's bitmap (8 or 16 bits, grey or RGB) as a CGImage, copied.
    static func bitmap(_ picture: SBRawPicture) -> CGImage? {
        guard picture.kind == 2, picture.width > 0, picture.height > 0, let data = picture.data else { return nil }
        let colors = Int(picture.colors), bits = Int(picture.bits)
        let rowBytes = Int(picture.width) * colors * bits / 8
        guard picture.size >= rowBytes * Int(picture.height),
              let space = colors == 1 ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) : CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes: data, count: rowBytes * Int(picture.height)) as CFData) else { return nil }
        let order: CGBitmapInfo = bits == 16 ? .byteOrder16Little : []
        return CGImage(width: Int(picture.width), height: Int(picture.height), bitsPerComponent: bits, bitsPerPixel: bits * colors,
                       bytesPerRow: rowBytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(order),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// What LibRaw read of the camera, the exposure, the time and the
    /// place, as ImageIO's properties (the Inspector and the capture time
    /// read them like any picture's).
    static func properties(_ facts: SBRawFacts, orientation: Int) -> [CFString: Any] {
        var tiff: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        let make = text(facts.make), model = text(facts.model)
        if !make.isEmpty { tiff[kCGImagePropertyTIFFMake] = make }
        if !model.isEmpty { tiff[kCGImagePropertyTIFFModel] = model }
        // Read from the file as it is: only finite numbers in a camera's range
        if let iso = positive(facts.iso, below: 1e7) { exif[kCGImagePropertyExifISOSpeedRatings] = [Int(iso.rounded())] }
        if let shutter = positive(facts.shutter, below: 1e6) { exif[kCGImagePropertyExifExposureTime] = shutter }
        if let aperture = positive(facts.aperture, below: 1e4) { exif[kCGImagePropertyExifFNumber] = aperture }
        if let focal = positive(facts.focal_length, below: 1e5) { exif[kCGImagePropertyExifFocalLength] = focal }
        if facts.timestamp > 0 {
            // LibRaw read the camera's clock as the Mac's local time
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let time = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(facts.timestamp)))
            exif[kCGImagePropertyExifDateTimeOriginal] = time
            tiff[kCGImagePropertyTIFFDateTime] = time
        }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if facts.has_gps != 0, facts.latitude.isFinite, facts.longitude.isFinite, abs(facts.latitude) <= 90, abs(facts.longitude) <= 180 {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(facts.latitude), kCGImagePropertyGPSLatitudeRef: facts.latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(facts.longitude), kCGImagePropertyGPSLongitudeRef: facts.longitude < 0 ? "W" : "E",
            ] as [CFString: Any]
        }
        return properties
    }

    /// A number LibRaw read, when it is finite, above 0 and below `limit`
    /// (∞, NaN and 1e30 from a crafted file are none).
    static func positive(_ value: Float, below limit: Double) -> Double? {
        let number = Double(value)
        return number.isFinite && number > 0 && number < limit ? number : nil
    }

    /// A C string field as text.
    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }
}
