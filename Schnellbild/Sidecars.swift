import Foundation
import VLCFrames

// MARK: - Times as files write them

/// A clock reading as a file writes it: the wall clock (read as if it were
/// UTC, a "floating" time) and its offset from UTC when the file states one.
struct ClockReading: Equatable, Sendable {
    var floating: Date
    /// Seconds east of UTC.
    var offset: Int?

    /// The moment it names, the wall clock without offset read in `zone`.
    func instant(in zone: TimeZone = .current) -> Date {
        if let offset { return floating.addingTimeInterval(-Double(offset)) }
        let guess = floating.addingTimeInterval(-Double(zone.secondsFromGMT(for: floating)))
        return floating.addingTimeInterval(-Double(zone.secondsFromGMT(for: guess)))
    }

    /// ISO 8601 as XMP, GPX, QuickTime and Sony's XML write it:
    /// "2024-06-18T22:31:09+02:00", "…09.123Z", "…T22:31+0200", "2024-06-18 22:31:09";
    /// also EXIF's "2024:06:18 22:31:09". A date without a time is no reading.
    static func parse(_ text: String) -> ClockReading? {
        guard text.count < 200,
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
        guard let year = group(1).flatMap(Int.init), let month = group(2).flatMap(Int.init), let day = group(3).flatMap(Int.init),
              let hour = group(4).flatMap(Int.init), let minute = group(5).flatMap(Int.init) else { return nil }
        let second = group(6).flatMap(Int.init) ?? 0
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61,
              let floating = floatingDate(year, month, day, hour, minute, second) else { return nil }
        var fraction = 0.0
        if let digits = group(7) { fraction = Double("0." + digits) ?? 0 }
        var offset: Int?
        if let zone = group(8) {
            if zone == "Z" || zone == "z" {
                offset = 0
            } else {
                let sign = zone.hasPrefix("-") ? -1 : 1
                let digits = zone.dropFirst().filter(\.isNumber)
                let hours = Int(digits.prefix(2)) ?? 0, minutes = Int(digits.dropFirst(2)) ?? 0
                guard hours <= 18, minutes < 60 else { return nil }
                offset = sign * (hours * 3600 + minutes * 60)
            }
        }
        return ClockReading(floating: floating.addingTimeInterval(fraction), offset: offset)
    }

    /// Compiled once: a GPX track parses one time per point. Matching is
    /// thread-safe (NSRegularExpression is immutable). RFC 3339 allows "t"
    /// and "z" in lower case, and any number of digits of a second.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(\d{4})[-:](\d\d)[-:](\d\d)[Tt ](\d\d):(\d\d)(?::(\d\d)(?:[.,](\d+))?)?\s*([Zz]|[+-]\d\d(?::?\d\d)?)?"#)

    /// A wall clock's date (read as UTC), nil for one that doesn't exist.
    static func floatingDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }   // not 31 February
        return date
    }
}

// MARK: - XML, held short

/// What every XML reader here does before parsing: refuse a document type
/// declaration (XMP, GPX and Sony's clip files have none; entities are the
/// way to make a small file expand) and anything larger than `limit`. The
/// search for one is a search for ASCII bytes, so only documents in an
/// encoding that writes ASCII as ASCII are parsed: UTF-8 (as XMP requires)
/// or a declared single-byte one (old GPS tools write ISO-8859-1); not UTF-16
/// or UTF-32 (libxml2 tells them from the first bytes), UTF-7 or EBCDIC,
/// where a declaration would hide from the search.
enum SafeXML {
    /// The encodings an XML declaration may name, lower case.
    static let encodings = Set(["utf-8", "utf8", "us-ascii", "ascii"])
        .union((1...16).map { "iso-8859-\($0)" }).union((1250...1258).map { "windows-\($0)" })
        .union(["latin1", "iso-latin-1", "cp1252"])

    static func parser(for data: Data, limit: Int) -> XMLParser? {
        guard !data.isEmpty, data.count <= limit, isASCIICompatible(data) else { return nil }
        let head = data.prefix(1 << 20)
        for marker in ["<!DOCTYPE", "<!doctype", "<!ENTITY", "<!entity"] where head.range(of: Data(marker.utf8)) != nil {
            return nil
        }
        if data.count > head.count, data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
            return nil
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        return parser
    }

    /// The first bytes are ASCII (after a UTF-8 byte order mark) and the
    /// declaration, if any, names an encoding of `encodings`.
    static func isASCIICompatible(_ data: Data) -> Bool {
        var body = data[...]
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        guard body.prefix(4).allSatisfy({ (0x01...0x7F).contains($0) }) else { return false }
        let start = body.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        guard start.starts(with: Data("<?xml".utf8)) else { return true }
        // The declaration: up to its "?>"
        let declaration = start.prefix(200)
        guard let end = declaration.range(of: Data("?>".utf8)),
              let text = String(data: Data(declaration[declaration.startIndex..<end.lowerBound]), encoding: .ascii) else { return false }
        guard let found = text.range(of: #"encoding\s*=\s*["']([^"']*)["']"#, options: .regularExpression) else { return true }
        let named = text[found].split(whereSeparator: { $0 == "\"" || $0 == "'" }).dropFirst().first.map { $0.lowercased() } ?? ""
        return encodings.contains(named)
    }
}

/// A file beside a picture or video (an XMP sidecar, a GPX track, a flight
/// log, a clip XML), read only when it is a regular file of at most `limit`
/// bytes: never a FIFO (a read would wait for a writer), a device (a link
/// to /dev/zero never ends) or a folder, nor a file larger than its format
/// allows. Checked on the opened file, opened without waiting (`RegularFile`).
enum SidecarFile {
    static func read(_ url: URL, limit: Int) -> Data? {
        guard let file = try? RegularFile.open(url), file.size <= limit else { return nil }
        do {
            // At most one byte more than allowed: a file grown meanwhile is refused
            let data = try file.handle.read(upToCount: limit + 1) ?? Data()
            return data.count <= limit ? data : nil
        } catch {
            return nil
        }
    }
}

// MARK: - XMP (sidecars, and XMP inside a file)

/// Time and place from an XMP packet (Adobe's XMP Specification; the EXIF
/// properties as CIPA DC-010 maps them): `exif:GPSLatitude` /
/// `exif:GPSLongitude` ("DDD,MM,SSk" or "DDD,MM.mmk"), `exif:GPSAltitude`
/// (a rational) with `exif:GPSAltitudeRef` (1: below sea level),
/// `exif:GPSHPositioningError` (metres), the capture time from
/// `exif:DateTimeOriginal`, else `photoshop:DateCreated`, else
/// `xmp:CreateDate` (ISO 8601, the offset optional). Properties may be
/// attributes of `rdf:Description` or elements of their own.
enum XMPMetadata {
    static let exif = "http://ns.adobe.com/exif/1.0/"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    static let largest = 16 << 20

    struct Facts: Equatable, Sendable {
        var time: ClockReading?
        var location: MediaLocation?
        /// Metres, where the packet states the horizontal error.
        var accuracy: Double?
    }

    static func read(_ data: Data) -> Facts? {
        guard let parser = SafeXML.parser(for: data, limit: largest) else { return nil }
        let collector = PropertyCollector(wanted: [
            exif: ["GPSLatitude", "GPSLongitude", "GPSAltitude", "GPSAltitudeRef", "GPSHPositioningError", "DateTimeOriginal"],
            xmp: ["CreateDate"], photoshop: ["DateCreated"],
        ])
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        // A packet cut off still has what came before the break
        _ = parser.parse()
        let values = collector.values
        guard !values.isEmpty else { return nil }
        var facts = Facts()
        for key in [exif + "DateTimeOriginal", photoshop + "DateCreated", xmp + "CreateDate"] {
            if let text = values[key], let time = ClockReading.parse(text) { facts.time = time; break }
        }
        if let lat = values[exif + "GPSLatitude"].flatMap(coordinate), let lon = values[exif + "GPSLongitude"].flatMap(coordinate),
           !(lat == 0 && lon == 0), let point = GeoPoint(latitude: lat, longitude: lon) {
            var location = MediaLocation(point: point)
            if let altitude = values[exif + "GPSAltitude"].flatMap(rational), altitude.isFinite, abs(altitude) < 100_000 {
                location.altitude = values[exif + "GPSAltitudeRef"]?.trimmingCharacters(in: .whitespaces) == "1" ? -abs(altitude) : altitude
            }
            facts.location = location
            if let error = values[exif + "GPSHPositioningError"].flatMap(rational), error.isFinite, error >= 0, error < 1_000_000 {
                facts.accuracy = error
            }
        }
        return facts.time == nil && facts.location == nil ? nil : facts
    }

    /// "48,51.5004N", "48,51,30.02N", also a plain signed decimal.
    static func coordinate(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !value.isEmpty, value.count < 64 else { return nil }
        if let plain = Double(value), plain.isFinite { return plain }
        guard let last = value.last, "NSEW".contains(last) else { return nil }
        let parts = value.dropLast().split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        let degrees = parts[0]!, minutes = parts[1]!, seconds = parts.count == 3 ? parts[2]! : 0
        guard minutes < 60, seconds < 60, degrees <= 180 else { return nil }
        let result = degrees + minutes / 60 + seconds / 3600
        return last == "S" || last == "W" ? -result : result
    }

    /// "4321/10", "432.1".
    static func rational(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count < 64 else { return nil }
        let parts = value.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return parts.count == 1 ? Double(value) : nil
    }
}

/// Collects wanted properties of an RDF document: from attributes
/// (resolved through the namespace prefixes in scope) and from elements'
/// text (an `rdf:Alt` / `rdf:Seq`'s first item). The first value of each wins.
private final class PropertyCollector: NSObject, XMLParserDelegate {
    let wanted: [String: Set<String>]
    var values: [String: String] = [:]
    private var prefixes: [String: [String]] = [:]
    /// The property elements open, and the text gathered for the innermost.
    private var open: [(key: String?, text: String)] = []

    init(wanted: [String: Set<String>]) { self.wanted = wanted }

    private func key(_ namespace: String?, _ name: String) -> String? {
        guard let namespace, wanted[namespace]?.contains(name) == true else { return nil }
        return namespace + name
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        _ = prefixes[prefix]?.popLast()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        for (name, value) in attributeDict {
            let parts = name.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let uri = prefixes[String(parts[0])]?.last,
                  let key = key(uri, String(parts[1])), values[key] == nil else { continue }
            values[key] = value
        }
        let key = key(namespaceURI, elementName)
        open.append((key, ""))
        guard open.count < 64 else { parser.abortParsing(); return }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !open.isEmpty, open.contains(where: { $0.key != nil }), open[open.count - 1].text.count < 4_096 else { return }
        open[open.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let element = open.popLast() else { return }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = element.key {
            if values[key] == nil, !text.isEmpty { values[key] = text }
        } else if !open.isEmpty, open[open.count - 1].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An rdf:li's text goes to the property around it (the first item)
            open[open.count - 1].text = text
        }
    }
}

// MARK: - Sony's clip XML

/// Sony cameras write `<clip>M01.XML` beside a clip (`C0001.MP4` →
/// `C0001M01.XML`; the XDCAM layouts in XMP Specification Part 3, 1.3.4),
/// root `NonRealTimeMeta`: `<CreationDate value="2024-11-30T10:08:55+09:00"/>`
/// (Adobe's XMP Toolkit reads it as xmp:CreateDate, XDCAM_Support.cpp) and,
/// from cameras with a location, `AcquisitionRecord/Group name="ExifGPS"`
/// with `Item` name / value pairs in EXIF's GPS terms (`Latitude`
/// "35:38:46.649" with `LatitudeRef` "N", `Longitude`, `LongitudeRef`,
/// `Status` "A" active or "V" void, `Altitude` / `AltitudeRef`). Sony
/// publishes no schema; the GPS items are as the cameras write them.
enum SonyClipXML {
    static let largest = 4 << 20

    struct Facts: Equatable, Sendable {
        var time: ClockReading?
        var location: MediaLocation?
    }

    static func read(_ data: Data) -> Facts? {
        guard let parser = SafeXML.parser(for: data, limit: largest) else { return nil }
        let collector = ClipCollector()
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        _ = parser.parse()
        guard collector.root == "NonRealTimeMeta" else { return nil }
        var facts = Facts()
        facts.time = collector.creation.flatMap(ClockReading.parse)
        let gps = collector.gps
        if gps["Status"]?.uppercased() != "V",
           var lat = gps["Latitude"].flatMap(sexagesimal), var lon = gps["Longitude"].flatMap(sexagesimal) {
            if gps["LatitudeRef"]?.uppercased() == "S" { lat = -abs(lat) }
            if gps["LongitudeRef"]?.uppercased() == "W" { lon = -abs(lon) }
            if !(lat == 0 && lon == 0), let point = GeoPoint(latitude: lat, longitude: lon) {
                var location = MediaLocation(point: point)
                if let altitude = gps["Altitude"].flatMap(XMPMetadata.rational), altitude.isFinite, abs(altitude) < 100_000 {
                    location.altitude = gps["AltitudeRef"] == "1" ? -abs(altitude) : altitude
                }
                facts.location = location
            }
        }
        return facts.time == nil && facts.location == nil ? nil : facts
    }

    /// "35:38:46.649" (degrees, minutes, seconds), "35:38.777", "35.646".
    static func sexagesimal(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        let values = parts.map { $0! }
        guard values.count < 2 || values[1] < 60, values.count < 3 || values[2] < 60 else { return nil }
        return values.enumerated().reduce(0) { $0 + $1.element / pow(60, Double($1.offset)) }
    }
}

private final class ClipCollector: NSObject, XMLParserDelegate {
    var root: String?
    var creation: String?
    var gps: [String: String] = [:]
    private var groups: [String?] = []
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        guard depth < 64 else { parser.abortParsing(); return }
        if root == nil { root = elementName }
        switch elementName {
        case "CreationDate" where creation == nil:
            creation = attributeDict["value"]
        case "Group":
            groups.append(attributeDict["name"])
        case "Item" where groups.last == "ExifGPS":
            if let name = attributeDict["name"], let value = attributeDict["value"], gps[name] == nil, gps.count < 64 {
                gps[name] = value
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        if elementName == "Group" { _ = groups.popLast() }
    }
}

// MARK: - DJI's flight log (.SRT)

/// The subtitle file DJI drones write beside a video (`DJI_0001.MP4` →
/// `DJI_0001.SRT`): a SubRip block per frame or second whose text carries the
/// drone's place and clock. DJI publishes no description; the forms read here
/// are those of files from the drones (collected with
/// github.com/JuanIrache/DJI_SRT_Parser's samples):
/// - Phantom 3/4, Mavic Pro, Inspire: `HOME(lon,lat) 2017.08.05 14:11:51` /
///   `GPS(lon,lat,satellites) BAROMETER:1.9` (older firmware: `2017.8.5`, `Hb:`);
/// - Mavic Mini, Phantom 4 RTK: `F/2.8, SS 30.15, …, GPS (lon, lat, satellites), D 221.21m, H 200.70m`;
/// - Matrice 300: `2022.06.21 16:06:17` / `GPS(lat,lon,0.0M) BAROMETER:0.3M`
///   (latitude first, the third value with an "M");
/// - Mavic 2, Air, Air 2, Air 2S, Mini 2, Mavic 3, FPV: a date line
///   `2022-08-07 13:40:40,774,808` or `2021-12-25 12:27:52.373`, then
///   `[latitude: 41.42] [longitude: 2.23]` (Mavic 2: `[longtitude : …]`) with
///   `[altitude: 117.0]` or `[rel_alt: 2.4 abs_alt: 120.4]`.
/// The clock is the drone's local time, with no offset. Zeros mean no fix.
enum DJIFlightLog {
    static let largest = 128 << 20
    /// Blocks read for the track; the first fix is searched from the start.
    static let trackBlocks = 500

    struct Record: Equatable, Sendable {
        var point: GeoPoint?
        var altitude: Double?
        var clock: ClockReading?
    }

    struct Log: Equatable, Sendable {
        var first: Record?
        /// The first clock reading.
        var start: ClockReading?
        /// Records spread over the whole flight, those with a place.
        var track: [Record]
    }

    static func read(_ data: Data) -> Log? {
        guard !data.isEmpty, data.count <= largest else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blocks.isEmpty else { return nil }
        var log = Log(first: nil, start: nil, track: [])
        // The first fix and clock, from the start
        for block in blocks.prefix(2_000) {
            let record = parse(block)
            if log.start == nil, let clock = record.clock { log.start = clock }
            if log.first == nil, record.point != nil { log.first = record }
            if log.start != nil, log.first != nil { break }
        }
        let stride = max(1, blocks.count / trackBlocks)
        var index = 0
        var firstTracked: Int?
        while index < blocks.count {
            let record = parse(blocks[index])
            if record.point != nil {
                log.track.append(record)
                if firstTracked == nil { firstTracked = index }
            }
            index += stride
        }
        // A fix found only later (GPS locked after the blocks searched from
        // the start): the first one lies between the track's first point
        // and the block looked at before it
        if log.first == nil, let tracked = firstTracked {
            let from = max(min(2_000, blocks.count), tracked - stride + 1)
            log.first = blocks[from..<tracked].lazy.map(parse).first { $0.point != nil } ?? log.track.first
        }
        return log.first == nil && log.start == nil ? nil : log
    }

    /// A decimal number, not the start of one written with an exponent ("1e308").
    private static let number = #"(-?\d+(?:\.\d+)?)(?![\deE.])"#
    private static let patterns: [String: NSRegularExpression] = {
        let n = number
        let sources = [
            "date": #"(\d{4})[-.](\d{1,2})[-.](\d{1,2}) (\d{1,2}):(\d\d):(\d\d)(?:[.,](\d{1,3}))?"#,
            "gps": #"GPS\s*\(\s*"# + n + #"\s*,\s*"# + n + #"\s*(?:,\s*(-?[\d.]+)\s*([Mm])?\s*)?\)"#,
            "latitude": #"\[\s*latitude\s*:\s*"# + n,
            "longitude": #"\[\s*longt?itude\s*:\s*"# + n,
            "altitude": #"\[\s*altitude\s*:\s*"# + n,
            "absolute": #"abs_alt\s*:\s*"# + n,
        ]
        // "GPS(…,0.0M)" (Matrice 300) and "GPS(…,17m)" differ only in case
        return sources.compactMapValues { try? NSRegularExpression(pattern: $0, options: $0.hasPrefix("GPS") ? [] : [.caseInsensitive]) }
    }()

    static func parse(_ block: String) -> Record {
        var record = Record()
        let text = String(block.prefix(8_192))
        let range = NSRange(text.startIndex..., in: text)
        func groups(_ name: String) -> [String?]? {
            guard let regex = patterns[name], let match = regex.firstMatch(in: text, range: range) else { return nil }
            return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        if let g = groups("date"), let y = g[0].flatMap(Int.init), let mo = g[1].flatMap(Int.init), let d = g[2].flatMap(Int.init),
           let h = g[3].flatMap(Int.init), let mi = g[4].flatMap(Int.init), let s = g[5].flatMap(Int.init),
           (1990...2200).contains(y), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61,
           let floating = ClockReading.floatingDate(y, mo, d, h, mi, s) {
            let milliseconds = g[6].flatMap(Double.init).map { $0 / pow(10, Double(g[6]!.count)) } ?? 0
            record.clock = ClockReading(floating: floating.addingTimeInterval(milliseconds), offset: nil)
        }
        var lat: Double?, lon: Double?
        if let g = groups("latitude"), let g2 = groups("longitude") {
            lat = g[0].flatMap(Double.init)
            lon = g2[0].flatMap(Double.init)
            record.altitude = (groups("absolute")?[0] ?? groups("altitude")?[0]).flatMap(Double.init)
        } else if let g = groups("gps"), let a = g[0].flatMap(Double.init), let b = g[1].flatMap(Double.init) {
            // Longitude first, except the Matrice 300's form; a "latitude" beyond 90° says it was the other way
            if g[3] == "M" || abs(b) > 90 { (lat, lon) = (a, b) } else { (lat, lon) = (b, a) }
        }
        if let lat, let lon, !(lat == 0 && lon == 0), let point = GeoPoint(latitude: lat, longitude: lon) {
            record.point = point
        } else {
            record.altitude = nil
        }
        if let altitude = record.altitude, !(altitude.isFinite && abs(altitude) < 100_000) { record.altitude = nil }
        return record
    }
}

// MARK: - GPX tracks

/// A GPX track (GPX 1.0 / 1.1, topografix.com: `trk/trkseg/trkpt` with `lat` /
/// `lon` attributes, `ele` in metres and `time` in UTC, ISO 8601). Points
/// without a time can't place anything and are left out; each segment is
/// sorted by time.
struct GPXTrack: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var point: GeoPoint
        var altitude: Double?
        var time: Date
    }

    var segments: [[Point]]

    static let largest = 64 << 20
    static let largestPoints = 2_000_000
    /// A photo is placed only this close in time to a point of the track.
    static let gapLimit: TimeInterval = 300

    var isEmpty: Bool { segments.allSatisfy(\.isEmpty) }

    static func read(_ data: Data) -> GPXTrack? {
        guard let parser = SafeXML.parser(for: data, limit: largest) else { return nil }
        let collector = TrackCollector()
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        _ = parser.parse()
        guard collector.isGPX else { return nil }
        let segments = collector.segments.map { $0.sorted { $0.time < $1.time } }.filter { !$0.isEmpty }
        return segments.isEmpty ? nil : GPXTrack(segments: segments)
    }

    /// Where the track was at `time`: between the two points around it, along
    /// the straight line in proportion to the time; only inside a segment's
    /// time span and within `gapLimit` of the nearer point. Nil otherwise.
    func place(at time: Date) -> (point: GeoPoint, altitude: Double?, gap: TimeInterval)? {
        var best: (point: GeoPoint, altitude: Double?, gap: TimeInterval)?
        for segment in segments {
            guard let first = segment.first, let last = segment.last, first.time <= time, time <= last.time else { continue }
            // The last point at or before the time
            var low = 0, high = segment.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if segment[middle].time <= time { low = middle } else { high = middle - 1 }
            }
            let before = segment[low]
            let after = low + 1 < segment.count ? segment[low + 1] : before
            let span = after.time.timeIntervalSince(before.time)
            let gap = min(time.timeIntervalSince(before.time), after.time.timeIntervalSince(time))
            guard gap <= Self.gapLimit else { continue }
            let share = span > 0 ? time.timeIntervalSince(before.time) / span : 0
            var lon0 = before.point.longitude, lon1 = after.point.longitude
            // Across the antimeridian the short way round
            if lon1 - lon0 > 180 { lon0 += 360 } else if lon0 - lon1 > 180 { lon1 += 360 }
            var lon = lon0 + (lon1 - lon0) * share
            if lon > 180 { lon -= 360 }
            let lat = before.point.latitude + (after.point.latitude - before.point.latitude) * share
            var altitude: Double?
            if let a = before.altitude, let b = after.altitude { altitude = a + (b - a) * share } else { altitude = before.altitude ?? after.altitude }
            guard let point = GeoPoint(latitude: lat, longitude: lon) else { continue }
            if best == nil || gap < best!.gap { best = (point, altitude, gap) }
        }
        return best
    }
}

private final class TrackCollector: NSObject, XMLParserDelegate {
    var isGPX = false
    var segments: [[GPXTrack.Point]] = []
    private var count = 0
    private var current: (lat: Double, lon: Double)?
    private var altitude: Double?
    private var time: Date?
    private var text = ""
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        guard depth < 64 else { parser.abortParsing(); return }
        if depth == 1 { isGPX = elementName == "gpx" }
        text = ""
        switch elementName {
        case "trkseg":
            segments.append([])
        case "trkpt":
            if segments.isEmpty { segments.append([]) }
            current = nil
            altitude = nil
            time = nil
            if let lat = attributeDict["lat"].flatMap(Double.init), let lon = attributeDict["lon"].flatMap(Double.init) {
                current = (lat, lon)
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 256 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "ele":
            if let number = Double(value), number.isFinite, abs(number) < 100_000 { altitude = number }
        case "time":
            // GPX times are UTC; one written without a zone is taken as UTC
            if current != nil, let reading = ClockReading.parse(value) { time = reading.instant(in: TimeZone(identifier: "UTC")!) }
        case "trkpt":
            if let current, let time, let point = GeoPoint(latitude: current.lat, longitude: current.lon),
               !(current.lat == 0 && current.lon == 0), count < GPXTrack.largestPoints {
                segments[segments.count - 1].append(GPXTrack.Point(point: point, altitude: altitude, time: time))
                count += 1
                if count >= GPXTrack.largestPoints { parser.abortParsing() }
            }
            current = nil
        default: break
        }
        text = ""
    }
}
