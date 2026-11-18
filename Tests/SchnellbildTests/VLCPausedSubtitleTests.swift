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
    /// VLC's messages about pausing ("toggling pause": a decoder passing the
    /// pause on to its output), with the time since the pause was asked for.
    final class PauseLog: NSObject, VLCLogging, @unchecked Sendable {
        static let shared = PauseLog()
        /// Set once for the whole run and never taken away, as the app does:
        /// with VLCKit's loggers set and reset for every pause while earlier
        /// players were still stopping, a run hung (why, not known).
        private static let once: Void = { VLCLibrary.shared().loggers = [shared] }()
        static func installed() { _ = once }
        var level: VLCLogLevel = .debug
        private let lock = NSLock()
        private var began = Date()
        private var found: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return found }
        func start(at date: Date) { lock.lock(); began = date; found = []; lock.unlock() }
        func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
            guard message.contains("toggling") else { return }
            lock.lock()
            found.append("\(context?.module ?? "-") \(message) at +\(Int(Date().timeIntervalSince(began) * 1000)) ms")
            lock.unlock()
        }
    }


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
        PauseLog.installed()
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
        let paused = Date()
        PauseLog.shared.start(at: paused)
        setPause(native, 1)
        print("before pausing at \(at): \(before.joined(separator: " "))")
        // Every picture handed over from the pause on, with when it came
        var timeline: [String] = []
        var texts: [Bool] = []
        var last: CVPixelBuffer?
        let end = paused.addingTimeInterval(3)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(2))
            guard let picture = output.latestPicture, picture !== last else { continue }
            last = picture
            let text = VLCFrameOutput.probe(picture, shown: picture)?.text ?? false
            timeline.append("+\(Int(Date().timeIntervalSince(paused) * 1000)):\(text ? "T" : "-")")
            // The pictures after the video output has paused (the last ones it shows again and again)
            if Date().timeIntervalSince(paused) > 0.5 { texts.append(text) }
        }
        let pausedAt = getTime(native)
        // Stopped before the next one starts (VLC waits for its threads there)
        await Task.detached { held.player.stop() }.value
        print("after pausing at \(pausedAt) ms: \(timeline.prefix(12).joined(separator: " ")); \(PauseLog.shared.lines.joined(separator: "; "))")
        return (pausedAt, texts)
    }

    private func check(track: Int, _ name: String) async throws {
        var failures: [String] = []
        for at: Int64 in [700, 1500] + Array(stride(from: 1900, through: 2100, by: 10)) + [3950, 4000, 4050] {
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
