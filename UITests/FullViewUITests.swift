import XCTest

/// The full view: paging, zoom, rotation, inspector, slideshow, GIFs.
final class FullViewUITests: SchnellbildUITestCase {
    private var fullImage: XCUIElement { element("fullImage") }

    private func openA() {
        launchOnTempDir()
        app.typeKey(.return, modifierFlags: [])
        waitForBadge(containing: "1 / 3  ·  a.jpg")
    }

    func testOpensImageFileDirectlyInFullView() {
        launch(open: tempDir.appendingPathComponent("b.jpg").path)
        waitForBadge(containing: "2 / 3  ·  b.jpg")
        eventually("the image loads") { value(of: fullImage).hasSuffix("loaded") }
    }

    func testReturnOpensAndEscapeBackspaceReturnLeave() {
        openA()
        app.typeKey(.escape, modifierFlags: [])
        eventually("Escape leaves") { !badge.exists }
        app.typeKey(.return, modifierFlags: [])
        waitForBadge(containing: "a.jpg")
        app.typeKey(.delete, modifierFlags: [])
        eventually("Backspace leaves") { !badge.exists }
        app.typeKey(.return, modifierFlags: [])
        waitForBadge(containing: "a.jpg")
        app.typeKey(.return, modifierFlags: [])
        eventually("Return leaves") { !badge.exists }
        XCTAssertTrue(app.staticTexts["a.jpg"].exists)
    }

    func testOverviewToolbarButtonLeaves() {
        openA()
        app.buttons["Overview"].firstMatch.click()
        eventually("back to the grid") { !badge.exists }
    }

    func testArrowsAndSpacePageThroughImages() {
        openA()
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "2 / 3  ·  b.jpg")
        app.typeKey(.downArrow, modifierFlags: [])
        waitForBadge(containing: "3 / 3  ·  c.jpg")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "3 / 3", timeout: 2)   // clamps at the end
        app.typeKey(.upArrow, modifierFlags: [])
        waitForBadge(containing: "2 / 3")
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForBadge(containing: "1 / 3")
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "2 / 3")
    }

    func testZoomKeys() {
        openA()
        eventually("starts at fit") { value(of: fullImage).hasPrefix("zoom 100 %") }
        app.typeKey("+", modifierFlags: [])
        eventually("+ zooms in") { value(of: fullImage).hasPrefix("zoom 125 %") }
        app.typeKey("=", modifierFlags: .command)
        eventually("⌘+ zooms in") { value(of: fullImage).hasPrefix("zoom 156 %") }
        app.typeKey("-", modifierFlags: [])
        eventually("- zooms out") { value(of: fullImage).hasPrefix("zoom 125 %") }
        app.typeKey("0", modifierFlags: [])
        eventually("0 fits") { value(of: fullImage).hasPrefix("zoom 100 %") }
        app.typeKey("1", modifierFlags: [])
        eventually("1 = actual size (tiny image: stays at fit)") { value(of: fullImage).hasPrefix("zoom 100 %") }
        app.typeKey("+", modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        eventually("paging resets zoom") { value(of: fullImage).hasPrefix("zoom 100 %") }
    }

    func testRotateKeys() {
        openA()
        app.typeKey("]", modifierFlags: [])
        eventually("] rotates right") { value(of: fullImage).contains("rotation 90°") }
        app.typeKey("[", modifierFlags: [])
        app.typeKey("[", modifierFlags: [])
        eventually("[ rotates left") { value(of: fullImage).contains("rotation -90°") }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        eventually("leaving resets rotation") { value(of: fullImage).contains("rotation 0°") }
    }

    func testRotationNeverModifiesTheFile() throws {
        let file = tempDir.appendingPathComponent("a.jpg")
        let before = try Data(contentsOf: file)
        openA()
        app.typeKey("]", modifierFlags: [])
        app.typeKey("+", modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testInspectorShowsFileInfo() {
        openA()
        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Resolution"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["64 × 48 px"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Image"].exists)
        XCTAssertTrue(app.staticTexts["Size"].exists)
        app.typeKey("i", modifierFlags: [])
        eventually("i hides it") { !app.staticTexts["Resolution"].exists }
    }

    func testSlideshowAdvancesAndStops() {
        openA()
        app.typeKey("s", modifierFlags: [])
        waitForBadge(containing: "2 / 3", timeout: 8)
        app.typeKey("s", modifierFlags: [])
        let stoppedAt = text(of: badge)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(text(of: badge), stoppedAt, "slideshow stopped")
    }

    func testAnimatedGIFUsesTheAnimatedView() throws {
        try put("anim.gif", at: "d-anim.gif")
        launch(open: tempDir.appendingPathComponent("d-anim.gif").path)
        waitForBadge(containing: "d-anim.gif")
        XCTAssertTrue(element("animatedImage").waitForExistence(timeout: 5))
        XCTAssertFalse(fullImage.exists)
    }
}
