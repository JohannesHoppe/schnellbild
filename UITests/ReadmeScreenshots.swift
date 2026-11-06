import XCTest

/// Takes the README screenshots (docs/screenshots) as test attachments; the
/// workflow .github/workflows/screenshots.yml exports them from the result
/// bundle. Runs only with this environment (xcodebuild passes
/// TEST_RUNNER_<name> to the test runner as <name>):
///   SCREENSHOTS=1      take them
///   SCREENSHOT_SUFFIX  appended to each name, e.g. "-dark"
///   PHOTOS_DIR         the sample library (Scripts/make_sample_photos.swift),
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
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "\(name)\(suffix)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testReadmeScreenshots() throws {
        launchOnTempDir(waitFor: "Lofoten")
        tile("Fjord at Sunset.jpg").click()
        waitForSelected("Fjord at Sunset.jpg")
        shoot("grid")

        app.typeKey(.return, modifierFlags: [])
        let fullImage = element("fullImage")
        eventually("the image loads", timeout: 15) { text(of: fullImage).hasSuffix("loaded") }
        shoot("full")

        app.typeKey("i", modifierFlags: [])
        shoot("inspector")
        app.typeKey("i", modifierFlags: [])

        app.typeKey(.escape, modifierFlags: [])
        search("sunset")
        XCTAssertTrue(app.staticTexts["Sunset over the Dunes.jpg"].waitForExistence(timeout: 15))
        shoot("search")
    }
}
