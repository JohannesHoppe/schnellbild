import XCTest

/// Takes the README screenshots (docs/screenshots). Runs only when the
/// environment names an output folder, i.e. in .github/workflows/screenshots.yml:
///   SCREENSHOT_DIR     where the PNGs go
///   SCREENSHOT_SUFFIX  appended to each name, e.g. "-dark"
/// (xcodebuild passes TEST_RUNNER_<name> to the test runner as <name>).
final class ReadmeScreenshots: SchnellbildUITestCase {
    private var outDir: URL!
    private var suffix = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SCREENSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("README screenshots only run with SCREENSHOT_DIR set")
        }
        outDir = URL(fileURLWithPath: dir, isDirectory: true)
        suffix = env["SCREENSHOT_SUFFIX"] ?? ""
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Not super: its fixtures (a.jpg …) don't belong in the pictures
        continueAfterFailure = false
        // The window title shows the folder name
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbshots_\(UUID().uuidString)/Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try SampleScenes.writeLibrary(to: tempDir)
    }

    private func shoot(_ name: String) throws {
        // Let thumbnails and animations settle
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let png = app.windows.firstMatch.screenshot().pngRepresentation
        let url = outDir.appendingPathComponent("\(name)\(suffix).png")
        try png.write(to: url)
        print("Wrote \(url.path)")
    }

    func testReadmeScreenshots() throws {
        launchOnTempDir(waitFor: "Lofoten")
        tile("Fjord at Sunset.jpg").click()
        waitForSelected("Fjord at Sunset.jpg")
        try shoot("grid")

        app.typeKey(.return, modifierFlags: [])
        let fullImage = element("fullImage")
        eventually("the image loads", timeout: 15) { text(of: fullImage).hasSuffix("loaded") }
        try shoot("full")

        app.typeKey("i", modifierFlags: [])
        try shoot("inspector")
        app.typeKey("i", modifierFlags: [])

        app.typeKey(.escape, modifierFlags: [])
        search("sunset")
        XCTAssertTrue(app.staticTexts["Sunset over the Dunes.jpg"].waitForExistence(timeout: 15))
        try shoot("search")
    }
}
