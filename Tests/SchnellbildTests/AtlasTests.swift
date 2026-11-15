import XCTest
import OfflineMap
@testable import Schnellbild

/// The Atlas view without a screen: clusters, moving among them, the
/// timeline and its time zones, the tour's stations, route and sequence,
/// and its keys (also set to others in Settings → Keyboard); the Norway
/// trip of `Tests/SchnellbildTests/Locations` (norway-*, drawn by
/// `Scripts/make_location_fixtures.swift`) read as the app reads it.
@MainActor
final class AtlasTests: XCTestCase {
    private let oslo = 7200

    /// A local time at UTC+02:00 ("2026-06-14 10:12").
    private func time(_ text: String, offset: Int = 7200) -> Date {
        ClockReading.parse(text)!.instant(in: TimeZone(secondsFromGMT: offset)!)
    }

    private func item(_ name: String, _ when: String, _ place: (Double, Double)?, offset: Int? = 7200,
                      video: Bool = false) -> AtlasItem {
        AtlasItem(url: URL(fileURLWithPath: "/trip/\(name)"), isVideo: video,
                  coordinate: place.map { Coordinate(latitude: $0.0, longitude: $0.1) },
                  date: time(when, offset: offset ?? 0), offset: offset, hasCaptureTime: true)
    }

    /// The trip as the fixtures have it.
    private var trip: [AtlasItem] {
        [
            item("norway-01-bryggen.jpg", "2026-06-14 10:12:05", (60.3975, 5.3245)),
            item("norway-02-bryggen.jpg", "2026-06-14 10:20:41", (60.3978, 5.3236)),
            item("norway-03-harbour.jpg", "2026-06-14 10:31:17", (60.3966, 5.3226)),
            item("norway-04-floyen.jpg", "2026-06-14 14:05:52", (60.3940, 5.3460)),
            item("norway-05-flam.jpg", "2026-06-15 09:40:10", (60.8628, 7.1137)),
            item("norway-06-flam.jpg", "2026-06-15 09:52:33", (60.8634, 7.1149)),
            item("norway-07-stegastein.jpg", "2026-06-15 13:15:02", (60.9097, 7.2112)),
            item("norway-08-geiranger.jpg", "2026-06-16 11:02:44", (62.1009, 7.2059)),
            item("norway-09-geiranger.jpg", "2026-06-16 11:10:09", (62.1015, 7.2071)),
            item("norway-10-geiranger.mov", "2026-06-16 11:20:30", (62.1012, 7.2066), video: true),
            item("norway-11-dalsnibba.jpg", "2026-06-16 16:30:55", (62.0469, 7.2717)),
            item("norway-12-alesund.jpg", "2026-06-17 19:45:21", (62.4747, 6.1595)),
            item("norway-13-evening.jpg", "2026-06-17 21:03:12", nil),
            item("norway-14-trollstigen.jpg", "2026-06-18 10:30:00", (62.4565, 7.6644)),
        ]
    }

    private func names(_ station: TourStation) -> [String] { station.items.map(\.name) }

    // MARK: Clusters

    func testClustersJoinWhenZoomedOutAndPartWhenZoomedIn() {
        let points = trip.compactMap { item in item.coordinate.map { (id: item.url, coordinate: $0) } }
        let world = AtlasClustering.clusters(of: points, zoom: 2)
        XCTAssertEqual(world.count, 1, "all of Norway in one tile at zoom 2")
        XCTAssertEqual(world[0].count, 13)
        XCTAssertEqual(world[0].ids.first?.lastPathComponent, "norway-01-bryggen.jpg", "the first in time leads")

        let country = AtlasClustering.clusters(of: points, zoom: 7)
        XCTAssertGreaterThan(country.count, 2)
        XCTAssertLessThan(country.count, 8)

        let town = AtlasClustering.clusters(of: points, zoom: 12)
        let bergen = town.first { $0.ids.contains { $0.lastPathComponent == "norway-01-bryggen.jpg" } }
        XCTAssertEqual(bergen?.count, 3, "Bryggen's three photos stay together at zoom 12 (a few hundred metres)")
        XCTAssertFalse(bergen!.ids.contains { $0.lastPathComponent == "norway-04-floyen.jpg" }, "Fløyen parts from Bryggen")
        XCTAssertEqual(town.reduce(0) { $0 + $1.count }, 13, "every item in exactly one cluster")
        XCTAssertEqual(Set(town.flatMap(\.ids)).count, 13)
    }

    func testAClusterStandsInTheMiddleOfItsItems() {
        let a = Coordinate(latitude: 60, longitude: 10), b = Coordinate(latitude: 60, longitude: 10.01)
        let clusters = AtlasClustering.clusters(of: [(URL(fileURLWithPath: "/a"), a), (URL(fileURLWithPath: "/b"), b)], zoom: 5)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].coordinate.longitude, 10.005, accuracy: 0.0001)
        XCTAssertEqual(clusters[0].coordinate.latitude, 60, accuracy: 0.001)
    }

    func testThousandsClusterQuickly() {
        var points: [(id: URL, coordinate: Coordinate)] = []
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for i in 0..<20_000 {
            points.append((URL(fileURLWithPath: "/p\(i)"), Coordinate(latitude: 40 + random() * 30, longitude: -10 + random() * 40)))
        }
        for zoom in [1.0, 5.0, 9.0, 12.0] {
            let start = Date()
            let clusters = AtlasClustering.clusters(of: points, zoom: zoom)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "20 000 items at zoom \(zoom)")
            XCTAssertEqual(clusters.reduce(0) { $0 + $1.count }, 20_000)
        }
    }

    // MARK: Moving among the tiles

    func testArrowsGoToTheNearestTileThatWay() {
        let points = [CGPoint(x: 200, y: 100), CGPoint(x: 120, y: 101), CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 90)]
        let origin = CGPoint(x: 100, y: 100)
        XCTAssertEqual(AtlasNavigation.next(from: origin, among: points, .right), 1, "the near one slightly off the line")
        XCTAssertEqual(AtlasNavigation.next(from: origin, among: points, .down), 2)
        XCTAssertNil(AtlasNavigation.next(from: origin, among: points, .left), "nothing to the left")
        XCTAssertEqual(AtlasNavigation.next(from: CGPoint(x: 500, y: 100), among: points, .left), 3)
        XCTAssertNil(AtlasNavigation.next(from: origin, among: [origin], .right), "not the tile itself")
    }

    // MARK: Timeline

    func testTheTimelineNarrowsWhatIsShown() {
        let items = trip
        let span = try! XCTUnwrap(AtlasTimeline.span(of: items))
        XCTAssertEqual(span.lowerBound, time("2026-06-14 10:12:05"))
        XCTAssertEqual(span.upperBound, time("2026-06-18 10:30:00"))
        XCTAssertEqual(AtlasTimeline.filter(items, to: nil).count, 14, "no range: everything")
        let geirangerDay = time("2026-06-16 00:00:00")...time("2026-06-16 23:59:59")
        XCTAssertEqual(AtlasTimeline.filter(items, to: geirangerDay).map(\.name),
                       ["norway-08-geiranger.jpg", "norway-09-geiranger.jpg", "norway-10-geiranger.mov", "norway-11-dalsnibba.jpg"])
        let histogram = AtlasTimeline.histogram(items, span: span, bins: 4)
        XCTAssertEqual(histogram.reduce(0, +), 14)
        XCTAssertEqual(histogram, [6, 1, 4, 3])
        XCTAssertEqual(AtlasTimeline.nearest(to: time("2026-06-15 12:00:00"), in: items)?.name, "norway-07-stegastein.jpg")
        XCTAssertEqual(AtlasTimeline.fraction(of: span.lowerBound, span: span), 0)
        XCTAssertEqual(AtlasTimeline.date(at: 1, span: span), span.upperBound)
        XCTAssertEqual(AtlasTimeline.bin(of: span.upperBound, span: span, bins: 10), 9, "the end falls into the last bin")
    }

    func testAModelNarrowedToADayShowsOnlyThatDay() async {
        let atlas = AtlasModel(browser: nil) { _ in [:] }
        atlas.load(trip)
        XCTAssertEqual(atlas.placed.count, 13)
        XCTAssertEqual(atlas.unplaced.map(\.name), ["norway-13-evening.jpg"])
        atlas.range = time("2026-06-17 00:00:00")...time("2026-06-17 23:59:59")
        XCTAssertEqual(atlas.placed.map(\.name), ["norway-12-alesund.jpg"])
        XCTAssertEqual(atlas.unplaced.map(\.name), ["norway-13-evening.jpg"], "the strip follows the range too")
        XCTAssertEqual(atlas.stations.count, 1, "the tour keeps to the range")
        atlas.range = nil
        XCTAssertEqual(atlas.shown.count, 14)
    }

    // MARK: Time zones

    func testTimesAreShownAsTheClockWhereTheyWereTaken() throws {
        let photo = item("a.jpg", "2026-06-14 23:30:00", (60.39, 5.32))
        // The Mac may be anywhere: Oslo's clock shows 23:30
        let zone = AtlasTimeline.zone(at: photo.date, in: [photo])
        XCTAssertEqual(zone.secondsFromGMT(for: photo.date), oslo)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        XCTAssertEqual(calendar.component(.hour, from: photo.date), 23)
        XCTAssertEqual(AtlasItems.day(of: photo), DateComponents(year: 2026, month: 6, day: 14))
        // 21:30 UTC is already the 15th in Tokyo, still the 14th in Oslo
        var tokyo = photo
        tokyo.offset = 9 * 3600
        XCTAssertEqual(AtlasItems.day(of: tokyo), DateComponents(year: 2026, month: 6, day: 15))
    }

    func testDaysFollowEachItemsOwnClockNotTheMacs() {
        // 23:30 and 00:30 at Oslo's clock: two days, though both are the 14th in UTC
        let late = item("late.jpg", "2026-06-14 23:30:00", (60.3975, 5.3245))
        let early = item("early.jpg", "2026-06-15 00:30:00", (60.3976, 5.3246))
        let stations = TourPlanner.stations(from: [early, late])
        XCTAssertEqual(stations.map { names($0) }, [["late.jpg"], ["early.jpg"]], "after midnight there: a new day, a new station")
    }

    func testAVideosUTCTimeTakesTheOffsetOfThePhotosAroundIt() {
        let photo = item("photo.jpg", "2026-06-16 11:02:44", (62.1009, 7.2059))
        let facts = CaptureFacts(time: CaptureTime(utc: time("2026-06-16 09:20:30", offset: 0), source: .movieHeader), place: nil, track: nil)
        let video = AtlasItem.make(url: URL(fileURLWithPath: "/trip/video.mp4"), isVideo: true, facts: facts, modified: nil)
        XCTAssertNil(video.offset)
        XCTAssertTrue(video.timeIsUTC)
        let prepared = AtlasItems.prepared([video, photo])
        XCTAssertEqual(prepared.map(\.name), ["photo.jpg", "video.mp4"], "in the order of time")
        XCTAssertEqual(prepared[1].offset, oslo, "shown at 11:20 like the photos, not at the UTC time")
        // A camera clock without a zone stays in the Mac's zone (as it reads)
        let clock = ClockReading.parse("2026-06-16 11:30:00")!
        let camera = AtlasItem.make(url: URL(fileURLWithPath: "/trip/camera.jpg"), isVideo: false,
                                    facts: CaptureFacts(time: CaptureTime(clock, source: .file), place: nil, track: nil), modified: nil)
        XCTAssertNil(AtlasItems.prepared([camera, photo]).first { $0.name == "camera.jpg" }?.offset)
        // Without a capture time: the modification date
        let none = AtlasItem.make(url: URL(fileURLWithPath: "/trip/none.jpg"), isVideo: false, facts: CaptureFacts(), modified: photo.date)
        XCTAssertFalse(none.hasCaptureTime)
        XCTAssertEqual(none.date, photo.date)
        XCTAssertNil(none.coordinate)
    }

    // MARK: Stations and route

    func testStationsArePlacesWithinAKilometreOnOneDay() {
        let stations = TourPlanner.stations(from: trip.shuffled())
        XCTAssertEqual(stations.map { names($0) }, [
            ["norway-01-bryggen.jpg", "norway-02-bryggen.jpg", "norway-03-harbour.jpg"],
            ["norway-04-floyen.jpg"],
            ["norway-05-flam.jpg", "norway-06-flam.jpg"],
            ["norway-07-stegastein.jpg"],
            ["norway-08-geiranger.jpg", "norway-09-geiranger.jpg", "norway-10-geiranger.mov"],
            ["norway-11-dalsnibba.jpg"],
            ["norway-12-alesund.jpg"],
            ["norway-14-trollstigen.jpg"],
        ], "chronological; the photo without a place isn't a station")
        XCTAssertEqual(stations[0].coordinate.latitude, (60.3975 + 60.3978 + 60.3966) / 3, accuracy: 1e-9)
        // The same place on the next day is a new station
        let again = item("again.jpg", "2026-06-15 08:00:00", (60.3975, 5.3245))
        let next = TourPlanner.stations(from: [trip[0], again])
        XCTAssertEqual(next.count, 2)
        // Back to a place later the same day, after another one: a station of its own
        let back = item("back.jpg", "2026-06-14 18:00:00", (60.3975, 5.3245))
        XCTAssertEqual(TourPlanner.stations(from: [trip[0], trip[3], back]).count, 3)
    }

    func testTheRouteFollowsAVideosTrack() {
        var stations = TourPlanner.stations(from: Array(trip[7...10]))
        XCTAssertEqual(stations.count, 2)
        var video = stations[0].items[2]
        video.track = [Coordinate(latitude: 62.10, longitude: 7.20), Coordinate(latitude: 62.08, longitude: 7.23),
                       Coordinate(latitude: 62.06, longitude: 7.25)]
        stations[0].items[2] = video
        let route = TourPlanner.route(through: stations)
        XCTAssertEqual(route.arrivals, [0, 4], "the second station after the first's place and the track's three points")
        XCTAssertEqual(route.points.count, 5)
        XCTAssertEqual(route.points[1], video.track[0])
        XCTAssertEqual(route.points[4], stations[1].coordinate)
    }

    func testTheCameraDipsOutBetweenFarPlaces() {
        let size = CGSize(width: 960, height: 600)
        let bergen = MapCamera(center: Coordinate(latitude: 60.39, longitude: 5.32), zoom: 11)
        let trollstigen = MapCamera(center: Coordinate(latitude: 62.45, longitude: 7.66), zoom: 11)
        XCTAssertEqual(TourFlight.camera(from: bergen, to: trollstigen, at: 0, size: size), bergen)
        let end = TourFlight.camera(from: bergen, to: trollstigen, at: 1, size: size)
        XCTAssertEqual(end.center.latitude, 62.45, accuracy: 1e-6)
        XCTAssertEqual(end.zoom, 11, accuracy: 1e-9)
        let middle = TourFlight.camera(from: bergen, to: trollstigen, at: 0.5, size: size)
        XCTAssertLessThan(middle.zoom, 8, "out far enough to see both")
        let near = MapCamera(center: Coordinate(latitude: 60.391, longitude: 5.321), zoom: 11)
        XCTAssertEqual(TourFlight.camera(from: bergen, to: near, at: 0.5, size: size).zoom, 11, accuracy: 0.01, "no dip for a short way")
    }

    // MARK: The tour's sequence

    func testTheTourShowsEachStationsItemsInTurn() {
        var player = TourPlayer(stations: TourPlanner.stations(from: trip))
        XCTAssertEqual(player.phase, .flying)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.duration(reducedMotion: false), TourPlayer.flightSeconds)
        XCTAssertLessThan(player.duration(reducedMotion: true), TourPlayer.flightSeconds, "a cut, not a flight")
        player.advance()
        XCTAssertEqual(player.currentItem?.name, "norway-01-bryggen.jpg")
        XCTAssertEqual(player.duration(reducedMotion: false), TourPlayer.photoSeconds)
        player.advance()
        player.advance()
        XCTAssertEqual(player.currentItem?.name, "norway-03-harbour.jpg")
        player.advance()
        XCTAssertEqual(player.station, 1)
        XCTAssertEqual(player.phase, .flying, "on to the next station")
        // ← → jump between stations, from wherever
        player.next(); player.next(); player.next()
        XCTAssertEqual(player.station, 4)
        player.advance(); player.advance(); player.advance()
        XCTAssertEqual(player.currentItem?.name, "norway-10-geiranger.mov")
        XCTAssertEqual(player.duration(reducedMotion: false), TourPlayer.videoSeconds, "a video plays a short part")
        player.previous()
        XCTAssertEqual(player.station, 3)
        XCTAssertEqual(player.phase, .flying)
        for _ in 0..<10 { player.previous() }
        XCTAssertEqual(player.station, 0, "the first stays the first")
        for _ in 0..<7 { player.next() }
        XCTAssertEqual(player.station, 7)
        XCTAssertFalse(player.finished)
        player.next()
        XCTAssertTrue(player.finished, "past the last station")
        XCTAssertTrue(TourPlayer(stations: []).finished, "nothing to show")
    }

    // MARK: Keys

    private func window() throws -> (WindowModel, BrowserModel, Shortcuts, TempTree) {
        let tree = try TempTree(self)
        for item in trip { try tree.file(item.name) }
        let defaults = makeTestDefaults()
        let left = BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions)
        left.searchDebounce = .zero
        left.setFullScreen = { _ in false }
        let facts = Dictionary(uniqueKeysWithValues: trip.map { ($0.name, $0) })
        left.atlasFacts = { files in
            var result: [URL: CaptureFacts] = [:]
            for file in files {
                guard let item = facts[file.url.lastPathComponent] else { continue }
                let place = item.coordinate.flatMap { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
                result[file.url] = CaptureFacts(
                    time: CaptureTime(ClockReading(floating: item.date.addingTimeInterval(7200), offset: 7200), source: .file),
                    place: place.map { CapturePlace(location: MediaLocation(point: $0), source: .file) }, track: nil)
            }
            return result
        }
        let window = WindowModel(left: left, defaults: defaults) {
            BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions, settingsPrefix: "rightPane.")
        }
        let shortcuts = Shortcuts(defaults: makeTestDefaults())
        window.shortcuts = shortcuts
        return (window, left, shortcuts, tree)
    }

    func testWShowsTheAtlasAndTTheTourWithTheKeysAsSet() async throws {
        let (w, m, s, tree) = try window()
        await openAndWait(m, tree.root)
        m.viewMode = .list
        XCTAssertTrue(w.typeKey(.char("w")))
        XCTAssertEqual(m.viewMode, .atlas)
        await waitUntil { m.atlas.items.count == 14 && m.atlas.isComplete }
        m.atlas.mapSize = CGSize(width: 960, height: 600)
        m.atlas.fitAll()
        m.atlas.clusterNow()
        XCTAssertTrue(w.typeKey(.char("w")))
        XCTAssertEqual(m.viewMode, .list, "W again: back to where it came from")
        XCTAssertTrue(w.typeKey(.char("w")))
        XCTAssertEqual(w.shortcutContext, .grid)

        // Selection is the pane's: the arrows choose a tile, Space opens it
        XCTAssertTrue(w.typeKey(.right))
        let chosen = try XCTUnwrap(m.selectedEntry)
        XCTAssertTrue(chosen.isMedia, "a tile near the middle")
        XCTAssertTrue(m.atlas.visibleClusters().contains { $0.cluster.ids.contains(chosen.url) })
        XCTAssertTrue(w.typeKey(.char("+")))
        XCTAssertTrue(w.typeKey(.space))
        XCTAssertEqual(m.mode, .detail)
        XCTAssertEqual(m.selectedEntry?.url, chosen.url)
        XCTAssertTrue(w.typeKey(.escape))
        XCTAssertEqual(m.mode, .grid)
        XCTAssertEqual(m.viewMode, .atlas)

        // The tour: T, Space pauses, ← → stations, Esc ends
        XCTAssertTrue(w.typeKey(.char("t")))
        XCTAssertTrue(m.touring)
        XCTAssertTrue(m.presenting)
        XCTAssertEqual(w.shortcutContext, .tour)
        XCTAssertEqual(m.atlas.tour?.stations.count, 8)
        XCTAssertTrue(w.typeKey(.space))
        XCTAssertEqual(m.atlas.tour?.paused, true)
        XCTAssertTrue(w.typeKey(.right))
        XCTAssertEqual(m.atlas.tour?.station, 1)
        XCTAssertTrue(w.typeKey(.left))
        XCTAssertEqual(m.atlas.tour?.station, 0)

        // Next place on N: → does nothing then, N goes on
        s.assign(KeyChord(stored: "n")!, to: .tourNext, replacing: KeyChord(.right))
        XCTAssertFalse(w.typeKey(.right), "→ is the tour's no more")
        XCTAssertEqual(m.atlas.tour?.station, 0)
        XCTAssertTrue(w.typeKey(.char("n")))
        XCTAssertEqual(m.atlas.tour?.station, 1)
        XCTAssertTrue(w.typeKey(.space))
        XCTAssertEqual(m.atlas.tour?.paused, false)
        XCTAssertTrue(w.typeKey(.escape))
        XCTAssertFalse(m.touring)
        XCTAssertEqual(w.shortcutContext, .grid)

        // W and T on other keys
        s.assign(KeyChord(stored: "g")!, to: .toggleAtlas, replacing: KeyChord(.char("w")))
        s.assign(KeyChord(stored: "@$t")!, to: .startTour, replacing: KeyChord(.char("t")))
        XCTAssertFalse(w.typeKey(.char("w")))
        XCTAssertEqual(m.viewMode, .atlas)
        XCTAssertTrue(w.typeKey(.char("g")))
        XCTAssertEqual(m.viewMode, .list)
        XCTAssertFalse(w.typeKey(.char("t")))
        XCTAssertFalse(m.touring)
        XCTAssertTrue(w.typeKey(.char("t"), command: true, shift: true))
        XCTAssertTrue(m.touring, "the tour starts from the list too, in the Atlas")
        XCTAssertEqual(m.viewMode, .atlas)
        XCTAssertTrue(w.typeKey(.escape))
        XCTAssertFalse(m.touring)
    }

    func testTheTourRunsThroughToItsEnd() async throws {
        let (w, m, _, tree) = try window()
        await openAndWait(m, tree.root)
        m.viewMode = .atlas
        await waitUntil { m.atlas.items.count == 14 && m.atlas.isComplete }
        m.atlas.mapSize = CGSize(width: 960, height: 600)
        // Only the last day: one station, one photo
        m.atlas.range = time("2026-06-18 00:00:00")...time("2026-06-18 23:59:59")
        XCTAssertTrue(w.typeKey(.char("t")))
        XCTAssertEqual(m.atlas.tour?.stations.count, 1)
        await waitUntil({ m.atlas.tour?.phase == .showing }, timeout: 6)
        XCTAssertEqual(m.atlas.tour?.currentItem?.name, "norway-14-trollstigen.jpg")
        let target = m.atlas.camera(for: m.atlas.tour!.stations[0])
        XCTAssertEqual(m.atlas.camera.center.latitude, target.center.latitude, accuracy: 0.01, "the camera arrived")
        await waitUntil({ !m.touring }, timeout: 8)
        XCTAssertEqual(m.selectedEntry?.name, "norway-14-trollstigen.jpg", "the item shown last is selected")
    }

    func testTInTheGridStartsTheTourOnceThePlacesAreRead() async throws {
        let (w, m, _, tree) = try window()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.viewMode, .grid)
        XCTAssertTrue(w.typeKey(.char("t")))
        XCTAssertEqual(m.viewMode, .atlas, "the Atlas first")
        await waitUntil { m.touring }
        XCTAssertEqual(m.atlas.tour?.stations.count, 8)
        XCTAssertTrue(w.typeKey(.escape))
        XCTAssertFalse(m.touring)
    }

    func testTheArrowsReachTheStripAndBack() async throws {
        let (w, m, _, tree) = try window()
        await openAndWait(m, tree.root)
        m.viewMode = .atlas
        await waitUntil { m.atlas.items.count == 14 && m.atlas.isComplete }
        m.atlas.mapSize = CGSize(width: 960, height: 600)
        m.atlas.fitAll()
        m.atlas.clusterNow()
        XCTAssertTrue(w.typeKey(.down))
        for _ in 0..<12 { w.typeKey(.down) }
        XCTAssertEqual(m.selectedEntry?.name, "norway-13-evening.jpg", "down past the lowest tile: the strip")
        XCTAssertTrue(w.typeKey(.up))
        XCTAssertNotEqual(m.selectedEntry?.name, "norway-13-evening.jpg", "up: back onto the map")
        XCTAssertTrue(w.typeKey(.end))
        XCTAssertEqual(m.selectedEntry?.name, "norway-14-trollstigen.jpg", "End: the last in time")
        XCTAssertTrue(w.typeKey(.home))
        XCTAssertEqual(m.selectedEntry?.name, "norway-01-bryggen.jpg")
    }

    // MARK: The fixtures as the app reads them

    func testTheNorwayFixturesReadAsATrip() async throws {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "Locations", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("norway-") }
        XCTAssertEqual(files.count, 14)
        let facts = await AtlasModel.liveFacts(files.map { ($0, nil) })
        let items = files.map { AtlasItem.make(url: $0, isVideo: $0.pathExtension == "mov", facts: facts[$0], modified: nil) }
        XCTAssertTrue(items.allSatisfy(\.hasCaptureTime))
        XCTAssertEqual(items.filter { $0.coordinate == nil }.map(\.name), ["norway-13-evening.jpg"])
        let video = try XCTUnwrap(items.first { $0.isVideo })
        XCTAssertEqual(video.date, time("2026-06-16 11:20:30"))
        XCTAssertEqual(video.offset, oslo)
        XCTAssertEqual(try XCTUnwrap(video.coordinate).latitude, 62.1012, accuracy: 1e-4)
        let stations = TourPlanner.stations(from: items)
        XCTAssertEqual(stations.count, 8)
        XCTAssertEqual(stations[4].items.map(\.name), ["norway-08-geiranger.jpg", "norway-09-geiranger.jpg", "norway-10-geiranger.mov"])
        XCTAssertEqual(AtlasItems.prepared(items).first?.zone.secondsFromGMT(), oslo)
    }
}
