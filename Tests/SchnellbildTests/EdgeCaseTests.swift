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

    /// A grant whose volume isn't there at launch (a NAS asleep) is kept,
    /// not dropped from the preferences.
    @MainActor
    func testAGrantThatDoesntOpenIsKept() {
        let defaults = makeTestDefaults()
        defaults.set([Data("a bookmark of a volume not there".utf8)], forKey: FolderAccess.key)
        let access = FolderAccess(sandboxed: true)
        access.defaults = defaults
        access.restore()
        XCTAssertEqual(access.count, 1)
        XCTAssertEqual((defaults.array(forKey: FolderAccess.key) as? [Data])?.count, 1, "still in the preferences")
        XCTAssertFalse(access.retry(covering: URL(fileURLWithPath: "/Volumes/NAS/Photos")))
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
