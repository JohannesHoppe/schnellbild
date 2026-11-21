import XCTest

/// Settings → Keyboard: a key typed into an action's row is that action's
/// key from then on; Schnellbild's key it replaced does nothing, and a key
/// another action holds moves over after asking.
final class ShortcutsUITests: SchnellbildUITestCase {
    /// The Keyboard tab of the Settings window.
    private func openKeyboardSettings() {
        app.typeKey(",", modifierFlags: .command)
        let tab = [app.toolbars.buttons["Keyboard"], app.radioButtons["Keyboard"], app.tabs["Keyboard"]]
        var found: XCUIElement?
        eventually("the Keyboard tab", timeout: 10) {
            found = tab.map(\.firstMatch).first { $0.exists }
            return found != nil
        }
        found?.click()
        XCTAssertTrue(element("shortcuts.list").waitForExistence(timeout: 10), "the actions and their keys")
    }

    func testAKeySetInSettingsIsUsed() {
        launchOnTempDir()
        openKeyboardSettings()

        // L for the list becomes J
        let key = element("shortcut.toggleList.0").firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertEqual(key.label, "L")
        key.click()
        XCTAssertTrue(element("shortcuts.recording").firstMatch.waitForExistence(timeout: 5), "waits for the key")
        app.typeKey("j", modifierFlags: [])
        eventually("J is the key now") { self.element("shortcut.toggleList.0").firstMatch.label == "J" }

        // One more: E, Auto Enhance's key, moves over after asking
        element("shortcut.toggleList.add").firstMatch.click()
        XCTAssertTrue(element("shortcuts.recording").firstMatch.waitForExistence(timeout: 5))
        app.typeKey("e", modifierFlags: [])
        XCTAssertTrue(app.buttons["Reassign"].firstMatch.waitForExistence(timeout: 5), "asks: E is Auto Enhance's")
        // Reassign is the alert's default button (XCUITest's click finds its
        // copy in the Touch Bar, which it can't click)
        app.typeKey(.return, modifierFlags: [])
        eventually("the alert closed") { !self.app.buttons["Reassign"].firstMatch.exists }
        eventually("E is the list's second key") { self.element("shortcut.toggleList.1").firstMatch.label == "E" }
        XCTAssertFalse(element("shortcut.enhance.0").exists, "Auto Enhance lost it")
        app.typeKey("w", modifierFlags: .command)
        eventually("Settings closed") { !self.element("shortcuts.list").exists }

        // In the window: J shows the list, L does nothing, E goes on to the Atlas, then the grid
        app.typeKey("j", modifierFlags: [])
        XCTAssertTrue(element("list").waitForExistence(timeout: 5), "J shows the list")
        app.typeKey("l", modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(element("list").exists, "L does nothing now")
        app.typeKey("e", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 5), "E: the Atlas")
        app.typeKey("e", modifierFlags: [])
        XCTAssertTrue(tile("a.jpg").waitForExistence(timeout: 5), "E: the tiles again")

        // F1 lists the keys as set
        app.typeKey(XCUIKeyboardKey.F1.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["J / E"].firstMatch.waitForExistence(timeout: 5), "the help shows J / E for the list")
        app.typeKey(.escape, modifierFlags: [])

        // Kept: after a new launch J still shows the list
        app.terminate()
        launch(open: tempDir.path, resetState: false)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        app.typeKey("j", modifierFlags: [])
        XCTAssertTrue(element("list").waitForExistence(timeout: 5), "remembered")
    }
}
