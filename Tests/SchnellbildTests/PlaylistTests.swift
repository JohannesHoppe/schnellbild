import XCTest
import Combine
@testable import Schnellbild

/// The slideshow's playlist (P): reordering, taking out, jumping, the walk
/// adding more, the keys and what is remembered.
@MainActor
final class PlaylistTests: XCTestCase {
    private func names(_ m: BrowserModel) -> [String] { m.slideshow?.items.map(\.name) ?? [] }

    private func startShow(_ m: BrowserModel, _ tree: TempTree, files: [String]) async throws {
        for n in files { try tree.file(n) }
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false && m.shownMediaEntry != nil }
    }

    func testPOpensItAndEscClosesThePlaylistBeforeTheShow() async throws {
        let tree = try TempTree(self)
        let m = makeModel()
        XCTAssertFalse(m.handleKey(.char("p"), command: false), "no playlist without a slideshow")
        try await startShow(m, tree, files: ["a.jpg", "b.jpg"])
        XCTAssertTrue(m.handleKey(.char("p"), command: false))
        XCTAssertTrue(m.showPlaylist)
        XCTAssertTrue(m.handleKey(.char("P"), command: false), "also with Shift or Caps Lock")
        XCTAssertFalse(m.showPlaylist, "P again closes it")
        m.handleKey(.char("p"), command: false)
        XCTAssertTrue(m.handleKey(.escape, command: false))
        XCTAssertFalse(m.showPlaylist, "Esc closes the playlist first")
        XCTAssertNotNil(m.slideshow, "and the show goes on")
        m.handleKey(.char("p"), command: false)
        m.handleKey(.backspace, command: false)
        XCTAssertFalse(m.showPlaylist, "⌫ outside the list closes it too")
        XCTAssertNotNil(m.slideshow)
        XCTAssertTrue(m.handleKey(.escape, command: false))
        XCTAssertNil(m.slideshow, "then Esc ends the show")
        m.startSlideshow()
        await waitUntil { m.shownMediaEntry != nil }
        XCTAssertFalse(m.showPlaylist, "a new show starts without it")
    }

    func testReorderingKeepsTheItemShownAndTheShowFollowsTheNewOrder() async throws {
        let tree = try TempTree(self)
        let m = makeModel()
        try await startShow(m, tree, files: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg")
        m.moveSlideshowItems(from: [3], to: 0)   // d to the top
        XCTAssertEqual(names(m), ["d.jpg", "a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg", "the item on screen stays")
        XCTAssertEqual(m.slideshow?.index, 1)
        m.moveSlideshowItems(from: [1], to: 4)   // the one shown to the end
        XCTAssertEqual(names(m), ["d.jpg", "b.jpg", "c.jpg", "a.jpg"])
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg")
        m.slideshowStep(+1)
        XCTAssertEqual(m.shownMediaEntry?.name, "d.jpg", "on in the new order, round to the start")
        m.slideshowStep(+1)
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg")
        m.moveSlideshowItems(from: [0, 2], to: 4)   // several at once, keeping their order
        XCTAssertEqual(names(m), ["b.jpg", "a.jpg", "d.jpg", "c.jpg"])
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg")
    }

    func testTakingOutKeepsTheFileAndTheShownItemMovesOn() async throws {
        let tree = try TempTree(self)
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        try await startShow(m, tree, files: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        m.playSlideshowItem(at: 2)
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg")
        m.removeFromSlideshow(at: [0])
        XCTAssertEqual(names(m), ["b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg", "an item before the one shown: it stays")
        XCTAssertEqual(m.slideshow?.index, 1)
        m.removeFromSlideshow(at: [1])
        XCTAssertEqual(m.shownMediaEntry?.name, "d.jpg", "the one shown taken out: the next plays")
        m.removeFromSlideshow(at: [1])
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg", "the last one taken out: round to the first")
        XCTAssertTrue(spy.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("c.jpg").path),
                      "the file stays where it is")
        m.removeFromSlideshow(at: [0])
        XCTAssertNil(m.slideshow, "nothing left and nothing more to come: the show ends")
    }

    /// Items the walk still brings come in; what was moved or taken out stays so.
    func testTheWalkAddsMoreWithoutUndoingTheChanges() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "sub1/c.jpg", "sub2/d.jpg", "sub3/e.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        m.slideshowPartPause = .milliseconds(400)
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.slideshow?.items.count == 2 }
        XCTAssertEqual(m.slideshow?.loading, true, "the walk still runs")
        m.moveSlideshowItems(from: [1], to: 0)
        XCTAssertEqual(names(m), ["b.jpg", "a.jpg"])
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg")
        await waitUntil { m.slideshow?.items.count == 3 }
        XCTAssertEqual(names(m), ["b.jpg", "a.jpg", "c.jpg"])
        m.removeFromSlideshow(at: [0])
        m.moveSlideshowItems(from: [1], to: 0)   // c to the top, before the rest of the walk
        XCTAssertEqual(names(m), ["c.jpg", "a.jpg"])
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(names(m), ["c.jpg", "a.jpg", "d.jpg", "e.jpg"], "the rest comes after, b stays out")
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg", "the item shown kept its place")
    }

    /// A slideshow over thousands of search results: they reach the show in
    /// a few steps (each a pass over its items), in the results' order,
    /// starting at the one chosen.
    func testThousandsOfResultsReachTheShowInAFewSteps() async throws {
        let tree = try TempTree(self)
        let count = 3000
        for n in 0..<count { try tree.file(String(format: "IMG_%04d.jpg", n)) }
        try tree.file("trip/IMG_beach.jpg")
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        await searchAndWait(m, "IMG")
        XCTAssertEqual(m.entries.count, count + 1)
        let results = m.entries.map(\.name)
        let start = m.entries[count / 2].url
        var steps = 0
        let watch = m.$slideshow.sink { _ in steps += 1 }
        defer { watch.cancel() }
        m.startSlideshow(startingAt: start)
        await waitUntil({ m.slideshow?.loading == false }, timeout: 20)
        XCTAssertEqual(names(m), results)
        XCTAssertEqual(m.shownMediaEntry?.url, start)
        XCTAssertLessThan(steps, 30, "not one step per result")
    }

    /// A search over a folder and a file in it: the file taken out isn't
    /// brought back by the folder's walk.
    func testAnItemTakenOutIsNotBroughtBack() async throws {
        let tree = try TempTree(self)
        for n in ["beach2.jpg", "beach/beach1.jpg", "beach/x.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        m.slideshowPartPause = .milliseconds(300)
        await openAndWait(m, tree.root)
        m.searchText = "beach"
        await waitUntil { !m.isSearching && m.entries.count >= 3 }
        m.startSlideshow()
        await waitUntil { m.slideshow?.items.contains { $0.name == "beach1.jpg" } == true }
        if let index = m.slideshow?.items.firstIndex(where: { $0.name == "beach1.jpg" }) {
            m.removeFromSlideshow(at: [index])
        }
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertFalse(names(m).contains("beach1.jpg"), "\(names(m))")
    }

    /// ↑ ↓ ⌫ ↩ go to the playlist only after a click in it; ← → page as ever.
    func testTheListTakesItsKeysAfterAClick() async throws {
        let tree = try TempTree(self)
        let m = makeModel()
        try await startShow(m, tree, files: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        m.togglePlaylist()
        XCTAssertFalse(m.handleKey(.down, command: false), "↓ on a picture: nothing, not the list")
        XCTAssertNil(m.playlistCursor)
        m.clickPlaylistItem(at: 1)
        XCTAssertTrue(m.playlistFocused)
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg", "a click shows the item")
        XCTAssertTrue(m.handleKey(.down, command: false))
        XCTAssertEqual(m.playlistCursorIndex, 2)
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg", "↓ only chooses")
        XCTAssertTrue(m.handleKey(.enter, command: false))
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg", "↩ shows the chosen one")
        XCTAssertNotNil(m.slideshow, "and doesn't end the show")
        XCTAssertTrue(m.handleKey(.up, command: false))
        XCTAssertTrue(m.handleKey(.backspace, command: false))
        XCTAssertEqual(names(m), ["a.jpg", "c.jpg", "d.jpg"], "⌫ takes the chosen one out")
        XCTAssertEqual(m.playlistCursorIndex, 1, "the cursor goes to the one now in its place")
        XCTAssertTrue(m.showPlaylist)
        m.handleKey(.end, command: false)
        XCTAssertEqual(m.playlistCursorIndex, 2)
        m.handleKey(.home, command: false)
        XCTAssertEqual(m.playlistCursorIndex, 0)
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.shownMediaEntry?.name, "d.jpg", "→ still pages")
        m.playlistFocused = false   // a click on the picture
        XCTAssertFalse(m.handleKey(.up, command: false))
        XCTAssertEqual(names(m).count, 3)
        m.handleKey(.backspace, command: false)
        XCTAssertFalse(m.showPlaylist, "⌫ without the list's focus closes it")
        XCTAssertEqual(names(m).count, 3, "and takes nothing out")
    }

    /// Pinned and the width are kept for every pane and the next launch;
    /// the list itself is never saved.
    func testPinAndWidthAreRemembered() async throws {
        let tree = try TempTree(self)
        let defaults = makeTestDefaults()
        func model() -> BrowserModel {
            let m = BrowserModel(defaults: defaults)
            m.searchDebounce = .zero
            m.slideshowInterval = .seconds(60)
            m.setFullScreen = { _ in false }
            return m
        }
        let first = model()
        try await startShow(first, tree, files: ["a.jpg", "b.jpg"])
        first.togglePlaylist()
        XCTAssertFalse(first.playlistPinned, "over the picture at first")
        XCTAssertEqual(first.playlistWidth, BrowserModel.playlistDefaultWidth)
        first.playlistPinned = true
        first.setPlaylistWidth(420, remember: true)
        first.setPlaylistWidth(10_000)
        XCTAssertEqual(first.playlistWidth, BrowserModel.playlistWidthRange.upperBound, "held in its range")
        first.setPlaylistWidth(nil, remember: false)
        XCTAssertEqual(first.playlistWidth, BrowserModel.playlistDefaultWidth, "double click: the standard width")
        first.setPlaylistWidth(420, remember: true)
        first.removeFromSlideshow(at: [0])
        first.stopSlideshow()

        let second = model()
        await openAndWait(second, tree.root)
        second.startSlideshow()
        await waitUntil { second.slideshow?.loading == false }
        second.togglePlaylist()
        XCTAssertTrue(second.playlistPinned)
        XCTAssertEqual(second.playlistWidth, 420)
        XCTAssertEqual(names(second), ["a.jpg", "b.jpg"], "a new show has every item again")
    }
}
