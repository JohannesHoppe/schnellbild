import XCTest

/// The Inspector (I, ⌘I, Get Info) with a photo's capture facts and place,
/// and sorting by the distance from an item or from coordinates pasted.
final class InspectorUITests: SchnellbildUITestCase {
    /// geo.jpg (Munich) and three more landmarks, besides a.jpg … c.jpg without a place.
    private func putPlaces() throws {
        for name in ["geo.jpg", "geo-paris.jpg", "geo-sydney.jpg", "geo-newyork.jpg"] { try put(name, at: name) }
    }

    /// Whether tile `a` comes before tile `b` in the grid (rows, then columns).
    private func comesBefore(_ a: String, _ b: String) -> Bool {
        let first = tile(a).frame, second = tile(b).frame
        if abs(first.minY - second.minY) > 5 { return first.minY < second.minY }
        return first.minX < second.minX
    }

    private func contextItem(_ title: String) -> XCUIElement? {
        app.menuItems.allElementsBoundByIndex.first { $0.title == title && $0.isHittable }
    }

    private func sortLabel() -> String {
        app.descendants(matching: .any).matching(identifier: "sortMenu").allElementsBoundByIndex
            .map { text(of: $0) }.joined(separator: " ")
    }

    func testIShowsCaptureAndLocationInTheGrid() throws {
        try putPlaces()
        launchOnTempDir(waitFor: "geo.jpg")
        tile("geo.jpg").click()
        eventually("selected") { isSelected("geo.jpg") }
        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(element("inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Location"].exists)
        XCTAssertTrue(app.staticTexts["48.1372° N, 11.5761° E"].exists)
        XCTAssertTrue(app.staticTexts["Example Camera One"].exists)
        XCTAssertTrue(app.staticTexts["64 × 48 px"].exists)
        XCTAssertTrue(element("openInMaps").exists)
        // The offline map and the town near the place, from the map data the app carries
        XCTAssertTrue(element("inspectorMap").waitForExistence(timeout: 10))
        eventually("the town near it") { text(of: element("inspectorPlace")) == "near Munich, Germany" }
        // The next item: the sidebar follows the selection
        tile("geo-paris.jpg").click()
        eventually("Paris") { app.staticTexts["48.8584° N, 2.2945° E"].exists }
        app.typeKey("i", modifierFlags: [])
        eventually("I hides it") { !element("inspector").exists }
        // ⌘I, the menu item
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(element("inspector").waitForExistence(timeout: 5))
    }

    func testGetInfoFromATilesMenu() throws {
        try putPlaces()
        launchOnTempDir(waitFor: "geo.jpg")
        tile("geo-sydney.jpg").rightClick()
        // The context menu's, not the Actions menu's of the same name
        eventually("the context menu shows Get Info") { contextItem("Get Info") != nil }
        contextItem("Get Info")?.click()
        XCTAssertTrue(app.staticTexts["Location"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["33.8568° S, 151.2153° E"].exists)
        eventually("the item it was asked for is selected") { isSelected("geo-sydney.jpg") }
    }

    func testIInTheFullView() throws {
        try putPlaces()
        launchOnTempDir(waitFor: "geo.jpg")
        tile("geo.jpg").click()
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "geo.jpg")
        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Location"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Capture"].exists)
    }

    func testSortByDistanceFromAnItem() throws {
        try putPlaces()
        launchOnTempDir(waitFor: "geo.jpg")
        tile("geo-paris.jpg").rightClick()
        // The context menu's, not the Actions menu's of the same name
        eventually("the context menu shows Sort by Distance from Here") { contextItem("Sort by Distance from Here") != nil }
        contextItem("Sort by Distance from Here")?.click()
        eventually("Paris, Munich, New York, Sydney, then those without a place") {
            comesBefore("geo-paris.jpg", "geo.jpg") && comesBefore("geo.jpg", "geo-newyork.jpg")
                && comesBefore("geo-newyork.jpg", "geo-sydney.jpg") && comesBefore("geo-sydney.jpg", "a.jpg")
        }
        XCTAssertTrue(sortLabel().contains("Distance ↑"), sortLabel())
        // The list shows how far
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(element("column.distance").waitForExistence(timeout: 5))
    }

    /// ⌘6 (Distance) with no place yet asks for one.
    func testSortByDistanceFromPastedCoordinates() throws {
        try putPlaces()
        launchOnTempDir(waitFor: "geo.jpg")
        app.typeKey("6", modifierFlags: .command)
        let field = app.textFields["distanceOriginField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no place yet: the sheet asks for one")
        field.typeText("33.8568 S, 151.2153 E")
        eventually("read") { text(of: element("distanceOriginParsed")).contains("33.85") }
        app.typeKey(.return, modifierFlags: [])
        eventually("Sydney, New York, Munich, Paris, then those without a place") {
            comesBefore("geo-sydney.jpg", "geo-newyork.jpg") && comesBefore("geo-newyork.jpg", "geo.jpg")
                && comesBefore("geo.jpg", "geo-paris.jpg") && comesBefore("geo-paris.jpg", "a.jpg")
        }
    }

    /// A click on the sheet's map picks the place under it; Sort sorts from there.
    func testAClickOnTheSheetsMapPicksTheOrigin() throws {
        try putPlaces()
        launchOnTempDir(waitFor: "geo.jpg")
        app.typeKey("6", modifierFlags: .command)
        let pick = element("distanceOriginMapPick")
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "the offline map in the sheet")
        XCTAssertTrue(element("useMyLocation").exists, "Use My Location (not clicked: CI can't answer macOS's question)")
        pick.click()
        eventually("the place clicked is read") { text(of: element("distanceOriginParsed")).contains("°") }
        app.buttons["distanceOriginSort"].click()
        eventually("sorted by distance") { sortLabel().contains("Distance ↑") }
    }
}
