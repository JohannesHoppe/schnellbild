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
        app.menuItems["Rename Folder…"].click()
        enterName("Via Context")
        XCTAssertTrue(app.staticTexts["Via Context"].waitForExistence(timeout: 5))

        clickMenu("Actions", "Rename Folder… (F2)")
        enterName("Via Menu")
        XCTAssertTrue(app.staticTexts["Via Menu"].waitForExistence(timeout: 5))
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

    func testF2OnAnImageDoesNothing() {
        launchOnTempDir(waitFor: "album")
        tile("a.jpg").click()
        waitForSelected("a.jpg")
        app.typeKey(.F2, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(renameField.exists)
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

        app.typeKey(.return, modifierFlags: [])   // enter the renamed folder
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
}
