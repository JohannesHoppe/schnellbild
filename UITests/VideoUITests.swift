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

    // MARK: Subtitles, audio tracks, speed

    /// The tracks of a video with two of each (`tracks.mp4`: mov_text in
    /// AVKit; `tracks.mkv`: SubRip and ASS in VLC): the defaults on, ⌃⌘S and
    /// V switch the subtitles, ⌃⌘A the sound, > the speed, which the badge
    /// shows and the video plays at.
    private func checkTracksAndSpeed(_ fixture: String, vlc: Bool) throws {
        try put(fixture, at: fixture)
        launch(open: tempDir.appendingPathComponent(fixture).path, extra: (vlc ? ["--force-vlc"] : []) + ["--hold-video-bar"])
        let video = element(vlc ? "video.vlc" : "video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        eventually("the tracks are known, the defaults on", timeout: 20) {
            text(of: video).contains("audio 1/2 en, subtitles 1/2 en")
        }
        // Twice as fast: the position moves on about twice as fast (early,
        // so the 20 s video doesn't end meanwhile)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))   // VLC opens it again to draw subtitles
        for _ in 0..<4 { app.typeKey(">", modifierFlags: []) }
        eventually("2×") { text(of: video).contains("speed 2.0") }
        waitForBadge(containing: "2×")
        let progress = element("videoProgress")
        func percent() -> Int { Int(text(of: progress).filter(\.isNumber)) ?? -1 }
        let before = percent(), start = Date()
        RunLoop.current.run(until: start.addingTimeInterval(3))
        let played = Double(percent() - before) / 100 * 20   // seconds of the 20 s video (its subtitles end with it)
        let took = Date().timeIntervalSince(start)
        print("\(vlc ? "VLC" : "AVKit") at 2×: \(played) s of video in \(took) s")
        XCTAssertGreaterThan(played, took * 1.5, "plays faster than 1×")
        app.typeKey("\\", modifierFlags: .command)
        eventually("⌘\\: normal speed") { text(of: video).contains("speed 1.0") }
        XCTAssertFalse(text(of: badge).contains("×"), "at 1× the badge shows no speed: \(text(of: badge))")
        app.typeKey("s", modifierFlags: [.control, .command])
        eventually("⌃⌘S: the German subtitles") { text(of: video).contains("subtitles 2/2 de") }
        app.typeKey("v", modifierFlags: [])
        eventually("V: none") { text(of: video).contains("subtitles off/2") }
        app.typeKey("v", modifierFlags: [])
        eventually("V again: the German ones, the language chosen") { text(of: video).contains("subtitles 2/2 de") }
        app.typeKey("a", modifierFlags: [.control, .command])
        eventually("⌃⌘A: the German sound") { text(of: video).contains("audio 2/2 de") }
        // The control bar lists them
        video.hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5), "the control bar shows on the mouse moving")
        XCTAssertTrue(element("videoBar.subtitles").exists)
        XCTAssertTrue(element("videoBar.audio").exists)
        // The next launch starts with the choices: German subtitles and sound
        app.terminate()
        launch(open: tempDir.appendingPathComponent(fixture).path, resetState: false, extra: vlc ? ["--force-vlc"] : [])
        let again = element(vlc ? "video.vlc" : "video.avkit")
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        eventually("remembered", timeout: 20) { text(of: again).contains("audio 2/2 de, subtitles 2/2 de, speed 1.0") }
    }

    func testTracksAndSpeedInAVKit() throws { try checkTracksAndSpeed("tracks.mp4", vlc: false) }
    func testTracksAndSpeedInVLC() throws { try checkTracksAndSpeed("tracks.mkv", vlc: true) }
    func testMovTextTracksInVLC() throws { try checkTracksAndSpeed("tracks.mp4", vlc: true) }

    // MARK: The control bar

    /// The control bar (both players) is dragged by its grip; the next
    /// video and the next launch have it there; a double click on the grip
    /// puts it back at the bottom middle.
    private func checkControlBarStays(vlc: Bool) throws {
        try put("clip.mp4", at: "a-clip.mp4")
        try put("grey.mp4", at: "b-grey.mp4")
        let log = tempDir.appendingPathComponent("app.log")
        let extra = (vlc ? ["--force-vlc"] : []) + ["--hold-video-bar", "--test-log=\(log.path)"]
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        launch(open: tempDir.appendingPathComponent("a-clip.mp4").path, extra: extra)
        let id = vlc ? "video.vlc" : "video.avkit"
        var video = element(id)
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        waitForBadge(containing: "a-clip.mp4")
        video.hover()
        let bar = element("videoBar")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "shows on the mouse moving over the video")
        XCTAssertGreaterThan(bar.frame.midY, video.frame.midY, "at first at the bottom")
        XCTAssertEqual(bar.frame.midX, video.frame.midX, accuracy: 4, "in the middle")
        XCTAssertTrue(element("videoBar.playPause").exists)
        XCTAssertTrue(element("videoBar.position").exists)
        XCTAssertTrue(element("videoBar.speed").exists)
        XCTAssertFalse(element("videoBar.audio").exists, "one sound track: no menu for it")
        // Dragged up and to the left (by the grip at the bar's left end: the
        // bar moves as far as the mouse)
        let grip = element("videoBar.grip").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.2, thenDragTo: grip.withOffset(CGVector(dx: -100, dy: -video.frame.height * 0.6)))
        eventually("moved up and to the left") { bar.frame.midY < video.frame.midY && bar.frame.midX < video.frame.midX - 50 }
        let moved = bar.frame
        // The next video: the same place
        app.typeKey(.rightArrow, modifierFlags: .command)
        waitForBadge(containing: "b-grey.mp4")
        print("after paging: app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)"))
        video = element(id)
        video.hover()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        eventually("the same place for the next video") {
            abs(bar.frame.midX - moved.midX) < 3 && abs(bar.frame.midY - moved.midY) < 3
        }
        // The next launch too
        app.terminate()
        launch(open: tempDir.appendingPathComponent("a-clip.mp4").path, resetState: false, extra: extra)
        video = element(id)
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        video.hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5))
        eventually("the same place after a new launch") {
            abs(element("videoBar").frame.midX - moved.midX) < 3 && abs(element("videoBar").frame.midY - moved.midY) < 3
        }
        // Double click on the grip: back to the bottom
        element("videoBar.grip").doubleClick()
        eventually("back at the bottom") { element("videoBar").frame.midY > element(id).frame.midY }
    }

    func testTheControlBarStaysWhereItIsPutInAVKit() throws { try checkControlBarStays(vlc: false) }
    func testTheControlBarStaysWhereItIsPutInVLC() throws { try checkControlBarStays(vlc: true) }

    /// Without the mouse moving the bar goes after a few seconds, as AVKit's did.
    func testTheControlBarHidesWhenTheMouseRests() throws {
        try put("clip.mp4", at: "clip.mp4")
        launch(open: tempDir.appendingPathComponent("clip.mp4").path)
        let video = element("video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        video.hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5))
        eventually("gone once the mouse rests", timeout: 10) { !element("videoBar").exists }
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5), "back on moving")
    }

    func testImageBadgeStaysAtTheBottom() {
        launch(open: tempDir.appendingPathComponent("a.jpg").path)
        waitForBadge(containing: "a.jpg")
        let image = element("fullImage")
        XCTAssertGreaterThan(badge.frame.midY, image.frame.midY)
    }
}
