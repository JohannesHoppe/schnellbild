import XCTest
@testable import Schnellbild

/// The dual pane (D, ⌃O): two panes, marking several items, F5 / F6 into
/// the other pane, the other pane kept current, name conflicts.
@MainActor
final class DualPaneTests: XCTestCase {
    private func window(_ spy: FileActionsSpy) -> WindowModel {
        let defaults = makeTestDefaults()
        let left = BrowserModel(defaults: defaults, fileActions: spy.actions)
        left.searchDebounce = .zero
        return WindowModel(left: left, defaults: defaults) {
            let right = BrowserModel(defaults: defaults, fileActions: spy.actions, settingsPrefix: "rightPane.")
            right.searchDebounce = .zero
            return right
        }
    }

    func testMarkingSeveralItems() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        m.click(m.entries.first { $0.name == "c.jpg" }!, command: true, shift: false)
        XCTAssertEqual(m.actionEntries.map(\.name), ["a.jpg", "c.jpg"], "⌘-click adds; the one selected joins")
        m.click(m.entries.first { $0.name == "a.jpg" }!, command: true, shift: false)
        XCTAssertEqual(m.actionEntries.map(\.name), ["c.jpg"], "⌘-click again removes")
        m.click(m.entries.first { $0.name == "d.jpg" }!, command: false, shift: true)
        XCTAssertEqual(m.actionEntries.map(\.name), ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
                       "⇧-click: the range from the item clicked last, as in the Finder")
        XCTAssertTrue(m.handleKey(.char("a"), command: true))
        XCTAssertEqual(m.actionEntries.count, 4, "⌘A: all, not ..")
        XCTAssertTrue(m.handleKey(.escape, command: false))
        XCTAssertTrue(m.marked.isEmpty, "Esc unmarks first")
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.handleKey(.insert, command: false))
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg", "Insert marks and moves on")
        m.handleKey(.right, command: false, shift: true)
        XCTAssertEqual(m.actionEntries.map(\.name), ["b.jpg", "c.jpg"], "⇧→ marks the range")
        m.click(m.entries.first { $0.name == "d.jpg" }!, command: false, shift: false)
        XCTAssertTrue(m.marked.isEmpty, "a plain click unmarks")
    }

    func testDTabAndTheOtherPane() async throws {
        let tree = try TempTree(self)
        try tree.file("left/a.jpg")
        try tree.folder("right")
        let w = window(FileActionsSpy())
        await openAndWait(w.left, tree.root.appendingPathComponent("left"))
        XCTAssertTrue(w.handleWindowKey(.char("d"), command: false, control: false, textEditing: false))
        XCTAssertTrue(w.dual)
        let right = try XCTUnwrap(w.right)
        await waitUntil { right.isAt(tree.root.appendingPathComponent("left")) }
        XCTAssertTrue(w.left === w.active)
        XCTAssertTrue(w.handleWindowKey(.tab, command: false, control: false, textEditing: false))
        XCTAssertTrue(w.active === right)
        XCTAssertFalse(w.handleWindowKey(.tab, command: false, control: false, textEditing: true), "not while typing")
        XCTAssertTrue(w.handleWindowKey(.char("o"), command: false, control: true, textEditing: false), "⌃O as in Norton")
        XCTAssertFalse(w.dual)
        XCTAssertTrue(w.active === w.left)
    }

    /// F5 copies, F6 moves the marked items into the other pane's folder;
    /// both panes show the result.
    func testF5CopiesAndF6MovesToTheOtherPane() async throws {
        let tree = try TempTree(self)
        for n in ["left/a.jpg", "left/b.jpg", "left/c.jpg"] { try tree.file(n) }
        let leftFolder = tree.root.appendingPathComponent("left"), rightFolder = try tree.folder("right")
        let spy = FileActionsSpy()
        let w = window(spy)
        await openAndWait(w.left, leftFolder)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await waitUntil { !right.isLoading }
        await openAndWait(right, rightFolder)

        w.left.selectEntry(named: "a.jpg")
        XCTAssertTrue(w.handleWindowKey(.f5, command: false, control: false, textEditing: false))
        await waitUntil { right.isAt(rightFolder) && right.names.contains("a.jpg") }
        XCTAssertEqual(w.left.names, ["..", "a.jpg", "b.jpg", "c.jpg"], "copied: still here")

        w.left.selectEntry(named: "b.jpg")
        w.left.click(w.left.entries.first { $0.name == "c.jpg" }!, command: true, shift: false)
        XCTAssertTrue(w.handleWindowKey(.f6, command: false, control: false, textEditing: false))
        await waitUntil { w.left.transfersRunning == 0 }
        XCTAssertEqual(w.left.names, ["..", "a.jpg"], "moved: gone here")
        await waitUntil { right.isAt(rightFolder) && right.names.contains("c.jpg") }
        XCTAssertEqual(right.names, ["..", "a.jpg", "b.jpg", "c.jpg"])

        // A name taken there: keep both (numbered) or skip
        w.left.selectEntry(named: "a.jpg")
        spy.keepBoth = false
        _ = w.sendToOtherPane(how: .copy)
        await waitUntil { w.left.transfersRunning == 0 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rightFolder.appendingPathComponent("a 2.jpg").path), "skipped")
        spy.keepBoth = true
        _ = w.sendToOtherPane(how: .copy)
        await waitUntil { w.left.transfersRunning == 0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightFolder.appendingPathComponent("a 2.jpg").path), "kept both")
        XCTAssertFalse(w.handleWindowKey(.f6, command: false, control: false, shift: true, textEditing: false),
                       "⇧F6 is the pane's rename")
    }

    /// A change in one pane shows in the other one when it shows that folder.
    func testTheOtherPaneFollowsChanges() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let spy = FileActionsSpy()
        let w = window(spy)
        await openAndWait(w.left, tree.root)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await waitUntil { right.isAt(tree.root) }
        _ = try w.left.createFolder(named: "Sorted")
        await waitUntil { right.names.contains("Sorted") }
        XCTAssertEqual(right.names, ["..", "Sorted", "a.jpg"])
    }

    /// The mini keyboard and the volume are the window's: set in one pane,
    /// the other follows, without the two answering each other for ever.
    func testKeyboardAndVolumeAreKeptInStep() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let w = window(FileActionsSpy())
        await openAndWait(w.left, tree.root)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        w.left.showMiniKeyboard = true
        XCTAssertTrue(right.showMiniKeyboard)
        right.showMiniKeyboard = false
        XCTAssertFalse(w.left.showMiniKeyboard)
        w.left.changeVolume(by: -0.1)
        XCTAssertEqual(right.volume, 0.9, accuracy: 0.001)
    }

    /// The Trash takes what F5 / F6 take: one marked item is the one, not
    /// the cursor's; ⇧-arrows after it still work (the anchor left the list).
    func testTheTrashTakesTheMarkedItem() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let spy = FileActionsSpy()
        let m = BrowserModel(defaults: makeTestDefaults(), fileActions: spy.actions)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.handleKey(.insert, command: false))   // marks a, the cursor goes to b
        XCTAssertTrue(m.handleKey(.f8, command: false))
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["a.jpg"])
        m.selectEntry(named: "c.jpg")
        XCTAssertTrue(m.handleKey(.f8, command: false))
        XCTAssertEqual(m.names, ["..", "b.jpg"])
        m.handleKey(.left, command: false, shift: true)   // must not trap
        XCTAssertNotNil(m.selectedEntry)
    }

    /// Nothing moves the folder shown or one around it ("..").
    func testTheFolderShownNeverMoves() async throws {
        let tree = try TempTree(self)
        try tree.file("trip/a.jpg")
        let target = try tree.folder("elsewhere")
        let trip = tree.root.appendingPathComponent("trip")
        let spy = FileActionsSpy()
        let m = BrowserModel(defaults: makeTestDefaults(), fileActions: spy.actions)
        await openAndWait(m, trip)
        m.move([tree.root, trip], into: target)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertTrue(spy.moved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trip.appendingPathComponent("a.jpg").path))
    }

    /// A folder the other pane shows, renamed here: the other pane follows.
    func testTheOtherPaneFollowsARename() async throws {
        let tree = try TempTree(self)
        try tree.file("Trip/a.jpg")
        let w = window(FileActionsSpy())
        await openAndWait(w.left, tree.root)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await waitUntil { right.isAt(tree.root) }
        await openAndWait(right, tree.root.appendingPathComponent("Trip"))
        let trip = try XCTUnwrap(w.left.entries.first { $0.name == "Trip" })
        _ = try w.left.rename(trip, to: "Iceland")
        XCTAssertEqual(right.folderURL?.lastPathComponent, "Iceland")
        await waitUntil { right.names.contains("a.jpg") }
    }

    /// What the other pane moves out of the folder this one shows leaves it.
    func testWhatMovesAwayLeavesTheOtherPane() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.file("b.jpg")
        let sub = try tree.folder("Sub")
        let w = window(FileActionsSpy())
        await openAndWait(w.left, tree.root)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await waitUntil { right.isAt(tree.root) }
        right.move([tree.root.appendingPathComponent("a.jpg")], into: sub)
        await waitUntil { right.transfersRunning == 0 }
        XCTAssertEqual(w.left.names, ["..", "Sub", "b.jpg"])
    }

    func testEachPaneRemembersItsFolder() async throws {
        let tree = try TempTree(self)
        let one = try tree.folder("one"), two = try tree.folder("two")
        let defaults = makeTestDefaults()
        let left = BrowserModel(defaults: defaults)
        let right = BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        await openAndWait(left, one)
        await openAndWait(right, two)
        XCTAssertEqual(defaults.string(forKey: "lastFolderPath"), one.path)
        XCTAssertEqual(defaults.string(forKey: "rightPane.lastFolderPath"), two.path)
    }

    /// L: the list view, per pane and remembered; ↑↓ step one row.
    func testLSwitchesToTheList() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let defaults = makeTestDefaults()
        let m = BrowserModel(defaults: defaults)
        await openAndWait(m, tree.root)
        m.columnCount = 3
        XCTAssertTrue(m.handleKey(.char("l"), command: false))
        XCTAssertEqual(m.viewMode, .list)
        XCTAssertEqual(m.columnCount, 1, "rows, one item each")
        m.selectEntry(named: "a.jpg")
        m.handleKey(.down, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")
        XCTAssertEqual(BrowserModel(defaults: defaults).viewMode, .list, "remembered")
        XCTAssertEqual(BrowserModel(defaults: defaults, settingsPrefix: "rightPane.").viewMode, .grid, "per pane")
        m.handleKey(.char("L"), command: false)
        XCTAssertEqual(m.viewMode, .grid)
    }
}
