import XCTest

/// The Atlas view (W) on the Norway trip of `UITests/Fixtures` (norway-*:
/// 13 photos and a video on five days, one photo without a place):
/// switching to it, selecting on the map and in the strip (the grid's
/// selection), opening, narrowing the timeline, and the tour.
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
    private func openAtlas() {
        launchOnTempDir(waitFor: "norway-01-bryggen.jpg")
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
        eventually("the places are read", timeout: 20) { self.text(of: self.element("atlasCount")).contains("13 on the map") }
    }

    private func atlasTile(_ name: String) -> XCUIElement { element("atlas.\(name)").firstMatch }
    private func atlasSelected(_ name: String) -> Bool { text(of: atlasTile(name)).hasPrefix("selected") }
    private var mapTiles: Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'atlas.norway-'")).count
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
        let before = mapTiles
        // The cluster that holds the trip's first photo
        let first = atlasTile("norway-01-bryggen.jpg")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.click()
        eventually("selected on the map") { self.atlasSelected("norway-01-bryggen.jpg") }
        XCTAssertTrue(text(of: first).contains("items"), text(of: first))
        let count = Int(text(of: first).components(separatedBy: ", ").last?.split(separator: " ").first ?? "") ?? 0
        if count > 1 {
            first.doubleClick()
            eventually("zoomed in: the cluster parts", timeout: 10) { self.mapTiles > before }
        }
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
}
