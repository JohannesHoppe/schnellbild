import XCTest
import SwiftUI
@testable import Schnellbild

/// Hidden files and folders: one definition (a dot name or the hidden
/// flag; what macOS keeps for itself never), and every place that lists
/// items following the setting, off and on.
@MainActor
final class HiddenFilesTests: XCTestCase {
    nonisolated override func tearDownWithError() throws {
        HiddenFiles.shown = false
        try super.tearDownWithError()
    }

    /// The flag `chflags hidden` sets (as on ~/Library).
    @discardableResult
    private func flagHidden(_ url: URL) throws -> URL {
        var url = url
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
        return url
    }

    private func values(_ url: URL) -> URLResourceValues? { try? url.resourceValues(forKeys: HiddenFiles.keys) }

    /// A folder with something of every kind: visible, hidden by name, by
    /// the flag, and what macOS keeps for itself.
    private func mixedTree() throws -> TempTree {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.file(".dot.jpg")
        try flagHidden(tree.file("flagged.jpg"))
        try tree.file(".DS_Store")
        try tree.file("._a.jpg")
        try tree.file("Icon\r")
        try tree.file("notes.txt")
        try tree.file(".dotnotes.txt")
        try flagHidden(tree.file("flagged.txt"))
        try tree.file("sub/b.jpg")
        try tree.file(".hidden/c.jpg")
        try tree.file("flaggedfolder/d.jpg")
        try flagHidden(tree.root.appendingPathComponent("flaggedfolder", isDirectory: true))
        return tree
    }

    private func model(showing shown: Bool = false) -> BrowserModel {
        let m = makeModel()
        m.showHiddenFiles = shown
        return m
    }

    // MARK: The definition

    func testDotNamesAndTheFlagAreHidden() throws {
        let tree = try mixedTree()
        let url = { (name: String) in tree.root.appendingPathComponent(name) }
        XCTAssertFalse(HiddenFiles.isHidden(name: "a.jpg", values: values(url("a.jpg"))))
        XCTAssertTrue(HiddenFiles.isHidden(name: ".dot.jpg", values: nil), "a dot name, without looking at the disk")
        XCTAssertTrue(HiddenFiles.isHidden(name: "flagged.jpg", values: values(url("flagged.jpg"))), "the hidden flag")
        XCTAssertTrue(HiddenFiles.isHidden(name: "flaggedfolder", values: values(url("flaggedfolder"))))
        XCTAssertFalse(HiddenFiles.isHidden(name: "flagged.jpg", values: nil), "the flag needs the values")
    }

    func testWhatMacOSKeepsForItselfIsNeverShown() {
        for name in [".DS_Store", "._a.jpg", "._", "Icon\r", "__MACOSX", ".schnellbild-copy-\(UUID().uuidString)"] {
            XCTAssertTrue(HiddenFiles.isNeverShown(name), name)
            for shown in [false, true] {
                XCTAssertFalse(HiddenFiles.lists(URL(fileURLWithPath: "/x/\(name)"), values: nil, shown: shown), "\(name), shown \(shown)")
            }
        }
        for name in [".hidden", ".dot.jpg", "Icon", "Icons", "a.jpg", "_a.jpg", ".DS_Store2", "MACOSX"] {
            XCTAssertFalse(HiddenFiles.isNeverShown(name), name)
        }
    }

    func testListsFollowsTheSettingAndKeepsWhatWasOpened() throws {
        let tree = try mixedTree()
        let dot = tree.root.appendingPathComponent(".dot.jpg"), flagged = tree.root.appendingPathComponent("flagged.jpg")
        let plain = tree.root.appendingPathComponent("a.jpg")
        XCTAssertTrue(HiddenFiles.lists(plain, values: values(plain), shown: false))
        XCTAssertFalse(HiddenFiles.lists(dot, values: values(dot), shown: false))
        XCTAssertFalse(HiddenFiles.lists(flagged, values: values(flagged), shown: false))
        XCTAssertTrue(HiddenFiles.lists(dot, values: values(dot), shown: true))
        XCTAssertTrue(HiddenFiles.lists(flagged, values: values(flagged), shown: true))
        XCTAssertTrue(HiddenFiles.lists(dot, values: values(dot), shown: false, kept: [BrowserModel.canonicalPath(dot)]),
                      "opened by the user: shown though hidden")
    }

    func testPathsInsideArchives() {
        XCTAssertTrue(HiddenFiles.lists(archivePath: "Day 1/a.jpg", shown: false))
        XCTAssertFalse(HiddenFiles.lists(archivePath: ".hidden/a.jpg", shown: false), "a hidden folder on the way")
        XCTAssertTrue(HiddenFiles.lists(archivePath: ".hidden/a.jpg", shown: true))
        XCTAssertFalse(HiddenFiles.lists(archivePath: "__MACOSX/Day 1/._a.jpg", shown: true), "the Finder's AppleDouble folder")
        XCTAssertFalse(HiddenFiles.lists(archivePath: "Day 1/.DS_Store", shown: true))
    }

    func testTheFirstHiddenFolderOnTheWay() throws {
        let tree = try mixedTree()
        let deep = try tree.folder("sub/.inner/deeper")
        XCTAssertNil(HiddenFiles.firstHidden(below: tree.root, to: tree.root))
        XCTAssertNil(HiddenFiles.firstHidden(below: tree.root, to: tree.root.appendingPathComponent("sub")))
        XCTAssertEqual(HiddenFiles.firstHidden(below: tree.root, to: deep).map(BrowserModel.canonicalPath),
                       BrowserModel.canonicalPath(tree.root.appendingPathComponent("sub/.inner")))
        XCTAssertEqual(HiddenFiles.firstHidden(below: tree.root, to: tree.root.appendingPathComponent("flaggedfolder")).map(BrowserModel.canonicalPath),
                       BrowserModel.canonicalPath(tree.root.appendingPathComponent("flaggedfolder")), "by the flag")
        XCTAssertNil(HiddenFiles.firstHidden(below: tree.root.appendingPathComponent("sub/.inner"), to: deep),
                     "the folder the way starts at counts as shown")
    }

    // MARK: The grid, the list and the other files

    func testTheGridTheListAndTheOtherFiles() async throws {
        let tree = try mixedTree()
        for viewMode in [BrowserModel.ViewMode.grid, .list] {
            let m = model()
            m.viewMode = viewMode
            await openAndWait(m, tree.root)
            XCTAssertEqual(m.names, ["..", "sub", "a.jpg"], "\(viewMode): hidden items nowhere")
            XCTAssertEqual(m.otherFiles.map(\.name), ["notes.txt"], "the other files (and their count in the status bar)")
            XCTAssertFalse(m.entries.contains { $0.kind == .folder && $0.name != "sub" && $0.name != ".." },
                           "no hidden folder to drop onto")

            let shown = model(showing: true)
            shown.viewMode = viewMode
            await openAndWait(shown, tree.root)
            XCTAssertEqual(Set(shown.names), ["..", "sub", ".hidden", "flaggedfolder", "a.jpg", ".dot.jpg", "flagged.jpg"],
                           "\(viewMode): every hidden item, nothing macOS keeps for itself")
            XCTAssertEqual(Set(shown.otherFiles.map(\.name)), ["notes.txt", ".dotnotes.txt", "flagged.txt"])
        }
    }

    // MARK: Search

    func testSearchAlsoInSubfolders() async throws {
        let tree = try mixedTree()
        try tree.file("sub/match1.jpg")
        try tree.file(".hidden/match2.jpg")
        try tree.file("flaggedfolder/match3.jpg")
        try tree.file("sub/.match4.jpg")
        try flagHidden(tree.file("sub/match5.jpg"))
        try tree.file("sub/._match6.jpg")
        let m = model()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "match")
        XCTAssertEqual(m.names, ["match1.jpg"])

        let shown = model(showing: true)
        await openAndWait(shown, tree.root)
        await searchAndWait(shown, "match")
        XCTAssertEqual(Set(shown.names), ["match1.jpg", "match2.jpg", "match3.jpg", ".match4.jpg", "match5.jpg"])
    }

    // MARK: Slideshows and playlists, the Atlas, distance

    func testSlideshowAndItsPlaylist() async throws {
        let tree = try mixedTree()
        for shown in [false, true] {
            let m = model(showing: shown)
            m.slideshowInterval = .seconds(60)
            await openAndWait(m, tree.root)
            m.startSlideshow()
            await waitUntil { m.slideshow?.loading == false }
            let names = Set(m.slideshow?.items.map(\.name) ?? [])
            XCTAssertEqual(names, shown ? ["a.jpg", ".dot.jpg", "flagged.jpg", "b.jpg", "c.jpg", "d.jpg"] : ["a.jpg", "b.jpg"],
                           "shown \(shown): the show and its playlist hold the same items")
            m.stopSlideshow()
        }
    }

    func testTheAtlasWalkOfTheSubfolders() async throws {
        let tree = try mixedTree()
        for shown in [false, true] {
            let m = model(showing: shown)
            await openAndWait(m, tree.root)
            m.viewMode = .atlas
            let expected: Set<String> = shown ? ["a.jpg", ".dot.jpg", "flagged.jpg", "b.jpg", "c.jpg", "d.jpg"] : ["a.jpg", "b.jpg"]
            await waitUntil { !m.deepWalking && Set(m.names) == expected }
            XCTAssertEqual(Set(m.names), expected, "shown \(shown)")
        }
    }

    func testSortingByDistance() async throws {
        let tree = try mixedTree()
        let m = model()
        await openAndWait(m, tree.root)
        m.setDistanceOrigin(GeoPoint(latitude: 48, longitude: 11)!)
        await waitUntil { m.sortKey == .distance }
        XCTAssertEqual(m.names, ["..", "sub", "a.jpg"])
        m.showHiddenFiles = true
        await waitUntil { m.names.contains(".dot.jpg") }
        XCTAssertEqual(m.sortKey, .distance)
        XCTAssertEqual(Set(m.names), ["..", "sub", ".hidden", "flaggedfolder", "a.jpg", ".dot.jpg", "flagged.jpg"])
    }

    // MARK: Archives

    func testArchiveEntries() async throws {
        let tree = try TempTree(self)
        let content = try tree.folder("content")
        for name in ["a.jpg", ".b.jpg", ".hidden/c.jpg", "Day/.DS_Store", "Day/d.jpg", "__MACOSX/._a.jpg", ".notes.txt", "notes.txt"] {
            try tree.file("content/" + name, bytes: 4)
        }
        let zipping = Process()
        zipping.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipping.arguments = ["-q", "-0", "-r", "../holiday.zip", "."]
        zipping.currentDirectoryURL = content
        try zipping.run()
        zipping.waitUntilExit()
        XCTAssertEqual(zipping.terminationStatus, 0)
        let archive = tree.root.appendingPathComponent("holiday.zip")

        let m = model()
        await openAndWait(m, archive)
        XCTAssertEqual(Set(m.names), ["..", "Day", "a.jpg"])
        XCTAssertEqual(m.otherFiles.map(\.name), ["notes.txt"])
        let media = try await ArchiveStore.shared.media(below: archive).map(\.lastPathComponent)
        XCTAssertEqual(Set(media), ["a.jpg", "d.jpg"], "a folder tile's previews and emptiness")
        await searchAndWait(m, "jpg")
        XCTAssertEqual(Set(m.names), ["a.jpg", "d.jpg"])

        let shown = model(showing: true)
        await openAndWait(shown, archive)
        XCTAssertEqual(Set(shown.names), ["..", "Day", ".hidden", "a.jpg", ".b.jpg"], "never __MACOSX")
        XCTAssertEqual(Set(shown.otherFiles.map(\.name)), ["notes.txt", ".notes.txt"])
        await searchAndWait(shown, "jpg")
        XCTAssertEqual(Set(shown.names), ["a.jpg", ".b.jpg", "c.jpg", "d.jpg"])
    }

    // MARK: Folder tiles

    func testFolderTiles() async throws {
        let tree = try TempTree(self)
        let onlyHidden = try tree.folder("onlyHidden")
        try tree.file("onlyHidden/.a.jpg")
        try flagHidden(tree.file("onlyHidden/b.jpg"))
        try tree.file("onlyHidden/.inner/c.jpg")
        try tree.file("onlyHidden/._d.jpg")
        try tree.file("onlyHidden/.DS_Store")
        let empty = await BrowserModel.containsMedia(onlyHidden)
        XCTAssertEqual(empty, false, "greyed out: only hidden media")
        let none = await BrowserModel.folderPreviewFiles(in: onlyHidden)
        XCTAssertEqual(none, [])

        HiddenFiles.shown = true
        let full = await BrowserModel.containsMedia(onlyHidden)
        XCTAssertEqual(full, true)
        let previews = await BrowserModel.folderPreviewFiles(in: onlyHidden)
        XCTAssertEqual(Set(previews.map(\.lastPathComponent)), [".a.jpg", "b.jpg"], "never AppleDouble")

        try FileManager.default.removeItem(at: onlyHidden.appendingPathComponent(".a.jpg"))
        try FileManager.default.removeItem(at: onlyHidden.appendingPathComponent("b.jpg"))
        let deeper = await BrowserModel.folderPreviewFiles(in: onlyHidden)
        XCTAssertEqual(deeper.map(\.lastPathComponent), ["c.jpg"], "from a hidden subfolder while shown")
    }

    // MARK: What the user opened himself, and paths he didn't

    func testAFileDroppedIsShownThoughHidden() async throws {
        let tree = try mixedTree()
        let m = model()
        let dot = tree.root.appendingPathComponent(".dot.jpg")
        m.openDropped([dot])
        await waitUntil { m.isAt(tree.root) && m.mode == .detail }
        XCTAssertEqual(m.selectedEntry?.name, ".dot.jpg")
        XCTAssertTrue(m.names.contains(".dot.jpg"))
        XCTAssertFalse(m.names.contains("flagged.jpg"), "only that one")
    }

    func testAHiddenFolderOpenedStaysWhenTurnedOff() async throws {
        let tree = try mixedTree()
        let hidden = tree.root.appendingPathComponent(".hidden", isDirectory: true)
        let m = model(showing: true)
        m.openDropped([hidden])
        await waitUntil { m.isAt(hidden) }
        m.showHiddenFiles = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(m.isAt(hidden), "dropped on the window: the user's own choice")
        XCTAssertEqual(m.names, ["..", "c.jpg"])
    }

    func testTurnedOffInsideAHiddenFolderGoesToTheFolderAbove() async throws {
        let tree = try mixedTree()
        let inner = try tree.file(".hidden/inner/e.jpg").deletingLastPathComponent()
        let m = model(showing: true)
        await openAndWait(m, tree.root)
        m.open(folder: tree.root.appendingPathComponent(".hidden", isDirectory: true))
        await waitUntil { m.isAt(tree.root.appendingPathComponent(".hidden")) }
        m.open(folder: inner)
        await waitUntil { m.isAt(inner) }
        m.showHiddenFiles = false
        await waitUntil { m.isAt(tree.root) }
        XCTAssertEqual(m.names, ["..", "sub", "a.jpg"])
        XCTAssertFalse(m.backStack.contains { BrowserModel.canonicalPath($0.folder).contains("/.hidden") },
                       "the history leaves the hidden folders")
    }

    // MARK: Live switching

    func testSwitchingKeepsTheSelectionAndReachesEveryPane() async throws {
        let tree = try mixedTree()
        let defaults = makeTestDefaults()
        let left = BrowserModel(defaults: defaults)
        let right = BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        for pane in [left, right] { pane.searchDebounce = .zero }
        await openAndWait(left, tree.root)
        await openAndWait(right, tree.root)
        left.selectEntry(named: "a.jpg")
        await searchAndWait(right, "jpg")
        XCTAssertEqual(Set(right.names), ["a.jpg", "b.jpg"])

        left.showHiddenFiles = true
        XCTAssertTrue(right.showHiddenFiles, "the other pane follows")
        XCTAssertTrue(defaults.bool(forKey: HiddenFiles.shownKey), "remembered")
        await waitUntil { left.names.contains(".dot.jpg") && right.names.contains("c.jpg") && !right.isSearching }
        XCTAssertEqual(left.selectedEntry?.name, "a.jpg", "the selection stays on its item")
        XCTAssertEqual(Set(right.names), ["a.jpg", ".dot.jpg", "flagged.jpg", "b.jpg", "c.jpg", "d.jpg"], "the search again")

        right.showHiddenFiles = false
        XCTAssertFalse(left.showHiddenFiles)
        await waitUntil { !left.names.contains(".dot.jpg") && !right.names.contains("c.jpg") && !right.isSearching }
        XCTAssertEqual(left.selectedEntry?.name, "a.jpg")
        XCTAssertEqual(Set(right.names), ["a.jpg", "b.jpg"])

        let later = BrowserModel(defaults: defaults)
        XCTAssertFalse(later.showHiddenFiles, "a new pane reads the preference")
    }

    func testTheMenuKeyByItsPlaceOnTheKeyboard() async throws {
        let defaults = makeTestDefaults()
        let left = BrowserModel(defaults: defaults)
        let window = WindowModel(left: left, defaults: defaults) { BrowserModel(defaults: defaults, settingsPrefix: "rightPane.") }
        window.shortcuts = Shortcuts(defaults: defaults)
        let key = try XCTUnwrap(KeyChord(stored: "$@."))
        XCTAssertEqual(key.text, "⇧⌘.")
        XCTAssertTrue(key.isOnKey)
        XCTAssertEqual(window.shortcuts.keys(.hiddenFiles), [key])
        XCTAssertEqual(key.menuShortcut, KeyboardShortcut(".", modifiers: [.command, .shift]))
        // ⇧⌘. as AppKit reads it on a US layout (⌘>) and on a German one (⌘:)
        for typed in [">", ":"] {
            let before = window.showHiddenFiles
            XCTAssertEqual(window.handleTyped(KeyChord(.char(Character(typed)), command: true, shift: true), physical: key, textEditing: false), true)
            XCTAssertEqual(window.showHiddenFiles, !before, typed)
        }
        XCTAssertNil(window.handleTyped(KeyChord(.char("."), command: true), physical: nil, textEditing: false), "⌘. alone is no action's")
    }

    // MARK: Hidden companions stay readable

    func testHiddenTracksAndSidecarsAreStillRead() throws {
        let tree = try TempTree(self)
        try tree.file(".track.gpx")
        try flagHidden(tree.file("flagged.gpx"))
        try tree.file("._track.gpx")
        try tree.file(".a.jpg.xmp")
        let listing = FolderNames(recheck: 0).listing(of: tree.root)
        XCTAssertEqual(listing.tracks.map(\.name), [".track.gpx", "flagged.gpx"], "hidden tracks are read, AppleDouble files aren't tracks")
        XCTAssertEqual(listing.names[".a.jpg.xmp"], ".a.jpg.xmp", "hidden sidecars are found")
    }
}
