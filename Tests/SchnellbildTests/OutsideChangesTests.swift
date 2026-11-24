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

    /// The folder shown renamed from its title, FSEvents reporting it gone
    /// while the rename is under way (on disk, its change not applied yet)
    /// and again after: the pane stays in it under its new name.
    func testTheFolderShownRenamedByTheAppStaysWhenReportedGone() async throws {
        let tree = try TempTree(self)
        try tree.file("Trip/a.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root.appendingPathComponent("Trip"))
        spy.duringMove = { m.changedOutside(nil, rootChanged: true) }
        await m.renameCurrentFolder(to: "Iceland")
        m.changedOutside(nil, rootChanged: true)
        let renamed = tree.root.appendingPathComponent("Iceland")
        await stays(m, renamed)
        XCTAssertEqual(m.names, ["..", "a.jpg"])
    }

    /// FSEvents reports the folder shown gone, and while the disk is read
    /// the folder's move reaches the pane (another pane moved it): the pane
    /// follows the move and stays there.
    func testTheFolderShownMovedWhileLookedForStaysUnderItsNewPath() async throws {
        let tree = try TempTree(self)
        try tree.file("Trip/a.jpg")
        let trip = tree.root.appendingPathComponent("Trip")
        let renamed = tree.root.appendingPathComponent("Iceland")
        let m = makeModel()
        await openAndWait(m, trip)
        try FileManager.default.moveItem(at: trip, to: renamed)
        m.changedOutside(nil, rootChanged: true)
        m.adopt([.moved(trip, to: renamed)])
        await waitUntil { m.isAt(renamed) }
        await stays(m, renamed)
    }

    /// The folder shown deleted by another program: the folder around it
    /// opens, also when the report comes while the app renames something
    /// in another pane.
    func testTheFolderShownDeletedElsewhereOpensTheFolderAroundIt() async throws {
        let tree = try TempTree(self)
        try tree.file("pics/a.jpg")
        try tree.file("other/b.jpg")
        let pics = tree.root.appendingPathComponent("pics")
        let m = makeModel()
        await openAndWait(m, pics)
        let spy = FileActionsSpy()
        let other = makeModel(spy)
        await openAndWait(other, tree.root.appendingPathComponent("other"))
        spy.duringMove = {
            try? FileManager.default.removeItem(at: pics)
            m.changedOutside(nil, rootChanged: true)
        }
        _ = try await other.rename(try XCTUnwrap(other.entries.first { $0.name == "b.jpg" }), to: "c.jpg")
        await waitUntil { m.isAt(tree.root) }

        let gone = try tree.folder("again/inner")
        await openAndWait(m, gone)
        try FileManager.default.removeItem(at: gone.deletingLastPathComponent())
        m.changedOutside(nil, rootChanged: true)
        await waitUntil { m.isAt(tree.root) }
    }

    /// The pane stays at `folder` for a while (a wrong move would come
    /// within milliseconds: one look at the disk).
    /// A folder moved into the folder shown whole (FSEvents names only the
    /// folder shown): what it holds joins the search shown.
    func testAFolderMovedInWholeJoinsTheSearch() async throws {
        let tree = try TempTree(self)
        try tree.file("IMG_1.jpg")
        let elsewhere = try TempTree(self)
        try elsewhere.file("Trip/Day1/IMG_2.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "IMG")
        XCTAssertEqual(m.names, ["IMG_1.jpg"])
        try FileManager.default.moveItem(at: elsewhere.root.appendingPathComponent("Trip"), to: tree.root.appendingPathComponent("Trip"))
        m.changedOutside([BrowserModel.canonicalPath(tree.root)], rootChanged: false)
        await waitUntil { m.names == ["IMG_1.jpg", "IMG_2.jpg"] }
    }

    /// Changes inside hidden folders and packages, which the search never
    /// walks into, bring no results from there.
    func testChangesInsideHiddenFoldersAndPackagesBringNoResults() async throws {
        let tree = try TempTree(self)
        try tree.file("IMG_1.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "IMG")
        XCTAssertEqual(m.names, ["IMG_1.jpg"])
        try tree.file(".thumbnails/IMG_2.jpg")
        try tree.file("Tool.app/Contents/Resources/IMG_3.jpg")
        try tree.file("Visible/IMG_4.jpg")
        let paths = [".thumbnails", "Tool.app/Contents/Resources", "Visible"].map {
            BrowserModel.canonicalPath(tree.root.appendingPathComponent($0))
        }
        m.changedOutside(paths, rootChanged: false)
        await waitUntil { m.names.contains("IMG_4.jpg") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(m.names, ["IMG_1.jpg", "IMG_4.jpg"])
    }

    /// The folder shown replaced by another under the same path (FSEvents
    /// says only that its root changed): the new one's items show.
    func testTheFolderShownReplacedInPlaceIsReadAgain() async throws {
        let tree = try TempTree(self)
        try tree.file("p/old.jpg")
        try tree.file("pnew/new.jpg")
        let p = tree.root.appendingPathComponent("p")
        let m = makeModel()
        await openAndWait(m, p)
        try FileManager.default.moveItem(at: p, to: tree.root.appendingPathComponent("pold"))
        try FileManager.default.moveItem(at: tree.root.appendingPathComponent("pnew"), to: p)
        m.changedOutside(nil, rootChanged: true)
        await waitUntil { m.names == ["..", "new.jpg"] }
        XCTAssertTrue(m.isAt(p))
    }

    private func stays(_ m: BrowserModel, _ folder: URL, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<50 {
            guard m.isAt(folder) else { XCTFail("left \(folder.lastPathComponent): \(m.folderURL?.path ?? "none")", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
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
