import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VLCFrames
import VLCKit

/// What the inspector tells about a file beyond its name and size: the
/// format its content shows, the codecs, and whether its extension names
/// another format than the content.
struct FileFacts: Equatable, Sendable {
    /// The format by the content ("Matroska", "JPEG image").
    var format: String?
    /// A picture: bits per channel, colour profile, camera.
    var depth: Int?
    var profile: String?
    var camera: String?
    /// The extension to use where the file's own names another format.
    var recommendedExtension: String?

    // MARK: Pictures

    /// From an open image source (also a picture inside an archive).
    static func picture(_ source: CGImageSource, named url: URL) -> FileFacts {
        var facts = FileFacts()
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        facts.depth = (props[kCGImagePropertyDepth] as? NSNumber)?.intValue
        facts.profile = props[kCGImagePropertyProfileName] as? String
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        // Models often name their make already ("Canon EOS R6")
        let camera = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        facts.camera = camera.isEmpty ? nil : camera
        if let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) {
            facts.format = type.localizedDescription
            facts.recommendedExtension = recommendedExtension(for: url.pathExtension, content: type)
        }
        return facts
    }

    /// The extension for a picture whose content is `content` but whose
    /// extension is `ext`; nil when `ext` fits it.
    static func recommendedExtension(for ext: String, content: UTType) -> String? {
        let ext = ext.lowercased()
        let extensions = content.tags[.filenameExtension] ?? []
        guard !extensions.contains(ext) else { return nil }
        if let named = UTType(filenameExtension: ext) {
            if named == content || named.conforms(to: content) || content.conforms(to: named) { return nil }
            // RAW formats share extensions across makers (".raw"); ImageIO
            // names the maker's type, the extension another one's
            if named.conforms(to: .rawImage), content.conforms(to: .rawImage) { return nil }
        }
        // Formats an extension stands for that the system's type doesn't list
        let alike: [String: Set<String>] = [
            "public.jpeg": ["mpo", "jpe"],
            "public.heic": ["heif", "hif"],
            "public.heif": ["heic", "hif"],
            "public.heics": ["heic", "heif"],
        ]
        if alike[content.identifier]?.contains(ext) == true { return nil }
        return content.preferredFilenameExtension ?? extensions.first
    }

    // MARK: Videos

    /// A video container its first bytes show.
    struct Container: Equatable, Sendable {
        let name: String
        /// The extensions it goes by; the first is the one to recommend.
        let extensions: [String]
    }

    /// The container `head` (a file's first bytes) shows; nil when it shows
    /// none Schnellbild knows (VLC opens a file by the same sniffing,
    /// `VLCSafety.container`).
    static func container(in head: Data) -> Container? {
        guard let reader = VLCSafety.container(in: head) else { return nil }
        let b = [UInt8](head.prefix(12))
        switch reader.demux {
        case "mkv":
            return Container(name: "Matroska / WebM", extensions: ["mkv", "webm"])
        case "ts":
            // 192-byte packets (a time code before each): Blu-ray / AVCHD
            let timecoded = head.count > 4 && head[head.startIndex + 4] == 0x47 && head.first != 0x47
            return Container(name: "MPEG-TS", extensions: timecoded ? ["m2ts", "mts", "ts"] : ["ts", "m2ts", "mts"])
        case "mp4":
            let quickTime = b.count >= 12 && String(decoding: b[8..<12], as: UTF8.self) == "qt  "
            return Container(name: quickTime ? "QuickTime" : "MPEG-4",
                             extensions: quickTime ? ["mov", "qt", "mp4", "m4v"] : ["mp4", "m4v", "mov", "qt", "3gp", "3g2"])
        case "avi":      return Container(name: "AVI", extensions: ["avi"])
        case "ps":       return Container(name: "MPEG-PS", extensions: ["mpg", "mpeg", "vob"])
        case "asf":      return Container(name: "ASF / WMV", extensions: ["wmv", "asf"])
        case "avformat": return Container(name: "FLV", extensions: ["flv"])
        case "ogg":      return Container(name: "Ogg", extensions: ["ogv", "ogg"])
        default:         return nil
        }
    }

    /// A video file on disk, by its first bytes.
    static func video(head: Data?, named url: URL) -> FileFacts {
        var facts = FileFacts()
        guard let head, let container = container(in: head) else { return facts }
        facts.format = container.name
        if !container.extensions.contains(url.pathExtension.lowercased()) {
            facts.recommendedExtension = container.extensions.first
        }
        return facts
    }
}

/// The streams of a playing video, as its player reports them.
struct StreamFacts: Equatable, Sendable {
    /// The codec and the frames per second ("H.264, 25 fps").
    var video: String?
    /// The codec, channels and sample rate.
    var audio: String?
    /// The length in seconds, where the player knows it (for the bitrate).
    var seconds: Double?

    var isEmpty: Bool { video == nil && audio == nil }

    static func describeVideo(codec: String, frameRate: Double?) -> String {
        guard let frameRate, frameRate.isFinite, frameRate > 0 else { return codec }
        let rate = frameRate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(codec), \(rate) fps"
    }

    static func describeAudio(codec: String, channels: Int?, sampleRate: Double?) -> String {
        var parts = [codec]
        if let channels, channels > 0 { parts.append("\(channels) ch") }
        if let sampleRate, sampleRate > 0 { parts.append("\((sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz") }
        return parts.joined(separator: ", ")
    }

    /// "4.2 Mbit/s", "320 kbit/s".
    static func describeBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return "\((bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbit/s"
        }
        return "\(Int((bitsPerSecond / 1000).rounded())) kbit/s"
    }

    /// Bits per second of a file `bytes` long, playing `seconds`.
    static func bitrate(bytes: Int?, seconds: Double?) -> Double? {
        guard let bytes, bytes > 0, let seconds, seconds.isFinite, seconds > 0.1 else { return nil }
        return Double(bytes) * 8 / seconds
    }

    /// A codec's name for its four-character code (AVFoundation's subtypes).
    static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = [
            "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "HEVC (Dolby Vision)",
            "av01": "AV1", "vp09": "VP9", "vp08": "VP8", "mp4v": "MPEG-4 Part 2", "jpeg": "Motion JPEG",
            "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy",
            "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ",
            "mp2v": "MPEG-2", "mp1v": "MPEG-1", "dvc ": "DV", "dvcp": "DV", "dv5p": "DV",
            "aac ": "AAC", "aach": "HE-AAC", "aacp": "HE-AAC v2", ".mp3": "MP3", "ac-3": "AC-3", "ec-3": "E-AC-3",
            "alac": "Apple Lossless", "flac": "FLAC", "opus": "Opus", "lpcm": "PCM", "sowt": "PCM", "twos": "PCM",
            "ulaw": "µ-law", "alaw": "A-law", "samr": "AMR",
        ]
        let text = String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
        return names[text] ?? text.trimmingCharacters(in: .whitespaces)
    }

    /// From an AVFoundation asset.
    static func of(_ asset: AVAsset) async -> StreamFacts {
        var facts = StreamFacts()
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (descriptions, frameRate) = try? await track.load(.formatDescriptions, .nominalFrameRate),
           let description = descriptions.first {
            facts.video = describeVideo(codec: codecName(CMFormatDescriptionGetMediaSubType(description)),
                                        frameRate: Double(frameRate))
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first {
            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            facts.audio = describeAudio(codec: codecName(CMFormatDescriptionGetMediaSubType(description)),
                                        channels: basic.map { Int($0.mChannelsPerFrame) },
                                        sampleRate: basic?.mSampleRate)
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            facts.seconds = CMTimeGetSeconds(duration)
        }
        return facts
    }

    /// From VLC's media, once it plays (its tracks are known only then).
    @MainActor static func of(_ media: VLCMedia) -> StreamFacts {
        var facts = StreamFacts()
        let tracks = media.tracksInformation as? [[String: Any]] ?? []
        func number(_ track: [String: Any], _ key: String) -> Double? { (track[key] as? NSNumber)?.doubleValue }
        func codec(_ track: [String: Any], _ type: String) -> String? {
            guard let code = (track[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value, code != 0 else { return nil }
            let name = VLCMedia.codecName(forFourCC: code, trackType: type)
            if !name.isEmpty { return name }
            // VLC's four-character codes are little endian
            return codecName(code.byteSwapped)
        }
        func first(_ type: String) -> [String: Any]? {
            tracks.first { $0[VLCMediaTracksInformationType] as? String == type }
        }
        if let track = first(VLCMediaTracksInformationTypeVideo), let name = codec(track, VLCMediaTracksInformationTypeVideo) {
            var rate: Double?
            if let frames = number(track, VLCMediaTracksInformationFrameRate),
               let base = number(track, VLCMediaTracksInformationFrameRateDenominator), base > 0 {
                rate = frames / base
            }
            facts.video = describeVideo(codec: name, frameRate: rate)
        }
        if let track = first(VLCMediaTracksInformationTypeAudio), let name = codec(track, VLCMediaTracksInformationTypeAudio) {
            facts.audio = describeAudio(codec: name,
                                        channels: number(track, VLCMediaTracksInformationAudioChannelsNumber).map { Int($0) },
                                        sampleRate: number(track, VLCMediaTracksInformationAudioRate))
        }
        let ms = media.length.intValue
        if ms > 0 { facts.seconds = Double(ms) / 1000 }
        return facts
    }
}
