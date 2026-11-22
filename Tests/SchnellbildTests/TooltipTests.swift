import XCTest
import SwiftUI
import OfflineMap
@testable import Schnellbild

/// Every control of the app's windows has a tooltip: the views are shown in
/// a window of the test process and their accessibility elements walked, as
/// VoiceOver sees them; SwiftUI's `.help` is each control's accessibility
/// help, the text macOS shows as its tooltip. Each control found must have
/// help that isn't empty.
@MainActor
final class TooltipTests: XCTestCase {
    /// A control found: its role, what it is called, its help.
    struct Control: CustomStringConvertible {
        let role: String
        let name: String
        let help: String
        var description: String { "\(role) “\(name)”: \(help.isEmpty ? "NO HELP" : help)" }
    }

    /// The roles of what can be clicked or dragged.
    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .slider, .incrementor, .link, .disclosureTriangle,
    ]

    /// The controls under `element`, depth first.
    static func controls(in element: Any) -> [Control] {
        var found: [Control] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: Any, depth: Int) {
            guard depth < 80, let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted,
                  let node = element as? NSAccessibilityProtocol else { return }
            if let role = node.accessibilityRole(), controlRoles.contains(role), node.isAccessibilityElement() {
                let name = [node.accessibilityIdentifier() ?? "", node.accessibilityLabel() ?? "", node.accessibilityTitle() ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " / ")
                found.append(Control(role: role.rawValue, name: name, help: node.accessibilityHelp() ?? ""))
            }
            for child in node.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(element, depth: 0)
        return found
    }

    /// Shows `view` in a window of `size` and gives its run loop time to lay it out.
    private func show<V: View>(_ view: V, size: CGSize = CGSize(width: 900, height: 600), toolbar: Bool = false) -> NSWindow {
        let host = NSHostingView(rootView: view)
        if toolbar { host.sceneBridgingOptions = [.toolbars] }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        addTeardownBlock { window.close() }
        return window
    }

    private func controls(of window: NSWindow) -> [Control] {
        Self.controls(in: window)
    }

    /// Every control found has help; at least `expected` controls are found
    /// (the walk reaches them), each name in `names` among them.
    private func assertEveryControlHasHelp(_ controls: [Control], _ what: String, atLeast expected: Int, names: [String] = [],
                                           file: StaticString = #filePath, line: UInt = #line) {
        print("tooltips of \(what):\n" + controls.map { "  \($0)" }.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(controls.count, expected, "\(what): the controls found: \(controls)", file: file, line: line)
        for control in controls {
            XCTAssertFalse(control.help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(what): \(control.role) “\(control.name)” has no tooltip", file: file, line: line)
        }
        for name in names {
            XCTAssertTrue(controls.contains { $0.name.contains(name) }, "\(what): \(name) not found in \(controls)", file: file, line: line)
        }
    }

    func testTheVideoControlBarsButtonsHaveTooltips() {
        let model = BrowserModel(defaults: makeTestDefaults())
        let player = PlayerSpy.withTracks()
        player.lengthSeconds = 20
        model.activePlayer = player
        model.tracksChanged(from: player)
        let window = show(VideoControlBar(areaWidth: 700, dragging: .constant(false), onDrag: { _ in }, onDragEnd: {})
            .environmentObject(model).padding(40))
        assertEveryControlHasHelp(controls(of: window), "the video control bar", atLeast: 5,
                                  names: ["videoBar.playPause", "videoBar.position", "videoBar.volume", "videoBar.fullScreen"])
    }

    func testTheAdjustmentsHaveTooltips() {
        let model = BrowserModel(defaults: makeTestDefaults())
        let window = show(AdjustmentsView().environmentObject(model), size: CGSize(width: 340, height: 360))
        assertEveryControlHasHelp(controls(of: window), "the adjustments", atLeast: 6,
                                  names: ["autoSwitch", "slider.exposure", "slider.sharpness", "resetLook"])
    }

    func testTheAtlasHeaderAndTheMapsButtonsHaveTooltips() {
        let texts = AtlasHeaderTexts.localized(onMap: 13, progress: nil, shortcuts: .shared)
        let header = AtlasHeader(texts: texts, progress: nil, tourEnabled: true, showsSubfolders: true, subfolders: .constant(true),
                                 walking: false, onTour: {})
        assertEveryControlHasHelp(controls(of: show(header.padding(20))), "the Atlas header", atLeast: 2,
                                  names: ["tourButton", "atlasSubfolders"])
        let globe = GlobeView(camera: .constant(.world), renderer: nil)
        assertEveryControlHasHelp(controls(of: show(globe)), "the globe", atLeast: 6, names: ["Zoom in", "Tilt the view"])
    }

    func testTheMainWindowsControlsHaveTooltips() throws {
        let defaults = makeTestDefaults()
        let window = WindowModel(left: BrowserModel(defaults: defaults), defaults: defaults) {
            BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        }
        let shown = show(ContentView().environmentObject(window), size: CGSize(width: 1000, height: 640), toolbar: true)
        let found = controls(of: shown)
        print("toolbar items: \(shown.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
        assertEveryControlHasHelp(found, "the main window", atLeast: 8,
                                  names: ["backButton", "viewModePicker", "keyboardButton", "slideshowButton", "sortMenu"])
    }
}
