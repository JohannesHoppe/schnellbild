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
        XCTAssertEqual(m.actionEntries.map(\.name), ["c.jpg", "d.jpg"], "⇧-click: the range")
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
        XCTAssertEqual(w.left.names, ["..", "a.jpg"], "moved: gone here")
        await waitUntil { right.isAt(rightFolder) && right.names.contains("c.jpg") }
        XCTAssertEqual(right.names, ["..", "a.jpg", "b.jpg", "c.jpg"])

        // A name taken there: keep both (numbered) or skip
        w.left.selectEntry(named: "a.jpg")
        spy.keepBoth = false
        _ = w.sendToOtherPane(how: .copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rightFolder.appendingPathComponent("a 2.jpg").path), "skipped")
        spy.keepBoth = true
        _ = w.sendToOtherPane(how: .copy)
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
}
