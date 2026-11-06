import XCTest
import AppKit

/// What the screen really shows, measured: brightness of photos and videos
/// (both players), auto enhance and the sliders, and broken files.
///
/// The test runner may not record the screen, so the CI shell does it
/// (`.github/workflows/ci.yml`): the test puts "measure:<id>:<x>,<y>,<w>,<h>"
/// (screen points) on the pasteboard, the shell captures that region with
/// `screencapture` and answers "measured:<id>:<mean luminance>". Without the
/// shell (SCREEN_MEASURE unset) the measuring tests are skipped.
final class VisualUITests: SchnellbildUITestCase {

    /// Mean luminance (0 … 1) of the middle half of an element, as on screen.
    private func screenBrightness(of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else {
            throw XCTSkip("needs the screen-measuring shell of the CI workflow")
        }
        let f = element.frame
        let region = CGRect(x: f.midX - f.width / 4, y: f.midY - f.height / 4, width: f.width / 2, height: f.height / 2)
        let id = UUID().uuidString.prefix(8)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("measure:\(id):\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
                             forType: .string)
        var answer: Double?
        eventually("the screen was measured", timeout: 30, file: file, line: line) {
            guard let text = pasteboard.string(forType: .string), text.hasPrefix("measured:\(id):") else { return false }
            answer = Double(text.dropFirst("measured:\(id):".count))
            return true
        }
        return try XCTUnwrap(answer, file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval = 2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Opens a fixture video, with VLC when `vlc`; returns the player view.
    private func openVideo(_ fixture: String, vlc: Bool) throws -> XCUIElement {
        try put(fixture, at: fixture)
        launch(open: tempDir.appendingPathComponent(fixture).path, extra: vlc ? ["--force-vlc"] : [])
        let video = element(vlc ? "video.vlc" : "video.avkit")
        guard video.waitForExistence(timeout: 20) else {
            XCTFail("no \(vlc ? "VLC" : "AVKit") player for \(fixture); the window holds:\n\(app.debugDescription)")
            throw XCTSkip("no player")
        }
        waitForBadge(containing: fixture)
        settle()
        return video
    }

    // MARK: Videos show at full brightness

    /// The grey test clip (about 0.54) is shown as bright as it is from the
    /// start, and stays so when clicked or hovered.
    private func checkFullBrightness(vlc: Bool) throws {
        let video = try openVideo(vlc ? "clip.mkv" : "clip.mp4", vlc: vlc)
        let start = try screenBrightness(of: video)
        XCTAssertGreaterThan(start, 0.45, "shown dimmed from the start: \(start)")
        video.click()
        settle()
        let clicked = try screenBrightness(of: video)
        XCTAssertEqual(clicked, start, accuracy: 0.04, "a click changes the brightness: \(start) → \(clicked)")
        video.hover()
        settle(3)
        let hovered = try screenBrightness(of: video)
        XCTAssertEqual(hovered, start, accuracy: 0.04, "hovering changes the brightness: \(start) → \(hovered)")
    }

    func testAVKitVideoIsShownAtFullBrightness() throws { try checkFullBrightness(vlc: false) }
    func testVLCVideoIsShownAtFullBrightness() throws { try checkFullBrightness(vlc: true) }

    // MARK: Auto enhance and sliders on videos

    private func checkAutoEnhance(_ fixture: String, vlc: Bool, brighter: Bool) throws {
        let video = try openVideo(fixture, vlc: vlc)
        let before = try screenBrightness(of: video)
        app.typeKey("e", modifierFlags: [])
        waitForBadge(containing: "Enhanced")
        settle(3)   // measured once a second, then gliding
        let after = try screenBrightness(of: video)
        if brighter {
            XCTAssertGreaterThan(after, before + 0.12, "\(fixture) not brightened: \(before) → \(after)")
        } else {
            XCTAssertLessThan(after, before - 0.1, "\(fixture) not darkened: \(before) → \(after)")
        }
        app.typeKey("e", modifierFlags: [])
        settle()
        let off = try screenBrightness(of: video)
        XCTAssertEqual(off, before, accuracy: 0.04, "off shows the file as it is again: \(before) → \(off)")
    }

    func testAutoEnhanceBrightensADarkVideoInAVKit() throws { try checkAutoEnhance("dark.mp4", vlc: false, brighter: true) }
    func testAutoEnhanceBrightensADarkVideoInVLC() throws { try checkAutoEnhance("dark.mp4", vlc: true, brighter: true) }
    func testAutoEnhanceDarkensAnOverexposedVideoInAVKit() throws { try checkAutoEnhance("bright.mp4", vlc: false, brighter: false) }
    func testAutoEnhanceDarkensAnOverexposedVideoInVLC() throws { try checkAutoEnhance("bright.mp4", vlc: true, brighter: false) }

    private func checkExposureSlider(vlc: Bool) throws {
        let video = try openVideo("clip.mp4", vlc: vlc)
        let before = try screenBrightness(of: video)
        app.typeKey("a", modifierFlags: [])
        let slider = element("slider.exposure").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.9)
        waitForBadge(containing: "Adjusted")
        app.typeKey("a", modifierFlags: [])   // the popover would cover part of the picture
        settle()
        let after = try screenBrightness(of: video)
        XCTAssertGreaterThan(after, before + 0.12, "the exposure slider does nothing: \(before) → \(after)")
    }

    func testExposureSliderBrightensAnAVKitVideo() throws { try checkExposureSlider(vlc: false) }
    func testExposureSliderBrightensAVLCVideo() throws { try checkExposureSlider(vlc: true) }

    // MARK: Photos

    private func checkAutoEnhancePhoto(_ fixture: String, brighter: Bool) throws {
        try put(fixture, at: fixture)
        launch(open: tempDir.appendingPathComponent(fixture).path)
        let image = element("fullImage")
        eventually("the image loads", timeout: 15) { text(of: image).hasSuffix("loaded") }
        settle()
        let before = try screenBrightness(of: image)
        app.typeKey("e", modifierFlags: [])
        eventually("enhanced", timeout: 15) { text(of: image).contains("enhanced") }
        settle(1)
        let after = try screenBrightness(of: image)
        if brighter {
            XCTAssertGreaterThan(after, before + 0.12, "\(fixture) not brightened: \(before) → \(after)")
        } else {
            XCTAssertLessThan(after, before - 0.1, "\(fixture) not darkened: \(before) → \(after)")
        }
    }

    func testAutoEnhanceBrightensADarkPhoto() throws { try checkAutoEnhancePhoto("dark.jpg", brighter: true) }
    func testAutoEnhanceDarkensAnOverexposedPhoto() throws { try checkAutoEnhancePhoto("bright.jpg", brighter: false) }

    // MARK: Broken files

    /// Files with a media extension but garbage inside: the grid and the
    /// full view show them without the app going down.
    func testBrokenFilesDoNotTakeTheAppDown() throws {
        for name in ["broken.jpg", "broken.mp4", "broken.mkv"] { try put(name, at: name) }
        launchOnTempDir(waitFor: "broken.mkv")
        settle(3)   // thumbnails tried
        for name in ["broken.jpg", "broken.mp4", "broken.mkv"] {
            tile(name).click()
            waitForSelected(name)
            app.typeKey(.return, modifierFlags: [])
            waitForBadge(containing: name)
            settle(3)
            XCTAssertEqual(app.state, .runningForeground, "still running after opening \(name)")
            app.typeKey(.escape, modifierFlags: [])
            eventually("back in the grid") { self.tile("a.jpg").exists }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
