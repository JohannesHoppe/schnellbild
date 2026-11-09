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

    /// Mean luminance (0 … 1) of the middle half of an element as on screen.
    private func brightness(of element: XCUIElement) -> Double {
        let image = element.screenshot().image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let w = cg.width / 2, h = cg.height / 2
        guard let middle = cg.cropping(to: CGRect(x: w / 2, y: h / 2, width: w, height: h)) else { return -1 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(middle, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return sum / Double(w * h) / 255
    }

    /// The fixture clips are an even grey (about 0.46). A video shows at full
    /// brightness from the start, not dimmed until it is clicked.
    private func checkFullBrightness(_ clip: String, player: String) throws {
        try put(clip, at: clip)
        launch(open: tempDir.appendingPathComponent(clip).path)
        let video = element(player)
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        waitForBadge(containing: clip)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let before = brightness(of: video)
        video.click()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let after = brightness(of: video)
        print("brightness \(clip): before click \(before), after \(after)")
        XCTAssertGreaterThan(before, 0.38, "\(clip) is shown dimmed (\(before), after a click \(after))")
        XCTAssertEqual(before, after, accuracy: 0.04, "\(clip) changes brightness on a click")
    }

    func testAVKitVideoIsBrightFromTheStart() throws {
        try checkFullBrightness("clip.mp4", player: "video.avkit")
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
        launch(open: tempDir.appendingPathComponent("show").path, extra: vlc ? ["--force-vlc"] : [])
        XCTAssertTrue(tile("v1.mp4").waitForExistence(timeout: 15))
        app.typeKey("s", modifierFlags: [])
        waitForBadge(containing: "v1.mp4", timeout: 20)
        waitForBadge(containing: "v2.mp4", timeout: 20)
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
