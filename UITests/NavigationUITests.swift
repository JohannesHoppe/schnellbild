import XCTest

/// Folder navigation: enter, up (button, Backspace, ⌘↑, ".."), back/forward history.
final class NavigationUITests: SchnellbildUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try put("sample.jpg", at: "album/inside.jpg")
    }

    func testReturnEntersFolderAndParentTileGoesUp() {
        launchOnTempDir(waitFor: "album")
        waitForSelected("album")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        tile("..").doubleClick()
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 10))
        waitForSelected("album")
    }

    func testBackspaceGoesUpOneFolder() {
        let app = launch(open: tempDir.appendingPathComponent("album").path)
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 15))
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["album"].waitForExistence(timeout: 10))
    }

    func testUpButtonAndCommandUp() {
        let app = launch(open: tempDir.appendingPathComponent("album").path)
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 15))
        app.buttons["upButton"].click()
        XCTAssertTrue(app.staticTexts["album"].waitForExistence(timeout: 10))

        app.typeKey(.return, modifierFlags: [])   // back into album (selected)
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 10))
    }

    func testBackAndForwardButtons() {
        launchOnTempDir(waitFor: "album")
        XCTAssertFalse(app.buttons["backButton"].isEnabled)
        XCTAssertFalse(app.buttons["forwardButton"].isEnabled)

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        eventually("back enabled") { app.buttons["backButton"].isEnabled }

        app.buttons["backButton"].click()
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 10))
        waitForSelected("album")
        eventually("forward enabled") { app.buttons["forwardButton"].isEnabled }

        app.buttons["forwardButton"].click()
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
    }

    func testCommandBracketsNavigateHistory() {
        launchOnTempDir(waitFor: "album")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 10))
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
    }

    func testGoMenu() {
        launchOnTempDir(waitFor: "album")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        clickMenu("Go", "Back")
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 10))
        clickMenu("Go", "Forward")
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 10))
        clickMenu("Go", "Enclosing Folder")
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 10))
    }
}
