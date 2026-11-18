import Foundation
import AVFoundation
import ImageIO

// MARK: - When and where, from wherever it is written

/// Where a time or a place was read.
enum MetadataSource: Hashable, Sendable {
    /// The file's own header: EXIF, QuickTime metadata, the MP4 user data.
    case file
    /// The MP4 / QuickTime movie header's creation time (UTC).
    case movieHeader
    /// GoPro's GPMF telemetry track.
    case goPro
    /// A DJI drone's `.SRT` beside the video (its file name).
    case djiLog(String)
    /// An XMP sidecar or a camera's clip XML (its file name).
    case sidecar(String)
    /// XMP inside the file.
    case embeddedXMP
    /// A GPX track in the same folder (its file name).
    case gpxTrack(String)

    /// What the Inspector says about a place from here.
    var placeText: String {
        switch self {
        case .file, .movieHeader: return String(localized: "GPS in the file")
        case .goPro: return String(localized: "GPS from GoPro telemetry")
        case .djiLog(let name): return String(localized: "From DJI flight log \(name)")
        case .sidecar(let name): return String(localized: "From \(name)")
        case .embeddedXMP: return String(localized: "From the file's XMP data")
        case .gpxTrack(let name): return String(localized: "From GPX track \(name)")
        }
    }

    /// What the Inspector says about a time from here; nil for the file's
    /// own capture date (EXIF, QuickTime), which needs no note.
    var timeText: String? {
        switch self {
        case .file: return nil
        case .movieHeader: return String(localized: "From the movie header (UTC)")
        case .goPro: return String(localized: "GPS time from GoPro telemetry")
        default: return placeText
        }
    }
}

/// How exact a place is, as far as its source says.
enum PlaceAccuracy: Hashable, Sendable {
    /// The horizontal error in metres (EXIF's GPSHPositioningError).
    case metres(Double)
    /// GPS dilution of precision (GoPro).
    case dilution(Double)
    /// Placed on a track by time, this far from its nearer point.
    case interpolated(TimeInterval)

    var text: String {
        switch self {
        case .metres(let metres):
            return "±" + Measurement(value: metres, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
        case .dilution(let value):
            let number = value.formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "DOP \(number)")
        case .interpolated(let gap):
            let time = Duration.seconds(Int(gap.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            return String(localized: "Interpolated, \(time) from the nearest track point")
        }
    }
}

struct CapturePlace: Equatable, Sendable {
    var location: MediaLocation
    var source: MetadataSource
    var accuracy: PlaceAccuracy?
}

/// When a photo or video was taken.
struct CaptureTime: Equatable, Sendable {
    /// The moment.
    var date: Date
    /// Seconds east of UTC where the source states it.
    var offset: Int?
    /// A camera clock whose zone isn't known: `date` reads it in the Mac's
    /// time zone (as the Finder and Photos do).
    var isCameraClock: Bool
    var source: MetadataSource

    init(_ reading: ClockReading, source: MetadataSource, zone: TimeZone = .current) {
        date = reading.instant(in: zone)
        offset = reading.offset
        isCameraClock = reading.offset == nil
        self.source = source
    }

    /// A moment in UTC (GPS, a movie header).
    init(utc date: Date, source: MetadataSource) {
        self.date = date
        offset = nil
        isCameraClock = false
        self.source = source
    }

    /// As the camera's clock showed it with its offset ("Jun 18, 2024,
    /// 10:31:09 PM (UTC+02:00)"), else in the Mac's time zone.
    var text: String {
        var style = Date.FormatStyle(date: .abbreviated, time: .standard)
        guard let offset else { return date.formatted(style) }
        style.timeZone = TimeZone(secondsFromGMT: offset) ?? .current
        let sign = offset < 0 ? "-" : "+"
        let shown = String(format: "%@%02d:%02d", sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
        return "\(date.formatted(style)) (UTC\(shown))"
    }
}

/// A route: a video's GPS track (GoPro, DJI), spread over its length.
struct GeoTrack: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var point: GeoPoint
        var altitude: Double?
        var time: Date?
    }

    var points: [Point]
    var source: MetadataSource

    /// At most this many points are kept.
    static let largest = 500

    /// Metres along the points.
    var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.point.distance(to: $1.1.point) }
    }

    /// Evenly thinned to `largest`, the last point kept.
    static func thinned(_ points: [Point]) -> [Point] {
        guard points.count > largest else { return points }
        let step = Double(points.count - 1) / Double(largest - 1)
        return (0..<largest).map { points[Int((Double($0) * step).rounded())] }
    }
}

/// Everything known about when and where a file was taken.
struct CaptureFacts: Equatable, Sendable {
    var time: CaptureTime?
    var place: CapturePlace?
    var track: GeoTrack?

    var isEmpty: Bool { time == nil && place == nil && track == nil }
}

// MARK: - Files beside a file

/// The files next to a photo or video that say more about it: XMP sidecars
/// (`name.xmp`, Adobe's form, and `name.ext.xmp`, darktable's and others'),
/// a DJI drone's `name.SRT`, a Sony camera's `nameM01.XML`, and the GPX tracks
/// of the folder. Names compare without case. Inside archives: none.
struct Companions: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let url: URL
        let modified: Date?
        var name: String { url.lastPathComponent }
    }

    /// Most specific first.
    var xmp: [File] = []
    var flightLog: File?
    var clipXML: File?
    var tracks: [File] = []

    /// What a cached reading depends on: the files and their dates.
    var stamp: String {
        (xmp + [flightLog, clipXML].compactMap { $0 } + tracks)
            .map { "\($0.url.path)@\($0.modified?.timeIntervalSince1970 ?? -1)" }.joined(separator: "|")
    }

    /// At most this many GPX files of a folder are looked at.
    static let largestTrackCount = 50

    /// Waits on the disk: call it off Swift's threads (`Blocking.run`).
    static func of(_ url: URL, names: FolderNames = .shared) -> Companions {
        guard !ArchivePath.isInside(url) else { return Companions() }
        let folder = url.deletingLastPathComponent()
        let found = names.listing(of: folder)
        let listing = found.names
        guard !listing.isEmpty else { return related(of: url) }
        let name = url.lastPathComponent
        let base = url.deletingPathExtension().lastPathComponent
        func file(_ wanted: String) -> File? {
            guard let actual = listing[wanted.lowercased()], actual != name else { return nil }
            let found = folder.appendingPathComponent(actual)
            return File(url: found, modified: try? found.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
        var companions = Companions()
        companions.xmp = [file(name + ".xmp"), file(base + ".xmp")].compactMap { $0 }
        if BrowserModel.mediaKind(of: url) == .video {
            companions.flightLog = file(base + ".srt")
            companions.clipXML = file(base + "M01.xml")
        }
        // Their dates from the listing: a folder of thousands of photos
        // doesn't ask the disk for every track again per photo
        companions.tracks = found.tracks.compactMap { track in
            listing[track.name].map { File(url: folder.appendingPathComponent($0), modified: track.modified) }
        }
        return companions
    }

    /// A file the App Sandbox opened alone (its folder can't be listed):
    /// the companions of its own name with another extension, opened to the
    /// app as related items (`RelatedFiles`). A Sony clip's XML and the
    /// folder's GPX tracks have other names: they need the folder.
    static func related(of url: URL) -> Companions {
        guard RelatedFiles.isAlone(url) else { return Companions() }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        func file(_ name: String) -> File? {
            let candidate = folder.appendingPathComponent(name)
            guard RelatedFiles.open(candidate, beside: url) else { return nil }
            return File(url: candidate, modified: try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
        var companions = Companions()
        companions.xmp = [file(url.lastPathComponent + ".xmp"), file(base + ".xmp")].compactMap { $0 }
        if BrowserModel.mediaKind(of: url) == .video { companions.flightLog = file(base + ".SRT") ?? file(base + ".srt") }
        return companions
    }
}

/// The names in folders, by their lower-case form; read again when the
/// folder's date changes (checked at most every two seconds, when also the
/// GPX files' dates are read again: a track edited in place leaves the
/// folder's date as it was). Thread-safe; waits on the disk.
final class FolderNames: @unchecked Sendable {
    static let shared = FolderNames()

    /// A folder's names by their lower-case form, and its first
    /// `Companions.largestTrackCount` GPX files (lower case, sorted) with
    /// their dates.
    struct Listing {
        var names: [String: String] = [:]
        var tracks: [(name: String, modified: Date?)] = []
    }

    private struct Known { var checked: Date; var modified: Date?; var listing: Listing }
    private var known: [String: Known] = [:]
    private let lock = NSLock()
    private let recheck: TimeInterval

    init(recheck: TimeInterval = 2) { self.recheck = recheck }

    func listing(of folder: URL) -> Listing {
        let path = BrowserModel.canonicalPath(folder)
        lock.lock()
        if let entry = known[path], Date().timeIntervalSince(entry.checked) < recheck {
            lock.unlock()
            return entry.listing
        }
        let previous = known[path]
        lock.unlock()
        let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var listing = previous?.listing ?? Listing()
        var trackNames = listing.tracks.map(\.name)
        if previous == nil || previous?.modified != modified || modified == nil {
            listing = Listing()
            trackNames = []
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let lower = name.lowercased()
                listing.names[lower] = name
                // Hidden tracks too (hiding is about what the grid shows); "._" files are AppleDouble, no GPX
                if lower.hasSuffix(".gpx"), !lower.hasPrefix("._") { trackNames.append(lower) }
            }
            trackNames.sort()
        }
        listing.tracks = trackNames.prefix(Companions.largestTrackCount).compactMap { lower in
            listing.names[lower].map { name in
                (lower, try? folder.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            }
        }
        lock.lock()
        if known.count > 2_000 { known.removeAll(keepingCapacity: true) }
        known[path] = Known(checked: Date(), modified: modified, listing: listing)
        lock.unlock()
        return listing
    }
}

/// GPX files read, by path and date (a folder's tracks serve all its
/// photos). A file being parsed is parsed once: other callers wait for it.
/// Blocks: call it off Swift's threads.
final class TrackFiles: @unchecked Sendable {
    static let shared = TrackFiles()

    private final class Entry: @unchecked Sendable {
        let modified: Date?
        var track: GPXTrack?
        /// Left once `track` is set.
        let parsed = DispatchGroup()
        init(modified: Date?) { self.modified = modified; parsed.enter() }
    }

    private var known: [String: Entry] = [:]
    private let lock = NSLock()
    private let read: (URL) -> GPXTrack?

    init(read: @escaping (URL) -> GPXTrack? = { SidecarFile.read($0, limit: GPXTrack.largest).flatMap(GPXTrack.read) }) {
        self.read = read
    }

    func track(_ file: Companions.File) -> GPXTrack? {
        let path = file.url.path
        lock.lock()
        if let entry = known[path], entry.modified == file.modified {
            lock.unlock()
            entry.parsed.wait()
            return entry.track
        }
        let entry = Entry(modified: file.modified)
        if known.count >= 64 { known.removeAll() }
        known[path] = entry
        lock.unlock()
        entry.track = read(file.url)
        entry.parsed.leave()
        return entry.track
    }
}

// MARK: - Reading

/// Reads a file's capture facts from its header and its companions, in this
/// order of preference:
/// - time: an XMP sidecar (what an editor wrote last), the file's own (EXIF
///   DateTimeOriginal with OffsetTimeOriginal, then DateTimeDigitized,
///   DateTime; QuickTime's creation date with its offset), Sony's clip XML,
///   XMP inside the file, GoPro's GPS time, a DJI flight log's clock, the
///   movie header (UTC);
/// - place: an XMP sidecar, the file's own (EXIF GPS, QuickTime ISO 6709,
///   `©xyz`), GoPro's first good fix, a DJI flight log's first fix, Sony's
///   clip XML, XMP inside the file, and for anything still without a place,
///   a GPX track of the folder at the capture time;
/// - track: GoPro's telemetry, else a DJI flight log.
/// Files are only read; nothing is written.
enum CaptureReader {
    /// GoPro payloads read for the first good fix, and for the track.
    static let fixSamples = 120
    static let trackSamples = 300

    static func facts(of url: URL, companions: Companions? = nil) async -> CaptureFacts {
        guard !ArchivePath.isInside(url) else { return CaptureFacts() }
        // The folder and the files beside it: off Swift's threads, they wait on the disk
        let given = companions
        let (companions, sidecar) = await Blocking.run(.utility) { () -> (Companions, (String, XMPMetadata.Facts)?) in
            let companions = given ?? Companions.of(url)
            let sidecar = companions.xmp.lazy.compactMap { file in
                SidecarFile.read(file.url, limit: XMPMetadata.largest).flatMap(XMPMetadata.read).map { (file.name, $0) }
            }.first
            return (companions, sidecar)
        }
        var times: [CaptureTime?] = []
        var places: [CapturePlace?] = []
        var track: GeoTrack?
        times.append(sidecar.flatMap { name, facts in facts.time.map { CaptureTime($0, source: .sidecar(name)) } })
        places.append(sidecar.flatMap { name, facts in
            facts.location.map { CapturePlace(location: $0, source: .sidecar(name), accuracy: facts.accuracy.map(PlaceAccuracy.metres)) }
        })
        switch BrowserModel.mediaKind(of: url) {
        case .image:
            let own = await Blocking.run(.utility) { picture(url) }
            times.append(own.time)
            places.append(own.place)
        case .video:
            let own = await video(url, companions: companions)
            times += own.times
            places += own.places
            track = own.track
        default:
            return CaptureFacts()
        }
        var facts = CaptureFacts(time: times.lazy.compactMap { $0 }.first, place: places.lazy.compactMap { $0 }.first, track: track)
        if facts.place == nil, let time = facts.time {
            facts.place = await Blocking.run(.utility) { placeOnTracks(at: time.date, companions.tracks) }
        }
        return facts
    }

    /// The best place on the folder's GPX tracks at `date`.
    static func placeOnTracks(at date: Date, _ files: [Companions.File], tracks: TrackFiles = .shared) -> CapturePlace? {
        var best: (place: CapturePlace, gap: TimeInterval)?
        for file in files {
            guard let track = tracks.track(file), let found = track.place(at: date) else { continue }
            if best == nil || found.gap < best!.gap {
                best = (CapturePlace(location: MediaLocation(point: found.point, altitude: found.altitude),
                                     source: .gpxTrack(file.name), accuracy: .interpolated(found.gap)), found.gap)
            }
        }
        return best?.place
    }

    // MARK: Pictures

    static func picture(_ url: URL) -> (time: CaptureTime?, place: CapturePlace?) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else { return (nil, nil) }
        return picture(props)
    }

    static func picture(_ props: [CFString: Any]) -> (time: CaptureTime?, place: CapturePlace?) {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var time: CaptureTime?
        for case let (text?, offset) in pictureClocks(exif: exif, tiff: tiff) {
            if var reading = ClockReading.parse(text) {
                reading.offset = offset.flatMap(ClockReading.offset)
                time = CaptureTime(reading, source: .file)
                break
            }
        }
        var place: CapturePlace?
        if let location = MediaLocation.picture(props) {
            let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            let error = (gps?[kCGImagePropertyGPSHPositioningError] as? NSNumber)?.doubleValue
            place = CapturePlace(location: location, source: .file,
                                 accuracy: error.flatMap { $0.isFinite && $0 >= 0 && $0 < 1_000_000 ? .metres($0) : nil })
        }
        return (time, place)
    }

    /// EXIF's capture times with their offsets, the original first.
    static func pictureClocks(exif: [CFString: Any], tiff: [CFString: Any]) -> [(String?, String?)] {
        [(exif[kCGImagePropertyExifDateTimeOriginal] as? String, exif[kCGImagePropertyExifOffsetTimeOriginal] as? String),
         (exif[kCGImagePropertyExifDateTimeDigitized] as? String, exif[kCGImagePropertyExifOffsetTimeDigitized] as? String),
         (tiff[kCGImagePropertyTIFFDateTime] as? String, exif[kCGImagePropertyExifOffsetTime] as? String)]
    }

    // MARK: Videos

    struct VideoFacts {
        var times: [CaptureTime?] = []
        var places: [CapturePlace?] = []
        var track: GeoTrack?
    }

    static func video(_ url: URL, companions: Companions) async -> VideoFacts {
        var result = VideoFacts()
        // QuickTime metadata through AVFoundation (also the `mdta` keys iPhones write)
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let items = await VideoMetadata.allMetadata(asset)
        var ownTime: CaptureTime?
        for identifier: AVMetadataIdentifier in [.quickTimeMetadataCreationDate, .commonIdentifierCreationDate, .quickTimeUserDataCreationDate] {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) where ownTime == nil {
                if let text = try? await item.load(.stringValue), let reading = ClockReading.parse(text) {
                    ownTime = CaptureTime(reading, source: .file)
                } else if let date = try? await item.load(.dateValue) {
                    ownTime = CaptureTime(utc: date, source: .file)
                }
            }
        }
        let ownPlace = await MediaLocation.video(items).map { CapturePlace(location: $0, source: .file) }
        // The boxes, the telemetry and the files beside it: off the main thread, they wait on the disk
        let rest = await Blocking.run(.utility) { () -> (movie: MP4Boxes.Movie?, goPro: (fix: GPMF.Fix?, time: Date?, track: [GeoTrack.Point])?,
                                                       dji: DJIFlightLog.Log?, clip: SonyClipXML.Facts?, xmp: XMPMetadata.Facts?) in
            let file = FileBytes(url)
            let movie = file.flatMap(MP4Boxes.read)
            let goPro = file.flatMap { file in movie.flatMap { telemetry(file, $0.telemetry, starts: $0.telemetryStarts) } }
            let dji = companions.flightLog.flatMap { SidecarFile.read($0.url, limit: DJIFlightLog.largest) }.flatMap(DJIFlightLog.read)
            let clip = companions.clipXML.flatMap { SidecarFile.read($0.url, limit: SonyClipXML.largest) }.flatMap(SonyClipXML.read)
            let xmp = movie?.xmp.flatMap { XMPMetadata.read(Data($0)) }
            return (movie, goPro, dji, clip, xmp)
        }
        // A date AVFoundation reports that is the movie header's own moment
        // ranks as the header (a GoPro writes its local clock there)
        if let time = ownTime, time.offset == nil, let created = rest.movie?.created, abs(time.date.timeIntervalSince(created)) < 1 {
            ownTime = nil
        }
        let djiName = companions.flightLog?.name ?? ""
        let clipName = companions.clipXML?.name ?? ""
        result.times = [
            ownTime,
            rest.clip?.time.map { CaptureTime($0, source: .sidecar(clipName)) },
            rest.xmp?.time.map { CaptureTime($0, source: .embeddedXMP) },
            rest.goPro?.time.map { CaptureTime(utc: $0, source: .goPro) },
            rest.dji?.start.map { CaptureTime($0, source: .djiLog(djiName)) },
            rest.movie?.created.map { CaptureTime(utc: $0, source: .movieHeader) },
        ]
        result.places = [
            ownPlace,
            rest.movie?.location.map { CapturePlace(location: $0, source: .file) },
            rest.goPro?.fix.map { fix in
                CapturePlace(location: MediaLocation(point: fix.point, altitude: fix.altitude), source: .goPro,
                             accuracy: fix.dilution.map(PlaceAccuracy.dilution))
            },
            rest.dji?.first.flatMap { record in
                record.point.map { CapturePlace(location: MediaLocation(point: $0, altitude: record.altitude), source: .djiLog(djiName)) }
            },
            rest.clip?.location.map { CapturePlace(location: $0, source: .sidecar(clipName)) },
            rest.xmp?.location.map { CapturePlace(location: $0, source: .embeddedXMP, accuracy: rest.xmp?.accuracy.map(PlaceAccuracy.metres)) },
        ]
        if let points = rest.goPro?.track, points.count > 1 {
            result.track = GeoTrack(points: points, source: .goPro)
        } else if let log = rest.dji, log.track.count > 1 {
            // The drone's clock has no zone: its track's times are read in the Mac's
            let points = log.track.compactMap { record in
                record.point.map { GeoTrack.Point(point: $0, altitude: record.altitude, time: record.clock?.instant()) }
            }
            result.track = GeoTrack(points: GeoTrack.thinned(points), source: .djiLog(djiName))
        }
        return result
    }

    /// GoPro's first good fix (else its first locked one), the video's start by GPS time (the first fix's
    /// time less its payload's place in the video), and a track of one
    /// fix per payload read, at most `trackSamples` payloads spread over the
    /// video. Nil when the telemetry has no GPS.
    static func telemetry(_ file: ByteSource, _ samples: [Range<UInt64>], starts: [Double] = []) -> (fix: GPMF.Fix?, time: Date?, track: [GeoTrack.Point])? {
        guard !samples.isEmpty else { return nil }
        func fixes(_ index: Int) -> [GPMF.Fix] {
            let range = samples[index]
            guard range.count <= MP4Boxes.largestSample, let bytes = file.read(at: range.lowerBound, count: Int(range.count)) else { return [] }
            return GPMF.fixes(in: bytes)
        }
        // The first good fix; failing that (a dilution never under 5), the first locked one
        var first: GPMF.Fix?
        var locked: GPMF.Fix?
        var time: Date?
        for index in 0..<min(samples.count, fixSamples) {
            let found = fixes(index).filter(\.isLocked)
            if locked == nil { locked = found.first }
            if first == nil { first = found.first(where: \.isGood) }
            // The video began this long before the payload
            if time == nil, let fixTime = found.lazy.compactMap(\.time).first {
                time = fixTime.addingTimeInterval(-(index < starts.count ? starts[index] : 0))
            }
            if first != nil, time != nil { break }
        }
        first = first ?? locked
        var track: [GeoTrack.Point] = []
        let step = max(1, samples.count / trackSamples)
        for index in stride(from: 0, to: samples.count, by: step) {
            if let fix = fixes(index).first(where: \.isLocked) {
                track.append(GeoTrack.Point(point: fix.point, altitude: fix.altitude, time: fix.time))
            }
        }
        if first == nil, time == nil, track.isEmpty { return nil }
        return (first, time, GeoTrack.thinned(track))
    }
}

extension ClockReading {
    /// EXIF's OffsetTime* ("+02:00", "-05:30"); nil for anything else.
    static func offset(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^[+-]\d\d:\d\d$"#, options: .regularExpression) != nil,
              let hours = Int(value.dropFirst().prefix(2)), let minutes = Int(value.suffix(2)), hours <= 18, minutes < 60 else { return nil }
        return (value.hasPrefix("-") ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
}

// MARK: - Cache

/// The capture facts read so far, by file: its path, its modification date
/// and its companions' (an XMP sidecar or a GPX track edited reads it again),
/// so sorting again (another origin, the same folder later, search results)
/// reads no header twice. Thread-safe.
final class LocationCache: @unchecked Sendable {
    static let shared = LocationCache()

    private struct Known { let stamp: String; let facts: CaptureFacts }
    private var known: [String: Known] = [:]
    private let lock = NSLock()
    private let read: @Sendable (URL, Companions) async -> CaptureFacts
    private let companions: @Sendable (URL) -> Companions
    /// More files than this and the oldest knowledge goes (all of it: the
    /// entries are small, a folder read again is quick).
    private let limit: Int

    init(limit: Int = 500_000,
         companions: @escaping @Sendable (URL) -> Companions = { Companions.of($0) },
         read: @escaping @Sendable (URL, Companions) async -> CaptureFacts = { await CaptureReader.facts(of: $0, companions: $1) }) {
        self.limit = limit
        self.companions = companions
        self.read = read
    }

    private func stamp(_ modified: Date?, _ companions: Companions) -> String {
        "\(modified?.timeIntervalSince1970 ?? -1)|\(companions.stamp)"
    }

    /// The facts known for this version of the file and its companions; nil
    /// when they haven't been read. Looks up the companions: waits on the disk.
    func cachedFacts(_ url: URL, modified: Date?) -> CaptureFacts? {
        cachedFacts(url, stamp: stamp(modified, companions(url)))
    }

    private func cachedFacts(_ url: URL, stamp: String) -> CaptureFacts? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = known[BrowserModel.canonicalPath(url)], entry.stamp == stamp else { return nil }
        return entry.facts
    }

    /// The place known: `.some(nil)` when the file was read and has none,
    /// nil when it hasn't been read.
    func cached(_ url: URL, modified: Date?) -> GeoPoint?? {
        cachedFacts(url, modified: modified).map { $0.place?.location.point }
    }

    /// One file's facts, from the cache or the file and its companions.
    /// The companions are looked up off Swift's threads (they wait on the
    /// disk; eight at a time on a stalled share would hold the pool).
    func facts(of url: URL, modified: Date?) async -> CaptureFacts {
        let companions = companions
        let around = await Blocking.run(.utility) { companions(url) }
        let stamp = stamp(modified, around)
        if let cached = cachedFacts(url, stamp: stamp) { return cached }
        let facts = await read(url, around)
        if !Task.isCancelled { store(facts, for: url, stamp: stamp) }
        return facts
    }

    private func store(_ facts: CaptureFacts, for url: URL, stamp: String) {
        lock.lock(); defer { lock.unlock() }
        if known.count >= limit { known.removeAll(keepingCapacity: true) }
        known[BrowserModel.canonicalPath(url)] = Known(stamp: stamp, facts: facts)
    }

    func point(of url: URL, modified: Date?) async -> GeoPoint? {
        await facts(of: url, modified: modified).place?.location.point
    }

    /// The places of many files, eight read at a time; stops early when
    /// cancelled (what wasn't read is left out of the answer).
    func points(of files: [(url: URL, modified: Date?)]) async -> [URL: GeoPoint?] {
        await withTaskGroup(of: (URL, GeoPoint?).self) { group in
            var result: [URL: GeoPoint?] = [:]
            var pending = files[...]
            func addNext() {
                guard !Task.isCancelled, let file = pending.popFirst() else { return }
                group.addTask { (file.url, await self.point(of: file.url, modified: file.modified)) }
            }
            for _ in 0..<8 { addNext() }
            for await (url, point) in group {
                if !Task.isCancelled { result[url] = .some(point) }
                addNext()
            }
            return result
        }
    }
}

extension MediaLocation {
    /// A file's place, from its header and its companions (`CaptureReader`).
    /// Waits on the disk: call it off the main thread.
    static func read(_ url: URL) async -> GeoPoint? {
        await CaptureReader.facts(of: url).place?.location.point
    }
}
