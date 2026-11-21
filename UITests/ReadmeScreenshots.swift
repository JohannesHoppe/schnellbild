import XCTest
import AppKit

/// Takes the README screenshots (docs/screenshots), driven by
/// .github/workflows/screenshots.yml. A UI test can't photograph a window
/// with its shadow (nor write outside its container), so for each picture it
/// puts "shoot:<name>" on the pasteboard and waits for "done:<name>" from the
/// workflow's helper (Scripts/shoot_window.swift). Runs only with this
/// environment (xcodebuild passes TEST_RUNNER_<name> to the test runner as <name>):
///   SCREENSHOTS=1      take them
///   SCREENSHOT_SUFFIX  appended to each name, e.g. "-dark"
///   LANGUAGE           the app's language, a folder of Resources/Localization
///                      without ".lproj" (default "en")
///   PHOTOS_DIR         the sample library (Scripts/make_sample_media.swift),
///                      outside the runner's container so the status bar
///                      shows a short path
///   WORLD_DIR          the world trip (Scripts/fetch_world_photos.sh)
final class ReadmeScreenshots: SchnellbildUITestCase {
    private var suffix = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SCREENSHOTS"] == "1" else {
            throw XCTSkip("README screenshots only run with SCREENSHOTS=1")
        }
        suffix = env["SCREENSHOT_SUFFIX"] ?? ""
        uiLanguage = env["LANGUAGE"] ?? "en"
        // Not super: its fixtures (a.jpg …) don't belong in the pictures
        continueAfterFailure = false
        let photos = try XCTUnwrap(env["PHOTOS_DIR"], "PHOTOS_DIR missing")
        tempDir = URL(fileURLWithPath: photos, isDirectory: true)
    }

    /// The folder holding the photos and the world trip (`/Users/Shared`),
    /// opened to the app through the open panel as a user would.
    override var grantedRoot: URL { tempDir.deletingLastPathComponent() }

    override func tearDownWithError() throws {
        app?.terminate()   // keep the library: the dark run uses it too
    }

    /// The words the test looks for, in the app's language: the app's own
    /// translations (Resources/Localization, bundled with the tests too).
    private lazy var words: [String: String] = {
        guard uiLanguage != "en" else { return [:] }
        let path = Bundle(for: ReadmeScreenshots.self).path(forResource: "Localizable", ofType: "strings",
                                                            inDirectory: nil, forLocalization: uiLanguage)
        let words = path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] }
        XCTAssertNotNil(words, "no translations for \(uiLanguage)")
        return words ?? [:]
    }()

    private func ui(_ english: String) -> String { words[english] ?? english }

    /// `front`: the frontmost window (Settings), else the main one.
    private func shoot(_ name: String, settle: TimeInterval = 2.5, front: Bool = false) {
        // Let thumbnails and animations settle
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let picture = "\(name)\(suffix)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(front ? "shoot-front" : "shoot"):\(picture)", forType: .string)
        eventually("\(picture) photographed", timeout: 30) {
            pasteboard.string(forType: .string) == "done:\(picture)"
        }
    }

    /// The video's control bar in the middle of each of the sample video's
    /// six seconds, paused ("bartime-1" … "bartime-6": 0:01 / −0:06 …
    /// 0:06 / −0:01): Scripts/make_video_animation.py takes the times from
    /// them, so the bar counts along with the website's moving video. Left
    /// paused within the last seconds, so the video isn't resumed there later.
    private func shootVideoTimes() {
        // The bar shows while the mouse moves over the video and stays while
        // the mouse rests on it: here on the time played, off the slider
        element("video.avkit").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).hover()
        let bar = element("videoBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let rest = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5))
        rest.hover()
        // Paused: back to the start first, so it doesn't reach its end (which
        // pauses it too) between the look at the badge and the key
        let position = element("videoBar.position").firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        position.adjust(toNormalizedSliderPosition: 0)
        rest.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if !text(of: badge).contains(ui("Paused")) { app.typeKey(.space, modifierFlags: []) }
        waitForBadge(containing: ui("Paused"))
        for second in 1...6 {
            position.adjust(toNormalizedSliderPosition: (CGFloat(second) - 0.5) / 6)
            rest.hover()
            shoot("bartime-\(second)", settle: 1)
        }
    }

    func testReadmeScreenshots() throws {
        launchOnTempDir(waitFor: "Lofoten")
        tile("Fjord at Sunset.jpg").click()
        waitForSelected("Fjord at Sunset.jpg")
        shoot("grid")

        element("sortMenu").firstMatch.click()
        XCTAssertTrue(app.menuItems[ui("Date Taken")].waitForExistence(timeout: 5))
        shoot("sort")
        app.typeKey(.escape, modifierFlags: [])

        tile("Lofoten").click()
        waitForSelected("Lofoten")
        app.typeKey(.F2, modifierFlags: [])
        XCTAssertTrue(app.textFields["renameField"].waitForExistence(timeout: 5))
        shoot("rename")
        app.buttons[ui("Cancel")].firstMatch.click()

        app.typeKey(.F1, modifierFlags: [])
        XCTAssertTrue(app.staticTexts[ui("Full view")].waitForExistence(timeout: 5))
        shoot("help")
        app.buttons[ui("Done")].firstMatch.click()
        eventually("help closes") { !app.staticTexts[ui("Full view")].exists }

        tile("Fjord at Sunset.jpg").click()
        waitForSelected("Fjord at Sunset.jpg")
        app.typeKey(.space, modifierFlags: [])
        let fullImage = element("fullImage")
        eventually("the image loads", timeout: 15) { text(of: fullImage).hasSuffix("loaded") }
        shoot("full")

        for _ in 0..<4 { app.typeKey("+", modifierFlags: []) }
        shoot("zoom")
        app.typeKey("0", modifierFlags: [])

        app.typeKey("i", modifierFlags: [])
        shoot("inspector")
        app.typeKey("i", modifierFlags: [])

        app.typeKey("e", modifierFlags: [])   // auto enhance, its values on the sliders
        eventually("enhanced", timeout: 15) { text(of: fullImage).contains("enhanced") }
        app.typeKey("a", modifierFlags: [])
        XCTAssertTrue(element("slider.exposure").firstMatch.waitForExistence(timeout: 5))
        shoot("adjust")
        app.typeKey("a", modifierFlags: [])   // closes the sliders
        app.typeKey("e", modifierFlags: [])

        app.typeKey(.escape, modifierFlags: [])
        eventually("the full view closes") { !fullImage.exists }
        // The video's tile lies below the window's edge: the grid scrolls down to it
        let videoTile = tile("Sunset Timelapse.mp4")
        eventually("the video's tile can be clicked") {
            if videoTile.isHittable { return true }
            element("grid").firstMatch.scroll(byDeltaX: 0, deltaY: -200)
            return false
        }
        videoTile.click()
        waitForSelected("Sunset Timelapse.mp4")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // Playing (the sample video lasts 6 s, so no skimming ahead: it
        // would reach its end before the picture is taken): the website
        // lays the moving video over this picture (Scripts/make_video_animation.py)
        element("video.avkit").hover()   // the control bar shows
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5))
        shoot("video", settle: 0.5)
        if uiLanguage == "en" { shootVideoTimes() }

        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("s", modifierFlags: [])   // the whole library, full screen
        waitForBadge(containing: ui("Slideshow"))
        element("video.avkit").hover()   // the control bar shows
        _ = element("videoBar").waitForExistence(timeout: 5)
        shoot("slideshow", settle: 0.5)   // before the bar goes (3 s without the mouse moving)
        app.typeKey("p", modifierFlags: [])   // the playlist slides in
        XCTAssertTrue(element("playlist").firstMatch.waitForExistence(timeout: 5))
        shoot("playlist")
        app.typeKey(.escape, modifierFlags: [])   // the playlist goes
        eventually("the playlist closes") { !self.element("playlist").firstMatch.exists }
        app.typeKey(.escape, modifierFlags: [])   // then the show
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))   // out of full screen

        search("sunset")
        XCTAssertTrue(app.staticTexts["Sunset over the Dunes.jpg"].waitForExistence(timeout: 15))
        shoot("search")
        app.terminate()

        try newFeatureScreenshots()
    }

    /// The Atlas view on the sample library's Norway trip: the map with
    /// the timeline (a photo selected), and a frame of the tour. The Sun
    /// stands where it stood on the trip's last morning, so the globe shows
    /// Norway by day whenever the pictures are taken.
    func testAtlasScreenshots() throws {
        launch(open: tempDir.appendingPathComponent("Norway").path, extra: ["--globe-date=2026-06-18T10:30:00Z"])
        XCTAssertTrue(tile("Geirangerfjord.jpg").waitForExistence(timeout: 15))
        tile("Geirangerfjord.jpg").click()
        waitForSelected("Geirangerfjord.jpg")
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'atlas.'"))
        let deadline = Date().addingTimeInterval(20)
        while tiles.count < 3, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertGreaterThanOrEqual(tiles.count, 3, "the places on the map; count: \(text(of: element("atlasCount"))), "
            + "map: \(text(of: element("atlasMapState"))), strip: \(text(of: element("atlasStripTitle"))), empty: \(text(of: element("atlasEmpty"))), "
            + "tiles: \(tiles.allElementsBoundByIndex.map { $0.identifier + " " + self.text(of: $0) })")
        shoot("atlas", settle: 4)
        // Zoomed far out: the globe, the trip as one tile
        for _ in 0..<5 { app.typeKey("-", modifierFlags: []) }
        shoot("atlas-globe", settle: 4)
        for _ in 0..<5 { app.typeKey("+", modifierFlags: []) }

        app.typeKey("t", modifierFlags: [])
        let status = element("tourStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        // On to Geiranger (the fifth place), its photo shown, then held
        for _ in 0..<4 { app.typeKey(.rightArrow, modifierFlags: []) }
        eventually("Geiranger's photo", timeout: 15) { self.text(of: status).contains("showing") }
        app.typeKey(.space, modifierFlags: [])
        eventually("held") { self.text(of: status).hasSuffix("paused") }
        shoot("tour", settle: 2)
        app.typeKey(.escape, modifierFlags: [])
        eventually("the tour ended", timeout: 10) { !status.exists }
        RunLoop.current.run(until: Date().addingTimeInterval(2))   // out of full screen
    }

    /// The Atlas's globe close up over the Norway trip, for the website's four
    /// views: tilted towards the horizon, the relief exaggerated as the app
    /// shows it, the Sun low on a June evening, the trip's photos on the fjords.
    static let nearCameras = [("61.0,6.9,6.8,62,0", "2026-06-16T13:00:00Z"), ("61.0,6.9,6.8,62,0", "2026-06-16T16:30:00Z"),
                              ("60.7,7.0,7.0,66,10", "2026-06-16T15:00:00Z"), ("61.3,6.6,6.6,58,340", "2026-06-16T15:00:00Z"),
                              ("60.9,6.4,6.8,64,30", "2026-06-16T15:00:00Z"), ("60.6,7.3,7.0,70,350", "2026-06-16T16:00:00Z")]

    func testAtlasGlobeNearScreenshots() throws {
        for (index, (camera, date)) in Self.nearCameras.enumerated() {
            launch(open: tempDir.appendingPathComponent("Norway").path,
                   extra: ["--globe-camera=\(camera)", "--globe-date=\(date)"])
            XCTAssertTrue(tile("Geirangerfjord.jpg").waitForExistence(timeout: 15))
            app.typeKey("w", modifierFlags: [])
            XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
            let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'atlas.'"))
            let deadline = Date().addingTimeInterval(20)
            while tiles.count < 3, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            shoot("atlas-globe-near-\(index + 1)", settle: 6)
            app.terminate()
        }
    }

    /// The globe for the website's hero: the world trip (`WORLD_DIR`, real
    /// photographs from Scripts/build_world_photos.py) in the Atlas view,
    /// seen from low orbit over the Mediterranean as the Sun rises behind
    /// the horizon, and the whole Earth by day with the trip's pins.
    func testGlobeScreenshots() throws {
        let world = try XCTUnwrap(ProcessInfo.processInfo.environment["WORLD_DIR"], "WORLD_DIR missing")
        for (name, camera, date) in [("globe-hero", "41,16,5.4,72,48", "2026-06-21T02:12:00Z"),
                                     ("globe-world", "38,20,2.7,0,0", "2026-06-21T10:30:00Z")] {
            launch(open: world, extra: ["--globe-camera=\(camera)", "--globe-date=\(date)"])
            XCTAssertTrue(tile("Rome-Colosseum.jpg").waitForExistence(timeout: 15))
            app.typeKey("w", modifierFlags: [])
            XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
            let pins = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'atlas.'"))
            let deadline = Date().addingTimeInterval(20)
            while pins.count < 4, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            XCTAssertGreaterThanOrEqual(pins.count, 4, "several pins on the globe: \(text(of: element("atlasMapState")))")
            shoot(name, settle: 6)
            app.terminate()
        }
    }

    /// Archives, other files, the password sheet, the mini keyboard, a new
    /// folder, the volume.
    private func newFeatureScreenshots() throws {
        // The archives and other files are made by the workflow (screenshots.yml)
        let photos = try FileManager.default.subpathsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(".jpg") && !$0.hasPrefix(".") }.sorted()

        launch(open: tempDir.path, extra: ["--hold-volume-display", "--hold-video-bar"])
        XCTAssertTrue(tile("Iceland 2025.zip").waitForExistence(timeout: 15))
        XCTAssertTrue(element("otherFiles").waitForExistence(timeout: 10))
        tile("Iceland 2025.zip").click()
        element("grid").firstMatch.scroll(byDeltaX: 0, deltaY: -2000)   // down to the other files
        shoot("archives")

        // Inside the archive: its name in the title bar (its pictures are named
        // like some outside it), back up where its tile is
        element("grid").firstMatch.scroll(byDeltaX: 0, deltaY: 2000)
        open(tile("Iceland 2025.zip"), until: "the archive opened") { self.text(of: self.element("folderTitle").firstMatch) == "Iceland 2025.zip" }
        XCTAssertTrue(app.staticTexts[(photos.first! as NSString).lastPathComponent].waitForExistence(timeout: 15))
        shoot("archive-inside")
        app.typeKey(.delete, modifierFlags: [])   // Backspace: back
        XCTAssertTrue(tile("Private.zip").waitForExistence(timeout: 15))

        openTile("Private.zip", showing: app.secureTextFields["passwordField"])
        shoot("password")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tile("Private.zip").waitForExistence(timeout: 15))

        app.typeKey("k", modifierFlags: [])
        XCTAssertTrue(element("miniKeyboard").waitForExistence(timeout: 5))
        tile("Lofoten").click()
        shoot("keyboard")
        app.typeKey("k", modifierFlags: [])

        app.typeKey("n", modifierFlags: [.command, .shift])
        let field = app.textFields["newFolderField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Best of")
        shoot("newfolder")
        app.typeKey(.escape, modifierFlags: [])   // made none

        openTile("Sunset Timelapse.mp4", showing: element("video.avkit"))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: ui("Paused"))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element("volumeDisplay").waitForExistence(timeout: 5))
        shoot("volume", settle: 0.5)

        // The list view of the library (archives and other files included)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tile("Lofoten").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(element("list").waitForExistence(timeout: 5))
        // From the top (".." in view), in light and dark alike
        app.typeKey(.home, modifierFlags: [])
        // A photo selected, in full view (not the video below the edge)
        let row = element("row.Fjord at Sunset.jpg").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        shoot("list")
        app.typeKey("l", modifierFlags: [])

        // The dual pane: the trip on the right, two photos marked on the left
        app.typeKey("d", modifierFlags: [])
        let left = element("pane.left"), right = element("pane.right")
        XCTAssertTrue(right.waitForExistence(timeout: 10))
        let rightTrip = right.descendants(matching: .any).matching(identifier: "tile.Lofoten").firstMatch
        XCTAssertTrue(rightTrip.waitForExistence(timeout: 15))
        // Inside the trip ("tile..." is in the library too)
        let inTrip = right.descendants(matching: .any).matching(identifier: "tile.Northern Lights.jpg").firstMatch
        open(rightTrip, until: "inside the trip") { inTrip.exists }
        let leftPhoto = left.descendants(matching: .any).matching(identifier: "tile.Fjord at Sunset.jpg").firstMatch
        XCTAssertTrue(leftPhoto.waitForExistence(timeout: 10))
        leftPhoto.click()
        app.typeKey(.rightArrow, modifierFlags: .shift)
        shoot("dualpane")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("d", modifierFlags: [])
        eventually("one pane again") { !self.element("pane.right").exists }

        // Settings (⌘,)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("settings.slideshowSeconds").waitForExistence(timeout: 5))
        shoot("settings", front: true)
        // Its Keyboard tab: every action's keys
        let keyboardTab = [app.toolbars.buttons[ui("Keyboard")], app.radioButtons[ui("Keyboard")]].map(\.firstMatch).first { $0.exists }
        XCTAssertNotNil(keyboardTab, "the Keyboard tab")
        keyboardTab?.click()
        XCTAssertTrue(element("shortcuts.list").waitForExistence(timeout: 5))
        shoot("shortcuts", front: true)
        app.typeKey("w", modifierFlags: .command)
    }
}
