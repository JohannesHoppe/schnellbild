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

    /// The reader is held to the file's format: a clip under another
    /// format's name gives no picture (VLC doesn't go looking for a reader
    /// that takes it).
    func testAClipUnderAnotherFormatsNameOpensNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renamed = dir.appendingPathComponent("clip.mkv")
        try FileManager.default.copyItem(at: try clip("wmv"), to: renamed)
        let frame = await VLCFrameGrab.frame(of: renamed, width: 128, timeout: 4)
        XCTAssertNil(frame)
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
            let frame = await VLCFrameGrab.frame(of: file, width: 128, timeout: 4)
            XCTAssertNil(frame, "a playlist named .\(ext) was followed")
        }
    }
}
