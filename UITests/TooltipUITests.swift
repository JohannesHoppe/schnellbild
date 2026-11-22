import XCTest
import AppKit

/// Probe: what XCUITest sees of a tooltip (help tags, attributes) after
/// resting the pointer on a control, with a picture of each.
final class TooltipUITests: SchnellbildUITestCase {
    private var osName: String { "macos\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)" }

    private func photograph(around frame: CGRect, as name: String) {
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else { return }
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let area = frame.insetBy(dx: -260, dy: -80).intersection(screen)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("shot:tooltip-\(name)-\(osName):\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))",
                             forType: .string)
        eventually("\(name) photographed", timeout: 30) {
            pasteboard.string(forType: .string) == "shot-done:tooltip-\(name)-\(osName)"
        }
    }

    private func probe(_ element: XCUIElement, _ name: String) {
        guard element.waitForExistence(timeout: 5) else { print("PROBE \(name): not found"); return }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        element.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        print("PROBE \(name): \(element.debugDescription.prefix(600))")
        let tags = app.descendants(matching: .helpTag).allElementsBoundByIndex
        print("PROBE \(name) helpTags: \(tags.count) \(tags.map { "[\($0.label)|\(String(describing: $0.value))|\($0.title)]" })")
        if let snapshot = try? element.snapshot() {
            print("PROBE \(name) snapshot: \(snapshot.dictionaryRepresentation)")
        }
        let windows = app.windows.allElementsBoundByIndex.map { "\($0.identifier)|\($0.title)|\($0.frame)" }
        print("PROBE \(name) windows: \(windows)")
        photograph(around: element.frame, as: name)
    }

    private func probeStatusBar(_ prefix: String) {
        probe(element("keyboardButton").firstMatch, prefix + "keyboard")
        probe(element("viewModePicker").firstMatch, prefix + "viewMode")
        probe(element("statusText").firstMatch, prefix + "statusText")
    }

    func testProbeTooltips() throws {
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try FileManager.default.removeItem(at: tempDir.appendingPathComponent(name)) }
        for name in ["norway-01-bryggen.jpg", "norway-05-flam.jpg", "norway-08-geiranger.jpg"] { try put(name, at: name) }
        let empty = try folder("empty")
        for (prefix, extra) in [("base-", [String]()), ("overlay-", ["--probe-tip=overlay"]), ("background-", ["--probe-tip=background"]),
                                ("notilehelp-", ["--probe-no-tile-help"])] {
            launch(open: tempDir.path, extra: extra)
            XCTAssertTrue(app.staticTexts["norway-01-bryggen.jpg"].waitForExistence(timeout: 15), "the grid")
            probeStatusBar(prefix)
            if prefix == "background-" {
                // the controls still take clicks
                element("keyboardButton").firstMatch.click()
                print("PROBE background click: mini keyboard \(element("miniKeyboard").waitForExistence(timeout: 3))")
            }
            app.terminate()
        }
        launch(open: empty.path)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        probeStatusBar("empty-")
    }
}
