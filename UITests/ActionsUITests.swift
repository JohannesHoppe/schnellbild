import XCTest

/// File actions: rename folder, move to trash.
final class ActionsUITests: SchnellbildUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try put("sample.jpg", at: "album/inside.jpg")
        try folder("taken")
    }

    private var renameField: XCUIElement { app.textFields["renameField"] }

    private func enterName(_ name: String) {
        XCTAssertTrue(renameField.waitForExistence(timeout: 5), "rename sheet appears")
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText(name + "\r")
    }

    func testF2RenamesTheSelectedFolder() {
        launchOnTempDir(waitFor: "album")
        waitForSelected("album")
        app.typeKey(.F2, modifierFlags: [])
        enterName("Holiday")
        XCTAssertTrue(app.staticTexts["Holiday"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["album"].exists)
        waitForSelected("Holiday")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Holiday/inside.jpg").path))
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
        let confirm = app.buttons["Move to Trash"]
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
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.staticTexts["c.jpg"].exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("c.jpg").path))
    }
}
