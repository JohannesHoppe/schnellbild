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

    /// A ⌘- or ⇧-click on a bar or header goes to it, not to a tile lying
    /// under it; only tiles where the grid can be seen take it.
    func testModifierClicksSkipTilesUnderTheBars() {
        let window = window(FileActionsSpy())
        let pane = ObjectIdentifier(window.left)
        let id = ObjectIdentifier(window)
        var clicked: [String] = []
        // The grid seen between y 40 and 600; a row of tiles scrolled up under
        // the search bar (0…40), one under the status bar (600…630)
        ModifierClicks.show(pane, view: "grid", rect: CGRect(x: 0, y: 40, width: 800, height: 560))
        ModifierClicks.cover(pane, view: "searchBar", rect: CGRect(x: 0, y: 0, width: 800, height: 40))
        ModifierClicks.cover(pane, view: "listHeader", rect: CGRect(x: 0, y: 40, width: 800, height: 20))
        func key(_ name: String) -> ModifierClicks.Key { ModifierClicks.Key(pane: pane, path: name) }
        defer {
            for name in ["test.top", "test.middle", "test.bottom"] { ModifierClicks.remove(key(name)) }
            ModifierClicks.show(pane, view: "grid", rect: nil)
            for view in ["searchBar", "listHeader"] { ModifierClicks.cover(pane, view: view, rect: nil) }
        }
        for (name, y) in [("test.top", 0.0), ("test.middle", 200.0), ("test.bottom", 590.0)] {
            ModifierClicks.place(key(name), frame: CGRect(x: 0, y: y, width: 100, height: 60), in: window,
                                 action: { _ in clicked.append(name) })
        }
        let onSearchBar = ModifierClicks.tile(at: CGPoint(x: 50, y: 20), in: id)
        XCTAssertNil(onSearchBar.action)
        XCTAssertFalse(onSearchBar.overTiles, "the bar's: not the tile hovered last either")
        XCTAssertNil(ModifierClicks.tile(at: CGPoint(x: 50, y: 50), in: id).action, "the header lies over it")
        XCTAssertNil(ModifierClicks.tile(at: CGPoint(x: 50, y: 610), in: id).action, "below what can be seen")
        ModifierClicks.tile(at: CGPoint(x: 50, y: 230), in: id).action?([.command])
        ModifierClicks.tile(at: CGPoint(x: 50, y: 595), in: id).action?([.command])
        XCTAssertEqual(clicked, ["test.middle", "test.bottom"])
        XCTAssertTrue(ModifierClicks.tile(at: CGPoint(x: 500, y: 300), in: id).overTiles, "free space in the grid")
    }

    /// The help's menu item waits while the other pane has a sheet up (a
    /// window shows one at a time): the help would never show and keep the
    /// active pane's keys.
    func testTheHelpWaitsForTheOtherPanesSheet() throws {
        let w = window(FileActionsSpy())
        w.setDual(true)
        let other = try XCTUnwrap(w.right)
        XCTAssertTrue(w.active === w.left)
        other.newFolderRequested = true
        w.openHelp()
        XCTAssertFalse(w.left.showHelp)
        other.newFolderRequested = false
        w.openHelp()
        XCTAssertTrue(w.left.showHelp)
    }

    /// F5 / F6 on what can't go (items inside an archive) is told, as an
    /// empty selection is (a beep), not swallowed: the move says nothing goes.
    func testAMoveOfNothingThatCanGoSaysSo() throws {
        let tree = try TempTree(self)
        let target = try tree.folder("Sorted")
        let photo = try tree.file("a.jpg")
        let m = makeModel(FileActionsSpy())
        XCTAssertFalse(m.move([tree.root.appendingPathComponent("Holiday.zip/Day 1/b.jpg")], into: target, how: .copy),
                       "inside an archive: only read")
        XCTAssertFalse(m.move([target], into: target, how: .copy), "not into itself")
        XCTAssertTrue(m.move([photo], into: target, how: .copy))
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
        XCTAssertTrue(m.handleKey(.char("m"), command: false))
        XCTAssertEqual(m.actionEntries.map(\.name), ["a.jpg", "b.jpg"], "M marks and moves on, as Insert (Mac keyboards have none)")
        XCTAssertEqual(m.selectedEntry?.name, "c.jpg")
        XCTAssertFalse(m.handleKey(.char("m"), command: true), "⌘M is the window's (Minimize)")
        XCTAssertTrue(m.handleKey(.escape, command: false))
        m.selectEntry(named: "b.jpg")
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

    /// The first window's model outlives its window (the next window takes
    /// it): closed, it follows no changes; taken again, it reads its folder afresh.
    func testAClosedWindowFollowsNothingUntilAWindowTakesItAgain() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let spy = FileActionsSpy()
        let first = window(spy)
        XCTAssertTrue(WindowModel.claim(first, defaults: makeTestDefaults()) === first)
        await openAndWait(first.left, tree.root)
        first.windowClosed()

        let other = window(spy)
        await openAndWait(other.left, tree.root)
        other.left.selectEntry(named: "a.jpg")
        other.left.moveSelectionToTrash()
        await waitUntil { !other.left.names.contains("a.jpg") }
        XCTAssertTrue(first.left.names.contains("a.jpg"), "closed: left alone")

        XCTAssertTrue(WindowModel.claim(first, defaults: makeTestDefaults()) === first, "free for the next window")
        await waitUntil { first.left.isAt(tree.root) && !first.left.names.contains("a.jpg") }
        XCTAssertEqual(first.left.names, ["..", "b.jpg"])
    }

    /// A slideshow whose items the other pane trashed, all of them, ends.
    func testASlideshowLeftWithNothingEnds() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let spy = FileActionsSpy()
        let w = window(spy)
        w.left.slideshowInterval = .seconds(60)
        w.left.setFullScreen = { _ in false }
        await openAndWait(w.left, tree.root)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await waitUntil { !right.isLoading }
        await openAndWait(right, tree.root)
        w.left.startSlideshow()
        await waitUntil { w.left.slideshow?.loading == false && w.left.shownMediaEntry?.name == "a.jpg" }

        right.selectEntry(named: "a.jpg")
        right.moveSelectionToTrash()
        await waitUntil { w.left.shownMediaEntry?.name == "b.jpg" }
        right.selectEntry(named: "b.jpg")
        right.moveSelectionToTrash()
        await waitUntil { w.left.slideshow == nil }
    }

    /// F5 / F6 into a pane showing search results are refused, as a drop there is.
    func testF5IntoSearchResultsIsRefused() async throws {
        let tree = try TempTree(self)
        try tree.file("left/a.jpg")
        try tree.file("right/sub/beach.jpg")
        let leftFolder = tree.root.appendingPathComponent("left"), rightFolder = tree.root.appendingPathComponent("right")
        let spy = FileActionsSpy()
        let w = window(spy)
        await openAndWait(w.left, leftFolder)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await waitUntil { !right.isLoading }
        await openAndWait(right, rightFolder)
        await searchAndWait(right, "beach")
        XCTAssertNil(right.paneDropFolder, "drops are refused there")

        w.left.selectEntry(named: "a.jpg")
        XCTAssertTrue(w.handleWindowKey(.f5, command: false, control: false, textEditing: false))
        await waitUntil { w.left.transfersRunning == 0 }
        XCTAssertEqual(spy.reported as? [SendRefusal], [.otherPaneSearching], "said why")
        XCTAssertTrue(spy.copied.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rightFolder.appendingPathComponent("a.jpg").path))
    }

    /// ⇧⌘C copies and ⇧⌘M moves, as F5 / F6 (which need fn on a Mac
    /// keyboard); only in the dual pane, not while typing, and plain ⌘C / ⌘M
    /// stay the system's (Copy, Minimize).
    func testShiftCommandCAndMCopyAndMoveToTheOtherPane() async throws {
        let tree = try TempTree(self)
        for n in ["left/a.jpg", "left/b.jpg"] { try tree.file(n) }
        let leftFolder = tree.root.appendingPathComponent("left"), rightFolder = try tree.folder("right")
        let w = window(FileActionsSpy())
        await openAndWait(w.left, leftFolder)
        XCTAssertFalse(w.handleWindowKey(.char("C"), command: true, control: false, shift: true, textEditing: false),
                       "a single pane: nothing to copy to")
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await waitUntil { !right.isLoading }
        await openAndWait(right, rightFolder)
        w.left.selectEntry(named: "a.jpg")
        XCTAssertFalse(w.handleWindowKey(.char("c"), command: true, control: false, shift: false, textEditing: false), "⌘C")
        XCTAssertFalse(w.handleWindowKey(.char("m"), command: true, control: false, shift: false, textEditing: false), "⌘M")
        XCTAssertFalse(w.handleWindowKey(.char("C"), command: true, control: false, shift: true, textEditing: true), "not while typing")
        XCTAssertTrue(w.handleWindowKey(.char("C"), command: true, control: false, shift: true, textEditing: false))
        await waitUntil { right.isAt(rightFolder) && right.names.contains("a.jpg") }
        XCTAssertEqual(w.left.names, ["..", "a.jpg", "b.jpg"], "copied: still here")
        w.left.selectEntry(named: "b.jpg")
        XCTAssertTrue(w.handleWindowKey(.char("M"), command: true, control: false, shift: true, textEditing: false))
        await waitUntil { w.left.transfersRunning == 0 }
        XCTAssertEqual(w.left.names, ["..", "a.jpg"], "moved: gone here")
        await waitUntil { right.names.contains("b.jpg") }
        XCTAssertEqual(w.active.lastKeyPress.map { $0.matches(.char("m"), command: true, shift: true) }, true,
                       "the mini keyboard lights up ⇧⌘M")
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
        _ = try await w.left.createFolder(named: "Sorted")
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

    /// Several marked: one prompt, counted, with every name (not a title
    /// that strings the first names together).
    func testTheTrashPromptForSeveralNamesThemAll() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg"] { try tree.file(n) }
        let spy = FileActionsSpy()
        let m = BrowserModel(defaults: makeTestDefaults(), fileActions: spy.actions)
        await openAndWait(m, tree.root)
        XCTAssertTrue(m.handleKey(.char("a"), command: true))
        m.moveSelectionToTrash()
        XCTAssertEqual(spy.confirmNames, [["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg"]])
        XCTAssertEqual(spy.trashed.count, 6)
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
        _ = try await w.left.rename(trip, to: "Iceland")
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

    /// A tile dropped into the other pane a second time (SwiftUI dragged it
    /// again after the first drop, seen on CI on macOS 26): the file is
    /// gone from where it was dragged, so nothing is asked and nothing fails.
    func testATileDroppedTwiceMovesOnceAndAsksNothing() async throws {
        let tree = try TempTree(self)
        let c = try tree.file("c.jpg")
        let sorted = try tree.folder("Sorted")
        let spy = FileActionsSpy()
        let w = window(spy)
        await openAndWait(w.left, tree.root)
        w.left.move([c], into: sorted)
        await waitUntil { w.left.transfersRunning == 0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sorted.appendingPathComponent("c.jpg").path))
        let moves = spy.moved.count
        w.left.move([c], into: sorted)
        await waitUntil { w.left.transfersRunning == 0 }
        XCTAssertEqual(spy.keepBothAsked, 0, "no question about the file just moved")
        XCTAssertEqual(spy.moved.count, moves, "nothing moved again")
        XCTAssertTrue(spy.reported.isEmpty, "nothing failed: \(spy.reported)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sorted.appendingPathComponent("c.jpg").path))
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

    /// A pinch on a video goes to the pane under the fingers, as wide as the divider makes it.
    func testThePaneUnderAPointFollowsTheDivider() {
        let w = window(FileActionsSpy())
        XCTAssertTrue(w.pane(atX: 900, width: 1000) === w.left, "a single pane takes everything")
        w.setDual(true)
        w.setSplit(0.7)
        XCTAssertTrue(w.pane(atX: 600, width: 1000) === w.left, "left of the divider, right of the middle")
        XCTAssertTrue(w.pane(atX: 720, width: 1000) === w.right)
        w.setSplit(0.3)
        XCTAssertTrue(w.pane(atX: 400, width: 1000) === w.right)
        XCTAssertTrue(w.pane(atX: 250, width: 1000) === w.left)
    }

    // MARK: Videos in both panes

    /// Both panes in the full view, each on a video with English and German
    /// sound and subtitles, the right one active.
    private func videosInBothPanes() async throws -> (WindowModel, left: PlayerSpy, right: PlayerSpy) {
        let tree = try TempTree(self)
        for n in ["a.mp4", "b.mp4"] { try tree.file(n) }
        let w = window(FileActionsSpy())
        await openAndWait(w.left, tree.root)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await openAndWait(right, tree.root)
        let players = (left: PlayerSpy.withTracks(), right: PlayerSpy.withTracks())
        for (pane, name, player) in [(w.left, "a.mp4", players.left), (right, "b.mp4", players.right)] {
            pane.selectEntry(named: name)
            pane.activateSelection()
            pane.activePlayer = player
            pane.tracksChanged(from: player)
        }
        w.activate(right)
        return (w, players.left, players.right)
    }

    /// What the key monitor does with a key: the window's first, then the active pane's.
    @discardableResult
    private func type(_ key: BrowserModel.KeyInput, shift: Bool = false, in w: WindowModel) -> Bool {
        w.handleWindowKey(key, command: false, control: false, shift: shift, textEditing: false)
            || w.active.handleKey(key, command: false, shift: shift)
    }

    /// Keys go to the active pane's video only: Space pauses it, → skims
    /// it; Tab hands them to the other one.
    func testVideoKeysGoToTheActivePane() async throws {
        let (w, left, right) = try await videosInBothPanes()
        XCTAssertTrue(type(.space, in: w))
        XCTAssertFalse(right.isPlaying, "the right (active) video paused")
        XCTAssertTrue(left.isPlaying, "the left one plays on")
        XCTAssertEqual(w.right?.videoPaused, true)
        XCTAssertFalse(w.left.videoPaused)
        type(.right, in: w)
        XCTAssertEqual(right.calls.last, "seek 10 %")
        XCTAssertFalse(left.calls.contains { $0.hasPrefix("seek") })
        XCTAssertTrue(type(.tab, in: w))
        XCTAssertTrue(w.active === w.left)
        type(.space, in: w)
        XCTAssertFalse(left.isPlaying, "now the left one")
        XCTAssertFalse(right.isPlaying, "the right one stays paused")
        type(.space, in: w)
        XCTAssertTrue(left.isPlaying)
        XCTAssertFalse(right.isPlaying)
    }

    /// The control bar works the pane it lies over (its environment's
    /// model): the right pane's play button and position slider act on the
    /// right video, also while the left pane is active.
    func testTheControlBarActsOnItsOwnPane() async throws {
        let (w, left, right) = try await videosInBothPanes()
        w.activate(w.left)
        let rightPane = try XCTUnwrap(w.right)
        rightPane.togglePlayPause()
        XCTAssertFalse(right.isPlaying)
        XCTAssertTrue(left.isPlaying)
        XCTAssertTrue(rightPane.videoPaused)
        XCTAssertFalse(w.left.videoPaused)
        rightPane.activePlayer?.seek(toProgress: 0.8)
        XCTAssertEqual(right.calls.last, "seek 80 %")
        XCTAssertFalse(left.calls.contains { $0.hasPrefix("seek") })
        XCTAssertTrue(w.active === w.left, "the left pane stays the active one")
    }

    /// The volume, the speed and the subtitles switch are the window's: set
    /// in one pane (keys or its control bar), the other pane's video on
    /// screen follows at once.
    func testVolumeSpeedAndSubtitlesFollowInTheOtherPane() async throws {
        let (w, left, right) = try await videosInBothPanes()
        let rightPane = try XCTUnwrap(w.right)
        // Volume: ↓ in the active (right) pane, then the left pane's slider
        type(.down, in: w)
        XCTAssertEqual(right.volume ?? -1, 0.9, accuracy: 0.001)
        XCTAssertEqual(left.volume ?? -1, 0.9, accuracy: 0.001, "the other pane's video too")
        w.left.setVolume(0.5)
        XCTAssertEqual(right.volume ?? -1, 0.5, accuracy: 0.001)
        // Speed: > in the right pane, the left pane's speed menu
        type(.char(">"), shift: true, in: w)
        XCTAssertEqual(right.speed, 1.25)
        XCTAssertEqual(left.speed, 1.25, "the other pane's video too")
        w.left.setSpeed(2)
        XCTAssertEqual(right.speed, 2)
        XCTAssertEqual(rightPane.playbackSpeed, 2)
        // Subtitles off (V in the right pane): the left video's go too
        type(.char("v"), in: w)
        XCTAssertNil(right.tracks.subtitleID)
        XCTAssertNil(left.tracks.subtitleID, "the other pane's video too")
        XCTAssertNil(w.left.videoTracks.subtitleID)
        XCTAssertFalse(w.left.showSubtitles)
        // V in the left pane then: on again in both (the panes aren't out of step)
        type(.tab, in: w)
        type(.char("v"), in: w)
        XCTAssertEqual(left.tracks.subtitleID, 3)
        XCTAssertEqual(right.tracks.subtitleID, 3, "the other pane's video on again")
        XCTAssertEqual(left.calls.filter { $0.hasPrefix("subtitles") }, ["subtitles off", "subtitles 3"],
                       "one change each, no echo between the panes")
        XCTAssertEqual(right.calls.filter { $0.hasPrefix("subtitles") }, ["subtitles off", "subtitles 3"])
        // Off, then German chosen in the left pane's menu: the right one
        // comes on in German too
        type(.char("v"), in: w)
        w.left.selectSubtitle(4)
        XCTAssertEqual(left.tracks.subtitleID, 4)
        XCTAssertEqual(right.tracks.subtitleID, 4, "on in the language just chosen")
        // A track chosen while on stays that pane's (the switch didn't change)
        w.left.selectSubtitle(3)
        XCTAssertEqual(right.tracks.subtitleID, 4)
    }

    /// A pane back on its grid takes the window's speed and subtitles
    /// switch for its next video.
    func testAPaneWithoutAVideoKeepsTheSettingsForItsNext() async throws {
        let (w, _, right) = try await videosInBothPanes()
        w.left.handleKey(.escape, command: false)   // the left pane back to its grid
        XCTAssertNil(w.left.shownMediaEntry)
        type(.char("v"), in: w)
        type(.char(">"), shift: true, in: w)
        XCTAssertNil(right.tracks.subtitleID)
        XCTAssertFalse(w.left.showSubtitles)
        XCTAssertEqual(w.left.playbackSpeed, 1.25)
        w.left.selectEntry(named: "a.mp4")
        w.left.activateSelection()
        let next = PlayerSpy.withTracks()
        w.left.activePlayer = next
        w.left.tracksChanged(from: next)
        XCTAssertEqual(next.speed, 1.25, "its next video plays at the window's speed")
        XCTAssertNil(next.tracks.subtitleID, "and without subtitles")
    }
}
