import CoreVideo
import Foundation
import VLCKit

/// A video's colours as VLC knows them: its transfer function, primaries
/// and matrix, and for HDR10 the mastering display and content light
/// level. libVLC 3 hands the video callbacks only a chroma and a size, so
/// they are read from the stream information VLC keeps for the media
/// (VLC's "Codec details": what the container states, then what the decoder
/// found in the stream, `LibVLCVideo.streamInformation`).
public struct VideoColour: Equatable, Sendable {
    public enum Transfer: Sendable { case sdr, pq, hlg }
    public enum Primaries: Sendable { case bt709, bt2020, p3 }

    public var transfer: Transfer
    public var primaries: Primaries
    /// The YCbCr matrix is BT.2020's (else BT.709's).
    public var matrix2020: Bool
    public var fullRange: Bool
    /// `kCVImageBufferMasteringDisplayColorVolumeKey`'s 24 bytes (the HEVC
    /// SEI's layout, big-endian), when VLC knows the whole of it.
    public var masteringDisplay: Data?
    /// `kCVImageBufferContentLightLevelInfoKey`'s 4 bytes: MaxCLL, MaxFALL.
    public var contentLightLevel: Data?

    public var isHDR: Bool { transfer != .sdr }

    public init(transfer: Transfer, primaries: Primaries, matrix2020: Bool, fullRange: Bool = false,
                masteringDisplay: Data? = nil, contentLightLevel: Data? = nil) {
        self.transfer = transfer
        self.primaries = primaries
        self.matrix2020 = matrix2020
        self.fullRange = fullRange
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
    }

    /// From one stream's information, by the names and formats VLC 3.0's
    /// `EsOutUpdateInfo` writes (in English: VLCKit's libVLC has no
    /// translations). nil when it states no transfer function (not known
    /// yet, or never). An HDR video that states no primaries or matrix gets
    /// BT.2020's, which HDR10 and HLG use.
    public init?(information info: [String: String]) {
        guard let transfer = info["Color transfer function"], !transfer.isEmpty else { return nil }
        switch transfer {
        case "SMPTE ST2084 (PQ)": self.transfer = .pq
        case "Hybrid Log-Gamma":  self.transfer = .hlg
        default:                  self.transfer = .sdr
        }
        let hdr = self.transfer != .sdr
        switch info["Color primaries"] ?? "" {
        case "ITU-R BT.2020": primaries = .bt2020
        case "DCI/P3 D65":    primaries = .p3
        case "ITU-R BT.709":  primaries = .bt709
        default:              primaries = hdr ? .bt2020 : .bt709
        }
        let space = info["Color space"] ?? ""   // "ITU-R BT.2020 Limited Range"
        matrix2020 = space.isEmpty ? hdr : space.hasPrefix("ITU-R BT.2020")
        fullRange = space.hasSuffix("Full Range")

        // "1000.0000 cd/m²", "x=0.6800 y=0.3200", "1000 cd/m²"
        func number(_ key: String) -> Double? {
            guard let text = info[key] else { return nil }
            return Double(text.prefix { $0.isNumber || $0 == "." })
        }
        func point(_ key: String) -> (Double, Double)? {
            guard let parts = info[key]?.split(separator: " "), parts.count == 2,
                  parts[0].hasPrefix("x="), parts[1].hasPrefix("y="),
                  let x = Double(parts[0].dropFirst(2)), let y = Double(parts[1].dropFirst(2)) else { return nil }
            return (x, y)
        }
        var bytes = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
        // Held in the field's range (a value VLC read from a crafted file may be anything)
        func whole<T: FixedWidthInteger>(_ v: Double) -> T {
            guard v.isFinite, v > 0 else { return 0 }
            return v < Double(T.max) ? T(v.rounded()) : T.max
        }
        func chromaticity(_ v: Double) -> UInt16 { whole(v * 50000) }
        func luminance(_ v: Double) -> UInt32 { whole(v * 10000) }
        // The SEI's order: green, blue, red, white point; luminance in 0.0001 cd/m²
        if let g = point("Primary G"), let b = point("Primary B"), let r = point("Primary R"),
           let white = point("White point"), let high = number("Max. luminance") {
            for (x, y) in [g, b, r, white] { append(chromaticity(x)); append(chromaticity(y)) }
            append(luminance(high))
            append(luminance(number("Min. luminance") ?? 0))
            masteringDisplay = bytes
        }
        if let maxCLL = number("MaxCLL") {
            bytes = Data()
            append(whole(maxCLL) as UInt16)
            append(whole(number("MaxFALL") ?? 0) as UInt16)
            contentLightLevel = bytes
        }
    }

    /// Tags a pixel buffer with these colours.
    public func attach(to buffer: CVPixelBuffer) {
        let transferFunction: CFString
        switch transfer {
        case .pq:  transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case .sdr: transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        let primaryKey: CFString
        switch primaries {
        case .bt2020: primaryKey = kCVImageBufferColorPrimaries_ITU_R_2020
        case .p3:     primaryKey = kCVImageBufferColorPrimaries_P3_D65
        case .bt709:  primaryKey = kCVImageBufferColorPrimaries_ITU_R_709_2
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              matrix2020 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaryKey, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transferFunction, .shouldPropagate)
        if let masteringDisplay {
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplay as CFData, .shouldPropagate)
        }
        if let contentLightLevel {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, contentLightLevel as CFData, .shouldPropagate)
        }
    }
}

extension VideoColour {
    /// An SD or HD picture's colours as the app shows them, decided by the
    /// visible height as VLC decides (`isHD`): HD with BT.709's matrix and
    /// primaries, SD with BT.601's matrix and SMPTE C's primaries; BT.709's
    /// transfer function either way. `VLCFrameOutput` and `VLCFrameGrab`
    /// tag their SDR pictures with them, so the full view and the tile show
    /// the same colours.
    public static func sdrAttachments(hd: Bool) -> [CFString: CFString] {
        [kCVImageBufferYCbCrMatrixKey: hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
         kCVImageBufferColorPrimariesKey: hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C,
         kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2]
    }

    /// HD: more than 576 visible rows (BT.709), else SD (BT.601).
    public static func isHD(visibleHeight: Int) -> Bool { visibleHeight > 576 }

    /// Tags an SDR pixel buffer (`sdrAttachments`).
    public static func attachSDR(to buffer: CVPixelBuffer, hd: Bool) {
        for (key, value) in sdrAttachments(hd: hd) { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }
    }
}

extension LibVLCVideo {
    private typealias GetInfo = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private static let getInfo: GetInfo? = dlsym(dlopen(nil, RTLD_NOW), "input_item_GetInfo")
        .map { unsafeBitCast($0, to: GetInfo.self) }

    /// The names a video stream's colours are kept under.
    static let colourKeys = ["Color transfer function", "Color primaries", "Color space", "Max. luminance",
                             "Min. luminance", "Primary R", "Primary G", "Primary B", "White point", "MaxCLL", "MaxFALL"]

    /// The colours VLC knows of the media's video stream: the first stream
    /// whose information states a transfer function. nil while none does.
    ///
    /// Read from the media's input item (`input_item_GetInfo`, exported by
    /// VLCKit). libVLC 3 has no function for a media's input item, so it is
    /// read from `libvlc_media_t` at its place in VLC 3.0's
    /// `lib/media_internal.h` (`p_input_item` at 0x58, `p_libvlc_instance` at
    /// 0x68, as the DWARF of VLCKit 3.7.5 says; check them when updating
    /// VLCKit). The instance pointer must be the shared library's, else the
    /// layout isn't the one expected and nothing is read.
    public static func colour(of media: VLCMedia) -> VideoColour? {
        guard let getInfo, let item = inputItem(of: media) else { return nil }
        func value(_ category: String, _ key: String) -> String? {
            guard let text = getInfo(item, category, key) else { return nil }
            defer { free(text) }
            let value = String(cString: text)
            return value.isEmpty ? nil : value
        }
        for stream in 0..<32 {
            let category = "Stream \(stream)"
            guard value(category, "Color transfer function") != nil else { continue }
            var info: [String: String] = [:]
            for key in colourKeys { info[key] = value(category, key) }
            return VideoColour(information: info)
        }
        return nil
    }

    /// The video stream's visible size and its buffer's, as VLC's stream
    /// information states them once the decoder has said ("Video
    /// resolution", "Buffer dimensions": the decoder pads its buffer, 240
    /// rows into 256, 1080 into 1088). nil while VLC hasn't said.
    public static func resolution(of media: VLCMedia) -> (visible: (width: Int, height: Int), buffer: (width: Int, height: Int)?)? {
        guard let getInfo, let item = inputItem(of: media) else { return nil }
        func size(_ category: String, _ key: String) -> (width: Int, height: Int)? {
            guard let text = getInfo(item, category, key) else { return nil }
            defer { free(text) }
            let parts = String(cString: text).split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            return (parts[0], parts[1])
        }
        for stream in 0..<32 {
            let category = "Stream \(stream)"
            guard let visible = size(category, "Video resolution") else { continue }
            return (visible, size(category, "Buffer dimensions"))
        }
        return nil
    }

    /// A video track's pixel size and pixel shape (width / height of one pixel).
    public struct Track: Equatable {
        public var width: Int
        public var height: Int
        public var sampleAspect: Double

        public init(width: Int, height: Int, sampleAspect: Double) {
            self.width = width
            self.height = height
            self.sampleAspect = sampleAspect
        }
    }

    /// The size a picture is shown at, by the full view and the tiles alike:
    /// the track's visible size when it fits in what VLC decodes (else VLC's
    /// own size), turned as VLC turns the picture, with non-square pixels
    /// widened (or made taller); even sides, as NV12 needs. `visibleHeight`:
    /// before the pixels are made square (it decides BT.601 or BT.709,
    /// `VideoColour.isHD`).
    public static func shownSize(track: Track?, decoded: (width: Int, height: Int)) -> (width: Int, height: Int, visibleHeight: Int) {
        var w = decoded.width, h = decoded.height
        var aspect = 1.0
        if var track {
            // VLC hands over an upright picture of a video stored turned
            if (track.width > track.height) != (w > h), track.width != track.height, w != h {
                swap(&track.width, &track.height)
                track.sampleAspect = 1 / track.sampleAspect
            }
            if track.width <= w, track.height <= h { w = track.width; h = track.height }
            if track.sampleAspect.isFinite, abs(track.sampleAspect - 1) > 0.01 {
                aspect = min(max(track.sampleAspect, 0.25), 4)
            }
        }
        let visibleHeight = h
        if aspect > 1 { w = Int((Double(w) * aspect).rounded()) } else if aspect < 1 { h = Int((Double(h) / aspect).rounded()) }
        func even(_ side: Int) -> Int { max(2, side + side % 2) }
        return (even(w), even(h), visibleHeight)
    }

    /// The video track's visible size and the shape of its pixels: from the
    /// media's tracks (what the container states), else from VLC's stream
    /// information (an elementary stream such as MPEG-1 video states its
    /// size only in the stream), square pixels then. nil: not known yet.
    public static func visibleTrack(of media: VLCMedia) -> Track? {
        if let tracks = media.tracksInformation as? [[String: Any]] {
            for track in tracks where track[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo {
                let number = { (key: String) in (track[key] as? NSNumber)?.intValue ?? 0 }
                let width = number(VLCMediaTracksInformationVideoWidth), height = number(VLCMediaTracksInformationVideoHeight)
                guard width > 0, height > 0 else { continue }
                let num = number(VLCMediaTracksInformationSourceAspectRatio)
                let den = number(VLCMediaTracksInformationSourceAspectRatioDenominator)
                return Track(width: width, height: height, sampleAspect: num > 0 && den > 0 ? Double(num) / Double(den) : 1)
            }
        }
        if let stated = resolution(of: media) { return Track(width: stated.visible.width, height: stated.visible.height, sampleAspect: 1) }
        // An MPEG-1 or MPEG-2 elementary stream (".m1v", ".m2v"): VLC states
        // its size only once its decoder has run, after its output opened
        return media.url.flatMap(mpegSequenceSize(of:)).map { Track(width: $0.width, height: $0.height, sampleAspect: $0.sampleAspect) }
    }

    /// The size and pixel shape in an MPEG-1 / MPEG-2 video sequence header
    /// (ISO/IEC 11172-2 2.4.2.3, 13818-2 6.2.2.1: 00 00 01 B3, 12 bits
    /// width, 12 bits height, 4 bits aspect ratio) in the file's first 4 KB.
    /// Square pixels unless MPEG-2 (an extension start code, 00 00 01 B5,
    /// follows) states a display aspect of 4:3, 16:9 or 2.21:1.
    static func mpegSequenceSize(of url: URL) -> (width: Int, height: Int, sampleAspect: Double)? {
        guard let head = RegularFile.head(of: url, count: 4096) else { return nil }
        let bytes = [UInt8](head)
        guard bytes.count >= 8 else { return nil }
        for at in 0..<(bytes.count - 7) where bytes[at] == 0 && bytes[at + 1] == 0 && bytes[at + 2] == 1 && bytes[at + 3] == 0xB3 {
            let width = Int(bytes[at + 4]) << 4 | Int(bytes[at + 5]) >> 4
            let height = (Int(bytes[at + 5]) & 0x0F) << 8 | Int(bytes[at + 6])
            guard width > 0, height > 0 else { return nil }
            let code = Int(bytes[at + 7]) >> 4
            let rest = bytes[(at + 8)...]
            let mpeg2 = rest.indices.contains { i in
                i + 3 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && bytes[i + 3] == 0xB5
            }
            let display: Double? = mpeg2 ? [2: 4.0 / 3, 3: 16.0 / 9, 4: 2.21][code] : nil
            return (width, height, display.map { $0 * Double(height) / Double(width) } ?? 1)
        }
        return nil
    }

    private typealias GetURI = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
    private static let getURI: GetURI? = dlsym(dlopen(nil, RTLD_NOW), "input_item_GetURI")
        .map { unsafeBitCast($0, to: GetURI.self) }

    /// The URI of the input item `colour(of:)` reads from (nil: not found):
    /// the media's own, while the place it is read from fits this VLCKit
    /// (`VLCHDRTests` holds it to that).
    public static func inputItemURI(of media: VLCMedia) -> String? {
        guard let getURI, let item = inputItem(of: media), let text = getURI(item) else { return nil }
        defer { free(text) }
        return String(cString: text)
    }

    private static func inputItem(of media: VLCMedia) -> UnsafeMutableRawPointer? {
        let selector = NSSelectorFromString("libVLCMediaDescriptor")
        let library: UnsafeMutableRawPointer? = VLCLibrary.shared().instance
        guard media.responds(to: selector), let instance = library else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        guard let descriptor = unsafeBitCast(media.method(for: selector), to: Getter.self)(media, selector) else { return nil }
        guard descriptor.load(fromByteOffset: 0x68, as: UnsafeMutableRawPointer?.self) == instance else { return nil }
        return descriptor.load(fromByteOffset: 0x58, as: UnsafeMutableRawPointer?.self)
    }
}
