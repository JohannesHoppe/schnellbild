import XCTest

/// Undo and Redo of every file action, end to end with the real Trash:
/// Edit → Undo / Redo, ⌘Z / ⇧⌘Z and the context menu.
final class UndoUITests: SchnellbildUITestCase {
    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(path).path)
    }

    /// Gone from disk and from the grid, or back on both.
    private func waitFor(_ name: String, present: Bool, _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        eventually("\(name): \(what)", timeout: 15, file: file, line: line) {
            self.exists(name) == present && self.tile(name).exists == present
        }
    }

    /// The Edit menu's item at the top: its title and whether it can be chosen.
    private func editItem(_ index: Int) -> (title: String, enabled: Bool) {
        app.menuBars.menuBarItems["Edit"].firstMatch.click()
        let item = app.menuBars.menuBarItems["Edit"].firstMatch.menuItems.element(boundBy: index)
        let result = (item.title, item.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        return result
    }

    private func clickEdit(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(editItem(title.hasPrefix("Undo") ? 0 : 1).title, title, "Edit menu", file: file, line: line)
        clickMenu("Edit", title)
    }

    private func confirmTrash() {
        let confirm = app.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks before trashing")
        confirm.click()
    }

    private func contextMenuItem(_ tileName: String, _ title: String) throws -> XCUIElement {
        tile(tileName).rightClick()
        // The Actions menu has items of the same names: the one on screen
        let item = app.menuItems.allElementsBoundByIndex.first { $0.title == title && $0.isHittable }
        return try XCTUnwrap(item, "the context menu of \(tileName) shows \(title)")
    }

    /// Johannes' case: a folder, right-click, Move to Trash; then Undo by
    /// ⌘Z and from the Edit menu, Redo both ways, and from the context menu.
    func testAFolderTrashedFromItsContextMenuIsUndoneAndRedone() throws {
        try put("sample.jpg", at: "Album/x.jpg")
        launchOnTempDir(waitFor: "Album")
        XCTAssertEqual(editItem(0).title, "Undo")
        XCTAssertFalse(editItem(0).enabled, "nothing to undo yet")

        try contextMenuItem("Album", "Move to Trash…").click()
        confirmTrash()
        waitFor("Album", present: false, "in the Trash")
        XCTAssertEqual(editItem(0).title, "Undo Move to Trash")
        XCTAssertTrue(editItem(0).enabled)

        app.typeKey("z", modifierFlags: .command)
        waitFor("Album", present: true, "⌘Z takes it out of the Trash")
        XCTAssertTrue(exists("Album/x.jpg"), "with what it holds")
        app.typeKey("z", modifierFlags: [.command, .shift])
        waitFor("Album", present: false, "⇧⌘Z: in the Trash again")
        clickEdit("Undo Move to Trash")
        waitFor("Album", present: true, "Edit → Undo")
        clickEdit("Redo Move to Trash")
        waitFor("Album", present: false, "Edit → Redo")

        try contextMenuItem("a.jpg", "Undo Move to Trash").click()
        waitFor("Album", present: true, "the context menu's Undo")
        try contextMenuItem("a.jpg", "Redo Move to Trash").click()
        waitFor("Album", present: false, "the context menu's Redo")
        app.typeKey("z", modifierFlags: .command)
        waitFor("Album", present: true, "back for good")
        XCTAssertTrue(exists("Album/x.jpg"))
        XCTAssertFalse(app.buttons["Forget"].firstMatch.exists || app.buttons["OK"].firstMatch.exists, "no failure reported")
    }

    /// A single file (⌘⌫) and a marked set: all of it back with one Undo.
    func testAFileAndAMarkedSetAreUndoneAndRedone() throws {
        launchOnTempDir()
        tile("c.jpg").click()
        waitForSelected("c.jpg")
        app.typeKey(.delete, modifierFlags: .command)
        confirmTrash()
        waitFor("c.jpg", present: false, "in the Trash")
        app.typeKey("z", modifierFlags: .command)
        waitFor("c.jpg", present: true, "⌘Z")
        clickEdit("Redo Move to Trash")
        waitFor("c.jpg", present: false, "Edit → Redo")
        clickEdit("Undo Move to Trash")
        waitFor("c.jpg", present: true, "Edit → Undo")

        tile("a.jpg").click()
        waitForSelected("a.jpg")
        app.typeKey(.rightArrow, modifierFlags: .shift)
        eventually("b.jpg marked too") { self.isSelected("b.jpg") }
        app.typeKey(.delete, modifierFlags: .command)
        confirmTrash()
        waitFor("a.jpg", present: false, "marked: in the Trash")
        waitFor("b.jpg", present: false, "marked: in the Trash")
        XCTAssertTrue(exists("c.jpg"), "only the marked ones")
        app.typeKey("z", modifierFlags: .command)
        waitFor("a.jpg", present: true, "one ⌘Z brings back the set")
        waitFor("b.jpg", present: true, "one ⌘Z brings back the set")
        app.typeKey("z", modifierFlags: [.command, .shift])
        waitFor("a.jpg", present: false, "⇧⌘Z")
        waitFor("b.jpg", present: false, "⇧⌘Z")
        clickEdit("Undo Move to Trash")
        waitFor("a.jpg", present: true, "Edit → Undo")
        waitFor("b.jpg", present: true, "Edit → Undo")
    }

    /// A split RAR archive goes to the Trash with all its parts and comes back with all of them.
    func testAnArchiveWithAllItsPartsIsUndoneAndRedone() throws {
        let parts = (1...4).map { "photos-vols.part\($0).rar" }
        for part in parts { try put(part, at: part) }
        launchOnTempDir(waitFor: parts[0])
        tile(parts[0]).click()
        waitForSelected(parts[0])
        app.typeKey(.delete, modifierFlags: .command)
        confirmTrash()
        eventually("every part in the Trash", timeout: 15) { parts.allSatisfy { !self.exists($0) } }
        clickEdit("Undo Move to Trash")
        eventually("every part back", timeout: 15) { parts.allSatisfy { self.exists($0) } }
        XCTAssertTrue(tile(parts[0]).waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [.command, .shift])
        eventually("every part in the Trash again", timeout: 15) { parts.allSatisfy { !self.exists($0) } }
        app.typeKey("z", modifierFlags: .command)
        eventually("every part back again", timeout: 15) { parts.allSatisfy { self.exists($0) } }
    }

    private var renameField: XCUIElement { app.textFields["renameField"] }

    /// Rename, New Folder and a move into a folder (a tile dragged onto it).
    func testRenameNewFolderAndMoveAreUndoneAndRedone() throws {
        launchOnTempDir()
        tile("a.jpg").click()
        waitForSelected("a.jpg")
        app.typeKey(.F2, modifierFlags: [])
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("renamed.jpg\r")
        waitFor("renamed.jpg", present: true, "renamed")
        app.typeKey("z", modifierFlags: .command)
        waitFor("a.jpg", present: true, "Undo Rename")
        XCTAssertFalse(exists("renamed.jpg"))
        clickEdit("Redo Rename")
        waitFor("renamed.jpg", present: true, "Redo Rename")
        clickEdit("Undo Rename")
        waitFor("a.jpg", present: true, "Undo Rename again")

        app.typeKey("n", modifierFlags: [.command, .shift])
        let field = app.textFields["newFolderField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Sorted\r")
        waitFor("Sorted", present: true, "made")
        clickEdit("Undo New Folder")
        waitFor("Sorted", present: false, "Undo New Folder")
        app.typeKey("z", modifierFlags: [.command, .shift])
        waitFor("Sorted", present: true, "Redo New Folder")

        tile("b.jpg").press(forDuration: 0.6, thenDragTo: tile("Sorted"))
        eventually("b.jpg went into the folder", timeout: 10) { self.exists("Sorted/b.jpg") && !self.tile("b.jpg").exists }
        app.typeKey("z", modifierFlags: .command)
        waitFor("b.jpg", present: true, "Undo Move")
        XCTAssertFalse(exists("Sorted/b.jpg"))
        clickEdit("Redo Move")
        eventually("Redo Move", timeout: 10) { self.exists("Sorted/b.jpg") && !self.exists("b.jpg") }
        try contextMenuItem("a.jpg", "Undo Move").click()
        waitFor("b.jpg", present: true, "the context menu's Undo Move")
    }

    /// F5 into the other pane's folder, undone (the copy to the Trash) and redone.
    func testACopyToTheOtherPaneIsUndoneAndRedone() throws {
        try folder("Sorted")
        launchOnTempDir()
        app.typeKey("d", modifierFlags: [])
        let left = element("pane.left"), right = element("pane.right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), "two panes")
        let rightSorted = right.descendants(matching: .any).matching(identifier: "tile.Sorted").firstMatch
        XCTAssertTrue(rightSorted.waitForExistence(timeout: 15))
        rightSorted.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        eventually("Sorted selected in the right pane") { self.text(of: rightSorted).hasPrefix("selected") }
        app.typeKey(.space, modifierFlags: [])
        eventually("inside Sorted in the right pane") { !rightSorted.exists }

        let leftA = left.descendants(matching: .any).matching(identifier: "tile.a.jpg").firstMatch
        leftA.click()
        eventually("a.jpg selected on the left") { self.text(of: leftA).hasPrefix("selected") }
        app.typeKey(.F5, modifierFlags: [])
        let rightA = right.descendants(matching: .any).matching(identifier: "tile.a.jpg").firstMatch
        XCTAssertTrue(rightA.waitForExistence(timeout: 10), "copied into the other pane")
        XCTAssertEqual(editItem(0).title, "Undo Copy")
        app.typeKey("z", modifierFlags: .command)
        eventually("the copy went to the Trash", timeout: 15) { !self.exists("Sorted/a.jpg") && !rightA.exists }
        XCTAssertTrue(exists("a.jpg"), "the original stays")
        clickEdit("Redo Copy")
        eventually("copied again", timeout: 15) { self.exists("Sorted/a.jpg") && rightA.exists }
        clickEdit("Undo Copy")
        eventually("the copy went to the Trash again", timeout: 15) { !self.exists("Sorted/a.jpg") }
        XCTAssertTrue(exists("a.jpg"))
    }

    /// ⌘Z while typing in the search field is the field's: the file action stays.
    func testCommandZWhileTypingStaysInTheField() throws {
        launchOnTempDir()
        tile("c.jpg").click()
        waitForSelected("c.jpg")
        app.typeKey(.delete, modifierFlags: .command)
        confirmTrash()
        waitFor("c.jpg", present: false, "in the Trash")
        search("zz")
        app.typeKey("z", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(exists("c.jpg"), "⌘Z in the search field didn't take the file out of the Trash")
        XCTAssertNotEqual(text(of: searchField), "zz", "it undid the typing")
    }
}
