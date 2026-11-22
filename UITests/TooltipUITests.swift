import XCTest
import AppKit

/// Every button of the main window shows a tooltip when the pointer rests
/// on it: the toolbar, the search bar, the status bar, the list's headers,
/// the full view, the Inspector, the Atlas with its map, the video control
/// bar and the mini keyboard. XCUITest reads no control's tooltip text (no
/// such attribute), but the tooltip macOS shows is an element of its own
/// (a help tag): each control is hovered and the help tag must appear. The
/// texts and their keys are the code's (`Shortcuts.tip`, `toolTip`), in
/// every language through `LocalizationTests`. With the CI workflow's
/// shell (SCREEN_MEASURE=1) a control whose tooltip doesn't show is
/// photographed into `measurements-<runner>` (`tooltip-missing-*.png`).
final class TooltipUITests: SchnellbildUITestCase {
    private var osName: String { "macos\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)" }
    /// Controls whose tooltip didn't show.
    private var missing: [String] = []

    /// Rests the pointer on `element` (after moving it off the window, so a
    /// tooltip shown before is gone) and waits for a tooltip; once more if
    /// none came (the first hover after a move across the window was now and
    /// then too quick for the tooltip's timer on CI).
    private func expectTooltip(_ element: XCUIElement, _ name: String) {
        guard element.waitForExistence(timeout: 10) else {
            missing.append("\(name) (not found)")
            return
        }
        let tags = app.descendants(matching: .helpTag)
        // Off the window, until the tooltip shown before is gone; on macOS 15
        // one now and then stayed for more than 15 s, so a tooltip counts only
        // where none stood before the pointer came (its frame is new)
        for y in [0.5, 0.3, 0.7] {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: -0.02, dy: y)).hover()
            let gone = Date().addingTimeInterval(5)
            while tags.firstMatch.exists, Date() < gone { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            if !tags.firstMatch.exists { break }
        }
        let before = Set(tags.allElementsBoundByIndex.map { NSStringFromRect($0.frame) })
        func shown(within seconds: TimeInterval) -> Bool {
            let until = Date().addingTimeInterval(seconds)
            repeat {
                if tags.allElementsBoundByIndex.contains(where: { !before.contains(NSStringFromRect($0.frame)) }) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < until
            return false
        }
        element.hover()
        if shown(within: 6) { return }
        // The pointer moved on a little inside it, as a hand does (a
        // tooltip that didn't show on the way in from a neighbour's)
        for x in [0.35, 0.65] {
            element.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).hover()
            if shown(within: 6) {
                print("tooltip of \(name) after moving inside it")
                return
            }
        }
        missing.append(name)
        photograph(around: element.frame, as: name)
    }

    private func photograph(around frame: CGRect, as name: String) {
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else { return }
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let area = frame.insetBy(dx: -200, dy: -60).intersection(screen)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let shot = "tooltip-missing-\(name)-\(osName)"
        pasteboard.setString("shot:\(shot):\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))", forType: .string)
        eventually("\(name) photographed", timeout: 30) { pasteboard.string(forType: .string) == "shot-done:\(shot)" }
    }

    private func assertAllShown(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(missing.isEmpty, "no tooltip showed on: \(missing.joined(separator: ", "))", file: file, line: line)
    }

    func testTheWindowsControlsShowTooltips() throws {
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try FileManager.default.removeItem(at: tempDir.appendingPathComponent(name)) }
        for name in ["norway-01-bryggen.jpg", "norway-05-flam.jpg", "norway-08-geiranger.jpg"] { try put(name, at: name) }
        try folder("Day 2")
        launch(open: tempDir.path)
        XCTAssertTrue(app.staticTexts["norway-01-bryggen.jpg"].waitForExistence(timeout: 15), "the grid")

        // The toolbar
        for id in ["backButton", "forwardButton", "upButton", "folderTitle", "bookmarksMenu", "dualPaneButton", "enhanceButton",
                   "adjustButton", "slideshowButton", "sortMenu"] {
            expectTooltip(element(id).firstMatch, id)
        }
        expectTooltip(app.toolbars.buttons["Open Folder"].firstMatch, "openFolder")
        // The search bar and the status bar
        for id in ["searchField", "searchMode", "statusText", "statusPath", "viewModePicker", "keyboardButton"] {
            expectTooltip(element(id).firstMatch, id)
        }
        // A click goes through the tooltip to the control below: the list's
        // segment, the keyboard button; the mini keyboard's keys
        element("viewModePicker").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(element("list").waitForExistence(timeout: 5), "the view switch still takes clicks")
        app.typeKey("l", modifierFlags: [])
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(tile("norway-01-bryggen.jpg").waitForExistence(timeout: 10), "the grid again")
        element("keyboardButton").firstMatch.click()
        XCTAssertTrue(element("miniKeyboard").waitForExistence(timeout: 5), "the keyboard button still takes clicks")
        expectTooltip(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'key.'")).firstMatch, "miniKey")
        element("keyboardButton").firstMatch.click()

        // The list's column headers
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(element("list").waitForExistence(timeout: 10), "the list")
        expectTooltip(element("column.name").firstMatch, "column.name")

        // The Atlas: its header, the map's buttons, the timeline
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10), "the Atlas")
        for id in ["tourButton", "atlasSubfolders", "timeline.start", "timeline.end"] {
            expectTooltip(element(id).firstMatch, id)
        }
        for title in ["Zoom in", "Zoom out", "Tilt the view", "Hide day and night", "Hide the clouds"] {
            expectTooltip(app.buttons[title].firstMatch, title)
        }

        // The full view: back to the grid, the Inspector
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(tile("norway-01-bryggen.jpg").waitForExistence(timeout: 10), "the grid again")
        openInFullView("norway-01-bryggen.jpg")
        expectTooltip(app.toolbars.buttons["Grid"].firstMatch, "grid")
        app.typeKey("i", modifierFlags: [])
        expectTooltip(element("inspectorClose").firstMatch, "inspectorClose")
        assertAllShown()
    }

    func testTheVideoControlBarShowsTooltips() throws {
        try put("tracks.mp4", at: "tracks.mp4")
        launch(open: tempDir.appendingPathComponent("tracks.mp4").path, extra: ["--hold-video-bar"])
        let video = element("video.avkit")
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        eventually("the tracks are known", timeout: 20) { self.text(of: video).contains("subtitles 1/2") }
        video.hover()
        XCTAssertTrue(element("videoBar").waitForExistence(timeout: 5), "the control bar")
        for id in ["videoBar.grip", "videoBar.playPause", "videoBar.position", "videoBar.volume", "videoBar.speed",
                   "videoBar.subtitles", "videoBar.audio", "videoBar.fullScreen"] {
            expectTooltip(element(id).firstMatch, id)
        }
        assertAllShown()
    }
}
