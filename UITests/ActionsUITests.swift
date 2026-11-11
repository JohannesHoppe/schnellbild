import XCTest

/// File actions: rename folder, move to trash.
final class ActionsUITests: SchnellbildUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try put("sample.jpg", at: "album/inside.jpg")
        try folder("taken")
    }

    private var renameField: XCUIElement { app.textFields["renameField"] }

    private func enterName(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(renameField.waitForExistence(timeout: 5), "rename sheet appears", file: file, line: line)
        renameField.click()
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeKey(.delete, modifierFlags: [])
        renameField.typeText(name)
        XCTAssertEqual(text(of: renameField), name, "rename field holds the new name", file: file, line: line)
        renameField.typeKey(.return, modifierFlags: [])
    }

    func testF2RenamesTheSelectedFolder() {
        launchOnTempDir(waitFor: "album")
        waitForSelected("album")
        app.typeKey(.F2, modifierFlags: [])
        enterName("Holiday")
        eventually("renamed on disk") {
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Holiday/inside.jpg").path)
        }
        eventually("rename sheet closes") { !renameField.exists }
        XCTAssertTrue(app.staticTexts["Holiday"].waitForExistence(timeout: 5))
        eventually("old name is gone") { !app.staticTexts["album"].exists }
        waitForSelected("Holiday")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Holiday/inside.jpg").path))
    }

    func testF1InRenameSheetDoesNotBlockTheGrid() {
        launchOnTempDir(waitFor: "album")
        waitForSelected("album")
        app.typeKey(.F2, modifierFlags: [])
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        app.typeKey(.F1, modifierFlags: [])
        app.buttons["Cancel"].firstMatch.click()
        eventually("sheet closes") { !renameField.exists }
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForSelected("taken")
    }

    func testRenameFromContextMenuAndActionsMenu() {
        launchOnTempDir(waitFor: "album")
        tile("album").rightClick()
        app.menuItems["Rename…"].click()
        enterName("Via Context")
        XCTAssertTrue(app.staticTexts["Via Context"].waitForExistence(timeout: 5))

        clickMenu("Actions", "Rename… (F2)")
        enterName("Via Menu")
        XCTAssertTrue(app.staticTexts["Via Menu"].waitForExistence(timeout: 5))
    }

    /// The context menu acts on the tile it was opened on, not on the
    /// selected one: trashing the wrong file would lose data.
    func testContextMenuTrashesTheTileItWasOpenedOn() throws {
        launchOnTempDir(waitFor: "album")
        tile("a.jpg").click()
        waitForSelected("a.jpg")
        tile("c.jpg").rightClick()
        // The Actions menu has an item of the same name: the one on screen
        let item = app.menuItems.allElementsBoundByIndex.first { $0.title == "Move to Trash…" && $0.isHittable }
        try XCTUnwrap(item, "the context menu shows Move to Trash…").click()
        let confirm = app.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        eventually("c.jpg is gone") { !self.app.staticTexts["c.jpg"].exists }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("c.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("a.jpg").path),
                      "the selected a.jpg stays")
    }

    /// "Start Slideshow of This Folder" on a folder tile plays that folder, not the one shown.
    func testContextMenuPlaysTheFoldersSlideshow() throws {
        try put("sample.jpg", at: "album/second.jpg")
        launchOnTempDir(waitFor: "album")
        tile("a.jpg").click()
        waitForSelected("a.jpg")
        tile("album").rightClick()
        let item = app.menuItems["Start Slideshow of This Folder"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the folder's context menu")
        item.click()
        waitForBadge(containing: "Slideshow")
        eventually("only the folder's pictures") { self.text(of: self.badge).contains("/ 2") }
        XCTAssertFalse(text(of: badge).contains("a.jpg"))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRenameRejectsExistingNameAndCancelKeepsIt() {
        launchOnTempDir(waitFor: "album")
        waitForSelected("album")
        app.typeKey(.F2, modifierFlags: [])
        enterName("taken")
        XCTAssertTrue(app.staticTexts["renameError"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: app.staticTexts["renameError"]).contains("already exists"))
        app.buttons["Cancel"].click()
        eventually("sheet closes") { !renameField.exists }
        XCTAssertTrue(app.staticTexts["album"].exists)
    }

    func testF2RenamesAFileKeepingItsExtension() {
        launchOnTempDir(waitFor: "album")
        tile("a.jpg").click()
        waitForSelected("a.jpg")
        app.typeKey(.F2, modifierFlags: [])
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.typeText("Sunrise")   // replaces the selected base name only
        XCTAssertEqual(text(of: renameField), "Sunrise.jpg")
        renameField.typeKey(.return, modifierFlags: [])
        eventually("renamed on disk") {
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Sunrise.jpg").path)
        }
        waitForSelected("Sunrise.jpg")
    }

    /// Return in the rename sheet renames once. The text field and the
    /// default button can both react to Return; the second confirmation must
    /// not rename again (it would work on the old name and fail, or move a
    /// case-only rename twice). The app logs each confirmation and each
    /// rename it runs.
    func testReturnInTheRenameSheetRenamesOnce() throws {
        let log = tempDir.appendingPathComponent("test.log")
        launch(open: tempDir.path, extra: ["--test-log=\(log.path)"])
        XCTAssertTrue(app.staticTexts["album"].waitForExistence(timeout: 15))
        waitForSelected("album")
        app.typeKey(.F2, modifierFlags: [])
        enterName("Album")   // case only, the trickiest rename; confirmed with Return
        eventually("rename sheet closes") { !self.renameField.exists }
        XCTAssertFalse(app.staticTexts["renameError"].exists, "no error on the way out")
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // a late second confirmation
        let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        print("rename log: \(lines)")
        XCTAssertEqual(lines.filter { $0.hasPrefix("rename album") }.count, 1, "renamed exactly once: \(lines)")
        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(names.contains("Album"), "\(names)")
        XCTAssertFalse(names.contains("album"), "\(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix(".rename-") }, "no half-done rename left: \(names)")
    }

    func testF6InTheFullViewRenamesTheFileShown() {
        launchOnTempDir(waitFor: "album")
        tile("b.jpg").doubleClick()
        waitForBadge(containing: "b.jpg")
        app.typeKey(.F6, modifierFlags: [])   // Norton Commander's rename
        enterName("Harbour.jpg")
        waitForBadge(containing: "Harbour.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Harbour.jpg").path))
    }

    func testCommandBackspaceMovesToTrash() {
        launchOnTempDir(waitFor: "album")
        tile("c.jpg").click()
        waitForSelected("c.jpg")
        app.typeKey(.delete, modifierFlags: .command)
        let confirm = app.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "⌘⌫ asks before trashing")
        confirm.click()
        eventually("tile disappears") { !app.staticTexts["c.jpg"].exists }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("c.jpg").path))
        XCTAssertTrue(app.staticTexts["album"].exists, "⌘⌫ didn't navigate up")
    }

    /// The dialog keeps its keys: Return confirms, Esc cancels (the app's
    /// own key handling stays out of it).
    func testTrashDialogAnswersReturnAndEscape() {
        launchOnTempDir(waitFor: "album")
        tile("c.jpg").click()
        waitForSelected("c.jpg")
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(app.buttons["Move to Trash"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        eventually("Esc cancels") { !self.app.buttons["Move to Trash"].firstMatch.exists }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("c.jpg").path))
        XCTAssertTrue(isSelected("c.jpg"), "still in the grid, nothing opened")

        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(app.buttons["Move to Trash"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        eventually("Return confirms") { !self.app.staticTexts["c.jpg"].exists }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("c.jpg").path))
        XCTAssertFalse(app.descendants(matching: .any)["fullImage"].exists, "Return didn't open anything")
    }

    func testTrashCancelKeepsTheFile() {
        launchOnTempDir(waitFor: "album")
        tile("c.jpg").click()
        waitForSelected("c.jpg")
        clickMenu("Actions", "Move to Trash…")
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.staticTexts["c.jpg"].exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("c.jpg").path))
    }

    // MARK: Rename while searching

    private func searchAlbum() {
        search("album")
        XCTAssertTrue(app.staticTexts["album-photo.jpg"].waitForExistence(timeout: 10))
        waitForSelected("album")
    }

    func testRenameASearchResultKeepsTheResultsAndBackShowsThem() throws {
        try put("sample.jpg", at: "album/album-photo.jpg")
        launchOnTempDir(waitFor: "album")
        searchAlbum()

        app.typeKey(.F2, modifierFlags: [])   // works straight from the search field
        enterName("Holiday")
        XCTAssertTrue(app.staticTexts["Holiday"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["album-photo.jpg"].exists, "results stay")
        XCTAssertTrue(app.staticTexts["Holiday"].exists)
        XCTAssertEqual(text(of: searchField), "album", "query stays")
        waitForSelected("Holiday")
        XCTAssertFalse(app.staticTexts["taken"].exists, "still the search results, not the folder")

        app.typeKey(.space, modifierFlags: [])   // enter the renamed folder
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        toolbarButton("backButton").click()
        XCTAssertTrue(app.staticTexts["album-photo.jpg"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Holiday"].exists, "the rename shows in the restored search")
        XCTAssertEqual(text(of: searchField), "album")
        waitForSelected("Holiday")
    }

    func testRenameInsideAResultFolderStaysThereAndBackWorks() throws {
        try folder("album/sub")
        launchOnTempDir(waitFor: "album")
        searchField.click()
        searchField.typeText("album")
        XCTAssertTrue(app.staticTexts["album"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])   // open the result
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        waitForSelected("sub")

        app.typeKey(.F2, modifierFlags: [])
        enterName("sub2")
        XCTAssertTrue(app.staticTexts["sub2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["inside.jpg"].exists, "still inside the result folder")
        waitForSelected("sub2")

        toolbarButton("backButton").click()
        XCTAssertTrue(app.staticTexts["album"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["inside.jpg"].exists)
        XCTAssertEqual(text(of: searchField), "album")
        waitForSelected("album")
    }

    /// ⇧⌘N, a name, ↩: a folder; Esc instead: none. Then a tile dragged
    /// onto it goes into it.
    func testNewFolderAndDraggingIntoIt() throws {
        launchOnTempDir()
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tempDir.path))
        app.typeKey("n", modifierFlags: [.command, .shift])
        let field = app.textFields["newFolderField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        eventually("closed") { !field.exists }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: tempDir.path)), before, "Esc: no folder made")

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Sorted\r")
        let folder = tile("Sorted")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        waitForSelected("Sorted")

        tile("b.jpg").press(forDuration: 0.6, thenDragTo: folder)
        eventually("b.jpg went into the folder", timeout: 10) { !self.tile("b.jpg").exists }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Sorted/b.jpg").path))
        folder.doubleClick()
        XCTAssertTrue(tile("b.jpg").waitForExistence(timeout: 10), "inside the folder")
    }

    /// The divider between the panes: dragged, the left pane grows; a
    /// double click shares the window equally again.
    func testThePaneDivider() throws {
        launch(open: tempDir.path)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        app.typeKey("d", modifierFlags: [])
        let left = element("pane.left"), right = element("pane.right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), "two panes")
        let divider = element("paneDivider")
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        eventually("equal at first") { abs(left.frame.width - right.frame.width) < 20 }
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 150, dy: 0)))
        eventually("the left pane wider") { left.frame.width - right.frame.width > 200 }
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        eventually("equal again") { abs(left.frame.width - right.frame.width) < 20 }
    }

    /// "Open in Other Pane" from the left pane's grid into the right pane's
    /// list, back and forth: the rows stay rows (seen once: rows 325 pt
    /// apart without their name, as if laid out by the grid's large tiles).
    func testOpenInOtherPaneKeepsTheListsRows() throws {
        for folderName in ["One", "Two"] {
            for i in 0..<30 { try put("sample.jpg", at: "\(folderName)/\(folderName.lowercased())\(i).jpg") }
        }
        launch(open: tempDir.path)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        // Large tiles in both panes (the size is the window's)
        for _ in 0..<6 { app.typeKey("=", modifierFlags: .command) }
        app.typeKey("d", modifierFlags: [])
        let left = element("pane.left"), right = element("pane.right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), "two panes")
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(right.descendants(matching: .any).matching(identifier: "list").firstMatch.waitForExistence(timeout: 10))
        app.typeKey(.tab, modifierFlags: [])

        func row(_ name: String) -> XCUIElement { right.descendants(matching: .any).matching(identifier: "row.\(name)").firstMatch }
        for round in 0..<6 {
            let name = round % 2 == 0 ? "One" : "Two", stem = name.lowercased()
            let tile = left.descendants(matching: .any).matching(identifier: "tile.\(name)").firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 10))
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            let item = app.menuItems["Open in Other Pane"]
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.click()
            XCTAssertTrue(row("\(stem)0.jpg").waitForExistence(timeout: 10), "round \(round): \(name) in the list")
            // Rows a row apart, each a row high (also after the list settles)
            for check in 0..<2 {
                let frames = (0..<4).map { row("\(stem)\($0).jpg").frame }
                let report = "round \(round), check \(check): " + frames.map { "\(Int($0.minY))/\(Int($0.height))" }.joined(separator: " ")
                print(report)
                for (a, b) in zip(frames, frames.dropFirst()) {
                    XCTAssertLessThan(b.minY - a.minY, 60, report)
                }
                for frame in frames {
                    XCTAssertLessThan(frame.height, 60, report)
                    XCTAssertGreaterThan(frame.width, 400, "the row spans the list: " + report)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            // Back up in the right pane, so the next round opens anew
            app.typeKey(.tab, modifierFlags: [])
            app.typeKey(.upArrow, modifierFlags: .command)
            app.typeKey(.tab, modifierFlags: [])
        }
    }

    /// D opens the dual pane (the button shows it on); Tab switches; F5
    /// copies the marked items into the other pane's folder; dragging a tile
    /// into the other pane moves it there; D closes it again.
    func testTheDualPane() throws {
        try folder("Sorted")
        // Where each key went (printed when D doesn't close the pane)
        let log = tempDir.appendingPathComponent("keys.log")
        launch(open: tempDir.path, extra: ["--test-log=\(log.path)"])
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        app.typeKey("d", modifierFlags: [])
        let left = element("pane.left"), right = element("pane.right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), "two panes")
        // The right pane opens on the same folder: into "Sorted" there
        let rightSorted = right.descendants(matching: .any).matching(identifier: "tile.Sorted").firstMatch
        XCTAssertTrue(rightSorted.waitForExistence(timeout: 15))
        // By its place on screen: on macOS 26 the tile of a pane added next
        // to the first one reports itself as not hittable
        rightSorted.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        XCTAssertTrue(right.descendants(matching: .any).matching(identifier: "tile...").firstMatch.waitForExistence(timeout: 10))

        // Left: a.jpg and b.jpg marked (⇧→; a ⌘-click lands a row off here,
        // the grid's accessibility frames lag behind its scrolling), F5
        let leftA = left.descendants(matching: .any).matching(identifier: "tile.a.jpg").firstMatch
        leftA.click()
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey(.F5, modifierFlags: [])
        let rightA = right.descendants(matching: .any).matching(identifier: "tile.a.jpg").firstMatch
        XCTAssertTrue(rightA.waitForExistence(timeout: 10), "copied into the other pane")
        XCTAssertTrue(right.descendants(matching: .any).matching(identifier: "tile.b.jpg").firstMatch.exists, "b too")
        XCTAssertTrue(leftA.exists, "a copy: still on the left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Sorted/b.jpg").path))

        // c.jpg dragged into the right pane: moved
        let leftC = left.descendants(matching: .any).matching(identifier: "tile.c.jpg").firstMatch
        leftC.press(forDuration: 0.6, thenDragTo: right)
        eventually("moved into the right pane", timeout: 10) {
            right.descendants(matching: .any).matching(identifier: "tile.c.jpg").firstMatch.exists && !leftC.exists
        }

        app.typeKey("d", modifierFlags: [])
        let closed = Date()
        let deadline = Date().addingTimeInterval(10)
        while element("pane.right").exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        // Printed before the check, so a failing run says where D went
        print("closed after \(String(format: "%.1f", Date().timeIntervalSince(closed))) s; key log:\n"
              + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)"))
        XCTAssertFalse(element("pane.right").exists, "one pane again")
    }

    /// A click on the folder's name in the title bar renames the folder shown.
    func testRenamingTheFolderShownFromItsTitle() throws {
        try put("sample.jpg", at: "Trip/x.jpg")
        launch(open: tempDir.appendingPathComponent("Trip").path)
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15))
        let title = element("folderTitle").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the folder's name in the title bar")
        title.click()
        let field = app.textFields["folderTitleField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "an editable name")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Iceland\r")
        eventually("renamed on disk", timeout: 10) {
            FileManager.default.fileExists(atPath: self.tempDir.appendingPathComponent("Iceland/x.jpg").path)
        }
        XCTAssertTrue(tile("x.jpg").exists, "still in the folder, under its new name")
    }
}
