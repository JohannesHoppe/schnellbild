import XCTest
import AppKit
import AVFoundation

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

    /// The badge shows how far the video has played, in both players.
    private func checkProgressBar(vlc: Bool) throws {
        try put("clip.mp4", at: "clip.mp4")
        launch(open: tempDir.appendingPathComponent("clip.mp4").path, extra: vlc ? ["--force-vlc"] : [])
        let bar = element("videoProgress")
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        func percent() -> Int { Int(text(of: bar).filter(\.isNumber)) ?? -1 }
        eventually("moves on while playing", timeout: 15) { percent() > 10 }
        XCTAssertLessThanOrEqual(percent(), 100)
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        let paused = percent()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertLessThanOrEqual(abs(percent() - paused), 2, "stands while paused")
    }

    func testTheProgressBarFollowsAnAVKitVideo() throws { try checkProgressBar(vlc: false) }
    func testTheProgressBarFollowsAVLCVideo() throws { try checkProgressBar(vlc: true) }

    /// AVKit's floating controls stay where they were dragged, also for the
    /// next video.
    func testTheControlBarKeepsItsPlaceFromVideoToVideo() throws {
        // Named to follow each other (the folder holds pictures too)
        try put("clip.mp4", at: "zz1.mp4")
        try put("clip.mp4", at: "zz2.mp4")
        launch(open: tempDir.appendingPathComponent("zz1.mp4").path)
        let video = element("video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        waitForBadge(containing: "zz1.mp4")
        app.typeKey(.space, modifierFlags: [])   // paused: the controls stay up
        waitForBadge(containing: "Paused")
        // AVKit's play button is a check box "play/pause" inside the player view
        func playButton() -> XCUIElement { video.checkBoxes["play/pause"].firstMatch }
        video.hover()
        let button = playButton()
        guard button.waitForExistence(timeout: 10) else {
            XCTFail("no play/pause button; the player's elements: \(video.debugDescription)")
            return
        }
        let before = button.frame
        // Grab the bar left of its buttons (no control there) and drag it up
        let grab = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -100, dy: 0))
        grab.press(forDuration: 0.3, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: -150)))
        video.hover()
        let dragged = playButton().frame
        print("control bar: \(before) → dragged \(dragged)")
        XCTAssertLessThan(dragged.midY, before.midY - 100, "the bar moved up")
        app.typeKey(.rightArrow, modifierFlags: .command)   // the next video
        waitForBadge(containing: "zz2.mp4")
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        video.hover()
        let next = playButton()
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        print("control bar on the next video: \(next.frame)")
        XCTAssertEqual(next.frame.midY, dragged.midY, accuracy: 4, "kept for the next video")
    }

    /// ↓ / ↑ on a video set the volume, shown a moment; remembered across launches.
    func testUpAndDownSetTheVolume() throws {
        try put("clip.mp4", at: "clip.mp4")
        let path = tempDir.appendingPathComponent("clip.mp4").path
        launch(open: path, extra: ["--hold-volume-display"])
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 20))
        app.typeKey(.downArrow, modifierFlags: [])
        let display = element("volumeDisplay")
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: display).contains("90 %"), text(of: display))
        waitForBadge(containing: "clip.mp4")   // still the video, not the next item
        app.terminate()
        launch(open: path, resetState: false, extra: ["--hold-volume-display"])
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 20))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element("volumeDisplay").waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: element("volumeDisplay")).contains("80 %"), "remembered: \(text(of: element("volumeDisplay")))")
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

    /// The Inspector shows a video's resolution, from either player (VLC
    /// through `--force-vlc`, so AVFoundation can tell the test the size).
    private func checkInspectorResolution(vlc: Bool) throws {
        try put("clip.mp4", at: "clip.mp4")
        let url = tempDir.appendingPathComponent("clip.mp4")
        launch(open: url.path, extra: vlc ? ["--force-vlc"] : [])
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").waitForExistence(timeout: 20))
        let size = try XCTUnwrap(Self.videoSize(of: url))
        let expected = "\(Int(size.width)) × \(Int(size.height)) px"
        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Resolution"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 10), "the Inspector shows \(expected)")
    }

    /// The video's size as AVFoundation reads it (waits for it).
    private static func videoSize(of url: URL) -> CGSize? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var size: CGSize?
        Task.detached {
            if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first {
                size = try? await track.load(.naturalSize)
            }
            done.signal()
        }
        done.wait()
        return size
    }

    func testInspectorShowsAnAVKitVideosResolution() throws { try checkInspectorResolution(vlc: false) }
    func testInspectorShowsAVLCVideosResolution() throws { try checkInspectorResolution(vlc: true) }

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

    /// Videos QuickLook can't read get their tile picture from VLC.
    func testMKVTileShowsAFrame() throws {
        try put("clip.mkv", at: "clip.mkv")
        launchOnTempDir(waitFor: "clip.mkv")
        eventually("a picture, not the file icon", timeout: 20) { self.text(of: self.tile("clip.mkv")).hasSuffix(", preview") }
    }

    /// At the end of a video Space plays it again from the start, every
    /// time: it takes the whole clip to end again. The app logs the
    /// player's states (shown when it fails).
    private func checkSpaceAtTheEndPlaysAgain(vlc: Bool) throws {
        try put("dark.mp4", at: "short.mp4")   // three seconds
        let log = tempDir.appendingPathComponent("test.log")
        launch(open: tempDir.appendingPathComponent("short.mp4").path,
               extra: (vlc ? ["--force-vlc"] : []) + ["--test-log=\(log.path)"])
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").waitForExistence(timeout: 20))
        continueAfterFailure = true
        defer { print("player log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        waitForBadge(containing: "Paused", timeout: 20)   // it ended
        for round in 1...3 {
            app.typeKey(.space, modifierFlags: [])
            let start = Date()
            eventually("plays again (round \(round))") { !self.text(of: self.badge).contains("Paused") }
            waitForBadge(containing: "Paused", timeout: 20)   // it ended again
            XCTAssertGreaterThan(Date().timeIntervalSince(start), 2, "round \(round) played from the start")
        }
    }

    /// The slideshow moves on once a video has played to its end, with
    /// either player.
    private func checkSlideshowMovesOnAfterAVideo(vlc: Bool) throws {
        try put("dark.mp4", at: "show/v1.mp4")   // three seconds each
        try put("bright.mp4", at: "show/v2.mp4")
        let log = tempDir.appendingPathComponent("app.log")
        launch(open: tempDir.appendingPathComponent("show").path,
               extra: (vlc ? ["--force-vlc"] : []) + ["--test-log=\(log.path)"])
        XCTAssertTrue(tile("v1.mp4").waitForExistence(timeout: 15))
        app.typeKey("s", modifierFlags: [])
        waitForBadge(containing: "v1.mp4", timeout: 20)
        let deadline = Date().addingTimeInterval(20)
        while !text(of: badge).contains("v2.mp4"), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        if !text(of: badge).contains("v2.mp4") {
            XCTFail("the slideshow stayed on “\(text(of: badge))”; app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "none"))
        }
    }

    func testSlideshowMovesOnAfterAnAVKitVideo() throws { try checkSlideshowMovesOnAfterAVideo(vlc: false) }
    func testSlideshowMovesOnAfterAVLCVideo() throws { try checkSlideshowMovesOnAfterAVideo(vlc: true) }

    func testSpaceAtTheEndPlaysAnAVKitVideoAgain() throws { try checkSpaceAtTheEndPlaysAgain(vlc: false) }
    func testSpaceAtTheEndPlaysAVLCVideoAgain() throws { try checkSpaceAtTheEndPlaysAgain(vlc: true) }

    func testVideosZoomLikePictures() throws {
        try put("clip.mp4", at: "clip.mp4")
        launch(open: tempDir.appendingPathComponent("clip.mp4").path)
        let video = element("video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        app.typeKey("+", modifierFlags: [])
        app.typeKey("+", modifierFlags: [])
        eventually("zoomed") { text(of: video).contains("zoom 156 %") }
        app.typeKey("0", modifierFlags: [])
        eventually("fit again") { text(of: video).contains("zoom 100 %") }
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
