import XCTest
import AppKit

/// The About window shows every license in full: Schnellbild's MIT License on
/// top, then a section per project; the list beside the text jumps there,
/// ⌘F finds in it. With the CI workflow's shell (SCREEN_MEASURE=1, see
/// ScreenMeasure.swift) the window is photographed in light and dark mode
/// into the artifact `measurements-<runner>` (about-*.png).
final class AboutUITests: SchnellbildUITestCase {
    private var aboutWindow: XCUIElement { app.windows["About Schnellbild"].firstMatch }
    private var licenseText: XCUIElement { aboutWindow.textViews["aboutLicenseText"].firstMatch }
    private var licenseScroll: XCUIElement { aboutWindow.scrollViews["aboutLicenseScroll"].firstMatch }

    /// Where the text's top lies with the view at the top (the scroll view
    /// reaches a little above the text's own top; 20 points on CI).
    private var topOffset: CGFloat = 0
    /// How far the license text is scrolled, in points: its top above the
    /// top of the view it scrolls in, from where it starts.
    private var scrolled: CGFloat { licenseScroll.frame.minY - licenseText.frame.minY - topOffset }

    private func openAbout(appearance: String) {
        launch(extra: ["--appearance=\(appearance)"])
        clickMenu("Schnellbild", "About Schnellbild")
        XCTAssertTrue(aboutWindow.waitForExistence(timeout: 10), "the About window")
        XCTAssertTrue(licenseText.waitForExistence(timeout: 10), "the license text")
        topOffset = licenseScroll.frame.minY - licenseText.frame.minY
        XCTAssertLessThan(abs(topOffset), 40, "the text starts at the top of its view")
    }

    /// A section of the text, by its id, in the list beside it.
    private func choose(_ section: String) {
        let row = aboutWindow.descendants(matching: .any)["aboutSection.\(section)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(section) in the list")
        row.click()
    }

    /// Asks the workflow's shell to photograph the About window (the test
    /// runner may not record the screen); without it, nothing.
    private func photograph(_ name: String) {
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let frame = aboutWindow.frame
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("shot:\(name):\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
                             forType: .string)
        eventually("\(name) photographed", timeout: 30) {
            pasteboard.string(forType: .string) == "shot-done:\(name)"
        }
    }

    func testEveryLicenseIsShownInFull() throws {
        openAbout(appearance: "light")
        let text = (licenseText.value as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("Schnellbild\n"), String(text.prefix(200)))
        // Schnellbild's own license first, in full
        let mit = try XCTUnwrap(text.range(of: "Permission is hereby granted, free of charge"), "the MIT License")
        let lgpl = try XCTUnwrap(text.range(of: "GNU LESSER GENERAL PUBLIC LICENSE"), "VLCKit's license")
        XCTAssertLessThan(mit.lowerBound, lgpl.lowerBound)
        for part in ["LGPL-only build of VLCKit", "UnRAR source code may be used in any software",
                     "Alliance for Open Media", "Open Database License", "CC0 1.0 Universal", "Joshua Stevens"] {
            XCTAssertTrue(text.contains(part), part)
        }
        photograph("about-light")

        // The list jumps to a project's section
        choose("unrar")
        eventually("scrolled to UnRAR") { self.scrolled > 2000 }
        let atUnRAR = scrolled
        photograph("about-unrar-light")
        choose("vlckit")
        eventually("scrolled to VLCKit") { self.scrolled > 100 && self.scrolled < atUnRAR }
        photograph("about-vlckit-light")

        // ⌘↑ goes back to the top
        // A click into the text's left margin (no link there) gives it the keys
        licenseScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
        aboutWindow.typeKey(.upArrow, modifierFlags: .command)
        eventually("back at the top") { abs(self.scrolled) < 5 }

        // ⌘F finds in the text: the Black Marble credit, after UnRAR
        aboutWindow.typeKey("f", modifierFlags: .command)
        let find = aboutWindow.searchFields.firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5), "the find bar")
        find.typeText("Joshua Stevens\r")
        eventually("found near the end") { self.scrolled > atUnRAR }
    }

    func testTheWindowInDarkMode() throws {
        openAbout(appearance: "dark")
        photograph("about-dark")
        choose("vlckit")
        eventually("scrolled to VLCKit") { self.scrolled > 100 }
        photograph("about-vlckit-dark")
    }
}
