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

    func testCommandArrowsSeekWithoutPaging() throws {
        try put("clip.mp4", at: "clip.mp4")
        launch(open: tempDir.appendingPathComponent("clip.mp4").path)
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 15))
        waitForBadge(containing: "clip.mp4")
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(text(of: badge).contains("clip.mp4"), "⌘←/⌘→ seek instead of paging")
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForBadge(containing: "c.jpg")   // plain arrows still page
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
