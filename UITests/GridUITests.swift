import XCTest

/// The grid: tiles, selection, keyboard, sizes, sorting, status bar, states.
final class GridUITests: SchnellbildUITestCase {
    func testGridShowsTilesAndStatusCounts() {
        launchOnTempDir()
        XCTAssertTrue(app.staticTexts["b.jpg"].exists)
        XCTAssertTrue(app.staticTexts["c.jpg"].exists)
        XCTAssertTrue(app.staticTexts[".."].exists, "parent tile")
        eventually("status bar counts the images") { text(of: app.staticTexts["statusText"]) == "3 images" }
    }

    func testArrowKeysHomeAndEndMoveTheSelection() {
        launchOnTempDir()
        waitForSelected("a.jpg")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForSelected("b.jpg")
        app.typeKey(.end, modifierFlags: [])
        waitForSelected("c.jpg")
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForSelected("b.jpg")
        app.typeKey(.home, modifierFlags: [])
        waitForSelected("..")
    }

    func testClickSelectsAndDoubleClickOpens() {
        launchOnTempDir()
        tile("c.jpg").click()
        waitForSelected("c.jpg")
        tile("b.jpg").doubleClick()
        waitForBadge(containing: "b.jpg")
    }

    func testCommandPlusAndMinusResizeTiles() {
        launchOnTempDir()
        let before = tile("a.jpg").frame.width
        app.typeKey("+", modifierFlags: .command)
        eventually("tiles grow") { tile("a.jpg").frame.width > before }
        app.typeKey("-", modifierFlags: .command)
        app.typeKey("-", modifierFlags: .command)
        eventually("tiles shrink") { tile("a.jpg").frame.width < before }
    }

    func testThumbnailSizeMenuItems() {
        launchOnTempDir()
        let before = tile("a.jpg").frame.width
        clickMenu("View", "Larger Thumbnails (⌘+)")
        eventually("tiles grow") { tile("a.jpg").frame.width > before }
        clickMenu("View", "Smaller Thumbnails (⌘−)")
        eventually("tiles back") { abs(tile("a.jpg").frame.width - before) < 1 }
    }

    func testSortByNameTogglesDirection() {
        launchOnTempDir()
        XCTAssertLessThan(tile("a.jpg").frame.minX, tile("c.jpg").frame.minX)
        clickMenu("View", "Sort by Name")
        eventually("descending: c before a") { tile("c.jpg").frame.minX < tile("a.jpg").frame.minX }
    }

    func testSortBySize() throws {
        try put("large.jpg", at: "0-large.jpg")
        launchOnTempDir()
        XCTAssertLessThan(tile("0-large.jpg").frame.minX, tile("a.jpg").frame.minX, "by name first")
        clickMenu("View", "Sort by Size")
        eventually("large file sorts last") { tile("0-large.jpg").frame.minX > tile("c.jpg").frame.minX }
    }

    func testSortByDate() throws {
        let old = tempDir.appendingPathComponent("c.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        launchOnTempDir()
        clickMenu("View", "Sort by Date")
        eventually("oldest first") { tile("c.jpg").frame.minX < tile("a.jpg").frame.minX }
    }

    func testEmptyFolderState() throws {
        let empty = try folder("empty")
        let app = launch(open: empty.path)
        XCTAssertTrue(app.staticTexts["Nothing to show"].waitForExistence(timeout: 15))
    }

    func testNoFolderStateWithDisabledSearch() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["No folder open"].waitForExistence(timeout: 15))
        XCTAssertTrue(searchField.exists, "search is always visible")
        XCTAssertFalse(searchField.isEnabled, "but disabled without a folder")
    }

    func testLastFolderIsRestoredOnRelaunch() {
        launchOnTempDir()
        app.terminate()
        let relaunched = launch(resetState: false)
        XCTAssertTrue(relaunched.staticTexts["a.jpg"].waitForExistence(timeout: 15),
                      "the last folder reopens")
    }

    func testFolderTilesShowPreviewImages() throws {
        for name in ["1.jpg", "2.jpg", "3.jpg", "4.jpg"] { try put("sample.jpg", at: "album/\(name)") }
        try folder("empty")
        launchOnTempDir()
        eventually("album shows three previews", timeout: 20) { text(of: tile("album")).hasSuffix("3 previews") }
        XCTAssertTrue(text(of: tile("empty")).hasSuffix("0 previews"))
    }

    func testFullScreenToggle() {
        launchOnTempDir()
        let window = app.windows.firstMatch
        let before = window.frame.size
        app.typeKey("f", modifierFlags: [])
        eventually("window enters full screen", timeout: 10) {
            window.frame.width > before.width || window.frame.height > before.height
        }
        app.typeKey("f", modifierFlags: [])
        eventually("window leaves full screen", timeout: 10) { window.frame.size == before }
    }

    func testF1AndHelpMenuShowShortcuts() {
        launchOnTempDir()
        app.typeKey(.F1, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Keyboard Shortcuts"].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        eventually("help closes") { !app.staticTexts["Keyboard Shortcuts"].exists }
        clickMenu("Help", "Schnellbild Help")
        XCTAssertTrue(app.staticTexts["Keyboard Shortcuts"].waitForExistence(timeout: 5))
    }

    func testCommandOShowsTheOpenPanel() {
        launchOnTempDir()
        app.typeKey("o", modifierFlags: .command)
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the open panel appears")
        cancel.click()
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 5))
    }
}
