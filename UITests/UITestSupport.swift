import XCTest

/// Base for the end-to-end tests: each test gets a fresh temp folder with
/// real media fixtures, launches the real app on it (via `--open`) with its
/// own, reset preferences, and drives it through the accessibility layer.
class SchnellbildUITestCase: XCTestCase {
    var tempDir: URL!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sbui_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try put("sample.jpg", at: name) }
    }

    override func tearDownWithError() throws {
        app?.terminate()   // macOS apps are single-instance; the next test launches fresh
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: Fixtures

    /// Copy a bundled fixture (UITests/Fixtures) to `path` inside the temp folder.
    @discardableResult
    func put(_ fixture: String, at path: String) throws -> URL {
        let parts = fixture.split(separator: ".")
        let source = try XCTUnwrap(
            Bundle(for: SchnellbildUITestCase.self).url(forResource: String(parts[0]), withExtension: String(parts[1])),
            "missing fixture \(fixture)")
        let target = tempDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = tempDir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Launch

    @discardableResult
    func launch(open path: String? = nil, resetState: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-testing"]
        if resetState { args.append("--reset-state") }
        if let path { args += ["--open", path] }
        app.launchArguments = args
        app.launch()
        self.app = app
        return app
    }

    /// Launch on the temp folder and wait for the grid.
    @discardableResult
    func launchOnTempDir(waitFor name: String = "a.jpg") -> XCUIApplication {
        let app = launch(open: tempDir.path)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 15), "grid should show \(name)")
        return app
    }

    // MARK: Queries

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func tile(_ name: String) -> XCUIElement { element("tile.\(name)") }

    var searchField: XCUIElement { app.searchFields["searchField"] }

    /// Text of an element: SwiftUI exposes a Text via `label` *or* `value`.
    func text(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        let value = (element.value as? String) ?? ""
        return value.isEmpty ? element.label : value
    }

    func value(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return (element.value as? String) ?? ""
    }

    // MARK: Waiting

    /// Poll until `condition` holds (re-queries each time; cached elements
    /// don't re-evaluate).
    func eventually(_ message: String, timeout: TimeInterval = 10,
                    file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail(message, file: file, line: line)
    }

    /// The full view's position badge ("n / m  ·  name").
    var badge: XCUIElement { app.staticTexts["positionBadge"] }

    func waitForBadge(containing needle: String, timeout: TimeInterval = 15,
                      file: StaticString = #filePath, line: UInt = #line) {
        eventually("badge should contain “\(needle)”", timeout: timeout, file: file, line: line) {
            text(of: badge).contains(needle)
        }
    }

    func waitForSelected(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        eventually("\(name) should be selected", file: file, line: line) {
            value(of: tile(name)) == "selected"
        }
    }

    func clickMenu(_ menu: String, _ item: String) {
        app.menuBars.menuBarItems[menu].click()
        app.menuBars.menuItems[item].click()
    }
}
