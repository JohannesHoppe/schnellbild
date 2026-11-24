import XCTest
import AVFoundation
import ImageIO
@testable import Schnellbild

// MARK: - Date taken from real files

/// Sorting by date taken reads the files themselves: EXIF in photos, the
/// QuickTime creation date in videos, whatever the file system says.
final class CaptureDateSortTests: XCTestCase {
    /// A small JPEG, with an EXIF capture date when given.
    private func writePhoto(_ url: URL, taken: String?) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let props = taken.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: $0]] as CFDictionary }
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), props)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// A three-picture QuickTime video with a creation date in its metadata.
    private func writeVideo(_ url: URL, created: String) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.value = created as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [item]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<3 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    func testVideoCreationDateIsRead() async throws {
        let tree = try TempTree(self)
        let url = tree.root.appendingPathComponent("clip.mov")
        try writeVideo(url, created: "2019-05-01T10:00:00+0000")
        let date = await BrowserModel.captureDate(of: url)
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2019-05-01T10:00:00Z"))
    }

    /// Copied files: the modification dates run against the order they were
    /// taken in, and one photo has no EXIF (it falls back to its date
    /// modified). Date taken sorts by the capture dates; newest first, and
    /// the same key again reverses.
    @MainActor
    func testSortByDateTakenUsesTheFilesCaptureDates() async throws {
        let tree = try TempTree(self)
        let early = tree.root.appendingPathComponent("early.jpg")
        let middle = tree.root.appendingPathComponent("middle.mov")
        let late = tree.root.appendingPathComponent("late.jpg")
        let plain = tree.root.appendingPathComponent("plain.jpg")
        try writePhoto(early, taken: "2015:03:01 09:00:00")
        try writeVideo(middle, created: "2018-06-01T12:00:00+0000")
        try writePhoto(late, taken: "2023:08:20 17:45:00")
        try writePhoto(plain, taken: nil)
        // Copied in the opposite order; the photo without EXIF in between
        try setModified(early, 1_700_000_300)
        try setModified(middle, 1_700_000_200)
        try setModified(late, 1_700_000_100)
        try setModified(plain, 1_600_000_000)   // 2020

        let m = makeModel()
        await openAndWait(m, tree.root)
        m.setSort(.modified)
        XCTAssertEqual(m.names.filter { $0 != ".." }, ["early.jpg", "middle.mov", "late.jpg", "plain.jpg"], "date modified, newest first")
        m.setSort(.captured)
        await waitUntil({ m.names.filter { $0 != ".." } == ["late.jpg", "plain.jpg", "middle.mov", "early.jpg"] }, timeout: 15)
        XCTAssertEqual(m.names.filter { $0 != ".." }, ["late.jpg", "plain.jpg", "middle.mov", "early.jpg"],
                       "date taken, newest first (plain.jpg by its date modified)")
        m.setSort(.captured)
        XCTAssertEqual(m.names.filter { $0 != ".." }, ["early.jpg", "middle.mov", "plain.jpg", "late.jpg"], "reversed")
    }
}

// MARK: - Folders that can't be read or have gone

final class UnreadableFolderTests: XCTestCase {
    /// A folder nobody may read (`chmod 000`); readable again in the teardown
    /// so the tree can be removed.
    private func lockedFolder(_ tree: TempTree, _ path: String, holding file: String) throws -> URL {
        try tree.file("\(path)/\(file)")
        let url = tree.root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil {
            throw XCTSkip("running with rights to read any folder")
        }
        return url
    }

    /// Opening it shows only `..` to get out and says it can't be read
    /// (never "This folder is empty"); it doesn't hang in loading.
    @MainActor
    func testAnUnreadableFolderSaysItCantBeRead() async throws {
        let tree = try TempTree(self)
        let locked = try lockedFolder(tree, "locked", holding: "secret.jpg")
        let m = makeModel()
        await openAndWait(m, locked)
        await waitUntil { m.loadError != nil }
        XCTAssertEqual(m.names, [".."])
        XCTAssertEqual(m.loadError?.archive, false)
        XCTAssertFalse(m.loadError?.reason.isEmpty ?? true, "with the system's reason")
        m.handleKey(.backspace, command: false)
        await waitUntil { m.isAt(tree.root) }
        XCTAssertEqual(m.selectedEntry?.name, "locked", "back out, on the folder it came from")
    }

    /// The search walks past it and finds what the other folders hold.
    @MainActor
    func testSearchWalksPastAnUnreadableFolder() async throws {
        let tree = try TempTree(self)
        _ = try lockedFolder(tree, "a-locked", holding: "beach-secret.jpg")
        try tree.file("b/beach.jpg")
        try tree.file("c/deep/beach2.jpg")
        let m = makeModel()
        await openAndWait(m, tree.root)
        await searchAndWait(m, "beach")
        XCTAssertEqual(Set(m.names), ["beach.jpg", "beach2.jpg"])
    }

    /// The slideshow plays the rest of the tree.
    @MainActor
    func testSlideshowPlaysPastAnUnreadableFolder() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg")
        _ = try lockedFolder(tree, "b-locked", holding: "secret.jpg")
        try tree.file("c/c.jpg")
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        m.startSlideshow(over: tree.root)
        await waitUntil { m.slideshow?.loading == false }
        XCTAssertEqual(m.slideshow?.items.map(\.name), ["a.jpg", "c.jpg"])
    }

    /// A folder it can't look into counts as holding no media (greyed out),
    /// and finding that out finishes.
    func testContainsMediaAnswersForAnUnreadableFolder() async throws {
        let tree = try TempTree(self)
        let locked = try lockedFolder(tree, "locked", holding: "secret.jpg")
        let found = await BrowserModel.containsMedia(locked)
        XCTAssertEqual(found, false)
        try tree.file("open/sub/p.jpg")
        _ = try lockedFolder(tree, "open/sub-locked", holding: "q.jpg")
        let other = await BrowserModel.containsMedia(tree.root.appendingPathComponent("open"))
        XCTAssertEqual(other, true, "a locked subfolder doesn't hide the readable one")
    }

    /// Back to a folder deleted in the meantime (in Finder, say): it shows
    /// empty, and Forward and Back still work.
    @MainActor
    func testBackToARemovedFolder() async throws {
        let tree = try TempTree(self)
        let gone = try tree.folder("gone")
        try tree.file("gone/p.jpg")
        let next = try tree.folder("next")
        try tree.file("next/q.jpg")
        let m = makeModel()
        await openAndWait(m, gone)
        await openAndWait(m, next)
        try FileManager.default.removeItem(at: gone)
        m.navigateBack()
        await waitUntil { m.isAt(gone) }
        await waitUntil { m.loadError != nil }
        XCTAssertEqual(m.names, [".."], "nothing left in it, and it says it can't be read")
        m.navigateForward()
        await waitUntil { m.isAt(next) }
        await waitUntil { m.names == ["..", "q.jpg"] }
        XCTAssertNil(m.loadError)
        m.navigateBack()
        await waitUntil { m.isAt(gone) }
        m.handleKey(.backspace, command: false)
        await waitUntil { m.isAt(tree.root) }
        XCTAssertEqual(m.names, ["..", "next"], "up from it to what is still there")
    }

    /// In the App Sandbox a file dropped from a folder outside every grant
    /// is all the app may read: it alone is shown, at once in the full
    /// view, and the folder offers "Allow Access…" (not "needs permission"
    /// instead of the picture).
    @MainActor
    func testADroppedFileOutsideEveryGrantShowsAlone() async throws {
        let tree = try TempTree(self)
        let photo = try tree.file("outside/photo.jpg")
        try tree.file("outside/other.jpg")
        let folder = photo.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)   // not listable, files readable
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil {
            throw XCTSkip("running with rights to read any folder")
        }
        let saved = FolderAccess.shared
        let sandbox = FolderAccess(sandboxed: true)
        sandbox.defaults = makeTestDefaults()
        FolderAccess.shared = sandbox
        defer { FolderAccess.shared = saved }
        let m = makeModel(FileActionsSpy())
        m.openDropped([photo])
        await waitUntil { m.folderURL != nil && !m.isLoading }
        XCTAssertEqual(m.names, ["..", "photo.jpg"])
        XCTAssertTrue(m.accessLimited)
        XCTAssertNil(m.loadError)
        XCTAssertEqual(m.mode, .detail, "the picture at once")
    }

    /// A grant whose folder isn't there at launch (its volume not mounted,
    /// a NAS asleep) is kept, not dropped from the preferences; data that
    /// is no bookmark at all goes.
    @MainActor
    func testAGrantThatDoesntOpenIsKept() async {
        // A bookmark of a folder on a NAS that isn't mounted, and data that is no bookmark
        let nas = Data("nas".utf8), damaged = Data("no bookmark".utf8)
        var system = FolderAccess.System.live
        system.resolve = { _ in nil }
        system.path = { $0 == nas ? "/Volumes/NAS/Photos" : nil }
        system.mountedVolumes = { ["/"] }
        let defaults = makeTestDefaults()
        defaults.set([nas, damaged], forKey: FolderAccess.key)
        let access = FolderAccess(sandboxed: true, system: system)
        access.defaults = defaults
        access.restore()
        await access.restored()
        XCTAssertEqual(access.count, 1, "the bookmark waits for its volume; the damaged data is gone")
        XCTAssertEqual(defaults.array(forKey: FolderAccess.key) as? [Data], [nas], "still in the preferences")
        let covered = await access.retry(covering: URL(fileURLWithPath: "/Volumes/NAS/Photos"))
        XCTAssertFalse(covered)
    }

    /// In the App Sandbox the folder the user opened to the app can be
    /// read and changed inside, but not renamed or moved itself (that
    /// changes the folder above, which isn't open to the app): its name in
    /// the title bar asks for the folder above first. A folder inside it
    /// renames at once, and nothing is offered for a file shown alone.
    @MainActor
    func testOnlyWhatIsInsideAGrantCanBeRenamedOrMoved() async throws {
        let tree = try TempTree(self)
        let trip = try tree.folder("Trip")
        try tree.file("Trip/x.jpg")
        try tree.folder("Trip/Day 1")
        let saved = FolderAccess.shared
        // Trip stands for a folder the user granted
        let sandbox = FolderAccess(sandboxed: true, standardFolders: [trip])
        sandbox.defaults = makeTestDefaults()
        FolderAccess.shared = sandbox
        defer { FolderAccess.shared = saved }
        let m = makeModel(FileActionsSpy())
        m.open(folder: trip)
        await waitUntil { !m.isLoading && m.names.contains("x.jpg") }
        XCTAssertFalse(m.canRenameCurrentFolder, "the grant itself")
        XCTAssertTrue(m.renameNeedsAccess, "its name asks for the folder above")
        XCTAssertTrue(m.canCreateFolder)
        let photo = try XCTUnwrap(m.entries.first { $0.name == "x.jpg" })
        XCTAssertTrue(m.canChange(photo))
        XCTAssertTrue(m.canRename(photo))
        XCTAssertFalse(sandbox.mayChange(in: tree.root), "the folder above")

        m.open(folder: trip.appendingPathComponent("Day 1"))
        await waitUntil { !m.isLoading && m.folderURL?.lastPathComponent == "Day 1" }
        XCTAssertTrue(m.canRenameCurrentFolder, "a folder inside the grant")
        XCTAssertFalse(m.renameNeedsAccess)

        // Outside every grant nothing can be changed
        let outside = GridEntry(url: tree.root.appendingPathComponent("y.jpg"), kind: .image)
        XCTAssertFalse(m.canChange(outside))
    }

    /// The UI tests start from empty preferences but keep the folders
    /// granted through the open panel, unless they ask for none.
    @MainActor
    func testResetStateKeepsTheGrantsUnlessAskedNotTo() throws {
        let grants = [Data("grant".utf8)]
        func suite(_ name: String) throws -> String {
            let suite = "reset-\(name)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(grants, forKey: FolderAccess.key)
            defaults.set("/somewhere", forKey: "lastFolder-test")
            addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            return suite
        }
        let kept = BrowserModel.makeDefaults(arguments: ["--ui-testing", "--reset-state"], suite: try suite("kept"))
        XCTAssertEqual(kept.array(forKey: FolderAccess.key) as? [Data], grants)
        XCTAssertNil(kept.string(forKey: "lastFolder-test"), "the rest starts empty")
        let none = BrowserModel.makeDefaults(arguments: ["--ui-testing", "--reset-state", "--reset-grants"], suite: try suite("none"))
        XCTAssertNil(none.array(forKey: FolderAccess.key))
        XCTAssertNil(none.string(forKey: "lastFolder-test"))
    }

    /// Related items (App Sandbox): the files of a file's name with
    /// another extension, in its folder.
    func testRelatedFilesHaveTheNameWithAnotherExtension() {
        let photo = URL(fileURLWithPath: "/P/IMG_1.JPG")
        XCTAssertTrue(RelatedFiles.isRelated(URL(fileURLWithPath: "/P/IMG_1.xmp"), to: photo))
        XCTAssertTrue(RelatedFiles.isRelated(URL(fileURLWithPath: "/P/IMG_1.JPG.xmp"), to: photo), "the whole name and one more")
        XCTAssertFalse(RelatedFiles.isRelated(URL(fileURLWithPath: "/P/IMG_2.xmp"), to: photo))
        XCTAssertFalse(RelatedFiles.isRelated(URL(fileURLWithPath: "/Q/IMG_1.xmp"), to: photo), "another folder")
        XCTAssertFalse(RelatedFiles.isRelated(URL(fileURLWithPath: "/P/IMG_1.jpg"), to: photo), "the file itself")
        let rar = URL(fileURLWithPath: "/P/film.rar")
        XCTAssertTrue(RelatedFiles.isRelated(URL(fileURLWithPath: "/P/film.r00"), to: rar))
        XCTAssertTrue(RelatedFiles.isRelated(URL(fileURLWithPath: "/P/film.7z.002"), to: URL(fileURLWithPath: "/P/film.7z.001")))
        XCTAssertFalse(RelatedFiles.isRelated(URL(fileURLWithPath: "/P/film.part2.rar"), to: URL(fileURLWithPath: "/P/film.part1.rar")),
                       "another name: the folder must be opened")
    }

    /// The last folder isn't there at launch: said, not a bare "No folder
    /// open"; the next launch isn't told it crashed there.
    @MainActor
    func testAnUnavailableLastFolderIsSaid() async throws {
        let tree = try TempTree(self)
        let defaults = makeTestDefaults()
        let gone = tree.root.appendingPathComponent("NAS/Photos").path
        defaults.set(gone, forKey: BrowserModel.lastFolderKey)
        let m = BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions)
        m.restoreLastFolder()
        await waitUntil { m.unavailableRestore != nil }
        XCTAssertEqual(m.unavailableRestore, gone)
        XCTAssertNil(m.folderURL)
        XCTAssertNil(defaults.string(forKey: BrowserModel.restoreUnconfirmedKey))
    }
}

// MARK: - Drop zones

final class DropZoneTests: XCTestCase {
    func testTheLeftHalfBrowsesTheRightHalfPlays() {
        XCTAssertEqual(DropZoneDelegate.zone(atX: 0, width: 800), .browse)
        XCTAssertEqual(DropZoneDelegate.zone(atX: 399, width: 800), .browse)
        XCTAssertEqual(DropZoneDelegate.zone(atX: 400, width: 800), .slideshow)
        XCTAssertEqual(DropZoneDelegate.zone(atX: 799, width: 800), .slideshow)
    }

    /// An update arriving after the mouse is released (the drop is done)
    /// shows no zone: the overlay must go away.
    func testNoZoneOnceTheMouseIsUp() {
        XCTAssertNil(DropZoneDelegate.zone(atX: 100, width: 800, mouseDown: false))
        XCTAssertNil(DropZoneDelegate.zone(atX: 700, width: 800, mouseDown: false))
    }
}

// MARK: - Pictures read from disk

/// Pictures the app reads itself (`MediaData`) wait on the disk off Swift's
/// threads: many tiles of a share that stalls leave the rest of the app's
/// async work running, and a FIFO named like a picture is refused without
/// waiting for a writer.
final class MediaDataTests: XCTestCase {
    func testFIFOsNamedLikePicturesNeitherWaitNorStarveOtherWork() throws {
        let tree = try TempTree(self)
        let fifos = try ["a.svg", "b.qoi", "c.bay", "d.eps", "e.png"].map { name -> URL in
            let url = tree.root.appendingPathComponent(name)
            XCTAssertEqual(mkfifo(url.path, 0o600), 0)
            return url
        }
        let reads = ProcessInfo.processInfo.activeProcessorCount * 2 + 4
        let done = DispatchGroup()
        for i in 0..<reads {
            let url = fifos[i % fifos.count]
            done.enter()
            Task.detached {
                switch i % 3 {
                case 0: _ = try? await MediaData.read(url)
                case 1: _ = await MediaData.picture(url)
                default: _ = await RawDecoder.thumbnail(of: url, maxPixel: 64)
                }
                done.leave()
            }
        }
        let other = DispatchSemaphore(value: 0)
        Task.detached { other.signal() }
        let ran = other.wait(timeout: .now() + 10)
        // Every read ends without a writer ever opening a FIFO
        let unaided = done.wait(timeout: .now() + 10)
        // A read still waiting for a writer is let go (an end of file), so none outlives the test
        let deadline = Date() + 60
        while done.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
            for fifo in fifos {
                let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
                if writer >= 0 { close(writer) }
            }
        }
        XCTAssertEqual(ran, .success, "other async work waited behind the reads")
        XCTAssertEqual(unaided, .success, "a read waited for a writer")
        XCTAssertEqual(done.wait(timeout: .now()), .success)
    }

    /// A disk that stalls (each read waits until let go) under more reads
    /// than Swift has threads: they all wait at once, and other async work
    /// runs meanwhile.
    func testReadsThatStallLeaveSwiftsThreadsFree() throws {
        let tree = try TempTree(self)
        let file = try tree.file("a.svg", bytes: 10)
        final class Waiting: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func enter() { lock.withLock { count += 1 } }
            var now: Int { lock.withLock { count } }
        }
        let waiting = Waiting()
        let release = DispatchSemaphore(value: 0)
        let saved = MediaData.fileReader
        MediaData.fileReader = { url in
            waiting.enter()
            release.wait()
            return try MediaData.readFile(url)
        }
        defer { MediaData.fileReader = saved }
        let reads = ProcessInfo.processInfo.activeProcessorCount * 2 + 4
        let done = DispatchGroup()
        let read = Waiting()
        for _ in 0..<reads {
            done.enter()
            Task.detached {
                if let data = try? await MediaData.read(file), data.count == 10 { read.enter() }
                done.leave()
            }
        }
        let deadline = Date() + 10
        while waiting.now < reads, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(waiting.now, reads, "every read waits at once")
        let other = DispatchSemaphore(value: 0)
        Task.detached { other.signal() }
        let ran = other.wait(timeout: .now() + 10)
        for _ in 0..<reads { release.signal() }
        XCTAssertEqual(ran, .success, "other async work waited behind the reads")
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(read.now, reads)
    }
}
