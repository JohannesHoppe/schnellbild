import XCTest

/// The Atlas view (W) on the Norway trip of `UITests/Fixtures` (norway-*:
/// 13 photos and a video on five days, one photo without a place):
/// switching to it, selecting on the map and in the strip (the grid's
/// selection), opening, narrowing the timeline, the tour, and the globe's
/// gestures with and without Reduce motion.
final class AtlasUITests: SchnellbildUITestCase {
    private let trip = [
        "norway-01-bryggen.jpg", "norway-02-bryggen.jpg", "norway-03-harbour.jpg", "norway-04-floyen.jpg",
        "norway-05-flam.jpg", "norway-06-flam.jpg", "norway-07-stegastein.jpg", "norway-08-geiranger.jpg",
        "norway-09-geiranger.jpg", "norway-10-geiranger.mov", "norway-11-dalsnibba.jpg", "norway-12-alesund.jpg",
        "norway-13-evening.jpg", "norway-14-trollstigen.jpg",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Only the trip: a.jpg … c.jpg would stretch the timeline to today
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try FileManager.default.removeItem(at: tempDir.appendingPathComponent(name)) }
        for name in trip { try put(name, at: name) }
    }

    /// The trip open in the Atlas, every place read.
    private func openAtlas(extra: [String] = []) {
        launch(open: tempDir.path, extra: extra)
        XCTAssertTrue(app.staticTexts["norway-01-bryggen.jpg"].waitForExistence(timeout: 15), "the grid")
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
        eventually("the places are read", timeout: 20) { self.text(of: self.element("atlasCount")).contains("13 on the map") }
    }

    private func atlasTile(_ name: String) -> XCUIElement { element("atlas.\(name)").firstMatch }
    private func atlasSelected(_ name: String) -> Bool { text(of: atlasTile(name)).hasPrefix("selected") }
    /// The tiles on screen: each one's first item and how many items it holds.
    private var mapTiles: [String: String] {
        var tiles: [String: String] = [:]
        for tile in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'atlas.norway-'"))
            .allElementsBoundByIndex where tile.exists {
            tiles[tile.identifier] = text(of: tile).components(separatedBy: ", ").last ?? ""
        }
        return tiles
    }

    func testTheAtlasShowsTheTripAndSharesTheSelection() throws {
        openAtlas()
        XCTAssertTrue(element("atlasStripTitle").waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: element("atlasStripTitle")), "No location · 1")
        XCTAssertTrue(element("timeline").exists)

        // The photo without a place, in the strip: selected here, selected in the grid
        atlasTile("norway-13-evening.jpg").click()
        eventually("selected in the strip") { self.atlasSelected("norway-13-evening.jpg") }
        app.typeKey("w", modifierFlags: [])
        eventually("the grid again") { self.tile("norway-13-evening.jpg").exists }
        waitForSelected("norway-13-evening.jpg")

        // Selected in the grid, ringed on the map
        tile("norway-14-trollstigen.jpg").click()
        waitForSelected("norway-14-trollstigen.jpg")
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 5))
        eventually("Trollstigen's tile is the selected one") {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'atlas.norway-'"))
                .allElementsBoundByIndex.contains { self.text(of: $0).hasPrefix("selected") }
        }

        // Space opens what is selected, Esc comes back to the Atlas
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "norway-14-trollstigen.jpg")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 5))
        XCTAssertTrue(element("timeline").waitForExistence(timeout: 5))
    }

    func testClickSelectsAndADoubleClickOnAClusterZoomsIn() throws {
        openAtlas()
        // The cluster that holds the trip's first photo
        let first = atlasTile("norway-01-bryggen.jpg")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.click()
        eventually("selected on the map") { self.atlasSelected("norway-01-bryggen.jpg") }
        XCTAssertTrue(text(of: first).contains("items"), text(of: first))
        let count = Int(text(of: first).components(separatedBy: ", ").last?.split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(count, 1, "the trip's first place holds several items at the fitted zoom")
        let before = mapTiles
        first.doubleClick()
        // Zoomed in: the tiles on screen change (they part, others leave the view)
        eventually("zoomed in", timeout: 10) { self.mapTiles != before }
        // The arrows move among the tiles
        app.typeKey(.rightArrow, modifierFlags: [])
        eventually("another tile selected") { !self.atlasSelected("norway-01-bryggen.jpg") }
    }

    func testTheTimelineNarrowsTheMap() throws {
        openAtlas()
        let track = element("timeline.track")
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        // Dragged across the later half: only those days on the map
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.6)))
        eventually("fewer on the map") {
            let shown = self.text(of: self.element("atlasCount"))
            return !shown.contains("13 on the map") && shown.contains("on the map")
        }
        XCTAssertTrue(element("timeline.count").waitForExistence(timeout: 5))
        XCTAssertFalse(atlasTile("norway-01-bryggen.jpg").exists, "the first day is out of the range")
        element("timeline.all").click()
        eventually("the whole span again") { self.text(of: self.element("atlasCount")).contains("13 on the map") }
    }

    func testTheTourPlaysPausesStepsAndEnds() throws {
        openAtlas()
        element("tourButton").click()
        let status = element("tourStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        eventually("the first place") { self.text(of: status).hasPrefix("station 1 of 8") }
        XCTAssertFalse(searchField.exists, "the tour has the window")

        app.typeKey(.space, modifierFlags: [])
        eventually("paused") { self.text(of: status).hasSuffix("paused") }
        app.typeKey(.rightArrow, modifierFlags: [])
        eventually("the next place") { self.text(of: status).hasPrefix("station 2 of 8") }
        app.typeKey(.rightArrow, modifierFlags: [])
        eventually("and the one after") { self.text(of: status).hasPrefix("station 3 of 8") }
        app.typeKey(.leftArrow, modifierFlags: [])
        eventually("back one") { self.text(of: status).hasPrefix("station 2 of 8") }
        XCTAssertTrue(text(of: status).hasSuffix("paused"), "still paused")

        // Resumed, it shows the place's photo after the flight
        app.typeKey(.space, modifierFlags: [])
        eventually("showing", timeout: 10) { self.text(of: status).contains("showing") }
        XCTAssertTrue(element("tourItem").waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        eventually("the tour ended", timeout: 10) { !status.exists }
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        XCTAssertTrue(element("timeline").waitForExistence(timeout: 5))
    }

    // MARK: The globe's gestures

    /// What the map reports under `--ui-testing` (`AtlasModel.testState`).
    private struct MapState {
        var zoom = 0.0, latitude = 0.0, longitude = 0.0
        var glides = 0, thrown = 0, fades = 0
    }

    private func mapState() -> MapState {
        let text = self.text(of: element("atlasMapState"))
        func number(after key: String, _ index: Int = 0) -> Double {
            guard let range = text.range(of: key + " ") else { return .nan }
            let words = text[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "," })
            return index < words.count ? Double(words[index]) ?? .nan : .nan
        }
        return MapState(zoom: number(after: "zoom"), latitude: number(after: "center"), longitude: number(after: "center", 1),
                        glides: Int(number(after: "glides")), thrown: Int(number(after: "throws")), fades: Int(number(after: "fades")))
    }

    /// The globe's view (its accessibility element; tiles lie over it only around the trip).
    private var globe: XCUIElement { app.images["Globe"].firstMatch }

    /// Zoomed out with the − button until the Earth is a globe in space.
    private func zoomOutToTheGlobe() {
        let minus = app.buttons["Zoom out"].firstMatch
        XCTAssertTrue(minus.waitForExistence(timeout: 5))
        for _ in 0..<8 where mapState().zoom > 2.2 {
            minus.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        eventually("the globe") { self.mapState().zoom <= 2.2 }
    }

    func testTheGlobeTurnsThrowsAndZooms() throws {
        openAtlas()
        XCTAssertTrue(globe.waitForExistence(timeout: 10))
        zoomOutToTheGlobe()
        XCTAssertGreaterThan(mapState().glides, 0, "the − button glides")

        // A slow drag to the right, held at its end: the globe turns west under the pointer, nothing thrown
        var before = mapState()
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.75))
            .press(forDuration: 0.2, thenDragTo: globe.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.75)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        var after = mapState()
        let dragged = before.longitude - after.longitude
        XCTAssertGreaterThan(dragged, 5, "turned: \(before) → \(after)")
        XCTAssertEqual(after.thrown, before.thrown, "held still: no throw")

        // Let go while moving: it keeps turning a moment
        before = after
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: globe.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.75)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        eventually("thrown") { self.mapState().thrown > before.thrown }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        after = mapState()
        // The same drag, and then the throw's turn on top of it
        XCTAssertGreaterThan(before.longitude - after.longitude, dragged + 3, "the throw went on after the mouse came up: \(after)")

        // A mouse's wheel zooms about the pointer
        before = after
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75)).scroll(byDeltaX: 0, deltaY: 4)
        eventually("zoomed by the wheel") { abs(self.mapState().zoom - before.zoom) > 0.2 }

        // A double click glides one step in
        before = mapState()
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75)).doubleClick()
        eventually("one step in") { abs(self.mapState().zoom - (before.zoom + 1)) < 0.05 }
        XCTAssertGreaterThan(mapState().glides, before.glides, "it glided")

        // In to the flat map: the globe fades out over it
        before = mapState()
        let plus = app.buttons["Zoom in"].firstMatch
        for _ in 0..<5 where mapState().zoom < 5.5 {
            plus.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        eventually("the flat map, the globe faded out", timeout: 10) { self.mapState().fades > before.fades }
    }

    func testWithReduceMotionNothingGlidesThrowsOrFades() throws {
        openAtlas(extra: ["--reduce-motion"])
        XCTAssertTrue(globe.waitForExistence(timeout: 10))
        zoomOutToTheGlobe()

        // Let go while moving: it turned with the drag and stops where the drag ended
        let start = mapState()
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: globe.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.75)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        let dropped = mapState()
        XCTAssertGreaterThan(start.longitude - dropped.longitude, 5, "turned: \(start) → \(dropped)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(mapState().longitude, dropped.longitude, accuracy: 1e-9, "no throw")

        // A double click jumps one step in
        let before = mapState()
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75)).doubleClick()
        eventually("one step in") { abs(self.mapState().zoom - (before.zoom + 1)) < 0.05 }

        // In to the flat map
        let plus = app.buttons["Zoom in"].firstMatch
        for _ in 0..<5 where mapState().zoom < 5.5 {
            plus.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        eventually("the flat map") { self.mapState().zoom >= 5.5 }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let state = mapState()
        XCTAssertEqual(state.glides, 0, "no glides: \(state)")
        XCTAssertEqual(state.thrown, 0, "no throws")
        XCTAssertEqual(state.fades, 0, "no fades")
    }
}
