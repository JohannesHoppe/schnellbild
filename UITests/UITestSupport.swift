import XCTest
import AppKit

/// Base for the end-to-end tests: each test gets a fresh temp folder with
/// real media fixtures, launches the real app on it (via `--open`) with its
/// own, reset preferences, and drives it through the accessibility layer.
///
/// The app runs in the App Sandbox exactly as it ships (CI launches the
/// bundle `build_app.sh` made, `SCHNELLBILD_APP`; `check_entitlements.sh`
/// holds it to `Sandbox/Schnellbild.entitlements`). So it reads only what
/// the user opened to it: the temp folders lie in `fixtureRoot`, outside
/// every app's container, which the app is given the way a user gives it,
/// through the open panel (`Grants.root`, once a run; every later launch
/// opens it again from its security-scoped bookmark). The test runner, which
/// never ships, may write there (`UITests/Runner.entitlements`).
class SchnellbildUITestCase: XCTestCase {
    var tempDir: URL!
    var app: XCUIApplication!
    /// The app's language where a launch names none.
    var uiLanguage = "en"

    /// Where every test's folders lie (made by the CI shell).
    static let fixtureRoot = URL(fileURLWithPath: "/Users/Shared/SchnellbildUITests", isDirectory: true)
    /// The folder `Grants.root` opens to the app: the fixture root (the
    /// screenshots: the folder holding their photos).
    var grantedRoot: URL { Self.fixtureRoot }
    /// The folder opened to the app through the open panel in this run (no
    /// launch has dropped the grants since).
    static var rootGranted: URL?

    /// What the app may read when it starts.
    enum Grants {
        /// `fixtureRoot`, granted through the open panel (as by a user who
        /// opened that folder before)
        case root
        /// What the last launch left (a relaunch)
        case kept
        /// Nothing: the app as on a Mac where no folder was opened to it yet
        case nothing
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        tempDir = Self.fixtureRoot.appendingPathComponent("sbui_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try put("sample.jpg", at: name) }
    }

    override func tearDownWithError() throws {
        // A failed test may leave a slideshow in full screen, which macOS would
        // bring back on the next launch (and hide the menu bar): Esc ends it.
        if let app, app.state == .runningForeground {
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
        }
        app?.terminate()   // macOS apps are single-instance; the next test launches fresh
        // A failed test: what the app logged (folder access, listings)
        if tempDir != nil, (testRun?.failureCount ?? 0) > 0 {
            print("app log of \(name):\n" + ((try? String(contentsOf: testLog("app.log"), encoding: .utf8)) ?? "(none)"))
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: Fixtures

    /// Copy a bundled fixture (UITests/Fixtures) to `path` inside the temp folder.
    @discardableResult
    func put(_ fixture: String, at path: String) throws -> URL {
        // The last extension only: "photos-vols.part1.rar", "photos-cut.rar.part"
        let name = (fixture as NSString).deletingPathExtension, ext = (fixture as NSString).pathExtension
        let source = try XCTUnwrap(
            Bundle(for: SchnellbildUITestCase.self).url(forResource: name, withExtension: ext),
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

    /// Launches the app. `grants`: by default the fixture root for a fresh
    /// start (`resetState`), what the last launch left for a relaunch.
    @discardableResult
    func launch(open path: String? = nil, resetState: Bool = true, extra: [String] = [],
                language: String? = nil, grants: Grants? = nil) -> XCUIApplication {
        var extra = extra
        switch grants ?? (resetState ? .root : .kept) {
        case .root: grantFixtureRoot()
        case .kept: break
        case .nothing:
            extra.append("--reset-grants")
            Self.rootGranted = nil
        }
        let language = language ?? uiLanguage
        let app = Self.makeApp()
        // English unless a test asks otherwise, whatever the runner's
        // language: the tests match UI text. AppKit reads "-name value"
        // pairs, so these pairs come first and every argument after them
        // starts with "-": a value left without its name would be taken
        // for a file to open, and the app would show no window.
        // No restored windows: a window that was in full screen when an
        // earlier launch ended (a slideshow) would open in full screen again.
        var args = ["-AppleLanguages", "(\(language))", "-AppleLocale", Self.locale(of: language),
                    "-ApplePersistenceIgnoreState", "YES",
                    "--ui-testing"] + extra
        // A log of its own unless the test reads one: printed when the test fails
        if !extra.contains(where: { $0.hasPrefix("--test-log=") }) { args.append("--test-log=\(testLog("app.log").lastPathComponent)") }
        if resetState { args.append("--reset-state") }
        if let path { args.append("--open=\(path)") }
        app.launchArguments = args
        app.launch()
        self.app = app
        return app
    }

    /// Quits the app as a user does (⌘Q), so it counts the folders it
    /// reopened at launch as harmless (a launch ended otherwise within 15 s
    /// doesn't reopen them next time: `restoreUnconfirmed`).
    func quitApp(file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("q", modifierFlags: .command)
        eventually("the app quits", timeout: 10, file: file, line: line) { self.app.state == .notRunning }
    }

    /// The app under test: the bundle CI built and signed as it ships
    /// (`SCHNELLBILD_APP`, through `TEST_RUNNER_SCHNELLBILD_APP`), else the
    /// Xcode build's.
    static func makeApp() -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["SCHNELLBILD_APP"], !path.isEmpty else { return XCUIApplication() }
        return XCUIApplication(url: URL(fileURLWithPath: path))
    }

    /// Opens `grantedRoot` to the app through the open panel, once a run
    /// (and again after a launch that dropped the grants).
    func grantFixtureRoot() {
        let root = grantedRoot
        guard Self.rootGranted != root else { return }
        let app = Self.makeApp()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES",
                               "--ui-testing", "--reset-state", "--reset-grants"]
        app.launch()
        self.app = app
        grantThroughOpenPanel(root)
        XCTAssertTrue(tile(tempDir.lastPathComponent).waitForExistence(timeout: 15), "\(root.path) opened to the app")
        app.terminate()
        Self.rootGranted = root
    }

    /// Opens `folder` to the app as a user does: Open Folder… (⌘O), then the
    /// folder chosen in the open panel.
    func grantThroughOpenPanel(_ folder: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "a window", file: file, line: line)
        app.typeKey("o", modifierFlags: .command)
        chooseInOpenPanel(folder, file: file, line: line)
    }

    /// The open panel is up (Open Folder…, Allow Access…): `folder` is chosen
    /// in it, its path typed into Go to Folder (⇧⌘G), then the panel's
    /// button (Return).
    func chooseInOpenPanel(_ folder: URL, file: StaticString = #filePath, line: UInt = #line) {
        let panel = waitForOpenPanel(file: file, line: line)
        // Again when the panel took the keys too early (seen on CI: ⇧⌘G
        // lost, the panel stayed where it was)
        for _ in 0..<3 where panel.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.typeKey("g", modifierFlags: [.command, .shift])
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            app.typeText(folder.path)
            app.typeKey(.return, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            app.typeKey(.return, modifierFlags: [])
            let deadline = Date().addingTimeInterval(4)
            while panel.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        closed(panel, file: file, line: line)
    }

    /// Drops `file` from the Finder onto the app's window, as a user drags
    /// it: the Finder shows it selected in its folder's window, its icon is
    /// dragged onto the Browse zone (the window's left half), below the
    /// Finder's window, which covers most of the app's on the runner's small
    /// screen. The Finder's windows are closed before and after: each new
    /// one opens further down than the last (seen on CI: after five drops it
    /// lay over the place dropped on, and the icon was dropped into itself).
    func dropFromFinder(_ file: URL, file sourceFile: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "a window", file: sourceFile, line: line)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        closeFinderWindows(finder)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        let folder = finder.windows.matching(NSPredicate(format: "title == %@", file.deletingLastPathComponent().lastPathComponent)).firstMatch
        let item = folder.descendants(matching: .any).matching(identifier: file.lastPathComponent).firstMatch
        if !item.waitForExistence(timeout: 15) {
            print("the Finder doesn't show \(file.lastPathComponent):\n\(finder.debugDescription)")
            XCTFail("the Finder shows \(file.lastPathComponent)", file: sourceFile, line: line)
            return
        }
        // Below the Finder's window: halfway between its bottom and the app window's
        let finderFrame = folder.frame, appFrame = window.frame
        let frames = "Finder window \(finderFrame), item \(item.frame), app window \(appFrame)"
        print("finder drop: \(frames)")
        guard finderFrame.maxY < appFrame.maxY - 20 else {
            XCTFail("the Finder's window covers the app's: \(frames)", file: sourceFile, line: line)
            return
        }
        // The Finder's window settled (its icons drawn, the item where it stays)
        var last = item.frame
        let settle = Date().addingTimeInterval(5)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let now = item.frame
            if now == last, item.isHittable { break }
            last = now
        } while Date() < settle
        let y = (max(finderFrame.maxY, appFrame.minY) + appFrame.maxY) / 2
        let target = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: (y - appFrame.minY) / appFrame.height))
        // Held over the window before the button comes up, as a hand does:
        // the window hears the drag enter before it is dropped
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: target, withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 1)
        // What reached the app (its log); without it, the screen is kept
        let log = testLog("app.log")
        let deadline = Date().addingTimeInterval(5)
        func seen() -> Bool { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(" drop") }
        while !seen(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        print("finder drop: the app's drop lines: "
              + ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains(" drop") || $0.contains("drag over") }.joined(separator: " | "))
        if !seen() {
            print("finder drop: nothing reached the app (\(frames))\n\(finder.debugDescription)")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("shot:finder-drop-\(tempDir.lastPathComponent):0,0,1024,768", forType: .string)
            RunLoop.current.run(until: Date().addingTimeInterval(3))
        }
        closeFinderWindows(finder)
        app.activate()
    }

    /// Every Finder window closed (⌥⌘W in the Finder).
    private func closeFinderWindows(_ finder: XCUIApplication) {
        let windows = finder.windows.matching(identifier: "FinderWindow")
        guard windows.count > 0 else { return }
        finder.activate()
        finder.typeKey("w", modifierFlags: [.command, .option])
        eventually("the Finder's windows closed", timeout: 5) { windows.count == 0 }
    }

    /// The open panel is up at the folder it was opened at: its button
    /// (Return) chooses that folder.
    func confirmOpenPanel(file: StaticString = #filePath, line: UInt = #line) {
        let panel = waitForOpenPanel(file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.return, modifierFlags: [])
        closed(panel, file: file, line: line)
    }

    private func waitForOpenPanel(file: StaticString, line: UInt) -> XCUIElement {
        let panel = openPanel
        if !panel.waitForExistence(timeout: 10) {
            print("no open panel; the app's elements:\n\(app.debugDescription)")
            XCTFail("the open panel", file: file, line: line)
        }
        return panel
    }

    private func closed(_ panel: XCUIElement, file: StaticString, line: UInt) {
        let deadline = Date().addingTimeInterval(10)
        while panel.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        if panel.exists {
            print("the open panel stays; the app's elements:\n\(app.debugDescription)")
            XCTFail("the open panel closes", file: file, line: line)
        }
    }

    /// The open panel (a window of the app; the sandbox shows it from
    /// another process).
    var openPanel: XCUIElement {
        app.dialogs["open-panel"].firstMatch
    }

    /// Where the app writes this test's log `name`: pass
    /// `--test-log=<its lastPathComponent>`. In the app's container (its
    /// temporary folder), named after the test's folder, so no other test's
    /// lines are in it.
    func testLog(_ name: String) -> URL {
        Self.appLogFile("\(tempDir.lastPathComponent)-\(name)")
    }

    static func appLogFile(_ name: String) -> URL {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Containers/art.haushoppe.schnellbild/Data/tmp/\(name)")
    }

    /// The locale that goes with an app language (Resources/Localization),
    /// so dates and numbers are written as there.
    static func locale(of language: String) -> String {
        let locales = ["en": "en_US", "de": "de_DE", "fr": "fr_FR", "es": "es_ES", "it": "it_IT",
                       "pt-BR": "pt_BR", "nl": "nl_NL", "pl": "pl_PL", "sv": "sv_SE", "da": "da_DK",
                       "nb": "nb_NO", "fi": "fi_FI", "cs": "cs_CZ", "tr": "tr_TR", "ru": "ru_RU",
                       "uk": "uk_UA", "ja": "ja_JP", "ko": "ko_KR", "zh-Hans": "zh-Hans_CN", "zh-Hant": "zh-Hant_TW"]
        return locales[language] ?? language
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

    func tile(_ name: String) -> XCUIElement { element("tile.\(name)").firstMatch }

    /// From the grid to the Atlas: L shows the list, L again the Atlas.
    func showAtlasFromTheGrid(file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(element("list").waitForExistence(timeout: 10), "L: the list first", file: file, line: line)
        app.typeKey("l", modifierFlags: [])
    }

    var searchField: XCUIElement { app.searchFields["searchField"] }

    /// Click into the search field and type a query.
    func search(_ query: String) {
        searchField.click()
        searchField.typeText(query)
    }

    /// Text of an element: its `label` or its `value` (a Text shows up as
    /// either, a search field's text and `accessibilityValue` as value);
    /// "" when it isn't there. Read in one go (a snapshot): an element that
    /// goes between reading whether it exists and reading its attributes
    /// would fail the test (XCUITest records a failure for an attribute of
    /// an element it can't find).
    func text(of element: XCUIElement) -> String {
        guard let snapshot = try? element.snapshot() else { return "" }
        let value = (snapshot.value as? String) ?? ""
        return value.isEmpty ? snapshot.label : value
    }

    /// A toolbar button (toolbar items show up more than once in the tree).
    func toolbarButton(_ identifier: String) -> XCUIElement { app.buttons[identifier].firstMatch }

    func isSelected(_ name: String) -> Bool { text(of: tile(name)).hasPrefix("selected") }

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

    /// Opens an item as a user does, with a double click: a tile, a list row
    /// or an Atlas place, once it can be clicked (nothing lies over it, such
    /// as a full view still closing), then waits until `opened` holds (the
    /// folder or archive shown, the picture or video open). The app tells a
    /// double click by the click count the event carries (`Clicks`), so one
    /// double click is enough.
    func open(_ item: XCUIElement, until what: String, timeout: TimeInterval = 15,
              file: StaticString = #filePath, line: UInt = #line, _ opened: () -> Bool) {
        eventually("\(item) can be clicked", timeout: 10, file: file, line: line) { item.exists && item.isHittable }
        item.doubleClick()
        eventually(what, timeout: timeout, file: file, line: line, opened)
    }

    /// Opens a tile (see `open(_:until:)`) and waits for `shown`: a tile of
    /// the folder opened, the picture's name in the badge …
    func openTile(_ name: String, showing shown: XCUIElement, timeout: TimeInterval = 15,
                  file: StaticString = #filePath, line: UInt = #line) {
        open(tile(name), until: "“\(name)” opened", timeout: timeout, file: file, line: line) { shown.exists }
    }

    /// Opens a picture's or video's tile and waits for the full view to show it.
    func openInFullView(_ name: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        open(tile(name), until: "“\(name)” in the full view", timeout: timeout, file: file, line: line) {
            self.badge.exists && self.text(of: self.badge).contains(name)
        }
    }

    /// Where the video on screen stands and the app's clock when it was
    /// read ("played 8.432 s at 1234.567 s" under the badge: the time left's
    /// label under `--ui-testing`), so a rate is measured on the app's
    /// clock, free of how long XCUITest takes to ask.
    func playerClock() -> (played: Double, at: Double)? {
        let element = element("videoTimeLeft").firstMatch
        guard element.exists else { print("no videoTimeLeft"); return nil }
        for text in [element.label, (element.value as? String) ?? "", element.title] {
            let numbers = text.split(separator: " ").compactMap { Double($0) }
            if text.hasPrefix("played "), numbers.count == 2, numbers[0] >= 0 { return (numbers[0], numbers[1]) }
        }
        print("videoTimeLeft: label “\(element.label)”, value “\(String(describing: element.value))”, title “\(element.title)”")
        return nil
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
            isSelected(name)
        }
    }

    func clickMenu(_ menu: String, _ item: String) {
        app.menuBars.menuBarItems[menu].firstMatch.click()
        app.menuBars.menuItems[item].firstMatch.click()
    }
}
