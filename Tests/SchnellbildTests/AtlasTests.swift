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

    func testOnTheGlobeTheFarSideIsInNoCluster() {
        let atlas = AtlasModel(browser: nil) { _ in [:] }
        var items = trip
        items.append(item("wellington.jpg", "2026-06-19 10:00:00", (-41.29, 174.78)))
        atlas.load(items)
        atlas.mapSize = CGSize(width: 960, height: 600)
        atlas.camera = MapCamera(center: Coordinate(latitude: 60, longitude: 8), zoom: 2)
        XCTAssertTrue(atlas.showsGlobe, "zoomed far out: the globe")
        atlas.clusterNow()
        let ids = atlas.clusters.flatMap(\.ids).map(\.lastPathComponent)
        XCTAssertEqual(ids.count, 13, "Norway's places")
        XCTAssertFalse(ids.contains("wellington.jpg"), "New Zealand lies on the far side")
        XCTAssertTrue(atlas.visibleClusters().allSatisfy { atlas.point(for: $0.cluster.coordinate) != nil })
        // Turned to the other side
        atlas.camera = MapCamera(center: Coordinate(latitude: -40, longitude: 175), zoom: 2)
        atlas.clusterNow()
        XCTAssertEqual(atlas.clusters.flatMap(\.ids).map(\.lastPathComponent), ["wellington.jpg"])
        // Flat from the flat zoom on: everything clustered in world points again
        atlas.camera = MapCamera(center: Coordinate(latitude: 60, longitude: 8), zoom: 6)
        XCTAssertFalse(atlas.showsGlobe)
        atlas.clusterNow()
        XCTAssertEqual(atlas.clusters.reduce(0) { $0 + $1.count }, 14)
        // The globe's limits: further out than the flat map allows
        XCTAssertLessThan(atlas.held(MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 0)).zoom,
                          MapViewport.minZoom(for: atlas.mapSize))
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
        let start = TourFlight.camera(from: bergen, to: trollstigen, at: 0, size: size)
        XCTAssertEqual(start.center.latitude, 60.39, accuracy: 1e-9)
        XCTAssertEqual(start.center.longitude, 5.32, accuracy: 1e-9)
        XCTAssertEqual(start.zoom, 11, accuracy: 1e-9)
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

    private func window(folders: [String: String] = [:], spy given: FileActionsSpy? = nil,
                        defaults: UserDefaults = makeTestDefaults()) throws -> (WindowModel, BrowserModel, Shortcuts, TempTree) {
        let tree = try TempTree(self)
        for item in trip { try tree.file((folders[item.name].map { $0 + "/" } ?? "") + item.name) }
        let spy = given ?? FileActionsSpy()
        let left = BrowserModel(defaults: defaults, fileActions: spy.actions)
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

    // MARK: Subfolders

    /// The trip in folders by day, the first day's photos in the folder
    /// itself, and a hidden folder (left out, as by the slideshow).
    private let byDay: [String: String] = [
        "norway-05-flam.jpg": "Day 2", "norway-06-flam.jpg": "Day 2", "norway-07-stegastein.jpg": "Day 2",
        "norway-08-geiranger.jpg": "Day 3", "norway-09-geiranger.jpg": "Day 3", "norway-10-geiranger.mov": "Day 3",
        "norway-11-dalsnibba.jpg": "Day 3", "norway-12-alesund.jpg": "Day 4/Evening", "norway-13-evening.jpg": "Day 4/Evening",
        "norway-14-trollstigen.jpg": "Day 5",
    ]

    private func atlasOfTheTree(spy: FileActionsSpy? = nil, defaults: UserDefaults = makeTestDefaults())
        async throws -> (WindowModel, BrowserModel, TempTree) {
        let (w, m, _, tree) = try window(folders: byDay, spy: spy, defaults: defaults)
        try tree.file(".hidden/norway-99-hidden.jpg")
        await openAndWait(m, tree.root)
        m.viewMode = .atlas
        await waitUntil({ !m.deepWalking && m.entries.count == 14 && m.atlas.items.count == 14 && m.atlas.isComplete }, timeout: 10)
        m.atlas.mapSize = CGSize(width: 960, height: 600)
        m.atlas.fitAll()
        m.atlas.clusterNow()
        return (w, m, tree)
    }

    private func names(_ entries: [GridEntry]) -> [String] { entries.map(\.name) }

    func testTheAtlasShowsTheSubfoldersUnlessTurnedOff() async throws {
        let defaults = makeTestDefaults()
        let (_, m, _) = try await atlasOfTheTree(defaults: defaults)
        XCTAssertTrue(m.atlasSubfolders, "on unless turned off")
        XCTAssertTrue(m.showsDeep)
        XCTAssertEqual(names(m.entries), trip.map(\.name), "every day's photos and the video, in the pane's order; no folders")
        XCTAssertFalse(m.entries.contains { $0.name == "norway-99-hidden.jpg" }, "hidden folders are left out")
        XCTAssertEqual(m.atlas.stations.count, 8)
        // Another pane of the same preferences follows the switch, and it is kept
        let other = BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions)
        m.atlasSubfolders = false
        XCTAssertFalse(other.atlasSubfolders)
        XCTAssertFalse(BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions).atlasSubfolders, "remembered")
        XCTAssertFalse(m.showsDeep)
        XCTAssertEqual(Set(names(m.entries.filter(\.isMedia))), ["norway-01-bryggen.jpg", "norway-02-bryggen.jpg",
                                                                  "norway-03-harbour.jpg", "norway-04-floyen.jpg"])
        XCTAssertTrue(m.entries.contains { $0.name == "Day 3" }, "the folder's own listing again")
        await waitUntil { m.atlas.items.count == 4 }
        m.atlasSubfolders = true
        await waitUntil({ !m.deepWalking && m.entries.count == 14 }, timeout: 10)
        XCTAssertTrue(BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions).atlasSubfolders)
    }

    func testTheSelectionCrossesBetweenTheAtlasAndTheGrid() async throws {
        let (w, m, _) = try await atlasOfTheTree()
        // Selected in the Atlas, in a subfolder: back in the grid its folder is selected
        let geiranger = try XCTUnwrap(m.entries.first { $0.name == "norway-09-geiranger.jpg" })
        m.atlas.select(geiranger.url)
        XCTAssertEqual(m.selectedEntry?.name, "norway-09-geiranger.jpg")
        XCTAssertTrue(w.typeKey(.char("w")))
        XCTAssertEqual(m.viewMode, .grid)
        XCTAssertEqual(m.selectedEntry?.name, "Day 3", "the folder the item lies in")
        XCTAssertFalse(m.showsDeep)
        // A folder selected in the grid: the Atlas selects its first item once it comes
        XCTAssertTrue(w.typeKey(.char("w")))
        await waitUntil({ !m.deepWalking && m.entries.count == 14 }, timeout: 10)
        XCTAssertEqual(m.selectedEntry?.name, "norway-08-geiranger.jpg")
        // The full view pages through every folder's items, in the pane's order
        XCTAssertTrue(w.typeKey(.space))
        XCTAssertEqual(m.mode, .detail)
        for expected in ["norway-09-geiranger.jpg", "norway-10-geiranger.mov", "norway-11-dalsnibba.jpg", "norway-12-alesund.jpg"] {
            XCTAssertTrue(w.typeKey(.right, command: true))
            XCTAssertEqual(m.shownMediaEntry?.name, expected)
        }
        XCTAssertTrue(w.typeKey(.escape))
        XCTAssertEqual(m.mode, .grid)
        XCTAssertEqual(m.viewMode, .atlas)
        XCTAssertEqual(m.selectedEntry?.name, "norway-12-alesund.jpg", "the item shown last stays selected")
        // Two levels down: the folder of the listing that holds it
        XCTAssertTrue(w.typeKey(.char("w")))
        XCTAssertEqual(m.selectedEntry?.name, "Day 4")
        // A photo of the folder itself stays selected either way
        m.selectEntry(named: "norway-02-bryggen.jpg")
        XCTAssertTrue(w.typeKey(.char("w")))
        await waitUntil({ !m.deepWalking }, timeout: 10)
        XCTAssertEqual(m.selectedEntry?.name, "norway-02-bryggen.jpg")
        XCTAssertTrue(w.typeKey(.char("w")))
        XCTAssertEqual(m.selectedEntry?.name, "norway-02-bryggen.jpg")
    }

    func testSwitchingWhileTheWalkRunsKeepsTheSelectionInRange() async throws {
        let (w, m, _) = try await atlasOfTheTree()
        for round in 0..<20 {
            w.typeKey(.char("w"))
            if round % 3 == 0 { m.atlasSubfolders.toggle() }
            if let selection = m.selection { XCTAssertTrue(m.entries.indices.contains(selection), "round \(round)") }
            w.typeKey(.right)
            if let selection = m.selection { XCTAssertTrue(m.entries.indices.contains(selection), "round \(round)") }
            await Task.yield()
        }
        m.viewMode = .atlas
        m.atlasSubfolders = true
        await waitUntil({ !m.deepWalking && m.entries.count == 14 }, timeout: 10)
        if let selection = m.selection { XCTAssertTrue(m.entries.indices.contains(selection)) }
    }

    func testAnItemTrashedFromASubfolderLeavesTheAtlas() async throws {
        let spy = FileActionsSpy()
        let (_, m, _) = try await atlasOfTheTree(spy: spy)
        m.selectEntry(named: "norway-06-flam.jpg")
        m.moveSelectionToTrash()
        await waitUntil { m.entries.count == 13 }
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["norway-06-flam.jpg"])
        XCTAssertFalse(m.entries.contains { $0.name == "norway-06-flam.jpg" })
        await waitUntil { m.atlas.items.count == 13 }
        if let selection = m.selection { XCTAssertTrue(m.entries.indices.contains(selection)) }
    }

    func testASearchInTheAtlasTakesOverAndGivesBack() async throws {
        let (_, m, _) = try await atlasOfTheTree()
        m.searchText = "geiranger"
        await waitUntil { !m.isSearching && m.entries.count == 3 }
        XCTAssertFalse(m.showsDeep, "a search's results come from every subfolder anyway")
        m.searchText = ""
        await waitUntil({ !m.deepWalking && m.entries.count == 14 }, timeout: 10)
        XCTAssertTrue(m.showsDeep)
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

    // MARK: Edge cases

    /// Taveuni lies on both sides of 180°: on the globe its photos are one
    /// tile, and the tile stands there, not at longitude 0.
    func testAClusterAcrossTheAntimeridianStandsOnIt() {
        let points = [(URL(fileURLWithPath: "/fiji/east.jpg"), Coordinate(latitude: -16.80, longitude: 179.95)),
                      (URL(fileURLWithPath: "/fiji/west.jpg"), Coordinate(latitude: -16.85, longitude: -179.95))]
        let projection = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: -17, longitude: 180), zoom: 2),
                                         size: CGSize(width: 960, height: 600))
        let clusters = AtlasClustering.clusters(of: points) { projection.isVisible($0) ? projection.point(for: $0) : nil }
        XCTAssertEqual(clusters.count, 1, "side by side on the globe")
        XCTAssertGreaterThan(abs(clusters[0].coordinate.longitude), 179.9, "in the Pacific: \(clusters[0].coordinate)")
        XCTAssertEqual(clusters[0].coordinate.latitude, -16.825, accuracy: 0.01)
        XCTAssertTrue(projection.isVisible(clusters[0].coordinate), "on the side shown")
        XCTAssertFalse(clusters[0].staysTogether, "they part when zoomed in")
    }

    /// Photos taken at the very same place stay one tile at the largest
    /// zoom: a click (and → ←) goes through them, a double click opens the
    /// one shown, and the tile says so.
    func testItemsAtOnePlaceTakeTurns() async throws {
        let (w, m, _, tree) = try window()
        let bryggen = Coordinate(latitude: 60.3975, longitude: 5.3245)
        let same: Set<String> = ["norway-01-bryggen.jpg", "norway-02-bryggen.jpg", "norway-03-harbour.jpg"]
        let facts = Dictionary(uniqueKeysWithValues: trip.map { ($0.name, $0) })
        m.atlasFacts = { files in
            var result: [URL: CaptureFacts] = [:]
            for file in files {
                guard let item = facts[file.url.lastPathComponent] else { continue }
                let c = same.contains(item.name) ? bryggen : item.coordinate
                let place = c.flatMap { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
                result[file.url] = CaptureFacts(
                    time: CaptureTime(ClockReading(floating: item.date.addingTimeInterval(7200), offset: 7200), source: .file),
                    place: place.map { CapturePlace(location: MediaLocation(point: $0), source: .file) }, track: nil)
            }
            return result
        }
        await openAndWait(m, tree.root)
        m.viewMode = .atlas
        await waitUntil { m.atlas.items.count == 14 && m.atlas.isComplete }
        m.atlas.mapSize = CGSize(width: 960, height: 600)
        m.atlas.moveByUser(to: MapCamera(center: bryggen, zoom: MapViewport.maxZoom))
        m.atlas.clusterNow()
        let cluster = try XCTUnwrap(m.atlas.clusters.first { $0.ids.first?.lastPathComponent == "norway-01-bryggen.jpg" })
        XCTAssertEqual(Set(cluster.ids.map(\.lastPathComponent)), same)
        XCTAssertTrue(cluster.staysTogether, "zooming in can't part them")
        XCTAssertFalse(m.atlas.clusters.contains { $0.count == 1 && $0.staysTogether })
        // (the pane selects its first item when it opens: something else first)
        m.selectEntry(named: "norway-14-trollstigen.jpg")
        m.atlas.click(cluster)
        XCTAssertEqual(m.selectedEntry?.url, cluster.ids[0])
        m.atlas.click(cluster)
        XCTAssertEqual(m.selectedEntry?.url, cluster.ids[1], "the next one")
        m.atlas.click(cluster)
        m.atlas.click(cluster)
        XCTAssertEqual(m.selectedEntry?.url, cluster.ids[0], "round again")
        XCTAssertTrue(w.typeKey(.right))
        XCTAssertEqual(m.selectedEntry?.url, cluster.ids[1], "→ goes through them too")
        XCTAssertTrue(w.typeKey(.left))
        XCTAssertEqual(m.selectedEntry?.url, cluster.ids[0])
        // Clusters that part when zoomed in say so as before
        let apart = AtlasClustering.clusters(of: trip.compactMap { item in item.coordinate.map { (id: item.url, coordinate: $0) } }, zoom: 2)
        XCTAssertFalse(apart[0].staysTogether)
    }

    /// A station in the north shown on the globe: it stands at
    /// `TourFlight.placeShare` of the width as the globe draws it, beside the
    /// card (the flat map's arithmetic puts it a tenth further right there).
    func testATourStationOnTheGlobeStandsWhereTheCardLeavesRoom() throws {
        let atlas = AtlasModel(browser: nil) { _ in [:] }
        let size = CGSize(width: 960, height: 600)
        atlas.mapSize = size
        let station = TourPlanner.stations(from: [item("a.jpg", "2026-06-16 10:00:00", (70, 18)),
                                                  item("b.jpg", "2026-06-16 11:00:00", (70.003, 18.003))])[0]
        var wide = station
        wide.items = [item("c.jpg", "2026-06-16 10:00:00", (61, 5)), item("d.jpg", "2026-06-16 11:00:00", (63, 31))]
        wide.coordinate = Coordinate(latitude: 62, longitude: 18)
        for shown in [station, wide] {
            let camera = atlas.camera(for: shown)
            let projection = GlobeProjection(camera: camera, size: size)
            let p = projection.point(for: shown.coordinate)
            XCTAssertEqual(p.x, size.width * TourFlight.placeShare, accuracy: 1.5, "zoom \(camera.zoom), flat \(projection.isFlat)")
            XCTAssertEqual(p.y, size.height / 2, accuracy: 1.5)
        }
        // The wide one is on the globe, where the flat map's arithmetic misses
        let camera = atlas.camera(for: wide)
        XCTAssertFalse(GlobeProjection(camera: camera, size: size).isFlat)
        let centred = MapViewport(camera: MapCamera(center: wide.coordinate, zoom: camera.zoom), size: size)
        let flat = MapCamera(center: centred.coordinate(at: CGPoint(x: size.width * (1 - TourFlight.placeShare), y: size.height / 2)),
                             zoom: camera.zoom)
        let missed = GlobeProjection(camera: flat, size: size).point(for: wide.coordinate).x
        XCTAssertGreaterThan(missed - size.width * TourFlight.placeShare, 30, "the flat map's place on the globe: \(missed)")
    }

    /// An item without any time (no capture time, no file date) comes first
    /// in the order of time but stays out of the timeline's span.
    func testItemsWithoutATimeStayOutOfTheTimeline() throws {
        let undated = AtlasItem.make(url: URL(fileURLWithPath: "/trip/undated.jpg"), isVideo: false, facts: CaptureFacts(), modified: nil)
        XCTAssertFalse(undated.isDated)
        let atlas = AtlasModel(browser: nil) { _ in [:] }
        atlas.load(trip + [undated])
        XCTAssertEqual(atlas.items.first?.name, "undated.jpg")
        let span = try XCTUnwrap(atlas.span)
        XCTAssertEqual(span.lowerBound, time("2026-06-14 10:12:05"), "not the year 1")
        XCTAssertEqual(AtlasTimeline.span(of: trip + [undated]), span)
        XCTAssertEqual(AtlasTimeline.histogram(sorted: atlas.items, span: span, bins: 4), [6, 1, 4, 3], "the bars count the dated items")
        XCTAssertTrue(atlas.isInStrip(undated.url), "in the strip while no range is chosen")
        XCTAssertNil(AtlasTimeline.span(sorted: [undated]))
    }

    /// The day by the item's clock as a number agrees with the calendar's
    /// day, for stated offsets and for the Mac's own zone (with its summer time).
    func testTheDayNumberIsTheCalendarDay() {
        var generator = Seeded(seed: 5)
        let start = Date(timeIntervalSince1970: 1_767_000_000)
        let items = (0..<600).map { i -> AtlasItem in
            let date = start.addingTimeInterval(Double(generator.next() % (400 * 86_400)))
            let offset: Int? = i % 3 == 0 ? nil : 900 * (Int(generator.next() % 105) - 48)
            return AtlasItem(url: URL(fileURLWithPath: "/d/\(i).jpg"), isVideo: false, coordinate: nil, date: date, offset: offset, hasCaptureTime: true)
        }
        for (a, b) in Array(zip(items, items.dropFirst())) + Array(zip(items, items.dropFirst(7))) {
            XCTAssertEqual(AtlasItems.dayNumber(of: a) == AtlasItems.dayNumber(of: b), AtlasItems.day(of: a) == AtlasItems.day(of: b),
                           "\(a.date) \(a.offset ?? 0), \(b.date) \(b.offset ?? 0)")
        }
        // Around midnight by the item's own clock
        let late = item("late.jpg", "2026-06-14 23:59:59", nil), early = item("early.jpg", "2026-06-15 00:00:00", nil)
        XCTAssertEqual(AtlasItems.dayNumber(of: early) - AtlasItems.dayNumber(of: late), 1)
    }

    /// A file whose place or time changed on disk is read again: its
    /// modification date changed, or its folder changed (a sidecar dropped
    /// beside it), also while the Atlas wasn't shown.
    func testAFileChangedOnDiskIsReadAgain() async throws {
        final class Disk: @unchecked Sendable {
            let lock = NSLock()
            var latitude = 60.0
            var reads = 0
        }
        let disk = Disk()
        let url = URL(fileURLWithPath: "/trip/photo.jpg")
        let atlas = AtlasModel(browser: nil) { files in
            disk.lock.withLock {
                disk.reads += files.count
                return Dictionary(uniqueKeysWithValues: files.map {
                    ($0.url, CaptureFacts(time: nil, place: CapturePlace(location: MediaLocation(point: GeoPoint(latitude: disk.latitude, longitude: 8)!),
                                                                         source: .file), track: nil))
                })
            }
        }
        func latitude() -> Double? { atlas.items.first?.coordinate?.latitude }
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        atlas.entriesChanged([GridEntry(url: url, kind: .image, modDate: first)], context: "trip")
        await waitUntil { atlas.isComplete && latitude() == 60 }
        // Geotagged in another app: a new modification date
        disk.lock.withLock { disk.latitude = 61 }
        atlas.entriesChanged([GridEntry(url: url, kind: .image, modDate: first.addingTimeInterval(5))], context: "trip")
        await waitUntil { atlas.isComplete && latitude() == 61 }
        // A sidecar beside it: the folder changed, the file didn't
        disk.lock.withLock { disk.latitude = 62 }
        atlas.foldersChanged([BrowserModel.canonicalPath(url.deletingLastPathComponent())])
        await waitUntil { atlas.isComplete && latitude() == 62 }
        // The same list again: nothing read
        let reads = disk.lock.withLock { disk.reads }
        atlas.entriesChanged([GridEntry(url: url, kind: .image, modDate: first.addingTimeInterval(5))], context: "trip")
        await waitUntil { atlas.isComplete }
        XCTAssertEqual(disk.lock.withLock { disk.reads }, reads, "unchanged: not read again")
        // While the Atlas isn't shown: kept for when it is
        atlas.pause()
        disk.lock.withLock { disk.latitude = 63 }
        atlas.foldersChanged(nil)
        XCTAssertEqual(disk.lock.withLock { disk.reads }, reads, "nothing read while not shown")
        atlas.entriesChanged([GridEntry(url: url, kind: .image, modDate: first.addingTimeInterval(5))], context: "trip")
        await waitUntil { atlas.isComplete && latitude() == 63 }
    }

    /// The window closed during the tour: the tour ends there, without
    /// taking another window out of full screen, and nothing goes on ticking.
    func testClosingTheWindowEndsTheTourWithoutLeavingFullScreen() async throws {
        let (w, m, _, tree) = try window()
        var fullScreen: [Bool] = []
        m.setFullScreen = { on in fullScreen.append(on); return true }
        await openAndWait(m, tree.root)
        m.viewMode = .atlas
        await waitUntil { m.atlas.items.count == 14 && m.atlas.isComplete }
        m.atlas.mapSize = CGSize(width: 960, height: 600)
        XCTAssertTrue(w.typeKey(.char("t")))
        XCTAssertTrue(m.touring)
        XCTAssertEqual(fullScreen, [true])
        w.windowClosed()
        XCTAssertFalse(m.touring, "the tour ended with its window")
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertFalse(m.touring)
        XCTAssertEqual(fullScreen, [true], "no window taken out of full screen")
        XCTAssertNil(m.atlas.progress)
    }
}
