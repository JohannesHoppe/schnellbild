import XCTest
import VLCFrames
import AVFoundation
@testable import Schnellbild

/// Downloads not finished ("x.mp4.part" counts as an MP4) and files whose
/// names say nothing (they count by their content), against the fixtures in
/// UITests/Fixtures/partial (`Scripts/make_video_fixtures.sh partial`).
@MainActor
final class PartialFilesTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITests/Fixtures/\(name)")
    }

    // MARK: Download endings

    func testDownloadEndingsAreLeftOut() {
        let cases = [
            ("film.mp4.part", "film.mp4"), ("film.MP4.PART", "film.MP4"), ("photo.jpg.partial", "photo.jpg"),
            ("film.mkv.crdownload", "film.mkv"), ("film.mkv.opdownload", "film.mkv"), ("film.mkv.!qB", "film.mkv"),
            ("film.avi.!ut", "film.avi"), ("film.avi.!bt", "film.avi"), ("photos.rar.part", "photos.rar"),
            ("notes.part", "notes"), ("film.mp4", "film.mp4"), ("x.part1.rar", "x.part1.rar"),
            ("x.part1.rar.part", "x.part1.rar"), (".part", ".part"),
        ]
        for (name, final) in cases {
            XCTAssertEqual(DownloadName.finalName(of: name), final, name)
            XCTAssertEqual(DownloadName.isPartial(name), name != final, name)
        }
        XCTAssertEqual(DownloadName.finalExtension(of: URL(fileURLWithPath: "/x/film.MKV.part")), "mkv")
        XCTAssertEqual(DownloadName.finalExtension(of: URL(fileURLWithPath: "/x/notes.part")), "")
    }

    /// The final name decides everywhere: the kind, the archive format, VLC's reader.
    func testADownloadCountsAsWhatItWillBe() {
        func kind(_ name: String) -> GridEntry.Kind? { BrowserModel.mediaKind(of: URL(fileURLWithPath: "/nowhere/\(name)")) }
        XCTAssertEqual(kind("film.mp4.part"), .video)
        XCTAssertEqual(kind("film.mkv.crdownload"), .video)
        XCTAssertEqual(kind("film.webm.!qB"), .video)
        XCTAssertEqual(kind("photo.jpg.part"), .image)
        XCTAssertEqual(kind("photo.HEIC.opdownload"), .image)
        XCTAssertNil(kind("notes.txt.part"))
        XCTAssertNil(kind("._film.mp4.part"))

        XCTAssertEqual(ArchiveName.format(of: "photos.rar.part"), .rar)
        XCTAssertEqual(ArchiveName.format(of: "photos.zip.crdownload"), .zip)
        XCTAssertEqual(ArchiveName.format(of: "photos.7z.partial"), .sevenZip)
        // RAR volumes: "x.part1.rar" is the first, read with the rest; still downloading too
        XCTAssertEqual(ArchiveName.format(of: "x.part1.rar"), .rar)
        XCTAssertEqual(ArchiveName.format(of: "x.part1.rar.part"), .rar)
        XCTAssertNil(ArchiveName.format(of: "x.part2.rar"))
        XCTAssertNil(ArchiveName.format(of: "x.part2.rar.part"))
        XCTAssertEqual(ArchiveName.firstVolumeNames(of: "x.part2.rar"), ["x.part1.rar", "x.part01.rar", "x.part001.rar"])

        XCTAssertEqual(VLCSafety.reader(for: URL(fileURLWithPath: "/x/film.mkv.part"))?.demux, "mkv")
        XCTAssertEqual(VLCSafety.reader(for: URL(fileURLWithPath: "/x/film.avi.crdownload"))?.demux, "avi")
        XCTAssertNil(VLCSafety.reader(for: URL(fileURLWithPath: "/x/film.m3u8.part")))

        let entry = GridEntry(url: URL(fileURLWithPath: "/x/film.mp4.part"), kind: .video)
        XCTAssertTrue(entry.isDownloading)
        XCTAssertEqual(entry.unfinishedNote, "Download not finished")
        XCTAssertFalse(GridEntry(url: URL(fileURLWithPath: "/x/film.mp4"), kind: .video).isDownloading)
    }

    // MARK: Content

    func testNamesWorthALookAtTheContent() {
        for name in ["IMG", "x.xyz", "x.part", "x.xyz.part", "dump.bin", "x.dat"] {
            XCTAssertTrue(ContentSniffer.isUnknown(name), name)
        }
        for name in ["x.jpg", "x.mp4.part", "x.txt", "x.pdf", "x.rar", "x.r00", "x.z01", "x.7z.002", ".hidden", "x.ts"] {
            XCTAssertFalse(ContentSniffer.isUnknown(name), name)
        }
    }

    func testTheFirstBytesTellWhatAFileHolds() throws {
        func content(_ name: String) throws -> FileFacts.Content? {
            FileFacts.content(in: try XCTUnwrap(VLCSafety.head(of: fixture(name))))
        }
        XCTAssertEqual(try content("partial/photo")?.kind, .picture)
        XCTAssertTrue(["jpeg", "jpg"].contains(try content("partial/photo")?.fileExtension ?? ""))
        XCTAssertEqual(try content("partial/video.xyz")?.kind, .video)
        XCTAssertEqual(try content("partial/video.xyz")?.fileExtension, "mp4")
        XCTAssertEqual(try content("partial/film.mkv.part")?.fileExtension, "mkv")
        XCTAssertEqual(try content("partial/end.mp4.part")?.kind, .video)
        XCTAssertEqual(try content("pages.pdf")?.fileExtension, "pdf")
        XCTAssertEqual(try content("rar/photos-cut.rar.part")?.kind, .archive(.rar))
        XCTAssertNil(FileFacts.content(in: Data("just some text, nothing else".utf8)))
        XCTAssertNil(FileFacts.content(in: Data()))
    }

    /// A file of an unknown name counts by its content once it was read;
    /// nothing is read by `mediaKind` itself.
    func testAFileOfAnUnknownNameCountsByItsContent() throws {
        let tree = try TempTree(self)
        let photo = tree.root.appendingPathComponent("IMG")
        let video = tree.root.appendingPathComponent("clip.xyz")
        let text = tree.root.appendingPathComponent("readme.xyz")
        try FileManager.default.copyItem(at: fixture("partial/photo"), to: photo)
        try FileManager.default.copyItem(at: fixture("partial/video.xyz"), to: video)
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertNil(BrowserModel.mediaKind(of: photo), "not read yet")
        XCTAssertTrue(ContentSniffer.shared.needsReading(photo, size: 28942))
        for url in [photo, video, text] { ContentSniffer.shared.content(of: url) }
        XCTAssertEqual(BrowserModel.mediaKind(of: photo), .image)
        XCTAssertEqual(BrowserModel.mediaKind(of: video), .video)
        XCTAssertNil(BrowserModel.mediaKind(of: text))
        XCTAssertFalse(ContentSniffer.shared.needsReading(text, size: 5))
        XCTAssertTrue(ContentSniffer.shared.needsReading(text, size: 6), "grown: read again")
        XCTAssertEqual(BrowserModel.shownExtension(of: video), "mp4")
        XCTAssertEqual(VLCSafety.reader(for: video, head: VLCSafety.head(of: video))?.demux, "mp4")
        XCTAssertNil(VLCSafety.reader(for: text, head: VLCSafety.head(of: text)))
        XCTAssertEqual(VideoDetailView.assetOptions(for: video)[AVURLAssetOverrideMIMETypeKey] as? String, "video/mp4")
        XCTAssertNil(VideoDetailView.assetOptions(for: URL(fileURLWithPath: "/x/a.mp4"))[AVURLAssetOverrideMIMETypeKey])
    }

    /// A ZIP under a name that says nothing opens like a folder.
    func testAnArchiveOfAnUnknownNameOpensByItsContent() async throws {
        let tree = try TempTree(self)
        let rar = tree.root.appendingPathComponent("photos.bin")
        try FileManager.default.copyItem(at: fixture("rar/photos-stored.rar"), to: rar)
        XCTAssertNil(ArchivePath.split(rar.appendingPathComponent("beach.jpg")))
        ContentSniffer.shared.content(of: rar)
        XCTAssertEqual(ArchiveName.format(ofFile: rar), .rar)
        XCTAssertEqual(ArchivePath.split(rar.appendingPathComponent("Day 1/sun.jpg"))?.inner, "Day 1/sun.jpg")
        let listing = try await ArchiveStore.shared.listing(in: rar)
        XCTAssertEqual(listing.entries.map(\.name).sorted(), ["Day 1", "beach.jpg", "clip.mp4"])
    }

    /// The answers kept reach their limit: the others go, the archives
    /// found by their content stay, so paths into one still resolve.
    func testArchivesFoundByTheirContentOutlastTheLimit() throws {
        let tree = try TempTree(self)
        let sniffer = ContentSniffer(limit: 3)
        let zip = tree.root.appendingPathComponent("photos.bin")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]).write(to: zip)
        sniffer.content(of: zip)
        let texts = try (0..<6).map { index in
            let url = tree.root.appendingPathComponent("note\(index).xyz")
            try "hello \(index)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        for url in texts { sniffer.content(of: url) }
        XCTAssertEqual(sniffer.known(zip)?.archiveFormat, .zip)
        XCTAssertEqual(sniffer.archive(containing: zip.appendingPathComponent("a/b.jpg"))?.inner, "a/b.jpg")
        XCTAssertFalse(sniffer.needsReading(texts.last!, size: nil), "the newest answer kept")
        XCTAssertTrue(sniffer.needsReading(texts[0], size: nil), "an older one let go")
    }

    // MARK: Cut off

    func testAnMP4CutBeforeItsIndexIsTold() throws {
        func cutOff(_ name: String) throws -> Bool { MP4Boxes.indexCutOff(try XCTUnwrap(FileBytes(fixture(name)))) }
        XCTAssertTrue(try cutOff("partial/end.mp4.part"), "the index last, the download cut before it")
        XCTAssertFalse(try cutOff("partial/front.mp4.part"), "the index first: plays as far as it reaches")
        XCTAssertFalse(try cutOff("partial/video.xyz"))
        XCTAssertFalse(try cutOff("clip.mp4"))
        XCTAssertFalse(try cutOff("partial/film.mkv.part"), "not made of boxes")
        XCTAssertFalse(MP4Boxes.indexCutOff(MemoryBytes([UInt8]("hello world".utf8))))
        // The header of the next box cut in half
        var bytes: [UInt8] = [0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0]
        bytes += [0, 0, 1]
        XCTAssertTrue(MP4Boxes.indexCutOff(MemoryBytes(bytes)))
    }

    /// A RAR download cut off: the entries before the cut are whole, the one
    /// it cuts is marked.
    func testTheEntryACutArchiveDoesntHoldWholeIsMarked() async throws {
        let tree = try TempTree(self)
        let cut = tree.root.appendingPathComponent("photos-cut.rar.part")
        try FileManager.default.copyItem(at: fixture("rar/photos-cut.rar.part"), to: cut)
        let index = try await ArchiveStore.shared.index(of: cut)
        XCTAssertEqual(index.cutOff, "Day 1/big.jpg")
        let top = try await ArchiveStore.shared.listing(in: cut)
        XCTAssertEqual(top.entries.filter(\.isIncomplete).map(\.name), [])
        let day = try await ArchiveStore.shared.listing(in: cut.appendingPathComponent("Day 1"))
        XCTAssertEqual(day.entries.filter(\.isIncomplete).map(\.name), ["big.jpg"])
        XCTAssertEqual(day.entries.first?.unfinishedNote, "Incomplete")
        let whole = tree.root.appendingPathComponent("photos-stored.rar")
        try FileManager.default.copyItem(at: fixture("rar/photos-stored.rar"), to: whole)
        let complete = try await ArchiveStore.shared.index(of: whole)
        XCTAssertNil(complete.cutOff)
    }

    // MARK: Listings

    /// A folder with downloads in progress and files of unknown names: the
    /// downloads show at once, the unknown ones once their content is read.
    func testAFolderShowsDownloadsAndFilesByTheirContent() async throws {
        let tree = try TempTree(self)
        for name in ["front.mp4.part", "film.mkv.part", "photo", "video.xyz"] {
            try FileManager.default.copyItem(at: fixture("partial/\(name)"), to: tree.root.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: fixture("rar/photos-cut.rar.part"), to: tree.root.appendingPathComponent("photos.rar.part"))
        try "hello".write(to: tree.root.appendingPathComponent("notes.xyz"), atomically: true, encoding: .utf8)
        let m = makeModel()
        await openAndWait(m, tree.root)
        await waitUntil { Set(m.names) == ["..", "film.mkv.part", "front.mp4.part", "photo", "photos.rar.part", "video.xyz"] }
        XCTAssertEqual(m.entries.filter(\.isDownloading).map(\.name).sorted(), ["film.mkv.part", "front.mp4.part", "photos.rar.part"])
        XCTAssertEqual(m.entries.first { $0.name == "photo" }?.kind, .image)
        XCTAssertEqual(m.entries.first { $0.name == "video.xyz" }?.kind, .video)
        XCTAssertTrue(m.entries.first { $0.name == "photos.rar.part" }?.isArchive == true)
        XCTAssertEqual(m.otherFiles.map(\.name), ["notes.xyz"])
    }

    /// The download finished and its tool renamed it: the selection goes
    /// along; Firefox's empty file of the final name isn't shown meanwhile.
    func testTheSelectionFollowsAFinishedDownload() async throws {
        let tree = try TempTree(self)
        try tree.file("a.jpg", bytes: 10)
        let part = tree.root.appendingPathComponent("film.mp4.part")
        try FileManager.default.copyItem(at: fixture("partial/front.mp4.part"), to: part)
        try tree.file("film.mp4")   // Firefox's placeholder: empty
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, ["..", "a.jpg", "film.mp4.part"], "the empty placeholder isn't shown")
        m.selectEntry(named: "film.mp4.part")
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("film.mp4"))
        try FileManager.default.moveItem(at: part, to: tree.root.appendingPathComponent("film.mp4"))
        m.relist(force: true)
        await waitUntil { m.names == ["..", "a.jpg", "film.mp4"] }
        XCTAssertEqual(m.selectedEntry?.name, "film.mp4")
    }

    /// VLC takes a whole file over from AVKit only for data AVFoundation
    /// can't read or decode, not for any failure it reports.
    func testOnlyDataFailuresHandAWholeFileToVLC() {
        func av(_ code: AVError.Code, underlying: NSError? = nil) -> NSError {
            NSError(domain: AVFoundationErrorDomain, code: code.rawValue,
                    userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        XCTAssertTrue(AVPlaybackControl.isDataFailure(av(.decodeFailed)))
        XCTAssertTrue(AVPlaybackControl.isDataFailure(av(.fileFormatNotRecognized)))
        XCTAssertTrue(AVPlaybackControl.isDataFailure(av(.unknown, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))),
                      "a read error underneath")
        XCTAssertFalse(AVPlaybackControl.isDataFailure(nil))
        XCTAssertFalse(AVPlaybackControl.isDataFailure(av(.unknown)))
        XCTAssertFalse(AVPlaybackControl.isDataFailure(av(.operationNotAllowed)))
        XCTAssertFalse(AVPlaybackControl.isDataFailure(av(.videoCompositorFailed)))
    }
}
