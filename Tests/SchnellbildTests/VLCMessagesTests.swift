import XCTest
import VLCKit
import VLCFrames
@testable import Schnellbild

/// VLC shows no messages over the video: its on-screen messages are off on
/// the player (`LibVLCVideo.hideMessages`), where its video output reads
/// the setting (a media's ":no-osd" doesn't reach it). A snapshot is what
/// makes VLC announce something there (its file's name) without its own
/// interface.
/// `grey.mp4` is even, so a message shows as text (`VLCFrameOutput.probe`);
/// decoded in software, as the app plays a video with subtitles (VLC can't
/// draw into VideoToolbox's pictures).
@MainActor
final class VLCMessagesTests: XCTestCase {
    private final class Held: @unchecked Sendable {
        let player = VLCMediaPlayer()
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITests/Fixtures/\(name)")
    }

    /// Plays `grey.mp4` with the player's media options, its messages
    /// hidden or not, takes a snapshot half a second in,
    /// and tells how many of the pictures handed over in the next 1.5 s
    /// hold text, and how many there were.
    private func picturesAfterASnapshot(hidden: Bool) async throws -> (text: Int, all: Int) {
        let options = VLCPlaybackControl.mediaOptions
        let url = fixture("grey.mp4")
        let media = VLCMedia(url: url)
        VLCSafety.restrict(media, for: url, head: VLCSafety.head(of: url))
        for option in options + [":no-audio", ":codec=avcodec,all"] { media.addOption(option) }
        let held = Held()
        // No picture of the snapshot in the corner: only the message counts
        XCTAssertTrue(LibVLCVideo.set("snapshot-preview", false, on: held.player))
        if hidden { XCTAssertTrue(LibVLCVideo.hideMessages(of: held.player), "set on the player") }
        held.player.media = media
        let output = VLCFrameOutput()
        output.attach(to: held.player)
        held.player.play()
        let started = Date()
        while output.latestPicture == nil, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(output.latestPicture, "pictures from VLC")
        var before: [String] = []
        var seen: CVPixelBuffer?
        let snapshotAt = Date().addingTimeInterval(0.5)
        while Date() < snapshotAt {
            try await Task.sleep(for: .milliseconds(5))
            guard let picture = output.latestPicture, picture !== seen else { continue }
            seen = picture
            before.append(VLCFrameOutput.probe(picture, shown: picture).map(String.init(describing:)) ?? "none")
        }
        print("VLCMessagesTests hidden \(hidden): before the snapshot: \(before.joined(separator: "; "))")
        let tree = try TempTree(self)
        held.player.saveVideoSnapshot(at: tree.root.appendingPathComponent("snapshot.png").path, withWidth: 0, andHeight: 0)
        var text = 0, all = 0
        var last: CVPixelBuffer?
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(5))
            guard let picture = output.latestPicture, picture !== last else { continue }
            last = picture
            all += 1
            let probe = VLCFrameOutput.probe(picture, shown: picture)
            if probe?.text == true { text += 1 }
            print("VLCMessagesTests hidden \(hidden): after the snapshot: \(probe.map(String.init(describing:)) ?? "none")")
        }
        await Task.detached { held.player.stop() }.value
        return (text, all)
    }

    func testVLCDrawsNoMessagesIntoThePictures() async throws {
        let shown = try await picturesAfterASnapshot(hidden: true)
        XCTAssertGreaterThan(shown.all, 5, "pictures after the snapshot")
        XCTAssertEqual(shown.text, 0, "a message drawn into \(shown.text) of \(shown.all) pictures")
        // With its messages on, VLC draws the snapshot's: the test sees one
        let messages = try await picturesAfterASnapshot(hidden: false)
        XCTAssertGreaterThan(messages.text, 0, "VLC's message with its messages on (of \(messages.all) pictures)")
    }
}
