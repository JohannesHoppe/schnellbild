import XCTest
@testable import Schnellbild

/// The App Sandbox's grants, against a stand-in for the system's bookmarks
/// that counts every start and stop of access: only what the app opens is
/// kept, every start is balanced by a stop when its grant goes, grants of
/// items that are gone are dropped, and bookmarks are resolved off the
/// main thread.
@MainActor
final class FolderAccessTests: XCTestCase {
    /// The system as the tests see it: a bookmark is its path; it resolves
    /// while something is there; access counted per path.
    final class FakeSystem: @unchecked Sendable {
        private let lock = NSLock()
        private var access: [String: Int] = [:]
        var mounted: Set<String> = ["/"]
        var resolveDelay: TimeInterval = 0

        /// Paths with access started and not stopped (each as often as started).
        var open: [String: Int] { lock.withLock { access.filter { $0.value != 0 } } }

        var system: FolderAccess.System {
            FolderAccess.System(
                bookmark: { Data($0.path.utf8) },
                resolve: { [self] data in
                    if resolveDelay > 0 { Thread.sleep(forTimeInterval: resolveDelay) }
                    let path = String(decoding: data, as: UTF8.self)
                    return FileManager.default.fileExists(atPath: path) ? (URL(fileURLWithPath: path), false) : nil
                },
                path: { BrowserModel.canonicalPath(URL(fileURLWithPath: String(decoding: $0, as: UTF8.self))) },
                start: { [self] url in lock.withLock { access[BrowserModel.canonicalPath(url), default: 0] += 1 }; return true },
                stop: { [self] url in lock.withLock { access[BrowserModel.canonicalPath(url), default: 0] -= 1 } },
                mountedVolumes: { [self] in lock.withLock { mounted } }
            )
        }
    }

    private func sandbox(_ fake: FakeSystem, saved: [URL] = []) -> FolderAccess {
        let access = FolderAccess(sandboxed: true, system: fake.system)
        access.defaults = makeTestDefaults()
        access.defaults.set(saved.map { Data($0.path.utf8) }, forKey: FolderAccess.key)
        return access
    }

    private func kept(_ access: FolderAccess) -> [String] {
        (access.defaults.array(forKey: FolderAccess.key) as? [Data] ?? []).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Many files dropped: none is kept for a restart, only the one opened
    /// is held; a folder dropped is kept, and its access is started once.
    func testOnlyWhatADropOpensIsKept() async throws {
        let tree = try TempTree(self)
        let photos = try (1...5).map { try tree.file("outside/IMG_\($0).jpg") }
        let fake = FakeSystem()
        let access = sandbox(fake)
        access.restore()
        await access.restored()
        let saved = FolderAccess.shared
        FolderAccess.shared = access
        defer { FolderAccess.shared = saved }
        let m = makeModel(FileActionsSpy())

        m.openDropped(photos)
        await waitUntil { m.folderURL != nil && !m.isLoading }
        XCTAssertEqual(kept(access), [], "no file is kept for a restart")
        XCTAssertEqual(access.count, 0)
        XCTAssertEqual(fake.open, [BrowserModel.canonicalPath(photos[0]): 1], "the file opened is held, the others left alone")

        let folder = try tree.folder("Trip")
        m.openDropped([folder])
        await waitUntil { m.isAt(folder) }
        XCTAssertEqual(kept(access), [folder.path])
        XCTAssertEqual(fake.open[BrowserModel.canonicalPath(folder)], 1, "held while looked at, then granted: started once")
        XCTAssertTrue(access.covers(folder.appendingPathComponent("a.jpg")))
    }

    /// Files dropped alone are held for the session, the newest few; the
    /// older ones are let go.
    func testHeldFilesAreLetGo() throws {
        let tree = try TempTree(self)
        let fake = FakeSystem()
        let access = sandbox(fake)
        let files = try (0..<(FolderAccess.heldFileLimit + 5)).map { try tree.file("f\($0).jpg") }
        for file in files { access.hold(file) }
        XCTAssertEqual(fake.open.count, FolderAccess.heldFileLimit)
        XCTAssertNil(fake.open[BrowserModel.canonicalPath(files[0])], "the oldest stopped")
        XCTAssertTrue(access.covers(files.last!))
        XCTAssertFalse(access.covers(files[0]))
        XCTAssertEqual(kept(access), [])
    }

    /// A grant around others replaces them, and their access stops; Forget
    /// stops every access the app started.
    func testAccessIsStoppedWhenAGrantGoes() async throws {
        let tree = try TempTree(self)
        let inner = try tree.folder("Photos/2024")
        let file = try tree.file("Photos/loose.jpg")
        let outer = inner.deletingLastPathComponent()
        let fake = FakeSystem()
        let access = sandbox(fake)
        access.grant(inner)
        access.hold(file)
        access.grant(inner)
        XCTAssertEqual(fake.open[BrowserModel.canonicalPath(inner)], 1, "granted once")
        access.grant(outer)
        XCTAssertEqual(fake.open, [BrowserModel.canonicalPath(outer): 1], "inside the new grant: stopped")
        XCTAssertEqual(kept(access), [outer.path])
        access.forgetAll()
        XCTAssertEqual(fake.open, [:])
        XCTAssertEqual(kept(access), [])
    }

    /// At launch: a grant that resolves opens; one whose item is gone from
    /// a volume that is there, or that lies in the Trash, is dropped; one
    /// on a volume not mounted waits.
    func testGrantsOfItemsGoneAreDropped() async throws {
        let tree = try TempTree(self)
        let here = try tree.folder("Here")
        let trashed = try tree.folder(".Trash/Old")
        let deleted = tree.root.appendingPathComponent("Deleted")
        let asleep = URL(fileURLWithPath: "/Volumes/NAS asleep/Photos")
        let fake = FakeSystem()
        let access = sandbox(fake, saved: [here, trashed, deleted, asleep])
        access.restore()
        await access.restored()
        XCTAssertEqual(kept(access), [here.path, asleep.path])
        XCTAssertEqual(access.count, 2)
        XCTAssertEqual(fake.open, [BrowserModel.canonicalPath(here): 1], "nothing left started for what was dropped")
        XCTAssertTrue(access.covers(here))

        // The volume mounts with the folder gone: dropped then
        fake.mounted.insert("/Volumes/NAS asleep")
        await access.volumeMounted()
        XCTAssertEqual(kept(access), [here.path])
        let covered = await access.retry(covering: asleep)
        XCTAssertFalse(covered)
    }

    /// The bookmarks are resolved off the main thread: `restore` returns
    /// at once, a folder is read once they are open.
    func testBookmarksAreResolvedOffTheMainThread() async throws {
        let tree = try TempTree(self)
        let folder = try tree.folder("Share")
        let fake = FakeSystem()
        fake.resolveDelay = 0.5
        let access = sandbox(fake, saved: [folder])
        let start = Date()
        access.restore()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25, "the launch isn't held")
        XCTAssertEqual(kept(access), [folder.path], "kept while it resolves")
        XCTAssertEqual(access.count, 1)
        await access.restored()
        XCTAssertTrue(access.covers(folder))
        XCTAssertEqual(kept(access), [folder.path])
    }

    /// Forget while the kept bookmarks still resolve: the grants the user
    /// gave up don't come back when the resolution returns, and the access
    /// it started is stopped. The same for a volume mounting meanwhile.
    func testForgetWhileResolvingKeepsNothing() async throws {
        let tree = try TempTree(self)
        let folder = try tree.folder("Share")
        let asleep = URL(fileURLWithPath: "/Volumes/NAS asleep/Photos")
        let fake = FakeSystem()
        fake.resolveDelay = 0.3
        let access = sandbox(fake, saved: [folder, asleep])
        access.restore()
        access.forgetAll()
        await access.restored()
        XCTAssertEqual(kept(access), [])
        XCTAssertEqual(access.count, 0)
        XCTAssertEqual(fake.open, [:], "what the resolution started is stopped")
        XCTAssertFalse(access.covers(folder))

        // A volume mounting while a pending grant resolves
        let later = sandbox(fake, saved: [asleep])
        later.restore()
        await later.restored()
        XCTAssertEqual(kept(later), [asleep.path])
        let mounting = Task { await later.volumeMounted() }
        try await Task.sleep(nanoseconds: 50_000_000)
        later.forgetAll()
        await mounting.value
        XCTAssertEqual(kept(later), [])
        XCTAssertEqual(later.count, 0)
    }

    /// A file held already: holding it again starts no second access.
    func testAFileIsHeldOnce() throws {
        let tree = try TempTree(self)
        let file = try tree.file("loose.jpg")
        let fake = FakeSystem()
        let access = sandbox(fake)
        access.hold(file)
        access.hold(file)
        XCTAssertEqual(fake.open, [BrowserModel.canonicalPath(file): 1])
    }

    func testTheVolumeOfAPath() {
        XCTAssertEqual(FolderAccess.volume(of: "/Volumes/NAS/Photos/a.jpg"), "/Volumes/NAS")
        XCTAssertEqual(FolderAccess.volume(of: "/Volumes/NAS"), "/Volumes/NAS")
        XCTAssertEqual(FolderAccess.volume(of: "/Users/a/Pictures"), "/")
        XCTAssertTrue(FolderAccess.isInTrash("/Users/a/.Trash/Old"))
        XCTAssertTrue(FolderAccess.isInTrash("/Volumes/NAS/.Trashes/501/Old"))
        XCTAssertFalse(FolderAccess.isInTrash("/Users/a/Trash/Old"))
    }
}
