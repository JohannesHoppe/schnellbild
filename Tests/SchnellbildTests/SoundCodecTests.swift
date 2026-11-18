import XCTest
@preconcurrency import VLCKit

/// Sound VLC decodes through FFmpeg: AC-3 and E-AC-3 (Dolby Digital and
/// Dolby Digital Plus, common in films and TV recordings). The bundled
/// VLCKit is built without FFmpeg's AArch64 AC-3 DSP and CRC code (their
/// files state the GPL; Scripts/vlc-patches/0006), so FFmpeg's C versions do
/// that work. Each clip (`Scripts/make_video_fixtures.sh sound`) is 2 s of a
/// 440 Hz tone; libVLC's audio callbacks take what VLC decodes, which must be
/// that tone.
final class SoundCodecTests: XCTestCase {
    func testAC3() async throws { try await assertTone("ac3") }
    func testEAC3() async throws { try await assertTone("eac3") }

    private func assertTone(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "Videos"),
                                "missing \(name).mkv", file: file, line: line)
        let sound = try await DecodedSound.of(url, seconds: 1)
        XCTAssertGreaterThanOrEqual(sound.frames, 48_000, "VLC decoded too little of \(name).mkv", file: file, line: line)
        // ffmpeg's sine at its amplitude of 1/8 (RMS about 2900 of 32767;
        // about 2000 come out of VLC): far above silence
        XCTAssertGreaterThan(sound.rms, 1000, "\(name).mkv decoded to silence", file: file, line: line)
        XCTAssertEqual(sound.frequency, 440, accuracy: 15, "\(name).mkv's tone", file: file, line: line)
    }
}

/// What libVLC's audio callbacks hand over for a file: 16-bit stereo at
/// 48 kHz, the first channel kept.
private final class DecodedSound: @unchecked Sendable {   // state behind `lock`
    private let lock = NSLock()
    private var left: [Int16] = []
    private let wanted: Int

    private init(frames: Int) { wanted = frames }

    var frames: Int { lock.withLock { left.count } }

    /// Root mean square of the first channel.
    var rms: Double {
        lock.withLock {
            guard !left.isEmpty else { return 0 }
            return (left.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(left.count)).squareRoot()
        }
    }

    /// The tone's frequency by its rising zero crossings, the first 0.1 s
    /// (the decoder's start) left out.
    var frequency: Double {
        lock.withLock {
            let samples = left.dropFirst(4800)
            guard samples.count > 4800 else { return 0 }
            var crossings = 0
            var previous = samples.first!
            for sample in samples.dropFirst() {
                if previous < 0 && sample >= 0 { crossings += 1 }
                previous = sample
            }
            return Double(crossings) / (Double(samples.count) / 48_000)
        }
    }

    private func take(_ samples: UnsafeRawPointer, count: Int) -> Bool {
        let stereo = samples.bindMemory(to: Int16.self, capacity: count * 2)
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<count { left.append(stereo[i * 2]) }
        return left.count >= wanted
    }

    /// Plays `url` to libVLC's audio callbacks until `seconds` of sound have
    /// come (or 15 s have passed). The player is libVLC's own, made, stopped
    /// and released here, the release awaited, so no two tests' players
    /// live at once. VLCKit releases its players later, on a queue of its
    /// own: with the AC-3 test's player still being destroyed there, the
    /// E-AC-3 test hung (run 44318947133) waiting to write VLC's
    /// configuration (the CoreAudio output a new player makes at once and
    /// the audio callbacks replace stores its device there as it closes)
    /// while another thread waited to read it; which thread held the lock
    /// isn't known.
    static func of(_ url: URL, seconds: Double) async throws -> DecodedSound {
        let vlc = try LibVLC()
        let sound = DecodedSound(frames: Int(seconds * 48_000))
        let instance = try XCTUnwrap(VLCLibrary.shared().instance)
        let media = try XCTUnwrap(url.path.withCString { vlc.mediaNewPath(instance, $0) })
        ":no-video".withCString { vlc.mediaAddOption(media, $0) }
        let player = try XCTUnwrap(vlc.playerNewFromMedia(media))
        vlc.mediaRelease(media)
        let opaque = Unmanaged.passRetained(sound).toOpaque()
        vlc.setCallbacks(player, { opaque, samples, count, _ in
            guard let opaque, let samples else { return }
            _ = Unmanaged<DecodedSound>.fromOpaque(opaque).takeUnretainedValue().take(samples, count: Int(count))
        }, nil, nil, nil, nil, opaque)
        "S16N".withCString { vlc.setFormat(player, $0, 48_000, 2) }
        _ = vlc.play(player)
        let deadline = Date().addingTimeInterval(15)
        while sound.frames < sound.wanted, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Stopped and released before the next test makes a player; the
        // callbacks' reference goes once nothing can call them any more
        let held = Held(player)
        await Task.detached {
            vlc.stop(held.player)
            vlc.playerRelease(held.player)
        }.value
        Unmanaged<DecodedSound>.fromOpaque(opaque).release()
        return sound
    }
}

/// A libVLC player handed to the thread that stops it.
private final class Held: @unchecked Sendable {
    let player: OpaquePointer
    init(_ player: OpaquePointer) { self.player = player }
}

/// The libVLC functions the test calls, looked up in VLCKit.
private struct LibVLC: @unchecked Sendable {
    typealias Play = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, Int64) -> Void
    typealias Pause = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Void
    typealias Drain = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let mediaNewPath: @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> OpaquePointer?
    let mediaAddOption: @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Void
    let mediaRelease: @convention(c) (OpaquePointer) -> Void
    let playerNewFromMedia: @convention(c) (OpaquePointer) -> OpaquePointer?
    let setCallbacks: @convention(c) (OpaquePointer, Play, Pause?, Pause?, Pause?, Drain?, UnsafeMutableRawPointer?) -> Void
    let setFormat: @convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt32, UInt32) -> Void
    let play: @convention(c) (OpaquePointer) -> Int32
    let stop: @convention(c) (OpaquePointer) -> Void
    let playerRelease: @convention(c) (OpaquePointer) -> Void

    init() throws {
        let handle = dlopen(nil, RTLD_NOW)
        func find<T>(_ name: String, _: T.Type) throws -> T {
            unsafeBitCast(try XCTUnwrap(dlsym(handle, name), "no \(name)"), to: T.self)
        }
        mediaNewPath = try find("libvlc_media_new_path", (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> OpaquePointer?).self)
        mediaAddOption = try find("libvlc_media_add_option", (@convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Void).self)
        mediaRelease = try find("libvlc_media_release", (@convention(c) (OpaquePointer) -> Void).self)
        playerNewFromMedia = try find("libvlc_media_player_new_from_media", (@convention(c) (OpaquePointer) -> OpaquePointer?).self)
        setCallbacks = try find("libvlc_audio_set_callbacks",
                                (@convention(c) (OpaquePointer, Play, Pause?, Pause?, Pause?, Drain?, UnsafeMutableRawPointer?) -> Void).self)
        setFormat = try find("libvlc_audio_set_format", (@convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt32, UInt32) -> Void).self)
        play = try find("libvlc_media_player_play", (@convention(c) (OpaquePointer) -> Int32).self)
        stop = try find("libvlc_media_player_stop", (@convention(c) (OpaquePointer) -> Void).self)
        playerRelease = try find("libvlc_media_player_release", (@convention(c) (OpaquePointer) -> Void).self)
    }
}
