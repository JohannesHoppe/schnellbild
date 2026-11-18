import XCTest
import AppKit
import AVFoundation

/// Video: AVKit for native formats, VLCKit fallback, keyboard control, layout.
final class VideoUITests: SchnellbildUITestCase {
    /// Enhance switched on and off quickly, many times, on a clip that has
    /// ended, playing and paused: AVKit's composition changes, redraws and
    /// seeks never count as the file failing, so AVKit keeps the video (VLC
    /// takes over only for data it can't read or a download not finished).
    func testEnhanceToggledQuicklyKeepsTheVideoInAVKit() throws {
        try put("bright.mp4", at: "bright.mp4")   // 3 s
        launch(open: tempDir.appendingPathComponent("bright.mp4").path)
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 20))
        waitForBadge(containing: "bright.mp4")
        RunLoop.current.run(until: Date().addingTimeInterval(5))   // ended
        func toggle(_ times: Int) {
            for round in 0..<times {
                app.typeKey("e", modifierFlags: [])
                RunLoop.current.run(until: Date().addingTimeInterval(round % 3 == 0 ? 0.4 : 0.1))
            }
        }
        toggle(12)
        app.typeKey(.space, modifierFlags: [])   // from the start again: playing
        toggle(10)
        app.typeKey(.space, modifierFlags: [])   // paused: redraws by seeking
        toggle(10)
        // A handover would come within two seconds of a failure
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        let video = element("video.avkit")
        XCTAssertTrue(video.exists, "still AVKit; the window holds:\n\(app.debugDescription)")
        XCTAssertFalse(element("video.vlc").exists)
        XCTAssertFalse(text(of: video).contains("taken over from AVKit"), text(of: video))
    }

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

    /// ↓ / ↑ on a video set the volume, shown a moment; remembered across
    /// launches (both players).
    private func checkUpAndDownSetTheVolume(vlc: Bool) throws {
        try put("clip.mp4", at: "clip.mp4")
        let path = tempDir.appendingPathComponent("clip.mp4").path
        let extra = (vlc ? ["--force-vlc"] : []) + ["--hold-volume-display"]
        launch(open: path, extra: extra)
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").waitForExistence(timeout: 20))
        app.typeKey(.downArrow, modifierFlags: [])
        let display = element("volumeDisplay")
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: display).contains("90 %"), text(of: display))
        waitForBadge(containing: "clip.mp4")   // still the video, not the next item
        app.terminate()
        launch(open: path, resetState: false, extra: extra)
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").waitForExistence(timeout: 20))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element("volumeDisplay").waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: element("volumeDisplay")).contains("80 %"), "remembered: \(text(of: element("volumeDisplay")))")
    }

    func testUpAndDownSetTheVolumeInAVKit() throws { try checkUpAndDownSetTheVolume(vlc: false) }
    func testUpAndDownSetTheVolumeInVLC() throws { try checkUpAndDownSetTheVolume(vlc: true) }

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

    /// Videos QuickLook can't read get their tile picture from Schnellbild's
    /// QuickLook extension or from VLC in the app, whichever answers first
    /// (`ThumbnailCache.videoThumbnail`); the app logs which one did.
    func testMKVTileShowsAFrame() throws {
        try put("clip.mkv", at: "clip.mkv")
        let log = tempDir.appendingPathComponent("app.log")
        launch(open: tempDir.path, extra: ["--test-log=\(log.path)"])
        XCTAssertTrue(app.staticTexts["clip.mkv"].waitForExistence(timeout: 15), "grid should show clip.mkv")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !text(of: tile("clip.mkv")).hasSuffix(", preview") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let written = (try? String(contentsOf: log, encoding: .utf8)) ?? "(none)"
        print("app log:\n" + written)
        XCTAssertTrue(text(of: tile("clip.mkv")).hasSuffix(", preview"),
                      "a picture, not the file icon: “\(text(of: tile("clip.mkv")))”; " +
                      written.components(separatedBy: "\n").filter { $0.contains("tile clip.mkv") }.joined(separator: "; "))
    }

    /// At the end of a video Space plays it again from the start, every
    /// time: it takes the whole clip to end again. The app logs the
    /// player's states (shown when it fails).
    private func checkSpaceAtTheEndPlaysAgain(vlc: Bool) throws {
        try put("dark.mp4", at: "short.mp4")   // three seconds
        let log = testLog("test.log")
        launch(open: tempDir.appendingPathComponent("short.mp4").path,
               extra: (vlc ? ["--force-vlc"] : []) + ["--test-log=\(log.lastPathComponent)"])
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
        let log = testLog("app.log")
        launch(open: tempDir.appendingPathComponent("show").path,
               extra: (vlc ? ["--force-vlc"] : []) + ["--test-log=\(log.lastPathComponent)"])
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

    /// Opens clip.mp4 (or another fixture) in the player asked for.
    @discardableResult
    private func openVideo(_ fixture: String = "clip.mp4", vlc: Bool, extra: [String] = []) throws -> XCUIElement {
        try put(fixture, at: fixture)
        launch(open: tempDir.appendingPathComponent(fixture).path, extra: (vlc ? ["--force-vlc"] : []) + extra)
        let video = element(vlc ? "video.vlc" : "video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        waitForBadge(containing: fixture)
        return video
    }

    /// + / 0 zoom a video as a picture; the badge sits at the top, away from
    /// the control bar; ⌥→ / ⌥← turn it and the bar stays upright at the
    /// bottom middle; F takes it to full screen and back (both players).
    private func checkZoomTurnAndFullScreen(vlc: Bool) throws {
        let video = try openVideo(vlc: vlc, extra: ["--hold-video-bar"])
        XCTAssertLessThan(badge.frame.midY, video.frame.midY, "the badge at the top")
        app.typeKey("+", modifierFlags: [])
        app.typeKey("+", modifierFlags: [])
        eventually("zoomed") { text(of: video).contains("zoom 156 %") }
        app.typeKey("0", modifierFlags: [])
        eventually("fit again") { text(of: video).contains("zoom 100 %") }
        app.typeKey(.rightArrow, modifierFlags: .option)
        eventually("⌥→ turns it") { text(of: video).contains("rotation 90°") }
        video.hover()
        let bar = element("videoBar")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(bar.frame.midY, video.frame.midY, "turned: the bar still at the bottom")
        XCTAssertEqual(bar.frame.midX, video.frame.midX, accuracy: 4, "turned: the bar still in the middle")
        XCTAssertGreaterThan(bar.frame.width, bar.frame.height * 4, "turned: the bar still lies flat")
        app.typeKey(.leftArrow, modifierFlags: .option)
        eventually("⌥← turns it back") { text(of: video).contains("rotation 0°") }
        let window = app.windows.firstMatch
        let before = window.frame.size
        app.typeKey("f", modifierFlags: [])
        eventually("F: full screen", timeout: 10) { window.frame.width > before.width || window.frame.height > before.height }
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").exists, "the video stays in full screen")
        app.typeKey("f", modifierFlags: [])
        eventually("F again: out of full screen", timeout: 10) { window.frame.size == before }
    }

    func testZoomTurnAndFullScreenInAVKit() throws { try checkZoomTurnAndFullScreen(vlc: false) }
    func testZoomTurnAndFullScreenInVLC() throws { try checkZoomTurnAndFullScreen(vlc: true) }

    /// The control bar's buttons and slider work the player: play / pause,
    /// a click on the position slider jumps there, the speed menu (both players).
    private func checkControlBarButtons(vlc: Bool) throws {
        let video = try openVideo("tracks.mp4", vlc: vlc, extra: ["--hold-video-bar"])
        video.hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5))
        element("videoBar.playPause").click()
        waitForBadge(containing: "Paused")
        let progress = element("videoProgress")
        func percent() -> Int { Int(text(of: progress).filter(\.isNumber)) ?? -1 }
        let before = percent()
        element("videoBar.position").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).click()
        eventually("a click on the slider jumps there") { percent() >= 60 }
        XCTAssertLessThan(before, 50)
        XCTAssertTrue(text(of: badge).contains("Paused"), "still paused after the jump")
        element("videoBar.playPause").click()
        eventually("plays again") { !text(of: badge).contains("Paused") }
        element("videoBar.speed").click()
        let faster = element("videoBar.speed").descendants(matching: .menuItem)["1.5×"]
        XCTAssertTrue(faster.waitForExistence(timeout: 5), "the speed menu lists 1.5×")
        faster.click()
        eventually("1.5× from the bar") { text(of: video).contains("speed 1.5") }
    }

    func testControlBarButtonsInAVKit() throws { try checkControlBarButtons(vlc: false) }
    func testControlBarButtonsInVLC() throws { try checkControlBarButtons(vlc: true) }

    // MARK: Subtitles, audio tracks, speed

    /// The tracks of a video with two of each (`tracks.mp4`: mov_text in
    /// AVKit; `tracks.mkv`: SubRip and ASS in VLC): the defaults on, ⌃⌘S and
    /// V switch the subtitles, ⌃⌘A the sound, > the speed, which the badge
    /// shows and the video plays at.
    private func checkTracksAndSpeed(_ fixture: String, vlc: Bool) throws {
        let log = testLog("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        try put(fixture, at: fixture)
        launch(open: tempDir.appendingPathComponent(fixture).path,
               extra: (vlc ? ["--force-vlc"] : []) + ["--hold-video-bar", "--test-log=\(log.lastPathComponent)"])
        let video = element(vlc ? "video.vlc" : "video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        eventually("the tracks are known, the defaults on", timeout: 20) {
            text(of: video).contains("audio 1/2 en, subtitles 1/2 en")
        }
        // The tracks first, while the 20 s video plays (on a slow runner it
        // had ended before the keys after the speed check)
        app.typeKey("s", modifierFlags: [.control, .command])
        eventually("⌃⌘S: the German subtitles") { text(of: video).contains("subtitles 2/2 de") }
        app.typeKey("v", modifierFlags: [])
        eventually("V: none") { text(of: video).contains("subtitles off/2") }
        app.typeKey("v", modifierFlags: [])
        eventually("V again: the German ones, the language chosen") { text(of: video).contains("subtitles 2/2 de") }
        app.typeKey("a", modifierFlags: [.control, .command])
        eventually("⌃⌘A: the German sound") { text(of: video).contains("audio 2/2 de") }
        // Twice as fast: the position moves on about twice as fast
        for _ in 0..<4 { app.typeKey(">", modifierFlags: []) }
        eventually("2×") { text(of: video).contains("speed 2.0") }
        waitForBadge(containing: "2×")
        // Room to play at 2× (on a slow runner the steps above took a while):
        // back in steps of 10 % (2 s), never past the start (← there would
        // go to the picture before)
        if let now = playerClock(), now.played > 6 {
            for _ in 0..<min(Int((now.played - 2) / 2), 9) { app.typeKey(.leftArrow, modifierFlags: []) }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        // The player's place against the app's clock, both read in the app
        // at the same moment: XCUITest's own delays don't count
        let first = playerClock()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let second = playerClock()
        if let first, let second, second.at > first.at {
            let played = second.played - first.played, took = second.at - first.at
            print("\(vlc ? "VLC" : "AVKit") at 2×: \(played) s of video in \(took) s on the app's clock")
            XCTAssertLessThan(second.played, 19.5, "still playing when measured (the 20 s video ended)")
            XCTAssertGreaterThan(played, took * 1.5, "plays faster than 1×")
        } else {
            XCTFail("the player's clock is read: \(String(describing: first)), \(String(describing: second))")
        }
        app.typeKey("\\", modifierFlags: .command)
        eventually("⌘\\: normal speed") { text(of: video).contains("speed 1.0") }
        XCTAssertFalse(text(of: badge).contains("×"), "at 1× the badge shows no speed: \(text(of: badge))")
        // The control bar lists them
        video.hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5), "the control bar shows on the mouse moving")
        XCTAssertTrue(element("videoBar.subtitles").exists)
        XCTAssertTrue(element("videoBar.audio").exists)
        // The next launch starts with the choices: German subtitles and sound
        app.terminate()
        launch(open: tempDir.appendingPathComponent(fixture).path, resetState: false,
               extra: (vlc ? ["--force-vlc"] : []) + ["--test-log=\(log.lastPathComponent)"])
        let again = element(vlc ? "video.vlc" : "video.avkit")
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        eventually("remembered", timeout: 20) { text(of: again).contains("audio 2/2 de, subtitles 2/2 de, speed 1.0") }
        print("the next launch: \(text(of: again))")
    }

    func testTracksAndSpeedInAVKit() throws { try checkTracksAndSpeed("tracks.mp4", vlc: false) }
    func testTracksAndSpeedInVLC() throws { try checkTracksAndSpeed("tracks.mkv", vlc: true) }
    func testMovTextTracksInVLC() throws { try checkTracksAndSpeed("tracks.mp4", vlc: true) }

    // MARK: The control bar

    /// The control bar (both players) is dragged by its grip; the next
    /// video and the next launch have it there; a double click on the grip
    /// puts it back at the bottom middle.
    private func checkControlBarStays(vlc: Bool) throws {
        // In a folder of their own: the next item is the other video, not a picture
        try put("clip.mp4", at: "videos/a-clip.mp4")
        try put("grey.mp4", at: "videos/b-grey.mp4")
        let extra = (vlc ? ["--force-vlc"] : []) + ["--hold-video-bar"]
        launch(open: tempDir.appendingPathComponent("videos/a-clip.mp4").path, extra: extra)
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
        video = element(id)
        video.hover()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        eventually("the same place for the next video") {
            abs(bar.frame.midX - moved.midX) < 3 && abs(bar.frame.midY - moved.midY) < 3
        }
        // The next launch too
        app.terminate()
        launch(open: tempDir.appendingPathComponent("videos/a-clip.mp4").path, resetState: false, extra: extra)
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

    // MARK: Going on where a video was left

    /// ⌘→ to the next video and ⌘← back: the first goes on where it was
    /// left, paused or playing as then; so does opening it again from the
    /// grid. Another folder and back: it starts from the beginning.
    /// (`tracks.mp4` in AVKit, `tracks.mkv` in VLC: 20 s each.)
    private func checkResume(_ fixture: String, player: String) throws {
        let ext = (fixture as NSString).pathExtension
        let a = "a.\(ext)", b = "b.\(ext)"
        try put(fixture, at: "videos/\(a)")
        try put(fixture, at: "videos/\(b)")
        let log = testLog("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        launch(open: tempDir.appendingPathComponent("videos/\(a)").path, extra: ["--test-log=\(log.lastPathComponent)"])
        XCTAssertTrue(element(player).waitForExistence(timeout: 20))
        waitForBadge(containing: a)
        let progress = element("videoProgress")
        func percent() -> Int { Int(text(of: progress).filter(\.isNumber)) ?? -1 }
        eventually("the length is known", timeout: 20) { progress.exists && percent() >= 0 }
        // Paused about halfway
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        for _ in 0..<8 where percent() < 45 {
            app.typeKey(.rightArrow, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let left = percent()
        XCTAssertTrue((40...70).contains(left), "about halfway: \(left) %")
        XCTAssertTrue(text(of: badge).contains(a), "still the first video")

        // The next video starts from the beginning, playing
        app.typeKey(.rightArrow, modifierFlags: .command)
        waitForBadge(containing: b)
        eventually("the next one plays from its start", timeout: 15) {
            !text(of: badge).contains("Paused") && (0...25).contains(percent())
        }
        // Back: where it was left, paused
        app.typeKey(.leftArrow, modifierFlags: .command)
        waitForBadge(containing: a)
        eventually("back where it was left (\(left) %), paused", timeout: 15) {
            abs(percent() - left) <= 3 && text(of: badge).contains("Paused")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertLessThanOrEqual(abs(percent() - left), 3, "stays there: \(percent()) %")
        XCTAssertTrue(text(of: badge).contains("Paused"))

        // Playing when left: playing again on coming back
        app.typeKey(.space, modifierFlags: [])
        eventually("plays") { !text(of: badge).contains("Paused") }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.rightArrow, modifierFlags: .command)
        waitForBadge(containing: b)
        app.typeKey(.leftArrow, modifierFlags: .command)
        waitForBadge(containing: a)
        eventually("on from where it was left, playing", timeout: 15) {
            (left...(left + 25)).contains(percent()) && !text(of: badge).contains("Paused")
        }
        let playing = percent()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertGreaterThan(percent(), playing, "plays on: \(playing) % → \(percent()) %")

        // Back to the grid and opened again: still on from there
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let paused = percent()
        app.typeKey(.return, modifierFlags: [])
        waitForSelected(a)
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: a)
        eventually("opened again from the grid: where it was left (\(paused) %)", timeout: 15) {
            abs(percent() - paused) <= 3 && text(of: badge).contains("Paused")
        }

        // Another folder and back: from the beginning
        app.typeKey(.return, modifierFlags: [])
        waitForSelected(a)
        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(tile("videos").waitForExistence(timeout: 10), "the enclosing folder")
        app.typeKey(.delete, modifierFlags: [])   // Back
        waitForSelected(a)
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: a)
        eventually("from the beginning, playing, after another folder", timeout: 15) {
            !text(of: badge).contains("Paused") && (0...25).contains(percent())
        }
    }

    func testAVideoGoesOnWhereItWasLeftInAVKit() throws { try checkResume("tracks.mp4", player: "video.avkit") }
    func testAVideoGoesOnWhereItWasLeftInVLC() throws { try checkResume("tracks.mkv", player: "video.vlc") }

    func testTheControlBarStaysWhereItIsPutInAVKit() throws { try checkControlBarStays(vlc: false) }
    func testTheControlBarStaysWhereItIsPutInVLC() throws { try checkControlBarStays(vlc: true) }

    /// Without the mouse moving the bar goes after a few seconds (both players).
    private func checkControlBarHides(vlc: Bool) throws {
        let video = try openVideo(vlc: vlc)
        video.hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5))
        eventually("gone once the mouse rests", timeout: 10) { !element("videoBar").exists }
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5), "back on moving")
    }

    func testTheControlBarHidesWhenTheMouseRestsInAVKit() throws { try checkControlBarHides(vlc: false) }
    func testTheControlBarHidesWhenTheMouseRestsInVLC() throws { try checkControlBarHides(vlc: true) }

    // MARK: Two videos side by side

    /// The dual pane with a video playing in each pane (both players): the
    /// right pane's control bar works the right video, keys work the active
    /// pane's (Tab switches), and the volume, the speed and the subtitles
    /// switch set in one pane reach the other pane's player at once.
    private func checkVideosInBothPanes(vlc: Bool) throws {
        let ext = vlc ? "mkv" : "mp4"   // tracks.mkv: SubRip in VLC; tracks.mp4: mov_text in AVKit
        try put("tracks.\(ext)", at: "videos/left.\(ext)")
        try put("tracks.\(ext)", at: "videos/right.\(ext)")
        let extra = (vlc ? ["--force-vlc"] : []) + ["--hold-video-bar"]
        launch(open: tempDir.appendingPathComponent("videos/left.\(ext)").path, extra: extra)
        let id = vlc ? "video.vlc" : "video.avkit"
        XCTAssertTrue(element(id).waitForExistence(timeout: 20))
        let leftPane = element("pane.left"), rightPane = element("pane.right")
        func inPane(_ pane: XCUIElement, _ identifier: String) -> XCUIElement {
            pane.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        // D: the right pane shows the same folder; a click there selects the
        // other video and makes the right pane the active one, Space opens it
        app.typeKey("d", modifierFlags: [])
        XCTAssertTrue(rightPane.waitForExistence(timeout: 10), "two panes")
        let tile = inPane(rightPane, "tile.right.\(ext)")
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.click()
        eventually("the right pane's tile selected") { text(of: tile).hasPrefix("selected") }
        app.typeKey(.space, modifierFlags: [])
        let leftVideo = inPane(leftPane, id), rightVideo = inPane(rightPane, id)
        let leftBadge = inPane(leftPane, "positionBadge"), rightBadge = inPane(rightPane, "positionBadge")
        eventually("the right pane opened its video", timeout: 15) { text(of: rightBadge).contains("right.\(ext)") }
        if !rightVideo.waitForExistence(timeout: 20) {
            print(app.debugDescription)
            XCTFail("the right pane's video in \(id)")
        }
        func paused(_ badge: XCUIElement) -> Bool { text(of: badge).contains("Paused") }
        func state() -> String { "left: \(text(of: leftVideo)) [\(text(of: leftBadge))]; right: \(text(of: rightVideo)) [\(text(of: rightBadge))]" }
        eventually("each pane plays its own video, the English subtitles on", timeout: 20) {
            text(of: leftBadge).contains("left.\(ext)") && text(of: rightBadge).contains("right.\(ext)")
                && !paused(leftBadge) && !paused(rightBadge)
                && text(of: leftVideo).contains("subtitles 1/2 en") && text(of: rightVideo).contains("subtitles 1/2 en")
        }

        // The right pane's control bar works the right video only
        rightVideo.hover()
        XCTAssertTrue(inPane(rightPane, "videoBar").waitForExistence(timeout: 5), "the right pane's bar")
        inPane(rightPane, "videoBar.playPause").click()
        eventually("the right bar paused the right video") { paused(rightBadge) }
        XCTAssertFalse(paused(leftBadge), "the left video plays on: \(state())")

        // Keys work the active pane: Tab to the left one, Space pauses it
        // and plays it again; the right video stays as it is
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        eventually("Space paused the left video") { paused(leftBadge) }
        app.typeKey(.space, modifierFlags: [])
        eventually("Space plays the left video again") { !paused(leftBadge) }
        XCTAssertTrue(paused(rightBadge), "the right video stays paused: \(state())")
        app.typeKey(.space, modifierFlags: [])
        eventually("the left video paused again") { paused(leftBadge) }
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        eventually("back in the right pane, Space plays the right video") { !paused(rightBadge) }
        XCTAssertTrue(paused(leftBadge), state())
        app.typeKey(.space, modifierFlags: [])
        eventually("the right video paused again") { paused(rightBadge) }

        // Both paused from here on (the 20 s videos don't end meanwhile);
        // what follows reaches paused players as well.
        // Volume (↓ in the right pane): both players at 90 %
        app.typeKey(.downArrow, modifierFlags: [])
        eventually("both players at 90 %: \(state())", timeout: 10) {
            text(of: leftVideo).contains("player volume 90 %") && text(of: rightVideo).contains("player volume 90 %")
        }
        // Speed (> twice in the right pane): both players at 1.5×
        app.typeKey(">", modifierFlags: [])
        app.typeKey(">", modifierFlags: [])
        eventually("both players at 1.5×: \(state())", timeout: 10) {
            text(of: leftVideo).contains("player speed 1.5") && text(of: rightVideo).contains("player speed 1.5")
        }
        // Subtitles off (V in the right pane): the left video's go too
        app.typeKey("v", modifierFlags: [])
        eventually("no subtitles in either pane: \(state())", timeout: 10) {
            text(of: leftVideo).contains("subtitles off/2") && text(of: rightVideo).contains("subtitles off/2")
        }
        // On again from the left pane: both
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey("v", modifierFlags: [])
        eventually("the subtitles back in both panes: \(state())", timeout: 10) {
            text(of: leftVideo).contains("subtitles 1/2 en") && text(of: rightVideo).contains("subtitles 1/2 en")
        }
        // The left pane's own bar: the speed menu, for both
        leftVideo.hover()
        let speed = inPane(leftPane, "videoBar.speed")
        XCTAssertTrue(speed.waitForExistence(timeout: 5), "the left pane's bar")
        speed.click()
        let normal = speed.descendants(matching: .menuItem)["1×"]
        XCTAssertTrue(normal.waitForExistence(timeout: 5), "the speed menu lists 1×")
        normal.click()
        eventually("both players at 1× again: \(state())", timeout: 10) {
            text(of: leftVideo).contains("player speed 1.0") && text(of: rightVideo).contains("player speed 1.0")
        }
        XCTAssertTrue(paused(leftBadge) && paused(rightBadge), "both still paused: \(state())")
    }

    func testVideosInBothPanesInAVKit() throws { try checkVideosInBothPanes(vlc: false) }
    func testVideosInBothPanesInVLC() throws { try checkVideosInBothPanes(vlc: true) }

    func testImageBadgeStaysAtTheBottom() {
        launch(open: tempDir.appendingPathComponent("a.jpg").path)
        waitForBadge(containing: "a.jpg")
        let image = element("fullImage")
        XCTAssertGreaterThan(badge.frame.midY, image.frame.midY)
    }
}
