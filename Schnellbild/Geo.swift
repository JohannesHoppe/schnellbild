import Foundation
import AVFoundation
import ImageIO

/// A place on Earth (WGS 84, as cameras and phones write it).
struct GeoPoint: Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    /// Nil outside ±90° / ±180° or for a value that is no number.
    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The great-circle distance in metres (haversine, on a sphere of the
    /// Earth's mean radius: within half a percent of the ellipsoid's).
    func distance(to other: GeoPoint) -> Double {
        let radius = 6_371_008.8
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let Δφ = (other.latitude - latitude) * .pi / 180
        let Δλ = (other.longitude - longitude) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// "48.1372° N, 11.5756° E" (four decimals: about 10 m).
    var text: String {
        func part(_ value: Double, _ positive: String, _ negative: String) -> String {
            let number = abs(value).formatted(.number.precision(.fractionLength(4)).locale(Locale(identifier: "en_US_POSIX")))
            return "\(number)° \(value < 0 ? negative : positive)"
        }
        return part(latitude, "N", "S") + ", " + part(longitude, "E", "W")
    }

    /// "48.137200,11.575600": what map links and the preferences take.
    var decimalPair: String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    /// Apple Maps at this place (opens the Maps app; online).
    var appleMapsURL: URL? {
        URL(string: "https://maps.apple.com/?ll=\(decimalPair)&q=\(decimalPair)")
    }

    /// "12 km", "850 m", "7.4 mi": the units of the user's region.
    static func describeDistance(_ metres: Double) -> String {
        let measurement = Measurement(value: metres, unit: UnitLength.meters)
        let digits = metres < 10_000 ? 0...1 : 0...0
        return measurement.formatted(.measurement(width: .abbreviated, usage: .road,
                                                  numberFormatStyle: .number.precision(.fractionLength(digits))))
    }
}

// MARK: - Reading coordinates people paste

extension GeoPoint {
    /// Coordinates from what a user pastes: "48.137, 11.575", "48.137 N
    /// 11.575 E", "N 48° 8' 14\" E 11° 34' 27\"", "48°8.23'N 11°34.45'E",
    /// "48,137 11,575", a `geo:` URI, or an Apple Maps, Google Maps or
    /// OpenStreetMap link. Nil when it is none of these (or a short link,
    /// which only its server can resolve: `isShortMapLink`).
    static func parse(_ input: String) -> GeoPoint? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 4_000 else { return nil }
        if let point = fromLink(text) { return point }
        if text.contains("://") { return nil }
        return fromText(text)
    }

    /// A link Google Maps shortens (maps.app.goo.gl, goo.gl/maps): its
    /// place is known only to the server it points at.
    static func isShortMapLink(_ input: String) -> Bool {
        guard let host = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "maps.app.goo.gl" || host == "goo.gl" || host == "g.co"
    }

    // MARK: Links

    private static func fromLink(_ text: String) -> GeoPoint? {
        let lower = text.lowercased()
        if lower.hasPrefix("geo:") {
            // geo:48.137,11.575;u=35 or geo:0,0?q=48.137,11.575
            let body = text.dropFirst(4)
            if let query = body.split(separator: "?", maxSplits: 1).dropFirst().first,
               let q = queryItems(String(query))["q"], let point = pair(q) { return point }
            let coordinates = body.split(whereSeparator: { $0 == ";" || $0 == "?" }).first.map(String.init) ?? ""
            return pair(coordinates)
        }
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("maps://") || lower.hasPrefix("comgooglemaps://"),
              let components = URLComponents(string: text) else { return nil }
        let host = components.host?.lowercased() ?? ""
        let items = queryItems(components.percentEncodedQuery ?? "")
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        // OpenStreetMap: a marker (mlat / mlon), else the map's middle (#map=zoom/lat/lon)
        if let lat = items["mlat"].flatMap(Double.init), let lon = items["mlon"].flatMap(Double.init),
           let point = GeoPoint(latitude: lat, longitude: lon) { return point }
        if let fragment = components.fragment, let range = fragment.range(of: "map=") {
            let parts = fragment[range.upperBound...].split(separator: "&").first?.split(separator: "/") ?? []
            if parts.count >= 3, let lat = Double(parts[1]), let lon = Double(parts[2]),
               let point = GeoPoint(latitude: lat, longitude: lon) { return point }
        }
        // Google Maps: a place's pin (!3d lat !4d lon) before the view's middle (@lat,lon,zoom)
        if let point = googlePin(path + "?" + (components.percentEncodedQuery ?? "")) { return point }
        // Apple Maps (ll, q, sll, coordinate), Google (q, query, ll, center, destination), Bing (cp: lat~lon)
        for key in ["ll", "q", "query", "coordinate", "sll", "center", "daddr", "destination", "saddr", "cp", "lat"] {
            if key == "lat", let lat = items["lat"].flatMap(Double.init),
               let lon = (items["lon"] ?? items["lng"]).flatMap(Double.init) {
                return GeoPoint(latitude: lat, longitude: lon)
            }
            if let value = items[key], let point = pair(value.replacingOccurrences(of: "~", with: ",")) { return point }
        }
        // Google's /maps/place/48°08'14"N 11°34'27"E/… or /maps/search/48.137,+11.575: the
        // place, before the view's middle after "@"
        if host.contains("google") || host.contains("apple") || host.contains("openstreetmap") {
            for part in path.split(separator: "/") where !part.hasPrefix("@") {
                if let point = fromText(String(part).replacingOccurrences(of: "+", with: " ")) { return point }
            }
        }
        if let at = path.range(of: "@") {
            let parts = path[at.upperBound...].split(separator: ",")
            if parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
               let point = GeoPoint(latitude: lat, longitude: lon) { return point }
        }
        return nil
    }

    private static func googlePin(_ text: String) -> GeoPoint? {
        guard let lat = text.range(of: "!3d"), let lon = text.range(of: "!4d", range: lat.upperBound..<text.endIndex) else { return nil }
        func number(from start: String.Index) -> Double? {
            let digits = text[start...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(digits)
        }
        guard let la = number(from: lat.upperBound), let lo = number(from: lon.upperBound) else { return nil }
        return GeoPoint(latitude: la, longitude: lo)
    }

    private static func queryItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for part in query.split(separator: "&") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard let name = pieces.first else { continue }
            let raw = pieces.count > 1 ? String(pieces[1]) : ""
            let value = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
            let key = name.lowercased()
            if items[key] == nil { items[key] = value }
        }
        return items
    }

    /// "48.137,11.575" (decimal, as links write it).
    private static func pair(_ text: String) -> GeoPoint? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return GeoPoint(latitude: lat, longitude: lon)
    }

    // MARK: Text

    /// One coordinate as written: degrees (with minutes and seconds) and a
    /// hemisphere letter before or after it.
    private struct Component {
        var degrees: Double?
        var minutes: Double?
        var seconds: Double?
        var negative = false
        var letter: Character?
        var hasNumber: Bool { degrees != nil }

        var value: Double? {
            guard let degrees else { return nil }
            if let minutes, minutes >= 60 { return nil }
            if let seconds, seconds >= 60 { return nil }
            if (minutes != nil || seconds != nil), degrees != degrees.rounded(.towardZero) { return nil }
            let magnitude = abs(degrees) + (minutes ?? 0) / 60 + (seconds ?? 0) / 3600
            let south = letter == "S" || letter == "W"
            return (negative || degrees < 0 || south) ? -magnitude : magnitude
        }
    }

    private enum Token: Equatable {
        case letter(Character)
        case number(Double, unit: Character?, negative: Bool)
    }

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"[NSEW]|([+-]?)\s*(\d+(?:\.\d+)?)\s*([°'"])?"#)

    static func fromText(_ input: String) -> GeoPoint? {
        var text = input.uppercased()
        for (from, to) in [("º", "°"), ("˚", "°"), ("′", "'"), ("’", "'"), ("‘", "'"), ("´", "'"), ("`", "'"),
                           ("″", "\""), ("”", "\""), ("“", "\""), ("''", "\""), ("−", "-"),
                           ("NORTH", "N"), ("SOUTH", "S"), ("EAST", "E"), ("WEST", "W")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        // A decimal comma ("48,137 11,575", "48,137; 11,575"): only where no
        // point is written and the comma can't be the separator
        if !text.contains("."), text.range(of: #"^\s*[+-]?\d+,\d+\s*[;\s]\s*[+-]?\d+,\d+\s*$"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        var tokens: [Token] = []
        var last = text.startIndex
        let ns = text as NSString
        for match in tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text) else { return nil }
            // Only separators between the tokens
            if text[last..<range.lowerBound].contains(where: { !($0.isWhitespace || $0 == "," || $0 == ";" || $0 == "/") }) { return nil }
            last = range.upperBound
            let whole = ns.substring(with: match.range)
            if whole.count == 1, let c = whole.first, "NSEW".contains(c) {
                tokens.append(.letter(c))
                continue
            }
            guard let numberRange = Range(match.range(at: 2), in: text), let number = Double(text[numberRange]) else { return nil }
            let sign = Range(match.range(at: 1), in: text).map { text[$0] } ?? ""
            let unit = Range(match.range(at: 3), in: text).flatMap { text[$0].first }
            tokens.append(.number(number, unit: unit, negative: sign == "-"))
        }
        if text[last...].contains(where: { !($0.isWhitespace || $0 == "," || $0 == ";" || $0 == "/") }) { return nil }
        guard let components = group(tokens), components.count == 2 else { return nil }
        // By the letters where they're written, else latitude first
        var latitude = components[0], longitude = components[1]
        let isLongitude: (Component) -> Bool = { $0.letter == "E" || $0.letter == "W" }
        let isLatitude: (Component) -> Bool = { $0.letter == "N" || $0.letter == "S" }
        if isLongitude(latitude) || isLatitude(longitude) { swap(&latitude, &longitude) }
        guard !isLongitude(latitude), !isLatitude(longitude),
              let lat = latitude.value, let lon = longitude.value else { return nil }
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// The tokens as coordinates. Letters stand either all before their
    /// numbers ("N 48 E 11") or all after them ("48 N 11 E").
    private static func group(_ tokens: [Token]) -> [Component]? {
        guard !tokens.isEmpty else { return nil }
        let lettersFirst = tokens.first.map { if case .letter = $0 { return true } else { return false } } ?? false
        var result: [Component] = []
        var current = Component()
        var pendingLetter: Character?
        func close() {
            if current.hasNumber { result.append(current) }
            current = Component()
        }
        for token in tokens {
            switch token {
            case .letter(let letter):
                if lettersFirst {
                    close()
                    guard pendingLetter == nil else { return nil }
                    pendingLetter = letter
                } else {
                    guard current.hasNumber, current.letter == nil else { return nil }
                    current.letter = letter
                    close()
                }
            case .number(let value, let unit, let negative):
                switch unit {
                case "'":
                    guard current.hasNumber, current.minutes == nil, current.seconds == nil, !negative else { return nil }
                    current.minutes = value
                case "\"":
                    guard current.hasNumber, current.seconds == nil, !negative else { return nil }
                    current.seconds = value
                default:
                    close()
                    current.degrees = value
                    current.negative = negative
                    if lettersFirst {
                        guard let letter = pendingLetter else { return nil }
                        current.letter = letter
                        pendingLetter = nil
                    }
                }
            }
        }
        close()
        guard pendingLetter == nil else { return nil }
        // A letter and a minus sign on one coordinate say two things
        if result.contains(where: { $0.negative && $0.letter != nil }) { return nil }
        return result
    }
}

// MARK: - ISO 6709 (QuickTime's location)

extension GeoPoint {
    /// "+48.1372+011.5756+520.000/" as iPhones write it into videos (also the
    /// degrees-minutes(-seconds) forms "+4808.23+01134.54/"), with the
    /// altitude in metres when it is given.
    static func iso6709(_ text: String) -> (point: GeoPoint, altitude: Double?)? {
        let pattern = #"^\s*([+-])(\d+(?:\.\d+)?)([+-])(\d+(?:\.\d+)?)(?:([+-]\d+(?:\.\d+)?))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
        guard let latSign = group(1), let latDigits = group(2), let lonSign = group(3), let lonDigits = group(4),
              let lat = sexagesimal(latDigits, degreeDigits: 2), let lon = sexagesimal(lonDigits, degreeDigits: 3),
              let point = GeoPoint(latitude: latSign == "-" ? -lat : lat, longitude: lonSign == "-" ? -lon : lon)
        else { return nil }
        return (point, group(5).flatMap(Double.init))
    }

    /// ISO 6709's DD(D).dd, DD(D)MM.mm or DD(D)MMSS.ss, by the number of
    /// digits before the point.
    private static func sexagesimal(_ text: String, degreeDigits: Int) -> Double? {
        let parts = text.split(separator: ".", maxSplits: 1)
        let whole = String(parts.first ?? "")
        let fraction = parts.count > 1 ? "." + parts[1] : ""
        switch whole.count - degreeDigits {
        case ...0: return Double(text)
        case 2:
            guard let d = Double(whole.prefix(degreeDigits)), let m = Double(whole.dropFirst(degreeDigits) + fraction), m < 60 else { return nil }
            return d + m / 60
        case 4:
            guard let d = Double(whole.prefix(degreeDigits)),
                  let m = Double(whole.dropFirst(degreeDigits).prefix(2)),
                  let s = Double(whole.dropFirst(degreeDigits + 2) + fraction), m < 60, s < 60 else { return nil }
            return d + m / 60 + s / 3600
        default: return nil
        }
    }
}

// MARK: - Where a photo or video was taken

/// A file's place with what else its metadata says about it.
struct MediaLocation: Equatable, Sendable {
    var point: GeoPoint
    /// Metres above sea level (negative below).
    var altitude: Double?
    /// Where the camera looked, in degrees, and whether from true north.
    var direction: Double?
    var trueNorth = true

    /// From ImageIO's properties of a picture (its GPS dictionary).
    static func picture(_ properties: [CFString: Any]) -> MediaLocation? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return nil }
        func number(_ key: CFString) -> Double? { (gps[key] as? NSNumber)?.doubleValue ?? (gps[key] as? String).flatMap(Double.init) }
        guard var lat = number(kCGImagePropertyGPSLatitude), var lon = number(kCGImagePropertyGPSLongitude) else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -abs(lat) }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lon = -abs(lon) }
        // A camera without a fix writes zeros
        guard !(lat == 0 && lon == 0), let point = GeoPoint(latitude: lat, longitude: lon) else { return nil }
        var location = MediaLocation(point: point)
        if let altitude = number(kCGImagePropertyGPSAltitude), altitude.isFinite {
            let below = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1
            location.altitude = below ? -abs(altitude) : altitude
        }
        if let direction = number(kCGImagePropertyGPSImgDirection), direction.isFinite, (0...360).contains(direction) {
            location.direction = direction
            location.trueNorth = (gps[kCGImagePropertyGPSImgDirectionRef] as? String)?.uppercased() != "M"
        }
        return location
    }

    /// From a video's QuickTime metadata (ISO 6709, as iPhones and most
    /// cameras write it).
    static func video(_ items: [AVMetadataItem]) async -> MediaLocation? {
        let identifiers: [AVMetadataIdentifier] = [.quickTimeMetadataLocationISO6709, .commonIdentifierLocation,
                                                    .quickTimeUserDataLocationISO6709]
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let text = try? await item.load(.stringValue), let found = GeoPoint.iso6709(text) {
                    return MediaLocation(point: found.point, altitude: found.altitude)
                }
            }
        }
        return nil
    }

    /// A file's place, read from its header (a picture's properties, a
    /// video's metadata); nil inside archives (they aren't unpacked for this)
    /// and for files without one. Waits on the disk: call it off the main thread.
    static func read(_ url: URL) async -> GeoPoint? {
        guard !ArchivePath.isInside(url) else { return nil }
        switch BrowserModel.mediaKind(of: url) {
        case .image:
            return await Blocking.run(.utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
                else { return nil }
                return picture(props)?.point
            }
        case .video:
            let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
            guard let items = try? await asset.load(.metadata) else { return nil }
            return await video(items)?.point
        default:
            return nil
        }
    }
}

/// The places read so far, by file (path and modification date), so sorting
/// by distance again (another origin, the same folder later, search results)
/// reads no header twice. Thread-safe.
final class LocationCache: @unchecked Sendable {
    static let shared = LocationCache()

    private struct Known { let modified: Date?; let point: GeoPoint? }
    private var known: [String: Known] = [:]
    private let lock = NSLock()
    private let read: @Sendable (URL) async -> GeoPoint?
    /// More files than this and the oldest knowledge goes (all of it: the
    /// entries are small, a folder read again is quick).
    private let limit: Int

    init(limit: Int = 500_000, read: @escaping @Sendable (URL) async -> GeoPoint? = { await MediaLocation.read($0) }) {
        self.limit = limit
        self.read = read
    }

    /// The place known for this version of the file: `.some(nil)` when it
    /// was read and has none, nil when it hasn't been read.
    func cached(_ url: URL, modified: Date?) -> GeoPoint?? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = known[BrowserModel.canonicalPath(url)], entry.modified == modified else { return nil }
        return .some(entry.point)
    }

    func store(_ point: GeoPoint?, for url: URL, modified: Date?) {
        lock.lock(); defer { lock.unlock() }
        if known.count >= limit { known.removeAll(keepingCapacity: true) }
        known[BrowserModel.canonicalPath(url)] = Known(modified: modified, point: point)
    }

    /// The place of one file, from the cache or its header.
    func point(of url: URL, modified: Date?) async -> GeoPoint? {
        if let cached = cached(url, modified: modified) { return cached }
        let point = await read(url)
        if !Task.isCancelled { store(point, for: url, modified: modified) }
        return point
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
