import XCTest
@preconcurrency import VLCKit
import VLCFrames

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
    /// come (or 15 s have passed).
    static func of(_ url: URL, seconds: Double) async throws -> DecodedSound {
        let handle = dlopen(nil, RTLD_NOW)
        typealias Play = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, Int64) -> Void
        typealias Pause = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Void
        typealias Drain = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias SetCallbacks = @convention(c) (OpaquePointer, Play, Pause?, Pause?, Pause?, Drain?, UnsafeMutableRawPointer?) -> Void
        typealias SetFormat = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt32, UInt32) -> Void
        let callbacks = try XCTUnwrap(dlsym(handle, "libvlc_audio_set_callbacks"))
        let format = try XCTUnwrap(dlsym(handle, "libvlc_audio_set_format"))
        let setCallbacks = unsafeBitCast(callbacks, to: SetCallbacks.self)
        let setFormat = unsafeBitCast(format, to: SetFormat.self)

        let sound = DecodedSound(frames: Int(seconds * 48_000))
        let media = VLCMedia(url: url)
        media.addOption(":no-video")
        let player = VLCMediaPlayer()
        player.media = media
        let native = try XCTUnwrap(LibVLCVideo.nativePlayer(of: player))
        // Held for good: VLC's audio thread may call in until the player is
        // released, after the test
        let opaque = Unmanaged.passRetained(sound).toOpaque()
        setCallbacks(native, { opaque, samples, count, _ in
            guard let opaque, let samples else { return }
            _ = Unmanaged<DecodedSound>.fromOpaque(opaque).takeUnretainedValue().take(samples, count: Int(count))
        }, nil, nil, nil, nil, opaque)
        "S16N".withCString { setFormat(native, $0, 48_000, 2) }
        player.play()
        let deadline = Date().addingTimeInterval(15)
        while sound.frames < sound.wanted, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        DispatchQueue.global().async { player.stop() }
        return sound
    }
}
