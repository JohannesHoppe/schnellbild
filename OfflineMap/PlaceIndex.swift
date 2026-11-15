import Compression
import Foundation

/// A named place of the place index: a country, region or locality.
public struct Place: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case country = 0, region, city, town, village, hamlet, locality }

    public var coordinate: Coordinate
    public var kind: Kind
    /// The zoom from which the map labels it (lower: more important)
    public var minZoom: Double
    /// Protomaps' population rank (0 unknown, up to about 17 for the largest cities)
    public var populationRank: Int
    public var isCountryCapital: Bool
    public var isRegionCapital: Bool
    /// ISO 3166-1 alpha-2, nil when unknown
    public var countryCode: String?
    /// The name as it is written there
    public var localName: String
    /// The names in other languages that differ from `localName`, by the app's language codes
    public var names: [String: String]

    public var isLocality: Bool { kind.rawValue >= Kind.city.rawValue }
}

/// Which name a label shows: the system's languages in order (as far as the
/// place index has them), then the local name. A local name in another
/// script than the reader's (Japanese for a German reader) gives way to the
/// English one first.
public struct MapLanguages: Equatable, Sendable {
    /// The index's language codes to try, in order
    public var order: [String]
    /// Whether a local name without Latin letters yields to the English one
    public var englishBeforeOtherScripts: Bool

    public init(order: [String], englishBeforeOtherScripts: Bool = false) {
        self.order = order
        self.englishBeforeOtherScripts = englishBeforeOtherScripts
    }

    public static let supported = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi", "cs",
                                   "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]
    private static let latin: Set<String> = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi", "cs", "tr"]

    /// The index's code for a BCP 47 language tag ("de-DE" → "de", "zh-TW" → "zh-Hant",
    /// "pt-PT" → "pt-BR", "no" / "nn" → "nb"), nil when it has none.
    public static func code(for tag: String) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased() else { return nil }
        switch language {
        case "zh":
            let traditional = parts.contains { ["Hant", "TW", "HK", "MO"].contains($0) }
            return traditional ? "zh-Hant" : "zh-Hans"
        case "pt": return "pt-BR"
        case "no", "nn", "nb": return "nb"
        default: return supported.contains(language) ? language : nil
        }
    }

    /// The order for these preferred languages (`Locale.preferredLanguages`).
    public static func preferring(_ tags: [String]) -> MapLanguages {
        var order: [String] = []
        for tag in tags { if let code = code(for: tag), !order.contains(code) { order.append(code) } }
        // Readers of a Latin script get English before a local name they may not read
        return MapLanguages(order: order, englishBeforeOtherScripts: order.first.map { latin.contains($0) } ?? true)
    }

    public static var system: MapLanguages { preferring(Locale.preferredLanguages) }

    /// Whether the text has no Latin letters (the local name of Tokyo for a German reader).
    static func lacksLatin(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value < 0x0250 }
    }
}

extension Place {
    /// The name in the first of the languages that has one, else the local
    /// name; a local name in another script yields to English for a reader
    /// of a Latin script.
    public func label(in languages: MapLanguages) -> String {
        for language in languages.order {
            if let name = names[language] { return name }
        }
        if languages.englishBeforeOtherScripts, MapLanguages.lacksLatin(localName), let english = names["en"] {
            return english
        }
        return localName
    }
}

/// The place index (Scripts/build_map_data.py writes it; the format is
/// described there): memory-mapped, read by one-degree cells. The major
/// places lie in the file as they are; the others, packed per cell, are
/// unpacked when a cell is first read and kept for a while.
public final class PlaceIndex: @unchecked Sendable {
    public enum IndexError: Error { case notAPlaceIndex, malformed }

    struct Block {
        var cell: Int
        var tier: Int
        var packed: Bool
        var count: Int
        var offset: Int
        var storedLength: Int
        var length: Int
    }

    public let placeCount: Int
    public let languages: [String]
    public let build: String
    /// Places with min_zoom below this lie in tier 0
    public let tierSplit: Double
    private let data: Data
    private let blocks: [Block]
    private let countries: [String?]
    /// The political positions' regions (Scripts/build_map_data.py, REGION_COUNTRIES), in order
    private let regions: [Region]

    /// A country's polygon: rings of (latitude, longitude), even-odd inside
    struct Region {
        var code: String
        var rings: [[(Double, Double)]]
        var south, north, west, east: Double

        func contains(_ c: Coordinate) -> Bool {
            guard c.latitude >= south, c.latitude <= north, c.longitude >= west, c.longitude <= east else { return false }
            var inside = false
            for ring in rings where ring.count > 2 {
                var j = ring.count - 1
                for i in ring.indices {
                    let (yi, xi) = ring[i], (yj, xj) = ring[j]
                    if (yi > c.latitude) != (yj > c.latitude),
                       c.longitude < xi + (c.latitude - yi) * (xj - xi) / (yj - yi) { inside.toggle() }
                    j = i
                }
            }
            return inside
        }
    }
    private let cache = NSCache<NSNumber, NSData>()

    static let columns = 360, rows = 180

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 64, data.prefix(8).elementsEqual("SBPLACE1".utf8) else { throw IndexError.notAPlaceIndex }
        let u32 = { (at: Int) -> Int in Self.uint32(data, at) }
        let blockCount = u32(8)
        placeCount = u32(12)
        guard u32(16) == Self.columns, u32(20) == Self.rows, u32(24) == 1_000_000 else { throw IndexError.malformed }
        let tableOffset = u32(28), countriesOffset = u32(32), countriesLength = u32(36)
        let languagesOffset = u32(40), languagesLength = u32(44)
        tierSplit = Double(u32(48)) / 10
        build = String(decoding: data.subdata(in: data.startIndex + 52..<data.startIndex + 60), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard tableOffset + blockCount * 24 <= data.count, countriesOffset + countriesLength <= data.count,
              languagesOffset + languagesLength <= data.count, countriesLength % 2 == 0 else { throw IndexError.malformed }
        var table: [Block] = []
        table.reserveCapacity(blockCount)
        for i in 0..<blockCount {
            let at = tableOffset + 24 * i
            let block = Block(cell: u32(at), tier: Int(data[data.startIndex + at + 4]), packed: data[data.startIndex + at + 5] == 1,
                              count: u32(at + 8), offset: u32(at + 12), storedLength: u32(at + 16), length: u32(at + 20))
            guard block.offset + block.storedLength <= data.count, block.count * 16 <= block.length else { throw IndexError.malformed }
            table.append(block)
        }
        blocks = table
        let codes = String(decoding: data.subdata(in: data.startIndex + countriesOffset..<data.startIndex + countriesOffset + countriesLength), as: UTF8.self)
        var list: [String?] = [nil]
        var it = codes.makeIterator()
        while let a = it.next(), let b = it.next() { list.append(String([a, b])) }
        countries = list
        languages = String(decoding: data.subdata(in: data.startIndex + languagesOffset..<data.startIndex + languagesOffset + languagesLength), as: UTF8.self)
            .split(separator: ",").map(String.init)
        cache.totalCostLimit = 64 << 20
        regions = Self.readRegions(data, at: u32(60))
    }

    /// The regions section (empty in a file without one, or one that doesn't read whole).
    static func readRegions(_ data: Data, at offset: Int) -> [Region] {
        guard offset > 0, offset + 4 <= data.count else { return [] }
        return data.withUnsafeBytes { raw -> [Region] in
            var p = offset
            func u32() -> Int? {
                guard p + 4 <= raw.count else { return nil }
                defer { p += 4 }
                return Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt32.self)))
            }
            func i32() -> Int32? {
                guard p + 4 <= raw.count else { return nil }
                defer { p += 4 }
                return Int32(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: Int32.self))
            }
            guard let count = u32(), count < 10_000 else { return [] }
            var out: [Region] = []
            for _ in 0..<count {
                guard p + 4 <= raw.count else { return [] }
                let code = String(decoding: UnsafeRawBufferPointer(rebasing: raw[p..<p + 2]), as: UTF8.self)
                let ringCount = Int(raw[p + 2]) | Int(raw[p + 3]) << 8
                p += 4
                var rings: [[(Double, Double)]] = []
                var south = 90.0, north = -90.0, west = 180.0, east = -180.0
                for _ in 0..<ringCount {
                    guard let n = u32(), n <= (raw.count - p) / 8 else { return [] }
                    var ring: [(Double, Double)] = []
                    ring.reserveCapacity(n)
                    for _ in 0..<n {
                        guard let lat = i32(), let lon = i32() else { return [] }
                        let point = (Double(lat) / 1e6, Double(lon) / 1e6)
                        ring.append(point)
                        south = min(south, point.0); north = max(north, point.0)
                        west = min(west, point.1); east = max(east, point.1)
                    }
                    rings.append(ring)
                }
                out.append(Region(code: code, rings: rings, south: south, north: north, west: west, east: east))
            }
            return out
        }
    }

    /// The country a point lies in by the political positions' regions, nil outside them.
    public func regionCountry(at c: Coordinate) -> String? {
        let c = c.normalized
        return regions.first { $0.contains(c) }?.code
    }

    static func uint32(_ data: Data, _ at: Int) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
    }

    // MARK: Cells

    private func blockIndex(cell: Int, tier: Int) -> Int? {
        let key = cell * 2 + tier
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let k = blocks[mid].cell * 2 + blocks[mid].tier
            if k == key { return mid }
            if k < key { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// The block's bytes, unpacked.
    private func bytes(of index: Int) -> Data? {
        let block = blocks[index]
        let stored = data.subdata(in: data.startIndex + block.offset..<data.startIndex + block.offset + block.storedLength)
        guard block.packed else { return stored }
        if let cached = cache.object(forKey: NSNumber(value: index)) { return cached as Data }
        var out = Data(count: block.length)
        let produced = out.withUnsafeMutableBytes { dst in
            stored.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, block.length,
                                          src.bindMemory(to: UInt8.self).baseAddress!, block.storedLength, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == block.length else { return nil }
        cache.setObject(out as NSData, forKey: NSNumber(value: index), cost: block.length)
        return out
    }

    /// The places of a cell's tier, the most important first, while `body` returns true.
    /// The places of a cell's tier, the most important first, while `body`
    /// returns true; it stops at the first place labelled after `maxMinZoom`
    /// and skips those `inside` refuses, both read from the record before the
    /// place is decoded (a view of the world asks every cell).
    private func forEach(cell: Int, tier: Int, maxMinZoom: Double = .infinity,
                         inside: ((Double, Double) -> Bool)? = nil, _ body: (Place) -> Bool) {
        guard let index = blockIndex(cell: cell, tier: tier), let bytes = bytes(of: index) else { return }
        let block = blocks[index]
        let row = cell / Self.columns, column = cell % Self.columns
        let south = Double(row - 90), west = Double(column - 180)
        bytes.withUnsafeBytes { raw in
            for i in 0..<block.count {
                let at = 16 * i
                if Double(raw[at + 13]) / 10 > maxMinZoom { return }   // the rest of the cell is less important
                if let inside {
                    let lat = south + Double(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))) / 1e6
                    let lon = west + Double(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))) / 1e6
                    if !inside(lat, lon) { continue }
                }
                guard let place = place(raw, at: at, south: south, west: west) else { return }
                if !body(place) { return }
            }
        }
    }

    private func place(_ raw: UnsafeRawBufferPointer, at: Int, south: Double, west: Double) -> Place? {
        func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
        let lat = south + Double(u32(at)) / 1e6, lon = west + Double(u32(at + 4)) / 1e6
        let kindFlags = raw[at + 12]
        guard let kind = Place.Kind(rawValue: kindFlags & 0x0F) else { return nil }
        let countryIndex = Int(raw[at + 15])
        var reader = ProtoReader(raw, from: u32(at + 8))
        guard let local = try? reader.string(), reader.position < raw.count else { return nil }
        var names: [String: String] = [:]
        let count = Int(raw[reader.position])
        reader.position += 1
        for _ in 0..<count {
            guard reader.position < raw.count else { return nil }
            let language = Int(raw[reader.position])
            reader.position += 1
            guard let name = try? reader.string() else { return nil }
            if languages.indices.contains(language) { names[languages[language]] = name }
        }
        return Place(coordinate: Coordinate(latitude: lat, longitude: lon), kind: kind,
                     minZoom: Double(raw[at + 13]) / 10, populationRank: Int(raw[at + 14]),
                     isCountryCapital: kindFlags & 0x10 != 0, isRegionCapital: kindFlags & 0x20 != 0,
                     countryCode: countries.indices.contains(countryIndex) ? countries[countryIndex] : nil,
                     localName: local, names: names)
    }

    /// The cells covering latitudes and longitudes (west may be greater than
    /// east: the span crosses the antimeridian; more than 360° takes every column).
    private func cells(south: Double, north: Double, west: Double, east: Double) -> [Int] {
        let r0 = max(0, Int(floor(south + 90))), r1 = min(Self.rows - 1, Int(floor(north + 90)))
        guard r0 <= r1 else { return [] }
        var columns: [Int] = []
        var span = east - west
        if span < 0 { span += 360 }
        if span >= 359 {
            columns = Array(0..<Self.columns)
        } else {
            let c0 = Int(floor(west + 180))
            let n = Int(floor(west + span + 180)) - c0
            for k in 0...n { columns.append(((c0 + k) % Self.columns + Self.columns) % Self.columns) }
        }
        var out: [Int] = []
        for r in r0...r1 { for c in columns { out.append(r * Self.columns + c) } }
        return out
    }

    // MARK: Queries

    /// Every place inside the span labelled from `maxMinZoom` on, the most
    /// important first (lowest min_zoom, then largest population).
    public func places(south: Double, north: Double, west: Double, east: Double, maxMinZoom: Double) -> [Place] {
        var found: [Place] = []
        let tiers = maxMinZoom >= tierSplit ? [0, 1] : [0]
        for cell in cells(south: south, north: north, west: west, east: east) {
            for tier in tiers {
                forEach(cell: cell, tier: tier, maxMinZoom: maxMinZoom,
                        inside: { lat, lon in lat >= south && lat <= north && Self.longitude(lon, west: west, east: east) }) { place in
                    found.append(place)
                    return true
                }
            }
        }
        found.sort { ($0.minZoom, -$0.populationRank) < ($1.minZoom, -$1.populationRank) }
        return found
    }

    static func longitude(_ lon: Double, west: Double, east: Double) -> Bool {
        var span = east - west
        if span < 0 { span += 360 }
        if span >= 359 { return true }
        var d = lon - west
        d -= floor(d / 360) * 360
        return d <= span
    }

    /// Every place within `radius` metres of the coordinate, with its distance.
    public func places(near c: Coordinate, radius: Double) -> [(place: Place, distance: Double)] {
        let c = c.normalized
        let dLat = radius / 111_195
        let cosLat = cos(min(89.9, abs(c.latitude)) * .pi / 180)
        let dLon = min(180, radius / (111_195 * cosLat))
        let west = c.longitude - dLon, east = c.longitude + dLon
        var out: [(Place, Double)] = []
        for cell in cells(south: c.latitude - dLat, north: c.latitude + dLat,
                          west: dLon >= 180 ? -180 : west.wrappedLongitude, east: dLon >= 180 ? 180 : east.wrappedLongitude) {
            for tier in [0, 1] {
                forEach(cell: cell, tier: tier) { place in
                    let d = c.distance(to: place.coordinate)
                    if d <= radius { out.append((place, d)) }
                    return true
                }
            }
        }
        return out
    }

    /// How much a place across a border from the photo counts less
    static let borderPenalty = 6.0

    /// The place a photo taken here is "near": the most important locality
    /// within `radius` metres, an important one further away preferred over
    /// a hamlet next door (`NearbyPlace.score`), one in the photo's own
    /// country over one across a border; nil where none is (the open sea).
    /// The photo's country is the one of the political positions' region it
    /// lies in, else the nearest locality's; a place without a country of its
    /// own (Jerusalem) takes the photo's.
    public func nearby(_ c: Coordinate, radius: Double = 50_000) -> NearbyPlace? {
        let found = places(near: c, radius: radius).filter { $0.place.isLocality }
        let here = regionCountry(at: c)
            ?? found.filter { $0.place.countryCode != nil }.min { $0.distance < $1.distance }?.place.countryCode
        var best: (NearbyPlace, Double)?
        for (place, distance) in found {
            let candidate = NearbyPlace(place: place, distance: distance, countryCode: place.countryCode ?? here)
            var score = candidate.score
            // A place of another country, or of none (Jerusalem), counts less: near it, it still wins
            if let here, place.countryCode != here { score -= Self.borderPenalty }
            if best == nil || score > best!.1 { best = (candidate, score) }
        }
        return best?.0
    }
}

/// A locality near a coordinate, with how far it is.
public struct NearbyPlace: Equatable, Sendable {
    public var place: Place
    /// In metres
    public var distance: Double
    /// ISO 3166-1 alpha-2 of the country the description names: the place's,
    /// or for a place without one (Jerusalem) the photo's; nil when unknown
    public var countryCode: String?

    public init(place: Place, distance: Double, countryCode: String? = nil) {
        self.place = place
        self.distance = distance
        self.countryCode = countryCode ?? place.countryCode
    }

    /// The place's importance (population rank, and how early the map
    /// labels it) less a penalty growing with the logarithm of the distance:
    /// a place twice as far must be clearly more important to win.
    public var score: Double {
        let importance = Double(place.populationRank) + max(0, 12 - place.minZoom) * 0.75
        return importance - 3 * log2(1 + distance / 2_000)
    }

    /// The country's name in the user's language (`CountryNames`), nil when unknown.
    public func countryName(locale: Locale = .current) -> String? {
        guard let code = countryCode else { return nil }
        return CountryNames.name(code, locale: locale)
    }

    /// "near Geiranger, Norway" in the app's language.
    public func description(languages: MapLanguages = .system, locale: Locale = .current) -> String {
        let name = place.label(in: languages)
        if let country = countryName(locale: locale) {
            return String(localized: "near \(name), \(country)")
        }
        return String(localized: "near \(name)")
    }
}

extension Double {
    var wrappedLongitude: Double {
        var lon = (self + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        return lon - 180
    }
}
