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
        if let decoded = PictureDecoders.facts(of: url),
           PictureDecoders.decodes(url) || RawDecoder.imageIOExtensions.contains(BrowserModel.shownExtension(of: url)) {
            // Decoded by the app (QOI, PCX, LibRaw): the format and depth of
            // the file, not of the picture handed to ImageIO
            facts.format = decoded.format
            facts.depth = decoded.depth
            facts.profile = nil
        } else if EmbeddedPreview.isPreview(url) {
            // The picture shown is the one the file carries: the file's own
            // format, and no other extension to recommend
            facts.format = previewFormat(of: url)
            facts.camera = nil
        } else if let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) {
            facts.format = type.localizedDescription
            facts.recommendedExtension = recommendedExtension(for: DownloadName.finalExtension(of: url), content: type)
        }
        return facts
    }

    /// "Encapsulated PostScript, embedded preview": the format its name
    /// says, and that what is shown is the preview it carries.
    static func previewFormat(of url: URL) -> String {
        String(localized: "\(formatName(ofExtension: DownloadName.finalExtension(of: url))), embedded preview")
    }

    /// The system's name of the format an extension names ("Encapsulated
    /// PostScript"), else the extension in capitals.
    static func formatName(ofExtension ext: String) -> String {
        UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0.localizedDescription } ?? ext.uppercased()
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
            "public.avif": ["avifs"],
            "public.avis": ["avifs", "avif"],
            "public.png": ["apng"],
            "public.pbm": ["pnm"],
            "public.jpeg-2000": ["j2c", "jpf", "jpx", "j2k"],
            "com.adobe.photoshop-image": ["psb"],
            "org.nema.dicom": ["dcm", "dicom"],
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
            return Container(name: "MPEG-TS", extensions: timecoded ? ["m2ts", "mts", "ts"] : ["ts", "m2ts", "mts", "m2t"])
        case "mp4":
            let quickTime = b.count >= 12 && String(decoding: b[8..<12], as: UTF8.self) == "qt  "
            return Container(name: quickTime ? "QuickTime" : "MPEG-4",
                             extensions: quickTime ? ["mov", "qt", "mp4", "m4v"] : ["mp4", "m4v", "mov", "qt", "3gp", "3g2", "insv", "360"])
        case "avi":      return Container(name: "AVI", extensions: ["avi", "divx"])
        case "ps":       return Container(name: "MPEG-PS", extensions: ["mpg", "mpeg", "vob"])
        case "asf":      return Container(name: "ASF / WMV", extensions: ["wmv", "asf"])
        case "ogg":      return Container(name: "Ogg", extensions: ["ogv", "ogg", "ogm"])
        case "avformat":
            switch reader.ffmpegFormat {
            case "rm":  return Container(name: "RealMedia", extensions: ["rm", "rmvb"])
            case "mov": return Container(name: "F4V", extensions: ["f4v"])
            case "mxf": return Container(name: "MXF", extensions: ["mxf"])
            default:    return Container(name: "FLV", extensions: ["flv"])
            }
        default:         return nil
        }
    }

    /// A video file on disk, by its first bytes.
    static func video(head: Data?, named url: URL) -> FileFacts {
        var facts = FileFacts()
        guard let head, let container = container(in: head) else { return facts }
        facts.format = container.name
        if !container.extensions.contains(DownloadName.finalExtension(of: url)) {
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
    /// How many video, audio and subtitle tracks the file has.
    var videoTracks = 0, audioTracks = 0, subtitleTracks = 0
    /// What VLC's metadata says (title, date, encoder …), for the
    /// Inspector's All Metadata where AVFoundation can't read the file.
    var tags: [MetadataGroup.Entry] = []

    var isEmpty: Bool { video == nil && audio == nil }

    /// "Video 1 · Audio 2 · Subtitles 1".
    var tracksText: String? {
        let parts = [(String(localized: "Video"), videoTracks), (String(localized: "Audio"), audioTracks),
                     (String(localized: "Subtitles"), subtitleTracks)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Units in the user's language: "25 fps", "25 B/s", "25 i/s" …
    static func describeVideo(codec: String, frameRate: Double?) -> String {
        guard let frameRate, frameRate.isFinite, frameRate > 0 else { return codec }
        let rate = frameRate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(codec), " + String(localized: "\(rate) fps")
    }

    /// "AAC, 2 channels, 48 kHz" (the kilohertz as the user's locale writes them).
    static func describeAudio(codec: String, channels: Int?, sampleRate: Double?) -> String {
        var parts = [codec]
        if let channels, channels > 0 { parts.append(String(localized: "\(channels) channels")) }
        if let sampleRate, sampleRate > 0 {
            parts.append(Measurement(value: sampleRate / 1000, unit: UnitFrequency.kilohertz)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0...1)))))
        }
        return parts.joined(separator: ", ")
    }

    /// "4.2 Mbit/s", "320 kbit/s" (in the user's language: "Мбит/с" …).
    static func describeBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            let megabits = (bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1)))
            return String(localized: "\(megabits) Mbit/s")
        }
        return String(localized: "\(Int((bitsPerSecond / 1000).rounded())) kbit/s")
    }

    /// "8 bits", "16 Bit" …
    static func describeDepth(_ bits: Int) -> String {
        String(localized: "\(bits) bits")
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
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                switch track.mediaType {
                case .video: facts.videoTracks += 1
                case .audio: facts.audioTracks += 1
                case .subtitle, .text, .closedCaption: facts.subtitleTracks += 1
                default: break
                }
            }
        }
        return facts
    }

    /// VLC's metadata of a media (never its artwork: VLC might fetch that).
    @MainActor static func tags(of meta: VLCMedia.MetaData) -> [MetadataGroup.Entry] {
        let fields: [(String, String?)] = [
            ("title", meta.title), ("artist", meta.artist), ("album", meta.album), ("genre", meta.genre),
            ("date", meta.date), ("description", meta.metaDescription), ("copyright", meta.copyright),
            ("publisher", meta.publisher), ("encodedBy", meta.encodedBy), ("language", meta.language),
            ("director", meta.director), ("showName", meta.showName), ("actors", meta.actors),
            ("albumArtist", meta.albumArtist), ("setting", meta.setting), ("rating", meta.rating),
        ]
        return fields.compactMap { key, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return MetadataGroup.Entry(key: key, value: MetadataText.shortened(value))
        }
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
        for track in tracks {
            switch track[VLCMediaTracksInformationType] as? String {
            case VLCMediaTracksInformationTypeVideo: facts.videoTracks += 1
            case VLCMediaTracksInformationTypeAudio: facts.audioTracks += 1
            case VLCMediaTracksInformationTypeText: facts.subtitleTracks += 1
            default: break
            }
        }
        facts.tags = tags(of: media.metaData)
        return facts
    }
}

// MARK: - Content

extension FileFacts {
    /// What a file holds by its first bytes, whatever its name says: a
    /// picture (ImageIO's type of the content, PDF included), a video (the
    /// container VLC would read, `container(in:)`) or an archive
    /// (`ArchiveStore.format(in:)`).
    struct Content: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case picture, video, archive(ArchiveFormat) }
        let kind: Kind
        /// The extension that names it ("jpeg", "mp4", "zip").
        let fileExtension: String
        /// The format's name ("JPEG image", "MPEG-4").
        let name: String

        var mediaKind: GridEntry.Kind? {
            switch kind {
            case .picture: return .image
            case .video:   return .video
            case .archive: return nil
            }
        }

        var archiveFormat: ArchiveFormat? {
            if case .archive(let format) = kind { return format }
            return nil
        }
    }

    /// What `head` (a file's first bytes, 512 are enough) shows; nil for
    /// anything else (text, a playlist, too few bytes).
    static func content(in head: Data) -> Content? {
        guard head.count >= 4 else { return nil }
        if let format = ArchiveStore.format(in: head) {
            let ext: String
            switch format {
            case .zip:      ext = "zip"
            case .rar:      ext = "rar"
            case .sevenZip: ext = "7z"
            }
            return Content(kind: .archive(format), fileExtension: ext, name: ext.uppercased())
        }
        // QOI (ImageIO doesn't read it): its header
        if QOIDecoder.header(head) != nil {
            return Content(kind: .picture, fileExtension: "qoi", name: "QOI")
        }
        // Pictures before videos: HEIF and AVIF are boxes with an "ftyp" too
        if let source = CGImageSourceCreateWithData(head as CFData, nil),
           let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
           let ext = (type.tags[.filenameExtension] ?? []).first(where: { BrowserModel.imageExtensions.contains($0.lowercased()) }) {
            return Content(kind: .picture, fileExtension: ext.lowercased(), name: type.localizedDescription ?? ext.uppercased())
        }
        if let container = container(in: head), let ext = container.extensions.first {
            return Content(kind: .video, fileExtension: ext, name: container.name)
        }
        return nil
    }
}

/// What files hold whose names don't say (no extension, one no app knows,
/// "x.part" of a file without one), read from their first bytes once and
/// kept by path, size and date; ".ts" files too (TypeScript far more often
/// than a TV recording). `BrowserModel.mediaKind` and the archive rules ask
/// `known` (no disk access); a listing has the files it holds of that sort
/// read off the main thread (`BrowserModel.sniffOtherFiles`), a file opened
/// or dropped is read before it opens.
final class ContentSniffer: @unchecked Sendable {
    static let shared = ContentSniffer()
    private let lock = NSLock()
    private struct Answer {
        let size: Int64
        let stamp: String
        let content: FileFacts.Content?
    }
    private var answers: [String: Answer] = [:]
    /// Archives found by their content (canonical paths), for `ArchivePath`.
    private var archives: Set<String> = []
    /// Kept answers at most (a folder of code has many .ts files).
    private let limit: Int

    init(limit: Int = 20_000) { self.limit = limit }

    /// The answer kept for the file, without looking at the disk.
    func known(_ url: URL) -> FileFacts.Content? {
        lock.withLock { answers[BrowserModel.canonicalPath(url)]?.content }
    }

    /// Whether the file must be read (again): never read, or listed now
    /// with another size than when it was read (a download growing).
    func needsReading(_ url: URL, size: Int?) -> Bool {
        lock.withLock {
            guard let answer = answers[BrowserModel.canonicalPath(url)] else { return true }
            return size.map { Int64($0) != answer.size } ?? false
        }
    }

    /// Reads the file's first bytes unless the answer for its size and date
    /// is kept. Off the main thread: it touches the disk.
    @discardableResult
    func content(of url: URL) -> FileFacts.Content? {
        // A path through an archive has no first bytes to read without unpacking
        guard !ArchivePath.isInside(url) else { return nil }
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let stamp = "\(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        let path = BrowserModel.canonicalPath(url)
        if let answer = lock.withLock({ answers[path] }), answer.stamp == stamp { return answer.content }
        // PostScript, Illustrator files and ZIP documents: a picture when
        // their bytes hold one the app shows (`EmbeddedPreview`), never an
        // archive (a Krita file is a ZIP)
        let ext = DownloadName.finalExtension(of: url)
        let content = EmbeddedPreview.extensions.contains(ext)
            ? EmbeddedPreview.content(of: url, ext: ext, size: Int(info.st_size))
            : VLCSafety.head(of: url).flatMap(FileFacts.content(in:))
        lock.withLock {
            if answers.count >= limit {
                // The archives found stay: one may be open, its paths go through `ArchivePath`
                answers = answers.filter { archives.contains($0.key) }
                if answers.count >= limit { answers.removeAll(keepingCapacity: true); archives.removeAll() }
            }
            answers[path] = Answer(size: Int64(info.st_size), stamp: stamp, content: content)
            if content?.archiveFormat != nil { archives.insert(path) } else { archives.remove(path) }
        }
        return content
    }

    /// The archive found by its content that `url` is or lies in, and the
    /// path inside it ("" for the archive itself), both canonical.
    func archive(containing url: URL) -> (archive: String, inner: String)? {
        guard lock.withLock({ !archives.isEmpty }) else { return nil }
        let path = BrowserModel.canonicalPath(url)
        // The path and the folders above it, each looked up (not every
        // archive known compared with the path)
        var candidate = path
        while true {
            if lock.withLock({ archives.contains(candidate) }) {
                return (candidate, String(path.dropFirst(candidate.count).drop { $0 == "/" }))
            }
            guard candidate != "/", !candidate.isEmpty else { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }

    /// Names whose content is worth a look: no extension, one that names
    /// nothing the system knows ("x.xyz"; "x.part" of a file without one),
    /// a catch-all ("x.bin", "x.dat"), or a format shown by what its bytes
    /// hold (PostScript, Illustrator, ZIP documents: `EmbeddedPreview`).
    /// Never a later volume of a split
    /// archive ("x.r00", "x.z01" start like archives of their own).
    static func isUnknown(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let final = DownloadName.finalName(of: name)
        let ext = (final as NSString).pathExtension.lowercased()
        if ext.isEmpty { return true }
        // PostScript, Illustrator files, ZIP documents: pictures by their content
        if EmbeddedPreview.extensions.contains(ext) { return true }
        if BrowserModel.imageExtensions.contains(ext) || BrowserModel.videoExtensions.contains(ext) || ext == "ts" { return false }
        if ArchiveName.format(of: name) != nil || !ArchiveName.firstVolumeNames(of: final).isEmpty { return false }
        if ["bin", "dat", "data", "tmp", "temp", "file", "unknown"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return true }
        return type.isDynamic
    }
}
