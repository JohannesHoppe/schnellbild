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
        XCTAssertEqual(keys("Sort by name, kind, date modified, date taken, size, distance (again: reverse)"), "⌘1 … ⌘6")
        XCTAssertEqual(keys("File info"), "I / ⌘I")
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
        XCTAssertEqual(GeoPoint.parse(picker.text), middle)
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
