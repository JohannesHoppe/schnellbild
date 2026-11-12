import XCTest

/// The grid: tiles, selection, keyboard, sizes, sorting, status bar, states.
final class GridUITests: SchnellbildUITestCase {
    func testGridShowsTilesAndStatusCounts() {
        launchOnTempDir()
        XCTAssertTrue(app.staticTexts["b.jpg"].exists)
        XCTAssertTrue(app.staticTexts["c.jpg"].exists)
        XCTAssertTrue(app.staticTexts[".."].exists, "parent tile")
        eventually("status bar counts the pictures") { text(of: app.staticTexts["statusText"]) == "3 pictures" }
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

    /// ↑ ↓ move by one row of the grid as laid out on screen, straight up
    /// and down, also after the tile size (and with it the number of
    /// columns) changes.
    func testUpAndDownMoveByTheRowsOnScreen() throws {
        let photos = (0..<20).map { String(format: "p%02d.jpg", $0) }
        for name in photos { try put("sample.jpg", at: name) }
        launchOnTempDir(waitFor: "p00.jpg")
        let names = ["..", "a.jpg", "b.jpg", "c.jpg"] + photos
        let grid = element("grid").firstMatch
        /// "<columns the keys use> columns, <columns laid out> laid out, selection <index>"
        func reported() -> (keys: Int, laidOut: Int, selection: Int) {
            let n = text(of: grid).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return n.count == 3 ? (n[0], n[1], n[2]) : (-1, -1, -1)
        }

        // As laid out: a.jpg's neighbour straight below is the selection
        tile("a.jpg").click()
        waitForSelected("a.jpg")
        let top = tile("..").frame.minY
        let wide = names.prefix { abs(tile($0).frame.minY - top) < 2 }.count
        XCTAssertGreaterThan(wide, 1, "several columns")
        XCTAssertEqual(reported().keys, wide, "the keys step by the columns on screen: \(text(of: grid))")
        app.typeKey(.downArrow, modifierFlags: [])
        waitForSelected(names[1 + wide])
        // Both frames at the same moment: ↓ scrolls the grid
        eventually("straight below, on the very next row") {
            let from = self.tile("a.jpg").frame, below = self.tile(names[1 + wide]).frame
            return abs(below.minX - from.minX) < 2 && below.minY > from.maxY && below.minY < from.maxY + from.height
        }
        app.typeKey(.upArrow, modifierFlags: [])
        waitForSelected("a.jpg")

        // Smaller tiles, more columns: the keys follow (the grid's old
        // cells may linger in the accessibility tree, so its report is read)
        app.typeKey("-", modifierFlags: .command)
        app.typeKey("-", modifierFlags: .command)
        eventually("more columns with smaller tiles: \(text(of: grid))") { reported().laidOut > wide }
        let narrow = reported()
        XCTAssertEqual(narrow.keys, narrow.laidOut, "the keys step by the columns laid out: \(text(of: grid))")
        XCTAssertEqual(narrow.selection, 1)
        app.typeKey(.downArrow, modifierFlags: [])
        eventually("↓ moves one row of \(narrow.laidOut): \(text(of: grid))") { reported().selection == 1 + narrow.laidOut }
        app.typeKey(.upArrow, modifierFlags: [])
        eventually("↑ back: \(text(of: grid))") { reported().selection == 1 }
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
        clickMenu("View", "Name")
        eventually("descending: c before a") { tile("c.jpg").frame.minX < tile("a.jpg").frame.minX }
    }

    func testSortBySizeLargestFirst() throws {
        try put("large.jpg", at: "z-large.jpg")
        launchOnTempDir()
        XCTAssertGreaterThan(tile("z-large.jpg").frame.minX, tile("c.jpg").frame.minX, "by name first")
        clickMenu("View", "Size")
        eventually("largest first") { tile("z-large.jpg").frame.minX < tile("a.jpg").frame.minX }
    }

    func testSortByDateModifiedNewestFirst() throws {
        let old = tempDir.appendingPathComponent("a.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        launchOnTempDir()
        clickMenu("View", "Date Modified")
        eventually("oldest last") { tile("a.jpg").frame.minX > tile("c.jpg").frame.minX }
    }

    /// The toolbar's sort menu (toolbar items show up more than once in the
    /// tree, so all matches are read).
    private var sortLabel: String {
        app.descendants(matching: .any).matching(identifier: "sortMenu").allElementsBoundByIndex
            .map { "\($0.label) \(($0.value as? String) ?? "") \($0.title)" }.joined(separator: " | ")
    }

    func testSortShortcutsShowInTheToolbar() {
        launchOnTempDir()
        XCTAssertTrue(sortLabel.contains("Name ↑"), "toolbar shows the order: \(sortLabel)")
        app.typeKey("5", modifierFlags: .command)
        eventually("⌘5: size, largest first") { sortLabel.contains("Size ↓") }
        app.typeKey("5", modifierFlags: .command)
        eventually("⌘5 again reverses") { sortLabel.contains("Size ↑") }
        app.typeKey("4", modifierFlags: .command)
        eventually("⌘4: date taken") { sortLabel.contains("Date Taken ↓") }
        XCTAssertEqual(app.windows.count, 1, "the window stays open")
    }

    private func checkRemembered(_ key: String, shortcut: String) {
        launchOnTempDir()
        app.typeKey(XCUIKeyboardKey(rawValue: shortcut), modifierFlags: .command)
        eventually("sorted by \(key)") { sortLabel.contains(key) }
        XCTAssertEqual(app.windows.count, 1, "window before quitting")
        app.terminate()
        launch(resetState: false)
        let shown = app.staticTexts["a.jpg"].waitForExistence(timeout: 15)
        if !shown { print("WINDOWS after relaunch: \(app.windows.count)") }
        XCTAssertTrue(shown, "the last folder reopens")
        XCTAssertTrue(sortLabel.contains(key), "remembered: \(sortLabel)")
    }

    func testSortBySizeIsRemembered() { checkRemembered("Size", shortcut: "5") }
    func testSortByDateTakenIsRemembered() { checkRemembered("Date Taken", shortcut: "4") }

    func testScrollPositionSurvivesTheFullView() throws {
        for i in 10..<90 { try put("sample.jpg", at: "p\(i).jpg") }
        launchOnTempDir()
        app.typeKey(.end, modifierFlags: [])
        waitForSelected("p89.jpg")
        XCTAssertFalse(tile("a.jpg").isHittable, "scrolled down, the top is out of view")
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "p89.jpg")
        app.typeKey(.escape, modifierFlags: [])
        eventually("back at the same place") { tile("p89.jpg").exists && tile("p89.jpg").isHittable }
        XCTAssertFalse(tile("a.jpg").isHittable, "not jumped back to the top")
    }

    func testBackFromASubfolderShowsTheFolderItCameFrom() throws {
        for i in 10..<80 { try folder("f\(i)") }
        launchOnTempDir(waitFor: "f10")
        app.typeKey(.end, modifierFlags: [])                 // c.jpg, the last item
        for _ in 0..<3 { app.typeKey(.leftArrow, modifierFlags: []) }
        waitForSelected("f79")
        app.typeKey(.space, modifierFlags: [])
        eventually("inside f79") { !tile("f79").exists }
        app.typeKey("[", modifierFlags: .command)
        waitForSelected("f79")
        eventually("scrolled to it") { tile("f79").isHittable }
    }

    func testFoldersWithoutPicturesAreGreyedOut() throws {
        try put("sample.jpg", at: "trip/day1/beach.jpg")   // media only deep down
        try folder("junk/inner")
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("junk/Thumbs.db").path, contents: Data())
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("junk/inner/desktop.ini").path, contents: Data())
        launchOnTempDir(waitFor: "junk")
        eventually("junk is greyed out") { text(of: tile("junk")).contains("empty folder") }
        XCTAssertFalse(text(of: tile("trip")).contains("empty"), "pictures further down count")
    }

    func testEmptyFolderState() throws {
        let empty = try folder("empty")
        let app = launch(open: empty.path)
        XCTAssertTrue(app.staticTexts["This folder is empty"].waitForExistence(timeout: 15))
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

    /// ⌘N: a second window, on the same folder at first, that goes its own
    /// way (into a folder) while the first stays where it was; closing it
    /// leaves the first.
    func testANewWindow() throws {
        try folder("sub")
        try put("sample.jpg", at: "sub/x.jpg")
        launchOnTempDir()
        app.typeKey("n", modifierFlags: .command)
        eventually("two windows", timeout: 10) { self.app.windows.count == 2 }
        func tiles(_ name: String, in window: XCUIElement) -> XCUIElement {
            window.descendants(matching: .any).matching(identifier: "tile.\(name)").firstMatch
        }
        // The new window is in front (windows come front to back)
        let second = app.windows.element(boundBy: 0)
        eventually("the new window on the same folder", timeout: 15) { tiles("sub", in: second).exists }
        tiles("sub", in: second).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        eventually("into sub in that window", timeout: 10) { tiles("x.jpg", in: second).exists }
        let first = app.windows.element(boundBy: 1)
        XCTAssertTrue(tiles("sub", in: first).exists, "the first window stays where it was")
        XCTAssertFalse(tiles("x.jpg", in: first).exists)
        app.typeKey("w", modifierFlags: .command)
        eventually("one window again", timeout: 10) { self.app.windows.count == 1 }
        XCTAssertTrue(tiles("a.jpg", in: app.windows.firstMatch).exists)
    }

    /// The boss key in full screen: X leaves full screen (its space would
    /// stay black behind the invisible window) and hides the app. X X X
    /// bringing it back isn't checked here: XCUITest's keys to the hidden app
    /// brought it back in some runs and not in others, on macOS 15 and 26
    /// alike (why is not known).
    func testBossKeyInFullScreen() {
        launchOnTempDir()
        let window = app.windows.firstMatch
        let before = window.frame.size
        app.typeKey("f", modifierFlags: [])
        eventually("window enters full screen", timeout: 10) {
            window.frame.width > before.width || window.frame.height > before.height
        }
        app.typeKey("x", modifierFlags: [])
        // Hidden once out of full screen: its window is gone from the screen
        eventually("hidden", timeout: 10) { !self.app.windows.firstMatch.exists }
    }

    /// L shows the list: whole names in rows; a click anywhere on a column's
    /// header sorts by it (again: the other way), like the sort menu; a double
    /// click opens the picture.
    func testTheListView() throws {
        try put("huge.jpg", at: "d-large.jpg")
        launchOnTempDir()
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(element("list").waitForExistence(timeout: 5))
        XCTAssertTrue(element("row.a.jpg").waitForExistence(timeout: 5))
        element("column.size").firstMatch.click()
        eventually("sorted by size, largest first") { self.sortLabel.contains("Size ↓") }
        element("column.size").firstMatch.click()
        eventually("again: smallest first") { self.sortLabel.contains("Size ↑") }
        // The whole column header takes the click, not only its word
        let kind = element("column.kind").firstMatch
        XCTAssertGreaterThan(kind.frame.width, 80, "as wide as the column")
        kind.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        eventually("by kind, from the column's far end") { self.sortLabel.contains("Kind ↑") }
        let name = element("column.name").firstMatch
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        eventually("by name") { self.sortLabel.contains("Name ↑") }
        element("row.b.jpg").firstMatch.doubleClick()
        eventually("the picture opens", timeout: 15) { self.text(of: self.element("fullImage")).hasSuffix("loaded") }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(tile("a.jpg").waitForExistence(timeout: 5), "tiles again")
    }

    /// ⌘-click marks one more item, ⇧-click the range from the last one,
    /// a plain click unmarks.
    func testCommandAndShiftClicksMark() {
        launchOnTempDir()
        tile("a.jpg").click()
        waitForSelected("a.jpg")
        XCUIElement.perform(withKeyModifiers: .command) { tile("c.jpg").click() }
        eventually("⌘-click marks c.jpg, a.jpg stays") { self.isSelected("c.jpg") && self.isSelected("a.jpg") }
        XCTAssertFalse(isSelected("b.jpg"))
        XCUIElement.perform(withKeyModifiers: .shift) { tile("a.jpg").click() }
        eventually("⇧-click marks the range") { self.isSelected("a.jpg") && self.isSelected("b.jpg") && self.isSelected("c.jpg") }
        tile("b.jpg").click()
        eventually("a plain click unmarks") { !self.isSelected("a.jpg") && !self.isSelected("c.jpg") }
    }

    /// ⌃⌘F is the system's full screen, not ⌘F's search.
    func testControlCommandFEntersFullScreen() {
        launchOnTempDir()
        let window = app.windows.firstMatch
        let before = window.frame.size
        app.typeKey("f", modifierFlags: [.control, .command])
        eventually("window enters full screen", timeout: 10) {
            window.frame.width > before.width || window.frame.height > before.height
        }
        app.typeKey("f", modifierFlags: [.control, .command])
        eventually("window leaves full screen", timeout: 10) { window.frame.size == before }
    }

    /// K slides up the mini keyboard: its keys act when clicked, light up
    /// when typed, change with what's on screen, and it stays after a restart.
    func testTheMiniKeyboard() {
        launchOnTempDir()
        let keyboard = element("miniKeyboard")
        XCTAssertFalse(keyboard.exists)
        app.typeKey("k", modifierFlags: [])
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        waitForSelected("a.jpg")
        element("key.→").firstMatch.click()
        waitForSelected("b.jpg")
        let clicked = text(of: element("key.→").firstMatch)
        XCTAssertEqual(clicked, "pressed 1", "a click lights it up too")
        app.typeKey(.rightArrow, modifierFlags: [])
        eventually("the typed key lights up", timeout: 3) { self.text(of: self.element("key.→").firstMatch) == "pressed 2" }
        XCTAssertTrue(element("key.⌫").exists, "grid keys")
        element("key.space").firstMatch.click()   // opens the picture
        XCTAssertTrue(element("key.+").firstMatch.waitForExistence(timeout: 10), "picture keys")
        XCTAssertFalse(element("key.⌫").exists)
        app.terminate()
        launch(open: tempDir.path, resetState: false)
        XCTAssertTrue(element("miniKeyboard").waitForExistence(timeout: 15), "remembered")
        app.typeKey("k", modifierFlags: [])
        eventually("hidden again") { !self.element("miniKeyboard").exists }
    }

    func testEscapeClosesTheHelp() {
        launchOnTempDir()
        app.typeKey(.F1, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Keyboard Shortcuts"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        eventually("help closes") { !app.staticTexts["Keyboard Shortcuts"].exists }
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
        // Not the Touch Bar's Cancel: the panel's, whatever kind of
        // element holds it
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10), "the open panel appears")
        let all = app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex
        let inPanel = all.first { $0.frame.width > 0 && app.windows.firstMatch.frame.intersects($0.frame) }
        XCTAssertNotNil(inPanel, "the panel's Cancel button: \(all.map(\.frame))")
        inPanel?.click()
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 5))
    }

    /// The app follows the macOS language (here German): the translations
    /// are in the bundle and used.
    func testSpeaksTheSystemLanguage() {
        launch(open: tempDir.path, language: "de")
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Diashow"].firstMatch.waitForExistence(timeout: 5), "the toolbar speaks German")
        eventually("the status bar speaks German") { self.text(of: self.element("statusText")).contains("Bilder") }
    }
}
