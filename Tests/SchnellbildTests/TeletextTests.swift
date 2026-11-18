import XCTest
@preconcurrency import VLCKit
import VLCFrames

/// Teletext subtitles (DVB recordings) reach the picture: VLC's own
/// Teletext decoder (telx; the bundled VLCKit has no libzvbi, whose packet
/// 8/30 and PDC decoders are under the GPL) turns page 888 of
/// `teletext.ts` (`Scripts/make_video_fixtures.sh teletext`: even grey, one
/// line in white from the start) into text, which VLC draws into the
/// pictures it decodes in software, as the app plays a video with
/// subtitles on (`:codec=avcodec,all`, the subtitle track chosen from the
/// start).
final class TeletextTests: XCTestCase {
    func testTheTeletextLineIsDrawnIntoThePicture() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "teletext", withExtension: "ts", subdirectory: "Videos"))
        let withLine = try await Pictures.of(url, options: [":codec=avcodec,all", ":sub-track=0"])
        let without = try await Pictures.of(url, options: [":codec=avcodec,all", ":no-spu"])
        let lower = withLine.marked(fromRow: withLine.height * 2 / 3)
        XCTAssertGreaterThan(lower, 200, "no Teletext line in the lower third (\(withLine.marked(fromRow: 0)) pixels "
                             + "other than the grey in the whole picture, \(withLine.pictures) pictures)")
        XCTAssertEqual(without.marked(fromRow: 0), 0, "the grey is even without subtitles")
        XCTAssertEqual(withLine.marked(fromRow: 0, toRow: withLine.height / 2), 0, "the line is at the bottom")
    }
}

/// The 30th picture VLC shows of a video (1.2 s at 25 frames a second),
/// as RGBA through libVLC's video callbacks.
private final class Pictures: @unchecked Sendable {   // state behind `lock`
    let width = 640, height = 360
    private let lock = NSLock()
    private let buffer: UnsafeMutableRawPointer
    private var shown = 0
    private var kept: [UInt8] = []

    private init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: 640 * 360 * 4, alignment: 16)
    }

    /// Pixels more than 40 away from the video's grey (128) in any channel:
    /// the line's letters and their outline, in rows `fromRow` up to `toRow`
    /// (the end).
    func marked(fromRow: Int, toRow: Int? = nil) -> Int {
        lock.withLock {
            guard !kept.isEmpty else { return -1 }
            var count = 0
            for y in fromRow..<(toRow ?? height) {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if (0..<3).contains(where: { abs(Int(kept[i + $0]) - 128) > 40 }) { count += 1 }
                }
            }
            return count
        }
    }

    private func display() {
        lock.withLock {
            shown += 1
            if shown == 30 {
                kept = Array(UnsafeRawBufferPointer(start: buffer, count: width * height * 4))
            }
        }
    }

    private var done: Bool { lock.withLock { !kept.isEmpty } }
    var pictures: Int { lock.withLock { shown } }

    static func of(_ url: URL, options: [String]) async throws -> Pictures {
        let api = try XCTUnwrap(LibVLCVideo.shared)
        // Held for good: VLC's video output may call in until the player
        // is released, after the test
        let pictures = Pictures()
        let opaque = Unmanaged.passRetained(pictures).toOpaque()
        let media = VLCMedia(url: url)
        VLCSafety.restrict(media, for: url, head: VLCSafety.head(of: url))
        for option in options + [":no-audio", ":no-osd"] { media.addOption(option) }
        let player = VLCMediaPlayer()
        player.media = media
        let native = try XCTUnwrap(LibVLCVideo.nativePlayer(of: player))
        api.setCallbacks(native, { opaque, planes in
            planes?.pointee = Unmanaged<Pictures>.fromOpaque(opaque!).takeUnretainedValue().buffer
            return nil
        }, { _, _, _ in }, { opaque, _ in
            Unmanaged<Pictures>.fromOpaque(opaque!).takeUnretainedValue().display()
        }, opaque)
        api.setFormatCallbacks(native, { opaque, chroma, width, height, pitches, lines in
            for (i, c) in "RGBA".utf8.enumerated() { chroma![i] = CChar(bitPattern: c) }
            width!.pointee = 640
            height!.pointee = 360
            pitches![0] = 640 * 4
            lines![0] = 360
            return 1
        }, { _ in })
        player.play()
        let deadline = Date().addingTimeInterval(15)
        while !pictures.done, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        DispatchQueue.global().async { player.stop() }
        return pictures
    }
}
