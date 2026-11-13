import XCTest
@testable import Schnellbild

/// Changes made outside the app (the Finder, a camera import, another Mac on
/// a share): the folder shown is read again in place, Reload (⌘R), a volume
/// going away, FSEvents.
@MainActor
final class OutsideChangesTests: XCTestCase {
    /// What came and went shows; the selection and the marks stay.
    func testReadingAgainKeepsTheSelectionAndTheMarks() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "b.jpg")
        m.click(try XCTUnwrap(m.entries.first { $0.name == "c.jpg" }), command: true, shift: false)
        let marked = m.marked
        let selected = m.selectedEntry?.name   // the ⌘-click moves the cursor along

        try tree.file("d.jpg")
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("a.jpg"))
        try tree.file("notes.txt")
        m.relist()   // the folder's date changed: read again
        await waitUntil { m.names == ["..", "b.jpg", "c.jpg", "d.jpg"] }
        XCTAssertNotNil(selected)
        XCTAssertEqual(m.selectedEntry?.name, selected)
        XCTAssertEqual(m.marked, marked)
        XCTAssertEqual(m.otherFiles.map(\.name), ["notes.txt"])
        XCTAssertFalse(m.isLoading, "in place, not loaded anew")
    }

    /// The selected item went: the one in its place is selected.
    func testTheSelectedItemGoneSelectsTheNextOne() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "b.jpg")
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("b.jpg"))
        m.relist(force: true)
        await waitUntil { m.names == ["..", "a.jpg", "c.jpg"] }
        XCTAssertEqual(m.selectedEntry?.name, "c.jpg")
    }

    /// Reload (⌘R) while a search is shown searches again.
    func testReloadSearchesAgain() async throws {
        let tree = try TempTree(self)
        try tree.file("beach.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "beach")
        XCTAssertEqual(m.names, ["beach.jpg"])
        try tree.file("sub/beach2.jpg")
        m.reload()
        await waitUntil { m.names == ["beach.jpg", "beach2.jpg"] && !m.isSearching }
        XCTAssertEqual(m.searchText, "beach", "the search stays")
    }

    /// An ejected volume takes the pane showing a folder on it to the drives' level.
    func testAnUnmountedVolumeLeadsToTheDrives() async throws {
        let tree = try TempTree(self)
        try tree.file("a/b/c.jpg")
        let m = makeModel()
        let inner = tree.root.appendingPathComponent("a/b")
        await openAndWait(m, inner)
        m.volumesChanged(unmounted: URL(fileURLWithPath: "/elsewhere"))
        XCTAssertTrue(m.isAt(inner), "another volume: stays")
        m.volumesChanged(unmounted: tree.root)
        await waitUntil { m.isAt(URL(fileURLWithPath: BrowserModel.volumesPath)) }
    }

    /// FSEvents: a file another program adds shows by itself; the folder
    /// deleted leads to the folder around it.
    func testTheWatchedFolderFollowsChangesOnDisk() async throws {
        let tree = try TempTree(self)
        try tree.file("pics/a.jpg")
        let pics = tree.root.appendingPathComponent("pics")
        let m = makeModel()
        m.watchesFolder = true
        await openAndWait(m, pics)
        // Another process: the app's own changes aren't reported
        try run("/usr/bin/touch", pics.appendingPathComponent("b.jpg").path)
        await waitUntil({ m.names == ["..", "a.jpg", "b.jpg"] }, timeout: 15)
        try run("/bin/rm", "-rf", pics.path)
        await waitUntil({ m.isAt(tree.root) }, timeout: 15)
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
}
