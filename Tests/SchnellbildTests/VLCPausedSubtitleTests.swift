import XCTest
import VLCKit
import VLCFrames
@testable import Schnellbild

/// A video paused while a subtitle line shows keeps showing it, also
/// paused just before the line ends: VLC hands over its picture again and
/// again while paused, with the subtitles drawn into it for the time it was
/// paused at. `tracks.mkv` (lines every 2 s, SubRip and ASS) through a
/// `VLCFrameOutput`, decoded in software with the track chosen from the
/// start, as the app plays it; the pictures as VLC hands them over.
@MainActor
final class VLCPausedSubtitleTests: XCTestCase {
    private final class Held: @unchecked Sendable {
        let player = VLCMediaPlayer()
    }

    private typealias GetTime = @convention(c) (OpaquePointer) -> Int64
    private typealias SetPause = @convention(c) (OpaquePointer, Int32) -> Void
    private static let getTime: GetTime? = dlsym(dlopen(nil, RTLD_NOW), "libvlc_media_player_get_time")
        .map { unsafeBitCast($0, to: GetTime.self) }
    private static let setPause: SetPause? = dlsym(dlopen(nil, RTLD_NOW), "libvlc_media_player_set_pause")
        .map { unsafeBitCast($0, to: SetPause.self) }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITests/Fixtures/\(name)")
    }

    /// Plays `tracks.mkv` with subtitle track `track` (3 SubRip, 4 ASS),
    /// pauses once VLC's time passes `at` ms, and reads the pictures VLC
    /// hands over for the next three seconds: whether each holds text.
    private func pausedPictures(track: Int, at: Int64) async throws -> (pausedAt: Int64, texts: [Bool]) {
        let url = fixture("tracks.mkv")
        let media = VLCMedia(url: url)
        VLCSafety.restrict(media, for: url, head: VLCSafety.head(of: url))
        for option in [":no-audio", ":no-osd", ":no-play-and-pause", ":codec=avcodec,all", ":sub-track-id=\(track)"] {
            media.addOption(option)
        }
        let held = Held()
        held.player.media = media
        let output = VLCFrameOutput()
        output.attach(to: held.player)
        held.player.play()
        defer { let held = held; Task.detached { held.player.stop() } }
        let native = try XCTUnwrap(LibVLCVideo.nativePlayer(of: held.player))
        let getTime = try XCTUnwrap(Self.getTime), setPause = try XCTUnwrap(Self.setPause)
        let deadline = Date().addingTimeInterval(15)
        // The pictures before the pause too: did the line show while playing?
        var before: [String] = []
        var seenBefore: CVPixelBuffer?
        while getTime(native) < at, Date() < deadline {
            if let picture = output.latestPicture, picture !== seenBefore, getTime(native) > at - 400 {
                seenBefore = picture
                before.append("\(getTime(native)):\(VLCFrameOutput.probe(picture, shown: picture)?.text == true ? "T" : "-")")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        setPause(native, 1)
        print("before pausing at \(at): \(before.joined(separator: " "))")
        try await Task.sleep(for: .milliseconds(300))
        let pausedAt = getTime(native)
        var texts: [Bool] = []
        var last: CVPixelBuffer?
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(50))
            guard let picture = output.latestPicture, picture !== last else { continue }
            last = picture
            texts.append(VLCFrameOutput.probe(picture, shown: picture)?.text ?? false)
        }
        return (pausedAt, texts)
    }

    private func check(track: Int, _ name: String) async throws {
        var failures: [String] = []
        for at: Int64 in [700, 1500, 1800, 1900, 1950, 1975, 2000, 2025, 2050, 2075, 2100, 2150, 3850, 3950, 4000, 4050] {
            let (pausedAt, texts) = try await pausedPictures(track: track, at: at)
            let shown = texts.map { $0 ? "T" : "-" }.joined()
            print("\(name) paused at \(pausedAt) ms (asked \(at)): \(shown)")
            XCTAssertFalse(texts.isEmpty, "\(name) at \(at): pictures while paused")
            if !texts.allSatisfy({ $0 }) { failures.append("\(pausedAt) ms: \(shown)") }
        }
        XCTAssertTrue(failures.isEmpty, "\(name): paused with no line: \(failures.joined(separator: "; "))")
    }

    func testSubRipStaysWhilePaused() async throws { try await check(track: 3, "SubRip") }
    func testASSStaysWhilePaused() async throws { try await check(track: 4, "ASS") }
}
