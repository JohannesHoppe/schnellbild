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
        eventually("the image loads") { text(of: fullImage).hasSuffix("loaded") }
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
        eventually("starts at fit") { text(of: fullImage).hasPrefix("zoom 100 %") }
        app.typeKey("+", modifierFlags: [])
        eventually("+ zooms in") { text(of: fullImage).hasPrefix("zoom 125 %") }
        app.typeKey("=", modifierFlags: .command)
        eventually("⌘+ zooms in") { text(of: fullImage).hasPrefix("zoom 156 %") }
        app.typeKey("-", modifierFlags: [])
        eventually("- zooms out") { text(of: fullImage).hasPrefix("zoom 125 %") }
        app.typeKey("0", modifierFlags: [])
        eventually("0 fits") { text(of: fullImage).hasPrefix("zoom 100 %") }
        app.typeKey("1", modifierFlags: [])
        eventually("1 = actual size (tiny image: stays at fit)") { text(of: fullImage).hasPrefix("zoom 100 %") }
        app.typeKey("+", modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        eventually("paging resets zoom") { text(of: fullImage).hasPrefix("zoom 100 %") }
    }

    func testRotateKeys() {
        openA()
        app.typeKey("]", modifierFlags: [])
        eventually("] rotates right") { text(of: fullImage).contains("rotation 90°") }
        app.typeKey("[", modifierFlags: [])
        app.typeKey("[", modifierFlags: [])
        eventually("[ rotates left") { text(of: fullImage).contains("rotation -90°") }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        eventually("leaving resets rotation") { text(of: fullImage).contains("rotation 0°") }
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

    func testEnhanceIsAFilterThatStaysOnWhilePaging() throws {
        openA()
        let image = element("fullImage")
        eventually("loaded") { text(of: image).contains("loaded") }
        app.typeKey("e", modifierFlags: [])
        eventually("enhanced") { text(of: image).contains("enhanced") }
        waitForBadge(containing: "Enhanced")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "b.jpg")
        eventually("still on for the next picture") { text(of: image).contains("enhanced") }
        element("enhanceButton").firstMatch.click()   // a toggle, not a plain button
        eventually("off again") { !text(of: badge).contains("Enhanced") && !text(of: image).contains("enhanced") }
    }

    func testSlideshowAdvancesAndStops() {
        openA()
        app.typeKey("s", modifierFlags: [])
        waitForBadge(containing: "Slideshow")
        waitForBadge(containing: "2 / 3", timeout: 8)
        app.typeKey(.escape, modifierFlags: [])
        eventually("slideshow ended") { !text(of: badge).contains("Slideshow") }
    }

    func testSlideshowButtonPlaysTheFolderAndSubfolders() throws {
        try put("sample.jpg", at: "sub/d.jpg")
        launchOnTempDir()
        toolbarButton("slideshowButton").click()
        waitForBadge(containing: "Slideshow")
        waitForBadge(containing: "/ 4  ·")   // the subfolder walked ("/ 3+" until then)
        XCTAssertFalse(searchField.exists, "nothing but the pictures")
        waitForBadge(containing: "d.jpg", timeout: 15)   // reaches the subfolder
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["sub"].waitForExistence(timeout: 10), "back to the grid")
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
    }

    func testAnimatedGIFUsesTheAnimatedView() throws {
        try put("anim.gif", at: "d-anim.gif")
        launch(open: tempDir.appendingPathComponent("d-anim.gif").path)
        waitForBadge(containing: "d-anim.gif")
        XCTAssertTrue(element("animatedImage").waitForExistence(timeout: 5))
        XCTAssertFalse(fullImage.exists)
    }

    /// Zoomed in, a photo larger than the screen is shown at its full
    /// resolution, not as a stretched screen-size copy.
    func testZoomingInDecodesTheFullPicture() throws {
        try put("huge.jpg", at: "huge.jpg")
        launch(open: tempDir.appendingPathComponent("huge.jpg").path)
        let image = element("fullImage")
        eventually("loaded at screen size", timeout: 15) {
            self.text(of: image).hasSuffix("loaded") && !self.text(of: image).contains("decoded 4000 px")
        }
        app.typeKey("+", modifierFlags: [])
        eventually("decoded at full size", timeout: 15) { self.text(of: image).contains("decoded 4000 px") }
    }

    /// "1" shows a photo larger than the window at its pixels: zoomed in.
    func testOneShowsALargePhotoAtItsPixels() throws {
        try put("huge.jpg", at: "huge.jpg")
        launch(open: tempDir.appendingPathComponent("huge.jpg").path)
        let image = element("fullImage")
        eventually("loaded", timeout: 15) { self.text(of: image).hasSuffix("loaded") }
        app.typeKey("1", modifierFlags: [])
        eventually("zoomed to 100 %, well past fit") {
            let label = self.text(of: image)
            guard let range = label.range(of: "zoom ") else { return false }
            return (Int(label[range.upperBound...].prefix { $0.isNumber }) ?? 0) > 150
        }
    }
}
