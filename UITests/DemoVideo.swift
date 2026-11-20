import XCTest
import AppKit

/// Drives the app through the demo video's script on the sample library's
/// Norway trip, at a pace a person can follow: the grid, a few photos in the
/// full view, the Atlas, out to the globe, and the tour diving in from there.
/// Driven by .github/workflows/demo-video.yml, whose shell records the
/// screen (only it holds the permission): the test asks over the pasteboard
/// ("record:start", "record:stop") and waits for the answer ("recording",
/// "stopped"). It prints a line "DEMO-MARK <seconds since 1970> <scene>" at
/// each scene, the workflow's log keeps them for cutting. Runs only with
/// this environment (xcodebuild passes TEST_RUNNER_<name> to the test
/// runner as <name>):
///   DEMO_VIDEO=1   record it
///   LANGUAGE       the app's language, a folder of Resources/Localization
///                  without ".lproj" (default "en")
///   PHOTOS_DIR     the sample library (Scripts/make_sample_media.swift)
///   TOUR_STATIONS  how many of the tour's stations to show before it ends
///                  (default all of them)
final class DemoVideo: SchnellbildUITestCase {
    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DEMO_VIDEO"] == "1" else { throw XCTSkip("the demo video only runs with DEMO_VIDEO=1") }
        uiLanguage = env["LANGUAGE"] ?? "en"
        continueAfterFailure = false
        let photos = try XCTUnwrap(env["PHOTOS_DIR"], "PHOTOS_DIR missing")
        tempDir = URL(fileURLWithPath: photos, isDirectory: true)
    }

    /// The folder holding the sample library (`/Users/Shared`).
    override var grantedRoot: URL { tempDir.deletingLastPathComponent() }

    override func tearDownWithError() throws {
        app?.terminate()   // the library stays: the workflow made it
    }

    /// The app's own words in its language (Resources/Localization).
    private lazy var words: [String: String] = {
        guard uiLanguage != "en" else { return [:] }
        let path = Bundle(for: DemoVideo.self).path(forResource: "Localizable", ofType: "strings",
                                                    inDirectory: nil, forLocalization: uiLanguage)
        return path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
    }()

    private func ui(_ english: String) -> String { words[english] ?? english }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func mark(_ scene: String) {
        print(String(format: "DEMO-MARK %.3f %@", Date().timeIntervalSince1970, scene))
    }

    /// Asks the workflow's shell for `request` and waits for `answer`.
    private func ask(_ request: String, answer: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(request, forType: .string)
        eventually("the shell answers \(answer)", timeout: 60) {
            pasteboard.string(forType: .string) == answer
        }
    }

    /// The pointer out of the way: the window's bottom right corner, over
    /// the status bar (in full screen nothing shows there on hover).
    private func pointerAside() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995)).hover()
    }

    func testDemoVideo() throws {
        let stations = Int(ProcessInfo.processInfo.environment["TOUR_STATIONS"] ?? "") ?? .max
        // The globe by day over Europe, as on the trip's first morning
        launch(open: tempDir.appendingPathComponent("Norway").path, extra: ["--globe-date=2026-06-14T10:00:00Z"])
        XCTAssertTrue(tile("Alesund from Aksla.jpg").waitForExistence(timeout: 15))
        tile("Alesund from Aksla.jpg").click()
        waitForSelected("Alesund from Aksla.jpg")
        app.typeKey("f", modifierFlags: [.control, .command])   // full screen: no menu bar, no desktop
        pointerAside()
        pause(3)   // the move into full screen
        for _ in 0..<2 { app.typeKey("+", modifierFlags: []) }   // larger thumbnails: the trip fills the screen
        // The map's tiles and the globe's textures made once before the
        // recording, so neither shows grey while it loads: the Atlas, out
        // to the globe and back by keys (the same camera again), the grid
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
        pause(4)
        for _ in 0..<4 { app.typeKey("-", modifierFlags: []); pause(1) }
        pause(3)
        for _ in 0..<4 { app.typeKey("+", modifierFlags: []); pause(0.5) }
        pause(2)
        app.typeKey("w", modifierFlags: [])
        waitForSelected("Alesund from Aksla.jpg")
        pause(3)   // the thumbnails settled
        ask("record:start", answer: "recording")
        pause(1)

        mark("grid")
        pause(1.5)
        for _ in 0..<3 {
            app.typeKey(.rightArrow, modifierFlags: [])
            pause(0.45)
        }
        waitForSelected("Bryggen Morning.jpg")
        pause(0.8)

        mark("full view")
        app.typeKey(.space, modifierFlags: [])
        let fullImage = element("fullImage")
        eventually("the photo loads", timeout: 15) { self.text(of: fullImage).hasSuffix("loaded") }
        pause(1.8)
        for _ in 0..<2 {
            app.typeKey(.rightArrow, modifierFlags: [])
            pause(1.6)
        }
        app.typeKey(.escape, modifierFlags: [])
        pause(1)

        mark("atlas")
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'atlas.'"))
        eventually("the places on the map", timeout: 20) { tiles.count >= 3 }
        pause(3)

        mark("globe")
        let zoomOut = app.buttons[ui("Zoom out")].firstMatch
        XCTAssertTrue(zoomOut.waitForExistence(timeout: 5), "the map's Zoom out button")
        for _ in 0..<4 {
            zoomOut.click()
            pause(0.6)
        }
        pointerAside()   // before the button's tooltip shows
        pause(2.5)

        mark("tour")
        app.typeKey("t", modifierFlags: [])
        let status = element("tourStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        if stations < .max {
            // Until the station after the last one wanted is reached
            eventually("\(stations) stations shown", timeout: 120) {
                self.text(of: status).contains("\(stations + 1) of")
            }
            mark("tour end")
            app.typeKey(.escape, modifierFlags: [])
        } else {
            mark("tour runs to its end")
        }
        eventually("the tour ended", timeout: 120) { !status.exists }
        mark("atlas again")
        pause(2.5)

        ask("record:stop", answer: "stopped")
        mark("stopped")
    }
}
