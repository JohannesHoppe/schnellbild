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
        guard element.exists else {
            XCTFail("the element went; the window holds:\n\(app.debugDescription)", file: file, line: line)
            throw XCTSkip("no element")
        }
        let f = element.frame
        return try screenStats(of: CGRect(x: f.midX - f.width / 4, y: f.midY - f.height / 4,
                                          width: f.width / 2, height: f.height / 2), file: file, line: line).mean
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
        // The even grey clip: a moving picture would change the brightness
        // by itself (VLC plays the MP4 too, with --force-vlc)
        let video = try openVideo("grey.mp4", vlc: vlc)
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

    // MARK: HDR

    /// A video in AVKit, then through VLC (`--force-vlc`), measured over its
    /// picture: VLC must report `pictures` (what `VLCFrameOutput` hands to
    /// the screen) and whether its layer is in EDR, and show the same brightness and colours, channel by
    /// channel.
    private func checkBothPlayersShowAlike(_ fixture: String, pictures: String, edr: Bool) throws {
        var shown: [String: ScreenStats] = [:]
        for vlc in [false, true] {
            let video = try openVideo(fixture, vlc: vlc)
            if vlc {
                eventually("VLC hands over \(pictures), EDR \(edr ? "on" : "off"): \(text(of: video))", timeout: 15) {
                    let label = text(of: video)
                    return label.contains(pictures) && label.contains(edr ? "EDR on" : "EDR off")
                }
            }
            shown[vlc ? "VLC" : "AVKit"] = try screenStats(of: picture(in: video))
            app.terminate()
        }
        let avkit = try XCTUnwrap(shown["AVKit"]), vlc = try XCTUnwrap(shown["VLC"])
        let report = String(format: "AVKit %.3f (%.3f %.3f %.3f), VLC %.3f (%.3f %.3f %.3f)",
                            avkit.mean, avkit.red, avkit.green, avkit.blue, vlc.mean, vlc.red, vlc.green, vlc.blue)
        print("\(fixture): " + report)
        XCTAssertGreaterThan(avkit.mean, 0.1, "AVKit shows the picture: \(report)")
        XCTAssertEqual(vlc.mean, avkit.mean, accuracy: 0.05, report)
        XCTAssertEqual(vlc.red, avkit.red, accuracy: 0.06, report)
        XCTAssertEqual(vlc.green, avkit.green, accuracy: 0.06, report)
        XCTAssertEqual(vlc.blue, avkit.blue, accuracy: 0.06, report)
    }

    /// An HDR10 video (10-bit HEVC, PQ, BT.2020) through VLC goes to the
    /// screen as HDR: 10-bit pictures tagged PQ and BT.2020, the layer in
    /// EDR. CI's virtual display has no EDR headroom, so how bright the
    /// highlights get on an HDR screen can't be seen here; what is compared
    /// instead is that VLC's picture looks like AVKit's (both turn the PQ
    /// picture into what the display can show).
    func testAVKitAndVLCShowAnHDRVideoAlike() throws {
        try checkBothPlayersShowAlike("hdr10.mp4", pictures: "pictures P010 PQ 2020 matrix 2020", edr: true)
    }

    /// A 10-bit SDR video (BT.709, HD) through VLC: P010 pictures tagged
    /// BT.709, no EDR, shown as AVKit shows it.
    func testAVKitAndVLCShowA10BitSDRVideoAlike() throws {
        try checkBothPlayersShowAlike("sdr10.mp4", pictures: "pictures P010 709 709 matrix 709", edr: false)
    }

    /// The same for HDR10 in Matroska (always VLC), and an SDR video after
    /// it: 8-bit NV12, BT.709's transfer, no EDR.
    func testVLCShowsHDRMatroskaAsHDRAndSDRAsSDR() throws {
        let hdr = try openVideo("hdr10.mkv", vlc: true)
        eventually("HDR pictures in EDR: \(text(of: hdr))", timeout: 15) {
            let label = text(of: hdr)
            return label.contains("pictures P010 PQ 2020 matrix 2020") && label.contains("EDR on")
        }
        XCTAssertGreaterThan(try screenBrightness(of: hdr), 0.1, "the picture is on screen")
        app.terminate()
        let sdr = try openVideo("clip.mkv", vlc: true)
        eventually("SDR pictures without EDR: \(text(of: sdr))", timeout: 15) {
            let label = text(of: sdr)
            return label.contains("pictures NV12 709") && label.contains("EDR off")
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

    // MARK: Subtitles

    /// VLC draws subtitles only into pictures it decoded in software. With
    /// subtitles on, a file starts in software (its tracks read first); a
    /// media opened again for them (`decodeInSoftware`) shows the
    /// hardware-decoded pictures until then. Waits until pictures of the
    /// media in software have reached the screen.
    private func waitForSoftwarePictures(of video: XCUIElement) {
        func picturesOfMedia(_ label: String) -> Int {
            let suffix = " of this media"
            let part = label.components(separatedBy: ", ").first { $0.hasSuffix(suffix) }
            return part.flatMap { Int($0.dropLast(suffix.count)) } ?? 0
        }
        eventually("pictures decoded in software on screen", timeout: 20) {
            let label = text(of: video)
            return label.contains("decoding software") && picturesOfMedia(label) >= 5
        }
    }

    /// What the app's test log says about the pictures VLC handed over
    /// (`VLCFrameOutput.probe`): "vlc picture <n> of media <m>: luma <l>[, text | , no text]".
    private struct Box { var x0, x1, y0, y1: Int }
    private struct ProbedPicture { var number: Int; var media: Int; var luma: Int; var text: Bool?; var box: Box? }

    private func probedPicture(_ line: String) -> ProbedPicture? {
        guard line.hasPrefix("vlc picture ") else { return nil }
        // "… | <time> ms": when it was shown
        let line = line.components(separatedBy: " | ")[0]
        let words = line.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ",", with: "")
            .components(separatedBy: " ")
        // vlc picture <n> of media <m> luma <l> [text | no text] [box <x0> <x1> <y0> <y1>]
        guard words.count >= 8, let n = Int(words[2]), let m = Int(words[5]), let l = Int(words[7]) else { return nil }
        let text: Bool? = line.contains(", no text") ? false : line.contains(", text") ? true : nil
        var box: Box?
        if let at = words.firstIndex(of: "box"), words.count >= at + 5,
           let x0 = Int(words[at + 1]), let x1 = Int(words[at + 2]), let y0 = Int(words[at + 3]), let y1 = Int(words[at + 4]) {
            box = Box(x0: x0, x1: x1, y0: y0, y1: y1)
        }
        return ProbedPicture(number: n, media: m, luma: l, text: text, box: box)
    }

    private func probedPictures(in log: String) -> [ProbedPicture] {
        log.components(separatedBy: "\n").compactMap(probedPicture)
    }

    /// The pictures shown while the app drew a subtitle line of its own
    /// (from "the app draws [text]" to "the app draws []") and those after
    /// it, VLC's.
    private func handoverPictures(in log: String) -> (app: [ProbedPicture], vlc: [ProbedPicture]) {
        var app: [ProbedPicture] = [], vlc: [ProbedPicture] = []
        var state = 0   // 0 before, 1 the app's line, 2 after
        for line in log.components(separatedBy: "\n") {
            if line.hasPrefix("vlc: the app draws [") { state = line.hasPrefix("vlc: the app draws []") ? (state == 1 ? 2 : state) : 1 }
            guard let picture = probedPicture(line) else { continue }
            if state == 1 { app.append(picture) }
            if state == 2 { vlc.append(picture) }
        }
        return (app, vlc)
    }

    /// The app's subtitle line looks as VLC's: their text boxes on the
    /// picture (the same text on every line of the fixtures) lie within a
    /// few pixels of each other.
    private func checkTheAppsLineLooksAsVLCs(_ log: String, _ what: String) {
        let (app, vlc) = handoverPictures(in: log)
        let appBox = app.last(where: { $0.box != nil })?.box
        let vlcBox = vlc.first(where: { $0.box != nil })?.box
        print("\(what): the app's line \(String(describing: appBox)), VLC's \(String(describing: vlcBox))")
        guard let appBox, let vlcBox else { return XCTFail("\(what): a line of the app's and one of VLC's on the pictures") }
        XCTAssertEqual(Double(appBox.y0), Double(vlcBox.y0), accuracy: 2, "\(what): the top of the line")
        XCTAssertEqual(Double(appBox.y1), Double(vlcBox.y1), accuracy: 2, "\(what): the bottom of the line")
        XCTAssertEqual(Double(appBox.x0), Double(vlcBox.x0), accuracy: 3, "\(what): the left of the line")
        XCTAssertEqual(Double(appBox.x1), Double(vlcBox.x1), accuracy: 3, "\(what): the right of the line")
    }

    /// Switched to another subtitle track in the middle of a line (in
    /// software already): the new track's running line shows at once,
    /// drawn by the app, then VLC's from its next line, looking the same.
    private func checkRunningLineWhenSwitching(_ fixture: String, from start: String = "subtitles 1/2 en", to label: String,
                                               _ what: String) throws {
        let log = tempDir.appendingPathComponent("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        let video = try openVideo(fixture, vlc: true, extra: ["--test-log=\(log.path)"])
        eventually("the subtitles are on", timeout: 20) { text(of: video).contains(start) }
        waitForSoftwarePictures(of: video)
        func time(_ label: String) -> Int {
            guard let range = label.range(of: "time ") else { return -1 }
            return Int(label[range.upperBound...].prefix { $0.isNumber }) ?? -1
        }
        // In the middle of the line from 2 s to 4 s
        eventually("2.6 s in", timeout: 20) { time(text(of: video)) >= 2600 }
        let mark = logLength(log)
        app.typeKey("s", modifierFlags: [.control, .command])
        eventually("the other track") { text(of: video).contains(label) }
        eventually("VLC's lines again", timeout: 20) { logSince(log, mark).contains("vlc: the app's lines are over") }
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))   // VLC's next line, 2 s on
        let written = logSince(log, mark)
        let (app, vlc) = handoverPictures(in: written)
        print("\(what): the app's pictures \(app.map { $0.text == true ? "text" : "no text" }), VLC's \(vlc.compactMap { $0.text == true ? "text" : nil }.count) with text")
        XCTAssertEqual(app.first?.text, true, "\(what): the running line on the first picture after switching")
        XCTAssertTrue(vlc.contains { $0.text == true }, "\(what): VLC's next line")
        checkTheAppsLineLooksAsVLCs(written, what)
    }

    func testVLCShowsTheRunningASSLineWhenSwitchedTo() throws {
        try checkRunningLineWhenSwitching("tracks.mkv", to: "subtitles 2/2 de", "ASS")
    }

    func testVLCShowsTheRunningMovTextLineWhenSwitchedTo() throws {
        try checkRunningLineWhenSwitching("tracks.mp4", to: "subtitles 2/2 de", "mov_text")
    }

    /// At 1280 × 720: the app's SubRip line as VLC's (sizes and margins scale with the picture).
    func testVLCShowsTheRunningSubRipLineWhenSwitchedToInHD() throws {
        try checkRunningLineWhenSwitching("tracks720.mkv", from: "subtitles 1/2 de", to: "subtitles 2/2 en", "SubRip HD")
    }

    /// ASS lines with override tags (`asstags.mkv`: one at the top in red,
    /// bold and larger with a white outline, one placed by `\pos` in two
    /// italic underlined lines in another font): the app's running line
    /// where libass puts VLC's next one.
    func testVLCShowsTheRunningASSLineWithItsTagsWhenSwitchedTo() throws {
        try checkRunningLineWhenSwitching("asstags.mkv", to: "subtitles 2/2 de", "ASS tags")
    }

    /// Played to its end and started again (Space), the video opens with
    /// the subtitle track chosen last, its line from 0 on the first picture.
    func testVLCReplaysWithTheSubtitlesChosenLast() throws {
        let log = tempDir.appendingPathComponent("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        let video = try openVideo("tracks.mkv", vlc: true, extra: ["--test-log=\(log.path)"])
        eventually("the subtitles are on", timeout: 20) { text(of: video).contains("subtitles 1/2 en") }
        waitForSoftwarePictures(of: video)
        app.typeKey("s", modifierFlags: [.control, .command])
        eventually("the German ones") { text(of: video).contains("subtitles 2/2 de") }
        guard let line = logSince(log).components(separatedBy: "\n").first(where: { $0.hasPrefix("vlc: handing over subtitles ") }),
              let german = Int(line.dropFirst("vlc: handing over subtitles ".count).prefix { $0.isNumber }) else {
            return XCTFail("the German track handed over")
        }
        // To the end in 10 % steps, as fast as keys come (a key held down):
        // the last ones land in the video's last second or past it
        for _ in 0..<9 { app.typeKey(.rightArrow, modifierFlags: []) }
        let ended = Date()
        waitForBadge(containing: "Paused", timeout: 8)
        print("ended \(String(format: "%.1f", Date().timeIntervalSince(ended))) s after the last step: \(text(of: video))")
        let mark = logLength(log)
        app.typeKey(" ", modifierFlags: [])
        eventually("playing again", timeout: 20) { self.logSince(log, mark).contains("vlc picture 1 of media 2") }
        let written = logSince(log, mark)
        XCTAssertTrue(written.contains("vlc: media opened with subtitles \(german)\n"), "opened again with the German track (\(german))")
        let first = probedPictures(in: written).first { $0.media == 2 }
        XCTAssertEqual(first?.text, true, "the German line from 0 on the first picture")
    }

    /// The video started in software, decoding the subtitles from its first
    /// picture on, and was not opened again: its first pictures (the five
    /// the app logs) carry the line that begins at 0. `log`: the app's log
    /// of this launch.
    private func checkStartedInSoftware(_ video: XCUIElement, log: String) {
        let label = text(of: video)
        XCTAssertTrue(label.contains("decoding software"), "in software: \(label)")
        XCTAssertTrue(label.contains("media 1, "), "opened once, not again for the subtitles: \(label)")
        XCTAssertTrue(log.contains("vlc: software decoding for subtitles from the start"), "chosen before playing")
        XCTAssertFalse(log.contains("stopped at"), "never stopped to open it again")
        let first = probedPictures(in: log).filter { $0.media == 1 }
        let withText = first.first { $0.text == true }
        print("first pictures: \(first.map { "\($0.number): \($0.text == true ? "text" : "no text")" }.joined(separator: ", "))")
        XCTAssertNotNil(withText, "the line that begins at 0 in the first pictures")
        XCTAssertEqual(first.first?.text, true, "the line that begins at 0 on the first picture")
    }

    /// The log as far as written (before a launch: where its lines begin).
    private func logLength(_ log: URL) -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").count
    }

    /// The log written after `start` characters (`logLength` before the launch).
    private func logSince(_ log: URL, _ start: Int = 0) -> String {
        String(((try? String(contentsOf: log, encoding: .utf8)) ?? "").dropFirst(start))
    }

    /// The lower part of the picture, where the subtitles go, measured
    /// while a line shows: the fixtures' lines follow each other every 2 s
    /// up to their end at 20 s, so the video is paused, wherever it stands
    /// (a paused picture keeps the line of its own time, also just after a
    /// line began: Scripts/vlc-patches/0007, `VLCPausedSubtitleTests`), and
    /// the player's place checked (a slow runner may have played it to its
    /// end, and an even grey would read as no text). It plays on afterwards.
    private func measureWhileALineShows(_ video: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws -> ScreenStats {
        app.typeKey(" ", modifierFlags: [])
        waitForBadge(containing: "Paused", file: file, line: line)
        // The mouse off the video: the control bar goes and covers nothing
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).hover()
        settle(4)
        let place = playerClock()
        print("measured paused at \(String(describing: place)); \(text(of: video))")
        XCTAssertLessThan(place?.played ?? .infinity, 19.8, "paused while a line shows, before the end: \(String(describing: place))",
                          file: file, line: line)
        let picture = picture(in: video)
        let lower = CGRect(x: picture.minX + picture.width * 0.15, y: picture.minY + picture.height * 0.7,
                           width: picture.width * 0.7, height: picture.height * 0.28)
        let stats = try screenStats(of: lower, file: file, line: line)
        app.typeKey(" ", modifierFlags: [])
        eventually("playing on", file: file, line: line) { !self.text(of: self.badge).contains("Paused") }
        return stats
    }

    /// The subtitles inside the video are drawn over the picture, by AVKit
    /// and by VLC (into the pictures it hands over through its video
    /// callbacks): on the even grey clip the lower part of the picture,
    /// where they go, shows the text; with V it is even again.
    private func checkSubtitlesAreDrawn(_ fixture: String, vlc: Bool) throws {
        let log = tempDir.appendingPathComponent("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        let video = try openVideo(fixture, vlc: vlc, extra: ["--test-log=\(log.path)"])
        eventually("the subtitles are on", timeout: 20) { text(of: video).contains("subtitles 1/2 en") }
        if vlc {
            waitForSoftwarePictures(of: video)
            checkStartedInSoftware(video, log: logSince(log))
        }
        let shown = try measureWhileALineShows(video)
        let picture = picture(in: video)
        let lower = CGRect(x: picture.minX + picture.width * 0.15, y: picture.minY + picture.height * 0.7,
                           width: picture.width * 0.7, height: picture.height * 0.28)
        app.typeKey("v", modifierFlags: [])
        eventually("off") { text(of: video).contains("subtitles off/2") }
        settle(3)   // past the line that was showing (a line every 2 s)
        let hidden = try screenStats(of: lower)
        print("\(vlc ? "VLC" : "AVKit") \(fixture) subtitles: on ± \(shown.spread) (mean \(shown.mean)), off ± \(hidden.spread) (mean \(hidden.mean))")
        XCTAssertGreaterThan(hidden.mean, 0.3, "the picture is there")
        XCTAssertGreaterThan(shown.spread, 0.03, "on: text over the lower part of the picture (even grey: 0)")
        XCTAssertLessThan(hidden.spread, 0.01, "off: the lower part is even grey")
    }

    func testAVKitDrawsMovTextSubtitles() throws { try checkSubtitlesAreDrawn("tracks.mp4", vlc: false) }
    func testVLCDrawsSubRipSubtitles() throws { try checkSubtitlesAreDrawn("tracks.mkv", vlc: true) }
    func testVLCDrawsMovTextSubtitles() throws { try checkSubtitlesAreDrawn("tracks.mp4", vlc: true) }

    /// The ASS subtitles (libass) of the MKV, chosen with ⌃⌘S.
    func testVLCDrawsASSSubtitles() throws {
        let log = tempDir.appendingPathComponent("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        var video = try openVideo("tracks.mkv", vlc: true, extra: ["--test-log=\(log.path)"])
        eventually("the subtitles are on", timeout: 20) { text(of: video).contains("subtitles 1/2 en") }
        app.typeKey("s", modifierFlags: [.control, .command])
        eventually("the ASS track") { text(of: video).contains("subtitles 2/2 de") }
        // Chosen from the start (the language is kept): VLC reads a track
        // chosen later only from its next line on, and the fixture's one
        // line began at 0
        let mark = logLength(log)
        app.terminate()
        launch(open: tempDir.appendingPathComponent("tracks.mkv").path, resetState: false,
               extra: ["--force-vlc", "--test-log=\(log.path)"])
        video = element("video.vlc")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        eventually("the ASS track at once", timeout: 20) { text(of: video).contains("subtitles 2/2 de") }
        waitForSoftwarePictures(of: video)
        checkStartedInSoftware(video, log: logSince(log, mark))
        let shown = try measureWhileALineShows(video)
        print("VLC ASS subtitles: ± \(shown.spread) (mean \(shown.mean)); \(text(of: video))")
        XCTAssertGreaterThan(shown.spread, 0.05, "text over the lower part of the picture")
    }

    /// Subtitles switched on while VLC plays in hardware: it opens the video
    /// again in software and goes on at the picture it stood at, neither
    /// back nor ahead. `ramp.mkv` grows brighter with time (0.9 luma steps
    /// a picture), so a picture's luma tells where it is; the app logs the
    /// last picture before opening again and the first ones after.
    func testVLCGoesOnWhereItStoodWhenSubtitlesAreSwitchedOn() throws {
        let log = tempDir.appendingPathComponent("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        var video = try openVideo("ramp.mkv", vlc: true, extra: ["--test-log=\(log.path)"])
        eventually("the subtitles are on", timeout: 20) { text(of: video).contains("subtitles 1/1 en") }
        app.typeKey("v", modifierFlags: [])
        eventually("off") { text(of: video).contains("subtitles off/1") }
        // Started again with subtitles off (kept): in hardware
        let mark = logLength(log)
        app.terminate()
        launch(open: tempDir.appendingPathComponent("ramp.mkv").path, resetState: false,
               extra: ["--force-vlc", "--test-log=\(log.path)"])
        video = element("video.vlc")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        func time(_ label: String) -> Int {
            guard let range = label.range(of: "time ") else { return -1 }
            return Int(label[range.upperBound...].prefix { $0.isNumber }) ?? -1
        }
        eventually("playing a while in hardware", timeout: 20) {
            let label = text(of: video)
            return label.contains("decoding hardware") && time(label) >= 4000
        }
        let before = time(text(of: video))
        app.typeKey("v", modifierFlags: [])
        eventually("opened again in software", timeout: 20) { text(of: video).contains("media 2, ") }
        waitForSoftwarePictures(of: video)
        let written = logSince(log, mark)
        func luma(after marker: String) -> Int? {
            guard let range = written.range(of: marker) else { return nil }
            let rest = written[range.upperBound...]
            guard let l = rest.range(of: "luma ") else { return nil }
            return Int(rest[l.upperBound...].prefix { $0.isNumber })
        }
        let last = luma(after: "vlc: last picture before opening again: ")
        let next = probedPictures(in: written).first { $0.media == 2 }?.luma
        print("VLC switched to software at about \(before) ms (label); last picture luma \(last ?? -1), next \(next ?? -1)")
        if let last, let next {
            XCTAssertGreaterThanOrEqual(next, last - 2, "it went back: luma \(last) → \(next) (0.9 a picture)")
            XCTAssertLessThanOrEqual(next, last + 3, "it skipped ahead: luma \(last) → \(next) (0.9 a picture)")
        } else {
            XCTFail("the pictures around the switch are logged")
        }
        // The line running when it was switched on shows on the first picture
        // after it (the app's), then VLC's from its next line, looking the same
        let after = probedPictures(in: written).filter { $0.media == 2 }
        print("after switching: \(after.map { "\($0.number): \($0.text == true ? "text" : "no text")" }.joined(separator: ", "))")
        XCTAssertEqual(after.first?.text, true, "the running line on the first picture after switching on")
        eventually("VLC's lines again", timeout: 20) { self.logSince(log, mark).contains("vlc: the app's lines are over") }
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        checkTheAppsLineLooksAsVLCs(logSince(log, mark), "SubRip")
        let shown = try measureWhileALineShows(video)
        print("VLC ramp subtitles after switching: ± \(shown.spread) (mean \(shown.mean))")
        XCTAssertGreaterThan(shown.spread, 0.03, "text over the lower part of the picture")
    }

    /// The time a "… | <ms> ms" line of the app's log was written.
    private func loggedTime(of marker: String, in log: String) -> Double? {
        guard let line = log.components(separatedBy: "\n").first(where: { $0.contains(marker) }),
              let bar = line.range(of: " | ", options: .backwards) else { return nil }
        return Double(line[bar.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    /// Tracks that come late (a slow share, here held back 3 s with
    /// `--vlc-parse-delay`) don't hold the first picture: VLC starts in
    /// hardware after `VLCPlaybackControl.parseWait` and opens the video
    /// again in software once its subtitles are known, the line running
    /// then on the first picture shown after.
    func testVLCStartsAtOnceWhenItsTracksComeLate() throws {
        let log = tempDir.appendingPathComponent("app.log")
        continueAfterFailure = true   // the log below shows on a failure too
        defer { print("app log:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "(none)")) }
        let video = try openVideo("tracks.mkv", vlc: true, extra: ["--test-log=\(log.path)", "--vlc-parse-delay=3000"])
        eventually("the subtitles are on", timeout: 20) { text(of: video).contains("subtitles 1/2 en") }
        eventually("opened again in software", timeout: 20) { text(of: video).contains("media 2, ") }
        waitForSoftwarePictures(of: video)
        let written = logSince(log)
        XCTAssertTrue(written.contains("vlc: tracks not read within"), "played without the tracks")
        // The first picture shown (in hardware, or in software when the
        // subtitles came before it), with the line running then
        let opening = loggedTime(of: "vlc: opening", in: written)
        let first = loggedTime(of: "vlc picture 1 of media ", in: written)
        if let opening, let first {
            print("VLC with late tracks: first picture \(Int(first - opening)) ms after opening")
            XCTAssertLessThan(first - opening, 1500, "the first picture doesn't wait for the tracks")
        } else {
            XCTFail("opening and first picture logged")
        }
        let software = probedPictures(in: written).filter { $0.media == 2 }
        print("in software: \(software.map { "\($0.number): \($0.text == true ? "text" : "no text")" }.joined(separator: ", "))")
        XCTAssertEqual(software.first?.text, true, "the running line on the first picture in software")
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

    /// A PDF pages like a video seeks: → ← turn its pages (each drawn in its
    /// own colour, at fit, sharper when zoomed in), past the last page → is
    /// the next item, ⌘← comes back to its first page, before it ← is the
    /// previous item. `pages.pdf` (`Scripts/make_pdf_fixture.swift`): red, green (landscape), blue.
    func testAPDFIsShownPageByPage() throws {
        try put("pages.pdf", at: "bb.pdf")   // a.jpg, b.jpg, bb.pdf, c.jpg
        launch(open: tempDir.appendingPathComponent("bb.pdf").path)
        let image = element("fullImage")
        func colour() throws -> ScreenStats {
            // Left of the white square in the middle of each page
            let f = image.frame
            return try screenStats(of: CGRect(x: f.midX - f.height * 0.25, y: f.midY - 10, width: 20, height: 20))
        }
        func decoded() -> Int {
            let label = text(of: image)
            guard let range = label.range(of: "decoded ") else { return 0 }
            return Int(label[range.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        waitForBadge(containing: "3 / 4  ·  bb.pdf  ·  Page 1 / 3")
        eventually("page 1 drawn", timeout: 15) { self.text(of: image).hasSuffix("loaded, page 1 of 3") }
        settle(1)
        let red = try colour()
        XCTAssertTrue(red.red > 0.6 && red.green < 0.3, "page 1 is red: \(red)")

        let atFit = decoded()
        XCTAssertGreaterThan(atFit, 0, text(of: image))
        app.typeKey("+", modifierFlags: [])
        app.typeKey("+", modifierFlags: [])
        eventually("zoomed in: drawn again, larger", timeout: 15) {
            self.text(of: image).hasPrefix("zoom 156 %") && self.text(of: image).contains("page 1 of 3") && decoded() > atFit
        }

        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "Page 2 / 3")
        eventually("page 2 drawn at fit", timeout: 15) { self.text(of: image).hasPrefix("zoom 100 %") && self.text(of: image).hasSuffix("loaded, page 2 of 3") }
        settle(1)
        let green = try colour()
        XCTAssertTrue(green.green > 0.5 && green.red < 0.3, "page 2 is green: \(green)")

        app.typeKey(.rightArrow, modifierFlags: [])
        eventually("page 3 drawn", timeout: 15) { self.text(of: image).hasSuffix("loaded, page 3 of 3") }
        settle(1)
        let blue = try colour()
        XCTAssertTrue(blue.blue > 0.6 && blue.red < 0.3, "page 3 is blue: \(blue)")

        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "c.jpg")
        XCTAssertFalse(text(of: badge).contains("Page"), text(of: badge))

        app.typeKey(.leftArrow, modifierFlags: .command)
        waitForBadge(containing: "bb.pdf")
        waitForBadge(containing: "Page 1 / 3")
        eventually("its first page again", timeout: 15) { self.text(of: image).hasSuffix("loaded, page 1 of 3") }
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForBadge(containing: "b.jpg")
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
    /// at the top, at fit and when zoomed in (decoded again, larger).
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
                // "decoded <n> px": larger once zoomed in
                func decoded() -> Int {
                    let text = text(of: image)
                    guard let range = text.range(of: #"decoded (\d+) px"#, options: .regularExpression) else { return 0 }
                    return Int(text[range].split(separator: " ")[1]) ?? 0
                }
                let atFit = decoded()
                for _ in 0..<2 { app.typeKey("+", modifierFlags: []) }
                eventually("decoded again, larger", timeout: 15) { decoded() > atFit }
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
            app.typeKey(.space, modifierFlags: [])
            // A hung app can't answer the accessibility queries below (they
            // fail before any check of ours): a watchdog on its own thread
            // samples it after 12 s unless the badge has come
            let shown = WatchFlag()
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                guard !shown.isSet else { return }
                // The CI shell may sample it (the test runner may not)
                print("== \(name): no badge after 12 s; asking the shell for a sample")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("sample:\(name)", forType: .string)
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
