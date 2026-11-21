import XCTest
import AppKit

/// What macOS draws in a menu for each key the app shows (`KeyGlyphs` keeps
/// the app's own texts to the same glyphs): the Help menu with the test's
/// items of every key (`KeyGlyphsTestMenu`, `--key-glyphs-menu`) and the Go
/// menu are photographed, with the CI workflow's shell (SCREEN_MEASURE=1),
/// into the artifact `measurements-<runner>` (`menu-glyphs-*.png`), and
/// attached to the test's result. XCUITest can't read the glyph a menu draws
/// (no such attribute), so the pictures are the check: look at them on
/// macOS 15 and 26 after a change to `KeyGlyphs`.
final class KeyGlyphsUITests: SchnellbildUITestCase {
    private var osName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macos\(v.majorVersion)"
    }

    private func photograph(_ menu: XCUIElement, as name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(osName)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else { return }
        // The menu with a margin, so its edges show
        // (the whole screen when XCUITest gives the menu no frame)
        let frame = menu.frame.width > 10 ? menu.frame.insetBy(dx: -8, dy: -8)
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
        launch(extra: ["--key-glyphs-menu"])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "a window")

        app.menuBars.menuBarItems["Help"].firstMatch.click()
        let first = app.menuBars.menuItems["glyph left"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the test's items in the Help menu")
        XCTAssertTrue(app.menuBars.menuItems["glyph home alone"].exists)
        photograph(app.menuBars.menuBarItems["Help"].firstMatch.descendants(matching: .menu).firstMatch, as: "menu-glyphs-help")
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["Go"].firstMatch.click()
        XCTAssertTrue(app.menuBars.menuItems["Enclosing Folder"].firstMatch.waitForExistence(timeout: 5), "the Go menu")
        photograph(app.menuBars.menuBarItems["Go"].firstMatch.descendants(matching: .menu).firstMatch, as: "menu-glyphs-go")
        app.typeKey(.escape, modifierFlags: [])
    }
}
