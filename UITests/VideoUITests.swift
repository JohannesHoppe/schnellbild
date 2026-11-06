import XCTest

/// Video: AVKit for native formats, VLCKit fallback, keyboard control, layout.
final class VideoUITests: SchnellbildUITestCase {
    func testMP4PlaysInAVKitAndSpaceTogglesPause() throws {
        try put("clip.mp4", at: "clip.mp4")
        launch(open: tempDir.appendingPathComponent("clip.mp4").path)
        let video = element("video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        waitForBadge(containing: "clip.mp4")
        XCTAssertFalse(text(of: badge).contains("Paused"), "autoplays")
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        app.typeKey(.space, modifierFlags: [])
        eventually("Space plays again") { !text(of: badge).contains("Paused") }
    }

    func testMKVFallsBackToVLCAndSpaceTogglesPause() throws {
        try put("clip.mkv", at: "clip.mkv")
        launch(open: tempDir.appendingPathComponent("clip.mkv").path)
        let video = element("video.vlc")
        XCTAssertTrue(video.waitForExistence(timeout: 20), "non-native formats use VLCKit")
        waitForBadge(containing: "clip.mkv")
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        app.typeKey(.space, modifierFlags: [])
        eventually("Space resumes VLC playback") { !text(of: badge).contains("Paused") }
    }

    /// → skims through the video in tenths, then moves on; ⌘← pages at once.
    private func checkSkimming(_ clip: String, player: String) throws {
        try put(clip, at: clip)
        try put("sample.jpg", at: "z.jpg")
        launch(open: tempDir.appendingPathComponent(clip).path)
        XCTAssertTrue(element(player).waitForExistence(timeout: 20))
        waitForBadge(containing: clip)
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // length known
        app.typeKey(.rightArrow, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(text(of: badge).contains(clip), "→ skips within the video first")
        for _ in 0..<12 where !text(of: badge).contains("z.jpg") {
            app.typeKey(.rightArrow, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        waitForBadge(containing: "z.jpg")   // past the end: the next item
        app.typeKey(.leftArrow, modifierFlags: .command)
        waitForBadge(containing: clip)
        app.typeKey(.leftArrow, modifierFlags: .command)
        waitForBadge(containing: "c.jpg")   // ⌘← pages straight away
    }

    func testArrowsSkimThroughAnAVKitVideo() throws {
        try checkSkimming("clip.mp4", player: "video.avkit")
    }

    func testArrowsSkimThroughAVLCVideo() throws {
        try checkSkimming("clip.mkv", player: "video.vlc")
    }

    func testBadgeDoesNotCoverThePlayerControls() throws {
        try put("clip.mp4", at: "clip.mp4")
        launch(open: tempDir.appendingPathComponent("clip.mp4").path)
        let video = element("video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        waitForBadge(containing: "clip.mp4")
        XCTAssertLessThan(badge.frame.midY, video.frame.midY,
                          "on videos the badge sits at the top, away from the control bar")
    }

    func testImageBadgeStaysAtTheBottom() {
        launch(open: tempDir.appendingPathComponent("a.jpg").path)
        waitForBadge(containing: "a.jpg")
        let image = element("fullImage")
        XCTAssertGreaterThan(badge.frame.midY, image.frame.midY)
    }
}
