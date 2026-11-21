import XCTest
import AppKit

/// What macOS draws in a menu for each key the app shows (`KeyGlyphs` keeps
/// the app's own texts to the same glyphs): the Help menu with the test's
/// items of every key (`KeyGlyphsTestMenu`, `--key-glyphs-menu`) and the Go
/// menu are photographed, then the app's own keys beside them: F1's list
/// and the mini keyboard, a cap per key. With the CI workflow's shell
/// (SCREEN_MEASURE=1) the pictures go into the artifact
/// `measurements-<runner>` (`menu-glyphs-*.png`, `key-caps-*.png`), and each
/// is attached to the test's result. XCUITest can't read the glyph a menu
/// draws (no such attribute), so the pictures are the check: look at them on
/// macOS 15 and 26 after a change to `KeyGlyphs` or `KeyCapsView`.
final class KeyGlyphsUITests: SchnellbildUITestCase {
    private var osName: String {
        "macos\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    }

    private func photograph(_ element: XCUIElement, as name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(osName)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else { return }
        // With a margin, so the edges show (the whole screen when XCUITest
        // gives the element no frame)
        let frame = element.frame.width > 10 ? element.frame.insetBy(dx: -8, dy: -8)
            : (NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1024, height: 768))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("shot:\(name)-\(osName):\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
                             forType: .string)
        eventually("\(name) photographed", timeout: 30) {
            pasteboard.string(forType: .string) == "shot-done:\(name)-\(osName)"
        }
    }

    func testMenusShowTheSystemsKeyGlyphs() {
        launch(open: tempDir.path, extra: ["--key-glyphs-menu"])
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15), "the grid")

        app.menuBars.menuBarItems["Help"].firstMatch.click()
        XCTAssertTrue(app.menuBars.menuItems["glyph left"].firstMatch.waitForExistence(timeout: 5), "the test's items in the Help menu")
        XCTAssertTrue(app.menuBars.menuItems["glyph delete alone"].exists)
        photograph(app.menuBars.menuBarItems["Help"].firstMatch.descendants(matching: .menu).firstMatch, as: "menu-glyphs-help")
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["Go"].firstMatch.click()
        XCTAssertTrue(app.menuBars.menuItems["Enclosing Folder"].firstMatch.waitForExistence(timeout: 5), "the Go menu")
        photograph(app.menuBars.menuBarItems["Go"].firstMatch.descendants(matching: .menu).firstMatch, as: "menu-glyphs-go")
        app.typeKey(.escape, modifierFlags: [])

    }

    /// The app's own keys as caps: F1's list and the mini keyboard, light
    /// and dark (`key-caps-help-light-*.png` …).
    func testTheAppsOwnKeysAreCaps() {
        for appearance in ["light", "dark"] {
            launch(open: tempDir.path, extra: ["--appearance=\(appearance)"])
            XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15), "the grid")
            app.typeKey(.F1, modifierFlags: [])
            XCTAssertTrue(app.buttons["printCheatSheet"].firstMatch.waitForExistence(timeout: 5), "the help")
            photograph(app.windows.firstMatch, as: "key-caps-help-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            eventually("the help closes") { !self.app.buttons["printCheatSheet"].firstMatch.exists }
            app.typeKey("k", modifierFlags: [])
            XCTAssertTrue(element("miniKeyboard").waitForExistence(timeout: 5), "the mini keyboard")
            photograph(app.windows.firstMatch, as: "key-caps-mini-keyboard-\(appearance)")
            app.terminate()
        }
    }
}
