import XCTest
import AppKit
import VLCKit
import VLCFrames
@testable import Schnellbild

/// `VLCPlaybackControl` with a real player (no view: the pictures go to its
/// `VLCFrameOutput` only): stopping while `VLCStops` is held, and Space or
/// a seek while it opens a video again in software. The player's state is
/// libVLC's own (`LibVLCVideo.playerState`).
@MainActor
final class VLCPlaybackTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITests/Fixtures/\(name)")
    }

    private static let playing: Int32 = 3, paused: Int32 = 4

    private func state(of control: VLCPlaybackControl) -> Int32 {
        guard let state = LibVLCVideo.playerState, let native = LibVLCVideo.nativePlayer(of: control.player) else { return -1 }
        return state(native)
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(what, file: file, line: line)
        return false
    }

    /// `tracks.mkv` (20 s, two subtitle tracks) playing in hardware: its
    /// subtitles off, so its tracks aren't read first.
    private func playingInHardware() async -> VLCPlaybackControl {
        let url = fixture("tracks.mkv")
        let control = VLCPlaybackControl(source: .file(url, head: VLCSafety.head(of: url)), subtitles: false, onStateChange: { _, _ in })
        control.play()
        await waitUntil("playing, its subtitle tracks known") {
            state(of: control) == Self.playing
                && ((control.player.videoSubTitlesIndexes as? [NSNumber])?.filter { $0.intValue >= 0 }.count ?? 0) == 2
        }
        try? await Task.sleep(for: .seconds(1))
        return control
    }

    private func firstSubtitle(of control: VLCPlaybackControl) -> Int? {
        (control.player.videoSubTitlesIndexes as? [NSNumber])?.map(\.intValue).first { $0 >= 0 }
    }

    /// Players stopping on a share that stalls hold every place on
    /// `VLCStops`: a video left now still stops at once, picture and sound.
    func testStoppingDoesNotWaitForTheStopQueue() async throws {
        let control = await playingInHardware()
        let gate = DispatchSemaphore(value: 0)
        for _ in 0..<4 { VLCStops.run { gate.wait() } }
        defer { for _ in 0..<4 { gate.signal() } }
        control.stop()
        await waitUntil("stopped while the queue is held", timeout: 5) {
            ![Self.playing, Self.paused].contains(state(of: control))
        }
    }

    /// Subtitles switched on while it plays in hardware open it again in
    /// software; Space pressed meanwhile holds: it opens paused.
    func testAPauseWhileOpeningAgainInSoftwareHolds() async throws {
        let control = await playingInHardware()
        defer { control.stop() }
        let before = control.player.media
        control.selectSubtitleTrack(try XCTUnwrap(firstSubtitle(of: control)))
        control.pause()
        XCTAssertFalse(control.isPlaying)
        await waitUntil("opened again in software, paused") {
            control.player.media !== before && state(of: control) == Self.paused
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(state(of: control), Self.paused, "still paused")
        XCTAssertFalse(control.isPlaying)
    }

    /// A seek meanwhile goes to the media opened again.
    func testASeekWhileOpeningAgainInSoftwareGoesThere() async throws {
        let control = await playingInHardware()
        defer { control.stop() }
        let before = control.player.media
        control.selectSubtitleTrack(try XCTUnwrap(firstSubtitle(of: control)))
        control.seek(toProgress: 0.75)
        await waitUntil("opened again in software, playing from 15 s") {
            control.player.media !== before && state(of: control) == Self.playing && control.player.time.intValue >= 14_000
        }
        XCTAssertTrue(control.isPlaying)
    }

    /// A seek made while paused (VLC reports no time while paused) is where
    /// it opens again in software, not the place before the seek.
    func testASeekWhilePausedCarriesIntoSoftware() async throws {
        let control = await playingInHardware()
        defer { control.stop() }
        control.pause()
        await waitUntil("paused") { state(of: control) == Self.paused }
        control.seek(toProgress: 0.75)
        try await Task.sleep(for: .milliseconds(300))
        let before = control.player.media
        control.selectSubtitleTrack(try XCTUnwrap(firstSubtitle(of: control)))
        await waitUntil("opened again in software, paused") {
            control.player.media !== before && state(of: control) == Self.paused
        }
        XCTAssertEqual(control.playedSeconds ?? 0, 15, accuracy: 0.5)
        control.play()
        await waitUntil("playing on from 15 s") { state(of: control) == Self.playing && control.player.time.intValue > 0 }
        XCTAssertGreaterThanOrEqual(control.player.time.intValue, 14_000, "on from the seek's target")
    }

    /// Space before the control has started (its tracks being read, no
    /// view yet) holds: it opens on its first picture and stays paused.
    func testAPauseBeforeItStartsHolds() async throws {
        let url = fixture("tracks.mkv")
        let control = VLCPlaybackControl(source: .file(url, head: VLCSafety.head(of: url)), subtitles: true, onStateChange: { _, _ in })
        defer { control.stop() }
        control.pause()
        control.attach(to: NSView())
        await waitUntil("opened, paused") { state(of: control) == Self.paused }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(state(of: control), Self.paused, "still paused")
        XCTAssertFalse(control.isPlaying)
    }

    /// A file renamed while it plays: the media opened again (in software,
    /// from the end) is the file under its new name.
    func testARenamedFileOpensUnderItsNewName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("a.mkv"), new = folder.appendingPathComponent("b.mkv")
        try FileManager.default.copyItem(at: fixture("tracks.mkv"), to: old)
        let control = VLCPlaybackControl(source: .file(old, head: VLCSafety.head(of: old)), subtitles: false, onStateChange: { _, _ in })
        defer { control.stop() }
        control.play()
        await waitUntil("playing, its subtitle tracks known") {
            state(of: control) == Self.playing
                && ((control.player.videoSubTitlesIndexes as? [NSNumber])?.filter { $0.intValue >= 0 }.count ?? 0) == 2
        }
        try FileManager.default.moveItem(at: old, to: new)
        control.follow(renamedTo: new)
        let before = control.player.media
        control.selectSubtitleTrack(try XCTUnwrap(firstSubtitle(of: control)))
        await waitUntil("opened again in software, playing") {
            control.player.media !== before && state(of: control) == Self.playing
        }
        XCTAssertEqual(control.player.media?.url?.lastPathComponent, "b.mkv")
    }

    /// A download whose data ends before the length its header states
    /// (`film.mkv.part`: 10 s, data to 5.8 s): at its end `progress` says
    /// 1, `playedSeconds` where the data ended (where a grown download
    /// opens again).
    func testADownloadEndedShortOfItsLengthSaysWhereItStood() async throws {
        let url = fixture("partial/film.mkv.part")
        let control = VLCPlaybackControl(source: .file(url, head: VLCSafety.head(of: url)), subtitles: false, onStateChange: { _, _ in })
        defer { control.stop() }
        control.play()
        await waitUntil("played to the end of its data", timeout: 30) { control.progress == 1 && !control.isPlaying }
        let length = try XCTUnwrap(control.lengthSeconds)
        XCTAssertEqual(length, 10, accuracy: 0.5)
        let stood = try XCTUnwrap(control.playedSeconds)
        XCTAssertGreaterThan(stood, 4)
        XCTAssertLessThan(stood, length - 1, "where its data ended, not its length")
    }
}
