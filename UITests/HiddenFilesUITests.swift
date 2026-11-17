import XCTest

/// Hidden files and folders: off, they appear nowhere (the grid, a search
/// into the subfolders, the Atlas with its subfolders); View → Show Hidden
/// Files, ⇧⌘. and Settings → General switch them on and off in the open
/// window at once.
final class HiddenFilesUITests: SchnellbildUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try put("geo-sydney.jpg", at: "sydney.jpg")
        try put("geo-paris.jpg", at: ".trip/paris.jpg")
        try put("sample.jpg", at: ".dot.jpg")
    }

    /// What the grid, the search and the Atlas show, with hidden items or without.
    private func check(shown: Bool, file: StaticString = #filePath, line: UInt = #line) {
        if shown {
            XCTAssertTrue(tile(".dot.jpg").waitForExistence(timeout: 10), "the hidden file", file: file, line: line)
            XCTAssertTrue(tile(".trip").exists, "the hidden folder", file: file, line: line)
        } else {
            eventually("no hidden items in the grid", file: file, line: line) { !self.tile(".dot.jpg").exists && !self.tile(".trip").exists }
            XCTAssertTrue(tile("a.jpg").exists, file: file, line: line)
        }
        // The search, also in the subfolders
        search("paris")
        if shown {
            XCTAssertTrue(app.staticTexts["paris.jpg"].waitForExistence(timeout: 10), "found in the hidden folder", file: file, line: line)
        } else {
            let none = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                            "whose name contains “paris”", "whose name contains “paris”"))
            eventually("nothing found, the search done", file: file, line: line) { none.count > 0 }
            XCTAssertFalse(app.staticTexts["paris.jpg"].exists, file: file, line: line)
        }
        searchField.typeKey(.escape, modifierFlags: [])
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tile("a.jpg").waitForExistence(timeout: 10), file: file, line: line)
        // The Atlas with the subfolders: Paris only while hidden items show
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10), file: file, line: line)
        let count = element("atlasCount")
        eventually(shown ? "Sydney and Paris on the map" : "Sydney alone on the map", timeout: 30, file: file, line: line) {
            self.text(of: count).contains(shown ? "2 on the map" : "1 on the map")
        }
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(tile("a.jpg").waitForExistence(timeout: 10), file: file, line: line)
    }

    func testTheSettingTheMenuAndTheKey() {
        launchOnTempDir()
        check(shown: false)

        // View → Show Hidden Files
        clickMenu("View", "Show Hidden Files")
        check(shown: true)

        // ⇧⌘. as in the Finder
        app.typeKey(".", modifierFlags: [.command, .shift])
        check(shown: false)

        // Settings → General
        app.typeKey(",", modifierFlags: .command)
        let toggle = element("settings.showHiddenFiles").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        eventually("off in Settings") { (toggle.value as? Int ?? (toggle.value as? NSNumber)?.intValue ?? -1) == 0 }
        toggle.click()
        eventually("on in Settings") { (toggle.value as? Int ?? (toggle.value as? NSNumber)?.intValue ?? -1) == 1 }
        app.typeKey("w", modifierFlags: .command)   // the Settings window
        XCTAssertTrue(tile(".dot.jpg").waitForExistence(timeout: 10), "the open window followed")
        check(shown: true)

        // Remembered for the next launch
        app.terminate()
        launch(open: tempDir.path, resetState: false)
        XCTAssertTrue(tile(".dot.jpg").waitForExistence(timeout: 15), "still shown after a new launch")
    }
}
