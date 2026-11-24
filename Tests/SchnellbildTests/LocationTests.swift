import XCTest
import ImageIO
@testable import Schnellbild

/// Places: coordinates and map links people paste, ISO 6709, distances,
/// the places and camera facts read from photos and videos
/// (`Tests/SchnellbildTests/Locations`, drawn by
/// `Scripts/make_location_fixtures.swift`), the cache, sorting by distance
/// and the Inspector's report.
@MainActor
final class LocationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Locations"), "missing fixture \(name)")
    }

    private func assertPoint(_ text: String, _ latitude: Double, _ longitude: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let point = GeoPoint.parse(text) else { return XCTFail("nothing read from \(text)", file: file, line: line) }
        XCTAssertEqual(point.latitude, latitude, accuracy: 1e-5, text, file: file, line: line)
        XCTAssertEqual(point.longitude, longitude, accuracy: 1e-5, text, file: file, line: line)
    }

    // MARK: Parsing

    func testDecimalCoordinates() {
        assertPoint("48.137, 11.575", 48.137, 11.575)
        assertPoint("48.137,11.575", 48.137, 11.575)
        assertPoint("  48.137 11.575\n", 48.137, 11.575)
        assertPoint("-33.8568, 151.2153", -33.8568, 151.2153)
        assertPoint("40.6892, -74.0445", 40.6892, -74.0445)
        assertPoint("48,137 11,575", 48.137, 11.575)
        assertPoint("48,137; 11,575", 48.137, 11.575)
    }

    func testHemisphereLetters() {
        assertPoint("48.137° N, 11.575° E", 48.137, 11.575)
        assertPoint("48.137N 11.575E", 48.137, 11.575)
        assertPoint("N 48.137 E 11.575", 48.137, 11.575)
        assertPoint("11.575 E, 48.137 N", 48.137, 11.575)
        assertPoint("40.6892° N 74.0445° W", 40.6892, -74.0445)
        assertPoint("33.8568 S 151.2153 E", -33.8568, 151.2153)
    }

    func testDegreesMinutesSeconds() {
        assertPoint("48°8'14\"N 11°34'27\"E", 48.137222, 11.574167)
        assertPoint("48° 8′ 14″ N, 11° 34′ 27″ E", 48.137222, 11.574167)
        assertPoint("N 48° 8' 14\" E 11° 34' 27\"", 48.137222, 11.574167)
        assertPoint("33°51'24.4\"S 151°12'55.1\"E", -33.856778, 151.215306)
        assertPoint("48°8.233'N 11°34.45'E", 48.137217, 11.574167)
    }

    func testMapLinks() {
        assertPoint("https://maps.apple.com/?ll=48.137,11.575&q=Marienplatz", 48.137, 11.575)
        assertPoint("https://maps.apple.com/place?coordinate=48.137,11.575&name=Marienplatz", 48.137, 11.575)
        assertPoint("https://maps.apple.com/?q=48.137,11.575", 48.137, 11.575)
        // A place's pin, not the middle of the map around it
        assertPoint("https://www.google.com/maps/place/Marienplatz/@48.1373932,11.5732545,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d48.1373932!4d11.5754432",
                    48.1373932, 11.5754432)
        assertPoint("https://www.google.com/maps/place/48%C2%B008'14.0%22N+11%C2%B034'27.0%22E/@48.1372,11.5742,17z", 48.137222, 11.574167)
        assertPoint("https://www.google.com/maps/@48.1373932,11.5732545,15z", 48.1373932, 11.5732545)
        assertPoint("https://www.google.com/maps/search/?api=1&query=48.137,11.575", 48.137, 11.575)
        assertPoint("https://maps.google.com/?q=48.137,11.575", 48.137, 11.575)
        assertPoint("https://www.openstreetmap.org/?mlat=48.1372&mlon=11.5756#map=14/48.1372/11.5756", 48.1372, 11.5756)
        assertPoint("https://www.openstreetmap.org/#map=14/48.1372/11.5756", 48.1372, 11.5756)
        assertPoint("geo:48.137,11.575", 48.137, 11.575)
        assertPoint("geo:48.137,11.575;u=35", 48.137, 11.575)
        // RFC 5870's altitude; Android's labelled pin
        assertPoint("geo:48.137,11.575,520", 48.137, 11.575)
        assertPoint("geo:48.137,11.575,520;u=35", 48.137, 11.575)
        assertPoint("geo:0,0?q=48.137,11.575(Marienplatz)", 48.137, 11.575)
    }

    /// A geo: URI whose query is a search: its 0,0 is a placeholder, no place.
    func testAGeoSearchIsNoPlace() {
        XCTAssertNil(GeoPoint.parse("geo:0,0?q=Marienplatz+M%C3%BCnchen"))
        XCTAssertNil(GeoPoint.parse("geo:0,0?q=Marienplatz(Somewhere)"))
        XCTAssertNil(GeoPoint.parse("geo:48.137,11.575,high"))
    }

    func testWhatIsNoPlace() {
        for text in ["", "hello", "48.137", "91, 10", "10, 181", "48.137 N 11.575 N", "1, 2, 3", "48°61'N 11°E",
                     "https://example.com/", "https://maps.app.goo.gl/abc123"] {
            XCTAssertNil(GeoPoint.parse(text), text)
        }
        XCTAssertTrue(GeoPoint.isShortMapLink("https://maps.app.goo.gl/abc123"))
        XCTAssertFalse(GeoPoint.isShortMapLink("https://maps.apple.com/?ll=48.137,11.575"))
    }

    func testISO6709() throws {
        let full = try XCTUnwrap(GeoPoint.iso6709("+48.1372+011.5761+519.000/"))
        XCTAssertEqual(full.point.latitude, 48.1372, accuracy: 1e-6)
        XCTAssertEqual(full.point.longitude, 11.5761, accuracy: 1e-6)
        XCTAssertEqual(full.altitude, 519)
        let south = try XCTUnwrap(GeoPoint.iso6709("-33.8568+151.2153/"))
        XCTAssertEqual(south.point.latitude, -33.8568, accuracy: 1e-6)
        XCTAssertNil(south.altitude)
        let minutes = try XCTUnwrap(GeoPoint.iso6709("+4808.232+01134.566/"))
        XCTAssertEqual(minutes.point.latitude, 48.1372, accuracy: 1e-4)
        XCTAssertEqual(minutes.point.longitude, 11.5761, accuracy: 1e-4)
        let seconds = try XCTUnwrap(GeoPoint.iso6709("+480814+0113427/"))
        XCTAssertEqual(seconds.point.latitude, 48.137222, accuracy: 1e-5)
        XCTAssertNil(GeoPoint.iso6709("garbage"))
        XCTAssertNil(GeoPoint.iso6709("+95.0+011.0/"))
    }

    // MARK: Distance

    func testHaversine() throws {
        let munich = try XCTUnwrap(GeoPoint(latitude: 48.137154, longitude: 11.576124))
        let paris = try XCTUnwrap(GeoPoint(latitude: 48.858370, longitude: 2.294481))
        XCTAssertEqual(munich.distance(to: paris) / 1000, 688.1, accuracy: 1)
        XCTAssertEqual(munich.distance(to: paris), paris.distance(to: munich), accuracy: 1e-6)
        XCTAssertEqual(munich.distance(to: munich), 0, accuracy: 1e-6)
        // One degree along the equator, and half the way round
        let origin = try XCTUnwrap(GeoPoint(latitude: 0, longitude: 0))
        XCTAssertEqual(origin.distance(to: try XCTUnwrap(GeoPoint(latitude: 0, longitude: 1))) / 1000, 111.195, accuracy: 0.01)
        XCTAssertEqual(origin.distance(to: try XCTUnwrap(GeoPoint(latitude: 0, longitude: 180))) / 1000, 20015.1, accuracy: 1)
        // Across the date line: the short way
        let fiji = try XCTUnwrap(GeoPoint(latitude: -17, longitude: 179.5))
        let samoa = try XCTUnwrap(GeoPoint(latitude: -17, longitude: -179.5))
        XCTAssertLessThan(fiji.distance(to: samoa) / 1000, 120)
    }

    func testCoordinatesText() throws {
        XCTAssertEqual(try XCTUnwrap(GeoPoint(latitude: 48.137154, longitude: 11.576124)).text, "48.1372° N, 11.5761° E")
        XCTAssertEqual(try XCTUnwrap(GeoPoint(latitude: -33.856784, longitude: -74.044502)).text, "33.8568° S, 74.0445° W")
        XCTAssertFalse(GeoPoint.describeDistance(12_345).isEmpty)
        XCTAssertNil(GeoPoint(latitude: .nan, longitude: 0))
    }

    // MARK: Reading places and camera facts

    func testPictureLocation() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try fixture("geo.jpg") as CFURL, nil))
        let report = PictureMetadata.report(source)
        let location = try XCTUnwrap(report.location)
        XCTAssertEqual(location.point.latitude, 48.137154, accuracy: 1e-5)
        XCTAssertEqual(location.point.longitude, 11.576124, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(location.altitude), 519, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(location.direction), 123.4, accuracy: 0.01)
        XCTAssertTrue(location.trueNorth)
        for (name, latitude, longitude) in [("geo-sydney.jpg", -33.856784, 151.215297), ("geo-newyork.jpg", 40.689247, -74.044502)] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(try fixture(name) as CFURL, nil))
            let point = try XCTUnwrap(PictureMetadata.report(source).location?.point, name)
            XCTAssertEqual(point.latitude, latitude, accuracy: 1e-5, name)
            XCTAssertEqual(point.longitude, longitude, accuracy: 1e-5, name)
        }
        let none = try XCTUnwrap(CGImageSourceCreateWithURL(try fixture("nogeo.jpg") as CFURL, nil))
        XCTAssertNil(PictureMetadata.report(none).location)
        // A camera without a fix writes zeros: no place
        XCTAssertNil(MediaLocation.picture([kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0, kCGImagePropertyGPSLongitude: 0]]))
    }

    /// Numbers are written as the Mac's region writes them (a decimal comma in Germany).
    private static var decimalSeparator: String { Locale.current.decimalSeparator ?? "." }

    func testPictureCaptureFacts() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try fixture("geo.jpg") as CFURL, nil))
        let report = PictureMetadata.report(source)
        let capture = Dictionary(report.capture.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(capture[String(localized: "Camera")], "Example Camera One")
        XCTAssertEqual(capture[String(localized: "Lens")], "Example Lens 4.2mm f/1.8")
        XCTAssertEqual(capture[String(localized: "Aperture")]?.hasPrefix("ƒ/1"), true)
        XCTAssertEqual(capture[String(localized: "Shutter Speed")], PictureMetadata.shutter(1.0 / 250))
        XCTAssertEqual(capture["ISO"], "100")
        XCTAssertEqual(capture[String(localized: "Flash")], String(localized: "Did not fire"))
        XCTAssertEqual(capture[String(localized: "Exposure Program")], String(localized: "Program"))
        XCTAssertEqual(capture[String(localized: "White Balance")], String(localized: "Auto"))
        XCTAssertEqual(capture[String(localized: "Exposure Bias")], "+0.7 EV".replacingOccurrences(of: ".", with: Self.decimalSeparator))
        XCTAssertTrue(capture[String(localized: "Date Taken")]?.hasSuffix("(UTC+02:00)") == true, "with the camera's offset")
        XCTAssertNotNil(capture[String(localized: "Focal Length")])
        let groups = Set(report.groups.map(\.name))
        for group in ["Exif", "GPS", "TIFF", "IPTC"] { XCTAssertTrue(groups.contains(group), "group \(group) in \(groups)") }
        let exif = try XCTUnwrap(report.groups.first { $0.name == "Exif" })
        XCTAssertTrue(exif.entries.contains { $0.key == "LensModel" && $0.value == "Example Lens 4.2mm f/1.8" })
        XCTAssertTrue(report.media.contains { $0.label == String(localized: "Resolution") && $0.value == "64 × 48 px" })
    }

    func testCaptureValues() {
        XCTAssertEqual(PictureMetadata.flashText(0x20), String(localized: "No flash"))
        XCTAssertEqual(PictureMetadata.flashText(0x19), String(localized: "Fired"))
        XCTAssertEqual(PictureMetadata.biasText(-1.33), "−1.3 EV".replacingOccurrences(of: ".", with: Self.decimalSeparator))
        XCTAssertEqual(PictureMetadata.biasText(0), "0 EV")
        XCTAssertNil(PictureMetadata.programText(0))
        XCTAssertNotNil(PictureMetadata.orientationText(6))
        XCTAssertNil(PictureMetadata.orientationText(9))
        XCTAssertNil(PictureMetadata.wallClock("0000:00:00 00:00:00", offset: nil), "a clock never set")
        XCTAssertNil(PictureMetadata.wallClock("2024:02:30 10:00:00", offset: nil), "no such day: none, as for sorting")
        XCTAssertNil(PictureMetadata.wallClock("2024:13:01 10:00:00", offset: nil), "no such month")
        XCTAssertEqual(PictureMetadata.wallClock("2024:06:18 22:31:09", offset: "+02:00")?.hasSuffix("(UTC+02:00)"), true)
        XCTAssertEqual(VideoMetadata.takenText("2024-06-18T22:31:09+0200")?.hasSuffix("(UTC+02:00)"), true)
        XCTAssertEqual(VideoMetadata.takenText("2024-06-18T20:31:09Z")?.hasSuffix("(UTC+00:00)"), true)
        XCTAssertNil(VideoMetadata.takenText("yesterday"))
    }

    func testVideoLocationAndCamera() async throws {
        let read = await VideoMetadata.report(try fixture("geo.mov"))
        let report = try XCTUnwrap(read, "AVFoundation reads the QuickTime movie")
        let location = try XCTUnwrap(report.location, "the ISO 6709 location")
        XCTAssertEqual(location.point.latitude, 48.1372, accuracy: 1e-4)
        XCTAssertEqual(location.point.longitude, 11.5761, accuracy: 1e-4)
        XCTAssertEqual(location.altitude, 519)
        let capture = Dictionary(report.capture.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(capture[String(localized: "Camera")], "Example Camera One")
        XCTAssertTrue(capture[String(localized: "Date Taken")]?.hasSuffix("(UTC+02:00)") == true)
        XCTAssertTrue(report.media.contains { $0.label == String(localized: "Resolution") && $0.value == "64 × 48 px" })
        XCTAssertTrue(report.groups.contains { group in group.entries.contains { $0.key.contains("location.ISO6709") } })
        let point = await CaptureReader.facts(of: try fixture("geo.mov")).place?.location.point
        XCTAssertEqual(try XCTUnwrap(point).latitude, 48.1372, accuracy: 1e-4)
    }

    func testLongValuesAreShortened() {
        let long = String(repeating: "x", count: 5_000)
        XCTAssertLessThan(MetadataText.shortened(long).count, 400)
        let blob = MetadataText.describe(Data(repeating: 0xab, count: 70_000))
        XCTAssertTrue(blob.contains("ab ab"))
        XCTAssertLessThan(blob.count, 120)
        XCTAssertEqual(MetadataText.describe([1, 2, 3] as [Any]), "(1, 2, 3)")
    }

    func testInspectorFilter() {
        let groups = [MetadataGroup(name: "Exif", entries: [.init(key: "FNumber", value: "1.8"), .init(key: "ISO", value: "100")]),
                      MetadataGroup(name: "GPS", entries: [.init(key: "Latitude", value: "48.1")])]
        XCTAssertEqual(InspectorView.filtered(groups, by: "").count, 2)
        XCTAssertEqual(InspectorView.filtered(groups, by: "fnum").map(\.name), ["Exif"])
        XCTAssertEqual(InspectorView.filtered(groups, by: "fnum").first?.entries.count, 1)
        XCTAssertEqual(InspectorView.filtered(groups, by: "48.1").map(\.name), ["GPS"])
        XCTAssertEqual(InspectorView.filtered(groups, by: "gps").first?.entries.count, 1, "a group's name keeps all its keys")
        XCTAssertTrue(InspectorView.filtered(groups, by: "nothing").isEmpty)
    }

    // MARK: Cache

    func testTheCacheReadsAFileOnce() async throws {
        let reads = Counter()
        let paris = try XCTUnwrap(GeoPoint(latitude: 48.858370, longitude: 2.294481))
        let cache = LocationCache(companions: { _ in Companions() }) { url, _, _ in
            reads.add()
            return url.lastPathComponent == "none.jpg" ? CaptureFacts() : CaptureFacts(place: CapturePlace(location: MediaLocation(point: paris), source: .file))
        }
        let url = URL(fileURLWithPath: "/tmp/a.jpg"), none = URL(fileURLWithPath: "/tmp/none.jpg")
        let date = Date(timeIntervalSince1970: 1_000)
        let first = await cache.point(of: url, modified: date)
        XCTAssertEqual(first, paris)
        _ = await cache.point(of: url, modified: date)
        XCTAssertEqual(reads.value, 1, "the same version: from the cache")
        _ = await cache.point(of: url, modified: date.addingTimeInterval(1))
        XCTAssertEqual(reads.value, 2, "changed since: read again")
        _ = await cache.point(of: none, modified: date)
        let noPlace = await cache.point(of: none, modified: date)
        XCTAssertNil(noPlace)
        XCTAssertEqual(reads.value, 3, "no place is known too")
        let many = (0..<50).map { (URL(fileURLWithPath: "/tmp/\($0).jpg"), Optional(date)) }
        let found = await cache.points(of: many)
        XCTAssertEqual(found.count, 50)
        XCTAssertEqual(reads.value, 53)

        // Sorting reads without a GoPro's route; asked for it, the file is
        // read once more, and then known for both
        let routes = Counter()
        let withRoutes = LocationCache(companions: { _ in Companions() }) { _, _, track in
            if track { routes.add() }
            return CaptureFacts()
        }
        _ = await withRoutes.point(of: url, modified: date)
        _ = await withRoutes.facts(of: url, modified: date, track: false)
        XCTAssertEqual(routes.value, 0)
        _ = await withRoutes.facts(of: url, modified: date)
        _ = await withRoutes.facts(of: url, modified: date)
        _ = await withRoutes.point(of: url, modified: date)
        XCTAssertEqual(routes.value, 1)
    }

    // MARK: Sorting by distance

    func testSortingPutsItemsWithoutAPlaceLast() throws {
        let munich = try XCTUnwrap(GeoPoint(latitude: 48.137154, longitude: 11.576124))
        func entry(_ name: String) -> GridEntry { GridEntry(url: URL(fileURLWithPath: "/p/\(name)"), kind: .image) }
        let near = entry("near.jpg"), far = entry("far.jpg"), farther = entry("farther.jpg")
        let unknown = entry("a-unknown.jpg"), unknown2 = entry("b-unknown.jpg")
        let folder = GridEntry(url: URL(fileURLWithPath: "/p/zz"), kind: .folder)
        let located: [URL: GeoPoint] = [
            near.url: try XCTUnwrap(GeoPoint(latitude: 48.2, longitude: 11.6)),
            far.url: try XCTUnwrap(GeoPoint(latitude: 48.858370, longitude: 2.294481)),
            farther.url: try XCTUnwrap(GeoPoint(latitude: -33.856784, longitude: 151.215297)),
        ]
        let input = [unknown2, farther, folder, unknown, near, far]
        let nearestFirst = BrowserModel.sortEntries(input, key: .distance, ascending: true, origin: munich, located: located)
        XCTAssertEqual(nearestFirst.map(\.name), ["zz", "near.jpg", "far.jpg", "farther.jpg", "a-unknown.jpg", "b-unknown.jpg"])
        let farthestFirst = BrowserModel.sortEntries(input, key: .distance, ascending: false, origin: munich, located: located)
        XCTAssertEqual(farthestFirst.map(\.name), ["zz", "farther.jpg", "far.jpg", "near.jpg", "a-unknown.jpg", "b-unknown.jpg"],
                       "reversed, and still without a place at the end")
        let noOrigin = BrowserModel.sortEntries(input, key: .distance, ascending: true, located: located)
        XCTAssertEqual(noOrigin.map(\.name), ["zz", "a-unknown.jpg", "b-unknown.jpg", "far.jpg", "farther.jpg", "near.jpg"],
                       "no origin: by name")
        // Merged results keep the order
        let order = BrowserModel.EntryOrder(key: .distance, ascending: true, captured: [:], origin: munich, located: located)
        XCTAssertEqual(order.merged(order.sorted([near, unknown]), [farther, far]).map(\.name),
                       ["near.jpg", "far.jpg", "farther.jpg", "a-unknown.jpg"])
    }

    private func folderWithPlaces() throws -> (TempTree, URL) {
        let tree = try TempTree(self)
        for name in ["geo.jpg", "geo-paris.jpg", "geo-sydney.jpg", "geo-newyork.jpg", "nogeo.jpg", "geo.mov"] {
            try FileManager.default.copyItem(at: try fixture(name), to: tree.root.appendingPathComponent(name))
        }
        return (tree, tree.root)
    }

    func testSortByDistanceFromAnItem() async throws {
        let (_, folder) = try folderWithPlaces()
        let m = makeModel()
        await openAndWait(m, folder)
        await waitUntil { !m.isLoading && m.entries.filter(\.isMedia).count == 6 }
        let paris = try XCTUnwrap(m.entries.first { $0.name == "geo-paris.jpg" })
        m.sortByDistance(from: paris)
        // Paris; Munich (the photo and the video, a few metres apart); New York; Sydney; no place
        await waitUntil({ m.mediaNames == ["geo-paris.jpg", "geo.jpg", "geo.mov", "geo-newyork.jpg", "geo-sydney.jpg", "nogeo.jpg"]
                          || m.mediaNames == ["geo-paris.jpg", "geo.mov", "geo.jpg", "geo-newyork.jpg", "geo-sydney.jpg", "nogeo.jpg"] },
                        timeout: 10)
        XCTAssertEqual(m.sortKey, .distance)
        XCTAssertTrue(m.sortAscending)
        XCTAssertEqual(m.knownDistance(of: paris.url) ?? -1, 0, accuracy: 1)
        XCTAssertNil(m.knownDistance(of: folder.appendingPathComponent("nogeo.jpg")))
        // The same toggle as the other sorts reverses it; no place stays last
        m.setSort(.distance)
        await waitUntil({ m.mediaNames.first == "geo-sydney.jpg" && m.mediaNames.last == "nogeo.jpg" }, timeout: 5)
        // Another sort: back by name
        m.setSort(.name)
        await waitUntil { m.sortKey == .name && m.mediaNames.last == "nogeo.jpg" && m.mediaNames.first != "geo-sydney.jpg" }
        XCTAssertNil(m.locationProgress)
    }

    func testSortByDistanceFromCoordinatesAndRemembered() async throws {
        let (_, folder) = try folderWithPlaces()
        let defaults = makeTestDefaults()
        let m = BrowserModel(defaults: defaults)
        await openAndWait(m, folder)
        await waitUntil { !m.isLoading && m.entries.filter(\.isMedia).count == 6 }
        // Distance without a place to measure from asks for one
        m.setSort(.distance)
        XCTAssertTrue(m.distanceOriginRequested)
        XCTAssertEqual(m.sortKey, .name)
        m.distanceOriginRequested = false
        // Sydney Opera House, pasted as a link
        m.setDistanceOrigin(try XCTUnwrap(GeoPoint.parse("https://maps.apple.com/?ll=-33.8568,151.2153")))
        await waitUntil({ m.mediaNames.first == "geo-sydney.jpg" && m.mediaNames.last == "nogeo.jpg" }, timeout: 10)
        let again = BrowserModel(defaults: defaults)
        XCTAssertEqual(again.sortKey, .distance)
        XCTAssertEqual(try XCTUnwrap(again.distanceOrigin).latitude, -33.8568, accuracy: 1e-4)
    }

    func testAnItemWithoutAPlaceSays() async throws {
        let (_, folder) = try folderWithPlaces()
        let m = makeModel()
        await openAndWait(m, folder)
        await waitUntil { !m.isLoading && m.entries.filter(\.isMedia).count == 6 }
        m.sortByDistance(from: try XCTUnwrap(m.entries.first { $0.name == "nogeo.jpg" }))
        await waitUntil { m.locationMissing == "nogeo.jpg" }
        XCTAssertNotEqual(m.sortKey, .distance)
    }

    // MARK: Inspector key and Get Info

    func testInspectorInTheGridAndGetInfo() async throws {
        let (_, folder) = try folderWithPlaces()
        let m = makeModel()
        XCTAssertFalse(m.handleKey(.char("i"), command: false), "no folder: nothing to inspect")
        await openAndWait(m, folder)
        await waitUntil { !m.isLoading && m.entries.filter(\.isMedia).count == 6 }
        XCTAssertTrue(m.handleKey(.char("i"), command: false))
        XCTAssertTrue(m.showInspector)
        XCTAssertNotNil(m.inspectedEntry)
        XCTAssertTrue(m.handleKey(.char("i"), command: false))
        XCTAssertFalse(m.showInspector)
        XCTAssertFalse(m.handleKey(.char("i"), command: true), "⌘I goes to its menu item")
        let sydney = try XCTUnwrap(m.entries.first { $0.name == "geo-sydney.jpg" })
        m.getInfo(sydney)
        XCTAssertTrue(m.showInspector)
        XCTAssertEqual(m.inspectedEntry?.name, "geo-sydney.jpg")
    }
}

/// Counts calls from any thread.
/// Counts calls from any thread (read counts of caches).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}

private extension BrowserModel {
    /// The names of the photos and videos shown, in order (no "..").
    var mediaNames: [String] { entries.filter(\.isMedia).map(\.name) }
}
