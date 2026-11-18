import XCTest
@preconcurrency import VLCKit

/// Many libVLC players at once, as in the app (tiles' frame grabs, the
/// video playing) and in the unit tests: each one makes its CoreAudio
/// output at once and closes it again as its audio goes to callbacks or the
/// player is released. The outputs open and close side by side on several
/// threads; none may wait for ever (Scripts/vlc-patches/0008: the output
/// writes nothing to VLC's configuration, whose lock a closing output took
/// for writing while others read it, and a test process hung there).
final class VLCAudioOutputTests: XCTestCase {
    private typealias NewPlayer = @convention(c) (UnsafeMutableRawPointer) -> OpaquePointer?
    private typealias Release = @convention(c) (OpaquePointer) -> Void
    private typealias Play = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, Int64) -> Void
    private typealias Pause = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Void
    private typealias Drain = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetCallbacks = @convention(c) (OpaquePointer, Play, Pause?, Pause?, Pause?, Drain?, UnsafeMutableRawPointer?) -> Void

    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testPlayersMadeAndReleasedSideBySideNeverHang() throws {
        let handle = dlopen(nil, RTLD_NOW)
        let newPlayer = unsafeBitCast(try XCTUnwrap(dlsym(handle, "libvlc_media_player_new")), to: NewPlayer.self)
        let release = unsafeBitCast(try XCTUnwrap(dlsym(handle, "libvlc_media_player_release")), to: Release.self)
        let setCallbacks = unsafeBitCast(try XCTUnwrap(dlsym(handle, "libvlc_audio_set_callbacks")), to: SetCallbacks.self)
        let instance = try XCTUnwrap(VLCLibrary.shared().instance)
        let threads = 8, rounds = 1_500
        let done = Done()
        for thread in 0..<threads {
            Thread.detachNewThread {
                for round in 0..<rounds {
                    guard let player = newPlayer(instance) else { continue }
                    // Every other one hands its audio to callbacks (the output closes now),
                    // the others close theirs as the player goes
                    if (thread + round) % 2 == 0 {
                        setCallbacks(player, { _, _, _, _ in }, nil, nil, nil, nil, nil)
                    }
                    release(player)
                }
                done.add()
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while done.value < threads, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(done.value, threads, "players made and released on \(threads) threads: some waited for ever")
    }
}
