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

    /// Launching with a file path opens that image directly in the full-size
    /// view — the position badge ("2 / 3  ·  b.jpg") is the only static text
    /// containing " / ".
    func testOpensImageFileInFullView() {
        let app = launchApp(openPath: tempDir.appendingPathComponent("b.jpg").path)
        // The position badge ("2 / 3  ·  b.jpg") is the only text containing
        // " / ". SwiftUI exposes a Text via `label` *or* `value`, so check both;
        // re-query each iteration (a cached firstMatch doesn't re-evaluate).
        var text: String?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let match = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS ' / ' OR value CONTAINS ' / '"))
                .firstMatch
            if match.exists { text = (match.value as? String) ?? match.label; break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertNotNil(text, "full-size view should open (position badge not found)")
        XCTAssertTrue(text?.contains("b.jpg") ?? false, "badge: \(text ?? "nil")")
    }
}
