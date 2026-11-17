import XCTest

/// Every action that changes the disk, in the App Sandbox as the app ships:
/// between two folders opened to the app one by one through the open panel
/// (A and B, side by side in the dual pane, their common folder not open to
/// it) and on another volume (a disk image CI mounts at
/// `/Volumes/SchnellbildUITests`, opened the same way). Each action is
/// undone and done again from the context menu.
final class FileActionsUITests: SchnellbildUITestCase {
    private var folderA: URL!
    private var folderB: URL!
    private var onVolume: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let volume = URL(fileURLWithPath: "/Volumes/SchnellbildUITests", isDirectory: true)
        guard FileManager.default.fileExists(atPath: volume.path) else {
            throw XCTSkip("no disk image mounted at \(volume.path) (CI mounts one)")
        }
        folderA = try folder("A")
        folderB = try folder("B")
        try put("sample.jpg", at: "A/photo.jpg")
        try put("sample.jpg", at: "A/second.jpg")
        try put("sample.jpg", at: "B/other.jpg")
        onVolume = volume.appendingPathComponent(tempDir.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: onVolume, withIntermediateDirectories: true)
        let source = try XCTUnwrap(Bundle(for: SchnellbildUITestCase.self).url(forResource: "sample", withExtension: "jpg"))
        try FileManager.default.copyItem(at: source, to: onVolume.appendingPathComponent("away.jpg"))
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        if let onVolume { try? FileManager.default.removeItem(at: onVolume) }
    }

    // MARK: Helpers

    private var left: XCUIElement { element("pane.left") }
    private var right: XCUIElement { element("pane.right") }

    private func tile(_ name: String, in pane: XCUIElement) -> XCUIElement {
        pane.descendants(matching: .any).matching(identifier: "tile.\(name)").firstMatch
    }

    private func exists(_ url: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    /// A on the left, `other` on the right, each opened through the open
    /// panel; the left pane active.
    private func openPanes(right other: URL, showing shown: String) {
        launch(grants: .none)
        XCTAssertTrue(app.staticTexts["No folder open"].waitForExistence(timeout: 15))
        grantThroughOpenPanel(folderA)
        XCTAssertTrue(app.staticTexts["photo.jpg"].waitForExistence(timeout: 15), "A opened")
        app.typeKey("d", modifierFlags: [])
        XCTAssertTrue(right.waitForExistence(timeout: 10), "two panes")
        app.typeKey(.tab, modifierFlags: [])
        grantThroughOpenPanel(other)
        XCTAssertTrue(tile(shown, in: right).waitForExistence(timeout: 15), "\(other.lastPathComponent) opened on the right")
        app.typeKey(.tab, modifierFlags: [])
    }

    /// Selects a tile (its pane becomes the active one).
    private func select(_ name: String, in pane: XCUIElement) {
        let item = tile(name, in: pane)
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(name) there")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        eventually("\(name) selected") { self.text(of: item).hasPrefix("selected") }
    }

    /// An item of a tile's context menu (the Actions menu has some of the same names).
    private func contextMenu(_ title: String, on name: String, in pane: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        let item = tile(name, in: pane)
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(name) there", file: file, line: line)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        var found: XCUIElement?
        eventually("the context menu has \(title)", timeout: 5, file: file, line: line) {
            found = self.app.menuItems.allElementsBoundByIndex.first { $0.title == title && $0.isHittable && $0.isEnabled }
            return found != nil
        }
        found?.click()
    }

    private func rename(_ name: String, in pane: XCUIElement, to base: String) {
        select(name, in: pane)
        app.typeKey(.F2, modifierFlags: [])
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the rename sheet")
        field.typeText(base)   // replaces the selected base name
        field.typeKey(.return, modifierFlags: [])
        eventually("the rename sheet closes") { !field.exists }
    }

    private func trash(_ name: String, in pane: XCUIElement) {
        select(name, in: pane)
        app.typeKey(.delete, modifierFlags: .command)
        let confirm = app.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks first")
        confirm.click()
    }

    // MARK: The actions

    /// Rename in a granted folder and on another volume, each undone and done again.
    func testRenameWithUndoAndRedo() throws {
        openPanes(right: onVolume, showing: "away.jpg")
        rename("photo.jpg", in: left, to: "renamed")
        eventually("renamed in A") { self.exists(self.folderA, "renamed.jpg") && !self.exists(self.folderA, "photo.jpg") }
        contextMenu("Undo Rename", on: "renamed.jpg", in: left)
        eventually("undone") { self.exists(self.folderA, "photo.jpg") && !self.exists(self.folderA, "renamed.jpg") }
        contextMenu("Redo Rename", on: "photo.jpg", in: left)
        eventually("done again") { self.exists(self.folderA, "renamed.jpg") }

        rename("away.jpg", in: right, to: "far")
        eventually("renamed on the volume") { self.exists(self.onVolume, "far.jpg") && !self.exists(self.onVolume, "away.jpg") }
        contextMenu("Undo Rename", on: "far.jpg", in: right)
        eventually("undone on the volume") { self.exists(self.onVolume, "away.jpg") && !self.exists(self.onVolume, "far.jpg") }
        contextMenu("Redo Rename", on: "away.jpg", in: right)
        eventually("done again on the volume") { self.exists(self.onVolume, "far.jpg") }
    }

    /// Move (F6) from A into B, two folders granted one by one, then onto
    /// another volume (a copy and the original removed); each undone and
    /// done again.
    func testMoveWithUndoAndRedo() throws {
        openPanes(right: folderB, showing: "other.jpg")
        select("photo.jpg", in: left)
        app.typeKey(.F6, modifierFlags: [])
        eventually("moved into B") { self.exists(self.folderB, "photo.jpg") && !self.exists(self.folderA, "photo.jpg") }
        XCTAssertTrue(tile("photo.jpg", in: right).waitForExistence(timeout: 10))
        contextMenu("Undo Move", on: "other.jpg", in: right)
        eventually("back in A") { self.exists(self.folderA, "photo.jpg") && !self.exists(self.folderB, "photo.jpg") }
        contextMenu("Redo Move", on: "other.jpg", in: right)
        eventually("in B again") { self.exists(self.folderB, "photo.jpg") && !self.exists(self.folderA, "photo.jpg") }

        app.typeKey(.tab, modifierFlags: [])
        grantThroughOpenPanel(onVolume)
        XCTAssertTrue(tile("away.jpg", in: right).waitForExistence(timeout: 15))
        select("second.jpg", in: left)
        app.typeKey(.F6, modifierFlags: [])
        eventually("moved to the volume") { self.exists(self.onVolume, "second.jpg") && !self.exists(self.folderA, "second.jpg") }
        contextMenu("Undo Move", on: "away.jpg", in: right)
        eventually("back in A from the volume") { self.exists(self.folderA, "second.jpg") && !self.exists(self.onVolume, "second.jpg") }
        contextMenu("Redo Move", on: "away.jpg", in: right)
        eventually("on the volume again") { self.exists(self.onVolume, "second.jpg") && !self.exists(self.folderA, "second.jpg") }
    }

    /// Copy (F5) from A into B and onto another volume, each undone and done again.
    func testCopyWithUndoAndRedo() throws {
        openPanes(right: folderB, showing: "other.jpg")
        select("photo.jpg", in: left)
        app.typeKey(.F5, modifierFlags: [])
        eventually("copied into B") { self.exists(self.folderB, "photo.jpg") && self.exists(self.folderA, "photo.jpg") }
        contextMenu("Undo Copy", on: "other.jpg", in: right)
        eventually("the copy gone") { !self.exists(self.folderB, "photo.jpg") && self.exists(self.folderA, "photo.jpg") }
        contextMenu("Redo Copy", on: "other.jpg", in: right)
        eventually("copied again") { self.exists(self.folderB, "photo.jpg") }

        app.typeKey(.tab, modifierFlags: [])
        grantThroughOpenPanel(onVolume)
        XCTAssertTrue(tile("away.jpg", in: right).waitForExistence(timeout: 15))
        select("second.jpg", in: left)
        app.typeKey(.F5, modifierFlags: [])
        eventually("copied to the volume") { self.exists(self.onVolume, "second.jpg") && self.exists(self.folderA, "second.jpg") }
        contextMenu("Undo Copy", on: "away.jpg", in: right)
        eventually("the copy on the volume gone") { !self.exists(self.onVolume, "second.jpg") }
        contextMenu("Redo Copy", on: "away.jpg", in: right)
        eventually("copied to the volume again") { self.exists(self.onVolume, "second.jpg") }
    }

    /// A new folder (⇧⌘N) in a granted folder and on another volume.
    func testNewFolder() throws {
        openPanes(right: onVolume, showing: "away.jpg")
        select("photo.jpg", in: left)
        app.typeKey("n", modifierFlags: [.command, .shift])
        let field = app.textFields["newFolderField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Sorted\r")
        XCTAssertTrue(tile("Sorted", in: left).waitForExistence(timeout: 10))
        XCTAssertTrue(exists(folderA, "Sorted"))

        select("away.jpg", in: right)
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Kept\r")
        XCTAssertTrue(tile("Kept", in: right).waitForExistence(timeout: 10))
        XCTAssertTrue(exists(onVolume, "Kept"))
    }

    /// Move to Trash in a granted folder (the Mac's Trash) and on another
    /// volume (its own Trash), each undone (out of the Trash) and done again.
    func testMoveToTrashWithUndoAndRedo() throws {
        openPanes(right: onVolume, showing: "away.jpg")
        trash("photo.jpg", in: left)
        eventually("in the Trash") { !self.exists(self.folderA, "photo.jpg") }
        contextMenu("Undo Move to Trash", on: "second.jpg", in: left)
        eventually("back from the Trash") { self.exists(self.folderA, "photo.jpg") }
        contextMenu("Redo Move to Trash", on: "second.jpg", in: left)
        eventually("in the Trash again") { !self.exists(self.folderA, "photo.jpg") }

        try FileManager.default.copyItem(at: onVolume.appendingPathComponent("away.jpg"), to: onVolume.appendingPathComponent("stays.jpg"))
        XCTAssertTrue(tile("stays.jpg", in: right).waitForExistence(timeout: 15), "seen by the pane")
        trash("away.jpg", in: right)
        eventually("in the volume's Trash") { !self.exists(self.onVolume, "away.jpg") }
        contextMenu("Undo Move to Trash", on: "stays.jpg", in: right)
        eventually("back from the volume's Trash") { self.exists(self.onVolume, "away.jpg") }
        contextMenu("Redo Move to Trash", on: "stays.jpg", in: right)
        eventually("in the volume's Trash again") { !self.exists(self.onVolume, "away.jpg") }
    }
}
