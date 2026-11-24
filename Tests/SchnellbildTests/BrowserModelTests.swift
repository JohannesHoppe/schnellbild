import XCTest
import Combine
import AppKit
import ImageIO
import CoreImage
import QuickLookThumbnailing
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
    /// What Copy Path put on the pasteboard.
    var copiedTexts: [String] = []
    var opened: [URL] = []
    var trashed: [URL] = []
    var moved: [(URL, URL)] = []
    var created: [URL] = []
    var copied: [(URL, URL)] = []
    var keepBoth = true
    /// Answers every taken name at once ("Apply to all"); `keepBoth` otherwise.
    var conflictAnswer: ConflictAnswer?
    var keepBothAsked = 0
    /// A failed Undo: kept to try again (true) or forgotten.
    var keepFailedUndo = true
    var confirm = true
    var confirmDetails: [String] = []
    var confirmNames: [[String]] = []
    var moveError: Error?
    /// Moves, transfers and copies of files with these names fail.
    var failOn: Set<String> = []
    var trashError: Error?
    /// The Trash takes items without saying where they lie (a volume that doesn't).
    var trashGivesNoPlace = false
    /// Runs while an item is being trashed (a second ⌘⌫ meanwhile).
    var duringTrash: (() -> Void)?
    /// Runs once an item was moved or renamed on disk, before the app
    /// applies the change (FSEvents reporting it meanwhile).
    var duringMove: (() -> Void)?
    var reported: [Error] = []
    /// Forces the "target exists" answer, e.g. to act as a case-sensitive volume.
    var conflictOverride: Bool?

    var actions: FileActions {
        FileActions(
            reveal: { self.revealed.append($0) },
            openInDefaultApp: { self.opened.append($0) },
            copyText: { self.copiedTexts.append($0) },
            confirmTrash: { names, detail in
                self.confirmNames.append(names)
                self.confirmDetails.append(detail)
                return self.confirm
            },
            trash: { url, _ in
                if let error = self.trashError { throw error }
                if let during = self.duringTrash { self.duringTrash = nil; during() }
                self.trashed.append(url)
                // A trash of its own, so Undo can bring it back
                let bin = FileManager.default.temporaryDirectory.appendingPathComponent("spy-trash-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                let inTrash = bin.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: inTrash)
                return self.trashGivesNoPlace ? nil : inTrash
            },
            move: { from, to in
                if let error = self.moveError { throw error }
                if self.failOn.contains(from.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
                self.moved.append((from, to))
                try FileActions.live.move(from, to)
                if let during = self.duringMove { self.duringMove = nil; during() }
            },
            transfer: { from, to in
                if let error = self.moveError { throw error }
                if self.failOn.contains(from.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
                self.moved.append((from, to))
                return try FileActions.live.transfer(from, to)
            },
            createFolder: { url in
                self.created.append(url)
                try FileActions.live.createFolder(url)
            },
            copy: { from, to in
                if self.failOn.contains(from.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
                self.copied.append((from, to))
                try FileActions.live.copy(from, to)
            },
            askKeepBoth: { _, _, _ in
                self.keepBothAsked += 1
                return self.conflictAnswer ?? ConflictAnswer(choice: self.keepBoth ? .keepBoth : .skip)
            },
            conflicts: { target, source in
                self.conflictOverride ?? FileActions.live.conflicts(target, source)
            },
            report: { self.reported.append($0) },
            keepFailedUndo: { error, _ in
                self.reported.append(error)
                return self.keepFailedUndo
            }
        )
    }
}

@MainActor
final class PlayerSpy: PlaybackControl {
    var calls: [String] = []
    var isPlaying = true   // videos autoplay
    var progress: Double? = 0
    var playsWithoutLength = false
    var lengthSeconds: Double?
    var playedSeconds: Double?
    /// Ended where its data ends, short of its length (a download), as VLC
    /// reports it: `progress` stands there.
    var endedShort = false
    var hasEnded: Bool { endedShort || (!isPlaying && (progress ?? 0) >= 0.99) }
    func play()  { calls.append("play"); isPlaying = true }
    func pause() { calls.append("pause"); isPlaying = false }
    func seek(toProgress progress: Double) {
        calls.append("seek \(Int((progress * 100).rounded())) %")
        self.progress = progress
    }
    var enhancement = Enhancement.off
    var enhanced: Bool { enhancement == .auto }
    func setEnhancement(_ enhancement: Enhancement) { self.enhancement = enhancement }
    var volume: Double?
    func setVolume(_ volume: Double) { self.volume = volume }
    var tracks = VideoTracks()
    var speed = 1.0
    func selectAudioTrack(_ id: Int) { calls.append("audio \(id)"); tracks.audioID = id }
    func selectSubtitleTrack(_ id: Int?) { calls.append("subtitles \(id.map(String.init) ?? "off")"); tracks.subtitleID = id }
    func setSpeed(_ speed: Double) { self.speed = speed }

    /// A video with English and German sound and subtitles, the file's
    /// defaults on (as players open it).
    static func withTracks() -> PlayerSpy {
        let player = PlayerSpy()
        player.tracks = VideoTracks(
            audio: [MediaTrack(id: 1, name: "English", language: "eng"), MediaTrack(id: 2, name: "German", language: "deu")],
            subtitles: [MediaTrack(id: 3, name: "English", language: "en"), MediaTrack(id: 4, name: "German", language: "ger")],
            audioID: 1, subtitleID: 3)
        return player
    }
}

/// A fresh preferences suite per model; every suite made is removed when the
/// test process ends, so test runs leave no files in ~/Library/Preferences.
func makeTestDefaults() -> UserDefaults {
    TestDefaults.make()
}

/// The preferences suites of the tests. Each name holds the test process's
/// id ("sb.tests.<pid>.<label>.<UUID>"): the suites are removed when the
/// process ends, and what a process that didn't end normally (killed,
/// crashed) left behind is removed by the next test process.
enum TestDefaults {
    static let prefix = "sb.tests."
    private static let lock = NSLock()
    private static var names: [String] = []

    static func make(_ label: String = "") -> UserDefaults {
        UserDefaults(suiteName: name(label))!
    }

    /// A suite's name, removed with the others (for code that opens the suite itself).
    static func name(_ label: String = "") -> String {
        let name = prefix + "\(getpid())." + (label.isEmpty ? "" : label + ".") + UUID().uuidString
        lock.lock()
        if names.isEmpty {
            removeLeftovers()
            atexit { TestDefaults.removeAll() }
        }
        names.append(name)
        lock.unlock()
        return name
    }

    private static var preferences: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
    }

    private static func file(_ name: String) -> URL { preferences.appendingPathComponent("\(name).plist") }

    /// Emptied, then their files removed. The preferences daemon writes an
    /// emptied suite's file on its own time, which may be after the file
    /// was removed (an empty suite's file comes back): removed again until
    /// none has come back for a moment.
    static func removeAll() {
        lock.lock()
        let made = names
        names = []
        lock.unlock()
        for name in made {
            UserDefaults.standard.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
        }
        let deadline = Date() + 2
        var quiet = 0
        while quiet < 3, Date() < deadline {
            var removed = false
            for name in made where (try? FileManager.default.removeItem(at: file(name))) != nil { removed = true }
            quiet = removed ? 0 : quiet + 1
            usleep(50_000)
        }
    }

    /// The files of suites whose test process has ended.
    private static func removeLeftovers() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
            guard let pid = Int32(file.dropFirst(prefix.count).prefix { $0 != "." }), pid > 0, pid != getpid(),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(file))
        }
    }
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

    /// As the list's Kind column: pictures before videos, then by extension and name.
    func testSortByKindGroupsKindsThenExtensionsThenNames() {
        let input = [entry("b.png", .image), entry("c.jpg", .image), entry("a.png", .image), entry("clip.mp4", .video)]
        XCTAssertEqual(BrowserModel.sortEntries(input, key: .kind, ascending: true).map(\.name),
                       ["c.jpg", "a.png", "b.png", "clip.mp4"])
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

    /// A folder too long to sort on the main thread: sorted off it to the
    /// same order, re-sorted keeping the selection, and a rename put in
    /// place without sorting it all again.
    func testALongFolderSortsAsAShortOne() async throws {
        let tree = try TempTree(self)
        let count = BrowserModel.mainThreadSortLimit + 1_000
        for i in 0..<count {
            XCTAssertTrue(FileManager.default.createFile(atPath: tree.root.appendingPathComponent("img\(i).jpg").path, contents: nil))
        }
        let numbered = (0..<count).map { "img\($0).jpg" }
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, [".."] + numbered, "by name, numbers as numbers")
        m.selectEntry(named: "img5.jpg")

        m.setSort(.name)   // reversed, off the main thread
        await waitUntil { m.names.dropFirst().first == numbered.last }
        XCTAssertEqual(m.names, [".."] + numbered.reversed())
        XCTAssertEqual(m.selectedEntry?.name, "img5.jpg", "the selection follows its item")

        let old = tree.root.appendingPathComponent("img5.jpg")
        let new = tree.root.appendingPathComponent("zzz.jpg")
        try FileManager.default.moveItem(at: old, to: new)
        m.apply(FileChange.moved(old, to: new))
        XCTAssertEqual(m.names[1], "zzz.jpg", "the renamed one where it sorts now")
        XCTAssertEqual(m.names, BrowserModel.sortEntries(m.entries, key: .name, ascending: false).map(\.name))
        XCTAssertEqual(m.selectedEntry?.name, "zzz.jpg")
    }

    /// Changes followed in place give the order a full sort gives.
    func testFollowingChangesKeepsTheOrder() {
        let order = BrowserModel.EntryOrder(key: .name, ascending: true, captured: [:])
        let list = order.sorted((0..<500).map { entry("p\($0).jpg", .image) } + [entry("dotdot", .parent), entry("f", .folder)])
        let changes = FileChanges([
            .moved(URL(fileURLWithPath: "/root/p7.jpg"), to: URL(fileURLWithPath: "/root/a.jpg")),
            .moved(URL(fileURLWithPath: "/root/p300.jpg"), to: URL(fileURLWithPath: "/root/zz.jpg")),
            .removed(URL(fileURLWithPath: "/root/p42.jpg"))
        ])
        let followed = order.following(list, changes)
        XCTAssertEqual(followed.map(\.name), order.sorted(followed).map(\.name))
        XCTAssertEqual(followed.count, list.count - 1)
        XCTAssertEqual(Array(followed.map(\.name).prefix(4)), ["..", "f", "a.jpg", "p0.jpg"])
        XCTAssertEqual(followed.last?.name, "zz.jpg")
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

    /// A camera whose clock was never set writes zeros: no date (not the
    /// year 2), or the next date the file has.
    func testAZeroCaptureDateIsNone() async throws {
        let tree = try TempTree(self)
        func photo(_ name: String, _ properties: [CFString: Any]) throws -> URL {
            let url = tree.root.appendingPathComponent(name)
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            return url
        }
        let zero = [kCGImagePropertyExifDateTimeOriginal: "0000:00:00 00:00:00"] as CFDictionary
        let none = await BrowserModel.captureDate(of: try photo("zero.jpg", [kCGImagePropertyExifDictionary: zero]))
        XCTAssertNil(none)
        let fallback = await BrowserModel.captureDate(of: try photo("tiff.jpg", [
            kCGImagePropertyExifDictionary: zero,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2019:11:19 13:47:00"] as CFDictionary
        ]))
        XCTAssertEqual(Calendar.current.component(.year, from: try XCTUnwrap(fallback)), 2019)
    }
}

// MARK: - Directory scan & folder previews

final class ScanTests: XCTestCase {
    func testScanClassifiesExcludesHiddenAndNonMedia() async throws {
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
        XCTAssertNil(byName[".secret.png"], "hidden media is listed only while hidden files are shown (HiddenFilesTests)")
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

    /// Any three of the folder's own media (as the disk lists them: a big
    /// folder isn't listed to its end), never hidden ones or other files,
    /// not from a subfolder while the folder has its own.
    func testFolderPreviewFilesAreThreeOfTheFoldersOwnMedia() async throws {
        let tree = try TempTree(self)
        for n in ["img10.jpg", "img2.jpg", "img1.jpg", "clip.mp4", "notes.txt", ".hidden.jpg"] {
            try tree.file(n)
        }
        try tree.file("deeper/aaa.jpg")

        let files = await BrowserModel.folderPreviewFiles(in: tree.root)
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(Set(files.map(\.lastPathComponent)).isSubset(of: ["img10.jpg", "img2.jpg", "img1.jpg", "clip.mp4"]))
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
        m.leaveDetailOrGoBack()
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

    /// A launch that reopened the last folder and didn't last (a file there
    /// may crash the app): the next launch doesn't reopen it, and says so.
    func testAFolderThatEndedTheLastLaunchIsNotReopened() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let defaults = makeTestDefaults()
        await openAndWait(BrowserModel(defaults: defaults), tree.root)

        let crashed = BrowserModel(defaults: defaults)
        crashed.restoreLastFolder()
        await waitUntil { crashed.isAt(tree.root) }
        // (the app ends here without quitting normally)

        let next = BrowserModel(defaults: defaults)
        next.restoreLastFolder()
        XCTAssertNil(next.folderURL)
        XCTAssertEqual(next.skippedRestore.map { URL(fileURLWithPath: $0).lastPathComponent }, tree.root.lastPathComponent)

        let after = BrowserModel(defaults: defaults)
        after.restoreLastFolder()
        await waitUntil { after.isAt(tree.root) }   // once only

        BrowserModel.confirmRestore(in: defaults)   // a normal quit
        let again = BrowserModel(defaults: defaults)
        again.restoreLastFolder()
        await waitUntil { again.isAt(tree.root) }
    }

    /// The reopened folder counts as harmless only a while after its
    /// listing is shown, however long the listing takes.
    func testTheRestoredFolderIsConfirmedOnlyAfterItIsShown() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let defaults = makeTestDefaults()
        await openAndWait(BrowserModel(defaults: defaults), tree.root)
        let m = BrowserModel(defaults: defaults)
        m.restoreConfirmDelay = .zero
        // Looked at the moment the mark is removed (on the main thread), not by polling
        final class Watch: NSObject {
            let key: String
            var shownWhenConfirmed: [Bool] = []
            init(key: String) { self.key = key }
            var shown: () -> Bool = { false }
            override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                       context: UnsafeMutableRawPointer?) {
                guard (object as? UserDefaults)?.string(forKey: key) == nil else { return }
                XCTAssertTrue(Thread.isMainThread)
                shownWhenConfirmed.append(shown())
            }
        }
        let watch = Watch(key: BrowserModel.restoreUnconfirmedKey)
        watch.shown = { MainActor.assumeIsolated { m.isAt(tree.root) } }
        defaults.addObserver(watch, forKeyPath: BrowserModel.restoreUnconfirmedKey, options: [.new], context: nil)
        defer { defaults.removeObserver(watch, forKeyPath: BrowserModel.restoreUnconfirmedKey) }
        m.restoreLastFolder()
        XCTAssertNotNil(defaults.string(forKey: BrowserModel.restoreUnconfirmedKey), "marked while it opens")
        await waitUntil { m.isAt(tree.root) }
        await waitUntil { defaults.string(forKey: BrowserModel.restoreUnconfirmedKey) == nil }
        XCTAssertEqual(watch.shownWhenConfirmed, [true], "confirmed only once the folder was shown")
    }

    /// A normal quit confirms the folders of every window's panes, not only the first window's.
    func testANormalQuitConfirmsTheFoldersOfEveryWindow() {
        let defaults = makeTestDefaults()
        let prefixes = ["", "rightPane.", "window2.", "window2.rightPane.", "window7."]
        for prefix in prefixes { defaults.set("/somewhere", forKey: prefix + BrowserModel.restoreUnconfirmedKey) }
        defaults.set("/kept", forKey: "window2." + BrowserModel.lastFolderKey)
        BrowserModel.confirmRestore(in: defaults)
        for prefix in prefixes { XCTAssertNil(defaults.string(forKey: prefix + BrowserModel.restoreUnconfirmedKey), prefix) }
        XCTAssertEqual(defaults.string(forKey: "window2." + BrowserModel.lastFolderKey), "/kept")
    }

    func testRestoreIgnoresMissingFolder() async throws {
        let defaults = makeTestDefaults()
        defaults.set("/does/not/exist", forKey: BrowserModel.lastFolderKey)
        let m = BrowserModel(defaults: defaults)
        m.restoreLastFolder()
        XCTAssertTrue(m.restoringLastFolder)
        await waitUntil { !m.restoringLastFolder }   // decided in the background
        XCTAssertNil(m.folderURL)
    }

    func testUITestingUsesSeparateResettableDefaults() {
        XCTAssertTrue(BrowserModel.makeDefaults(arguments: ["app"]) === UserDefaults.standard)
        let name = TestDefaults.name("reset")
        let suite = BrowserModel.makeDefaults(arguments: ["app", "--ui-testing"], suite: name)
        XCTAssertFalse(suite === UserDefaults.standard)
        suite.set("x", forKey: BrowserModel.lastFolderKey)
        let reset = BrowserModel.makeDefaults(arguments: ["app", "--ui-testing", "--reset-state"], suite: name)
        XCTAssertNil(reset.string(forKey: BrowserModel.lastFolderKey))
        // Written during the run: kept when asked again (Shortcuts, Bookmarks, the quit)
        reset.set("y", forKey: BrowserModel.lastFolderKey)
        let again = BrowserModel.makeDefaults(arguments: ["app", "--ui-testing", "--reset-state"], suite: name)
        XCTAssertEqual(again.string(forKey: BrowserModel.lastFolderKey), "y", "emptied once per launch")
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
    /// The three modes beside the field: ignoring case, matching case, a
    /// regular expression (anywhere in the name; one that doesn't compile
    /// matches nothing).
    func testNameMatcherModes() {
        XCTAssertTrue(NameMatcher("img").matches("IMG_0001.JPG"))
        XCTAssertFalse(NameMatcher("img", mode: .matchingCase).matches("IMG_0001.JPG"))
        XCTAssertTrue(NameMatcher("IMG", mode: .matchingCase).matches("IMG_0001.JPG"))
        XCTAssertTrue(NameMatcher("a.c", mode: .matchingCase).matches("a.c.jpg"))
        XCTAssertFalse(NameMatcher("a.c", mode: .matchingCase).matches("abc.jpg"), "taken as typed, not as a pattern")
        XCTAssertTrue(NameMatcher(#"^IMG_\d{4}\.jpe?g$"#, mode: .regex).matches("IMG_0001.jpg"))
        XCTAssertFalse(NameMatcher(#"^IMG_\d{4}\.jpe?g$"#, mode: .regex).matches("IMG_0001.png"))
        XCTAssertTrue(NameMatcher("(?i)^img", mode: .regex).matches("Img_7.jpg"))
        XCTAssertTrue(NameMatcher("[", mode: .regex).isValid == false)
        XCTAssertFalse(NameMatcher("[", mode: .regex).matches("[a].jpg"))
        XCTAssertTrue(NameMatcher("[").isValid)
        XCTAssertTrue(NameMatcher("[").matches("[a].jpg"))
    }

    /// An expression that backtracks without end gives up on a name instead of hanging.
    func testARunawayExpressionGivesUpOnAName() {
        let name = String(repeating: "a", count: 40) + ".jpg"
        let start = Date()
        XCTAssertFalse(NameMatcher("(a|a)*b", mode: .regex).matches(name))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "bounded")
        XCTAssertTrue(NameMatcher("(a|a)*\\.jpg", mode: .regex).matches(name), "a match it finds in time stays one")
        let stop = WalkStop()
        stop.set()
        XCTAssertFalse(NameMatcher("a", mode: .regex).matches(name, stop: stop), "nothing once the search is over")
    }

    /// A regular expression is matched off the main thread: typing stays
    /// quick, and a new query takes over from the old one.
    func testARegularExpressionDoesNotHoldTheMainThread() async throws {
        let tree = try TempTree(self)
        for i in 0..<40 { try tree.file(String(repeating: "a", count: 30 + i) + ".jpg") }
        try tree.file("b.jpg")
        let m = makeModel()
        m.searchMode = .regex
        await openAndWait(m, tree.root)
        let start = Date()
        m.searchText = "(a|a)*b"
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the main thread goes on at once")
        XCTAssertTrue(m.isSearching)
        // While the names are matched (each up to the matcher's deadline),
        // the main thread keeps turning
        var largestGap: TimeInterval = 0, last = Date(), beats = 0
        while Date().timeIntervalSince(start) < 1, m.isSearching {
            try await Task.sleep(nanoseconds: 10_000_000)
            largestGap = max(largestGap, Date().timeIntervalSince(last))
            last = Date()
            beats += 1
        }
        XCTAssertLessThan(largestGap, 0.5, "the main thread was held while matching (\(beats) beats)")
        await searchAndWait(m, "^b")
        XCTAssertEqual(m.names, ["b.jpg"])
    }

    /// Switching the mode searches again, in subfolders too, and is remembered.
    func testTheSearchModeSearchesAgainAndIsRemembered() async throws {
        let tree = try TempTree(self)
        for n in ["Beach.jpg", "beach2.jpg", "sub/BEACH-3.jpg", "sub/dune.jpg"] { try tree.file(n) }
        let defaults = makeTestDefaults()
        let m = BrowserModel(defaults: defaults)
        m.searchDebounce = .zero
        await openAndWait(m, tree.root)
        await searchAndWait(m, "beach")
        XCTAssertEqual(Set(m.names), ["Beach.jpg", "beach2.jpg", "BEACH-3.jpg"])
        m.searchMode = .matchingCase
        await waitUntil { !m.isSearching }
        XCTAssertEqual(m.names, ["beach2.jpg"])
        m.searchMode = .regex
        await searchAndWait(m, "^(?i)beach-?\\d")
        XCTAssertEqual(Set(m.names), ["beach2.jpg", "BEACH-3.jpg"])
        await searchAndWait(m, "beach(")
        XCTAssertEqual(m.names, [], "not an expression: nothing")
        XCTAssertFalse(m.matcher.isValid)
        XCTAssertEqual(BrowserModel(defaults: defaults).searchMode, .regex, "remembered")
    }

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
            found += batch.entries
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

    /// Back twice in quick succession (a slow share still loading the first
    /// step): the step passed over keeps its selection for Forward.
    func testBackWhileLoadingKeepsTheSelectionForForward() async throws {
        let tree = try TempTree(self)
        let a = try tree.folder("a")
        let b = try tree.folder("a/b")
        try tree.folder("a/c")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await openAndWait(m, a)
        m.selectEntry(named: "b")
        await openAndWait(m, b)

        m.navigateBack()       // starts loading a, where b is selected
        XCTAssertTrue(m.isLoading)
        m.navigateBack()       // before a has loaded
        await waitUntil { m.isAt(tree.root) }
        m.navigateForward()
        await waitUntil { m.isAt(a) }
        XCTAssertEqual(m.selectedEntry?.name, "b")
    }

    /// Back while a folder of search results loads keeps the search: Forward
    /// shows the remembered results, not a search started over.
    func testBackWhileLoadingKeepsTheSearchForForward() async throws {
        let tree = try TempTree(self)
        let start = try tree.folder("start")
        let sub = try tree.folder("sub")
        try tree.file("deep/x/album.jpg")
        let m = makeModel()
        await openAndWait(m, start)
        await openAndWait(m, tree.root)
        await searchAndWait(m, "album")
        XCTAssertEqual(m.names, ["album.jpg"])
        await openAndWait(m, sub)

        m.navigateBack()       // to the results, still loading
        m.navigateBack()       // on to start before they are on screen
        await waitUntil { m.isAt(start) }
        m.navigateForward()
        await waitUntil { m.isAt(tree.root) && !m.isLoading }
        XCTAssertEqual(m.searchText, "album")
        XCTAssertEqual(m.names, ["album.jpg"])
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

        m.handleKey(.space, command: false)   // enter the result folder
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
        m.handleKey(.space, command: false)
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

    /// Backspace is Back (also back to a search); with no history it goes up.
    func testBackspaceGoesBackElseUp() async throws {
        let tree = try TempTree(self)
        let sub = try tree.folder("sub")
        try tree.file("sub/deep/album/x.jpg")
        let m = makeModel()
        await openAndWait(m, sub)
        m.handleKey(.backspace, command: false)
        await waitUntil { m.isAt(tree.root) }   // no history: up

        await openAndWait(m, sub)
        await searchAndWait(m, "album")
        m.selectEntry(named: "album")
        m.activateSelection()
        await waitUntil { m.isAt(sub.appendingPathComponent("deep/album")) }
        m.handleKey(.backspace, command: false)
        await waitUntil { m.isAt(sub) && !m.isLoading }
        XCTAssertEqual(m.searchText, "album", "back to the search, not up to deep")
        XCTAssertEqual(m.names, ["album"])
        await searchAndWait(m, "")

        await openAndWait(m, sub)
        m.select(0)   // ".."
        m.activateSelection()
        await waitUntil { m.isAt(tree.root) }
    }

    /// Above "/" lie the drives (/Volumes, the startup disk among them);
    /// above them nothing.
    func testAboveTheRootLieTheDrivesAndThenNothing() async {
        let m = makeModel()
        XCTAssertFalse(m.canGoUp)
        await openAndWait(m, URL(fileURLWithPath: "/"))
        XCTAssertTrue(m.canGoUp)
        XCTAssertEqual(m.entries.first?.kind, .parent)
        m.goToParentFolder()
        await waitUntil { m.isAt(URL(fileURLWithPath: "/Volumes")) }
        XCTAssertFalse(m.canGoUp)
        XCTAssertNotEqual(m.entries.first?.kind, .parent)
        XCTAssertTrue(m.entries.contains { $0.kind == .folder }, "the startup disk at least")
        XCTAssertFalse(m.entries.contains { $0.name.hasPrefix("com.apple.") })
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
        let new = try await m.rename(entry, to: "  Zebra  ")

        XCTAssertEqual(new.lastPathComponent, "Zebra", "whitespace is trimmed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("Zebra/x.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("old").path))
        XCTAssertEqual(m.names, ["..", "Zebra"])
        XCTAssertEqual(m.selectedEntry?.name, "Zebra")
        XCTAssertNil(m.renameTarget, "sheet closes")
    }

    /// The other pane renames or trashes the item while its rename sheet is
    /// open here: the sheet follows the new name, or closes.
    func testTheRenameSheetFollowsChangesFromElsewhere() async throws {
        let tree = try TempTree(self)
        let a = try tree.file("a.jpg")
        try tree.file("b.jpg")
        let notes = try tree.file("notes.txt")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.beginRename())
        m.adopt([.moved(a, to: tree.root.appendingPathComponent("c.jpg"))])
        XCTAssertEqual(m.renameTarget?.name, "c.jpg", "follows the new name")
        m.adopt([.removed(tree.root.appendingPathComponent("c.jpg"))])
        XCTAssertNil(m.renameTarget, "closes: the item is gone")
        m.beginRename(try XCTUnwrap(m.otherFiles.first))
        XCTAssertEqual(m.renameFileTarget?.url.lastPathComponent, "notes.txt")
        m.adopt([.removed(notes)])
        XCTAssertNil(m.renameFileTarget)
    }

    /// The files listed under the grid (not pictures or videos) are renamed,
    /// moved and trashed too; the list follows.
    func testOtherFilesAreRenamedMovedAndTrashed() async throws {
        let tree = try TempTree(self)
        try tree.file("notes.txt")
        try tree.file("b.log")
        try tree.file("c.dat")
        let sorted = try tree.folder("Sorted")
        try tree.file("Sorted/x.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.otherFiles.map(\.name), ["b.log", "c.dat", "notes.txt"])

        let notes = try XCTUnwrap(m.otherFiles.first { $0.name == "notes.txt" })
        m.beginRename(notes)
        XCTAssertEqual(m.renameFileTarget?.name, "notes.txt")
        XCTAssertTrue(m.otherSheetOpen)
        try await m.rename(notes, to: "a.md")
        XCTAssertNil(m.renameFileTarget, "sheet closes")
        XCTAssertEqual(m.otherFiles.map(\.name), ["a.md", "b.log", "c.dat"], "renamed in place, sorted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("a.md").path))

        let b = try XCTUnwrap(m.otherFiles.first { $0.name == "b.log" })
        m.moveToTrash(b)
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["b.log"])
        XCTAssertEqual(m.otherFiles.map(\.name), ["a.md", "c.dat"])

        m.move([tree.root.appendingPathComponent("c.dat")], into: sorted)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertEqual(m.otherFiles.map(\.name), ["a.md"], "moved out of the folder shown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sorted.appendingPathComponent("c.dat").path))
    }

    func testRenameValidation() async throws {
        let tree = try TempTree(self)
        try tree.folder("a")
        try tree.folder("b")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let a = try XCTUnwrap(m.entries.first { $0.name == "a" })

        await assertThrowsAsync(try await m.rename(a, to: "   ")) { XCTAssertEqual($0 as? RenameError, .emptyName) }
        await assertThrowsAsync(try await m.rename(a, to: "x/y")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        await assertThrowsAsync(try await m.rename(a, to: "x:y")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        await assertThrowsAsync(try await m.rename(a, to: "..")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        await assertThrowsAsync(try await m.rename(a, to: "b")) { XCTAssertEqual($0 as? RenameError, .alreadyExists("b")) }
        XCTAssertTrue(spy.moved.isEmpty, "nothing touched the disk")

        let same = try await m.rename(a, to: "a")
        XCTAssertEqual(same, a.url, "same name is a no-op")
        XCTAssertTrue(spy.moved.isEmpty)
    }

    func testCaseOnlyRenameIsAllowed() async throws {
        let tree = try TempTree(self)
        try tree.folder("photos")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        let entry = try XCTUnwrap(m.entries.first { $0.name == "photos" })
        try await m.rename(entry, to: "Photos")
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
        await assertThrowsAsync(try await m.rename(a, to: "b")) { error in
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
        m.renameTarget = nil
        XCTAssertTrue(m.handleKey(.f6, command: false), "Norton Commander's F6 in a single pane")
    }

    func testRenameAFileInTheFullViewStaysOnIt() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.mp4"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "b.jpg")
        m.activateSelection()
        let entry = try XCTUnwrap(m.selectedEntry)

        await assertThrowsAsync(try await m.rename(entry, to: "b.txt")) {
            XCTAssertEqual($0 as? RenameError, .changesKind("jpg", video: false))
        }
        await assertThrowsAsync(try await m.rename(entry, to: "a.jpg")) {
            XCTAssertEqual($0 as? RenameError, .alreadyExists("a.jpg"))
        }
        let new = try await m.rename(entry, to: "Beach.jpg")
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
        try await m.rename(entry, to: "new")

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
        try await m.rename(entry, to: "Target 2")
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
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "Holiday")

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
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "Holiday")

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
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "sub2")
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
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "Renamed")
        m.navigateForward()
        await waitUntil { m.folderURL?.lastPathComponent == "Renamed" && !m.isLoading }
        XCTAssertEqual(m.names, ["..", "sub", "trip-beach.jpg"])
    }

    func testEditingTheQueryAfterRestoreSearchesAgain() async throws {
        let (tree, m) = try await searchTrip()
        m.selectEntry(named: "trip-2024")
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "Holiday")
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

    /// The status bar's path menu: Copy Path (the folder's POSIX path), Copy
    /// Path of Selected Item (not ".."), Reveal in Finder (the folder;
    /// nothing at the drives' level).
    func testTheStatusBarPathIsCopiedAndRevealed() async throws {
        let tree = try TempTree(self)
        try tree.file("sub folder/a.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        let folder = tree.root.appendingPathComponent("sub folder", isDirectory: true)
        await openAndWait(m, folder)
        m.copyFolderPath()
        XCTAssertEqual(spy.copiedTexts.count, 1)
        XCTAssertTrue(BrowserModel.samePath(URL(fileURLWithPath: spy.copiedTexts[0]), folder), spy.copiedTexts[0])
        XCTAssertFalse(spy.copiedTexts[0].hasPrefix("file:"), "a POSIX path, not a URL")
        XCTAssertFalse(spy.copiedTexts[0].hasSuffix("/"))

        m.select(0)   // ".."
        XCTAssertNil(m.selectedItemPath)
        m.copySelectedItemPath()
        XCTAssertEqual(spy.copiedTexts.count, 1, "nothing for ..")
        m.selectEntry(named: "a.jpg")
        m.copySelectedItemPath()
        XCTAssertEqual(spy.copiedTexts.last.map { URL(fileURLWithPath: $0).lastPathComponent }, "a.jpg")

        XCTAssertTrue(m.canRevealFolder)
        m.revealFolderInFinder()
        XCTAssertEqual(spy.revealed.count, 1)
        XCTAssertTrue(spy.revealed.first.map { BrowserModel.samePath($0, folder) } == true)

        await openAndWait(m, URL(fileURLWithPath: "/Volumes", isDirectory: true))
        XCTAssertFalse(m.canRevealFolder)
        m.revealFolderInFinder()
        XCTAssertEqual(spy.revealed.count, 1, "the drives' level isn't revealed")
        m.copyFolderPath()
        XCTAssertEqual(spy.copiedTexts.last, "/Volumes")
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

    /// Trashed in the full view: the next picture comes up at fit, upright.
    func testTrashInTheFullViewResetsZoomAndRotation() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg"] { try tree.file(n) }
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        m.activateSelection()
        XCTAssertEqual(m.mode, .detail)
        m.handleKey(.char("+"), command: false)
        m.handleKey(.right, command: false, option: true)
        XCTAssertNotEqual(m.zoom, 1)
        m.moveSelectionToTrash()
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg")
        XCTAssertEqual(m.zoom, 1)
        XCTAssertEqual(m.rotation, 0)
    }

    /// ⇧⌘N: the folder exists only once named; it is listed and selected.
    func testNewFolderIsMadeOnlyWhenNamed() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.folder("Taken")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        XCTAssertTrue(m.beginNewFolder())
        XCTAssertTrue(m.newFolderRequested)
        XCTAssertFalse(m.handleKey(.right, command: false), "the sheet keeps the keys")
        await assertThrowsAsync(try await m.createFolder(named: "  ")) { XCTAssertEqual($0 as? RenameError, .emptyName) }
        await assertThrowsAsync(try await m.createFolder(named: "a/b")) { XCTAssertEqual($0 as? RenameError, .invalidName) }
        await assertThrowsAsync(try await m.createFolder(named: "Taken")) { XCTAssertEqual($0 as? RenameError, .alreadyExists("Taken")) }
        XCTAssertTrue(spy.created.isEmpty, "nothing made yet")
        let made = try await m.createFolder(named: "Sorted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
        XCTAssertFalse(m.newFolderRequested)
        XCTAssertEqual(m.selectedEntry?.name, "Sorted")
        XCTAssertEqual(m.names, ["..", "Sorted", "Taken", "a.jpg"])

        m.newFolderRequested = true   // Esc
        m.newFolderRequested = false
        XCTAssertEqual(spy.created.count, 1, "cancelled: no folder")

        let zip = try tree.file("x.zip")
        _ = zip
        await openAndWait(m, tree.root.appendingPathComponent("Sorted"))
        XCTAssertTrue(m.canCreateFolder)
    }

    /// The folder shown, renamed from its title: it stays open under the
    /// new name, its pictures with it; Back leads to the parent.
    func testRenamingTheFolderShown() async throws {
        let tree = try TempTree(self)
        try tree.file("Trip/a.jpg")
        try tree.folder("Taken")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        await openAndWait(m, tree.root.appendingPathComponent("Trip"))
        XCTAssertTrue(m.canRenameCurrentFolder)
        await m.renameCurrentFolder(to: "Taken")
        XCTAssertEqual(spy.reported.count, 1, "the name is taken")
        await m.renameCurrentFolder(to: "Iceland 2025")
        let renamed = tree.root.appendingPathComponent("Iceland 2025")
        XCTAssertTrue(m.isAt(renamed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("a.jpg").path))
        XCTAssertEqual(m.names, ["..", "a.jpg"])
        XCTAssertTrue(BrowserModel.samePath(m.entries[1].url, renamed.appendingPathComponent("a.jpg")), "its pictures follow")
        m.navigateBack()
        await waitUntil { m.isAt(tree.root) }
        XCTAssertTrue(m.names.contains("Iceland 2025"))
    }

    /// The folder of the search on screen renamed from its title: the search
    /// keeps its results, and so does its history step.
    func testRenamingTheFolderOfASearchKeepsItsResults() async throws {
        let tree = try TempTree(self)
        try tree.file("Trip/IMG_1.jpg")
        try tree.file("Trip/day 2/IMG_2.jpg")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root.appendingPathComponent("Trip"))
        await searchAndWait(m, "IMG")
        XCTAssertEqual(m.names, ["IMG_1.jpg", "IMG_2.jpg"])
        await m.renameCurrentFolder(to: "Trip 2024")
        let renamed = tree.root.appendingPathComponent("Trip 2024")
        XCTAssertEqual(m.names, ["IMG_1.jpg", "IMG_2.jpg"])
        await openAndWait(m, renamed.appendingPathComponent("day 2"))
        m.navigateBack()
        await waitUntil { m.isAt(renamed) && m.searchText == "IMG" && !m.entries.isEmpty }
        XCTAssertEqual(m.names, ["IMG_1.jpg", "IMG_2.jpg"], "Back shows the results under the new name")
    }

    /// Dropped onto a folder tile: into it (and out of this listing); onto
    /// ".." a level up; not into itself, not into an archive.
    func testMovingIntoAFolder() async throws {
        let tree = try TempTree(self)
        let a = try tree.file("a.jpg"), b = try tree.file("b.jpg")
        let sorted = try tree.folder("Sorted")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.move([a, b], into: sorted)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertEqual(m.names, ["..", "Sorted"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sorted.appendingPathComponent("a.jpg").path))
        let movesBefore = spy.moved.count, reportsBefore = spy.reported.count
        m.move([sorted], into: sorted)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertEqual(spy.moved.count, movesBefore, "not into itself: nothing is tried")
        XCTAssertEqual(spy.reported.count, reportsBefore, "and nothing fails")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sorted.path))
        await openAndWait(m, sorted)
        m.move([sorted.appendingPathComponent("a.jpg")], into: tree.root)   // onto ".."
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertEqual(m.names, ["..", "b.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("a.jpg").path))
        let archive = tree.root.appendingPathComponent("photos.zip")
        let before = spy.moved.count
        m.move([sorted.appendingPathComponent("b.jpg")], into: archive)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertEqual(spy.moved.count, before, "nothing goes into an archive")
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

    /// A file selected in the grid: the show starts there, also deep in the
    /// tree, and goes on (and round) from it. A folder selected: at its
    /// first item. The tile selected on opening a folder doesn't count.
    func testSlideshowStartsAtTheSelection() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "sub1/c.jpg", "sub1/d.jpg", "sub2/e.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.selectedEntry?.name, "sub1", "selected on opening")
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg", "not at the folder selected on opening")
        m.stopSlideshow()

        m.selectEntry(named: "b.jpg")
        m.startSlideshow()
        await waitUntil { m.shownMediaEntry != nil }
        XCTAssertEqual(m.shownMediaEntry?.name, "b.jpg")
        m.slideshowStep(+1)
        // sub1 may still be walked: past the last item the show waits for it
        await waitUntil { m.shownMediaEntry?.name == "c.jpg" }
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg", "goes on into the subfolders")
        m.stopSlideshow()

        m.selectEntry(named: "sub2")
        m.startSlideshow()
        await waitUntil { m.shownMediaEntry != nil }
        XCTAssertEqual(m.shownMediaEntry?.name, "e.jpg", "the selected folder's first item")
        await waitUntil { m.slideshow?.loading == false }
        m.slideshowStep(+1)
        XCTAssertEqual(m.shownMediaEntry?.name, "a.jpg", "and round to the start")
        m.stopSlideshow()

        m.selectEntry(named: "sub1")
        m.handleKey(.char("s"), command: false)
        await waitUntil { m.shownMediaEntry != nil }
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg", "a folder the user selected (again) counts")
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
        // c.jpg keeps the short interval it was shown with; a.jpg stays long
        // enough to be seen (else the show is on the video again at once)
        m.slideshowInterval = .seconds(60)
        await waitUntil { m.shownMediaEntry?.name == "a.jpg" }    // starts over
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

    /// A video that plays without a known length (a browser's WebM) stays
    /// until it ends.
    func testSlideshowWaitsForAVideoWithoutALength() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.webm", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowVideoCheck = .milliseconds(30)
        await openAndWait(m, tree.root)
        m.startSlideshow()
        await waitUntil { m.shownMediaEntry?.name == "b.webm" }
        m.slideshowInterval = .seconds(60)
        let player = PlayerSpy()
        player.progress = nil
        player.playsWithoutLength = true
        m.activePlayer = player
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(m.shownMediaEntry?.name, "b.webm", "not skipped while it plays")
        player.progress = 1   // VLC reports the end
        player.isPlaying = false
        m.playbackStateChanged(player, isPlaying: false)
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg")
    }

    /// A download that ends where its data ends, short of its length: the
    /// show moves on; paused there by the user, it stays.
    func testSlideshowMovesOnFromADownloadEndedShortOfItsLength() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.mkv", "c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.slideshowInterval = .seconds(60)
        m.startSlideshow(startingAt: tree.root.appendingPathComponent("b.mkv"))
        await waitUntil { m.shownMediaEntry?.name == "b.mkv" }
        let player = PlayerSpy()
        m.activePlayer = player
        player.progress = 0.58
        player.isPlaying = false
        m.playbackStateChanged(player, isPlaying: false)
        XCTAssertEqual(m.shownMediaEntry?.name, "b.mkv", "paused, not ended")
        player.endedShort = true
        m.playbackStateChanged(player, isPlaying: false)
        XCTAssertEqual(m.shownMediaEntry?.name, "c.jpg")
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

    /// ⌘↑ and the history's menu items don't move the grid behind a
    /// slideshow (which would end it): no navigation while presenting.
    func testNoNavigationDuringASlideshow() async throws {
        let tree = try TempTree(self)
        for n in ["trip/a.jpg", "trip/b.jpg", "other/c.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root.appendingPathComponent("other"))
        let trip = tree.root.appendingPathComponent("trip")
        await openAndWait(m, trip)
        XCTAssertTrue(m.canGoBack)
        m.slideshowInterval = .seconds(60)
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertTrue(m.handleKey(.up, command: true), "⌘↑ taken by the slideshow, not handed to the menu")
        XCTAssertTrue(m.handleKey(.down, command: true))
        XCTAssertFalse(m.canGoUp)
        XCTAssertFalse(m.canGoBack)
        m.goToParentFolder()
        m.navigateBack()
        XCTAssertNotNil(m.slideshow, "the show goes on")
        XCTAssertTrue(m.isAt(trip), "the grid behind it stays")
        m.stopSlideshow()
        XCTAssertTrue(m.canGoUp)
        XCTAssertTrue(m.canGoBack)
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

    /// Auto reports a video's look four times a second: the same look again
    /// publishes nothing (each change redraws the grid behind the video).
    func testTheSameAutoLookAgainPublishesNothing() {
        let m = makeModel()
        let player = PlayerSpy()
        m.activePlayer = player
        m.enhance = true
        let measured = Look(exposure: 0.4, contrast: 0.2, saturation: 0.1, sharpness: 0.5)
        m.autoLookMeasured(measured, from: player)
        var changes = 0
        let watch = m.objectWillChange.sink { changes += 1 }
        m.autoLookMeasured(measured, from: player)
        watch.cancel()
        XCTAssertEqual(changes, 0)
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
        m.handleKey(.right, command: false, option: true)
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

    /// a.jpg, clip.mp4, z.jpg: open on the video with a player at the start.
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

    /// A download played to where its data ends, short of its length: →
    /// moves on as at its end, ← goes back a tenth from where it stands.
    func testArrowsAtTheEndOfADownloadsData() async throws {
        let (m, player) = try await openOnVideo()
        player.progress = 0.58
        player.isPlaying = false
        player.endedShort = true
        m.handleKey(.left, command: false)
        XCTAssertEqual(player.calls.last, "seek 48 %", "a tenth back from where its data ended")
        player.progress = 0.58
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg", "ended: on to the next item")
    }

    /// ⇧←/⇧→: a hundredth of the length, staying in the video at its ends.
    func testShiftArrowsStepOnePercent() async throws {
        let (m, player) = try await openOnVideo()
        player.progress = 0.5
        m.handleKey(.right, command: false, shift: true)
        XCTAssertEqual(player.calls.last, "seek 51 %")
        m.handleKey(.left, command: false, shift: true)
        m.handleKey(.left, command: false, shift: true)
        XCTAssertEqual(player.calls.last, "seek 49 %")
        player.progress = 0.005
        let shown = m.shownMediaEntry
        m.handleKey(.left, command: false, shift: true)
        XCTAssertEqual(player.calls.last, "seek 0 %")
        XCTAssertEqual(m.shownMediaEntry, shown, "no paging at the start")
    }

    /// → held down skims through a video and stops at its end; a new press
    /// moves on. A video whose length isn't known yet isn't left at once.
    func testAHeldArrowStaysInTheVideo() async throws {
        let (m, player) = try await openOnVideo()
        player.progress = 0.85
        m.handleKey(.right, command: false, repeating: true)
        XCTAssertEqual(player.calls.last, "seek 95 %")
        player.progress = 0.95
        m.handleKey(.right, command: false, repeating: true)
        XCTAssertEqual(m.selectedEntry?.name, "clip.mp4", "held down: stays at the end")
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg", "pressed again: on to the next item")

        m.selectEntry(named: "clip.mp4")
        let fresh = PlayerSpy()
        fresh.progress = nil   // just opened, no length yet
        m.activePlayer = fresh
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "clip.mp4", "waits for the length")
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
        XCTAssertEqual(m.selectedEntry?.name, "clip.mp4", "↓ on a video is its volume")
        XCTAssertEqual(player.volume ?? -1, 0.9, accuracy: 0.001)
        XCTAssertEqual(player.calls, [], "no seeking")
    }

    /// ↑/↓ on a video: one volume for all videos, in tenths, from 100 %,
    /// remembered.
    func testUpAndDownSetTheVolumeOfEveryVideo() async throws {
        let (m, player) = try await openOnVideo()
        XCTAssertEqual(m.volume, 1, "starts at 100 %")
        m.handleKey(.up, command: false)
        XCTAssertEqual(m.volume, 1, "no louder than 100 %")
        m.handleKey(.down, command: false)
        m.handleKey(.down, command: false)
        XCTAssertEqual(m.volume, 0.8, accuracy: 0.001)
        XCTAssertEqual(player.volume ?? -1, 0.8, accuracy: 0.001)
        XCTAssertEqual(BrowserModel(defaults: m.defaults).volume, 0.8, accuracy: 0.001, "remembered")
        let next = PlayerSpy()
        m.activePlayer = next
        XCTAssertEqual(next.volume ?? -1, 0.8, accuracy: 0.001, "the next video gets it too")
        m.selectEntry(named: "z.jpg")
        XCTAssertFalse(m.handleKey(.up, command: false), "on a picture at fit ↑ does nothing")
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg", "no paging")
        m.handleKey(.char("+"), command: false)
        XCTAssertTrue(m.handleKey(.down, command: false), "zoomed in: look further down")
        XCTAssertEqual(m.panRequest?.up, false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg")
        m.zoomReset()
        for _ in 0..<12 { m.selectEntry(named: "clip.mp4"); m.handleKey(.down, command: false) }
        XCTAssertEqual(m.volume, 0, "no quieter than silent")
    }

    // MARK: Subtitles, audio tracks, speed

    /// Subtitles are on at first, with the file's default track; V turns
    /// them off for this video and the next ones (remembered).
    func testVTurnsSubtitlesOffAndTheChoiceIsRemembered() async throws {
        let (m, _) = try await openOnVideo()
        let player = PlayerSpy.withTracks()
        m.activePlayer = player
        m.tracksChanged(from: player)
        XCTAssertEqual(player.calls, [], "the file's default subtitles stay")
        XCTAssertEqual(m.videoTracks.subtitleID, 3)
        XCTAssertTrue(m.handleKey(.char("v"), command: false))
        XCTAssertEqual(player.calls, ["subtitles off"])
        XCTAssertNil(m.videoTracks.subtitleID)
        XCTAssertEqual(m.playbackNotice?.text, "Subtitles off")
        let next = PlayerSpy.withTracks()
        m.activePlayer = next
        m.tracksChanged(from: next)
        XCTAssertEqual(next.calls, ["subtitles off"], "the next video starts without")
        XCTAssertFalse(BrowserModel(defaults: m.defaults).showSubtitles, "remembered")
        m.handleKey(.char("V"), command: false)
        XCTAssertEqual(next.calls, ["subtitles off", "subtitles 3"], "on again: the default track")
        XCTAssertTrue(m.showSubtitles)
    }

    /// ⌃⌘S goes through the subtitle tracks, then none; the language chosen
    /// is the next video's.
    func testNextSubtitleTrackCyclesAndRemembersTheLanguage() async throws {
        let (m, _) = try await openOnVideo()
        let player = PlayerSpy.withTracks()
        m.activePlayer = player
        m.tracksChanged(from: player)
        m.nextSubtitleTrack()
        m.nextSubtitleTrack()
        m.nextSubtitleTrack()
        XCTAssertEqual(player.calls, ["subtitles 4", "subtitles off", "subtitles 3"])
        m.selectSubtitle(4)
        XCTAssertEqual(m.videoTracks.currentSubtitle?.language, "de")
        let next = PlayerSpy.withTracks()
        m.activePlayer = next
        m.tracksChanged(from: next)
        XCTAssertEqual(next.calls, ["subtitles 4"], "German again ('ger' and 'deu' are 'de')")
        XCTAssertEqual(m.videoTracks.subtitleID, 4)
    }

    /// Tracks VLC finds later (a list that grows) are decided again; the same
    /// list reported again changes nothing the user chose.
    func testSubtitlesFoundLaterAreChosenToo() async throws {
        let (m, _) = try await openOnVideo()
        let player = PlayerSpy()
        player.tracks.audio = [MediaTrack(id: 1, name: "English", language: "en")]
        player.tracks.audioID = 1
        m.activePlayer = player
        m.tracksChanged(from: player)
        XCTAssertEqual(player.calls, [])
        player.tracks.subtitles = [MediaTrack(id: 5, name: "English", language: "en")]
        m.tracksChanged(from: player)
        XCTAssertEqual(player.calls, ["subtitles 5"], "on, though the file marks none as default")
        m.selectSubtitle(nil)
        m.tracksChanged(from: player)
        XCTAssertEqual(player.calls, ["subtitles 5", "subtitles off"], "the user's choice stays")
    }

    /// ⌃⌘A: the next audio track, round; its language is the next video's.
    func testNextAudioTrackIsRemembered() async throws {
        let (m, _) = try await openOnVideo()
        let player = PlayerSpy.withTracks()
        m.activePlayer = player
        m.tracksChanged(from: player)
        m.nextAudioTrack()
        XCTAssertEqual(player.calls, ["audio 2"])
        XCTAssertEqual(m.playbackNotice?.text, "Audio: German")
        m.nextAudioTrack()
        m.nextAudioTrack()
        XCTAssertEqual(player.calls, ["audio 2", "audio 1", "audio 2"])
        let next = PlayerSpy.withTracks()
        m.activePlayer = next
        m.tracksChanged(from: next)
        XCTAssertEqual(next.calls, ["audio 2"], "German sound again")
        let single = PlayerSpy()
        single.tracks.audio = [MediaTrack(id: 1, name: "English", language: "en")]
        m.activePlayer = single
        m.tracksChanged(from: single)
        m.nextAudioTrack()
        XCTAssertEqual(single.calls, [], "one track: nothing to switch")
        XCTAssertEqual(m.playbackNotice?.text, "This video has only one audio track")
    }

    /// < / > step the speed (0.5× … 2×), shown in the badge's model and kept
    /// for the next video until the app quits; nothing on a picture.
    func testLessAndGreaterChangeTheSpeed() async throws {
        let (m, player) = try await openOnVideo()
        XCTAssertTrue(m.handleKey(.char(">"), command: false, shift: true))
        XCTAssertEqual(player.speed, 1.25)
        XCTAssertEqual(m.playbackNotice?.text, "Speed " + PlaybackSpeed.text(1.25))
        for _ in 0..<6 { m.handleKey(.char(">"), command: false, shift: true) }
        XCTAssertEqual(m.playbackSpeed, 2, "no faster than 2×")
        for _ in 0..<9 { m.handleKey(.char("<"), command: false, shift: true) }
        XCTAssertEqual(m.playbackSpeed, 0.5, "no slower than 0.5×")
        m.handleKey(.char(">"), command: false, shift: true)
        let next = PlayerSpy()
        m.activePlayer = next
        XCTAssertEqual(next.speed, 0.75, "the next video plays at it too")
        XCTAssertEqual(BrowserModel(defaults: m.defaults).playbackSpeed, 1, "not remembered across launches")
        m.setSpeed(1)
        XCTAssertEqual(next.speed, 1)
        m.selectEntry(named: "z.jpg")
        XCTAssertFalse(m.handleKey(.char(">"), command: false, shift: true), "a picture has no speed")
        XCTAssertFalse(m.handleKey(.char("v"), command: false))
        m.closeDetail()
        XCTAssertFalse(m.handleKey(.char("v"), command: false), "nor the grid")
    }

    func testSpeedSteps() {
        XCTAssertEqual(PlaybackSpeed.step(from: 1, by: 1), 1.25)
        XCTAssertEqual(PlaybackSpeed.step(from: 1, by: -1), 0.75)
        XCTAssertEqual(PlaybackSpeed.step(from: 2, by: 1), 2)
        XCTAssertEqual(PlaybackSpeed.step(from: 0.5, by: -1), 0.5)
        XCTAssertEqual(PlaybackSpeed.step(from: 1.1, by: -1), 1, "from between two steps to the nearer one that way")
    }

    func testTrackLanguagesAndNames() {
        XCTAssertEqual(MediaTrack.languageCode("eng"), "en")
        XCTAssertEqual(MediaTrack.languageCode("ger"), "de")
        XCTAssertEqual(MediaTrack.languageCode("deu"), "de")
        XCTAssertEqual(MediaTrack.languageCode("en-US"), "en")
        XCTAssertNil(MediaTrack.languageCode("und"))
        let english = Locale.current.localizedString(forLanguageCode: "en") ?? "?"
        XCTAssertEqual(MediaTrack.name(title: nil, language: "eng", number: 1), english)
        XCTAssertEqual(MediaTrack.name(title: "English", language: "eng", number: 1), english, "a title that only names the language")
        XCTAssertEqual(MediaTrack.name(title: "Commentary", language: "eng", number: 2), "Commentary (\(english))")
        XCTAssertEqual(MediaTrack.name(title: nil, language: nil, number: 3), "Track 3")
    }

    /// The control bar's place: its share of the video area, held inside it.
    func testTheControlBarStaysInsideTheVideoArea() {
        let bar = CGSize(width: 400, height: 40)
        let area = CGSize(width: 1000, height: 600)
        let bottom = VideoBarPlacement.place(nil, bar: bar, in: area)
        XCTAssertEqual(bottom.x, 500)
        XCTAssertEqual(bottom.y, 600 - VideoBarPlacement.bottomMargin - 20)
        let corner = VideoBarPlacement.place(CGPoint(x: 0, y: 0), bar: bar, in: area)
        XCTAssertEqual(corner.x, 200 + VideoBarPlacement.margin)
        XCTAssertEqual(corner.y, 20 + VideoBarPlacement.margin)
        let kept = VideoBarPlacement.place(CGPoint(x: 0.7, y: 0.3), bar: bar, in: area)
        XCTAssertEqual(kept, CGPoint(x: 700, y: 180))
        // A narrower window: still all of it on screen
        let narrow = VideoBarPlacement.place(CGPoint(x: 0.95, y: 0.5), bar: bar, in: CGSize(width: 500, height: 300))
        XCTAssertEqual(narrow.x, 500 - 200 - VideoBarPlacement.margin)
        let tiny = VideoBarPlacement.place(CGPoint(x: 0.9, y: 0.9), bar: bar, in: CGSize(width: 300, height: 30))
        XCTAssertEqual(tiny, CGPoint(x: 150, y: 15), "larger than the area: in its middle")
        XCTAssertEqual(VideoBarPlacement.fraction(of: CGPoint(x: 250, y: 150), in: CGSize(width: 1000, height: 600)), CGPoint(x: 0.25, y: 0.25))
    }

    /// A video that never gets a length (not playable) is left with →,
    /// once it had its moment to open.
    func testArrowsPageFromAVideoThatNeverGetsALength() async throws {
        let (m, player) = try await openOnVideo()
        player.progress = nil   // not playable
        m.lengthGrace = 0
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

    /// As in the Finder: Return renames the selected item, Space opens it;
    /// in the full view Return goes back to the grid.
    func testReturnRenamesAndSpaceOpens() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.handleKey(.enter, command: false))
        XCTAssertEqual(m.renameTarget?.name, "a.jpg", "Return renames")
        m.renameTarget = nil
        XCTAssertEqual(m.mode, .grid)
        XCTAssertTrue(m.handleKey(.space, command: false))
        XCTAssertEqual(m.mode, .detail, "Space opens")
        XCTAssertTrue(m.handleKey(.enter, command: false))
        XCTAssertEqual(m.mode, .grid, "Return leaves the full view")
        XCTAssertNil(m.renameTarget)
    }

    /// On ".." Return and Space both go up (".." has nothing to rename).
    func testReturnAndSpaceOnTheParentTileGoUp() async throws {
        let tree = try TempTree(self)
        try tree.file("inner/a.jpg")
        let m = makeModel()
        for key in [BrowserModel.KeyInput.enter, .space] {
            await openAndWait(m, tree.root.appendingPathComponent("inner"))
            m.selectEntry(named: "..")
            XCTAssertTrue(m.handleKey(key, command: false))
            await waitUntil { !m.isLoading && m.folderURL?.lastPathComponent == tree.root.lastPathComponent }
            XCTAssertNil(m.renameTarget)
        }
    }

    func testOptionArrowsRotateInDetailOnly() {
        let m = makeModel()
        XCTAssertFalse(m.handleKey(.right, command: false, option: true), "nothing in the grid")
        XCTAssertEqual(m.rotation, 0)
        m.mode = .detail
        XCTAssertTrue(m.handleKey(.right, command: false, option: true))
        XCTAssertEqual(m.rotation, 90)
        XCTAssertTrue(m.handleKey(.left, command: false, option: true))
        XCTAssertEqual(m.rotation, 0)
        XCTAssertFalse(m.handleKey(.char("]"), command: false), "] no longer turns")
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

    /// Esc with the sliders open closes them, not the full view.
    func testEscapeClosesTheAdjustmentsFirst() {
        let m = makeModel(); m.mode = .detail
        m.showAdjustments = true
        XCTAssertTrue(m.handleKey(.escape, command: false))
        XCTAssertFalse(m.showAdjustments)
        XCTAssertEqual(m.mode, .detail)
    }

    /// K shows and hides the mini keyboard, remembered; every key that acts
    /// is reported for it to light up.
    func testKTogglesTheMiniKeyboardAndKeysAreReported() {
        let defaults = makeTestDefaults()
        let m = BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions)
        XCTAssertFalse(m.showMiniKeyboard)
        XCTAssertTrue(m.handleKey(.char("k"), command: false))
        XCTAssertTrue(m.showMiniKeyboard)
        XCTAssertTrue(BrowserModel(defaults: defaults).showMiniKeyboard, "remembered")
        XCTAssertTrue(m.lastKeyPress?.matches(.char("K"), command: false, shift: false) == true)
        XCTAssertFalse(m.lastKeyPress?.matches(.char("k"), command: true, shift: false) == true)
        let before = m.lastKeyPress
        XCTAssertFalse(m.handleKey(.end, command: false), "nothing to do in an empty grid")
        XCTAssertEqual(m.lastKeyPress, before, "a key that didn't act isn't lit")
        m.handleKey(.char("K"), command: false)
        XCTAssertFalse(m.showMiniKeyboard)
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
            (115, .home), (119, .end), (122, .f1), (120, .f2), (99, .f3), (118, .f4), (96, .f5), (97, .f6), (98, .f7), (100, .f8), (101, .f9), (109, .f10), (114, .insert), (48, .tab),
        ]
        for (code, key) in cases {
            XCTAssertEqual(ContentView.keyInput(code: code, characters: ""), key, "keyCode \(code)")
        }
        XCTAssertEqual(ContentView.keyInput(code: 0, characters: "a"), .char("a"))
        XCTAssertEqual(ContentView.keyInput(code: 46, characters: "m"), .char("m"), "M marks")
        XCTAssertEqual(ContentView.keyInput(code: 8, characters: "C"), .char("C"), "⇧⌘C: the shifted letter, as ⌘ reads it")
        XCTAssertEqual(ContentView.keyInput(code: 46, characters: "Ь", latin: { "M" }), .char("M"),
                       "⇧⌘M on a Cyrillic layout")
        XCTAssertNil(ContentView.keyInput(code: 0, characters: ""))
        XCTAssertEqual(ContentView.keyInput(code: 1, characters: "ы", latin: { "s" }), .char("s"),
                       "a Cyrillic layout: the key read as on the Latin one")
        XCTAssertEqual(ContentView.keyInput(code: 1, characters: "s", latin: { "x" }), .char("s"))
        XCTAssertEqual(ContentView.keyInput(code: 1, characters: "ы"), .char("ы"), "no Latin layout")
    }

    /// ⌘⌫ / ⌘↩ while typing go to the text field, not to Trash / Open.
    func testCommandBackspaceAndReturnGoToTheTextField() {
        XCTAssertTrue(ContentView.textFieldTakes(code: 51, command: true))
        XCTAssertTrue(ContentView.textFieldTakes(code: 36, command: true))
        XCTAssertTrue(ContentView.textFieldTakes(code: 76, command: true))
        XCTAssertFalse(ContentView.textFieldTakes(code: 51, command: false))
        XCTAssertFalse(ContentView.textFieldTakes(code: 3, command: true), "⌘F")
        XCTAssertTrue(ContentView.textFieldTakes(code: 126, command: true), "⌘↑ moves the cursor, not up a folder")
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
        XCTAssertEqual(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/"))?.path, "/Volumes", "above /: every drive")
        XCTAssertNil(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/Volumes")), "nothing above the drives")
        XCTAssertEqual(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/Volumes/NAS/Photos"))?.path, "/Volumes/NAS")
        XCTAssertEqual(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/a/b/"))?.path, "/a")
        XCTAssertEqual(BrowserModel.parentFolder(of: URL(fileURLWithPath: "/a"))?.path, "/")
    }
}

// MARK: - Search stays consistent with renames and trash

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
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "Pics")

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
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "2024-old")
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
        await assertThrowsAsync(try await m.rename(entry, to: "Photos")) {
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
        XCTAssertEqual(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/VTS_01_1.VOB")), .video, "a DVD's video")
        XCTAssertNil(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/a.txt")))
        XCTAssertNil(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/._a.jpg")), "macOS's '._' companion files")
    }

    /// App Sandbox: a folder is readable when it is a granted one or lies
    /// inside one; outside the sandbox every folder is.
    @MainActor
    func testFolderAccessCoversWhatIsInsideAGrant() async {
        XCTAssertTrue(FolderAccess.path("/Users/a/Photos", isIn: "/Users/a/Photos"))
        XCTAssertTrue(FolderAccess.path("/Users/a/Photos/2025/x.jpg", isIn: "/Users/a/Photos"))
        XCTAssertTrue(FolderAccess.path("/Users/a/Photos/Trip.zip/Day 1", isIn: "/Users/a/Photos"), "inside an archive")
        XCTAssertFalse(FolderAccess.path("/Users/a/Photos2", isIn: "/Users/a/Photos"), "a name that only starts alike")
        XCTAssertFalse(FolderAccess.path("/Users/a", isIn: "/Users/a/Photos"), "the folder above")
        XCTAssertTrue(FolderAccess.path("/Volumes/Share", isIn: "/"))

        XCTAssertTrue(FolderAccess(sandboxed: false).covers(URL(fileURLWithPath: "/anywhere")))
        let sandboxed = FolderAccess(sandboxed: true)
        sandboxed.defaults = TestDefaults.make("access")
        sandboxed.restore()
        await sandboxed.restored()
        XCTAssertFalse(sandboxed.covers(URL(fileURLWithPath: "/anywhere")), "nothing granted yet")
        XCTAssertEqual(sandboxed.count, 0)
    }

    /// Light or dark: as the system's until chosen, then kept.
    func testTheAppearanceIsKept() throws {
        let defaults = TestDefaults.make("appearance")
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
        XCTAssertNil(AppAppearance.system.appearanceName)
        defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.key)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .dark)
        XCTAssertEqual(AppAppearance.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppAppearance.light.appearanceName, .aqua)
        defaults.set("purple", forKey: AppAppearance.key)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system, "an unknown value")
    }

    /// The marked items are found once per change of the list or the marks,
    /// not on each of the menus' many questions.
    func testTheMarkedItemsAreFoundOncePerChange() async throws {
        let tree = try TempTree(self)
        for n in 0..<4000 { try tree.file(String(format: "IMG_%04d.jpg", n)) }
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        for i in [1, 2000, 3999] { m.click(m.entries[i], command: true, shift: false) }
        // One finding of them: the marks changed before each run (one more marked, then not)
        var once = Double.infinity
        for _ in 0..<3 {
            m.click(m.entries[5], command: true, shift: false)
            once = min(once, TimeBudget.seconds(.thread) { XCTAssertEqual(m.actionEntries.count, 4) })
            m.click(m.entries[5], command: true, shift: false)
        }
        XCTAssertEqual(m.actionEntries.count, 3)
        TimeBudget.check("asked 200 times: not found 200 times", under: max(once * 20, 0.05)) {
            for _ in 0..<200 { XCTAssertTrue(m.canTrash) }
        }
        m.click(m.entries[1], command: true, shift: false)   // unmarks one
        XCTAssertEqual(m.actionEntries.count, 2, "a change of the marks is seen")
    }

    /// Capture dates are read by a chain of tasks, each waiting for the one
    /// before: cancelling the newest (another folder) stops them all.
    func testCancellingAChainOfReadsStopsEveryRead() async {
        let first = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let second = Task<Void, Never> { await BrowserModel.after(first) }
        let third = Task<Void, Never> { await BrowserModel.after(second) }
        third.cancel()
        let start = Date()
        await first.value
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(second.isCancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "the first read stopped, not waited out")
    }

    /// A ".ts" video and a picture known only by its content are renamed
    /// like any other: the kind is decided by the names, not by reading the
    /// new path, which doesn't exist yet.
    func testRenamingKeepsAKindToldByContent() async throws {
        let tree = try TempTree(self)
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "clip", withExtension: "ts", subdirectory: "Videos"))
        let recording = tree.root.appendingPathComponent("Recording.ts")
        try FileManager.default.copyItem(at: clip, to: recording)
        let m = makeModel()
        await openAndWait(m, tree.root)
        let entry = try XCTUnwrap(m.entries.first { $0.name == "Recording.ts" })
        XCTAssertEqual(entry.kind, .video)
        let renamed = try await m.rename(entry, to: "Holiday.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(m.entries.first { $0.name == "Holiday.ts" }?.kind, .video)

        func keeps(_ kind: GridEntry.Kind, _ old: String, _ new: String) -> Bool {
            BrowserModel.keepsKind(kind, renaming: URL(fileURLWithPath: "/x/" + old), to: URL(fileURLWithPath: "/x/" + new))
        }
        XCTAssertTrue(keeps(.image, "IMG_0001", "Beach"), "no extension before or after")
        XCTAssertTrue(keeps(.video, "clip.xyz", "film.XYZ"), "the same unknown ending")
        XCTAssertTrue(keeps(.image, "IMG_0001", "Beach.jpg"))
        XCTAssertTrue(keeps(.video, "a.mp4.part", "b.mp4.part"), "a download's final name")
        XCTAssertFalse(keeps(.image, "IMG_0001", "Beach.txt"))
        XCTAssertFalse(keeps(.image, "a.jpg", "a.mp4"), "another kind's extension")
        XCTAssertFalse(keeps(.video, "a.mkv", "a.ts"), "only a .ts that was one stays a video")
        XCTAssertFalse(keeps(.video, "a.ts", "a.txt"))
    }

    /// ".ts" by its content: a transport stream is a video, TypeScript is
    /// not; a file written anew is looked at again.
    func testATSFileIsAVideoOnlyWhenItIsATransportStream() throws {
        let tree = try TempTree(self)
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "clip", withExtension: "ts", subdirectory: "Videos"))
        let recording = try tree.file("Recording.ts")
        try FileManager.default.removeItem(at: recording)
        try FileManager.default.copyItem(at: clip, to: recording)
        XCTAssertEqual(BrowserModel.mediaKind(of: recording), .video)

        let code = try tree.file("main.ts")
        try Data("export const answer: number = 42;\n".utf8).write(to: code)
        XCTAssertNil(BrowserModel.mediaKind(of: code))
        XCTAssertNil(BrowserModel.mediaKind(of: code), "the kept answer")
        try FileManager.default.removeItem(at: code)
        try FileManager.default.copyItem(at: clip, to: code)
        XCTAssertEqual(BrowserModel.mediaKind(of: code), .video, "written anew: read again")

        XCTAssertNil(BrowserModel.mediaKind(of: tree.root.appendingPathComponent("missing.ts")))
        XCTAssertNil(BrowserModel.mediaKind(of: URL(fileURLWithPath: tree.root.path + "/Holiday.zip/a.ts")), "inside an archive")
    }

    /// SVG is a picture like any other, drawn sharp at the size asked for.
    func testSVGIsAPictureDrawnAtAnySize() async throws {
        XCTAssertEqual(BrowserModel.mediaKind(of: URL(fileURLWithPath: "/x/logo.SVG")), .image)
        let tree = try TempTree(self)
        let svg = try tree.file("logo.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#ff0000"/></svg>"##.utf8).write(to: svg)
        let rendered = await VectorPicture.render(svg, longestSide: 1600)
        let (picture, size) = try XCTUnwrap(rendered)
        XCTAssertEqual(size, CGSize(width: 200, height: 100))
        XCTAssertEqual(picture.width, 1600)
        XCTAssertEqual(picture.height, 800)
        let stats = try XCTUnwrap(PictureStats.of(CIImage(cgImage: picture)))
        XCTAssertGreaterThan(stats.mean, 0.2, "drawn, not empty")
        let inspected = await MediaInfo.pixelSize(ofAnywhere: svg)
        XCTAssertEqual(inspected, CGSize(width: 200, height: 100), "the Inspector's resolution")
    }

    /// An SVG's tile and folder preview are a picture of it: QuickLook's,
    /// else drawn by the app as the full view draws it (QuickLook may answer
    /// with the icon or not at all). The test log says what QuickLook gave.
    func testAnSVGGetsAPictureAsItsThumbnail() async throws {
        let tree = try TempTree(self)
        let svg = try tree.file("A/B/logo.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#ff0000"/></svg>"##.utf8).write(to: svg)
        let request = QLThumbnailGenerator.Request(fileAt: svg, size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .all)
        let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        print("QuickLook for an SVG on macOS \(ProcessInfo.processInfo.operatingSystemVersionString): "
              + (rep.map { $0.type == .thumbnail ? "thumbnail" : $0.type == .icon ? "icon" : "low-quality thumbnail" } ?? "nothing"))

        let picture = await ThumbnailCache.pictureThumbnail(of: svg, side: 64)
        let drawn = try XCTUnwrap(picture, "drawn by the app")
        let pixels = try XCTUnwrap(drawn.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(max(pixels.width, pixels.height), Int(64 * NSScreen.mainBackingScale))
        let stats = try XCTUnwrap(PictureStats.of(CIImage(cgImage: pixels)))
        XCTAssertGreaterThan(stats.mean, 0.2, "drawn, not empty")

        let preview = await ThumbnailCache(megabytes: 8).thumbnail(for: svg, side: 64)
        XCTAssertNotNil(preview)
        XCTAssertNotEqual(preview?.accessibilityDescription, ThumbnailCache.fileIcon, "a picture, not the file's icon")
    }

    /// One rule for a folder tile: what the greying-out walk counts as media
    /// (blue), the previews' walk finds previews for, and the reverse.
    func testAFolderTileWithMediaFindsPreviewsAndTheWalksAgree() async throws {
        let tree = try TempTree(self)
        let layouts = ["svg2/B/a.svg", "svg3/B/C/a.svg", "jpg2/B/a.jpg", "jpg3/B/C/a.jpg", "video/B/C/D/E/clip.mp4",
                       "none/B/C/notes.txt", "hidden/.B/a.jpg", "pkg/Tool.app/Contents/a.jpg"]
        for path in layouts { try tree.file(path) }
        try tree.folder("empty/B/C")
        for name in ["svg2", "svg3", "jpg2", "jpg3", "video", "none", "hidden", "pkg", "empty"] {
            let folder = tree.root.appendingPathComponent(name)
            let previews = await BrowserModel.folderPreviewFiles(in: folder)
            let hasMedia = await BrowserModel.containsMedia(folder)
            XCTAssertEqual(hasMedia, !previews.isEmpty, name)
            XCTAssertEqual(previews.isEmpty, ["none", "hidden", "pkg", "empty"].contains(name), name)
        }
        for (name, file) in [("svg2", "a.svg"), ("svg3", "a.svg"), ("jpg2", "a.jpg"), ("jpg3", "a.jpg")] {
            let previews = await BrowserModel.folderPreviewFiles(in: tree.root.appendingPathComponent(name))
            XCTAssertEqual(previews.map(\.lastPathComponent), [file], name)
        }
    }

    /// A package (".app", ".photoslibrary") is one item to the user, as in
    /// the Finder: not listed as a folder, not walked by the slideshow or the
    /// search, the same as for the greyed-out check.
    func testPackagesAreNeitherFoldersNorWalked() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "Tool.app/Contents/Resources/inside.jpg", "sub/b.jpg"] { try tree.file(n) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names.filter { $0 != ".." }, ["sub", "a.jpg"])
        await searchAndWait(m, "inside")
        XCTAssertEqual(m.names, [])
        m.searchText = ""
        m.slideshowInterval = .seconds(60)
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.slideshow?.items.map(\.name), ["a.jpg", "b.jpg"])
    }

    /// A folder with media only in its subfolders previews those.
    func testFolderPreviewsLookIntoSubfolders() async throws {
        let tree = try TempTree(self)
        for n in ["trip/day1/a.jpg", "trip/day1/b.mp4", "trip/day2/c.jpg", "trip/day2/d.jpg"] { try tree.file(n) }
        let found = await BrowserModel.folderPreviewFiles(in: tree.root.appendingPathComponent("trip"))
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { BrowserModel.mediaKind(of: $0) != nil })
        try tree.file("top/x.png")
        try tree.file("top/sub/y.jpg")
        let top = await BrowserModel.folderPreviewFiles(in: tree.root.appendingPathComponent("top"))
        XCTAssertEqual(top.map(\.lastPathComponent), ["x.png"], "the folder's own first")
    }

    /// A folder holding only a folder holding the pictures previews them,
    /// at any depth, SVGs as well as JPEGs and PNGs.
    func testAFolderOfAFolderPreviewsThePicturesInside() async throws {
        let tree = try TempTree(self)
        try tree.file("A/B/a.jpg")
        try tree.file("A/B/b.png")
        try tree.file("Vectors/Inner/logo.svg")
        try tree.file("Deep/B/C/D/pic.svg")
        try tree.file("Deep/B/C/D/photo.jpg")
        let a = await BrowserModel.folderPreviewFiles(in: tree.root.appendingPathComponent("A"))
        XCTAssertEqual(Set(a.map(\.lastPathComponent)), ["a.jpg", "b.png"])
        let vectors = await BrowserModel.folderPreviewFiles(in: tree.root.appendingPathComponent("Vectors"))
        XCTAssertEqual(vectors.map(\.lastPathComponent), ["logo.svg"])
        let deep = await BrowserModel.folderPreviewFiles(in: tree.root.appendingPathComponent("Deep"))
        XCTAssertEqual(Set(deep.map(\.lastPathComponent)), ["pic.svg", "photo.jpg"])
        for folder in ["A", "Vectors", "Deep"] {
            let found = await FolderPreviewCache().containsMedia(tree.root.appendingPathComponent(folder))
            XCTAssertEqual(found, true, folder)
        }
    }

    /// The walk for the previews goes level by level: a large subtree with
    /// no pictures (a project's node_modules) doesn't use up the walk's
    /// limit before the folder beside it with pictures is reached.
    func testThePreviewWalkReachesShallowPicturesBeforeALargeSubtree() async throws {
        let tree = try TempTree(self)
        for i in 0..<60 { try tree.file("P/main/node_modules/pkg\(i / 10)/f\(i).js") }
        try tree.file("P/main/icons/logo.svg")
        try tree.file("P/main/.hidden/x.png")
        let root = tree.root.appendingPathComponent("P")
        var found: [String] = []
        let ending = FolderWalk(root: root, keys: [.isRegularFileKey], limit: 20, shown: false, appleDoubles: false, breadthFirst: true)
            .run { url in
                if BrowserModel.mediaKind(of: url) != nil { found.append(url.lastPathComponent) }
                return true
            }
        XCTAssertEqual(ending, .gaveUp)
        XCTAssertEqual(found, ["logo.svg"], "level 3 before the files at level 4; no hidden folder walked into")
        // Walked whole, level by level visits what the depth-first walk visits
        func visited(_ breadthFirst: Bool) -> Set<String> {
            var all: Set<String> = []
            FolderWalk(root: root, shown: false, breadthFirst: breadthFirst).run { all.insert($0.lastPathComponent); return true }
            return all
        }
        XCTAssertEqual(visited(true), visited(false))
        // main, node_modules, six packages, 60 files, icons, logo.svg
        XCTAssertEqual(visited(true).count, 70)
    }

    /// A preview listing made before the pictures arrived deeper down (the
    /// folder's own date stays the same) is let go once the folder is found
    /// to hold media, so the tile lists again and shows them.
    func testAnEmptyPreviewListingIsListedAgainWhenMediaTurnUpBelow() async throws {
        let tree = try TempTree(self)
        try tree.folder("A/B/C")
        let top = tree.root.appendingPathComponent("A")
        let cache = FolderPreviewCache()
        let before = await cache.files(in: top)
        XCTAssertEqual(before, [])
        let date = try XCTUnwrap(try top.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try tree.file("A/B/C/x.svg")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: top.path)
        let cached = await cache.files(in: top)
        XCTAssertEqual(cached, [], "the folder's own date is the same: the listing holds")
        let found = await cache.containsMedia(top)
        XCTAssertEqual(found, true)
        let again = await cache.files(in: top)
        XCTAssertEqual(again.map(\.lastPathComponent), ["x.svg"])
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

    /// Kept while the folder's date stays; listed again once it changes
    /// (a file added outside the app), checked at the next ask.
    func testFolderPreviewListFollowsTheFoldersDate() async throws {
        let tree = try TempTree(self)
        try tree.file("b.jpg")
        let cache = FolderPreviewCache(recheckAfter: 0)
        let first = await cache.files(in: tree.root)
        XCTAssertEqual(first.map(\.lastPathComponent), ["b.jpg"])
        let again = await cache.files(in: tree.root)
        XCTAssertEqual(again, first, "unchanged folder: kept")
        let found = await cache.containsMedia(tree.root)
        XCTAssertEqual(found, true)
        // A date the folder didn't have: as after a file arrived
        try tree.file("a.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: tree.root.path)
        let changed = await cache.files(in: tree.root)
        XCTAssertEqual(Set(changed.map(\.lastPathComponent)), ["a.jpg", "b.jpg"], "listed again")
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
        m.openHelp()
        XCTAssertFalse(m.showHelp, "the Help menu neither, during a rename")
        m.renameTarget = nil

        XCTAssertTrue(m.handleKey(.f1, command: false))
        XCTAssertFalse(m.beginRename(), "the Rename menu neither, over the help")
        XCTAssertNil(m.renameTarget)
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

/// The boss key comes back only on X typed three times in a row, each
/// within a second of the one before.
final class BossKeyTests: XCTestCase {
    /// The release puts back exactly what hiding changed: the windows it
    /// hid get their own alpha and mouse handling again (also when they
    /// were hidden once more on the way, as when the app is brought
    /// forward), a window it never hid keeps its own.
    @MainActor
    func testTheReleaseRestoresOnlyWhatHidingChanged() {
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let plain = window(), own = window(), later = window()
        own.alphaValue = 0.6
        own.ignoresMouseEvents = true
        var hidden = BossKey.HiddenWindows()
        hidden.hide([plain, own])
        for w in [plain, own] {
            XCTAssertEqual(w.alphaValue, 0)
            XCTAssertTrue(w.ignoresMouseEvents)
        }
        hidden.hide([plain, own])
        later.alphaValue = 0.8
        later.ignoresMouseEvents = true
        hidden.restore()
        XCTAssertEqual(plain.alphaValue, 1)
        XCTAssertFalse(plain.ignoresMouseEvents)
        XCTAssertEqual(own.alphaValue, 0.6, accuracy: 0.001, "its own alpha, not 1")
        XCTAssertTrue(own.ignoresMouseEvents, "it let clicks through before")
        XCTAssertEqual(later.alphaValue, 0.8, accuracy: 0.001, "never hidden: left alone")
        XCTAssertTrue(later.ignoresMouseEvents)
        hidden.restore()
        XCTAssertEqual(own.alphaValue, 0.6, accuracy: 0.001, "restored once")
    }

    func testThreeXInARowBringTheAppBack() {
        var c = BossKey.Counter()
        let t = Date()
        XCTAssertFalse(c.typed(x: true, at: t))
        XCTAssertFalse(c.typed(x: true, at: t + 0.3))
        XCTAssertTrue(c.typed(x: true, at: t + 0.6))
        XCTAssertFalse(c.typed(x: true, at: t + 1), "counting starts over")
        XCTAssertFalse(c.typed(x: false, at: t + 1.2), "another key")
        XCTAssertFalse(c.typed(x: true, at: t + 1.4))
        XCTAssertFalse(c.typed(x: true, at: t + 1.6))
        XCTAssertFalse(c.typed(x: true, at: t + 3), "too slow: one X again")
        XCTAssertFalse(c.typed(x: true, at: t + 3.5))
        XCTAssertTrue(c.typed(x: true, at: t + 4))
    }

    /// The keys as they come from the key monitor: the boss key as set, a
    /// key held down (its repeats) neither counting nor starting over, ⇧
    /// with the letter counting as the letter.
    @MainActor
    func testTheBossKeyAsTypedBringsTheAppBack() {
        let shortcuts = Shortcuts(defaults: makeTestDefaults())
        let x = KeyChord(.char("x")), shiftX = KeyChord(.char("x"), shift: true), y = KeyChord(.char("y"))
        let t = Date()
        var c = BossKey.Counter()
        XCTAssertFalse(c.typed(key: x, repeating: false, at: t, shortcuts: shortcuts))
        XCTAssertFalse(c.typed(key: x, repeating: true, at: t + 0.2, shortcuts: shortcuts), "held down a moment")
        XCTAssertFalse(c.typed(key: x, repeating: false, at: t + 0.4, shortcuts: shortcuts))
        XCTAssertTrue(c.typed(key: x, repeating: false, at: t + 0.6, shortcuts: shortcuts), "three X, the repeat in between left out")
        XCTAssertFalse(c.typed(key: shiftX, repeating: false, at: t + 2, shortcuts: shortcuts))
        XCTAssertFalse(c.typed(key: x, repeating: false, at: t + 2.3, shortcuts: shortcuts))
        XCTAssertTrue(c.typed(key: shiftX, repeating: false, at: t + 2.6, shortcuts: shortcuts), "⇧X counts as X")
        XCTAssertFalse(c.typed(key: x, repeating: false, at: t + 4, shortcuts: shortcuts))
        XCTAssertFalse(c.typed(key: y, repeating: false, at: t + 4.2, shortcuts: shortcuts))
        XCTAssertFalse(c.typed(key: x, repeating: false, at: t + 4.4, shortcuts: shortcuts))
        XCTAssertFalse(c.typed(key: nil, repeating: false, at: t + 4.5, shortcuts: shortcuts), "a key no shortcut can use")
        XCTAssertFalse(c.typed(key: x, repeating: false, at: t + 4.6, shortcuts: shortcuts), "another key started over")
        // The user's own boss key: B B B, X no longer
        shortcuts.assign(KeyChord(.char("b")), to: .bossKey, replacing: x)
        let b = KeyChord(.char("b"))
        XCTAssertFalse(c.typed(key: x, repeating: false, at: t + 6, shortcuts: shortcuts))
        XCTAssertFalse(c.typed(key: b, repeating: false, at: t + 6.2, shortcuts: shortcuts))
        XCTAssertFalse(c.typed(key: b, repeating: false, at: t + 6.4, shortcuts: shortcuts))
        XCTAssertTrue(c.typed(key: b, repeating: false, at: t + 6.6, shortcuts: shortcuts))
    }

    /// The first use explains the boss key once, with its key as set; UI
    /// tests see it only when they ask for it.
    @MainActor
    func testTheFirstUseIsExplainedOnce() {
        let defaults = makeTestDefaults()
        XCTAssertTrue(BossKey.needsExplaining(defaults: defaults, testing: false, asked: false))
        XCTAssertFalse(BossKey.needsExplaining(defaults: defaults, testing: true, asked: false), "UI tests aren't held up")
        XCTAssertTrue(BossKey.needsExplaining(defaults: defaults, testing: true, asked: true))
        defaults.set(true, forKey: BossKey.explainedKey)
        XCTAssertFalse(BossKey.needsExplaining(defaults: defaults, testing: false, asked: false), "never again")
        let shortcuts = Shortcuts(defaults: makeTestDefaults())
        XCTAssertTrue(BossKey.explanation(shortcuts).contains("press X three times"))
        shortcuts.assign(KeyChord(.char("b")), to: .bossKey, replacing: KeyChord(.char("x")))
        XCTAssertTrue(BossKey.explanation(shortcuts).contains("press B three times"))
    }

    /// F1 lists the boss key on (its key) and off (its key three times),
    /// following the user's key.
    @MainActor
    func testTheHelpListsTheBossKeyOnAndOff() {
        let shortcuts = Shortcuts(defaults: makeTestDefaults())
        func row(_ prefix: String) -> HelpShortcut? {
            ShortcutsHelpView.groups(shortcuts).flatMap(\.shortcuts).first { $0.action.hasPrefix(prefix) }
        }
        XCTAssertEqual(row("Boss key on:")?.keys, "X")
        XCTAssertEqual(row("Boss key off:")?.keys, "X X X")
        shortcuts.assign(KeyChord(.char("b")), to: .bossKey, replacing: KeyChord(.char("x")))
        XCTAssertEqual(row("Boss key on:")?.keys, "B")
        XCTAssertEqual(row("Boss key off:")?.keys, "B B B")
    }
}

/// Folder bookmarks: set and removed by the same action, remembered, they
/// follow a rename the app makes, and two of the same name tell their folders.
@MainActor
final class BookmarkTests: XCTestCase {
    func testBookmarksToggleRememberAndFollowARename() async throws {
        let tree = try TempTree(self)
        let a = try tree.folder("Photos/Holiday")
        let b = try tree.folder("Videos/Holiday")
        try tree.file("Photos/Holiday/x.jpg")
        let defaults = makeTestDefaults()
        let bookmarks = Bookmarks(defaults: defaults)
        bookmarks.toggle(a)
        bookmarks.toggle(b)
        XCTAssertTrue(bookmarks.contains(a))
        XCTAssertEqual(bookmarks.folders.map(bookmarks.title(of:)), ["Photos/Holiday", "Videos/Holiday"])
        bookmarks.toggle(b)
        XCTAssertFalse(bookmarks.contains(b))
        XCTAssertEqual(bookmarks.folders.map(bookmarks.title(of:)), ["Holiday"])
        XCTAssertEqual(Bookmarks(defaults: defaults).folders.count, 1, "remembered")

        let renamed = tree.root.appendingPathComponent("Photos/Summer")
        bookmarks.follow([.moved(a, to: renamed)])
        XCTAssertTrue(bookmarks.contains(renamed))
        XCTAssertFalse(bookmarks.contains(a))
        XCTAssertTrue(Bookmarks(defaults: defaults).contains(renamed), "saved")
    }

    /// Each folder is bookmarked once (the menus tell bookmarks by their
    /// folder): saved twice, or two that follow a move to one folder, are one.
    func testBookmarksStayOnePerFolder() throws {
        let tree = try TempTree(self)
        let a = try tree.folder("A")
        let gone = tree.root.appendingPathComponent("B")
        let defaults = makeTestDefaults()
        defaults.set([gone.path, a.path, gone.path + "/", a.path], forKey: Bookmarks.key)
        let bookmarks = Bookmarks(defaults: defaults)
        XCTAssertEqual(bookmarks.folders.map(\.lastPathComponent), ["B", "A"])
        bookmarks.follow([.moved(a, to: gone)])
        XCTAssertEqual(bookmarks.folders.map(\.lastPathComponent), ["B"])
        XCTAssertEqual(Bookmarks(defaults: defaults).folders.count, 1, "saved")
        bookmarks.toggle(a)
        bookmarks.toggle(URL(fileURLWithPath: a.path + "/"))
        XCTAssertEqual(bookmarks.folders.map(\.lastPathComponent), ["B"], "the same folder: toggled off again")
    }
}


/// Undo and redo of renames, trashing and moves, as often as wanted.
@MainActor
final class UndoTests: XCTestCase {
    func testRenameTrashAndMoveAreUndoneAndRedone() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.file("b.jpg")
        let sorted = try tree.folder("Sorted")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: tree.root.appendingPathComponent(path).path) }

        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.beginRename())
        try await m.rename(try XCTUnwrap(m.renameTarget), to: "c.jpg")
        m.selectEntry(named: "b.jpg")
        m.moveSelectionToTrash()
        XCTAssertFalse(exists("b.jpg"))
        m.move([tree.root.appendingPathComponent("c.jpg")], into: sorted)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertTrue(exists("Sorted/c.jpg"))
        XCTAssertEqual(m.undoHistory.undoSteps.map(\.kind), [.rename, .trash, .move])

        m.undo()   // the move
        await waitUntil { exists("c.jpg") && !m.isLoading && m.names.contains("c.jpg") }
        XCTAssertFalse(exists("Sorted/c.jpg"))
        m.undo()   // the trash
        await waitUntil { exists("b.jpg") && m.names.contains("b.jpg") }
        m.undo()   // the rename
        await waitUntil { exists("a.jpg") && m.names.contains("a.jpg") }
        XCTAssertFalse(exists("c.jpg"))
        XCTAssertTrue(m.undoHistory.undoSteps.isEmpty)
        XCTAssertEqual(m.undoHistory.redoSteps.map(\.kind), [.move, .trash, .rename])

        m.redo()   // the rename
        await waitUntil { exists("c.jpg") && m.names.contains("c.jpg") }
        m.redo()   // the trash
        await waitUntil { !exists("b.jpg") && !m.names.contains("b.jpg") }
        m.redo()   // the move
        await waitUntil { exists("Sorted/c.jpg") && !m.isLoading }
        XCTAssertEqual(m.names, ["..", "Sorted"])
        XCTAssertTrue(m.undoHistory.redoSteps.isEmpty)

        m.undo()
        await waitUntil { exists("c.jpg") && !m.isLoading && m.names.contains("c.jpg") }
        // Something new: what was undone can't be redone any more
        m.selectEntry(named: "c.jpg")
        XCTAssertTrue(m.beginRename())
        try await m.rename(try XCTUnwrap(m.renameTarget), to: "d.jpg")
        XCTAssertTrue(m.undoHistory.redoSteps.isEmpty)
    }

    /// A move to another volume whose original could be removed only in
    /// part: the copy is the only whole one, so there is no Undo Copy that
    /// would move it to the Trash; what happened is reported.
    func testACopyWhoseOriginalWasPartlyRemovedGetsNoUndo() async throws {
        let tree = try TempTree(self)
        try tree.file("Trip/a.jpg")
        let target = try tree.folder("Elsewhere")
        let spy = FileActionsSpy()
        spy.moveError = TransferError.originalPartlyRemoved("“a.jpg” is locked.")
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.move([tree.root.appendingPathComponent("Trip")], into: target, how: .move)
        await waitUntil { m.transfersRunning == 0 && !spy.reported.isEmpty }
        XCTAssertTrue(m.undoHistory.undoSteps.isEmpty, "no Undo for it")
        let reasons = (spy.reported.first as? TransferFailure)?.failures.map(\.reason) ?? []
        XCTAssertEqual(reasons, [TransferError.originalPartlyRemoved("“a.jpg” is locked.").localizedDescription])
        XCTAssertTrue(m.names.contains("Trip"), "what is left of the original stays listed")
    }

    /// Redo of a Move to Trash on a volume that doesn't say where the item
    /// went: it is in the Trash, it leaves the list, no error; it has no
    /// Undo then, as when trashed the first time.
    func testRedoOfATrashWithoutItsPlaceInTheTrash() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.file("b.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "b.jpg")
        m.moveSelectionToTrash()
        await waitUntil { !m.names.contains("b.jpg") }
        m.undo()
        await waitUntil { m.names.contains("b.jpg") && !m.undoHistory.running }
        spy.trashGivesNoPlace = true
        m.redo()
        await waitUntil { !m.names.contains("b.jpg") && !m.undoHistory.running }
        XCTAssertTrue(spy.reported.isEmpty, "\(spy.reported)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("b.jpg").path))
        XCTAssertTrue(m.undoHistory.redoSteps.isEmpty)
        XCTAssertTrue(m.undoHistory.undoSteps.isEmpty)
    }

    /// Every way to the Trash asks first: ⌘⌫ on one item and on marked
    /// ones, an other file's Move to Trash, Undo Copy, Undo New Folder and
    /// Redo Move to Trash. A no trashes nothing, and an Undo or Redo asked
    /// for stays where it was.
    func testEveryWayToTheTrashAsksFirst() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg", "notes.txt"] { try tree.file(n) }
        let target = try tree.folder("Sorted")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: tree.root.appendingPathComponent(path).path) }

        // The steps to undo: a copy, a new folder, a trash undone (to redo)
        m.move([tree.root.appendingPathComponent("a.jpg")], into: target, how: .copy)
        await waitUntil { m.transfersRunning == 0 && exists("Sorted/a.jpg") }
        m.newFolderRequested = true
        _ = try await m.createFolder(named: "New")
        m.selectEntry(named: "b.jpg")
        m.moveSelectionToTrash()
        await waitUntil { !exists("b.jpg") }
        XCTAssertEqual(spy.confirmNames.last, ["b.jpg"])
        m.undo()
        await waitUntil { exists("b.jpg") && !m.undoHistory.running }
        XCTAssertEqual(m.undoHistory.undoSteps.map(\.kind), [.copy, .newFolder])
        XCTAssertEqual(m.undoHistory.redoSteps.map(\.kind), [.trash])
        spy.trashed = []
        spy.confirmNames = []

        // No to every question
        spy.confirm = false
        m.redo()
        XCTAssertEqual(spy.confirmNames.last, ["b.jpg"], "Redo Move to Trash asks")
        m.undo()
        XCTAssertEqual(spy.confirmNames.last, ["New"], "Undo New Folder asks")
        XCTAssertEqual(m.undoHistory.undoSteps.map(\.kind), [.copy, .newFolder], "a no leaves the step where it was")
        XCTAssertEqual(m.undoHistory.redoSteps.map(\.kind), [.trash])
        await waitUntil { !m.isLoading && m.names.contains("c.jpg") }
        m.selectEntry(named: "c.jpg")
        m.moveSelectionToTrash()
        await waitUntil { spy.confirmNames.last == ["c.jpg"] }
        m.click(try XCTUnwrap(m.entries.first { $0.name == "a.jpg" }), command: true, shift: false)
        m.click(try XCTUnwrap(m.entries.first { $0.name == "b.jpg" }), command: true, shift: false)
        m.moveSelectionToTrash()
        XCTAssertEqual(Set(spy.confirmNames.last ?? []), ["a.jpg", "b.jpg", "c.jpg"], "the marked ones, asked together")
        m.moveToTrash(try XCTUnwrap(m.otherFiles.first { $0.name == "notes.txt" }))
        XCTAssertEqual(spy.confirmNames.last, ["notes.txt"])
        XCTAssertEqual(spy.trashed, [], "nothing trashed")
        for path in ["a.jpg", "b.jpg", "c.jpg", "notes.txt", "New", "Sorted/a.jpg"] { XCTAssertTrue(exists(path), path) }

        // Yes: Undo New Folder and Undo Copy ask, then trash
        spy.confirm = true
        m.undo()
        await waitUntil { !exists("New") && !m.undoHistory.running }
        XCTAssertEqual(spy.confirmNames.last, ["New"])
        m.undo()
        await waitUntil { !exists("Sorted/a.jpg") && !m.undoHistory.running }
        XCTAssertEqual(spy.confirmNames.last, ["a.jpg"], "Undo Copy names the copy")
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["New", "a.jpg"])
        XCTAssertTrue(exists("a.jpg"), "the original stays")
    }

    /// The name was taken meanwhile: nothing is overwritten, it is reported.
    func testUndoNeverOverwrites() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.beginRename())
        try await m.rename(try XCTUnwrap(m.renameTarget), to: "b.jpg")
        try tree.file("a.jpg")   // someone else took the old name
        m.undo()
        await waitUntil { !spy.reported.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("b.jpg").path))
        XCTAssertEqual(m.undoHistory.undoSteps.count, 1, "still there to try again")
    }

    /// A step that fails can be forgotten: the next Undo reaches the one before.
    func testAFailedStepForgottenLetsUndoReachTheOlderOnes() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.file("c.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(m.beginRename())
        try await m.rename(try XCTUnwrap(m.renameTarget), to: "b.jpg")
        m.selectEntry(named: "c.jpg")
        XCTAssertTrue(m.beginRename())
        try await m.rename(try XCTUnwrap(m.renameTarget), to: "d.jpg")
        try tree.file("c.jpg")   // someone else took the old name
        spy.keepFailedUndo = false
        m.undo()
        await waitUntil { !spy.reported.isEmpty }
        XCTAssertEqual(m.undoHistory.undoSteps.count, 1, "forgotten")
        m.undo()
        await waitUntil { FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("a.jpg").path) }
        XCTAssertFalse(m.undoHistory.running)
    }

    /// Undo Copy trashes only the copy it made: not another file that took
    /// its name, not a copied folder something was put into since.
    func testUndoCopyTrashesOnlyTheCopyItMade() async throws {
        let tree = try TempTree(self)
        try tree.file("src/a.jpg")
        try tree.file("src/trip/x.jpg")
        let sorted = try tree.folder("Sorted")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root.appendingPathComponent("src"))
        m.move([tree.root.appendingPathComponent("src/a.jpg")], into: sorted, how: .copy)
        await waitUntil { m.transfersRunning == 0 }
        let copy = sorted.appendingPathComponent("a.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        try FileManager.default.removeItem(at: copy)
        try tree.file("Sorted/a.jpg", bytes: 3)   // another file under the copy's name
        m.undo()
        await waitUntil { !spy.reported.isEmpty }
        XCTAssertTrue(spy.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

        spy.reported = []
        spy.keepFailedUndo = false
        m.undo()   // the failed step is kept on top: forget it
        await waitUntil { !spy.reported.isEmpty }
        m.move([tree.root.appendingPathComponent("src/trip")], into: sorted, how: .copy)
        await waitUntil { m.transfersRunning == 0 }
        try tree.file("Sorted/trip/added later.jpg")
        spy.reported = []
        m.undo()
        await waitUntil { !spy.reported.isEmpty }
        XCTAssertTrue(spy.trashed.isEmpty, "the folder holds something it didn't when copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sorted.appendingPathComponent("trip/added later.jpg").path))
    }

    /// New Folder: Undo moves the folder made to the Trash, Redo makes it
    /// again; a folder something was put into since stays.
    func testNewFolderIsUndoneAndRedoneOnlyWhileEmpty() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        XCTAssertTrue(m.beginNewFolder())
        let made = try await m.createFolder(named: "Sorted")
        XCTAssertEqual(m.undoHistory.undoSteps.map(\.kind), [.newFolder])
        try Data().write(to: made.appendingPathComponent(".DS_Store"))   // the Finder looked at it
        m.undo()
        await waitUntil { !FileManager.default.fileExists(atPath: made.path) && !m.names.contains("Sorted") }
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["Sorted"])
        XCTAssertEqual(m.undoHistory.redoSteps.map(\.kind), [.newFolder])
        m.redo()
        await waitUntil { FileManager.default.fileExists(atPath: made.path) && m.names.contains("Sorted") }

        try tree.file("Sorted/._b.jpg")   // an AppleDouble file, which FileManager doesn't list
        spy.keepFailedUndo = false
        m.undo()
        await waitUntil { !spy.reported.isEmpty }
        XCTAssertEqual((spy.reported.first as? UndoError)?.errorDescription,
                       UndoError.filled("Sorted").errorDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("Sorted/._b.jpg").path))
        XCTAssertEqual(spy.trashed.count, 1, "not trashed a second time")
    }

    /// Undo Move to Trash that can't be carried out leaves the item in the
    /// Trash and says so: the name taken meanwhile, the Trash emptied.
    func testAFailedUndoOfTheTrashLeavesTheItemInTheTrash() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.file("b.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        func inTrash() throws -> URL {
            guard case .trashed(_, let url, _)? = m.undoHistory.undoSteps.last?.parts.first else { throw CocoaError(.fileNoSuchFile) }
            return url
        }
        m.selectEntry(named: "a.jpg")
        m.moveSelectionToTrash()
        let aInTrash = try inTrash()
        try tree.file("a.jpg", bytes: 7)   // another file under its name
        m.undo()
        await waitUntil { !spy.reported.isEmpty }
        guard case .stillInTrash(let name, _)? = spy.reported.first as? UndoError else { return XCTFail("\(spy.reported)") }
        XCTAssertEqual(name, "a.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aInTrash.path), "still in the Trash")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: tree.root.appendingPathComponent("a.jpg").path)[.size] as? Int, 7,
                       "the other file is untouched")
        XCTAssertEqual(m.undoHistory.undoSteps.count, 1, "kept to try again")

        spy.reported = []
        spy.keepFailedUndo = false
        m.undo()   // forgotten
        await waitUntil { !spy.reported.isEmpty }
        m.selectEntry(named: "b.jpg")
        m.moveSelectionToTrash()
        try FileManager.default.removeItem(at: try inTrash())   // the Trash emptied
        spy.reported = []
        m.undo()
        await waitUntil { !spy.reported.isEmpty }
        guard case .goneFromTrash(let gone)? = spy.reported.first as? UndoError else { return XCTFail("\(spy.reported)") }
        XCTAssertEqual(gone, "b.jpg")
        XCTAssertFalse(m.undoHistory.running)
    }

    /// A second ⌘⌫ while a trash is still under way (a slow share) asks
    /// nothing and trashes nothing again; one Undo step for the items.
    func testASecondTrashWhileOneRunsLeavesTheItemsAlone() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        try tree.file("b.jpg")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")
        var canTrashMeanwhile: Bool?
        spy.duringTrash = {
            canTrashMeanwhile = m.canTrash
            m.moveSelectionToTrash()
        }
        m.moveSelectionToTrash()
        await waitUntil { !m.names.contains("a.jpg") }
        XCTAssertEqual(canTrashMeanwhile, false, "the menu item is off while it goes")
        XCTAssertEqual(spy.confirmNames, [["a.jpg"]], "asked once")
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertTrue(spy.reported.isEmpty)
        XCTAssertEqual(m.undoHistory.undoSteps.count, 1)
        m.selectEntry(named: "b.jpg")
        XCTAssertTrue(m.canTrash, "free again once done")
    }

    /// A second ⌘⌫ (or the menu) while the item's parts are still looked up
    /// off the main thread, before the prompt: asked once. (The prompt is
    /// answered No, so nothing reaches the real Trash.)
    func testASecondTrashDuringThePartsLookupAsksOnce() async throws {
        let tree = try TempTree(self)
        try tree.file("x.part1.rar", bytes: 10)
        try tree.file("x.part2.rar", bytes: 10)
        let spy = FileActionsSpy()
        spy.confirm = false
        var actions = spy.actions
        actions.runsOffMain = true
        let m = BrowserModel(defaults: makeTestDefaults(), fileActions: actions)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "x.part1.rar")
        XCTAssertTrue(m.canTrash)
        m.moveSelectionToTrash()
        XCTAssertTrue(m.trashLookupPending, "looked up off the main thread")
        XCTAssertFalse(m.canTrash, "the menu item is off while it is looked up")
        m.moveSelectionToTrash()
        await waitUntil { !m.trashLookupPending }
        XCTAssertEqual(spy.confirmNames, [["x.part1.rar"]], "asked once")
        XCTAssertEqual(spy.confirmDetails.count, 1)
        XCTAssertTrue(spy.trashed.isEmpty)
        XCTAssertTrue(m.canTrash, "free again once answered")
    }

    /// ⌘Z and ⇧⌘Z are told apart from other keys (⌥, ⌃, other letters).
    func testTheUndoKeys() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 6) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(ContentView.isUndoKey(try key("z", .command)))
        XCTAssertTrue(ContentView.isUndoKey(try key("Z", [.command, .shift])))
        XCTAssertFalse(ContentView.isUndoKey(try key("z", [])))
        XCTAssertFalse(ContentView.isUndoKey(try key("z", [.command, .option])))
        XCTAssertFalse(ContentView.isUndoKey(try key("z", [.command, .control])))
        XCTAssertFalse(ContentView.isUndoKey(try key("y", .command, code: 16)))
    }

    /// The folder shown renamed from the title bar: undone like any rename;
    /// its other files stay listed through the rename.
    func testRenamingTheFolderShownKeepsItsOtherFilesAndIsUndone() async throws {
        let tree = try TempTree(self)
        try tree.file("Trip/a.jpg")
        try tree.file("Trip/notes.txt")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, tree.root.appendingPathComponent("Trip"))
        XCTAssertEqual(m.otherFiles.map(\.name), ["notes.txt"])
        await m.renameCurrentFolder(to: "Travel")
        XCTAssertEqual(m.folderURL?.lastPathComponent, "Travel")
        XCTAssertEqual(m.otherFiles.map(\.name), ["notes.txt"])
        XCTAssertEqual(m.undoHistory.undoSteps.map(\.kind), [.rename])
        m.undo()
        await waitUntil { m.folderURL?.lastPathComponent == "Trip" && !m.isLoading }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("Trip/notes.txt").path))
        XCTAssertEqual(m.names, ["..", "a.jpg"])
    }
}

/// Copies and moves never leave a cut-off file under the real name, and a
/// move that fails half way keeps what it did.
@MainActor
final class SafeTransferTests: XCTestCase {
    /// A case-only rename is one step of the system's rename: nothing under
    /// a temporary name; quitting waits for a rename under way.
    func testACaseOnlyRenameLeavesNothingBehind() async throws {
        let tree = try TempTree(self)
        try tree.file("photos/a.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        let entry = try XCTUnwrap(m.entries.first { $0.name == "photos" })
        var waitedFor = false
        let saved = BrowserModel.onTransfersDone
        BrowserModel.onTransfersDone = { waitedFor = true }
        defer { BrowserModel.onTransfersDone = saved }
        let renames = Locked<[(to: String, result: Int32)]>([])
        let system = LiveFiles.systemRename
        LiveFiles.systemRename = { from, to, flags in
            let result = system(from, to, flags)
            renames.withLock { $0.append(((to as NSString).lastPathComponent, result)) }
            return result
        }
        defer { LiveFiles.systemRename = system }
        try await m.rename(entry, to: "Photos")
        XCTAssertTrue(waitedFor, "counted among the transfers quitting waits for")
        XCTAssertEqual(renames.withLock { $0.map(\.to) }, ["Photos"], "the system's rename, straight to the new name")
        XCTAssertEqual(renames.withLock { $0.map(\.result) }, [0], "done in that one step")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tree.root.path), ["Photos"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tree.root.appendingPathComponent("Photos").path), ["a.jpg"])
    }

    /// A volume that renames in no single step: the item goes by a hidden
    /// name carrying the new one, and ends under the new name with nothing
    /// else left.
    func testACaseOnlyRenameOnAVolumeWithoutTheSystemsRename() throws {
        let tree = try TempTree(self)
        try tree.file("photos/a.jpg")
        let system = LiveFiles.systemRename
        LiveFiles.systemRename = { _, _, _ in errno = ENOTSUP; return -1 }
        defer { LiveFiles.systemRename = system }
        let copyItem = LiveFiles.copyItem
        LiveFiles.copyItem = { _, _ in XCTFail("a rename copies nothing") }
        defer { LiveFiles.copyItem = copyItem }
        try LiveFiles.move(tree.root.appendingPathComponent("photos"), tree.root.appendingPathComponent("Photos"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tree.root.path), ["Photos"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tree.root.appendingPathComponent("Photos").path), ["a.jpg"])
    }

    /// An item left under a case-only rename's temporary name gets the name
    /// it carries, once it has rested; a listing does that.
    func testARenameLeftoverIsPutBack() async throws {
        let tree = try TempTree(self)
        let name = LiveFiles.renameTemporaryName(for: "Photos")
        XCTAssertEqual(LiveFiles.renameLeftoverTarget(name), "Photos")
        XCTAssertNil(LiveFiles.renameLeftoverTarget(LiveFiles.renamePrefix + "not-a-uuid-Photos"))
        XCTAssertNil(LiveFiles.renameLeftoverTarget(".rename-x"))
        XCTAssertEqual(LiveFiles.renameTemporaryName(for: String(repeating: "x", count: 240)).count, LiveFiles.renamePrefix.count + 36,
                       "too long to carry the name")
        let leftover = try tree.folder(name)
        try tree.file(name + "/a.jpg")
        XCTAssertNil(LiveFiles.restoreIfLeftOver(leftover), "just changed: another Mac may be renaming it")
        let restored = try XCTUnwrap(LiveFiles.restoreIfLeftOver(leftover, settled: 0))
        XCTAssertEqual(restored.lastPathComponent, "Photos")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("a.jpg").path))
        let again = try tree.folder(LiveFiles.renameTemporaryName(for: "Photos"))
        XCTAssertNil(LiveFiles.restoreIfLeftOver(again, settled: 0), "never over a name taken")
        // A file onto a file: the system's plain rename would replace it
        let notes = tree.root.appendingPathComponent("notes.txt")
        try Data("kept".utf8).write(to: notes)
        let leftoverFile = tree.root.appendingPathComponent(LiveFiles.renameTemporaryName(for: "notes.txt"))
        try Data("leftover".utf8).write(to: leftoverFile)
        XCTAssertNil(LiveFiles.restoreIfLeftOver(leftoverFile, settled: 0), "never over a file taken")
        XCTAssertEqual(try Data(contentsOf: notes), Data("kept".utf8))
        XCTAssertEqual(try Data(contentsOf: leftoverFile), Data("leftover".utf8))
    }

    func testACopyIsWrittenUnderATemporaryNameAndLeftoversAreSwept() async throws {
        let tree = try TempTree(self)
        let source = try tree.file("a.jpg", bytes: 100)
        let target = try tree.folder("Sorted")
        // While it is written: under the hidden name only, known as under way
        var written: [URL] = []
        let copyItem = LiveFiles.copyItem
        defer { LiveFiles.copyItem = copyItem }
        LiveFiles.copyItem = { from, to in
            written.append(to)
            XCTAssertTrue(LiveFiles.isPartialCopy(to.lastPathComponent), "written under a temporary name, not \(to.lastPathComponent)")
            XCTAssertEqual(to.deletingLastPathComponent().standardizedFileURL, target.standardizedFileURL, "in the target folder")
            XCTAssertTrue(PartialCopies.shared.isRunning(to), "a listing meanwhile leaves it alone")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.jpg").path), "nothing under the real name yet")
            try copyItem(from, to)
        }
        try LiveFiles.copy(source, target.appendingPathComponent("a.jpg"))
        LiveFiles.copyItem = copyItem
        XCTAssertEqual(written.count, 1)
        XCTAssertFalse(written.first.map(PartialCopies.shared.isRunning) ?? true, "not under way once renamed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["a.jpg"], "nothing left under a temporary name")
        XCTAssertThrowsError(try LiveFiles.copy(source, target.appendingPathComponent("a.jpg")), "never over a name taken")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["a.jpg"])
        // A copy that fails half way (a file it can't read): nothing under
        // the real name, nothing under the temporary one
        try tree.file("album/1.jpg", bytes: 100)
        let unreadable = try tree.file("album/2.jpg", bytes: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        XCTAssertThrowsError(try LiveFiles.copy(tree.root.appendingPathComponent("album"), target.appendingPathComponent("album")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["a.jpg"], "no cut-off copy left")

        let old = target.appendingPathComponent(LiveFiles.partialCopyPrefix + UUID().uuidString)
        let fresh = target.appendingPathComponent(LiveFiles.partialCopyPrefix + UUID().uuidString)
        let alike = target.appendingPathComponent(LiveFiles.partialCopyPrefix + "mine")
        for url in [old, fresh, alike] { try Data(count: 5).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86400)], ofItemAtPath: alike.path)
        // One this process is writing stays, however old
        let running = target.appendingPathComponent(LiveFiles.partialCopyPrefix + UUID().uuidString)
        try Data(count: 5).write(to: running)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86400)], ofItemAtPath: running.path)
        PartialCopies.shared.begin(running)
        XCTAssertFalse(LiveFiles.removeIfLeftOver(running), "a copy under way")
        PartialCopies.shared.end(running)
        XCTAssertTrue(LiveFiles.removeIfLeftOver(running))
        let m = makeModel()
        await openAndWait(m, target)
        XCTAssertEqual(m.names, ["..", "a.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a leftover is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "one written lately may be another Mac's copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alike.path), "only the exact pattern")
    }

    /// A split archive whose second part can't go: the first part's move
    /// counts (its tile leaves, Undo brings it back), the failure is named.
    func testAMoveThatFailsHalfWayKeepsWhatItDid() async throws {
        let tree = try TempTree(self)
        try tree.file("src/x.part1.rar", bytes: 10)
        try tree.file("src/x.part2.rar", bytes: 10)
        try tree.file("src/b.jpg")
        let target = try tree.folder("Sorted")
        let spy = FileActionsSpy()
        spy.failOn = ["x.part2.rar"]
        let m = makeModel(spy)
        let src = tree.root.appendingPathComponent("src")
        await openAndWait(m, src)
        m.move([src.appendingPathComponent("x.part1.rar"), src.appendingPathComponent("b.jpg")], into: target, how: .move)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("x.part1.rar").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("b.jpg").path))
        XCTAssertEqual(m.names, [".."], "what moved left the listing")
        let failure = try XCTUnwrap(spy.reported.first as? TransferFailure)
        XCTAssertEqual(failure.failures.map(\.name), ["x.part2.rar"])
        XCTAssertEqual(m.undoHistory.undoSteps.last?.parts.count, 2, "the first part and b.jpg")
    }

    /// "Apply to all" answers every taken name at once; Cancel stops the whole move.
    func testKeepBothForAllAndCancel() async throws {
        let tree = try TempTree(self)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file("src/\(name)") }
        try tree.file("Sorted/a.jpg")
        try tree.file("Sorted/b.jpg")
        let target = tree.root.appendingPathComponent("Sorted")
        let src = tree.root.appendingPathComponent("src")
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, src)
        let all = ["a.jpg", "b.jpg", "c.jpg"].map { src.appendingPathComponent($0) }
        spy.conflictAnswer = ConflictAnswer(choice: .cancel)
        m.move(all, into: target, how: .copy)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertEqual(spy.keepBothAsked, 1)
        XCTAssertTrue(spy.copied.isEmpty, "nothing, not even the name that was free")

        spy.keepBothAsked = 0
        spy.conflictAnswer = ConflictAnswer(choice: .keepBoth, forAll: true)
        m.move(all, into: target, how: .copy)
        await waitUntil { m.transfersRunning == 0 }
        XCTAssertEqual(spy.keepBothAsked, 1, "asked once")
        for name in ["a 2.jpg", "b 2.jpg", "c.jpg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path), name)
        }
    }
}

/// Other files open only when they hold no program; a web location only
/// to a web address.
final class OpenOtherFileTests: XCTestCase {
    func testOnlyDocumentsAndWebAddressesOpen() throws {
        let tree = try TempTree(self)
        func webloc(_ name: String, _ address: String) throws -> URL {
            let url = tree.root.appendingPathComponent(name)
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": address], format: .xml, options: 0)
            try data.write(to: url)
            return url
        }
        func text(_ name: String, _ content: String) throws -> URL {
            let url = tree.root.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        XCTAssertEqual(LiveFiles.webAddress(in: try webloc("site.webloc", "https://example.com/a"))?.absoluteString, "https://example.com/a")
        XCTAssertNil(LiveFiles.webAddress(in: try webloc("app.webloc", "file:///System/Applications/Calculator.app")))
        XCTAssertNil(LiveFiles.webAddress(in: try webloc("scheme.webloc", "x-apple.systempreferences:com.apple.preference.security")))
        XCTAssertEqual(LiveFiles.webAddress(in: try text("site.url", "[InternetShortcut]\r\nURL=http://example.org/\r\n"))?.host, "example.org")
        XCTAssertNil(LiveFiles.webAddress(in: try text("bad.url", "[InternetShortcut]\nURL=smb://server/share\n")))
        XCTAssertFalse(LiveFiles.canOpenOtherFile(try webloc("app2.webloc", "file:///Applications/")))

        XCTAssertTrue(LiveFiles.canOpenOtherFile(try text("notes.txt", "hello")))
        XCTAssertTrue(LiveFiles.canOpenOtherFile(try text("data.csv", "a,b")))
        for name in ["run.command", "run.sh", "tool.scpt", "setup.pkg", "disk.dmg", "x.terminal"] {
            XCTAssertFalse(LiveFiles.canOpenOtherFile(try text(name, "#!/bin/sh\necho hi\n")), name)
        }
        // Web content would open in a browser: its scripts run, it loads from the network
        for name in ["page.html", "page.htm", "page.xhtml", "saved.webarchive", "drawing.svg", "archive.mhtml"] {
            XCTAssertFalse(LiveFiles.canOpenOtherFile(try text(name, "<html><script>alert(1)</script></html>")), name)
        }
        let app = try tree.folder("Fake.app/Contents/MacOS")
        XCTAssertFalse(LiveFiles.canOpenOtherFile(app.deletingLastPathComponent().deletingLastPathComponent()))
        // A link named like a document, pointing to a script
        let script = try text("evil.command", "#!/bin/sh\n")
        let link = tree.root.appendingPathComponent("readme.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        XCTAssertFalse(LiveFiles.canOpenOtherFile(link))
    }
}

/// A search's walk tells the folder tiles what it saw: whether a found folder
/// holds media and its first pictures (as the tile would look them up), so
/// the tiles needn't walk the same folders again over the network.
final class FolderFactsTests: XCTestCase {
    func testTheWalkLearnsWhatTheFolderTilesNeed() async throws {
        let tree = try TempTree(self)
        for name in ["d.jpg", "b.jpg", "a.jpg", "c.jpg"] { try tree.file("trip-top/\(name)") }
        try tree.file("trip-deep/day/x.jpg")
        try tree.file("trip-none/notes.txt")
        try tree.folder("other")
        var learnt = FolderFacts.Learnt()
        for await batch in BrowserModel.recursiveMatches(under: tree.root, query: "trip") {
            learnt.withMedia += batch.facts.withMedia
            learnt.previews.merge(batch.facts.previews) { $1 }
            learnt.withoutMedia += batch.facts.withoutMedia
        }
        func name(_ urls: [URL]?) -> [String] { (urls ?? []).map(\.lastPathComponent) }
        func previews(_ folder: String) -> [String] {
            name(learnt.previews.first { $0.key.lastPathComponent == folder }?.value)
        }
        XCTAssertEqual(Set(name(learnt.withMedia)), ["trip-top", "trip-deep"])
        XCTAssertEqual(previews("trip-top").count, 3, "three of the four at the top")
        XCTAssertTrue(Set(previews("trip-top")).isSubset(of: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]))
        XCTAssertEqual(previews("trip-deep"), ["x.jpg"], "none at the top: from further down")
        XCTAssertEqual(name(learnt.withoutMedia), ["trip-none"])
    }
}

/// Symbolic links from others: a link to a folder is the link (trash,
/// rename, move act on it, as in the Finder) and opens the folder it points
/// to; a link named like an archive or a picture must lead to one.
@MainActor
final class LinkTests: XCTestCase {
    func testALinkedFolderIsTrashedAsTheLinkAndOpensItsFolder() async throws {
        let tree = try TempTree(self)
        let real = try tree.folder("Pictures/2024")
        try tree.file("Pictures/2024/a.jpg")
        let shown = try tree.folder("Shared")
        let link = shown.appendingPathComponent("Vacation")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // A link next to the folder it points to: two tiles, two ids
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("Near"), withDestinationURL: shown)
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, shown)
        let tile = try XCTUnwrap(m.entries.first { $0.name == "Vacation" })
        XCTAssertEqual(tile.url.lastPathComponent, "Vacation", "listed as the link")
        XCTAssertTrue(BrowserModel.samePath(try XCTUnwrap(tile.linkTarget), real.resolvingSymlinksInPath()))
        m.selectEntry(named: "Vacation")
        m.moveSelectionToTrash()
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["Vacation"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("a.jpg").path), "the folder it pointed to stays")

        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, ["..", "Near", "Pictures", "Shared"])
        XCTAssertEqual(Set(m.entries.map(\.id)).count, m.entries.count)
        m.selectEntry(named: "Near")
        m.activateSelection()
        await waitUntil { m.isAt(shown.resolvingSymlinksInPath()) }
    }

    /// The other pane's change leaves a linked folder in this pane's listing.
    func testALinkedFolderStaysWhenTheOtherPaneChangesSomething() async throws {
        let tree = try TempTree(self)
        let real = try tree.folder("elsewhere/real")
        try tree.file("here/a.jpg")
        let here = tree.root.appendingPathComponent("here")
        try FileManager.default.createSymbolicLink(at: here.appendingPathComponent("Linked"), withDestinationURL: real)
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, here)
        XCTAssertEqual(m.names, ["..", "Linked", "a.jpg"])
        m.adopt([.removed(here.appendingPathComponent("a.jpg"))])
        XCTAssertEqual(m.names, ["..", "Linked"])
    }

    func testALinkNamedLikeAnArchiveMustLeadToOne() async throws {
        let tree = try TempTree(self)
        let pkg = try tree.file("setup.pkg", bytes: 10)
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("Photos.zip"), withDestinationURL: pkg)
        let zip = try tree.file("real.zip", bytes: 10)
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("Comics.zip"), withDestinationURL: zip)
        let entries = await BrowserModel.scan(tree.root)
        XCTAssertFalse(entries.contains { $0.name == "Photos.zip" }, "no archive tile for an installer")
        XCTAssertTrue(entries.contains { $0.name == "Comics.zip" && $0.isArchive })
    }

    /// ⌘↩ opens only what the item really is: archives of the grid's
    /// formats, never installers, disk images or a link to another kind.
    func testOpenWithTheDefaultAppRefusesWhatInstallsOrMounts() throws {
        let tree = try TempTree(self)
        func link(_ name: String, to target: URL) throws -> URL {
            let url = tree.root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }
        let zip = try tree.file("real.zip", bytes: 10)
        XCTAssertNotNil(LiveFiles.openableTarget(zip))
        XCTAssertNotNil(LiveFiles.openableTarget(try tree.file("photo.jpg", bytes: 10)))
        for name in ["setup.pkg", "disk.dmg", "Xcode.xip", "backup.aar", "page.html", "drawing.svg"] {
            XCTAssertNil(LiveFiles.openableTarget(try tree.file(name, bytes: 10)), name)
        }
        XCTAssertNil(LiveFiles.openableTarget(try link("Photos.zip", to: tree.root.appendingPathComponent("setup.pkg"))))
        XCTAssertNil(LiveFiles.openableTarget(try link("Photos2.zip", to: tree.root.appendingPathComponent("disk.dmg"))))
        XCTAssertNil(LiveFiles.openableTarget(try link("holiday.jpg", to: zip)), "a link must lead to its own kind")
        XCTAssertNotNil(LiveFiles.openableTarget(try link("comics.zip", to: zip)))
    }

    /// The live open actions, run to the workspace (a spy there): ⌘↩ and
    /// an other file's Open hand over what the item really is, and nothing
    /// that runs, however it is named.
    func testTheLiveOpenActionsHandOverOnlyWhatMayOpen() async throws {
        let tree = try TempTree(self)
        func link(_ name: String, to target: URL) throws -> URL {
            let url = tree.root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }
        let script = try tree.file("run.command", bytes: 10)
        let photo = try tree.file("photo.jpg", bytes: 10)
        let notes = tree.root.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)
        let site = tree.root.appendingPathComponent("site.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/"], format: .xml, options: 0).write(to: site)
        let holiday = try link("Holiday.jpg", to: script)
        let readme = try link("readme.txt", to: script)
        var launched: [(item: URL, app: URL?)] = []
        let saved = LiveFiles.launch
        LiveFiles.launch = { launched.append(($0, $1)) }
        defer { LiveFiles.launch = saved }

        let live = FileActions.live
        live.openInDefaultApp(holiday)
        live.openInDefaultApp(script)
        live.openOtherFile(readme)
        live.openOtherFile(script)
        XCTAssertTrue(launched.isEmpty, "\(launched.map(\.item.lastPathComponent))")
        live.openInDefaultApp(photo)
        live.openOtherFile(notes)
        live.openOtherFile(site)
        XCTAssertEqual(launched.map(\.item.absoluteString), [photo.absoluteString, notes.absoluteString, "https://example.com/"])
        XCTAssertEqual(launched.map { $0.app != nil }, [true, true, false], "a web address goes to the browser")

        // Through the model (⌘↩ on the selection, Open on an other file);
        // a link named like a picture that leads elsewhere is an other file
        launched = []
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, ["..", "photo.jpg"])
        let others = Dictionary(uniqueKeysWithValues: m.otherFiles.map { ($0.name, $0) })
        for name in ["Holiday.jpg", "readme.txt", "run.command"] { m.open(try XCTUnwrap(others[name], name)) }
        XCTAssertTrue(launched.isEmpty, "\(launched.map(\.item.lastPathComponent))")
        m.selectEntry(named: "photo.jpg")
        m.openInDefaultApp()
        m.open(try XCTUnwrap(others["notes.txt"]))
        XCTAssertEqual(launched.map(\.item.lastPathComponent), ["photo.jpg", "notes.txt"])
    }

    /// Drives on the drives' level are mounted and ejected by the system:
    /// never renamed or trashed here.
    func testDrivesAreNeitherRenamedNorTrashed() {
        let m = makeModel(FileActionsSpy())
        let drive = GridEntry(url: URL(fileURLWithPath: "/Volumes/USB", isDirectory: true), kind: .folder)
        XCTAssertTrue(BrowserModel.isDrive(drive.url))
        XCTAssertFalse(m.canRename(drive))
        XCTAssertFalse(m.canChange(drive))
        XCTAssertTrue(m.canChange(GridEntry(url: URL(fileURLWithPath: "/Volumes/USB/Photos", isDirectory: true), kind: .folder)))
    }
}

/// Items found by their path in the list (a map made on the second lookup
/// after a change), and what follows a change on disk: the folder shown
/// moving along, what left it leaving the listing, the full view going
/// back to the grid when what it showed went.
@MainActor
final class ListLookupTests: XCTestCase {
    func testItemsAreFoundByPathAcrossChangesOfTheList() async throws {
        let tree = try TempTree(self)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(name) }
        let m = makeModel()
        await openAndWait(m, tree.root)
        func entry(_ name: String) -> GridEntry { m.entries.first { $0.name == name }! }
        for name in ["c.jpg", "a.jpg", "b.jpg", "c.jpg"] {
            XCTAssertTrue(m.select(entry(name)))
            XCTAssertEqual(m.selectedEntry?.name, name)
        }
        let a = entry("a.jpg")
        m.adopt([.moved(a.url, to: tree.root.appendingPathComponent("z.jpg"))])
        XCTAssertEqual(m.names, ["..", "b.jpg", "c.jpg", "z.jpg"])
        XCTAssertEqual(m.selectedEntry?.name, "c.jpg", "the selection follows its item")
        for name in ["z.jpg", "b.jpg", "z.jpg"] {
            XCTAssertTrue(m.select(entry(name)))
            XCTAssertEqual(m.selectedEntry?.name, name)
        }
        XCTAssertFalse(m.select(a), "gone under its old path")
        m.click(entry("b.jpg"), command: false, shift: false)
        m.click(entry("z.jpg"), command: false, shift: true)
        XCTAssertEqual(Set(m.actionEntries.map(\.name)), ["b.jpg", "c.jpg", "z.jpg"], "a range from its anchor, found by path")
    }

    /// Each folder's change is looked up once and serves every item in it:
    /// what lies in a removed folder is gone, in a moved one moves, the rest stays.
    func testChangesFoundPerFolderServeEveryItemInIt() {
        let changes = FileChanges([.removed(URL(fileURLWithPath: "/r/gone", isDirectory: true)),
                                   .moved(URL(fileURLWithPath: "/r/old", isDirectory: true), to: URL(fileURLWithPath: "/r/new", isDirectory: true))])
        for _ in 0..<2 {
            XCTAssertNil(changes.path("/r/gone"))
            XCTAssertNil(changes.path("/r/gone/a.jpg"))
            XCTAssertNil(changes.path("/r/gone/deep/b.jpg"))
            XCTAssertEqual(changes.path("/r/old/a.jpg"), "/r/new/a.jpg")
            XCTAssertEqual(changes.path("/r/old/deep/b.jpg"), "/r/new/deep/b.jpg")
            XCTAssertEqual(changes.path("/r/kept/a.jpg"), "/r/kept/a.jpg")
            XCTAssertEqual(changes.path("/r/gone-not.jpg"), "/r/gone-not.jpg")
        }
    }

    func testWhatLeftTheFolderLeavesTheListingAndTheFullView() async throws {
        let tree = try TempTree(self)
        let sub = try tree.folder("sub")
        let a = try tree.file("a.jpg")
        try tree.file("b.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.selectEntry(named: "b.jpg")
        m.activateSelection()
        XCTAssertEqual(m.mode, .detail)
        m.adopt([.moved(a, to: sub.appendingPathComponent("a.jpg"))])
        XCTAssertEqual(m.names, ["..", "sub", "b.jpg"], "moved into a subfolder: out of the listing")
        XCTAssertEqual(m.mode, .detail, "the picture shown is still there")
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")
        m.adopt([.removed(tree.root.appendingPathComponent("b.jpg"))])
        XCTAssertEqual(m.names, ["..", "sub"])
        XCTAssertEqual(m.mode, .grid, "what the full view showed went: back to the grid")

        let moved = tree.root.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        m.adopt([.moved(tree.root, to: moved)])
        XCTAssertTrue(BrowserModel.samePath(m.folderURL!, moved), "the folder shown follows its own move")
    }
}

// MARK: - What was read meanwhile (`ChangeLog`)

@MainActor
final class ChangeLogTests: XCTestCase {
    /// A change that moves what another moved: applied in order, not looked
    /// up as if independent.
    func testChangesBuildingOnEachOtherApplyInOrder() {
        let b = URL(fileURLWithPath: "/r/b", isDirectory: true)
        let c = URL(fileURLWithPath: "/r/c", isDirectory: true)
        let changes = FileChanges([.moved(b, to: c), .moved(c.appendingPathComponent("x"), to: URL(fileURLWithPath: "/r/d"))])
        XCTAssertEqual(changes.path("/r/b/x/f.jpg"), "/r/d/f.jpg")
        XCTAssertEqual(changes.path("/r/b/y.jpg"), "/r/c/y.jpg")
        XCTAssertEqual(changes.path("/r/c/x/g.jpg"), "/r/d/g.jpg")
    }

    /// What was read before changes gets them carried out; what was read
    /// after none; when the changes since aren't all kept, nothing of it.
    func testReplayCarriesOutTheChangesSinceTheReading() {
        let log = ChangeLog()
        let a = GridEntry(url: URL(fileURLWithPath: "/r/Trip/a.jpg"), kind: .image)
        let b = GridEntry(url: URL(fileURLWithPath: "/r/Old/b.jpg"), kind: .image)
        let before = log.now
        log.record([.moved(URL(fileURLWithPath: "/r/Trip"), to: URL(fileURLWithPath: "/r/Iceland")),
                    .removed(URL(fileURLWithPath: "/r/Old"))])
        XCTAssertEqual(log.replay([a, b], since: before).map(\.url.path), ["/r/Iceland/a.jpg"])
        XCTAssertEqual(log.replay([a, b], since: log.now).map(\.url.path), ["/r/Trip/a.jpg", "/r/Old/b.jpg"])
        log.noteAdded()
        XCTAssertEqual(log.now, before + 3, "something added counts")
        XCTAssertEqual(log.since(before)?.count, 2, "but replays nothing")
        log.record((0..<ChangeLog.keptLimit).map { .removed(URL(fileURLWithPath: "/elsewhere/\($0)")) })
        XCTAssertNil(log.since(before))
        XCTAssertEqual(log.replay([a], since: before), [], "not known for sure: left out")
    }

    /// A walk's batch read while changes were made: what is still on disk
    /// is at its place now, what is gone was read before a change.
    func testAWalksBatchIsStampedByWhatIsStillThere() throws {
        let tree = try TempTree(self)
        let here = GridEntry(url: try tree.file("here.jpg"), kind: .image)
        let gone = GridEntry(url: tree.root.appendingPathComponent("gone.jpg"), kind: .image)
        let clock = ChangeClock()
        let unchanged = clock.stamped([here, gone], since: 0)
        XCTAssertEqual(unchanged.map(\.stamp), [0], "no change since: all from the start")
        clock.set(3)
        let parts = clock.stamped([here, gone], since: 0)
        XCTAssertEqual(parts.map(\.stamp), [3, 0])
        XCTAssertEqual(parts.map { $0.entries.map(\.name) }, [["here.jpg"], ["gone.jpg"]])
    }

    /// A search whose walk is through still takes what a change below it
    /// brings (the other pane copied into it): read before a rename made
    /// meanwhile, it comes under the new path.
    func testAFinishedSearchReplaysChangesOnWhatArrivesLate() async throws {
        let tree = try TempTree(self)
        try tree.file("photos/IMG_1.jpg")
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        await searchAndWait(m, "IMG")
        XCTAssertEqual(m.names, ["IMG_1.jpg"])
        let read = m.changeLog.now
        m.selectEntry(named: "IMG_1.jpg")
        await searchAndWait(m, "")
        m.selectEntry(named: "photos")
        try await m.rename(try XCTUnwrap(m.selectedEntry), to: "Pics")
        await searchAndWait(m, "IMG")
        m.appendSearchBatch([GridEntry(url: tree.root.appendingPathComponent("photos/IMG_2.jpg"), kind: .image)], stamp: read)
        XCTAssertEqual(Set(m.entries.map { m.relativeLocation(of: $0) }), ["Pics"], "no result under the old path")
    }

    /// The case as typed: a name stored decomposed ("u" and a combining
    /// mark, as the file system writes it) matches a query typed precomposed.
    func testNamesMatchWhetherComposedOrNot() {
        let stored = "Su\u{0308}d 2024.jpg"
        for mode in NameMatcher.Mode.allCases {
            XCTAssertTrue(NameMatcher("Süd", mode: mode).matches(stored), "\(mode)")
            XCTAssertTrue(NameMatcher("Su\u{0308}d", mode: mode).matches("Süd.jpg"), "\(mode)")
        }
        XCTAssertFalse(NameMatcher("süd", mode: .matchingCase).matches(stored))
    }

    /// A found folder holding only archives holds media for its tile (as
    /// the tile itself counts it): not learnt as empty, no previews learnt
    /// (the tile looks into the archive).
    func testAFolderOfArchivesIsntLearntEmpty() {
        let root = URL(fileURLWithPath: "/r", isDirectory: true)
        let comics = root.appendingPathComponent("Comics", isDirectory: true)
        var facts = FolderFacts(root: root)
        facts.found(folder: comics)
        facts.met(archive: comics.appendingPathComponent("issue1.cbz"))
        let learnt = facts.finish()
        XCTAssertEqual(learnt.withMedia, [comics])
        XCTAssertEqual(learnt.withoutMedia, [])
        XCTAssertNil(learnt.previews[comics])
    }

    /// The selected item trashed with others before it: the one after it
    /// is selected, as in the Finder, not the one at its old place.
    func testTheSelectionGoesToTheNeighbourOfWhatWent() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"] { try tree.file(n) }
        let m = makeModel(FileActionsSpy())
        await openAndWait(m, tree.root)
        m.click(try XCTUnwrap(m.entries.first { $0.name == "a.jpg" }), command: false, shift: false)
        m.click(try XCTUnwrap(m.entries.first { $0.name == "c.jpg" }), command: true, shift: false)
        XCTAssertEqual(m.marked.count, 2)
        m.moveSelectionToTrash()
        await waitUntil { m.names == ["..", "b.jpg", "d.jpg", "e.jpg"] }
        XCTAssertEqual(m.selectedEntry?.name, "d.jpg")
    }
}
