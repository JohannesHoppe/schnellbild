import XCTest
import SwiftUI
import OfflineMap
import CoreLocation
@testable import Schnellbild

/// The Inspector and sorting by distance in the shortcut system (I and ⌘I,
/// ⌘6, both presets) and the Inspector's offline map and place names from
/// the bundled map data.
@MainActor
final class InspectorIntegrationTests: XCTestCase {
    private func chord(_ stored: String) -> KeyChord { KeyChord(stored: stored)! }

    private func window(_ shortcuts: Shortcuts) -> WindowModel {
        let defaults = makeTestDefaults()
        let left = BrowserModel(defaults: defaults)
        left.searchDebounce = .zero
        let window = WindowModel(left: left, defaults: defaults) {
            BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        }
        window.shortcuts = shortcuts
        return window
    }

    // MARK: Shortcuts

    func testDistanceIsASortActionOnCommand6() {
        XCTAssertEqual(ShortcutAction.sorts.map(\.sortKey), BrowserModel.SortKey.allCases.map { Optional($0) },
                       "one action per sort key, in the menu's order")
        let s = Shortcuts(defaults: makeTestDefaults())
        XCTAssertEqual(s.keys(.sortDistance), [chord("@6")])
        XCTAssertEqual(s.menuShortcut(.sortDistance), KeyboardShortcut("6", modifiers: .command))
        XCTAssertEqual(ShortcutAction.sortDistance.name, String(localized: "Sort by \(BrowserModel.SortKey.distance.title)"))
        // Remappable like the others
        s.assign(chord("^@6"), to: .sortDistance, replacing: chord("@6"))
        XCTAssertEqual(s.menuShortcut(.sortDistance), KeyboardShortcut("6", modifiers: [.command, .control]))
    }

    func testInfoIsIEverywhereAndCommandIInTheMenu() {
        let s = Shortcuts(defaults: makeTestDefaults())
        XCTAssertEqual(s.keys(.info), [chord("i"), chord("@i")])
        XCTAssertEqual(s.menuShortcut(.info), KeyboardShortcut("i", modifiers: .command), "Actions → Get Info")
        for scope: ShortcutScope in [.grid, .full, .show] {
            XCTAssertEqual(s.resolve(chord("i"), in: scope), .standard, "I in \(scope)")
            XCTAssertEqual(s.resolve(chord("@i"), in: scope), .standard, "⌘I in \(scope)")
        }
        s.assign(chord("j"), to: .info, replacing: chord("i"))
        XCTAssertEqual(s.resolve(chord("j"), in: .grid), .custom(.info))
    }

    func testThePhiewerPresetKeepsCommand6AndCommandIFree() {
        let s = Shortcuts(defaults: makeTestDefaults())
        s.choose(.phiewer)
        XCTAssertEqual(s.keys(.sortDistance), [chord("@6")])
        XCTAssertTrue(s.keys(.info).contains(chord("@i")))
        for action in ShortcutAction.allCases where action != .sortDistance && action != .info {
            XCTAssertFalse(s.keys(action).contains(chord("@6")), "\(action) has ⌘6 as in Phiewer")
            XCTAssertFalse(s.keys(action).contains(chord("@i")), "\(action) has ⌘I as in Phiewer")
        }
    }

    func testTheHelpListsDistanceAndInfo() {
        let s = Shortcuts(defaults: makeTestDefaults())
        let rows = ShortcutsHelpView.groups(s).flatMap(\.shortcuts)
        func keys(_ action: String) -> String? { rows.first { $0.action == String(localized: String.LocalizationValue(action)) }?.keys }
        XCTAssertEqual(keys("Sort by name, kind, date modified, date taken, size, distance (again: reverse)"), "⌘ + 1 … ⌘ + 6")
        XCTAssertEqual(keys("File info"), "I / ⌘ + I")
    }

    func testPerformingTheActions() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let w = window(Shortcuts(defaults: makeTestDefaults()))
        let m = w.active
        await openAndWait(m, tree.root)
        // ⌘6 without a place to measure from asks for one
        XCTAssertTrue(w.perform(.sortDistance))
        XCTAssertTrue(m.distanceOriginRequested)
        XCTAssertNotEqual(m.sortKey, .distance)
        m.distanceOriginRequested = false
        m.setDistanceOrigin(try XCTUnwrap(GeoPoint(latitude: 48.137, longitude: 11.575)))
        XCTAssertEqual(m.sortKey, .distance)
        XCTAssertTrue(w.perform(.sortDistance))
        XCTAssertFalse(m.sortAscending, "again: farthest first")
        // I in the grid
        XCTAssertTrue(w.perform(.info))
        XCTAssertTrue(m.showInspector)
        XCTAssertTrue(w.perform(.info))
        XCTAssertFalse(m.showInspector)
    }

    // MARK: Offline map and place names

    private static var renderer: MapRenderer?

    private func bundledRenderer() throws -> MapRenderer {
        if let renderer = Self.renderer { return renderer }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/Map")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let map = try XCTUnwrap(files.first { $0.pathExtension == "pmtiles" }, "Scripts/fetch_map.sh puts the map into Vendor/Map")
        let places = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("schnellbild-places-") })
        let renderer = MapRenderer(archive: try PMTilesArchive(url: map), places: try PlaceIndex(url: places))
        Self.renderer = renderer
        return renderer
    }

    func testThePlaceNearAPhoto() async throws {
        let geography = try XCTUnwrap(BundledGeography.make(renderer: try bundledRenderer()))
        let geiranger = await geography.placeName(near: try XCTUnwrap(GeoPoint(latitude: 62.1008, longitude: 7.2059)))
        XCTAssertTrue(geiranger?.contains("Geiranger") == true, "\(geiranger ?? "nil")")
        // The middle of the Atlantic: no town within 50 km
        let sea = await geography.placeName(near: try XCTUnwrap(GeoPoint(latitude: 30, longitude: -40)))
        XCTAssertNil(sea)
        XCTAssertNil(BundledGeography.make(renderer: nil), "no map data: no provider")
    }

    func testTheMapLooksAtThePhotosPlace() throws {
        let geography = try XCTUnwrap(BundledGeography.make(renderer: try bundledRenderer()))
        let point = try XCTUnwrap(GeoPoint(latitude: 48.137, longitude: 11.575))
        XCTAssertNotNil(geography.map(around: point))
        let camera = InspectorMap.camera(for: point)
        XCTAssertEqual(camera.center.latitude, 48.137, accuracy: 1e-9)
        XCTAssertEqual(camera.center.longitude, 11.575, accuracy: 1e-9)
        XCTAssertEqual(camera.zoom, BundledGeography.zoom)
        // Drawn as the Inspector shows it (off screen): tiles come in
        let host = NSHostingView(rootView: InspectorMap(point: point, renderer: try bundledRenderer())
            .frame(width: InspectorView.width - 28, height: 160))
        host.frame = CGRect(x: 0, y: 0, width: InspectorView.width - 28, height: 160)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.subviews.count, 0)
    }

    // MARK: The distance sheet: the map and Use My Location

    func testUseMyLocationFillsInThePlaceOrSaysWhy() async throws {
        let stub = LocationStub()
        let munich = try XCTUnwrap(GeoPoint(latitude: 48.137, longitude: 11.575))
        stub.answer = .success(munich)
        let picker = OriginPicker(location: stub, geography: { nil })
        XCTAssertEqual(stub.asked, 0, "nothing is asked before the click")
        await picker.useMyLocation()
        XCTAssertEqual(stub.asked, 1, "once")
        XCTAssertEqual(picker.point?.latitude ?? 0, 48.137, accuracy: 1e-6)
        XCTAssertNil(picker.locationProblem)
        XCTAssertFalse(picker.locating)
        for failure in [LocationFailure.denied, .restricted, .servicesOff, .unavailable] {
            stub.answer = .failure(failure)
            picker.text = ""
            await picker.useMyLocation()
            XCTAssertEqual(picker.locationProblem, failure.message)
            XCTAssertNil(picker.point, "\(failure): no place")
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertEqual(Set([LocationFailure.denied, .restricted, .servicesOff, .unavailable].map(\.message)).count, 4, "each says its own")
    }

    func testThePermissionDecidesWhetherToAsk() {
        XCTAssertEqual(CoreLocationProvider.failure(for: .denied), .denied)
        XCTAssertEqual(CoreLocationProvider.failure(for: .restricted), .restricted)
        XCTAssertNil(CoreLocationProvider.failure(for: .notDetermined), "asks the user")
        XCTAssertNil(CoreLocationProvider.failure(for: .authorizedAlways))
    }

    /// Use My Location's request: the time limit runs from the request for
    /// the position (not while macOS asks the user), a second click ends the
    /// first at once and the first's limit no longer ends the second, and a
    /// one-shot request that finds nothing ("location unknown") ends at once.
    func testUseMyLocationsRequestsAndTheirTimeLimit() async throws {
        let clock = LimitClock()
        var made: [RequesterStub] = []
        var status = CLAuthorizationStatus.authorizedAlways
        let provider = CoreLocationProvider(limit: .seconds(30), servicesEnabled: { true }, wait: { _ in await clock.wait() }) { _ in
            let requester = RequesterStub(status: status)
            made.append(requester)
            return requester
        }
        let munich = try XCTUnwrap(GeoPoint(latitude: 48.137, longitude: 11.575))

        // Two clicks: the first answered at once, the second has its own limit
        var results: [Int: Result<GeoPoint, LocationFailure>] = [:]
        Task { results[1] = await provider.currentLocation() }
        await waitUntil { made.count == 1 && clock.begun == 1 }
        XCTAssertEqual(made[0].positionsRequested, 1)
        Task { results[2] = await provider.currentLocation() }
        await waitUntil { results[1] != nil && made.count == 2 && clock.begun == 2 }
        XCTAssertEqual(results[1], .failure(.unavailable), "the first click's request ends")
        XCTAssertTrue(made[0].stopped)
        clock.release(0)   // the first request's limit runs out
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(results[2], "it doesn't end the second request")
        provider.located(munich, from: made[1])
        await waitUntil { results[2] != nil }
        XCTAssertEqual(results[2], .success(munich))
        clock.release(1)

        // The first time: no limit while macOS asks the user
        status = .notDetermined
        Task { results[3] = await provider.currentLocation() }
        await waitUntil { made.count == 3 && made[2].permissionAsked == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(clock.begun, 2, "no limit running during the prompt")
        XCTAssertEqual(made[2].positionsRequested, 0)
        provider.authorizationChanged(.authorizedAlways, from: made[2])
        await waitUntil { made[2].positionsRequested == 1 && clock.begun == 3 }
        // The one-shot request finds nothing: said at once, not after the limit
        provider.failed(.locationUnknown, from: made[2])
        await waitUntil { results[3] != nil }
        XCTAssertEqual(results[3], .failure(.unavailable))
        clock.release(2)

        // Denied in the prompt
        status = .notDetermined
        Task { results[4] = await provider.currentLocation() }
        await waitUntil { made.count == 4 && made[3].permissionAsked == 1 }
        provider.authorizationChanged(.denied, from: made[3])
        await waitUntil { results[4] != nil }
        XCTAssertEqual(results[4], .failure(.denied))
    }

    /// The sheet's map dragged far down stays within the world (no empty
    /// band above it); a place clicked twice, then coordinates typed: the
    /// map goes to them.
    func testTheSheetsMapStaysOnTheWorldAndFollowsTypedPlaces() throws {
        let size = CGSize(width: 440, height: 220)
        let start = MapCamera(center: Coordinate(latitude: 40, longitude: 10), zoom: 2)
        let dragged = OriginPicker.dragged(start, by: CGSize(width: 0, height: 2000), size: size)
        XCTAssertEqual(MapViewport(camera: dragged, size: size).unitBounds.minY, 0, accuracy: 1e-9, "the world's top at the view's top")
        let right = OriginPicker.dragged(start, by: CGSize(width: 100, height: 0), size: size)
        XCTAssertLessThan(right.center.longitude, start.center.longitude, "the map follows the pointer: the middle goes west")

        let picker = OriginPicker(location: LocationStub(), geography: { nil })
        let bergen = try XCTUnwrap(GeoPoint(latitude: 60.39, longitude: 5.32))
        picker.pick(bergen, fromMap: true)
        XCTAssertFalse(picker.mapFollows(picker.point), "a click keeps the view")
        picker.pick(bergen, fromMap: true)   // the same place again: the text doesn't change
        picker.text = "48.137, 11.575"
        XCTAssertTrue(picker.mapFollows(picker.point), "typed: the map goes there")
        picker.pick(bergen)
        XCTAssertTrue(picker.mapFollows(picker.point), "found elsewhere (Use My Location): the map goes there")
    }

    func testAClickOnTheMapPicksThePlaceUnderIt() async throws {
        let camera = MapCamera(center: Coordinate(latitude: 48.137, longitude: 11.575), zoom: 8)
        let size = CGSize(width: 440, height: 220)
        let middle = try XCTUnwrap(OriginPicker.point(at: CGPoint(x: 220, y: 110), camera: camera, size: size))
        XCTAssertEqual(middle.latitude, 48.137, accuracy: 1e-6)
        XCTAssertEqual(middle.longitude, 11.575, accuracy: 1e-6)
        let east = try XCTUnwrap(OriginPicker.point(at: CGPoint(x: 320, y: 110), camera: camera, size: size))
        XCTAssertGreaterThan(east.longitude, 11.575, "right of the middle: further east")
        let north = try XCTUnwrap(OriginPicker.point(at: CGPoint(x: 220, y: 10), camera: camera, size: size))
        XCTAssertGreaterThan(north.latitude, 48.137, "above the middle: further north")
        // The place picked goes into the field, with the town near it
        let geography = try XCTUnwrap(BundledGeography.make(renderer: try bundledRenderer()))
        let picker = OriginPicker(location: LocationStub(), geography: { geography })
        picker.pick(middle)
        let written = try XCTUnwrap(GeoPoint.parse(picker.text))
        XCTAssertEqual(written.latitude, middle.latitude, accuracy: 1e-6, "six decimals: about 10 cm")
        XCTAssertEqual(written.longitude, middle.longitude, accuracy: 1e-6)
        await picker.placeNameRead()
        XCTAssertTrue(picker.placeName?.contains("Munich") == true || picker.placeName?.contains("München") == true,
                      picker.placeName ?? "nil")
    }
}

/// Stands in for Core Location: answers what the test sets, counts the requests.
@MainActor
private final class LocationStub: LocationProvider {
    var answer: Result<GeoPoint, LocationFailure> = .failure(.unavailable)
    var asked = 0
    func currentLocation() async -> Result<GeoPoint, LocationFailure> {
        asked += 1
        return answer
    }
}

/// Stands in for Core Location's manager: records what was asked of it.
@MainActor
private final class RequesterStub: LocationRequester {
    let status: CLAuthorizationStatus
    var permissionAsked = 0
    var positionsRequested = 0
    var stopped = false
    init(status: CLAuthorizationStatus) { self.status = status }
    func askPermission() { permissionAsked += 1 }
    func requestPosition() { positionsRequested += 1 }
    func stop() { stopped = true }
}

/// The time limits' waits, each ended when the test says.
private final class LimitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>?] = []

    /// How many waits began.
    var begun: Int { lock.withLock { continuations.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    /// Ends the wait begun as the `index`th.
    func release(_ index: Int) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { continuations[index] = nil }
            return continuations[index]
        }
        continuation?.resume()
    }
}
