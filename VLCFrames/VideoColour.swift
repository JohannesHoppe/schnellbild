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

    /// The video track's visible size and the shape of its pixels: from the
    /// media's tracks (what the container states), else from VLC's stream
    /// information (an elementary stream such as MPEG-1 video states its
    /// size only in the stream), square pixels then. nil: not known yet.
    public static func visibleTrack(of media: VLCMedia) -> (width: Int, height: Int, sampleAspect: Double)? {
        if let tracks = media.tracksInformation as? [[String: Any]] {
            for track in tracks where track[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo {
                let number = { (key: String) in (track[key] as? NSNumber)?.intValue ?? 0 }
                let width = number(VLCMediaTracksInformationVideoWidth), height = number(VLCMediaTracksInformationVideoHeight)
                guard width > 0, height > 0 else { continue }
                let num = number(VLCMediaTracksInformationSourceAspectRatio)
                let den = number(VLCMediaTracksInformationSourceAspectRatioDenominator)
                return (width, height, num > 0 && den > 0 ? Double(num) / Double(den) : 1)
            }
        }
        return resolution(of: media).map { ($0.visible.width, $0.visible.height, 1) }
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
