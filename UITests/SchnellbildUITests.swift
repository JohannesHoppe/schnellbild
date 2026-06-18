import XCTest

/// End-to-end tests: launch the real app pointed at a temp folder (via the
/// `--open` launch argument) and drive it through the accessibility layer.
final class SchnellbildUITests: XCTestCase {
    private var tempDir: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fm = FileManager.default
        tempDir = fm.temporaryDirectory.appendingPathComponent("sbui_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()   // macOS apps are single-instance; ensure the next test launches fresh
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func launchApp(openPath: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--open", openPath]
        app.launch()
        self.app = app
        return app
    }

    /// The grid renders a tile (with filename label) for each image in the folder.
    func testGridShowsTilesForFolder() {
        let app = launchApp(openPath: tempDir.path)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15),
                      "a tile for a.jpg should appear")
        XCTAssertTrue(app.staticTexts["b.jpg"].exists)
        XCTAssertTrue(app.staticTexts["c.jpg"].exists)
    }

    /// F1 opens the keyboard-shortcuts help.
    func testF1ShowsShortcutsHelp() {
        let app = launchApp(openPath: tempDir.path)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))
        app.typeKey(.F1, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Keyboard Shortcuts"].waitForExistence(timeout: 5),
                      "F1 should open the shortcuts help")
    }

    /// Backspace in the grid navigates up one folder level.
    func testBackspaceGoesUpOneFolder() throws {
        let fm = FileManager.default
        let album = tempDir.appendingPathComponent("album")
        try fm.createDirectory(at: album, withIntermediateDirectories: true)
        try Data().write(to: album.appendingPathComponent("inside.jpg"))

        // Open the subfolder directly; it shows its own contents.
        let app = launchApp(openPath: album.path)
        XCTAssertTrue(app.staticTexts["inside.jpg"].waitForExistence(timeout: 15))

        // Backspace → up to the parent (tempDir), which contains "album".
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["album"].waitForExistence(timeout: 5),
                      "Backspace should navigate up to the parent folder")
    }

    /// Launching with a file path opens that image directly in the full-size
    /// view — the position badge ("2 / 3  ·  b.jpg") is the only static text
    /// containing " / ".
    func testOpensImageFileInFullView() {
        let app = launchApp(openPath: tempDir.appendingPathComponent("b.jpg").path)
        XCTAssertTrue(badge(app, contains: "b.jpg"), "launching a file should open the full-size view")
    }

    /// Return opens the full-size view; Escape returns to the grid (keyboard).
    func testReturnOpensFullViewAndEscapeReturns() {
        let app = launchApp(openPath: tempDir.path)
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 15))

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(badge(app, contains: "a.jpg"), "Return should open the full-size view")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["a.jpg"].waitForExistence(timeout: 5),
                      "Escape should return to the grid")
    }

    /// The position badge ("n / m  ·  name") is the only text containing " / ".
    /// SwiftUI exposes a Text via `label` *or* `value`, so check both, and
    /// re-query each iteration (a cached firstMatch doesn't re-evaluate).
    private func badge(_ app: XCUIApplication, contains needle: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS ' / ' OR value CONTAINS ' / '"))
                .firstMatch
            if match.exists {
                let text = (match.value as? String) ?? match.label
                if text.contains(needle) { return true }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }
}
