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
///   PHOTOS_DIR         the sample library (Scripts/make_sample_media.swift),
///                      outside the runner's container so the status bar
///                      shows a short path
final class ReadmeScreenshots: SchnellbildUITestCase {
    private var suffix = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SCREENSHOTS"] == "1" else {
            throw XCTSkip("README screenshots only run with SCREENSHOTS=1")
        }
        suffix = env["SCREENSHOT_SUFFIX"] ?? ""
        // Not super: its fixtures (a.jpg …) don't belong in the pictures
        continueAfterFailure = false
        let photos = try XCTUnwrap(env["PHOTOS_DIR"], "PHOTOS_DIR missing")
        tempDir = URL(fileURLWithPath: photos, isDirectory: true)
    }

    override func tearDownWithError() throws {
        app?.terminate()   // keep the library: the dark run uses it too
    }

    private func shoot(_ name: String) {
        // Let thumbnails and animations settle
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let picture = "\(name)\(suffix)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("shoot:\(picture)", forType: .string)
        eventually("\(picture) photographed", timeout: 30) {
            pasteboard.string(forType: .string) == "done:\(picture)"
        }
    }

    func testReadmeScreenshots() throws {
        launchOnTempDir(waitFor: "Lofoten")
        tile("Fjord at Sunset.jpg").click()
        waitForSelected("Fjord at Sunset.jpg")
        shoot("grid")

        element("sortMenu").firstMatch.click()
        XCTAssertTrue(app.menuItems["Date Taken"].waitForExistence(timeout: 5))
        shoot("sort")
        app.typeKey(.escape, modifierFlags: [])

        tile("Lofoten").click()
        waitForSelected("Lofoten")
        app.typeKey(.F2, modifierFlags: [])
        XCTAssertTrue(app.textFields["renameField"].waitForExistence(timeout: 5))
        shoot("rename")
        app.buttons["Cancel"].firstMatch.click()

        app.typeKey(.F1, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Full view"].waitForExistence(timeout: 5))
        shoot("help")
        app.buttons["Done"].firstMatch.click()
        eventually("help closes") { !app.staticTexts["Full view"].exists }

        tile("Fjord at Sunset.jpg").click()
        waitForSelected("Fjord at Sunset.jpg")
        app.typeKey(.return, modifierFlags: [])
        let fullImage = element("fullImage")
        eventually("the image loads", timeout: 15) { text(of: fullImage).hasSuffix("loaded") }
        shoot("full")

        for _ in 0..<4 { app.typeKey("+", modifierFlags: []) }
        shoot("zoom")
        app.typeKey("0", modifierFlags: [])

        app.typeKey("i", modifierFlags: [])
        shoot("inspector")
        app.typeKey("i", modifierFlags: [])

        app.typeKey(.escape, modifierFlags: [])
        tile("Sunset Timelapse.mp4").click()
        waitForSelected("Sunset Timelapse.mp4")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.rightArrow, modifierFlags: [])   // skim ahead, as in the README
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        shoot("video")

        app.typeKey(.escape, modifierFlags: [])
        tile("Lofoten").click()
        waitForSelected("Lofoten")
        app.typeKey("s", modifierFlags: [])   // the selected folder, full screen
        waitForBadge(containing: "Slideshow")
        shoot("slideshow")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))   // out of full screen

        search("sunset")
        XCTAssertTrue(app.staticTexts["Sunset over the Dunes.jpg"].waitForExistence(timeout: 15))
        shoot("search")
    }
}
