import XCTest

/// Search: always visible, always recursive, folder and file names.
final class SearchUITests: SchnellbildUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try put("sample.jpg", at: "trips/2024/deep-photo.jpg")
        try folder("archive/Urlaub 2024")
    }

    func testSearchFieldIsVisibleInGridAndFullView() {
        launchOnTempDir()
        XCTAssertTrue(searchField.exists)
        XCTAssertTrue(searchField.isEnabled)
        tile("a.jpg").doubleClick()
        waitForBadge(containing: "a.jpg")
        XCTAssertTrue(searchField.exists, "still visible in the full view")
    }

    func testSearchFieldDoesNotTakeKeysOnLaunch() {
        launchOnTempDir()
        waitForSelected("archive")   // folders sort first
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForSelected("trips")
        XCTAssertNotEqual(text(of: searchField), "→")
    }

    func testFindsFilesInSubfolders() {
        launchOnTempDir()
        search("deep")
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["trips/2024"].exists, "shows where the result lives")
        XCTAssertFalse(app.staticTexts["a.jpg"].exists)
        eventually("status shows the result count") {
            text(of: app.staticTexts["statusText"]).hasPrefix("1 result for “deep”")
        }
    }

    func testBackButtonFromAnOpenedResultKeepsTheSearch() {
        launchOnTempDir()
        search("deep")
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        tile("deep-photo.jpg").doubleClick()
        waitForBadge(containing: "deep-photo.jpg")
        toolbarButton("backButton").click()
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 5), "back to the results")
        XCTAssertEqual(text(of: searchField), "deep", "the search stays")
        XCTAssertFalse(app.staticTexts["a.jpg"].exists)
    }

    func testArrowsPageAfterOpeningAResultWithTheMouse() {
        launchOnTempDir()
        search("jpg")   // the search field keeps focus while typing
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        tile("a.jpg").doubleClick()
        waitForBadge(containing: "a.jpg")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "b.jpg")
        XCTAssertEqual(text(of: searchField), "jpg", "the arrow didn't go into the search field")
    }

    func testFindsFolderNamesInSubfolders() {
        launchOnTempDir()
        search("urlaub")
        XCTAssertTrue(app.staticTexts["Urlaub 2024"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["archive"].exists)
    }

    func testNoMatches() {
        launchOnTempDir()
        search("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 10))
    }

    /// The stop button ends a running search; what it found stays.
    func testStopButtonEndsTheSearchAndKeepsTheResults() {
        launch(open: tempDir.path, extra: ["--search-delay=30000"])   // the walk waits: a running search
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        search("a.jpg")
        let stop = app.buttons["stopSearch"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "a running search can be stopped")
        XCTAssertTrue(app.staticTexts["Searching subfolders…"].exists)
        stop.click()
        eventually("stopped") { !stop.exists && !self.app.staticTexts["Searching subfolders…"].exists }
        XCTAssertTrue(app.staticTexts["a.jpg"].exists, "the result found so far stays")
    }

    func testCommandFFocusesSearchAndEscapeClears() {
        let log = tempDir.appendingPathComponent("test.log")
        launch(open: tempDir.path, extra: ["--test-log=\(log.path)"])
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        continueAfterFailure = true   // to report the log below
        func appLog() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "(none)" }
        app.typeKey("f", modifierFlags: .command)
        app.typeText("deep")
        eventually("typed into the search field") { self.text(of: self.searchField) == "deep" }
        if text(of: searchField) != "deep" { XCTFail("search field holds “\(text(of: searchField))”; app log:\n\(appLog())") }
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 5), "Escape clears the search")
        eventually("results are gone") { !app.staticTexts["deep-photo.jpg"].exists }
    }

    func testEscapeInGridClearsSearch() {
        launchOnTempDir()
        search("deep")
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: [])   // leave the field
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 5))
    }

    func testReturnInSearchOpensTheResult() {
        launchOnTempDir()
        search("deep")
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        waitForBadge(containing: "deep-photo.jpg")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 5), "back to the results")
    }

    func testDownArrowMovesIntoResults() {
        launchOnTempDir()
        search(".jpg")
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])   // a grid key now, not a text cursor move
        waitForSelected("b.jpg")
    }

    func testTypingInFullViewShowsResults() {
        launchOnTempDir()
        tile("a.jpg").doubleClick()
        waitForBadge(containing: "a.jpg")
        search("deep")
        XCTAssertTrue(app.staticTexts["deep-photo.jpg"].waitForExistence(timeout: 10))
        XCTAssertFalse(badge.exists, "results show in the grid")
    }

    func testBackFromAResultFolderRestoresTheSearch() throws {
        try put("sample.jpg", at: "archive/Urlaub 2024/beach.jpg")
        launchOnTempDir()
        search("urlaub")
        XCTAssertTrue(app.staticTexts["Urlaub 2024"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])   // open the result folder
        XCTAssertTrue(app.staticTexts["beach.jpg"].waitForExistence(timeout: 10))

        toolbarButton("backButton").click()
        XCTAssertTrue(app.staticTexts["Urlaub 2024"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["beach.jpg"].exists)
        XCTAssertEqual(text(of: searchField), "urlaub")
        waitForSelected("Urlaub 2024")
    }
}
