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
        let f = element.frame
        return try screenStats(of: CGRect(x: f.midX - f.width / 4, y: f.midY - f.height / 4,
                                          width: f.width / 2, height: f.height / 2), file: file, line: line).mean
    }

    /// What a screen region shows: mean luminance, its standard deviation
    /// (how even it is) and the mean of each colour channel, all 0 … 1.
    private struct ScreenStats {
        let mean: Double
        let spread: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Measures a screen region, in screen points.
    private func screenStats(of region: CGRect, file: StaticString = #filePath, line: UInt = #line) throws -> ScreenStats {
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else {
            throw XCTSkip("needs the screen-measuring shell of the CI workflow")
        }
        let id = UUID().uuidString.prefix(8)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("measure:\(id):\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
                             forType: .string)
        var answer: ScreenStats?
        eventually("the screen was measured", timeout: 30, file: file, line: line) {
            guard let text = pasteboard.string(forType: .string), text.hasPrefix("measured:\(id):") else { return false }
            let n = text.dropFirst("measured:\(id):".count).split(separator: ":").compactMap { Double($0) }
            if n.count == 5, n[0] >= 0 { answer = ScreenStats(mean: n[0], spread: n[1], red: n[2], green: n[3], blue: n[4]) }
            return true
        }
        return try XCTUnwrap(answer, "the region couldn't be measured", file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval = 2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Opens a fixture video, with VLC when `vlc`; returns the player view.
    private func openVideo(_ fixture: String, vlc: Bool, extra: [String] = []) throws -> XCUIElement {
        if !FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(fixture).path) {
            try put(fixture, at: fixture)
        }
        launch(open: tempDir.appendingPathComponent(fixture).path, extra: (vlc ? ["--force-vlc"] : []) + extra)
        let video = element(vlc ? "video.vlc" : "video.avkit")
        guard video.waitForExistence(timeout: 20) else {
            XCTFail("no \(vlc ? "VLC" : "AVKit") player for \(fixture); the window holds:\n\(app.debugDescription)")
            throw XCTSkip("no player")
        }
        waitForBadge(containing: fixture)
        settle()
        print("player: \(text(of: video))")
        return video
    }

    // MARK: Videos show at full brightness

    /// The test clip (ffmpeg's colour-bar pattern, its middle half about
    /// 0.55 bright) is shown as bright as it is from the start, and stays so
    /// when clicked or hovered.
    private func checkFullBrightness(vlc: Bool) throws {
        let video = try openVideo(vlc ? "clip.mkv" : "clip.mp4", vlc: vlc)
        let start = try screenBrightness(of: video)
        XCTAssertGreaterThan(start, 0.45, "shown dimmed from the start: \(start); \(text(of: video))")
        video.click()
        settle()
        let clicked = try screenBrightness(of: video)
        XCTAssertEqual(clicked, start, accuracy: 0.04, "a click changes the brightness: \(start) → \(clicked)")
        video.hover()
        settle(3)
        let hovered = try screenBrightness(of: video)
        XCTAssertEqual(hovered, start, accuracy: 0.04, "hovering changes the brightness: \(start) → \(hovered)")
    }

    /// Moving the mouse onto the video and off again, several times, never
    /// dims the picture: measured right after each move and a while later,
    /// in the middle of the picture (the controls show at the bottom).
    private func checkHoverKeepsTheBrightness(vlc: Bool) throws {
        let video = try openVideo(vlc ? "clip.mkv" : "clip.mp4", vlc: vlc)
        func sample() throws -> Double { try screenBrightness(of: video) }
        let away = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        away.hover()
        settle(3)
        let start = try sample()
        var log = ["start \(start)"]
        var worst = 0.0
        for round in 1...3 {
            for (place, move) in [("on", { video.hover() }), ("off", { away.hover() })] {
                move()
                var waited = 0.0
                for wait in [0.3, 0.7, 2.0] {   // 0.3, 1 and 3 s after the move
                    settle(wait)
                    waited += wait
                    let now = try sample()
                    log.append("round \(round) \(place) +\(waited) s: \(now)")
                    worst = max(worst, abs(now - start))
                }
            }
        }
        print((vlc ? "VLC" : "AVKit") + " hover:\n" + log.joined(separator: "\n"))
        XCTAssertLessThan(worst, 0.04, "the picture changes when the mouse moves on and off it:\n" + log.joined(separator: "\n"))
    }

    func testHoverKeepsAnAVKitVideosBrightness() throws { try checkHoverKeepsTheBrightness(vlc: false) }
    func testHoverKeepsAVLCVideosBrightness() throws { try checkHoverKeepsTheBrightness(vlc: true) }
    /// Both players show the same video alike: the same brightness and,
    /// with the colour bars, the same colours (VLC's pictures are converted
    /// to RGB by the compositor, AVKit's by AVKit).
    func testAVKitAndVLCShowTheSamePicture() throws {
        for fixture in ["grey.mp4", "clip.mp4"] {
            var means: [Double] = []
            for vlc in [false, true] {
                let video = try openVideo(fixture, vlc: vlc)
                means.append(try screenBrightness(of: video))
                app.terminate()
            }
            print("\(fixture): AVKit \(means[0]), VLC \(means[1])")
            XCTAssertEqual(means[1], means[0], accuracy: 0.03, "\(fixture): AVKit \(means[0]), VLC \(means[1])")
        }
    }

    /// The picture of a 16:9 video fitted into its player view.
    private func picture(in video: XCUIElement) -> CGRect {
        let f = video.frame
        let width = min(f.width, f.height * 16 / 9), height = width * 9 / 16
        return CGRect(x: f.midX - width / 2, y: f.midY - height / 2, width: width, height: height)
    }

    /// The red, green and blue bands of `colours.mp4`, each measured in
    /// its middle.
    private func bands(of video: XCUIElement) throws -> [ScreenStats] {
        let p = picture(in: video)
        return try (0..<3).map { band in
            let midX = p.minX + p.width * (Double(band) + 0.5) / 3
            return try screenStats(of: CGRect(x: midX - p.width / 12, y: p.midY - p.height / 6,
                                              width: p.width / 6, height: p.height / 3))
        }
    }

    /// Both players show colours alike, channel by channel: VLC's pictures
    /// go to the screen as NV12 when unfiltered and as BGRA through the
    /// filter, so both ways are compared with AVKit (a swapped channel or
    /// the wrong colour matrix shows up here, not in the brightness).
    func testAVKitAndVLCShowTheSameColours() throws {
        var shown: [String: [ScreenStats]] = [:]
        for vlc in [false, true] {
            let video = try openVideo("colours.mp4", vlc: vlc)
            let player = vlc ? "VLC" : "AVKit"
            shown["\(player) as is"] = try bands(of: video)
            app.typeKey("a", modifierFlags: [])
            let slider = element("slider.contrast").firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            slider.adjust(toNormalizedSliderPosition: 0.6)
            waitForBadge(containing: "Adjusted")
            app.typeKey("a", modifierFlags: [])
            settle()
            shown["\(player) filtered"] = try bands(of: video)
            app.terminate()
        }
        for (key, stats) in shown.sorted(by: { $0.key < $1.key }) {
            print("\(key): " + stats.map { String(format: "(%.3f %.3f %.3f)", $0.red, $0.green, $0.blue) }.joined(separator: " "))
        }
        for way in ["as is", "filtered"] {
            let avkit = try XCTUnwrap(shown["AVKit \(way)"]), vlc = try XCTUnwrap(shown["VLC \(way)"])
            for (band, name) in ["red", "green", "blue"].enumerated() {
                let a = avkit[band], v = vlc[band]
                let channels = [a.red, a.green, a.blue]
                XCTAssertEqual(channels.firstIndex(of: channels.max()!), band, "AVKit \(way), \(name) band: \(channels)")
                for (channel, (x, y)) in ["red", "green", "blue"].enumerated().map({ ($0.element, [(a.red, v.red), (a.green, v.green), (a.blue, v.blue)][$0.offset]) }) {
                    XCTAssertEqual(y, x, accuracy: 0.04, "\(way), \(name) band, \(channel): AVKit \(x), VLC \(y)")
                }
            }
        }
    }

    /// The same video in both players, every correction one after the
    /// other: AVKit (what the app uses for MP4) and VLC (its pipeline,
    /// tested on the same file) show each the same, channel by channel.
    func testBothPlayersApplyEveryCorrectionAlike() throws {
        let steps: [(name: String, slider: String?, position: Double)] = [
            ("as is", nil, 0),
            ("brighter", "exposure", 0.85),
            ("darker", "exposure", 0.2),
            ("more contrast", "contrast", 0.85),
            ("less saturation", "saturation", 0.1),
            ("sharper", "sharpness", 1),
            ("reset", "reset", 0),
            ("auto", "auto", 0),
        ]
        var shown: [String: [ScreenStats]] = [:]
        let log = tempDir.appendingPathComponent("avkit.log")
        for vlc in [false, true] {
            let player = vlc ? "VLC" : "AVKit"
            let video = try openVideo("colours.mp4", vlc: vlc, extra: vlc ? [] : ["--test-log=\(log.path)"])
            for step in steps {
                if !vlc { BrowserModelLogMarker.write("step \(step.name)", to: log) }
                switch step.slider {
                case nil:
                    break
                case "auto":
                    app.typeKey("e", modifierFlags: [])
                    waitForBadge(containing: "Enhanced")
                case "reset":
                    app.typeKey("a", modifierFlags: [])
                    let reset = element("resetLook").firstMatch
                    XCTAssertTrue(reset.waitForExistence(timeout: 5))
                    reset.click()
                    eventually("back to the file as is") { !self.text(of: self.badge).contains("Adjusted") }
                    app.typeKey("a", modifierFlags: [])
                case let id?:
                    app.typeKey("a", modifierFlags: [])
                    let reset = element("resetLook").firstMatch
                    XCTAssertTrue(reset.waitForExistence(timeout: 5))
                    reset.click()   // each step from the file as is
                    let slider = element("slider.\(id)").firstMatch
                    XCTAssertTrue(slider.waitForExistence(timeout: 5))
                    slider.adjust(toNormalizedSliderPosition: step.position)
                    waitForBadge(containing: "Adjusted")
                    app.typeKey("a", modifierFlags: [])   // the sliders would cover the picture
                }
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).hover()
                settle(3)
                shown["\(player) \(step.name)"] = try bands(of: video)
            }
            app.terminate()
        }
        func describe(_ stats: [ScreenStats]) -> String {
            stats.map { String(format: "(%.3f %.3f %.3f)", $0.red, $0.green, $0.blue) }.joined(separator: " ")
        }
        for step in steps {
            print("\(step.name): AVKit \(describe(shown["AVKit \(step.name)"] ?? [])), VLC \(describe(shown["VLC \(step.name)"] ?? []))")
        }
        for step in steps {
            let avkit = try XCTUnwrap(shown["AVKit \(step.name)"]), vlc = try XCTUnwrap(shown["VLC \(step.name)"])
            for (band, name) in ["red", "green", "blue"].enumerated() {
                let a = avkit[band], v = vlc[band]
                for (channel, x, y) in [("red", a.red, v.red), ("green", a.green, v.green), ("blue", a.blue, v.blue)] {
                    XCTAssertEqual(y, x, accuracy: 0.05, "\(step.name), \(name) band, \(channel): AVKit \(x), VLC \(y)"
                                   + (abs(y - x) > 0.05 ? "\nAVKit log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "none") : ""))
                }
            }
        }
        // And each correction does what it says, in AVKit
        let base = try XCTUnwrap(shown["AVKit as is"])
        func mean(_ stats: [ScreenStats]) -> Double { stats.map(\.mean).reduce(0, +) / Double(stats.count) }
        func chroma(_ stats: [ScreenStats]) -> Double {
            stats.map { [$0.red, $0.green, $0.blue].max()! - [$0.red, $0.green, $0.blue].min()! }.reduce(0, +)
        }
        XCTAssertGreaterThan(mean(shown["AVKit brighter"]!), mean(base) + 0.05, "brighter")
        XCTAssertLessThan(mean(shown["AVKit darker"]!), mean(base) - 0.05, "darker")
        XCTAssertLessThan(chroma(shown["AVKit less saturation"]!), chroma(base) - 0.2, "less saturation")
        XCTAssertEqual(mean(shown["AVKit reset"]!), mean(base), accuracy: 0.02, "reset: the file as is")
    }

    func testAVKitVideoIsShownAtFullBrightness() throws { try checkFullBrightness(vlc: false) }
    func testVLCVideoIsShownAtFullBrightness() throws { try checkFullBrightness(vlc: true) }

    /// VLC shows no messages over the video (auto enhance takes a snapshot
    /// every second; VLC would announce each one with its path and a
    /// preview). The grey video is even, so the top corners of the
    /// picture, where VLC puts them, stay even too (the app's own badge
    /// sits in the middle between them).
    func testVLCShowsNoMessagesOverTheVideo() throws {
        let video = try openVideo("grey.mp4", vlc: true)
        app.typeKey("e", modifierFlags: [])
        waitForBadge(containing: "Enhanced")
        settle(2.5)
        let picture = picture(in: video)
        let width = picture.width, height = picture.height
        for (side, x) in [("left", picture.minX + width * 0.03), ("right", picture.minX + width * 0.67)] {
            let corner = CGRect(x: x, y: picture.minY + height * 0.03, width: width * 0.3, height: height * 0.3)
            let stats = try screenStats(of: corner)
            XCTAssertGreaterThan(stats.mean, 0.3, "the picture is there (\(side))")
            XCTAssertLessThan(stats.spread, 0.04, "something is drawn over the top \(side) of the video: ± \(stats.spread)")
        }
    }

    /// 4K at 60 frames per second through VLC: the picture reaches the
    /// screen, and handing each picture over to the app costs little (a
    /// picture has 16 ms at 60 fps). How many pictures VLC loses is only
    /// reported: on CI's virtual Macs it ranges from 3 to 40 %, depending on
    /// their load, which says nothing about the app.
    func testVLCHandsOver4KAt60FramesPerSecondCheaply() throws {
        let video = try openVideo("uhd60.mp4", vlc: true)
        settle(3)
        let label = text(of: video)
        func number(after word: String) -> Double {
            guard let range = label.range(of: "\(word) ") else { return -1 }
            return Double(label[range.upperBound...].prefix { $0.isNumber || $0 == "." }) ?? -1
        }
        print("4K60 through VLC: \(Int(number(after: "shown"))) pictures shown, \(Int(number(after: "lost"))) lost, "
              + "handover \(number(after: "handover")) ms per picture")
        let brightness = try screenBrightness(of: video)   // not inside the assertion: its skip stays a skip
        XCTAssertGreaterThan(brightness, 0.15, "the picture is on screen")
        XCTAssertGreaterThan(number(after: "shown"), 30, "pictures are shown: \(label)")
        let handover = number(after: "handover")
        XCTAssertGreaterThanOrEqual(handover, 0, "handover measured: \(label)")
        XCTAssertLessThan(handover, 3, "handing a 4K picture over costs too much: \(label)")
    }

    // MARK: Auto enhance and sliders on videos

    private func checkAutoEnhance(_ fixture: String, vlc: Bool, brighter: Bool) throws {
        let video = try openVideo(fixture, vlc: vlc)
        let before = try screenBrightness(of: video)
        app.typeKey("e", modifierFlags: [])
        waitForBadge(containing: "Enhanced")
        settle(3)   // measured once a second, then gliding
        let after = try screenBrightness(of: video)
        if brighter {
            XCTAssertGreaterThan(after, before + 0.12, "\(fixture) not brightened: \(before) → \(after); \(text(of: video))")
        } else {
            XCTAssertLessThan(after, before - 0.1, "\(fixture) not darkened: \(before) → \(after); \(text(of: video))")
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

    /// The grey video has mid-tones throughout, which exposure moves (pure
    /// colours like a test pattern's bars stay as they are).
    private func checkExposureSlider(vlc: Bool) throws {
        let log = tempDir.appendingPathComponent("test.log")
        let video = try openVideo("grey.mp4", vlc: vlc, extra: ["--test-log=\(log.path)"])
        let before = try screenBrightness(of: video)
        app.typeKey("a", modifierFlags: [])
        let slider = element("slider.exposure").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.9)
        waitForBadge(containing: "Adjusted")
        app.typeKey("a", modifierFlags: [])   // the popover would cover part of the picture
        // The mouse off the video, so the player's controls don't cover it
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).hover()
        settle(4)
        let after = try screenBrightness(of: video)
        XCTAssertGreaterThan(after, before + 0.12, "the exposure slider does nothing: \(before) → \(after); \(text(of: video)); app log:\n"
                             + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)"))
    }

    func testExposureSliderBrightensAnAVKitVideo() throws { try checkExposureSlider(vlc: false) }
    func testExposureSliderBrightensAVLCVideo() throws { try checkExposureSlider(vlc: true) }

    // MARK: Paused videos, paging, zoom

    /// The left quarter of a region (the dark end of the test pictures'
    /// left-to-right gradient).
    private func leftQuarter(of f: CGRect) throws -> Double {
        try screenStats(of: CGRect(x: f.minX + f.width * 0.1, y: f.midY - f.height / 8,
                                   width: f.width * 0.15, height: f.height / 4)).mean
    }

    private func middle(of f: CGRect) throws -> Double {
        try screenStats(of: CGRect(x: f.midX - f.width / 4, y: f.midY - f.height / 4,
                                   width: f.width / 2, height: f.height / 2)).mean
    }

    /// A new look reaches a paused video at once, not only when it plays on.
    private func checkPausedVideoTakesTheLook(vlc: Bool) throws {
        let video = try openVideo("dark.mp4", vlc: vlc)
        // The three-second video ends and stays paused on its last picture
        // (pressing Space could come just after its end and play it again)
        waitForBadge(containing: "Paused", timeout: 20)
        settle()
        let before = try screenBrightness(of: video)
        app.typeKey("e", modifierFlags: [])
        settle(2)
        let after = try screenBrightness(of: video)
        XCTAssertGreaterThan(after, before + 0.12, "paused, not brightened: \(before) → \(after); \(text(of: video))")
    }

    func testAPausedAVKitVideoTakesTheLook() throws { try checkPausedVideoTakesTheLook(vlc: false) }
    func testAPausedVLCVideoTakesTheLook() throws { try checkPausedVideoTakesTheLook(vlc: true) }

    /// Paging from one video to the next shows the next one's picture, not
    /// the last frame of the one before.
    private func checkPagingBetweenVideos(vlc: Bool) throws {
        try put("dark.mp4", at: "v1.mp4")
        try put("bright.mp4", at: "v2.mp4")
        let video = try openVideo("v1.mp4", vlc: vlc)
        let first = try screenBrightness(of: video)
        XCTAssertLessThan(first, 0.3, "the dark one: \(first)")
        app.typeKey(.rightArrow, modifierFlags: .command)
        waitForBadge(containing: "v2.mp4")
        let next = element(vlc ? "video.vlc" : "video.avkit")
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        settle()
        let second = try screenBrightness(of: next)
        XCTAssertGreaterThan(second, 0.7, "the bright one, not the last frame before: \(second)")
    }

    func testPagingBetweenAVKitVideosShowsTheNextOne() throws { try checkPagingBetweenVideos(vlc: false) }
    func testPagingBetweenVLCVideosShowsTheNextOne() throws { try checkPagingBetweenVideos(vlc: true) }

    /// Zooming in really enlarges the picture: the dark left edge of the
    /// gradient moves out, so the left quarter gets brighter. Dragging right
    /// then moves the darker part back into the middle. Measured in the area
    /// the view had before zooming (a video view's own frame grows with it).
    private func checkZoomAndPan(_ element: XCUIElement) throws {
        let area = element.frame
        let fit = try leftQuarter(of: area)
        for _ in 0..<3 { app.typeKey("+", modifierFlags: []) }
        settle(1)
        let zoomed = try leftQuarter(of: area)
        XCTAssertGreaterThan(zoomed, fit + 0.03, "zoom doesn't enlarge the picture: \(fit) → \(zoomed)")
        let before = try middle(of: area)
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - origin.x, dy: y - origin.y))
        }
        point(area.minX + area.width * 0.3, area.midY)
            .press(forDuration: 0.1, thenDragTo: point(area.minX + area.width * 0.7, area.midY))
        settle(1)
        let panned = try middle(of: area)
        XCTAssertLessThan(panned, before - 0.03, "dragging doesn't move the picture: \(before) → \(panned)")
    }

    func testZoomAndPanMoveAPhoto() throws {
        try put("gradient.jpg", at: "gradient.jpg")
        launch(open: tempDir.appendingPathComponent("gradient.jpg").path)
        let image = element("fullImage")
        eventually("loaded", timeout: 15) { text(of: image).hasSuffix("loaded") }
        settle()
        try checkZoomAndPan(image)
    }

    func testZoomAndPanMoveAnAVKitVideo() throws {
        try checkZoomAndPan(try openVideo("gradient.mp4", vlc: false))
    }

    func testZoomAndPanMoveAVLCVideo() throws {
        try checkZoomAndPan(try openVideo("gradient.mp4", vlc: true))
    }

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

    /// The exposure slider brightens a photo's mid-tones (the gradient has
    /// them across its middle), and the picture shown is the adjusted one.
    func testExposureSliderBrightensAPhoto() throws {
        try put("gradient.jpg", at: "gradient.jpg")
        launch(open: tempDir.appendingPathComponent("gradient.jpg").path)
        let image = element("fullImage")
        eventually("the image loads", timeout: 15) { text(of: image).hasSuffix("loaded") }
        settle()
        let before = try screenBrightness(of: image)
        app.typeKey("a", modifierFlags: [])
        let slider = element("slider.exposure").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.9)
        waitForBadge(containing: "Adjusted")
        eventually("the adjusted picture is shown", timeout: 15) { text(of: image).contains("adjusted") }
        app.typeKey("a", modifierFlags: [])   // the popover would cover part of the picture
        settle(1)
        let after = try screenBrightness(of: image)
        XCTAssertGreaterThan(after, before + 0.1, "the exposure slider does nothing on a photo: \(before) → \(after); \(text(of: image))")
    }

    /// An SVG shows like any picture: drawn sharp at the window's size, its
    /// colours as in the file, its size in the Inspector.
    func testAnSVGIsShownLikeAPhoto() throws {
        try put("vector.svg", at: "vector.svg")
        launch(open: tempDir.appendingPathComponent("vector.svg").path)
        let image = element("fullImage")
        eventually("the SVG loads", timeout: 15) { self.text(of: image).hasSuffix("loaded") }
        XCTAssertFalse(text(of: image).contains("decoded 200 px"), "drawn at the window's size: \(text(of: image))")
        settle(1)
        let f = image.frame
        // Left of the white circle in the middle: the red background
        let red = try screenStats(of: CGRect(x: f.midX - f.width * 0.35, y: f.midY - 10, width: f.width * 0.15, height: 20))
        XCTAssertGreaterThan(red.red, 0.6, "red as in the file: \(red)")
        XCTAssertLessThan(red.green, 0.3, "red as in the file: \(red)")
        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["200 × 100 px"].waitForExistence(timeout: 5))
    }

    /// A photo changed in another app gets a new tile once its folder is
    /// opened again, not the old picture from the session's cache.
    func testAChangedPhotoGetsANewTile() throws {
        let photo = try put("dark.jpg", at: "sub/x.jpg")
        launch(open: tempDir.appendingPathComponent("sub").path)
        let x = tile("x.jpg")
        eventually("the tile shows the photo", timeout: 15) { self.text(of: x).hasSuffix("preview") }
        settle(1)
        let before = try screenBrightness(of: x)

        try FileManager.default.removeItem(at: photo)
        try put("bright.jpg", at: "sub/x.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: photo.path)
        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        app.typeKey("[", modifierFlags: .command)
        eventually("back in the folder", timeout: 15) { x.exists && self.text(of: x).hasSuffix("preview") }
        var after = before
        eventually("the tile shows the changed photo", timeout: 20) {
            settle(1)
            after = (try? screenBrightness(of: x)) ?? before
            return after > before + 0.3
        }
        XCTAssertGreaterThan(after, before + 0.3, "tile still the old photo: \(before) → \(after)")
    }

    func testAutoEnhanceBrightensADarkPhoto() throws { try checkAutoEnhancePhoto("dark.jpg", brighter: true) }
    func testAutoEnhanceDarkensAnOverexposedPhoto() throws { try checkAutoEnhancePhoto("bright.jpg", brighter: false) }

    /// A photo taken with the camera held upright: stored lying (dark on the
    /// left), with EXIF orientation 6 to turn it. On screen it stands, dark
    /// at the top, at fit and when zoomed in (decoded again at full size).
    func testAnUprightPhotoIsShownTurned() throws {
        try put("upright.jpg", at: "upright.jpg")
        launch(open: tempDir.appendingPathComponent("upright.jpg").path)
        let image = element("fullImage")
        eventually("loaded", timeout: 15) { text(of: image).hasSuffix("loaded") }
        settle()
        let area = image.frame
        func strip(atHeight fraction: Double) throws -> Double {
            try screenStats(of: CGRect(x: area.midX - area.width * 0.04, y: area.minY + area.height * fraction,
                                       width: area.width * 0.08, height: area.height * 0.08)).mean
        }
        for state in ["fit", "zoomed in"] {
            let top = try strip(atHeight: 0.12), bottom = try strip(atHeight: 0.8)
            XCTAssertLessThan(top, bottom - 0.2, "\(state): not turned upright (top \(top), bottom \(bottom)); \(text(of: image))")
            if state == "fit" {
                for _ in 0..<2 { app.typeKey("+", modifierFlags: []) }
                eventually("decoded at full size", timeout: 15) { text(of: image).contains("decoded 2400 px") }
                settle()
            }
        }
    }

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
            // A hung app can't answer the accessibility queries below (they
            // fail before any check of ours): a watchdog on its own thread
            // samples it after 12 s unless the badge has come
            let shown = WatchFlag()
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                guard !shown.isSet else { return }
                print("== \(name): no badge after 12 s; the app's threads:\n" + Self.sampleApp())
            }
            defer { shown.set() }
            let deadline = Date().addingTimeInterval(20)
            while !text(of: badge).contains(name), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            if text(of: badge).contains(name) { shown.set() }
            if !text(of: badge).contains(name) {
                // A hang shows what each thread was doing
                XCTFail("no badge for \(name); the app's threads:\n" + Self.sampleApp())
                return
            }
            settle(3)
            XCTAssertEqual(app.state, .runningForeground, "still running after opening \(name)")
            app.typeKey(.escape, modifierFlags: [])
            eventually("back in the grid") { self.tile("a.jpg").exists }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Paging from a good photo onto a broken one shows that it's broken,
    /// never the previous photo.
    func testABrokenPhotoNeverShowsThePreviousOne() throws {
        try put("broken.jpg", at: "b-broken.jpg")
        launch(open: tempDir.appendingPathComponent("a.jpg").path)
        let image = element("fullImage")
        eventually("a.jpg loads", timeout: 15) { text(of: image).hasSuffix("loaded") }
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "b-broken.jpg")
        eventually("shown as broken", timeout: 15) { text(of: image).hasSuffix("failed") }
    }
}

extension VisualUITests {
    /// What the app's threads are doing (`sample`), for a test that finds
    /// the app hanging.
    static func sampleApp() -> String {
        func run(_ tool: String, _ args: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "\(tool) didn't start" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let pid = run("/usr/bin/pgrep", ["-n", "-x", "Schnellbild"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else { return "no Schnellbild process" }
        return String(run("/usr/bin/sample", [pid, "2"]).prefix(30000))
    }
}

/// A flag set on one thread and read on another.
final class WatchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Marks in the app's test log where a test step begins.
enum BrowserModelLogMarker {
    static func write(_ line: String, to log: URL) {
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(("--- " + line + "\n").utf8))
        try? handle.close()
    }
}
