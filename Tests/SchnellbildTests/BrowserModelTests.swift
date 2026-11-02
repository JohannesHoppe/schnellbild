import XCTest
@testable import Schnellbild

// MARK: - Helpers

/// A temporary folder tree, removed in the test's teardown (not in deinit:
/// ARC may release the object right after its last use, mid-test).
final class TempTree {
    let root: URL

    init(_ testCase: XCTestCase) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    /// Create a file (and its parent folders); returns its URL.
    @discardableResult
    func file(_ path: String, bytes: Int = 0) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Records file actions instead of touching Finder, the Trash or alerts.
@MainActor
final class FileActionsSpy {
    var revealed: [URL] = []
    var opened: [URL] = []
    var trashed: [URL] = []
    var moved: [(URL, URL)] = []
    var confirm = true
    var moveError: Error?

    var actions: FileActions {
        FileActions(
            reveal: { self.revealed.append($0) },
            openInDefaultApp: { self.opened.append($0) },
            confirmTrash: { _ in self.confirm },
            trash: { url in
                self.trashed.append(url)
                try FileManager.default.removeItem(at: url)
            },
            move: { from, to in
                if let error = self.moveError { throw error }
                self.moved.append((from, to))
                try FileActions.live.move(from, to)
            }
        )
    }
}

@MainActor
final class PlayerSpy: PlaybackControl {
    var calls: [String] = []
    func play()  { calls.append("play") }
    func pause() { calls.append("pause") }
    func seek(by seconds: Double) { calls.append("seek \(Int(seconds))") }
}

@MainActor
func makeModel(_ spy: FileActionsSpy? = nil) -> BrowserModel {
    let defaults = UserDefaults(suiteName: "sb.tests.\(UUID().uuidString)")!
    let model = BrowserModel(defaults: defaults, fileActions: spy?.actions ?? .live)
    model.searchDebounce = .zero
    model.slideshowInterval = .milliseconds(50)
    return model
}

@MainActor
func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5,
               file: StaticString = #filePath, line: UInt = #line) async {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > timeout {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
func openAndWait(_ model: BrowserModel, _ folder: URL) async {
    model.open(folder: folder)
    await waitUntil { model.isAt(folder) }
}

@MainActor
func searchAndWait(_ model: BrowserModel, _ query: String) async {
    model.searchText = query
    await waitUntil { !model.isSearching }
}

extension BrowserModel {
    /// Finished loading `folder` (compared by resolved path: /var vs /private/var).
    func isAt(_ folder: URL) -> Bool {
        !isLoading && folderURL.map { BrowserModel.samePath($0, folder) } == true
    }
    var names: [String] { entries.map(\.name) }
    func selectEntry(named name: String) {
        selection = entries.firstIndex { $0.name == name }
    }
}

// MARK: - GridEntry

final class GridEntryTests: XCTestCase {
    func testParentNameIsDotDot() {
        XCTAssertEqual(GridEntry(url: URL(fileURLWithPath: "/some/dir"), kind: .parent).name, "..")
    }

    func testFileNameIsLastComponent() {
        XCTAssertEqual(GridEntry(url: URL(fileURLWithPath: "/a/b/photo.jpg"), kind: .image).name, "photo.jpg")
    }

    func testIsMedia() {
        XCTAssertTrue(GridEntry(url: URL(fileURLWithPath: "/x.jpg"), kind: .image).isMedia)
        XCTAssertTrue(GridEntry(url: URL(fileURLWithPath: "/x.mp4"), kind: .video).isMedia)
        XCTAssertFalse(GridEntry(url: URL(fileURLWithPath: "/x"), kind: .folder).isMedia)
        XCTAssertFalse(GridEntry(url: URL(fileURLWithPath: "/x"), kind: .parent).isMedia)
    }

    func testIsGIFIsCaseInsensitive() {
        XCTAssertTrue(GridEntry(url: URL(fileURLWithPath: "/a/anim.GIF"), kind: .image).isGIF)
        XCTAssertFalse(GridEntry(url: URL(fileURLWithPath: "/a/anim.png"), kind: .image).isGIF)
    }
}

// MARK: - Sorting

@MainActor
final class SortTests: XCTestCase {
    private func entry(_ name: String, _ kind: GridEntry.Kind, date: Date? = nil, size: Int? = nil) -> GridEntry {
        GridEntry(url: URL(fileURLWithPath: "/root/\(name)"), kind: kind, modDate: date, byteSize: size)
    }

    func testParentFirstThenFoldersThenMedia() {
        let input = [entry("b.jpg", .image), entry("zfolder", .folder), entry("a.mp4", .video),
                     entry("dotdot", .parent), entry("afolder", .folder)]
        let sorted = BrowserModel.sortEntries(input, key: .name, ascending: true)
        XCTAssertEqual(sorted.map(\.name), ["..", "afolder", "zfolder", "a.mp4", "b.jpg"])
    }

    func testNameAscendingAndDescending() {
        let input = [entry("a.jpg", .image), entry("c.jpg", .image), entry("b.jpg", .image)]
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .name, ascending: true).map(\.name),
                       ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .name, ascending: false).map(\.name),
                       ["c.jpg", "b.jpg", "a.jpg"])
    }

    func testNameSortIsNumericAware() {
        let input = [entry("img2.jpg", .image), entry("img10.jpg", .image), entry("img1.jpg", .image)]
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .name, ascending: true).map(\.name),
                       ["img1.jpg", "img2.jpg", "img10.jpg"])
    }

    func testSortByDateAndSize() {
        let input = [entry("new.jpg", .image, date: Date(timeIntervalSince1970: 1000), size: 10),
                     entry("old.jpg", .image, date: Date(timeIntervalSince1970: 0), size: 99)]
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .date, ascending: true).map(\.name), ["old.jpg", "new.jpg"])
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .size, ascending: true).map(\.name), ["new.jpg", "old.jpg"])
    }

    func testSetSortTogglesDirectionAndKeepsSelection() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "b.jpg")

        m.setSort(.name)   // same key → descending
        XCTAssertFalse(m.sortAscending)
        XCTAssertEqual(m.names, ["..", "c.jpg", "b.jpg", "a.jpg"])
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")

        m.setSort(.size)   // new key → ascending again
        XCTAssertEqual(m.sortKey, .size)
        XCTAssertTrue(m.sortAscending)
    }
}

// MARK: - Directory scan & folder previews

final class ScanTests: XCTestCase {
    func testScanClassifiesIncludesHiddenExcludesNonMedia() async throws {
        let tree = try TempTree(self)
        try tree.file("photo.jpg")
        try tree.file("clip.mp4")
        try tree.file("notes.txt")
        try tree.file(".secret.png")
        try tree.folder("sub")

        let entries = await BrowserModel.scan(tree.root)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["photo.jpg"]?.kind, .image)
        XCTAssertEqual(byName["clip.mp4"]?.kind, .video)
        XCTAssertEqual(byName["sub"]?.kind, .folder)
        XCTAssertNotNil(byName[".secret.png"], "hidden media is listed")
        XCTAssertNil(byName["notes.txt"], "non-media files are excluded")
    }

    func testFolderPreviewFilesAreFirstThreeMediaByNameShallow() async throws {
        let tree = try TempTree(self)
        for n in ["img10.jpg", "img2.jpg", "img1.jpg", "clip.mp4", "notes.txt", ".hidden.jpg"] {
            try tree.file(n)
        }
        try tree.file("deeper/aaa.jpg")

        let files = await BrowserModel.folderPreviewFiles(in: tree.root)
        XCTAssertEqual(files.map(\.lastPathComponent), ["clip.mp4", "img1.jpg", "img2.jpg"])
    }

    func testFolderPreviewFilesOfEmptyOrMissingFolder() async throws {
        let tree = try TempTree(self)
        let empty = await BrowserModel.folderPreviewFiles(in: tree.root)
        XCTAssertTrue(empty.isEmpty)
        let missing = await BrowserModel.folderPreviewFiles(in: tree.root.appendingPathComponent("nope"))
        XCTAssertTrue(missing.isEmpty)
    }
}

// MARK: - Model basics

@MainActor
final class BrowserModelTests: XCTestCase {
    func testZoomClampsBetweenFitAndMax() {
        let m = makeModel()
        m.zoomIn()
        XCTAssertEqual(m.zoom, 1.25, accuracy: 0.0001)
        for _ in 0..<50 { m.zoomIn() }
        XCTAssertEqual(m.zoom, 8, accuracy: 0.0001)
        for _ in 0..<50 { m.zoomOut() }
        XCTAssertEqual(m.zoom, 1, accuracy: 0.0001)
    }

    func testPinchAndActualSizeClamp() {
        let m = makeModel()
        m.applyPinch(0.2)
        XCTAssertEqual(m.zoom, 1, accuracy: 0.0001)
        m.applyPinch(100)
        XCTAssertEqual(m.zoom, 8, accuracy: 0.0001)
        m.actualSizeFactor = 2.5
        m.zoomActualSize()
        XCTAssertEqual(m.zoom, 2.5, accuracy: 0.0001)
        m.actualSizeFactor = 0.3   // image smaller than the window → stays at fit
        m.zoomActualSize()
        XCTAssertEqual(m.zoom, 1, accuracy: 0.0001)
    }

    func testThumbnailSizeClamps() {
        let m = makeModel()
        for _ in 0..<50 { m.growThumbnails() }
        XCTAssertEqual(m.thumbnailSide, 320)
        for _ in 0..<50 { m.shrinkThumbnails() }
        XCTAssertEqual(m.thumbnailSide, 80)
    }

    func testScaleIsModeAware() {
        let m = makeModel()
        m.mode = .detail
        m.scaleUp()
        XCTAssertGreaterThan(m.zoom, 1)
        m.mode = .grid
        let side = m.thumbnailSide
        m.scaleUp()
        XCTAssertGreaterThan(m.thumbnailSide, side)
        m.scaleDown()
        XCTAssertEqual(m.thumbnailSide, side)
    }

    func testLeaveDetailReturnsToGrid() {
        let m = makeModel()
        m.mode = .detail
        m.leaveDetailOrGoUp()
        XCTAssertEqual(m.mode, .grid)
    }

    func testRotationWraps() {
        let m = makeModel()
        m.rotateRight()
        XCTAssertEqual(m.rotation, 90)
        m.rotateRight(); m.rotateRight(); m.rotateRight()
        XCTAssertEqual(m.rotation, 0)
        m.rotateLeft()
        XCTAssertEqual(m.rotation, -90)
    }

    func testCloseDetailResetsTransforms() {
        let m = makeModel()
        m.mode = .detail
        m.rotateRight()
        m.zoomIn()
        m.closeDetail()
        XCTAssertEqual(m.rotation, 0)
        XCTAssertEqual(m.zoom, 1)
        XCTAssertEqual(m.mode, .grid)
    }
}

// MARK: - Opening folders

@MainActor
final class OpenFolderTests: XCTestCase {
    func testOpenPopulatesCountsSelectionAndNavigation() async throws {
        let tree = try TempTree(self)
        try tree.folder("sub")
        for n in ["a.jpg", "b.jpg", "c.mp4"] { try tree.file(n) }

        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, ["..", "sub", "a.jpg", "b.jpg", "c.mp4"])
        XCTAssertEqual(m.folderCount, 1)
        XCTAssertEqual(m.imageCount, 2)
        XCTAssertEqual(m.videoCount, 1)
        XCTAssertEqual(m.mediaCount, 3)
        XCTAssertEqual(m.selectedEntry?.name, "sub", "selection starts on the first non-parent entry")

        m.selection = m.entries.count - 1
        m.stepMedia(1)
        XCTAssertEqual(m.selection, m.entries.count - 1, "stepMedia clamps at the end")
        m.selectEntry(named: "a.jpg")
        m.stepMedia(-1)
        XCTAssertEqual(m.selectedEntry?.name, "a.jpg", "stepMedia never lands on a folder")
        XCTAssertEqual(m.currentMediaNumber, 1)
    }

    func testDroppingAFileOpensItInDetail() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let file = try tree.file("b.jpg")

        let m = makeModel()
        m.openDropped([file])
        await waitUntil { m.mode == .detail }
        XCTAssertEqual(m.selectedMediaEntry?.name, "b.jpg")
    }

    func testDroppingAFolderOpensItAndMissingPathsAreIgnored() async throws {
        let tree = try TempTree(self)
        let sub = try tree.folder("sub")
        try tree.file("sub/x.jpg")

        let m = makeModel()
        m.openDropped([tree.root.appendingPathComponent("missing")])
        XCTAssertNil(m.folderURL)
        m.openDropped([sub])
        await waitUntil { m.isAt(sub) }
        await waitUntil { m.isAt(sub) }
        XCTAssertEqual(m.names, ["..", "x.jpg"])
    }

    func testLaunchArgumentOpensFolderOrFile() async throws {
        let tree = try TempTree(self)
        let file = try tree.file("a.jpg")
        let m = makeModel()
        XCTAssertFalse(m.openFromLaunchArguments(["app"]))
        XCTAssertFalse(m.openFromLaunchArguments(["app", "--open", "/does/not/exist"]))
        XCTAssertTrue(m.openFromLaunchArguments(["app", "--open", file.path]))
        await waitUntil { m.mode == .detail }
        XCTAssertEqual(m.selectedMediaEntry?.name, "a.jpg")
    }

    func testLastFolderIsRememberedAndRestored() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let defaults = UserDefaults(suiteName: "sb.tests.\(UUID().uuidString)")!

        let first = BrowserModel(defaults: defaults)
        await openAndWait(first, tree.root)

        let second = BrowserModel(defaults: defaults)
        second.restoreLastFolder()
        await waitUntil { second.isAt(tree.root) }
    }

    func testRestoreIgnoresMissingFolder() {
        let defaults = UserDefaults(suiteName: "sb.tests.\(UUID().uuidString)")!
        defaults.set("/does/not/exist", forKey: BrowserModel.lastFolderKey)
        let m = BrowserModel(defaults: defaults)
        m.restoreLastFolder()
        XCTAssertNil(m.folderURL)
    }

    func testUITestingUsesSeparateResettableDefaults() {
        XCTAssertTrue(BrowserModel.makeDefaults(arguments: ["app"]) === UserDefaults.standard)
        let suite = BrowserModel.makeDefaults(arguments: ["app", "--ui-testing"])
        XCTAssertFalse(suite === UserDefaults.standard)
        suite.set("x", forKey: BrowserModel.lastFolderKey)
        let reset = BrowserModel.makeDefaults(arguments: ["app", "--ui-testing", "--reset-state"])
        XCTAssertNil(reset.string(forKey: BrowserModel.lastFolderKey))
    }

    func testEmptyFolderHasOnlyParent() async throws {
        let tree = try TempTree(self)
        let empty = try tree.folder("empty")
        let m = makeModel()
        await openAndWait(m, empty)
        XCTAssertEqual(m.names, [".."])
        XCTAssertEqual(m.mediaCount, 0)
    }
}

// MARK: - Search

@MainActor
final class SearchTests: XCTestCase {
    func testSearchMatchesFileNamesInCurrentFolder() async throws {
        let tree = try TempTree(self)
        for n in ["apple.jpg", "banana.jpg", "cherry.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)

        await searchAndWait(m, "BAN")
        XCTAssertEqual(m.names, ["banana.jpg"], "case-insensitive, parent excluded")

        await searchAndWait(m, "")
        XCTAssertEqual(m.names, ["..", "apple.jpg", "banana.jpg", "cherry.jpg"])
    }

    func testSearchIsAlwaysRecursive() async throws {
        let tree = try TempTree(self)
        try tree.file("readme.jpg")
        try tree.file("vacation/2024/beach-sunset.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)

        await searchAndWait(m, "sunset")
        XCTAssertEqual(m.names, ["beach-sunset.jpg"])
        XCTAssertEqual(m.relativeLocation(of: m.entries[0]), "vacation/2024")
    }

    func testSearchMatchesFolderNamesAtAnyDepth() async throws {
        let tree = try TempTree(self)
        try tree.folder("Urlaub 2023")
        try tree.folder("archive/Urlaub 2024")
        try tree.file("urlaub-photo.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)

        await searchAndWait(m, "urlaub")
        XCTAssertEqual(m.names, ["Urlaub 2023", "Urlaub 2024", "urlaub-photo.jpg"],
                       "folders and files both match; folders first")
        XCTAssertEqual(m.entries.first { $0.name == "Urlaub 2024" }?.kind, .folder)
        XCTAssertNil(m.relativeLocation(of: m.entries[0]), "top-level match has no location")
    }

    func testSearchSkipsHiddenSubfoldersAndNonMedia() async throws {
        let tree = try TempTree(self)
        try tree.file(".git/match.jpg")
        try tree.file("sub/match.txt")
        try tree.file("sub/match.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)

        await searchAndWait(m, "match")
        XCTAssertEqual(m.names, ["match.jpg"])
        XCTAssertEqual(m.relativeLocation(of: m.entries[0]), "sub")
    }

    func testSearchWithNoMatchesIsEmpty() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "zzz")
        XCTAssertTrue(m.entries.isEmpty)
        XCTAssertNil(m.selection)
    }

    func testRecursiveMatchesStreamFindsEverythingAcrossBatches() async throws {
        let tree = try TempTree(self)
        for i in 0..<150 { try tree.file("d\(i % 7)/hit\(i).jpg") }
        var found: [GridEntry] = []
        for await batch in BrowserModel.recursiveMatches(under: tree.root, query: "hit") {
            found += batch
        }
        XCTAssertEqual(found.count, 150)
    }

    func testTypingInFullViewSwitchesToResultsGrid() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        m.activateSelection()
        XCTAssertEqual(m.mode, .detail)

        await searchAndWait(m, "b")
        XCTAssertEqual(m.mode, .grid)
        XCTAssertEqual(m.names, ["b.jpg"])
    }

    func testClearingSearchKeepsTheSelectedItem() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "c")
        XCTAssertEqual(m.selectedEntry?.name, "c.jpg")
        await searchAndWait(m, "")
        XCTAssertEqual(m.selectedEntry?.name, "c.jpg")
    }

    func testTypingWhileLoadingIsAppliedAfterLoad() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.open(folder: tree.root)
        m.searchText = "b"
        await waitUntil { !m.isLoading && !m.isSearching && !m.entries.isEmpty }
        XCTAssertEqual(m.names, ["b.jpg"])
    }

    func testEscapeInGridClearsSearch() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertFalse(m.handleKey(.escape, command: false), "nothing to clear")
        await searchAndWait(m, "b")
        XCTAssertTrue(m.handleKey(.escape, command: false))
        XCTAssertEqual(m.searchText, "")
        XCTAssertEqual(m.names, ["..", "a.jpg", "b.jpg"])
    }

    func testSearchFieldKeys() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.searchFocused = true
        await searchAndWait(m, "b")

        // Escape: first clears, then leaves the field.
        XCTAssertTrue(m.handleSearchFieldKey(.escape))
        XCTAssertEqual(m.searchText, "")
        XCTAssertTrue(m.searchFocused)
        XCTAssertTrue(m.handleSearchFieldKey(.escape))
        XCTAssertFalse(m.searchFocused)

        // ↓ moves into the results.
        m.searchFocused = true
        await searchAndWait(m, "b")
        XCTAssertTrue(m.handleSearchFieldKey(.down))
        XCTAssertFalse(m.searchFocused)
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")

        // Return opens the selected result.
        m.searchFocused = true
        XCTAssertTrue(m.handleSearchFieldKey(.enter))
        XCTAssertEqual(m.mode, .detail)
        XCTAssertEqual(m.selectedMediaEntry?.name, "b.jpg")

        XCTAssertFalse(m.handleSearchFieldKey(.left), "other keys stay with the field")
    }
}

// MARK: - History (back / forward / up)

@MainActor
final class HistoryTests: XCTestCase {
    func testBackAndForward() async throws {
        let tree = try TempTree(self)
        let sub = try tree.folder("sub")
        try tree.file("sub/x.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertFalse(m.canGoBack)
        XCTAssertFalse(m.canGoForward)

        m.selectEntry(named: "sub")
        m.activateSelection()
        await waitUntil { m.isAt(sub) }
        XCTAssertTrue(m.canGoBack)

        m.navigateBack()
        await waitUntil { m.isAt(tree.root) }
        XCTAssertEqual(m.selectedEntry?.name, "sub", "back restores the selection")
        XCTAssertTrue(m.canGoForward)

        m.navigateForward()
        await waitUntil { m.isAt(sub) }
        XCTAssertFalse(m.canGoForward)
        XCTAssertTrue(m.canGoBack)
    }

    func testNewNavigationClearsForward() async throws {
        let tree = try TempTree(self)
        let a = try tree.folder("a")
        try tree.folder("b")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await openAndWait(m, a)
        m.navigateBack()
        await waitUntil { m.isAt(tree.root) }
        XCTAssertTrue(m.canGoForward)
        await openAndWait(m, tree.root.appendingPathComponent("b"))
        XCTAssertFalse(m.canGoForward)
    }

    func testBackFromSearchResultRestoresTheSearch() async throws {
        let tree = try TempTree(self)
        let album = try tree.folder("deep/Album 2024")
        try tree.file("deep/Album 2024/inside.jpg")
        try tree.file("other.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "album")
        XCTAssertEqual(m.names, ["Album 2024"])

        m.handleKey(.enter, command: false)   // enter the result folder
        await waitUntil { m.isAt(album) }
        XCTAssertEqual(m.searchText, "", "the result folder shows its own contents")
        XCTAssertEqual(m.names, ["..", "inside.jpg"])

        m.navigateBack()
        await waitUntil { m.isAt(tree.root) && !m.isSearching && !m.entries.isEmpty }
        XCTAssertEqual(m.searchText, "album")
        XCTAssertEqual(m.names, ["Album 2024"])
        XCTAssertEqual(m.selectedEntry?.name, "Album 2024")

        m.navigateForward()
        await waitUntil { m.isAt(album) }
        XCTAssertEqual(m.searchText, "")
    }

    func testBackFromFullViewOfSearchResultRestoresSearch() async throws {
        let tree = try TempTree(self)
        try tree.file("sub/target.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "target")
        m.handleKey(.enter, command: false)
        XCTAssertEqual(m.mode, .detail)
        m.handleKey(.escape, command: false)
        XCTAssertEqual(m.mode, .grid)
        XCTAssertEqual(m.names, ["target.jpg"], "leaving the full view returns to the results")
    }

    func testUpGoesToParentAndSelectsTheFolderWeCameFrom() async throws {
        let tree = try TempTree(self)
        let sub = try tree.folder("sub")
        try tree.folder("another")
        let m = makeModel()
        await openAndWait(m, sub)
        XCTAssertTrue(m.canGoUp)
        XCTAssertTrue(m.handleKey(.up, command: true))   // ⌘↑
        await waitUntil { m.isAt(tree.root) }
        XCTAssertEqual(m.selectedEntry?.name, "sub")
        XCTAssertTrue(m.canGoBack, "going up is recorded in the history")
    }

    func testBackspaceAndParentTileGoUp() async throws {
        let tree = try TempTree(self)
        let sub = try tree.folder("sub")
        let m = makeModel()
        await openAndWait(m, sub)
        m.handleKey(.backspace, command: false)
        await waitUntil { m.isAt(tree.root) }

        await openAndWait(m, sub)
        m.select(0)   // ".."
        m.activateSelection()
        await waitUntil { m.isAt(tree.root) }
    }

    func testCannotGoUpFromFilesystemRoot() async {
        let m = makeModel()
        XCTAssertFalse(m.canGoUp)
        await openAndWait(m, URL(fileURLWithPath: "/"))
        XCTAssertFalse(m.canGoUp)
        XCTAssertNotEqual(m.entries.first?.kind, .parent)
    }
}

// MARK: - Rename folder

@MainActor
final class RenameTests: XCTestCase {
    func testRenameMovesFolderAndUpdatesGridAndSelection() async throws {
        let tree = try TempTree(self)
        try tree.file("old/x.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "old")

        XCTAssertTrue(m.beginRename())
        let entry = try XCTUnwrap(m.renameTarget)
        let new = try m.renameFolder(entry, to: "  Zebra  ")

        XCTAssertEqual(new.lastPathComponent, "Zebra", "whitespace is trimmed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("Zebra/x.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("old").path))
        XCTAssertEqual(m.names, ["..", "Zebra"])
        XCTAssertEqual(m.selectedEntry?.name, "Zebra")
        XCTAssertNil(m.renameTarget, "sheet closes")
    }

    func testRenameValidation() async throws {
        let tree = try TempTree(self)
        try tree.folder("a")
        try tree.folder("b")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let a = try XCTUnwrap(m.entries.first { $0.name == "a" })

        XCTAssertThrowsError(try m.renameFolder(a, to: "   ")) { XCTAssertEqual($0 as? RenameError, .emptyName) }
        XCTAssertThrowsError(try m.renameFolder(a, to: "x/y")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        XCTAssertThrowsError(try m.renameFolder(a, to: "x:y")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        XCTAssertThrowsError(try m.renameFolder(a, to: "..")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        XCTAssertThrowsError(try m.renameFolder(a, to: "b")) { XCTAssertEqual($0 as? RenameError, .alreadyExists("b")) }
        XCTAssertTrue(spy.moved.isEmpty, "nothing touched the disk")

        XCTAssertEqual(try m.renameFolder(a, to: "a"), a.url, "same name is a no-op")
        XCTAssertTrue(spy.moved.isEmpty)
    }

    func testCaseOnlyRenameIsAllowed() async throws {
        let tree = try TempTree(self)
        try tree.folder("photos")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let entry = try XCTUnwrap(m.entries.first { $0.name == "photos" })
        try m.renameFolder(entry, to: "Photos")
        XCTAssertEqual(spy.moved.count, 1)
        XCTAssertEqual(m.names, ["..", "Photos"])
    }

    func testRenameFailureIsReported() async throws {
        let tree = try TempTree(self)
        try tree.folder("a")
        let spy = FileActionsSpy()
        spy.moveError = CocoaError(.fileWriteNoPermission)
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let a = try XCTUnwrap(m.entries.first { $0.name == "a" })
        XCTAssertThrowsError(try m.renameFolder(a, to: "b")) { error in
            guard case .failed? = error as? RenameError else { return XCTFail("expected .failed") }
        }
        XCTAssertEqual(m.names, ["..", "a"])
    }

    func testRenameOnlyForFoldersInGrid() async throws {
        let tree = try TempTree(self)
        try tree.folder("dir")
        try tree.file("a.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)

        m.selectEntry(named: "a.jpg")
        XCTAssertFalse(m.handleKey(.f2, command: false))
        m.select(0)   // ".."
        XCTAssertFalse(m.beginRename())
        m.selectEntry(named: "dir")
        m.mode = .detail
        XCTAssertFalse(m.beginRename())
        m.mode = .grid
        XCTAssertTrue(m.handleKey(.f2, command: false))
        XCTAssertEqual(m.renameTarget?.name, "dir")
    }

    func testRenameRewritesHistoryIntoTheFolder() async throws {
        let tree = try TempTree(self)
        let inner = try tree.folder("old/inner")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, inner)
        await openAndWait(m, tree.root)          // back stack: old/inner
        m.selectEntry(named: "old")
        let entry = try XCTUnwrap(m.selectedEntry)
        try m.renameFolder(entry, to: "new")

        m.navigateBack()
        await waitUntil { !m.isLoading && m.folderURL?.lastPathComponent == "inner" }
        XCTAssertEqual(m.folderURL?.deletingLastPathComponent().lastPathComponent, "new")
    }

    func testRenameASearchResult() async throws {
        let tree = try TempTree(self)
        try tree.folder("deep/Target")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        await searchAndWait(m, "target")
        let entry = try XCTUnwrap(m.selectedEntry)
        try m.renameFolder(entry, to: "Target 2")
        XCTAssertEqual(m.names, ["Target 2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("deep/Target 2").path))
    }
}

// MARK: - Rename while searching / with history

@MainActor
final class RenameSearchStabilityTests: XCTestCase {
    /// archive/trip-2024/trip-beach.jpg + archive/trip-2024/sub, searched for "trip".
    private func searchTrip() async throws -> (TempTree, BrowserModel) {
        let tree = try TempTree(self)
        try tree.file("archive/trip-2024/trip-beach.jpg")
        try tree.folder("archive/trip-2024/sub")
        try tree.file("other.jpg")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        await searchAndWait(m, "trip")
        XCTAssertEqual(m.names, ["trip-2024", "trip-beach.jpg"])
        return (tree, m)
    }

    func testRenameInResultsKeepsFolderQueryAndResults() async throws {
        let (tree, m) = try await searchTrip()
        m.selectEntry(named: "trip-2024")
        try m.renameFolder(try XCTUnwrap(m.selectedEntry), to: "Holiday")

        XCTAssertTrue(m.isAt(tree.root), "still in the same folder")
        XCTAssertEqual(m.mode, .grid)
        XCTAssertEqual(m.searchText, "trip", "query unchanged")
        XCTAssertEqual(m.names, ["Holiday", "trip-beach.jpg"], "renamed folder stays although it no longer matches")
        XCTAssertEqual(m.selectedEntry?.name, "Holiday")
        let beach = try XCTUnwrap(m.entries.first { $0.name == "trip-beach.jpg" })
        XCTAssertEqual(m.relativeLocation(of: beach), "archive/Holiday", "results inside get the new path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: beach.url.path))
    }

    func testBackToSearchShowsRememberedResultsWithRename() async throws {
        let (tree, m) = try await searchTrip()
        m.selectEntry(named: "trip-2024")
        try m.renameFolder(try XCTUnwrap(m.selectedEntry), to: "Holiday")

        m.activateSelection()   // enter the renamed folder
        await waitUntil { m.folderURL?.lastPathComponent == "Holiday" && !m.isLoading }
        XCTAssertEqual(m.names, ["..", "sub", "trip-beach.jpg"])

        m.navigateBack()
        await waitUntil { m.isAt(tree.root) && !m.entries.isEmpty }
        XCTAssertEqual(m.searchText, "trip")
        XCTAssertEqual(m.names, ["Holiday", "trip-beach.jpg"], "stable: not searched again")
        XCTAssertEqual(m.selectedEntry?.name, "Holiday")

        m.navigateForward()
        await waitUntil { m.folderURL?.lastPathComponent == "Holiday" && !m.isLoading }
    }

    func testRenameInsideAResultFolderThenBack() async throws {
        let (tree, m) = try await searchTrip()
        m.selectEntry(named: "trip-2024")
        m.activateSelection()
        await waitUntil { m.folderURL?.lastPathComponent == "trip-2024" && !m.isLoading }
        let inside = try XCTUnwrap(m.folderURL)

        m.selectEntry(named: "sub")
        try m.renameFolder(try XCTUnwrap(m.selectedEntry), to: "sub2")
        XCTAssertTrue(m.isAt(inside), "still in the result folder")
        XCTAssertEqual(m.names, ["..", "sub2", "trip-beach.jpg"])
        XCTAssertEqual(m.selectedEntry?.name, "sub2")

        m.navigateBack()
        await waitUntil { m.isAt(tree.root) && !m.entries.isEmpty }
        XCTAssertEqual(m.searchText, "trip")
        XCTAssertEqual(m.names, ["trip-2024", "trip-beach.jpg"])
        XCTAssertEqual(m.selectedEntry?.name, "trip-2024")
    }

    func testRenameThenBackFromResultsFolderListRestoresRename() async throws {
        // Rename a result after coming back to it, then go forward again.
        let (_, m) = try await searchTrip()
        m.selectEntry(named: "trip-2024")
        m.activateSelection()
        await waitUntil { m.folderURL?.lastPathComponent == "trip-2024" && !m.isLoading }
        m.navigateBack()
        await waitUntil { m.searchText == "trip" && !m.isLoading && !m.entries.isEmpty }

        m.selectEntry(named: "trip-2024")
        try m.renameFolder(try XCTUnwrap(m.selectedEntry), to: "Renamed")
        m.navigateForward()
        await waitUntil { m.folderURL?.lastPathComponent == "Renamed" && !m.isLoading }
        XCTAssertEqual(m.names, ["..", "sub", "trip-beach.jpg"])
    }

    func testEditingTheQueryAfterRestoreSearchesAgain() async throws {
        let (tree, m) = try await searchTrip()
        m.selectEntry(named: "trip-2024")
        try m.renameFolder(try XCTUnwrap(m.selectedEntry), to: "Holiday")
        await searchAndWait(m, "holi")
        XCTAssertEqual(m.names, ["Holiday"], "a new query searches the disk")
        XCTAssertTrue(m.isAt(tree.root))
    }

    func testRebasedPaths() {
        let old = URL(fileURLWithPath: "/a/old")
        let new = URL(fileURLWithPath: "/a/new")
        XCTAssertEqual(BrowserModel.rebased(URL(fileURLWithPath: "/a/old"), from: old, to: new).path, "/a/new")
        XCTAssertEqual(BrowserModel.rebased(URL(fileURLWithPath: "/a/old/x/y.jpg"), from: old, to: new).path, "/a/new/x/y.jpg")
        XCTAssertEqual(BrowserModel.rebased(URL(fileURLWithPath: "/a/older/y.jpg"), from: old, to: new).path, "/a/older/y.jpg")
    }
}

// MARK: - File actions

@MainActor
final class FileActionTests: XCTestCase {
    func testRevealAndOpenUseTheSelectedItemButNotParent() async throws {
        let tree = try TempTree(self)
        let a = try tree.file("a.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)

        m.select(0)   // ".."
        m.revealInFinder()
        m.openInDefaultApp()
        XCTAssertTrue(spy.revealed.isEmpty)
        XCTAssertTrue(spy.opened.isEmpty)

        m.selectEntry(named: "a.jpg")
        m.revealInFinder()
        m.openInDefaultApp()
        XCTAssertEqual(spy.revealed.map(\.lastPathComponent), [a.lastPathComponent])
        XCTAssertEqual(spy.opened.map(\.lastPathComponent), [a.lastPathComponent])
    }

    func testTrashRemovesItemAndItStaysGoneAfterSearch() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        await searchAndWait(m, "b")
        m.moveSelectionToTrash()
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertTrue(m.entries.isEmpty)

        await searchAndWait(m, "")
        XCTAssertEqual(m.names, ["..", "a.jpg"], "trashed file doesn't come back")
    }

    func testTrashCancelledKeepsFile() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let spy = FileActionsSpy()
        spy.confirm = false
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        m.moveSelectionToTrash()
        XCTAssertTrue(spy.trashed.isEmpty)
        XCTAssertEqual(m.names, ["..", "a.jpg"])
    }

    func testTrashLastMediaInFullViewReturnsToGrid() async throws {
        let tree = try TempTree(self)
        try tree.folder("sub")
        try tree.file("a.jpg")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        m.activateSelection()
        m.moveSelectionToTrash()
        XCTAssertEqual(m.mode, .grid)
        XCTAssertEqual(m.names, ["..", "sub"])
    }
}

// MARK: - Slideshow & video

@MainActor
final class PlaybackTests: XCTestCase {
    func testSlideshowAdvancesWrapsAndStops() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        XCTAssertFalse(m.handleKey(.char("s"), command: false), "slideshow is full-view only")
        m.activateSelection()

        XCTAssertTrue(m.handleKey(.char("s"), command: false))
        XCTAssertTrue(m.slideshowOn)
        await waitUntil { m.selectedEntry?.name == "b.jpg" }
        await waitUntil { m.selectedEntry?.name == "a.jpg" }   // wraps around
        m.closeDetail()
        XCTAssertFalse(m.slideshowOn)
    }

    func testSpaceTogglesVideoAndCommandArrowsSeek() async throws {
        let tree = try TempTree(self)
        try tree.file("clip.mp4")
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "clip.mp4")
        m.activateSelection()
        let player = PlayerSpy()
        m.activePlayer = player
        XCTAssertFalse(m.videoPaused)

        m.handleKey(.space, command: false)
        XCTAssertTrue(m.videoPaused)
        m.handleKey(.space, command: false)
        XCTAssertFalse(m.videoPaused)
        m.handleKey(.right, command: true)
        m.handleKey(.left, command: true)
        XCTAssertEqual(player.calls, ["pause", "play", "seek 10", "seek -10"])
        XCTAssertEqual(m.mode, .detail, "seeking doesn't page")
    }

    func testNewPlayerStartsUnpaused() {
        let m = makeModel()
        let first = PlayerSpy()
        m.activePlayer = first
        m.togglePlayPause()
        XCTAssertTrue(m.videoPaused)
        let second = PlayerSpy()
        m.activePlayer = second
        XCTAssertFalse(m.videoPaused)
    }

    func testSpaceOnImageAdvances() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        m.handleKey(.space, command: false)   // grid: opens
        XCTAssertEqual(m.mode, .detail)
        m.handleKey(.space, command: false)   // full view: next
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")
    }
}

// MARK: - Key bindings (handleKey)

@MainActor
final class KeyBindingTests: XCTestCase {
    func testBackspaceGoesBackFromDetail() {
        let m = makeModel(); m.mode = .detail
        XCTAssertTrue(m.handleKey(.backspace, command: false))
        XCTAssertEqual(m.mode, .grid)
    }

    func testEscapeInDetail() {
        let m = makeModel(); m.mode = .detail
        XCTAssertTrue(m.handleKey(.escape, command: false))
        XCTAssertEqual(m.mode, .grid)
    }

    func testCommandBackspaceAndCommandReturnReachTheMenu() {
        let m = makeModel()
        XCTAssertFalse(m.handleKey(.backspace, command: true), "⌘⌫ = Move to Trash")
        XCTAssertFalse(m.handleKey(.enter, command: true), "⌘↩ = Open with Default App")
        m.mode = .detail
        XCTAssertFalse(m.handleKey(.backspace, command: true))
        XCTAssertEqual(m.mode, .detail)
    }

    func testZoomAndFitKeysInDetail() {
        let m = makeModel(); m.mode = .detail
        XCTAssertTrue(m.handleKey(.char("+"), command: false))
        XCTAssertGreaterThan(m.zoom, 1)
        XCTAssertTrue(m.handleKey(.char("-"), command: false))
        XCTAssertEqual(m.zoom, 1, accuracy: 0.0001)
        m.zoomIn()
        XCTAssertTrue(m.handleKey(.char("0"), command: false))
        XCTAssertEqual(m.zoom, 1, accuracy: 0.0001)
        m.actualSizeFactor = 3
        XCTAssertTrue(m.handleKey(.char("1"), command: false))
        XCTAssertEqual(m.zoom, 3, accuracy: 0.0001)
    }

    func testRotateKeysInDetailOnlyWithoutCommand() {
        let m = makeModel(); m.mode = .detail
        XCTAssertTrue(m.handleKey(.char("]"), command: false))
        XCTAssertEqual(m.rotation, 90)
        XCTAssertTrue(m.handleKey(.char("["), command: false))
        XCTAssertEqual(m.rotation, 0)
        m.handleKey(.char("["), command: true)   // ⌘[ = Back, not rotate
        XCTAssertEqual(m.rotation, 0)
    }

    func testCommandFFocusesSearchInAnyMode() {
        let m = makeModel()
        XCTAssertTrue(m.handleKey(.char("f"), command: true))
        XCTAssertTrue(m.searchFocused)
        let d = makeModel(); d.mode = .detail
        XCTAssertTrue(d.handleKey(.char("f"), command: true))
        XCTAssertTrue(d.searchFocused)
    }

    func testInspectorToggleIsDetailOnly() {
        let m = makeModel()
        XCTAssertFalse(m.handleKey(.char("i"), command: false))
        m.mode = .detail
        XCTAssertTrue(m.handleKey(.char("i"), command: false))
        XCTAssertTrue(m.showInspector)
        XCTAssertTrue(m.handleKey(.char("i"), command: false))
        XCTAssertFalse(m.showInspector)
    }

    func testUppercaseCharsStillMatch() {
        let m = makeModel(); m.mode = .detail
        XCTAssertTrue(m.handleKey(.char("I"), command: false))
        XCTAssertTrue(m.showInspector)
    }

    func testF1TogglesHelp() {
        let m = makeModel()
        XCTAssertTrue(m.handleKey(.f1, command: false))
        XCTAssertTrue(m.showHelp)
        XCTAssertTrue(m.handleKey(.f1, command: false))
        XCTAssertFalse(m.showHelp)
    }

    func testHomeEndOnlyInGrid() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertTrue(m.handleKey(.end, command: false))
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")
        XCTAssertTrue(m.handleKey(.home, command: false))
        XCTAssertEqual(m.selection, 0)
        m.mode = .detail
        XCTAssertFalse(m.handleKey(.home, command: false))
        XCTAssertFalse(m.handleKey(.end, command: false))
    }

    func testArrowsMoveByItemAndRow() async throws {
        let tree = try TempTree(self)
        for i in 0..<8 { try tree.file("p\(i).jpg") }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.columnCount = 3
        m.select(0)
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selection, 1)
        m.handleKey(.down, command: false)
        XCTAssertEqual(m.selection, 4)
        m.handleKey(.up, command: false)
        XCTAssertEqual(m.selection, 1)
        m.handleKey(.up, command: false)
        XCTAssertEqual(m.selection, 1, "no row above")
        m.handleKey(.left, command: false)
        m.handleKey(.left, command: false)
        XCTAssertEqual(m.selection, 0, "clamps at the start")
    }

    func testHistoryKeys() async throws {
        let tree = try TempTree(self)
        let sub = try tree.folder("sub")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await openAndWait(m, sub)
        XCTAssertTrue(m.handleKey(.char("["), command: true))
        await waitUntil { m.isAt(tree.root) }
        XCTAssertTrue(m.handleKey(.char("]"), command: true))
        await waitUntil { m.isAt(sub) }
    }

    func testUnboundKeysAreNotConsumed() {
        let m = makeModel()
        XCTAssertFalse(m.handleKey(.char("q"), command: false))
        XCTAssertFalse(m.handleKey(.char("o"), command: true), "⌘O reaches the menu")
        XCTAssertFalse(m.handleKey(.f2, command: false), "F2 without a folder selected")
    }

    func testHardwareKeyCodeMapping() {
        let cases: [(UInt16, BrowserModel.KeyInput)] = [
            (51, .backspace), (53, .escape), (36, .enter), (76, .enter), (49, .space),
            (123, .left), (124, .right), (125, .down), (126, .up),
            (115, .home), (119, .end), (122, .f1), (120, .f2),
        ]
        for (code, key) in cases {
            XCTAssertEqual(ContentView.keyInput(code: code, characters: ""), key, "keyCode \(code)")
        }
        XCTAssertEqual(ContentView.keyInput(code: 0, characters: "a"), .char("a"))
        XCTAssertNil(ContentView.keyInput(code: 0, characters: ""))
    }
}

// MARK: - Paths

final class PathTests: XCTestCase {
    func testCanonicalPathFoldsPrivateAliases() {
        XCTAssertEqual(BrowserModel.canonicalPath(URL(fileURLWithPath: "/private/var/x/gone")), "/var/x/gone")
        XCTAssertEqual(BrowserModel.canonicalPath(URL(fileURLWithPath: "/private/tmp")), "/tmp")
        XCTAssertEqual(BrowserModel.canonicalPath(URL(fileURLWithPath: "/privateer/x")), "/privateer/x")
        XCTAssertTrue(BrowserModel.samePath(URL(fileURLWithPath: "/a/b/"), URL(fileURLWithPath: "/a/b")))
    }

    func testParentFolder() {
        XCTAssertNil(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/")))
        XCTAssertEqual(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/a/b/"))?.path, "/a")
        XCTAssertEqual(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/a"))?.path, "/")
    }
}
