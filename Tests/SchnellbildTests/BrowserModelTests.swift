import XCTest
import ImageIO
import CoreImage
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
    var trashError: Error?
    var reported: [Error] = []
    /// Forces the "target exists" answer, e.g. to act as a case-sensitive volume.
    var conflictOverride: Bool?

    var actions: FileActions {
        FileActions(
            reveal: { self.revealed.append($0) },
            openInDefaultApp: { self.opened.append($0) },
            confirmTrash: { _ in self.confirm },
            trash: { url in
                if let error = self.trashError { throw error }
                self.trashed.append(url)
                try FileManager.default.removeItem(at: url)
            },
            move: { from, to in
                if let error = self.moveError { throw error }
                self.moved.append((from, to))
                try FileActions.live.move(from, to)
            },
            conflicts: { target, source in
                self.conflictOverride ?? FileActions.live.conflicts(target, source)
            },
            report: { self.reported.append($0) }
        )
    }
}

@MainActor
final class PlayerSpy: PlaybackControl {
    var calls: [String] = []
    var isPlaying = true   // videos autoplay
    var progress: Double? = 0
    func play()  { calls.append("play"); isPlaying = true }
    func pause() { calls.append("pause"); isPlaying = false }
    func seek(toProgress progress: Double) {
        calls.append("seek \(Int((progress * 100).rounded())) %")
        self.progress = progress
    }
    var enhancement = Enhancement.off
    var enhanced: Bool { enhancement == .auto }
    func setEnhancement(_ enhancement: Enhancement) { self.enhancement = enhancement }
}

func makeTestDefaults() -> UserDefaults {
    UserDefaults(suiteName: "sb.tests.\(UUID().uuidString)")!
}

@MainActor
func makeModel(_ spy: FileActionsSpy? = nil) -> BrowserModel {
    let defaults = makeTestDefaults()
    let model = BrowserModel(defaults: defaults, fileActions: spy?.actions ?? .live)
    model.searchDebounce = .zero
    model.slideshowInterval = .milliseconds(50)
    model.setFullScreen = { _ in false }
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
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .modified, ascending: true).map(\.name), ["old.jpg", "new.jpg"])
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

        m.setSort(.size)   // new key → its natural direction: largest first
        XCTAssertEqual(m.sortKey, .size)
        XCTAssertFalse(m.sortAscending)
        m.setSort(.kind)   // names and kinds start A→Z
        XCTAssertTrue(m.sortAscending)
    }

    func testSortByKindGroupsExtensionsThenNames() {
        let input = [entry("b.png", .image), entry("c.jpg", .image), entry("a.png", .image), entry("clip.mp4", .video)]
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .kind, ascending: true).map(\.name),
                       ["c.jpg", "clip.mp4", "a.png", "b.png"])
    }

    func testKindSortsFoldersByNameAndTiesStayAToZDescending() {
        let input = [entry("2024.10 Trip", .folder), entry("2024.02 Ski", .folder), entry("Archive", .folder)]
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .kind, ascending: true).map(\.name),
                       ["2024.02 Ski", "2024.10 Trip", "Archive"], "a dot in a folder name isn't a kind")
        let same = Date(timeIntervalSince1970: 7)
        let burst = [entry("IMG_0102.jpg", .image, date: same), entry("IMG_0101.jpg", .image, date: same),
                     entry("later.jpg", .image, date: Date(timeIntervalSince1970: 9))]
        XCTAssertEqual(BrowserModel.sortEntries(burst, key: .modified, ascending: false).map(\.name),
                       ["later.jpg", "IMG_0101.jpg", "IMG_0102.jpg"], "newest first, a burst still A→Z")
    }

    func testTiesFallBackToTheName() {
        let same = Date(timeIntervalSince1970: 500)
        let input = [entry("b.jpg", .image, date: same, size: 1), entry("a.jpg", .image, date: same, size: 1)]
        for key in BrowserModel.SortKey.allCases {
            XCTAssertEqual(BrowserModel.sortEntries(input, key: key, ascending: true).map(\.name), ["a.jpg", "b.jpg"], "\(key)")
        }
    }

    func testDateTakenFallsBackToDateModified() {
        let photo = entry("photo.jpg", .image, date: Date(timeIntervalSince1970: 9000))   // copied late
        let other = entry("other.jpg", .image, date: Date(timeIntervalSince1970: 5000))
        let taken = [photo.url: Date(timeIntervalSince1970: 100)]                         // but taken early
        XCTAssertEqual(BrowserModel.sortEntries([photo, other], key: .captured, ascending: true, captured: taken)
                        .map(\.name), ["photo.jpg", "other.jpg"])
        XCTAssertEqual(BrowserModel.sortEntries([photo, other], key: .modified, ascending: true)
                        .map(\.name), ["other.jpg", "photo.jpg"])
    }

    func testSortIsRemembered() {
        let defaults = makeTestDefaults()
        let first = BrowserModel(defaults: defaults)
        first.setSort(.modified)
        first.setSort(.modified)   // reversed: oldest first
        let second = BrowserModel(defaults: defaults)
        XCTAssertEqual(second.sortKey, .modified)
        XCTAssertTrue(second.sortAscending)
    }

    func testCaptureDateIsReadFromExif() async throws {
        let tree = try TempTree(self)
        let url = tree.root.appendingPathComponent("taken.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let exif = [kCGImagePropertyExifDateTimeOriginal: "2021:07:14 18:32:05"] as CFDictionary
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()),
                                   [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let date = await BrowserModel.captureDate(of: url)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(date))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2021, 7, 14, 18, 32])
        let none = await BrowserModel.captureDate(of: try tree.file("plain.jpg"))
        XCTAssertNil(none, "no EXIF, no date")
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

    /// On SMB shares and exFAT disks every photo has a "._" twin holding its
    /// extra data; the grid lists only the photo.
    @MainActor
    func testFolderListingLeavesOutDotUnderscoreFiles() async throws {
        let tree = try TempTree(self)
        try tree.file("IMG_1.jpg")
        try tree.file("._IMG_1.jpg")
        try tree.folder("Export.mov")
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, ["..", "Export.mov", "IMG_1.jpg"])
        XCTAssertEqual(m.entries.first { $0.name == "Export.mov" }?.kind, .folder)
    }

    func testContainsMediaLooksAtEveryDepthAndIgnoresJunk() async throws {
        let tree = try TempTree(self)
        try tree.file("junk/Thumbs.db")
        try tree.file("junk/desktop.ini")
        try tree.file("junk/.DS_Store")
        try tree.file("junk/.hidden.jpg")
        try tree.file("junk/inner/notes.txt")
        try tree.folder("bare")
        try tree.file("deep/a/b/c/photo.heic")
        try tree.file("flat/clip.mkv")
        try tree.file("double/._IMG_1.jpg")
        try tree.folder("named/Export.mov")
        func contains(_ name: String) async -> Bool? {
            await BrowserModel.containsMedia(tree.root.appendingPathComponent(name))
        }
        let junk = await contains("junk"), bare = await contains("bare")
        let deep = await contains("deep"), flat = await contains("flat")
        let double = await contains("double"), named = await contains("named")
        XCTAssertEqual(double, false, "macOS's '._' files are never pictures")
        XCTAssertEqual(named, false, "a folder named like a video isn't one")
        XCTAssertEqual(junk, false, "Thumbs.db, desktop.ini and hidden files don't count")
        XCTAssertEqual(bare, false)
        XCTAssertEqual(deep, true, "found at any depth")
        XCTAssertEqual(flat, true)
    }

    @MainActor
    func testEmptyFoldersAreForgottenWhenTheirContentChanges() async throws {
        let tree = try TempTree(self)
        try tree.folder("empty")
        try tree.file("photo.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let empty = try XCTUnwrap(m.entries.first { $0.name == "empty" })
        m.noteFolder(empty.url, empty: true)
        m.noteFolder(tree.root, empty: true)
        XCTAssertTrue(m.isEmptyFolder(empty))

        m.selectEntry(named: "photo.jpg")
        m.moveSelectionToTrash()   // a change in the root folder
        XCTAssertEqual(spy.trashed.count, 1)
        XCTAssertTrue(m.isEmptyFolder(empty), "a sibling stays as it was")
        XCTAssertFalse(m.emptyFolders.contains(BrowserModel.canonicalPath(tree.root)), "the parent is checked again")
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
        XCTAssertEqual(m.names, ["..", "x.jpg"])
    }

    func testLaunchArgumentOpensFolderOrFile() async throws {
        let tree = try TempTree(self)
        let file = try tree.file("a.jpg")
        let m = makeModel()
        XCTAssertFalse(m.openFromLaunchArguments(["app"]))
        XCTAssertFalse(m.openFromLaunchArguments(["app", "--open=/does/not/exist"]))
        XCTAssertTrue(m.openFromLaunchArguments(["app", "-AppleLocale", "en_US", "--open=\(file.path)"]))
        await waitUntil { m.mode == .detail }
        XCTAssertEqual(m.selectedMediaEntry?.name, "a.jpg")
    }

    func testLastFolderIsRememberedAndRestored() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let defaults = makeTestDefaults()

        let first = BrowserModel(defaults: defaults)
        await openAndWait(first, tree.root)

        let second = BrowserModel(defaults: defaults)
        second.restoreLastFolder()
        await waitUntil { second.isAt(tree.root) }
    }

    func testRestoreIgnoresMissingFolder() async throws {
        let defaults = makeTestDefaults()
        defaults.set("/does/not/exist", forKey: BrowserModel.lastFolderKey)
        let m = BrowserModel(defaults: defaults)
        m.restoreLastFolder()
        try await Task.sleep(for: .milliseconds(300))   // checked in the background
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
        let new = try m.rename(entry, to: "  Zebra  ")

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

        XCTAssertThrowsError(try m.rename(a, to: "   ")) { XCTAssertEqual($0 as? RenameError, .emptyName) }
        XCTAssertThrowsError(try m.rename(a, to: "x/y")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        XCTAssertThrowsError(try m.rename(a, to: "x:y")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        XCTAssertThrowsError(try m.rename(a, to: "..")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        XCTAssertThrowsError(try m.rename(a, to: "b")) { XCTAssertEqual($0 as? RenameError, .alreadyExists("b")) }
        XCTAssertTrue(spy.moved.isEmpty, "nothing touched the disk")

        XCTAssertEqual(try m.rename(a, to: "a"), a.url, "same name is a no-op")
        XCTAssertTrue(spy.moved.isEmpty)
    }

    func testCaseOnlyRenameIsAllowed() async throws {
        let tree = try TempTree(self)
        try tree.folder("photos")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let entry = try XCTUnwrap(m.entries.first { $0.name == "photos" })
        try m.rename(entry, to: "Photos")
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
        XCTAssertThrowsError(try m.rename(a, to: "b")) { error in
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

        m.select(0)   // ".."
        XCTAssertFalse(m.beginRename())
        m.selectEntry(named: "dir")
        XCTAssertTrue(m.handleKey(.f2, command: false))
        XCTAssertEqual(m.renameTarget?.name, "dir")
        m.renameTarget = nil
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.handleKey(.f2, command: false), "files too")
        XCTAssertEqual(m.renameTarget?.name, "a.jpg")
        m.renameTarget = nil
        m.activateSelection()   // full view
        XCTAssertTrue(m.handleKey(.f2, command: false), "also in the full view")
    }

    func testRenameAFileInTheFullViewStaysOnIt() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.mp4"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "b.jpg")
        m.activateSelection()
        let entry = try XCTUnwrap(m.selectedEntry)

        XCTAssertThrowsError(try m.rename(entry, to: "b.txt")) {
            XCTAssertEqual($0 as? RenameError, .changesKind("jpg"))
        }
        XCTAssertThrowsError(try m.rename(entry, to: "a.jpg")) {
            XCTAssertEqual($0 as? RenameError, .alreadyExists("a.jpg"))
        }
        let new = try m.rename(entry, to: "Beach.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
        XCTAssertEqual(m.mode, .detail, "the full view stays open")
        XCTAssertEqual(m.selectedEntry?.name, "Beach.jpg")
        XCTAssertEqual(m.names, ["..", "a.jpg", "Beach.jpg", "c.mp4"])
    }

    func testRenameRewritesHistoryIntoTheFolder() async throws {
        let tree = try TempTree(self)
        let inner = try tree.folder("old/inner")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, inner)
        await openAndWait(m, tree.root)          // back stack: old/inner
        m.selectEntry(named: "old")
        let entry = try XCTUnwrap(m.selectedEntry)
        try m.rename(entry, to: "new")

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
        try m.rename(entry, to: "Target 2")
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
        try m.rename(try XCTUnwrap(m.selectedEntry), to: "Holiday")

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
        try m.rename(try XCTUnwrap(m.selectedEntry), to: "Holiday")

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
        try m.rename(try XCTUnwrap(m.selectedEntry), to: "sub2")
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
        try m.rename(try XCTUnwrap(m.selectedEntry), to: "Renamed")
        m.navigateForward()
        await waitUntil { m.folderURL?.lastPathComponent == "Renamed" && !m.isLoading }
        XCTAssertEqual(m.names, ["..", "sub", "trip-beach.jpg"])
    }

    func testEditingTheQueryAfterRestoreSearchesAgain() async throws {
        let (tree, m) = try await searchTrip()
        m.selectEntry(named: "trip-2024")
        try m.rename(try XCTUnwrap(m.selectedEntry), to: "Holiday")
        await searchAndWait(m, "holi")
        XCTAssertEqual(m.names, ["Holiday"], "a new query searches the disk")
        XCTAssertTrue(m.isAt(tree.root))
    }

    func testFileChangeAppliesToPathsInside() {
        let moved = FileChange.moved(URL(fileURLWithPath: "/a/old"), to: URL(fileURLWithPath: "/a/new"))
        XCTAssertEqual(moved.apply(to: URL(fileURLWithPath: "/a/old"))?.path, "/a/new")
        XCTAssertEqual(moved.apply(to: URL(fileURLWithPath: "/a/old/x/y.jpg"))?.path, "/a/new/x/y.jpg")
        XCTAssertEqual(moved.apply(to: URL(fileURLWithPath: "/a/older/y.jpg"))?.path, "/a/older/y.jpg")
        let removed = FileChange.removed(URL(fileURLWithPath: "/a/old"))
        XCTAssertNil(removed.apply(to: URL(fileURLWithPath: "/a/old/x.jpg")))
        XCTAssertEqual(removed.apply(to: URL(fileURLWithPath: "/a/older"))?.path, "/a/older")
        XCTAssertTrue(BrowserModel.isSameOrInside("/a", "/"))
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

    /// A share without a Trash: the reason is shown, the file stays listed.
    func testFailedTrashTellsWhy() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let spy = FileActionsSpy()
        spy.trashError = CocoaError(.featureUnsupported)
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        m.moveSelectionToTrash()
        XCTAssertEqual(spy.reported.count, 1, "the reason is shown")
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
    func testSlideshowWalksFolderByFolderInSortOrder() async throws {
        let tree = try TempTree(self)
        for n in ["b.jpg", "a.mp4", "sub1/c.jpg", "sub1/deeper/d.jpg", "sub2/e.jpg", ".hidden/x.jpg", "empty/Thumbs.db"] {
            try tree.file(n)
        }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.slideshowInterval = .seconds(60)
        XCTAssertTrue(m.handleKey(.char("s"), command: false), "s starts it from the grid")
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.slideshow?.items.map(\.name), ["a.mp4", "b.jpg", "c.jpg", "d.jpg", "e.jpg"],
                       "the folder's own media first, then each subfolder, depth first")
        XCTAssertEqual(m.shownMediaEntry?.name, "a.mp4")
        XCTAssertTrue(m.handleKey(.escape, command: false))
        XCTAssertNil(m.slideshow)
        XCTAssertEqual(m.mode, .grid)
    }

    func testSlideshowOverResultsPlaysEachItemOnceAndStartsAtTheShownOne() async throws {
        let tree = try TempTree(self)
        for n in ["beach/a.jpg", "beach/beach-2024/b.jpg", "beach/beach1.jpg", "beach2.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        m.searchText = "beach"
        await waitUntil { !m.isSearching }
        m.selectEntry(named: "beach2.jpg")   // a file result, after the folder results
        m.activateSelection()
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        let names = m.slideshow?.items.map(\.name) ?? []
        XCTAssertEqual(names.sorted(), ["a.jpg", "b.jpg", "beach1.jpg", "beach2.jpg"], "each once: \(names)")
        XCTAssertEqual(m.shownMediaEntry?.name, "beach2.jpg", "starts at the item the full view showed")
    }

    func testSlideshowKeepsSearchHistoryAndFileActionsAway() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertTrue(m.handleKey(.char("f"), command: true), "⌘F is swallowed")
        XCTAssertFalse(m.searchFocused)
        m.moveSelectionToTrash()
        XCTAssertTrue(spy.trashed.isEmpty, "the hidden grid's selection isn't trashed")
        XCTAssertFalse(m.beginRename())
        XCTAssertTrue(m.handleKey(.char("S"), command: false), "S with Shift or Caps Lock")
        XCTAssertNil(m.slideshow, "ends it, doesn't restart it")
    }

    func testSlideshowShowsPicturesForTheIntervalAndVideosToTheirEnd() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.mp4", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.shownMediaEntry?.name == "b.mp4" }   // a.jpg moved on by itself
        let player = PlayerSpy()
        m.activePlayer = player
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(m.shownMediaEntry?.name, "b.mp4", "a video isn't cut off")
        player.progress = 1
        player.isPlaying = false
        m.playbackStateChanged(player, isPlaying: false)   // it ended
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg")
        await waitUntil { m.shownMediaEntry?.name == "a.jpg" }    // starts over
        if let s = m.slideshow, m.shownMediaEntry?.name != "a.jpg" {
            print("slideshow: at \(s.index) of \(s.items.map(\.name)), loading \(s.loading), waiting for more \(s.waitingForMore), paused \(s.paused)")
        }
    }

    /// A video nothing can play (it never gets a length) is skipped instead
    /// of halting the show.
    func testSlideshowSkipsAVideoThatNeverPlays() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.mkv", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowVideoCheck = .milliseconds(30)
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.shownMediaEntry?.name == "b.mkv" }
        let broken = PlayerSpy()
        broken.progress = nil   // never opens
        m.activePlayer = broken
        await waitUntil { m.shownMediaEntry?.name == "c.jpg" }
    }

    func testSlideshowOfAFolderWithoutMediaDoesNotStart() async throws {
        let tree = try TempTree(self)
        try tree.file("notes.txt")
        try tree.folder("empty")
        let m = makeModel()
        var fullScreen: [Bool] = []
        m.setFullScreen = { fullScreen.append($0); return true }
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.slideshow == nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(m.slideshow, "nothing to show: no black full screen")
        XCTAssertEqual(fullScreen.last ?? false, false, "and not left in full screen")
    }

    func testSlideshowBackFromTheFirstGoesToTheLast() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false && m.shownMediaEntry?.name == "a.jpg" }
        m.slideshowStep(-1)
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg")
        m.slideshowStep(1)
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg", "and on past the end to the first")
    }

    func testASlideshowOfOneVideoPlaysItAgain() async throws {
        let tree = try TempTree(self)
        try tree.file("only.mp4")
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.shownMediaEntry?.name == "only.mp4" && m.slideshow?.loading == false }
        let player = PlayerSpy()
        m.activePlayer = player
        player.progress = 1
        player.isPlaying = false
        m.playbackStateChanged(player, isPlaying: false)   // it ended
        XCTAssertEqual(m.shownMediaEntry?.name, "only.mp4")
        XCTAssertEqual(player.calls.last, "play", "plays again instead of standing still")
    }

    func testSlideshowKeys() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.slideshowInterval = .milliseconds(80)
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        m.handleKey(.space, command: false)
        XCTAssertEqual(m.slideshow?.paused, true)
        let shown = m.shownMediaEntry?.name
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(m.shownMediaEntry?.name, shown, "paused")
        m.handleKey(.right, command: false)
        XCTAssertNotEqual(m.shownMediaEntry?.name, shown, "→ still pages")
        XCTAssertFalse(m.handleKey(.f2, command: false), "no rename during the slideshow")
        XCTAssertNil(m.renameTarget)
        m.handleKey(.char("s"), command: false)
        XCTAssertNil(m.slideshow, "s ends it")
    }

    func testSlideshowStartsAtTheItemShownAndOverSearchResultsOrOneFolder() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg", "trip/x.jpg", "trip/y.jpg", "other/z.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)

        m.selectEntry(named: "b.jpg")
        m.activateSelection()
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg", "from the full view: at the item shown")
        m.stopSlideshow()
        m.closeDetail()

        m.selectEntry(named: "trip")
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.slideshow?.items.count, 6, "▶︎ plays the folder, not the selected tile")
        m.stopSlideshow()
        m.startSlideshow(over: tree.root.appendingPathComponent("trip"))   // the tile's context menu
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.slideshow?.items.map(\.name), ["x.jpg", "y.jpg"], "one folder from its tile")
        m.stopSlideshow()

        m.searchText = "z"
        await waitUntil { !m.isSearching && m.names == ["z.jpg"] }
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.slideshow?.items.map(\.name), ["z.jpg"], "the search results")
    }

    func testDropOnTheSlideshowZoneStartsOneAndFullScreenFollows() async throws {
        let tree = try TempTree(self)
        for n in ["trip/a.jpg", "trip/b.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        var fullScreen: [Bool] = []
        m.setFullScreen = { on in fullScreen.append(on); return true }
        let trip = tree.root.appendingPathComponent("trip")
        m.openDropped([trip.appendingPathComponent("b.jpg")], slideshow: true)
        await waitUntil { m.slideshow?.loading == false && m.isAt(trip) }
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg", "a dropped file: its folder, from that file")
        XCTAssertEqual(fullScreen, [true])
        m.handleKey(.escape, command: false)
        XCTAssertEqual(fullScreen, [true, false], "leaves full screen it entered")
        XCTAssertTrue(m.isAt(trip), "the dropped folder's grid stays")
    }

    func testEnhanceKeyTogglesItAndThePlayersFollow() {
        let m = makeModel()
        let first = PlayerSpy()
        m.activePlayer = first
        XCTAssertTrue(m.handleKey(.char("e"), command: false))
        XCTAssertTrue(m.enhance)
        XCTAssertTrue(first.enhanced)
        let next = PlayerSpy()
        m.activePlayer = next   // paging on: stays on
        XCTAssertTrue(next.enhanced)
        m.handleKey(.char("e"), command: false)
        XCTAssertFalse(next.enhanced)
    }

    func testAutoMovesTheSlidersAndASliderByHandSwitchesAutoOff() {
        let m = makeModel()
        let player = PlayerSpy()
        m.activePlayer = player
        m.enhance = true
        let measured = Look(exposure: 0.4, contrast: 0.2, saturation: 0.1, sharpness: 0.5)
        m.autoLookMeasured(measured, from: player)
        XCTAssertEqual(m.look, measured, "the sliders show what auto sets")
        m.autoLookMeasured(.neutral, from: PlayerSpy())
        XCTAssertEqual(m.look, measured, "a player no longer on screen is ignored")

        var byHand = m.look
        byHand.exposure = 0.6
        m.adjust(byHand)
        XCTAssertFalse(m.enhance, "moving a slider switches auto off")
        XCTAssertEqual(m.look, byHand, "and carries on from auto's values")
        XCTAssertEqual(player.enhancement, .manual(byHand))
        m.autoLookMeasured(.neutral, from: player)
        XCTAssertEqual(m.look, byHand, "auto's reports no longer move the sliders")

        let next = PlayerSpy()
        m.activePlayer = next
        XCTAssertEqual(next.enhancement, .manual(byHand), "settings by hand stay while paging")

        m.resetLook()
        XCTAssertEqual(m.look, .neutral)
        XCTAssertEqual(next.enhancement, .off)
    }

    func testSwitchingAutoOffShowsTheFilesAsTheyAre() {
        let m = makeModel()
        let player = PlayerSpy()
        m.activePlayer = player
        m.adjust(Look(exposure: 0.3))
        m.handleKey(.char("e"), command: false)
        XCTAssertEqual(player.enhancement, .auto)
        m.handleKey(.char("e"), command: false)
        XCTAssertEqual(player.enhancement, .off)
        XCTAssertEqual(m.look, .neutral)
    }

    func testAKeyOpensTheAdjustments() {
        let m = makeModel()
        XCTAssertTrue(m.handleKey(.char("a"), command: false))
        XCTAssertTrue(m.showAdjustments)
    }

    func testZoomAndRotateWorkOnVideosAndInTheSlideshow() async throws {
        let (m, _) = try await openOnVideo()
        m.handleKey(.char("+"), command: false)
        XCTAssertEqual(m.zoom, 1.25, accuracy: 0.001, "videos zoom like pictures")
        m.handleKey(.char("]"), command: false)
        XCTAssertEqual(m.rotation, 90)
        m.handleKey(.char("0"), command: false)
        XCTAssertEqual(m.zoom, 1)
        m.closeDetail()
        m.slideshowInterval = .seconds(60)
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        m.handleKey(.char("+"), command: false)
        XCTAssertEqual(m.zoom, 1.25, accuracy: 0.001, "and in the slideshow")
        XCTAssertEqual(m.thumbnailSide, 150, "not the grid's tiles")
    }

    func testSpaceTogglesVideo() async throws {
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
        XCTAssertEqual(player.calls, ["pause", "play"])
    }

    /// a.jpg, clip.mp4, z.jpg — open on the video with a player at the start.
    private func openOnVideo() async throws -> (BrowserModel, PlayerSpy) {
        let tree = try TempTree(self)
        for n in ["a.jpg", "clip.mp4", "z.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "clip.mp4")
        m.activateSelection()
        let player = PlayerSpy()
        m.activePlayer = player
        return (m, player)
    }

    func testRightArrowSkimsThroughAVideoThenMovesOn() async throws {
        let (m, player) = try await openOnVideo()
        for _ in 0..<9 { m.handleKey(.right, command: false) }
        XCTAssertEqual(player.calls, (1...9).map { "seek \($0 * 10) %" })
        XCTAssertEqual(m.selectedEntry?.name, "clip.mp4", "nine tenths: still the video")
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg", "past the end: the next item")
        XCTAssertEqual(m.mode, .detail)
    }

    func testLeftArrowSkimsBackThenMovesToThePreviousItem() async throws {
        let (m, player) = try await openOnVideo()
        player.progress = 0.55
        m.handleKey(.left, command: false)
        XCTAssertEqual(player.calls, ["seek 45 %"])
        player.progress = 0.01   // at the start
        m.handleKey(.left, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "a.jpg")
    }

    func testCommandArrowsAndUpDownPageStraightAwayFromAVideo() async throws {
        let (m, player) = try await openOnVideo()
        player.progress = 0.3
        m.handleKey(.right, command: true)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg")
        m.handleKey(.left, command: true)
        m.handleKey(.left, command: true)
        XCTAssertEqual(m.selectedEntry?.name, "a.jpg")
        m.selectEntry(named: "clip.mp4")
        m.handleKey(.down, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg")
        XCTAssertEqual(player.calls, [], "no seeking")
    }

    func testArrowsPageWhileTheVideoLengthIsUnknown() async throws {
        let (m, player) = try await openOnVideo()
        player.progress = nil   // still opening, or not playable
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg")
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

    func testCommandFFocusesSearchInAnyMode() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertTrue(m.handleKey(.char("f"), command: true))
        XCTAssertTrue(m.searchFocused)
        m.searchFocused = false
        m.selectEntry(named: "a.jpg")
        m.activateSelection()
        XCTAssertTrue(m.handleKey(.char("f"), command: true))
        XCTAssertTrue(m.searchFocused)
    }

    func testCommandFWithoutFolderLeavesNoPendingFocus() {
        let m = makeModel()
        XCTAssertTrue(m.handleKey(.char("f"), command: true))
        XCTAssertFalse(m.searchFocused, "the disabled field must not grab focus later")
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

// MARK: - Review fixes: search stays consistent with renames and trash

@MainActor
final class SearchConsistencyTests: XCTestCase {
    /// Root with photos/beach.jpg and photos/sub, searched for "photos" or
    /// "beach" with a debounce long enough that the walk hasn't started.
    private func model(_ tree: TempTree) async throws -> BrowserModel {
        try tree.file("photos/beach.jpg")
        try tree.file("photos-beach.jpg")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        m.searchDebounce = .seconds(60)
        return m
    }

    func testStaleBatchAfterRenameGetsTheNewPath() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchText = "photos"
        XCTAssertTrue(m.isSearching)
        XCTAssertEqual(m.names, ["photos", "photos-beach.jpg"])
        m.selectEntry(named: "photos")
        try m.rename(try XCTUnwrap(m.selectedEntry), to: "Pics")

        // The walk read "photos" before the rename and reports it now.
        let oldBeach = tree.root.appendingPathComponent("photos/beach.jpg")
        let oldFolder = tree.root.appendingPathComponent("photos", isDirectory: true)
        m.appendSearchBatch([GridEntry(url: oldFolder, kind: .folder), GridEntry(url: oldBeach, kind: .image)])

        XCTAssertEqual(m.names, ["Pics", "beach.jpg", "photos-beach.jpg"], "no old path comes back")
        let beach = try XCTUnwrap(m.entries.first { $0.name == "beach.jpg" })
        XCTAssertEqual(m.relativeLocation(of: beach), "Pics")
        XCTAssertEqual(m.selectedEntry?.name, "Pics")
    }

    func testStaleBatchAfterTrashDoesNotBringItBack() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchText = "photos"
        m.selectEntry(named: "photos")
        m.moveSelectionToTrash()
        XCTAssertEqual(m.names, ["photos-beach.jpg"])

        m.appendSearchBatch([
            GridEntry(url: tree.root.appendingPathComponent("photos", isDirectory: true), kind: .folder),
            GridEntry(url: tree.root.appendingPathComponent("photos/beach.jpg"), kind: .image),
        ])
        XCTAssertEqual(m.names, ["photos-beach.jpg"], "neither the folder nor its contents come back")
    }

    func testTrashingAFolderRemovesItsResultsToo() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchDebounce = .zero
        await searchAndWait(m, "beach")
        XCTAssertEqual(m.names, ["beach.jpg", "photos-beach.jpg"])
        await searchAndWait(m, "p")
        m.selectEntry(named: "photos")
        m.moveSelectionToTrash()
        XCTAssertFalse(m.names.contains("beach.jpg"), "contents of the trashed folder go with it")
    }

    func testRenamesDontLeakIntoLaterSearches() async throws {
        let tree = try TempTree(self)
        try tree.file("2024/a.jpg")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        m.selectEntry(named: "2024")
        try m.rename(try XCTUnwrap(m.selectedEntry), to: "2024-old")
        try tree.file("2024/b.jpg")   // a new folder with the old name

        await searchAndWait(m, "b.jpg")
        let b = try XCTUnwrap(m.entries.first)
        XCTAssertEqual(m.relativeLocation(of: b), "2024")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path))
    }

    func testAnUnfinishedSearchGoesOnWhileTheUserLooksAtAResult() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchDebounce = .milliseconds(300)
        m.searchText = "beach"
        XCTAssertTrue(m.isSearching)
        XCTAssertEqual(m.names, ["photos-beach.jpg"], "only the local match so far")
        await openAndWait(m, tree.root.appendingPathComponent("photos"))
        XCTAssertFalse(m.isSearching, "the result folder shows no search")
        try await Task.sleep(for: .seconds(1))   // the walk finishes meanwhile

        m.navigateBack()
        await waitUntil { m.isAt(tree.root) && !m.isLoading }
        XCTAssertFalse(m.isSearching, "not searched again")
        XCTAssertEqual(m.names, ["beach.jpg", "photos-beach.jpg"], "with what it found in the background")
    }

    func testComingBackToASearchStillRunningShowsItRunning() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)   // a long debounce: the walk is still waiting
        m.searchText = "beach"
        await openAndWait(m, tree.root.appendingPathComponent("photos"))
        m.navigateBack()
        await waitUntil { m.isAt(tree.root) && !m.isLoading }
        XCTAssertTrue(m.isSearching, "the same search, still running")
        m.appendSearchBatch([GridEntry(url: tree.root.appendingPathComponent("photos/beach.jpg"), kind: .image)])
        XCTAssertEqual(m.names, ["beach.jpg", "photos-beach.jpg"], "its batches still arrive")
    }

    func testStoppedSearchKeepsItsResultsAlsoAfterGoingBack() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchText = "beach"
        XCTAssertTrue(m.isSearching)
        m.stopSearch()
        XCTAssertFalse(m.isSearching)
        XCTAssertEqual(m.names, ["photos-beach.jpg"], "what it had found stays")
        await openAndWait(m, tree.root.appendingPathComponent("photos"))
        m.searchDebounce = .zero
        m.navigateBack()
        await waitUntil { m.isAt(tree.root) && !m.isLoading }
        XCTAssertFalse(m.isSearching, "not started again")
        XCTAssertEqual(m.names, ["photos-beach.jpg"])
    }

    func testASearchDroppedFromTheHistoryStops() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)   // a long debounce: the walk stays unfinished
        let photos = tree.root.appendingPathComponent("photos")
        await openAndWait(m, photos)
        await openAndWait(m, tree.root)
        m.searchText = "beach"
        m.navigateBack()   // the running search goes to the forward history
        await waitUntil { m.isAt(photos) && !m.isLoading }
        let run = try XCTUnwrap(m.forwardStack.last?.search)
        XCTAssertFalse(run.finished, "kept running while it can be come back to")
        await openAndWait(m, tree.root)   // a new path: the forward history goes
        XCTAssertTrue(run.finished, "nothing can come back to it, so it stops")
    }

    func testOnlyTheNewestSearchesKeepRunningInTheHistory() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)   // long debounce: every walk stays unfinished
        let photos = tree.root.appendingPathComponent("photos")
        for query in ["b", "be", "bea", "beac", "beach"] {
            m.searchText = query
            await openAndWait(m, photos)
            await openAndWait(m, tree.root)
        }
        m.searchDebounce = .zero
        // Back to the oldest one ("b"), stopped meanwhile: searched again
        for _ in 0..<10 { m.navigateBack(); await waitUntil { !m.isLoading } }
        XCTAssertEqual(m.searchText, "b")
        await waitUntil { !m.isSearching }
        XCTAssertTrue(m.names.contains("beach.jpg"), "searched afresh and finished: \(m.names)")
    }

    func testBackFromTheFullViewReturnsToTheResults() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchDebounce = .zero
        m.searchText = "beach"
        await waitUntil { !m.isSearching }
        let results = m.names
        m.selectEntry(named: "photos-beach.jpg")
        m.activateSelection()
        XCTAssertEqual(m.mode, .detail)
        XCTAssertTrue(m.canGoBack)
        let history = m.backStack.count

        m.navigateBack()
        XCTAssertEqual(m.mode, .grid)
        XCTAssertTrue(m.isAt(tree.root))
        XCTAssertEqual(m.searchText, "beach", "the search stays")
        XCTAssertEqual(m.names, results)
        XCTAssertEqual(m.selectedEntry?.name, "photos-beach.jpg")
        XCTAssertEqual(m.backStack.count, history, "no history step used up")
    }

    func testOpeningAResultTakesTheFocusFromTheSearchField() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchDebounce = .zero
        m.searchFocused = true
        m.searchText = "beach"
        await waitUntil { !m.isSearching }
        m.selectEntry(named: "beach.jpg")
        m.activateSelection()
        XCTAssertEqual(m.mode, .detail)
        XCTAssertFalse(m.searchFocused, "the full view gets the keys")
    }

    func testTrashRemovesItFromRememberedResults() async throws {
        let tree = try TempTree(self)
        try tree.file("picdir/pic1.jpg")
        try tree.file("pic2.jpg")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        await searchAndWait(m, "pic")
        XCTAssertEqual(m.names, ["picdir", "pic1.jpg", "pic2.jpg"])
        m.selectEntry(named: "picdir")
        m.activateSelection()
        await waitUntil { m.folderURL?.lastPathComponent == "picdir" && !m.isLoading }
        m.selectEntry(named: "pic1.jpg")
        m.moveSelectionToTrash()

        m.navigateBack()
        await waitUntil { m.isAt(tree.root) && !m.entries.isEmpty }
        XCTAssertEqual(m.names, ["picdir", "pic2.jpg"])
    }

    func testWhitespaceQueryDoesNotFilter() async throws {
        let tree = try TempTree(self)
        let m = try await model(tree)
        m.searchText = "   "
        XCTAssertFalse(m.isFiltering)
        XCTAssertFalse(m.isSearching)
        XCTAssertEqual(m.names, ["..", "photos", "photos-beach.jpg"])
    }
}

@MainActor
final class ReviewFixTests: XCTestCase {
    func testRenameOntoAnExistingCaseVariantIsRefused() async throws {
        // A case-sensitive volume where "Photos" is a different folder.
        let tree = try TempTree(self)
        try tree.folder("photos")
        let spy = FileActionsSpy()
        spy.conflictOverride = true
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let entry = try XCTUnwrap(m.entries.first { $0.name == "photos" })
        XCTAssertThrowsError(try m.rename(entry, to: "Photos")) {
            XCTAssertEqual($0 as? RenameError, .alreadyExists("Photos"))
        }
        XCTAssertTrue(spy.moved.isEmpty)
    }

    func testLiveConflictCheckTellsSameItemFromAnother() throws {
        let tree = try TempTree(self)
        let a = try tree.folder("a")
        let b = try tree.folder("b")
        XCTAssertTrue(FileActions.live.conflicts(b, a))
        XCTAssertFalse(FileActions.live.conflicts(a, a))
        XCTAssertFalse(FileActions.live.conflicts(tree.root.appendingPathComponent("c"), a))
    }

    func testHistoryIsBounded() async throws {
        let tree = try TempTree(self)
        let a = try tree.folder("a")
        let b = try tree.folder("b")
        let m = makeModel()
        for i in 0..<(BrowserModel.historyLimit + 10) {
            await openAndWait(m, i.isMultiple(of: 2) ? a : b)
        }
        XCTAssertEqual(m.backStack.count, BrowserModel.historyLimit)
    }

    func testOverlappingLoadsOfTheSameFolderKeepTheNewest() async throws {
        let tree = try TempTree(self)
        let b = try tree.file("b.jpg")
        try tree.file("a.jpg")
        let m = makeModel()
        m.open(folder: tree.root)
        m.open(folder: tree.root, selecting: b)
        await waitUntil { m.isAt(tree.root) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")
    }

    func testMediaKindIsTheOneRule() {
        XCTAssertEqual(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/a.JPG")), .image)
        XCTAssertEqual(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/a.mkv")), .video)
        XCTAssertNil(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/a.txt")))
        XCTAssertNil(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/._a.jpg")), "macOS's '._' companion files")
    }

    func testFolderPreviewListIsCachedPerFolder() async throws {
        let tree = try TempTree(self)
        try tree.file("b.jpg")
        let cache = FolderPreviewCache()
        let first = await cache.files(in: tree.root)
        try tree.file("a.jpg")
        let second = await cache.files(in: tree.root)
        XCTAssertEqual(first.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertEqual(second, first, "listed once, not on every tile appearance")
    }

    func testTextFieldsAndSheetsKeepTheirKeysExceptF1AndF2() async throws {
        let tree = try TempTree(self)
        try tree.folder("dir")
        try tree.file("a.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "dir")

        XCTAssertFalse(m.handleKey(.right, command: false, textEditing: true), "typing in the search field")
        XCTAssertEqual(m.selectedEntry?.name, "dir")
        m.searchFocused = true
        XCTAssertTrue(m.handleKey(.f2, command: false, textEditing: true), "F2 renames while typing")
        XCTAssertFalse(m.searchFocused, "and leaves the search field")
        XCTAssertNotNil(m.renameTarget)

        XCTAssertFalse(m.handleKey(.f1, command: false), "no help on top of the rename sheet")
        XCTAssertFalse(m.showHelp)
        XCTAssertFalse(m.handleKey(.right, command: false), "the sheet keeps its keys")
        m.renameTarget = nil

        XCTAssertTrue(m.handleKey(.f1, command: false))
        XCTAssertFalse(m.handleKey(.f2, command: false), "no rename over the help sheet")
        XCTAssertFalse(m.handleKey(.right, command: false))
        XCTAssertTrue(m.handleKey(.f1, command: false), "F1 closes help again")
        XCTAssertTrue(m.handleKey(.right, command: false))
    }

    func testPlayPauseFollowsThePlayersRealState() {
        let m = makeModel()
        let player = PlayerSpy()
        m.activePlayer = player
        // Paused with the player's own controls:
        player.isPlaying = false
        m.playbackStateChanged(player, isPlaying: false)
        XCTAssertTrue(m.videoPaused)
        m.togglePlayPause()
        XCTAssertEqual(player.calls, ["play"], "one Space resumes")
        XCTAssertFalse(m.videoPaused)

        // A player that is no longer on screen is ignored.
        let old = PlayerSpy()
        m.playbackStateChanged(old, isPlaying: false)
        XCTAssertFalse(m.videoPaused)
    }
}

// MARK: - Media info

final class MediaInfoTests: XCTestCase {
    /// A photo taken upright is stored landscape with an EXIF orientation;
    /// its size is reported as shown.
    func testUprightPhotoReportsItsShownSize() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        for (orientation, expected) in [(1, CGSize(width: 40, height: 30)), (6, CGSize(width: 30, height: 40))] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
            XCTAssertEqual(MediaInfo.pixelSize(from: source), expected, "orientation \(orientation)")
        }
    }

    /// A menu opened on a tile acts on that file, even if the list moved
    /// under it meanwhile (results streaming in, a new sort order).
    @MainActor
    func testSelectingByFileFindsItWhereverItMoved() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        let b = try XCTUnwrap(m.entries.first { $0.name == "b.jpg" })
        let before = m.entries.firstIndex(of: b)
        m.setSort(.name)   // name again: reversed, so b.jpg sits elsewhere
        XCTAssertNotEqual(m.entries.firstIndex(of: b), before)
        XCTAssertTrue(m.select(b))
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")
        XCTAssertFalse(m.select(GridEntry(url: tree.root.appendingPathComponent("gone.jpg"), kind: .image)),
                       "a file no longer listed selects nothing")
    }
}

// MARK: - Auto enhance

final class EnhanceTests: XCTestCase {
    private func grey(_ value: CGFloat) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: value, green: value, blue: value * 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        ctx.setFillColor(CGColor(red: value * 2, green: value * 1.5, blue: value, alpha: 1))
        ctx.fill(CGRect(x: 16, y: 12, width: 20, height: 20))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func stats(_ image: CGImage) throws -> PictureStats {
        try XCTUnwrap(PictureStats.of(CIImage(cgImage: image)))
    }

    private func auto(_ image: CGImage) throws -> CGImage {
        try XCTUnwrap(Look.render(image, with: Look.auto(for: try stats(image))))
    }

    func testDarkPicturesGetBrighterAndKeepTheirSize() throws {
        let dark = try grey(0.08)
        XCTAssertGreaterThan(Look.auto(for: try stats(dark)).exposure, 0, "brightened")
        let result = try auto(dark)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 48)
        let before = try stats(dark).mean, after = try stats(result).mean
        XCTAssertGreaterThan(after, before * 2, "clearly brighter: \(before) → \(after)")
    }

    func testOverexposedPicturesGetDarker() throws {
        let bright = try grey(0.78)
        XCTAssertLessThan(Look.auto(for: try stats(bright)).exposure, 0, "darkened")
        let before = try stats(bright).mean, after = try stats(try auto(bright)).mean
        XCTAssertLessThan(after, before - 0.1, "clearly darker: \(before) → \(after)")
    }

    func testWellExposedPicturesKeepTheirExposure() throws {
        XCTAssertEqual(Look.auto(for: try stats(try grey(0.42))).exposure, 0)
    }

    func testExposureAndGammaPowerAreInverse() {
        for exposure in [-1.0, -0.4, 0, 0.3, 1] {
            XCTAssertEqual(Look.exposure(forGammaPower: Look(exposure: exposure).gammaPower), exposure, accuracy: 0.0001)
        }
        XCTAssertLessThan(Look(exposure: 0.5).gammaPower, 1, "positive brightens (Core Image power < 1)")
    }

    func testFlatGreyPicturesGetMoreContrastAndBlackAndWhiteStaysGrey() {
        let flat = PictureStats(mean: 0.5, low: 0.4, high: 0.6, chroma: 0.0)
        let look = Look.auto(for: flat)
        XCTAssertGreaterThan(look.contrast, 0)
        XCTAssertEqual(look.saturation, 0, "no colour to lift")
    }

    func testWashedOutColoursAreLiftedAndGarishOnesCalmed() {
        XCTAssertGreaterThan(Look.auto(for: PictureStats(mean: 0.5, low: 0.05, high: 0.95, chroma: 0.08)).saturation, 0)
        XCTAssertLessThan(Look.auto(for: PictureStats(mean: 0.5, low: 0.05, high: 0.95, chroma: 0.5)).saturation, 0)
    }

    /// A coloured gradient with a hard edge in the middle.
    private func colourful() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<64 {
            let v = 0.2 + 0.6 * CGFloat(x) / 63
            ctx.setFillColor(CGColor(red: v, green: v * 0.7, blue: v * 0.4, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 48))
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 24))
        return try XCTUnwrap(ctx.makeImage())
    }

    func testSaturationTakesAndAddsColour() throws {
        let picture = try colourful()
        let before = try stats(picture).chroma
        let grey = try stats(try XCTUnwrap(Look.render(picture, with: Look(saturation: -1)))).chroma
        let vivid = try stats(try XCTUnwrap(Look.render(picture, with: Look(saturation: 0.6)))).chroma
        XCTAssertLessThan(grey, 0.01, "−1 is black and white")
        XCTAssertGreaterThan(vivid, before * 1.2, "more is more colourful: \(before) → \(vivid)")
    }

    func testContrastSpreadsAndNarrowsTheTones() throws {
        let picture = try colourful()
        func spread(_ look: Look) throws -> Double {
            let s = try stats(try XCTUnwrap(Look.render(picture, with: look)))
            return s.high - s.low
        }
        let normal = try spread(.neutral)
        XCTAssertGreaterThan(try spread(Look(contrast: 1)), normal + 0.05)
        XCTAssertLessThan(try spread(Look(contrast: -1)), normal - 0.05)
    }

    func testSharpnessMakesTheEdgeHarder() throws {
        let picture = try colourful()
        // Around the edge between the blue half and the gradient
        func edge(_ look: Look) throws -> Double {
            let image = CIImage(cgImage: try XCTUnwrap(Look.render(picture, with: look)))
                .cropped(to: CGRect(x: 0, y: 20, width: 64, height: 8))
            var rgba = [UInt8](repeating: 0, count: 64 * 8 * 4)
            Look.context.render(image.transformed(by: CGAffineTransform(translationX: 0, y: -20)), toBitmap: &rgba,
                                rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 8),
                                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let lum = stride(from: 0, to: rgba.count, by: 4).map { Double(rgba[$0 + 1]) / 255 }
            let mean = lum.reduce(0, +) / Double(lum.count)
            return (lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lum.count)).squareRoot()
        }
        XCTAssertGreaterThan(try edge(Look(sharpness: 1)), try edge(.neutral) * 1.05, "the unsharp mask works")
    }

    func testNeutralLookLeavesThePictureAlone() throws {
        let picture = try grey(0.3)
        let result = try XCTUnwrap(Look.render(picture, with: .neutral))
        XCTAssertEqual(try stats(result).mean, try stats(picture).mean, accuracy: 0.01)
    }

    func testVideoLookHoldsOnBlackAndTakesTheFirstPictureAtOnce() {
        var adaptive = AdaptiveLook()
        adaptive.measure(PictureStats(mean: 0, low: 0, high: 0, chroma: 0), instant: false)
        XCTAssertEqual(adaptive.look, .neutral, "not lifted on a black intro")
        XCTAssertFalse(adaptive.hasPicture)
        let dark = PictureStats(mean: 0.1, low: 0.02, high: 0.3, chroma: 0.1)
        adaptive.measure(dark, instant: false)
        XCTAssertEqual(adaptive.look, Look.auto(for: dark), "the first picture at once")
        adaptive.measure(PictureStats(mean: 0.99, low: 0.98, high: 1, chroma: 0), instant: false)
        adaptive.advance(by: 5)
        XCTAssertEqual(adaptive.look, Look.auto(for: dark), "held through a white flash")
    }

    func testVideoLookGlidesBetweenMeasurementsAndJumpsAfterSeeking() {
        var adaptive = AdaptiveLook()
        let dark = PictureStats(mean: 0.1, low: 0.02, high: 0.3, chroma: 0.1)
        let lighter = PictureStats(mean: 0.25, low: 0.05, high: 0.6, chroma: 0.1)
        adaptive.measure(dark, instant: false)
        adaptive.measure(lighter, instant: false)
        XCTAssertEqual(adaptive.look, Look.auto(for: dark), "not at once")
        adaptive.advance(by: 0.1)
        XCTAssertLessThan(adaptive.look.exposure, Look.auto(for: dark).exposure)
        XCTAssertGreaterThan(adaptive.look.exposure, Look.auto(for: lighter).exposure, "on its way")
        let bright = PictureStats(mean: 0.5, low: 0.05, high: 0.95, chroma: 0.2)
        adaptive.measure(bright, instant: true)   // seeked
        XCTAssertEqual(adaptive.look, Look.auto(for: bright), "at once after seeking")
    }
}
