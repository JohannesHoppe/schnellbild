import XCTest
import ImageIO
@testable import Schnellbild

/// Time and place from every source (`CaptureReader`): GoPro's GPMF track,
/// DJI flight logs, Sony's clip XML, XMP sidecars and XMP inside movies,
/// Android's `©xyz`, GPX tracks of the folder, time zones; the parsers fed
/// hostile input. Fixtures: `Tests/SchnellbildTests/Metadata`, written by
/// `python3 -I Scripts/make_metadata_fixtures.py Tests/SchnellbildTests/Metadata`.
final class MetadataSourceTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Metadata"), "missing fixture \(name)")
    }

    private func bytes(_ name: String) throws -> Data { try Data(contentsOf: try fixture(name)) }

    /// Fixtures copied into a folder of their own, under the names given.
    private func folder(_ files: [String: String]) throws -> URL {
        let tree = try TempTree(self)
        for (fixtureName, name) in files {
            try FileManager.default.copyItem(at: try fixture(fixtureName), to: tree.root.appendingPathComponent(name))
        }
        return tree.root
    }

    /// A 4 × 4 JPEG with the given properties.
    @discardableResult
    private func photo(_ url: URL, _ properties: [CFString: Any] = [:]) throws -> URL {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func utc(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }

    private func assertPlace(_ point: GeoPoint?, _ latitude: Double, _ longitude: Double, accuracy: Double = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let point else { return XCTFail("no place", file: file, line: line) }
        XCTAssertEqual(point.latitude, latitude, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(point.longitude, longitude, accuracy: accuracy, file: file, line: line)
    }

    // MARK: GoPro

    func testGoProTelemetryGPS5() async throws {
        let file = try XCTUnwrap(FileBytes(try fixture("gopro-gps5.mp4")))
        let movie = try XCTUnwrap(MP4Boxes.read(file))
        XCTAssertEqual(movie.telemetry.count, 10)
        XCTAssertEqual(movie.telemetryStarts.count, 10)
        XCTAssertEqual(movie.telemetryStarts[2], 2.002, accuracy: 1e-9)
        let payload = try XCTUnwrap(file.read(at: movie.telemetry[0].lowerBound, count: Int(movie.telemetry[0].count)))
        let fixes = GPMF.fixes(in: payload)
        XCTAssertEqual(fixes.count, 18, "the GPS stream's samples; the accelerometer's left alone")
        XCTAssertEqual(fixes[0].fix, 0)
        XCTAssertFalse(fixes[0].isGood, "no lock yet")
        XCTAssertEqual(fixes[0].time, try utc("2024-06-01T10:00:00Z"))

        // The whole file: the first good fix, the start by GPS time (not the movie header's local clock)
        let folder = try folder(["gopro-gps5.mp4": "GX010001.MP4"])
        let facts = await CaptureReader.facts(of: folder.appendingPathComponent("GX010001.MP4"))
        let place = try XCTUnwrap(facts.place)
        XCTAssertEqual(place.source, .goPro)
        assertPlace(place.location.point, 62.1012, 7.2065)
        XCTAssertEqual(try XCTUnwrap(place.location.altitude), 12, accuracy: 0.01)
        XCTAssertEqual(place.accuracy, .dilution(1.8))
        let time = try XCTUnwrap(facts.time)
        XCTAssertEqual(time.source, .goPro)
        XCTAssertEqual(time.date.timeIntervalSince1970, try utc("2024-06-01T10:00:00Z").timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNil(time.offset)
        XCTAssertFalse(time.isCameraClock)
        let track = try XCTUnwrap(facts.track)
        XCTAssertEqual(track.source, .goPro)
        XCTAssertEqual(track.points.count, 8, "one point per locked payload")
        assertPlace(track.points.last?.point, 62.1026, 7.2086)
        XCTAssertGreaterThan(track.length, 100)
    }

    func testGoProSamplesInChunks() throws {
        let file = try XCTUnwrap(FileBytes(try fixture("gopro-chunked.mp4")))
        let movie = try XCTUnwrap(MP4Boxes.read(file))
        XCTAssertEqual(movie.telemetry.count, 5, "two samples a chunk, the last chunk one")
        let found = try XCTUnwrap(CaptureReader.telemetry(file, movie.telemetry, starts: movie.telemetryStarts))
        assertPlace(found.fix?.point, 62.1012, 7.2065)
        XCTAssertEqual(found.track.count, 3)
    }

    func testGoProTelemetryGPS9() async throws {
        let folder = try folder(["gopro-gps9.mp4": "GX010002.MP4"])
        let facts = await CaptureReader.facts(of: folder.appendingPathComponent("GX010002.MP4"))
        assertPlace(facts.place?.location.point, 48.8738, 2.2950)
        XCTAssertEqual(facts.place?.accuracy, .dilution(1.2))
        XCTAssertEqual(try XCTUnwrap(facts.time).date.timeIntervalSince1970, try utc("2025-07-01T09:30:00Z").timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(facts.track?.points.count, 6)
        XCTAssertEqual(try XCTUnwrap(facts.track?.points[1].time).timeIntervalSince1970,
                       try utc("2025-07-01T09:30:01Z").timeIntervalSince1970, accuracy: 0.01, "GPS9's own time per sample")
    }

    func testGPMFTypeAndScale() throws {
        XCTAssertEqual(GPMF.expandType(Array("l[3]S".utf8)), Array("lllS".utf8))
        XCTAssertNil(GPMF.expandType(Array("l[".utf8)))
        XCTAssertEqual(GPMF.expandType(Array("[3]".utf8)), [], "a repeat with nothing before it repeats nothing")
        XCTAssertEqual(try XCTUnwrap(GPMF.gpsTime(Array("240601100002.002".utf8))).timeIntervalSince1970, 1_717_236_002.002, accuracy: 1e-6)
        XCTAssertNil(GPMF.gpsTime(Array("241301100002.002".utf8)), "month 13")
        XCTAssertNil(GPMF.gpsTime(Array("garbage".utf8)))
    }

    // MARK: MP4 user data and XMP inside movies

    func testAndroidLocationAndMovieHeader() async throws {
        let movie = try XCTUnwrap(MP4Boxes.read(MemoryBytes(try bytes("android.mp4"))))
        assertPlace(movie.location?.point, 59.9075, 10.7531)
        XCTAssertEqual(movie.created, try utc("2023-05-04T09:08:07Z"))
        let folder = try folder(["android.mp4": "VID_20230504.mp4"])
        let facts = await CaptureReader.facts(of: folder.appendingPathComponent("VID_20230504.mp4"))
        assertPlace(facts.place?.location.point, 59.9075, 10.7531)
        XCTAssertEqual(facts.place?.source, .file)
        XCTAssertEqual(facts.time?.date, try utc("2023-05-04T09:08:07Z"), "the movie header's time is UTC")
    }

    func testXMPInsideMovies() async throws {
        let folder = try folder(["xmp-uuid.mp4": "clip.mp4", "xmp-udta.mov": "clip.mov"])
        let mp4 = await CaptureReader.facts(of: folder.appendingPathComponent("clip.mp4"))
        assertPlace(mp4.place?.location.point, 41.4020, 2.1735)
        XCTAssertEqual(mp4.place?.source, .embeddedXMP)
        XCTAssertEqual(mp4.place?.location.altitude, 170)
        XCTAssertEqual(mp4.time?.date, try utc("2022-03-14T14:09:26Z"))
        XCTAssertEqual(mp4.time?.offset, 3600)
        XCTAssertEqual(mp4.time?.source, .embeddedXMP, "XMP's capture time before the movie header's")
        let mov = await CaptureReader.facts(of: folder.appendingPathComponent("clip.mov"))
        assertPlace(mov.place?.location.point, 35.6587, 139.7010)
        XCTAssertEqual(mov.time?.date, try utc("2021-11-01T23:15:00Z"))
    }

    // MARK: DJI

    func testDJIFlightLogForms() throws {
        struct Expected { let file: String; let lat: Double; let lon: Double; let clock: String?; let altitude: Double? }
        let cases = [
            Expected(file: "dji-phantom.SRT", lat: 47.5576, lon: 10.7498, clock: "2018-07-03T10:15:03Z", altitude: nil),
            Expected(file: "dji-oldfirmware.SRT", lat: 37.8199, lon: -122.4783, clock: "2017-08-05T14:11:51Z", altitude: nil),
            Expected(file: "dji-mini.SRT", lat: -25.3444, lon: 131.0369, clock: nil, altitude: nil),
            Expected(file: "dji-m300.SRT", lat: 36.5297, lon: -6.2925, clock: "2022-06-21T16:06:17Z", altitude: nil),
            Expected(file: "dji-mavic2.SRT", lat: 51.1789, lon: -1.8262, clock: "2019-09-27T10:28:08Z", altitude: nil),
            Expected(file: "dji-air2s.SRT", lat: 41.4036, lon: 2.1744, clock: "2022-08-07T13:40:40Z", altitude: 117),
            Expected(file: "dji-mavic3.SRT", lat: 27.1751, lon: 78.0421, clock: "2021-12-25T12:27:52Z", altitude: 171.401),
        ]
        for expected in cases {
            let log = try XCTUnwrap(DJIFlightLog.read(try bytes(expected.file)), expected.file)
            assertPlace(log.first?.point, expected.lat, expected.lon)
            XCTAssertEqual(log.track.count, 2, expected.file)
            if let clock = expected.clock {
                let floating = try XCTUnwrap(log.start?.floating, expected.file)
                XCTAssertEqual(floating.timeIntervalSince1970, try utc(clock).timeIntervalSince1970, accuracy: 1, expected.file)
                XCTAssertNil(log.start?.offset, "the drone's clock has no zone")
            } else {
                XCTAssertNil(log.start, expected.file)
            }
            if let altitude = expected.altitude {
                XCTAssertEqual(try XCTUnwrap(log.first?.altitude, expected.file), altitude, accuracy: 0.001)
            } else {
                XCTAssertNil(log.first?.altitude, expected.file)
            }
        }
        let milliseconds = try XCTUnwrap(DJIFlightLog.read(try bytes("dji-air2s.SRT"))?.start?.floating)
        XCTAssertEqual(milliseconds.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.774, accuracy: 0.0005)
        let none = try XCTUnwrap(DJIFlightLog.read(try bytes("dji-nofix.SRT")))
        XCTAssertNil(none.first, "zeros: no fix")
        XCTAssertNotNil(none.start)
    }

    func testADJIVideoTakesItsFlightLog() async throws {
        // The log's name in another case than the video's, as copied from some cards
        let folder = try folder(["DJI_0001.MP4": "DJI_0001.MP4", "DJI_0001.SRT": "dji_0001.srt"])
        let video = folder.appendingPathComponent("DJI_0001.MP4")
        let companions = Companions.of(video, names: FolderNames(recheck: 0))
        XCTAssertEqual(companions.flightLog?.name, "dji_0001.srt")
        let facts = await CaptureReader.facts(of: video, companions: companions)
        let place = try XCTUnwrap(facts.place)
        XCTAssertEqual(place.source, .djiLog("dji_0001.srt"))
        assertPlace(place.location.point, 52.5200, 13.4050)
        XCTAssertEqual(place.source.placeText, String(localized: "From DJI flight log dji_0001.srt"))
        let time = try XCTUnwrap(facts.time)
        XCTAssertEqual(time.source, .djiLog("dji_0001.srt"), "the log's clock before the movie header's")
        XCTAssertTrue(time.isCameraClock)
        let floating = try utc("2023-04-09T11:00:00Z")
        XCTAssertEqual(time.date, ClockReading(floating: floating, offset: nil).instant(in: .current))
        XCTAssertEqual(facts.track?.points.count, 3)
        XCTAssertEqual(facts.track?.source, .djiLog("dji_0001.srt"))
    }

    // MARK: Sony

    func testSonyClipXML() async throws {
        let folder = try folder(["C0001.MP4": "C0001.MP4", "C0001M01.XML": "C0001M01.XML"])
        let facts = await CaptureReader.facts(of: folder.appendingPathComponent("C0001.MP4"),
                                              companions: Companions.of(folder.appendingPathComponent("C0001.MP4"), names: FolderNames(recheck: 0)))
        assertPlace(facts.place?.location.point, 35.0393, 135.7297)
        XCTAssertEqual(facts.place?.source, .sidecar("C0001M01.XML"))
        XCTAssertEqual(facts.time?.date, try utc("2024-11-30T01:08:55Z"))
        XCTAssertEqual(facts.time?.offset, 9 * 3600)
        let void = Data("""
            <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.00"><AcquisitionRecord><Group name="ExifGPS">
            <Item name="Status" value="V"/><Item name="Latitude" value="35:2:21"/><Item name="Longitude" value="135:43:46"/>
            </Group></AcquisitionRecord></NonRealTimeMeta>
            """.utf8)
        XCTAssertNil(SonyClipXML.read(void), "a void fix is no place")
        XCTAssertNil(SonyClipXML.read(Data("<Other><CreationDate value=\"2024-11-30T10:08:55+09:00\"/></Other>".utf8)), "not Sony's root")
        XCTAssertEqual(try XCTUnwrap(SonyClipXML.sexagesimal("35:38:46.649")), 35.646291, accuracy: 1e-6)
        XCTAssertNil(SonyClipXML.sexagesimal("35:61:00"))
    }

    // MARK: XMP sidecars

    func testXMPSidecarsComeFirst() async throws {
        let folder = try folder(["lightroom.xmp": "IMG_0001.xmp", "darktable.xmp": "IMG_0002.JPG.xmp"])
        // Its own place and time: the sidecar's win (an editor wrote them last)
        try photo(folder.appendingPathComponent("IMG_0001.JPG"), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2001:01:01 00:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.0, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 10.0, kCGImagePropertyGPSLongitudeRef: "E"],
        ])
        try photo(folder.appendingPathComponent("IMG_0002.JPG"))
        let names = FolderNames(recheck: 0)
        let first = folder.appendingPathComponent("IMG_0001.JPG"), second = folder.appendingPathComponent("IMG_0002.JPG")
        let lightroom = await CaptureReader.facts(of: first, companions: .of(first, names: names))
        assertPlace(lightroom.place?.location.point, 64.1460, -21.9360)
        XCTAssertEqual(lightroom.place?.source, .sidecar("IMG_0001.xmp"))
        XCTAssertEqual(lightroom.place?.location.altitude, 25)
        XCTAssertEqual(try XCTUnwrap(lightroom.time).date.timeIntervalSince1970,
                       try utc("2020-03-01T00:59:30Z").timeIntervalSince1970 + 0.25, accuracy: 0.001)
        XCTAssertEqual(lightroom.time?.offset, -3600)
        XCTAssertEqual(lightroom.time?.source.timeText, String(localized: "From IMG_0001.xmp"))
        let darktable = await CaptureReader.facts(of: second, companions: .of(second, names: names))
        assertPlace(darktable.place?.location.point, -33.856833, 151.215, accuracy: 1e-6)
        XCTAssertEqual(darktable.place?.location.altitude, -5, "GPSAltitudeRef 1: below sea level")
        XCTAssertEqual(darktable.place?.accuracy, .metres(6))
        XCTAssertEqual(darktable.time?.isCameraClock, true)

        // name.ext.xmp before name.xmp
        try FileManager.default.copyItem(at: try fixture("darktable.xmp"), to: folder.appendingPathComponent("IMG_0001.JPG.xmp"))
        let both = Companions.of(first, names: names)
        XCTAssertEqual(both.xmp.map(\.name), ["IMG_0001.JPG.xmp", "IMG_0001.xmp"])
    }

    func testXMPValues() {
        XCTAssertEqual(XMPMetadata.coordinate("48,51.5004N"), 48 + 51.5004 / 60)
        XCTAssertEqual(XMPMetadata.coordinate("2,17,40.2W"), -(2 + 17 / 60.0 + 40.2 / 3600))
        XCTAssertEqual(XMPMetadata.coordinate("-12.5"), -12.5)
        XCTAssertNil(XMPMetadata.coordinate("48,61N"))
        XCTAssertNil(XMPMetadata.coordinate("48,10"))
        XCTAssertNil(XMPMetadata.coordinate("-48,10N"))
        XCTAssertNil(XMPMetadata.coordinate(String(repeating: "9", count: 10_000) + "N"))
        XCTAssertEqual(XMPMetadata.rational("4321/10"), 432.1)
        XCTAssertNil(XMPMetadata.rational("1/0"))
        let outOfRange = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSLatitude="95,0N" exif:GPSLongitude="10,0E"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        XCTAssertNil(XMPMetadata.read(outOfRange), "no latitude beyond 90°")
        let otherNamespace = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:exif="http://example.com/not-exif/" exif:GPSLatitude="45,0N" exif:GPSLongitude="10,0E"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        XCTAssertNil(XMPMetadata.read(otherNamespace), "properties count by their namespace, not their prefix")
    }

    // MARK: GPX

    private func track(_ points: [(Double, Double, String)], segments: [Int]? = nil) throws -> GPXTrack {
        var body = ""
        var index = 0
        for count in segments ?? [points.count] {
            body += "<trkseg>"
            for (lat, lon, time) in points[index..<index + count] {
                body += "<trkpt lat=\"\(lat)\" lon=\"\(lon)\"><time>\(time)</time></trkpt>"
            }
            body += "</trkseg>"
            index += count
        }
        let gpx = "<?xml version=\"1.0\"?><gpx version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk>\(body)</trk></gpx>"
        return try XCTUnwrap(GPXTrack.read(Data(gpx.utf8)))
    }

    func testGPXInterpolation() throws {
        let walk = try XCTUnwrap(GPXTrack.read(try bytes("walk.gpx")))
        XCTAssertEqual(walk.segments.map(\.count), [30, 10])
        // On a point, between two, at the gap's limit, beyond it, outside the span, between segments
        let onPoint = try XCTUnwrap(walk.place(at: try utc("2024-05-17T08:00:10Z")))
        assertPlace(onPoint.point, 60.3976, 5.3242, accuracy: 1e-6)
        XCTAssertEqual(onPoint.gap, 0)
        let between = try XCTUnwrap(walk.place(at: try utc("2024-05-17T08:00:05Z")))
        assertPlace(between.point, 60.39755, 5.3241, accuracy: 1e-7)
        XCTAssertEqual(between.altitude, 5.5)
        XCTAssertEqual(between.gap, 5)
        XCTAssertNil(walk.place(at: try utc("2024-05-17T07:59:59Z")), "before the track")
        XCTAssertNil(walk.place(at: try utc("2024-05-17T08:05:00Z")), "after the first segment, before the second")
        XCTAssertNil(walk.place(at: try utc("2024-05-17T09:45:00Z")), "after the track")

        let sparse = try track([(10, 10, "2024-01-01T10:00:00Z"), (10, 11, "2024-01-01T10:10:00Z"), (10, 12, "2024-01-01T10:20:01Z")])
        let atLimit = try XCTUnwrap(sparse.place(at: try utc("2024-01-01T10:05:00Z")), "300 s from both points")
        assertPlace(atLimit.point, 10, 10.5)
        XCTAssertNil(sparse.place(at: try utc("2024-01-01T10:15:01Z")), "301 s from the nearer point")

        // Across the antimeridian the short way, unsorted points sorted, points without time left out
        let pacific = try track([(0, 179.9, "2024-01-01T10:01:00Z"), (0, 179.5, "2024-01-01T10:00:00Z"), (0, -179.9, "2024-01-01T10:02:00Z")])
        let east = try XCTUnwrap(pacific.place(at: try utc("2024-01-01T10:01:30Z")))
        XCTAssertEqual(abs(east.point.longitude), 180, accuracy: 1e-6)
        let unsorted = try XCTUnwrap(pacific.place(at: try utc("2024-01-01T10:00:30Z")))
        assertPlace(unsorted.point, 0, 179.7)
        let timeless = try XCTUnwrap(GPXTrack.read(Data("""
            <gpx><trk><trkseg><trkpt lat="1" lon="1"/><trkpt lat="2" lon="2"><time>2024-01-01T10:00:00Z</time></trkpt></trkseg></trk></gpx>
            """.utf8)))
        XCTAssertEqual(timeless.segments.map(\.count), [1])
        // One point: only its own time; two at the same time: that point
        assertPlace(timeless.place(at: try utc("2024-01-01T10:00:00Z"))?.point, 2, 2)
        XCTAssertNil(timeless.place(at: try utc("2024-01-01T10:00:01Z")))
        let twice = try track([(5, 5, "2024-01-01T10:00:00Z"), (6, 6, "2024-01-01T10:00:00Z")])
        XCTAssertNotNil(twice.place(at: try utc("2024-01-01T10:00:00Z")))
        // A time written without a zone is UTC in GPX
        let noZone = try track([(5, 5, "2024-01-01T10:00:00"), (5, 6, "2024-01-01T10:01:00")])
        XCTAssertNotNil(noZone.place(at: try utc("2024-01-01T10:00:30Z")))
    }

    func testGPXPlacesPhotosWithoutGPSByTheirTime() async throws {
        let folder = try folder(["walk.gpx": "walk.gpx"])
        // 10:00:05 at UTC+02:00 is 08:00:05 UTC, five seconds into the track
        let offsetPhoto = try photo(folder.appendingPathComponent("a.jpg"), [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:05:17 10:00:05", kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]])
        let ownGPS = try photo(folder.appendingPathComponent("b.jpg"), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:17 10:00:05",
                                             kCGImagePropertyExifOffsetTimeOriginal: "+02:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 1.0, kCGImagePropertyGPSLongitudeRef: "E",
                                            kCGImagePropertyGPSHPositioningError: 4.0]])
        let outside = try photo(folder.appendingPathComponent("c.jpg"), [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:05:17 13:00:00", kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]])
        let names = FolderNames(recheck: 0)
        let placed = await CaptureReader.facts(of: offsetPhoto, companions: .of(offsetPhoto, names: names))
        let place = try XCTUnwrap(placed.place)
        XCTAssertEqual(place.source, .gpxTrack("walk.gpx"))
        XCTAssertEqual(place.source.placeText, String(localized: "From GPX track walk.gpx"))
        XCTAssertEqual(place.accuracy, .interpolated(5))
        assertPlace(place.location.point, 60.39755, 5.3241, accuracy: 1e-7)
        let own = await CaptureReader.facts(of: ownGPS, companions: .of(ownGPS, names: names))
        XCTAssertEqual(own.place?.source, .file, "a photo with its own GPS keeps it")
        XCTAssertEqual(own.place?.accuracy, .metres(4))
        let none = await CaptureReader.facts(of: outside, companions: .of(outside, names: names))
        XCTAssertNil(none.place, "outside the track's time")
        XCTAssertNotNil(none.time)
        // Nothing written: the photo is as it was
        let props = CGImageSourceCreateWithURL(offsetPhoto as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary])
    }

    // MARK: Time zones

    func testClockReadingsAndZones() throws {
        let oslo = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let summer = try XCTUnwrap(ClockReading.parse("2024:06:18 22:31:09"))
        XCTAssertNil(summer.offset)
        XCTAssertEqual(summer.instant(in: oslo), try utc("2024-06-18T20:31:09Z"), "a camera clock in Oslo's summer time")
        let winter = try XCTUnwrap(ClockReading.parse("2024-01-18T22:31:09"))
        XCTAssertEqual(winter.instant(in: oslo), try utc("2024-01-18T21:31:09Z"))
        let stated = try XCTUnwrap(ClockReading.parse("2024-06-18T22:31:09-05:30"))
        XCTAssertEqual(stated.instant(in: oslo), try utc("2024-06-19T04:01:09Z"), "a stated offset wins over the zone")
        XCTAssertEqual(ClockReading.parse("2024-06-18T22:31:09+0200")?.offset, 7200)
        XCTAssertEqual(ClockReading.parse("2024-06-18T22:31Z")?.offset, 0)
        XCTAssertEqual(ClockReading.parse("2024-06-18T22:31:09.25Z").map { $0.floating.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) }, 0.25)
        // A wall clock in the hour the clocks skip (Oslo, 31 March 2024, 02:00 → 03:00) still names a moment
        let skipped = try XCTUnwrap(ClockReading.parse("2024-03-31T02:30:00"))
        XCTAssertNotNil(skipped.instant(in: oslo))
        for text in ["0000:00:00 00:00:00", "2024-02-30T10:00:00", "2024-06-18", "    ", "2024-06-18T25:00:00", "2024-06-18T10:00:00+99:00"] {
            XCTAssertNil(ClockReading.parse(text), text)
        }
        XCTAssertEqual(ClockReading.offset("+05:45"), 20_700)
        XCTAssertEqual(ClockReading.offset("-03:30"), -12_600)
        XCTAssertNil(ClockReading.offset("05:00"))
        XCTAssertNil(ClockReading.offset("+25:00"))

        // EXIF: OffsetTimeOriginal goes with DateTimeOriginal
        let exif = CaptureReader.picture([kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:06:18 22:31:09", kCGImagePropertyExifOffsetTimeOriginal: "+09:00"]] as [CFString: Any])
        let time = try XCTUnwrap(exif.time)
        XCTAssertEqual(time.date, try utc("2024-06-18T13:31:09Z"))
        XCTAssertTrue(time.text.hasSuffix("(UTC+09:00)"), time.text)
        XCTAssertTrue(CaptureTime(try XCTUnwrap(ClockReading.parse("2024-06-18T22:31:09-03:30")), source: .file).text.hasSuffix("(UTC-03:30)"))
        // DateTime with OffsetTime when the original is missing
        let digitized = CaptureReader.picture([kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2019:11:19 13:47:00"],
                                               kCGImagePropertyExifDictionary: [kCGImagePropertyExifOffsetTime: "-08:00"]] as [CFString: Any])
        XCTAssertEqual(digitized.time?.date, try utc("2019-11-19T21:47:00Z"))
    }

    func testTheCaptureDateComesFromASidecar() async throws {
        let tree = try TempTree(self)
        let url = try photo(tree.root.appendingPathComponent("scan.jpg"))
        try Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:DateTimeOriginal="1987-07-01T12:00:00Z"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8).write(to: tree.root.appendingPathComponent("scan.xmp"))
        let date = await BrowserModel.captureDate(of: url)
        XCTAssertEqual(date, try utc("1987-07-01T12:00:00Z"))
    }

    // MARK: Cache and Inspector

    func testTheCacheFollowsTheCompanions() async throws {
        let tree = try TempTree(self)
        let url = try photo(tree.root.appendingPathComponent("p.jpg"))
        let names = FolderNames(recheck: 0)
        let cache = LocationCache(companions: { Companions.of($0, names: names) })
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let before = await cache.facts(of: url, modified: modified)
        XCTAssertNil(before.place)
        XCTAssertEqual(cache.cached(url, modified: modified), GeoPoint??.some(nil))
        // A sidecar arrives: the cached answer no longer counts
        let sidecar = tree.root.appendingPathComponent("p.xmp")
        try FileManager.default.copyItem(at: try fixture("lightroom.xmp"), to: sidecar)
        XCTAssertNil(cache.cachedFacts(url, modified: modified))
        let after = await cache.facts(of: url, modified: modified)
        assertPlace(after.place?.location.point, 64.1460, -21.9360)
        // Edited (another date): read again
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.copyItem(at: try fixture("darktable.xmp"), to: sidecar)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: sidecar.path)
        let edited = await cache.facts(of: url, modified: modified)
        assertPlace(edited.place?.location.point, -33.856833, 151.215, accuracy: 1e-6)
    }

    func testTheInspectorShowsTheSource() throws {
        var report = MediaReport()
        report.capture = [InfoRow(label: String(localized: "Date Taken"), value: "old"), InfoRow(label: String(localized: "Camera"), value: "X")]
        let point = try XCTUnwrap(GeoPoint(latitude: 62.1, longitude: 7.2))
        let facts = CaptureFacts(
            time: CaptureTime(utc: try utc("2024-06-01T10:00:00Z"), source: .goPro),
            place: CapturePlace(location: MediaLocation(point: point, altitude: 12), source: .goPro, accuracy: .dilution(1.8)),
            track: GeoTrack(points: [.init(point: point), .init(point: try XCTUnwrap(GeoPoint(latitude: 62.11, longitude: 7.2)))], source: .goPro))
        report.adopt(facts)
        XCTAssertEqual(report.capture.map(\.label), [String(localized: "Date Taken"), String(localized: "Date Source"), String(localized: "Camera")])
        XCTAssertEqual(report.capture[1].value, String(localized: "GPS time from GoPro telemetry"))
        XCTAssertNotEqual(report.capture[0].value, "old")
        report.adopt(facts)
        XCTAssertEqual(report.capture.count, 3, "adopting again adds no second note")
        let rows = InspectorView.locationRows(try XCTUnwrap(report.location), report: report)
        let byLabel = Dictionary(rows.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byLabel[String(localized: "Source")], String(localized: "GPS from GoPro telemetry"))
        XCTAssertEqual(byLabel[String(localized: "Accuracy")], PlaceAccuracy.dilution(1.8).text)
        XCTAssertNotNil(byLabel[String(localized: "Route")])
        XCTAssertEqual(Set(rows.map(\.label)).count, rows.count, "labels are the rows' ids")
        XCTAssertNil(MetadataSource.file.timeText, "the file's own date needs no note")
    }

    // MARK: Hostile input

    /// A fixed-seed generator, so a failure can be run again.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testDamagedMoviesNeverTrap() throws {
        var random = SplitMix(state: 2024)
        for name in ["gopro-gps5.mp4", "gopro-gps9.mp4", "android.mp4", "xmp-uuid.mp4"] {
            let original = [UInt8](try bytes(name))
            for round in 0..<1_500 {
                var damaged = original
                for _ in 0..<(1 + round % 16) {
                    damaged[Int.random(in: 0..<damaged.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
                }
                if round % 5 == 0 { damaged = Array(damaged.prefix(Int.random(in: 0..<damaged.count, using: &random))) }
                let source = MemoryBytes(damaged)
                guard let movie = MP4Boxes.read(source) else { continue }
                for range in movie.telemetry {
                    XCTAssertLessThanOrEqual(range.upperBound, source.size, "a sample inside the file")
                }
                _ = CaptureReader.telemetry(source, movie.telemetry, starts: movie.telemetryStarts)
                _ = movie.xmp.flatMap { XMPMetadata.read(Data($0)) }
            }
        }
    }

    func testCraftedBoxes() {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + payload.count)
            return withUnsafeBytes(of: size.bigEndian, Array.init) + type.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } + payload
        }
        let ftyp = box("ftyp", Array("mp41".utf8) + [0, 0, 0, 0])
        // A size beyond the file, a 64-bit size near UInt64.max, a size under the header, a size of zero (to the end)
        var huge: [UInt8] = [0, 0, 0, 1] + Array("moov".utf8)
        huge += withUnsafeBytes(of: UInt64.max.bigEndian, Array.init)
        for tail in [[0x7F, 0xFF, 0xFF, 0xFF] + Array("moov".utf8), huge, [0, 0, 0, 3] + Array("moov".utf8), [0, 0, 0, 0] + Array("moov".utf8)] as [[UInt8]] {
            let movie = MP4Boxes.read(MemoryBytes(ftyp + tail))
            XCTAssertNotNil(movie)
            XCTAssertNil(movie?.created)
        }
        XCTAssertNil(MP4Boxes.read(MemoryBytes(Array("GIF89a and more".utf8))), "not made of boxes")
        XCTAssertNil(MP4Boxes.read(MemoryBytes([])))
        // Boxes nested far deeper than any file has them
        var deep = box("free", [])
        for _ in 0..<2_000 { deep = box("udta", deep) }
        XCTAssertNotNil(MP4Boxes.read(MemoryBytes(ftyp + box("moov", deep))))
        // A sample table that claims more than it holds, a chunk far past the end, chunk runs going backwards
        func track(stsz: [UInt8], stco: [UInt8], stsc: [UInt8]) -> [UInt8] {
            let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + box("gpmd", [UInt8](repeating: 0, count: 8)))
            let table = box("stbl", stsd + box("stsz", stsz) + box("stco", stco) + box("stsc", stsc))
            let hdlr = box("hdlr", [0, 0, 0, 0] + Array("mhlrmeta".utf8) + [UInt8](repeating: 0, count: 12))
            return box("moov", box("trak", box("mdia", hdlr + box("minf", table))))
        }
        let full: [UInt8] = [0, 0, 0, 0]
        let cases: [[UInt8]] = [
            track(stsz: full + [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF], stco: full + [0, 0, 0, 1, 0, 0, 0, 0], stsc: full + [0, 0, 0, 0]),
            track(stsz: full + [0, 0, 0, 16, 0, 0, 0, 2], stco: full + [0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xF0], stsc: full + [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]),
            track(stsz: full + [0, 0, 0, 16, 0, 0, 0, 2], stco: full + [0, 0, 0, 1, 0, 0, 0, 0],
                  stsc: full + [0, 0, 0, 2] + [0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1] + [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]),
            track(stsz: full + [0, 0, 0, 16, 0, 0, 0, 2], stco: full + [0, 0, 0, 1, 0, 0, 0, 0],
                  stsc: full + [0, 0, 0, 1, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1]),
        ]
        for moov in cases {
            let source = MemoryBytes(ftyp + moov)
            let movie = MP4Boxes.read(source)
            XCTAssertNotNil(movie)
            for range in movie?.telemetry ?? [] { XCTAssertLessThanOrEqual(range.upperBound, source.size) }
        }
        // ©xyz with a length past its box
        let xyz = box("\u{A9}xyz", [0xFF, 0xFF, 0x15, 0xC7] + Array("+10.0+020.0/".utf8))
        let read = MP4Boxes.read(MemoryBytes(ftyp + box("moov", box("udta", xyz))))
        assertPlace(read?.location?.point, 10, 20)
        let empty = box("\u{A9}xyz", [0x00, 0x00, 0x15, 0xC7])
        XCTAssertNil(MP4Boxes.read(MemoryBytes(ftyp + box("moov", box("udta", empty))))?.location)
    }

    func testCraftedGPMF() {
        func klv(_ key: String, _ type: Character, _ size: UInt8, _ count: UInt16, _ data: [UInt8]) -> [UInt8] {
            var out = Array(key.utf8) + [type.asciiValue ?? 0, size] + withUnsafeBytes(of: count.bigEndian, Array.init) + data
            while out.count % 4 != 0 { out.append(0) }
            return out
        }
        func be(_ values: [Int32]) -> [UInt8] { values.flatMap { withUnsafeBytes(of: $0.bigEndian, Array.init) } }
        let sample = be([480_000_000, 110_000_000, 500_000, 0, 0])
        // A repeat count far beyond the data
        XCTAssertTrue(GPMF.fixes(in: klv("GPS5", "l", 20, 60_000, sample)).isEmpty)
        // A scale of zero, a scale of NaN
        XCTAssertTrue(GPMF.fixes(in: klv("SCAL", "l", 4, 1, be([0])) + klv("GPS5", "l", 20, 1, sample)).isEmpty)
        XCTAssertTrue(GPMF.fixes(in: klv("SCAL", "f", 4, 1, withUnsafeBytes(of: Float.nan.bitPattern.bigEndian, Array.init)) + klv("GPS5", "l", 20, 1, sample)).isEmpty)
        // A good one, then the same nested ten thousand levels deep (read to `deepest` only)
        let good = klv("SCAL", "l", 4, 1, be([10_000_000])) + klv("GPS5", "l", 20, 1, sample)
        XCTAssertEqual(GPMF.fixes(in: good).first?.point.latitude, 48)
        var nested = good
        for _ in 0..<2_000 {
            guard nested.count / 4 < Int(UInt16.max) else { break }
            nested = klv("DEVC", "\0", 4, UInt16(nested.count / 4), nested)
        }
        XCTAssertTrue(GPMF.fixes(in: nested).isEmpty)
        // A structure that doesn't add up to its size; a TYPE that repeats wildly
        XCTAssertTrue(GPMF.fixes(in: klv("TYPE", "c", 1, 4, Array("l[9]".utf8)) + klv("GPS9", "?", 32, 1, [UInt8](repeating: 1, count: 32))).isEmpty)
        XCTAssertTrue(GPMF.fixes(in: klv("TYPE", "c", 1, 12, Array("l[999999999]".utf8)) + klv("GPS9", "?", 32, 1, [UInt8](repeating: 1, count: 32))).isEmpty)
        // A day count that runs off the calendar
        let wild = klv("TYPE", "c", 1, 9, Array("lllllllSS".utf8))
            + klv("GPS9", "?", 32, 1, be([480_000_000, 110_000_000, 0, 0, 0, Int32.max, Int32.max]) + [0xFF, 0xFF, 0xFF, 0xFF])
        let scale = klv("SCAL", "l", 4, 9, be([10_000_000, 10_000_000, 1_000, 1_000, 100, 1, 1_000, 100, 1]))
        let fix = GPMF.fixes(in: scale + wild).first
        XCTAssertEqual(fix?.point.latitude, 48)
        XCTAssertNil(fix?.time)
        // Random bytes
        var random = SplitMix(state: 7)
        for _ in 0..<5_000 {
            let count = Int.random(in: 0..<512, using: &random)
            _ = GPMF.fixes(in: Array("DEVC".utf8) + [0, 4, 0, 64] + (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) })
        }
    }

    func testHostileTextFiles() throws {
        // Entities that would expand a small file into gigabytes: refused before parsing
        let laughs = """
            <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
            <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;"><!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">]>
            """
        XCTAssertNil(XMPMetadata.read(Data((laughs + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">&lol4;</x:xmpmeta>").utf8)))
        XCTAssertNil(GPXTrack.read(Data((laughs + "<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"1\"><time>&lol4;</time></trkpt></trkseg></trk></gpx>").utf8)))
        XCTAssertNil(SonyClipXML.read(Data((laughs + "<NonRealTimeMeta><CreationDate value=\"&lol4;\"/></NonRealTimeMeta>").utf8)))
        // An external entity (a file of the Mac) is never read
        let external = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/hosts\">]><gpx><trk><trkseg><trkpt lat=\"1\" lon=\"1\"><time>&e;</time></trkpt></trkseg></trk></gpx>"
        XCTAssertNil(GPXTrack.read(Data(external.utf8)))
        // Too large
        XCTAssertNil(XMPMetadata.read(Data(count: XMPMetadata.largest + 1)))
        XCTAssertNil(DJIFlightLog.read(Data(count: DJIFlightLog.largest + 1)))
        // Cut off, unbalanced, nonsense
        XCTAssertNil(GPXTrack.read(Data("<gpx><trk><trkseg><trkpt lat=\"91\" lon=\"1\"><time>2024-01-01T00:00:00Z</time></trkpt>".utf8)))
        XCTAssertNil(GPXTrack.read(Data("not xml at all".utf8)))
        XCTAssertNil(GPXTrack.read(Data("<kml><trkpt lat=\"1\" lon=\"1\"><time>2024-01-01T00:00:00Z</time></trkpt></kml>".utf8)), "only GPX")
        let cut = try bytes("lightroom.xmp").prefix(420)
        _ = XMPMetadata.read(Data(cut))
        var deep = ""
        for _ in 0..<10_000 { deep += "<a>" }
        XCTAssertNil(XMPMetadata.read(Data(deep.utf8)))
        XCTAssertNil(GPXTrack.read(Data(("<gpx>" + deep).utf8)))
        // Flight logs: endless digits, NaN and infinities, numbers past every range
        let digits = String(repeating: "9", count: 1_000_000)
        for text in ["1\n00:00:00,000 --> 00:00:01,000\nGPS(\(digits),\(digits),1)\n\n",
                     "1\n[latitude: nan] [longitude: inf]\n\n", "1\nGPS(1e308,1e308,1)\n\n",
                     "1\n[latitude: 45.0] [longitude: 10.0] [altitude: 1e308]\n\n", "\n\n\n\n", "\u{0}\u{1}\u{2}"] {
            let log = DJIFlightLog.read(Data(text.utf8))
            if let point = log?.first?.point { XCTAssertTrue(abs(point.latitude) <= 90 && abs(point.longitude) <= 180) }
            XCTAssertNil(log?.first?.altitude, "no altitude past any range")
        }
    }
}
