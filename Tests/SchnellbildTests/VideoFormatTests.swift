import XCTest
import VLCFrames
@testable import Schnellbild

/// Every video format the app lists: VLC reads it (one frame, as for a tile
/// and for the thumbnail extension; playing uses the same reader), and a file
/// that only claims a format opens nothing. The clips are drawn by
/// `Scripts/make_video_fixtures.sh`.
final class VideoFormatTests: XCTestCase {
    private func clip(_ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "clip", withExtension: ext, subdirectory: "Videos"), "missing clip.\(ext)")
    }

    private func assertFrame(_ ext: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = try clip(ext)
        let frame = await VLCFrameGrab.frame(of: url, width: 128)
        let image = try XCTUnwrap(frame, "no frame from clip.\(ext)", file: file, line: line)
        XCTAssertEqual(image.width, 128, file: file, line: line)
        XCTAssertGreaterThan(image.height, 0, file: file, line: line)
    }

    func testMKV() async throws { try await assertFrame("mkv") }
    func testWebM() async throws { try await assertFrame("webm") }
    func testAVI() async throws { try await assertFrame("avi") }
    func testMP4() async throws { try await assertFrame("mp4") }
    func testM4V() async throws { try await assertFrame("m4v") }
    func testMOV() async throws { try await assertFrame("mov") }
    func testQT() async throws { try await assertFrame("qt") }
    func test3GP() async throws { try await assertFrame("3gp") }
    func test3G2() async throws { try await assertFrame("3g2") }
    func testMPG() async throws { try await assertFrame("mpg") }
    func testMPEG() async throws { try await assertFrame("mpeg") }
    func testVOB() async throws { try await assertFrame("vob") }
    func testM2V() async throws { try await assertFrame("m2v") }
    func testTS() async throws { try await assertFrame("ts") }
    func testM2TS() async throws { try await assertFrame("m2ts") }
    func testMTS() async throws { try await assertFrame("mts") }
    func testWMV() async throws { try await assertFrame("wmv") }
    func testASF() async throws { try await assertFrame("asf") }
    func testFLV() async throws { try await assertFrame("flv") }
    func testOGV() async throws { try await assertFrame("ogv") }
    func testDV() async throws { try await assertFrame("dv") }
    func testF4V() async throws { try await assertFrame("f4v") }
    func testDivX() async throws { try await assertFrame("divx") }
    func testM2T() async throws { try await assertFrame("m2t") }
    func testM1V() async throws { try await assertFrame("m1v") }
    func testOGM() async throws { try await assertFrame("ogm") }
    func testRM() async throws { try await assertFrame("rm") }
    func testRMVB() async throws { try await assertFrame("rmvb") }
    func testMXF() async throws { try await assertFrame("mxf") }
    func testINSV() async throws { try await assertFrame("insv") }
    func test360() async throws { try await assertFrame("360") }

    /// RealMedia and MXF go to FFmpeg held to their one format, by their
    /// first bytes also under another name.
    func testRealMediaAndMXFAreReadByTheirContent() throws {
        for (ext, format) in [("rm", "rm"), ("mxf", "mxf")] {
            let head = try XCTUnwrap(VLCSafety.head(of: try clip(ext)))
            let reader = try XCTUnwrap(VLCSafety.reader(for: URL(fileURLWithPath: "/x/a.xyz"), head: head))
            XCTAssertEqual(reader.demux, "avformat", ext)
            XCTAssertEqual(reader.ffmpegFormat, format, ext)
        }
    }

    /// A new video extension needs a reader and a clip, or it would list
    /// videos VLC refuses to open.
    func testEveryListedVideoTypeHasAReaderAndAClip() throws {
        for ext in BrowserModel.videoExtensions.sorted() {
            XCTAssertNotNil(VLCSafety.reader(for: URL(fileURLWithPath: "/x/a.\(ext.uppercased())")), "no reader for .\(ext)")
            _ = try clip(ext)
        }
        XCTAssertNil(VLCSafety.reader(for: URL(fileURLWithPath: "/x/a.m3u8")))
        XCTAssertNil(VLCSafety.reader(for: URL(fileURLWithPath: "/x/a")))
    }

    /// A clip under another format's name (a transport stream recorded as
    /// ".mkv", a WMV named ".mkv") opens through the container its first
    /// bytes show, whatever the name; not a video at all under a video's
    /// name opens nothing.
    func testAClipUnderAnotherFormatsNameOpensByItsContent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (source, expected) in [("m2ts", "ts"), ("ts", "ts"), ("wmv", "asf"), ("mp4", "mp4"), ("avi", "avi")] {
            let renamed = dir.appendingPathComponent("\(source).mkv")
            try FileManager.default.copyItem(at: try clip(source), to: renamed)
            XCTAssertEqual(VLCSafety.reader(for: renamed, head: VLCSafety.head(of: renamed))?.demux, expected, source)
            let frame = await VLCFrameGrab.frame(of: renamed, width: 128, timeout: 8)
            XCTAssertNotNil(frame, "\(source) named .mkv")
        }
        let text = dir.appendingPathComponent("notes.mkv")
        try "not a video".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(VLCSafety.reader(for: text, head: VLCSafety.head(of: text))?.demux, "mkv", "the extension's reader")
        // VLC's Matroska reader refuses it: the grab says so long before its timeout
        try await assertRefused(text, "text named .mkv")
        XCTAssertEqual(VLCSafety.reader(for: dir.appendingPathComponent("a.xyz"), head: VLCSafety.head(of: try clip("mkv")))?.demux,
                       "mkv", "the content wins over a name that says nothing")
        XCTAssertNil(VLCSafety.reader(for: dir.appendingPathComponent("a.txt"), head: Data("#EXTM3U\n".utf8)),
                     "no video extension and no video's bytes: nothing")
    }

    /// A streaming playlist (HLS) named like a video: VLC must not follow it.
    /// Its segment is a real clip on disk, so a playlist reader that ran
    /// would come back with a picture.
    func testAPlaylistNamedLikeAVideoIsNotFollowed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = dir.appendingPathComponent("segment.ts")
        try FileManager.default.copyItem(at: try clip("ts"), to: segment)
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n\(segment.absoluteString)\n#EXT-X-ENDLIST\n"
        for ext in ["mkv", "ts", "flv", "mpg", "mp4", "avi", "wmv", "ogv", "m2v", "dv"] {
            let file = dir.appendingPathComponent("playlist.\(ext)")
            try playlist.write(to: file, atomically: true, encoding: .utf8)
            try await assertRefused(file, "a playlist named .\(ext)")
        }
    }

    /// VLC gave no picture because it refused the file or failed on it (its
    /// player's state: error, or the end with nothing shown), not because
    /// the grab timed out: a reader that followed a playlist slowly would
    /// time out too, and pass unnoticed.
    private func assertRefused(_ url: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let timeout = 30.0
        let began = Date()
        let outcome = await VLCFrameGrab.grab(of: url, width: 128, timeout: timeout)
        let took = Date().timeIntervalSince(began)
        print("\(what): \(outcome) after \(String(format: "%.2f", took)) s")
        switch outcome {
        case .refused, .failed: break
        default: XCTFail("\(what): \(outcome), not refused", file: file, line: line)
        }
        XCTAssertLessThan(took, timeout / 2, "\(what): ended by VLC, not by the timeout", file: file, line: line)
    }

    /// A file with no video (an audio-only WebM, a broken clip) ends the
    /// grab when VLC reaches its end, not at the timeout; a file no reader
    /// may open gets no player at all.
    func testAGrabWithoutAPictureEndsAtOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("broken.mkv")
        try Data(try Data(contentsOf: try clip("mkv")).prefix(600)).write(to: broken)
        try await assertRefused(broken, "a Matroska file cut off after its head")
        let download = dir.appendingPathComponent("setup.dmg.part")
        try Data(repeating: 0x42, count: 4096).write(to: download)
        let began = Date()
        let outcome = await VLCFrameGrab.grab(of: download, width: 128)
        guard case .refused = outcome else { return XCTFail("a download of a disk image: \(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "no player for a file no reader may open")
    }

    /// Options planted in the preferences VLCKit reads ("VLCParams") give
    /// way to VLCKit's own.
    func testPlantedLibraryOptionsGiveWayToVLCKitsOwn() throws {
        let defaults = TestDefaults.make("vlc")
        defaults.set(["--sout=#http{dst=:8080/x}"], forKey: "VLCParams")
        VLCSafety.forgetInjectedOptions(in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "VLCParams"), VLCSafety.libraryOptions)
    }
}
