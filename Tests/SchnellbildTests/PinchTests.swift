import XCTest
@testable import Schnellbild

/// A trackpad pinch (the window's `.magnify` monitor → `WindowModel.pinch`
/// → the pane under the fingers, `BrowserModel.pinch`): the grid's tile
/// size step by step, a video's zoom, a picture and the list left to
/// themselves; zooming keeps the middle of the view while panned.
/// XCUITest can't pinch on macOS, so this is where pinch is tested.
@MainActor
final class PinchTests: XCTestCase {
    private func grid() async throws -> BrowserModel {
        let tree = try TempTree(self)
        for n in ["a.jpg", "clip.mp4", "z.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        return m
    }

    /// On the grid a pinch grows the tiles one ⌘+ step (30 pt) each time it
    /// adds up to a quarter, never several at once; pinching in shrinks them.
    func testAPinchOnTheGridStepsTheTiles() async throws {
        let m = try await grid()
        XCTAssertEqual(m.thumbnailSide, 150)
        // (Fractions exact in binary: no rounding at the step's edge)
        XCTAssertTrue(m.pinch(0.125, began: true), "the grid takes the pinch")
        XCTAssertTrue(m.pinch(0.0625, began: false))
        XCTAssertEqual(m.thumbnailSide, 150, "not yet a quarter")
        m.pinch(0.125, began: false)
        XCTAssertEqual(m.thumbnailSide, 180, "a quarter: one step")
        XCTAssertEqual(m.tilePinch, 0.0625, "the rest counts toward the next step")
        m.pinch(0.1875, began: false)
        XCTAssertEqual(m.thumbnailSide, 210)
        // Pinching in, in the same gesture: back step by step
        m.pinch(-0.125, began: false)
        XCTAssertEqual(m.thumbnailSide, 210, "not yet a quarter in")
        m.pinch(-0.125, began: false)
        XCTAssertEqual(m.thumbnailSide, 180)
    }

    /// A fast pinch (a large event) still goes a step per quarter, as the
    /// keys would; the tiles stay within 80 … 320 pt, as with ⌘+ / ⌘−.
    func testTheGridPinchKeepsTheKeysLimits() async throws {
        let m = try await grid()
        m.pinch(0.5, began: true)
        XCTAssertEqual(m.thumbnailSide, 210, "two quarters: two steps")
        for _ in 0..<40 { m.pinch(0.1, began: false) }
        XCTAssertEqual(m.thumbnailSide, 320, "no larger than ⌘+ makes them")
        for _ in 0..<80 { m.pinch(-0.1, began: false) }
        XCTAssertEqual(m.thumbnailSide, 80, "no smaller than ⌘− makes them")
        // The same steps as the keys
        m.growThumbnails()
        let afterKey = m.thumbnailSide
        m.shrinkThumbnails()
        m.pinch(0.25, began: true)
        XCTAssertEqual(m.thumbnailSide, afterKey)
    }

    /// A new gesture starts from nothing: what the last one left short of a
    /// step doesn't carry over.
    func testANewPinchStartsAfresh() async throws {
        let m = try await grid()
        m.pinch(0.2, began: true)
        XCTAssertEqual(m.thumbnailSide, 150)
        m.pinch(0.1, began: true)
        XCTAssertEqual(m.thumbnailSide, 150, "0.2 of the last pinch is forgotten")
        m.pinch(-0.2, began: true)
        m.pinch(-0.1, began: true)
        XCTAssertEqual(m.thumbnailSide, 150)
    }

    /// The list keeps its rows; a sheet keeps the pinch away from the pane.
    func testTheListAndSheetsLeaveThePinch() async throws {
        let m = try await grid()
        m.viewMode = .list
        XCTAssertFalse(m.pinch(0.5, began: true), "the list lets the event go on")
        XCTAssertEqual(m.thumbnailSide, 150)
        m.viewMode = .grid
        m.showHelp = true
        XCTAssertFalse(m.pinch(0.5, began: true), "not under a sheet")
        XCTAssertEqual(m.thumbnailSide, 150)
    }

    /// A video zooms with each pinch event (1 … 8), the tiles stay; a
    /// picture zooms through its own gesture, so its events go on.
    func testAPinchZoomsAVideoAndLeavesAPicture() async throws {
        let m = try await grid()
        m.selectEntry(named: "clip.mp4")
        m.activateSelection()
        let player = PlayerSpy()   // (the model holds it weakly)
        m.activePlayer = player
        XCTAssertTrue(m.pinch(0.5, began: true))
        XCTAssertEqual(m.zoom, 1.5, accuracy: 0.0001)
        XCTAssertTrue(m.pinch(1, began: false))
        XCTAssertEqual(m.zoom, 3, accuracy: 0.0001, "each event multiplies")
        for _ in 0..<20 { m.pinch(0.5, began: false) }
        XCTAssertEqual(m.zoom, 8, accuracy: 0.0001, "no more than 800 %")
        for _ in 0..<40 { m.pinch(-0.5, began: false) }
        XCTAssertEqual(m.zoom, 1, accuracy: 0.0001, "no less than fit")
        XCTAssertEqual(m.thumbnailSide, 150, "the tiles stay")

        m.handleKey(.escape, command: false)
        m.selectEntry(named: "a.jpg")
        m.activateSelection()
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg")
        XCTAssertFalse(m.pinch(0.5, began: true), "a picture: its own gesture")
        XCTAssertEqual(m.zoom, 1)
        XCTAssertEqual(m.thumbnailSide, 150)
        // What the picture's gesture hands over at its end
        m.applyPinch(1.6)
        XCTAssertEqual(m.zoom, 1.6, accuracy: 0.0001, "not snapped to a key step")
    }

    /// A slideshow's video zooms too; its pictures go on to their gesture.
    func testAPinchInTheSlideshow() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "clip.mp4"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.slideshow?.current != nil }
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg")
        XCTAssertFalse(m.pinch(0.5, began: true))
        XCTAssertEqual(m.thumbnailSide, 150, "the grid behind the show stays")
        m.handleKey(.right, command: false)
        await waitUntil { m.shownMediaEntry?.name == "clip.mp4" }
        let player = PlayerSpy()   // (the model holds it weakly)
        m.activePlayer = player
        XCTAssertTrue(m.pinch(0.25, began: true))
        XCTAssertEqual(m.zoom, 1.25, accuracy: 0.0001)
    }

    /// In the dual pane the pane under the fingers takes the pinch, as wide
    /// as the divider makes it: a video on the right zooms, the grid on the
    /// left steps its tiles, each leaving the other alone.
    func testThePaneUnderTheFingersTakesThePinch() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "clip.mp4"] { try tree.file(n) }
        let defaults = makeTestDefaults()
        let w = WindowModel(left: BrowserModel(defaults: defaults), defaults: defaults) {
            BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        }
        await openAndWait(w.left, tree.root)
        w.setDual(true)
        let right = try XCTUnwrap(w.right)
        await openAndWait(right, tree.root)
        right.selectEntry(named: "clip.mp4")
        right.activateSelection()
        let player = PlayerSpy()   // (the model holds it weakly)
        right.activePlayer = player
        w.setSplit(0.6)
        // Left pane active; the pinch goes by place, not by focus
        XCTAssertTrue(w.pinch(0.5, began: true, atX: 700, width: 1000))
        XCTAssertEqual(right.zoom, 1.5, accuracy: 0.0001)
        XCTAssertEqual(w.left.thumbnailSide, 150)
        XCTAssertTrue(w.pinch(0.25, began: true, atX: 500, width: 1000), "left of the divider, right of the middle")
        XCTAssertEqual(w.left.thumbnailSide, 180)
        XCTAssertEqual(right.zoom, 1.5, accuracy: 0.0001)
        XCTAssertEqual(right.thumbnailSide, 150)
        // The right pane's list leaves it
        right.handleKey(.escape, command: false)
        right.viewMode = .list
        XCTAssertFalse(w.pinch(0.5, began: true, atX: 900, width: 1000))
    }

    /// Zooming while panned keeps the middle of the view on the same place
    /// of the picture: the pan scales with the zoom; at fit there is none.
    func testZoomKeepsTheMiddleOfTheViewWhilePanned() {
        let offset = CGSize(width: -300, height: 120)
        let zoomedIn = BrowserModel.panOffset(offset, zoomedFrom: 2, to: 3)
        XCTAssertEqual(zoomedIn.width, -450, accuracy: 0.0001)
        XCTAssertEqual(zoomedIn.height, 180, accuracy: 0.0001)
        // The place of the picture in the view's middle (in the picture's
        // fitted points from its own middle): −offset / zoom, before and after
        for (from, to) in [(2.0, 3.0), (8.0, 2.0), (1.25, 7.5), (4.0, 1.02)] {
            let after = BrowserModel.panOffset(offset, zoomedFrom: from, to: to)
            XCTAssertEqual(-offset.width / from, -after.width / to, accuracy: 0.0001, "\(from) → \(to)")
            XCTAssertEqual(-offset.height / from, -after.height / to, accuracy: 0.0001, "\(from) → \(to)")
        }
        // From far in, panned to an edge, out to 200 %: the picture still
        // fills the view's middle
        let edge = CGSize(width: -3.5 * 800, height: 0)   // 800 pt wide view, panned to the right edge at 800 %
        let out = BrowserModel.panOffset(edge, zoomedFrom: 8, to: 2)
        let halfWidth = 800 * 2 / 2.0
        XCTAssertLessThan(abs(out.width), halfWidth, "the picture still covers the middle")
        XCTAssertEqual(BrowserModel.panOffset(offset, zoomedFrom: 2, to: 1), .zero, "at fit: no pan")
        XCTAssertEqual(BrowserModel.panOffset(offset, zoomedFrom: 2, to: 1.005), .zero, "a hair above fit is fit")
    }
}
