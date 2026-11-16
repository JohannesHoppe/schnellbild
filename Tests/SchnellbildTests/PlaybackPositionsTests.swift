import XCTest
@testable import Schnellbild

/// Where videos go on when the user comes back to them in the same folder
/// (`PlaybackPositions`, `BrowserModel.videoLeft`).
@MainActor
final class PlaybackPositionsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/videos", isDirectory: true)
    private var a: URL { folder.appendingPathComponent("a.mp4") }
    private var b: URL { folder.appendingPathComponent("b.mkv") }

    private func positions() -> PlaybackPositions {
        var positions = PlaybackPositions()
        positions.enter(folder)
        return positions
    }

    func testAVideoLeftGoesOnWhereItStood() {
        var p = positions()
        p.leave(a, at: 10, length: 20, playing: true, list: p.list)
        p.leave(b, at: 30.5, length: 120, playing: false, list: p.list)
        XCTAssertEqual(p.place(of: a), .init(seconds: 10, playing: true))
        XCTAssertEqual(p.place(of: b), .init(seconds: 30.5, playing: false), "paused stays paused")
        // Left again later: the newer place
        p.leave(a, at: 12, length: 20, playing: false, list: p.list)
        XCTAssertEqual(p.place(of: a), .init(seconds: 12, playing: false))
        // The same file through another spelling of its path
        XCTAssertEqual(p.place(of: URL(fileURLWithPath: "/tmp/videos/./a.mp4")), .init(seconds: 12, playing: false))
    }

    func testTheStartIsNotRemembered() {
        var p = positions()
        p.leave(a, at: 0, length: 20, playing: true, list: p.list)
        XCTAssertNil(p.place(of: a))
        p.leave(a, at: 0.4, length: 20, playing: true, list: p.list)
        XCTAssertNil(p.place(of: a), "a moment in is the start")
        // Back at the start (← to its beginning): the earlier place is forgotten
        p.leave(a, at: 10, length: 20, playing: true, list: p.list)
        p.leave(a, at: 0.2, length: 20, playing: true, list: p.list)
        XCTAssertNil(p.place(of: a))
    }

    func testAnEndedVideoStartsFromTheBeginning() {
        var p = positions()
        p.leave(a, at: 20, length: 20, playing: false, list: p.list)
        XCTAssertNil(p.place(of: a), "played to its end")
        p.leave(a, at: 18, length: 20, playing: true, list: p.list)
        XCTAssertNil(p.place(of: a), "in its last seconds")
        p.leave(a, at: 16.5, length: 20, playing: true, list: p.list)
        XCTAssertEqual(p.place(of: a)?.seconds, 16.5)
        p.leave(a, at: 19.9, length: 20, playing: false, list: p.list)
        XCTAssertNil(p.place(of: a), "watched to the end since: forgotten")
    }

    func testAPlaceNotKnownChangesNothing() {
        var p = positions()
        p.leave(a, at: 10, length: 20, playing: true, list: p.list)
        p.leave(a, at: nil, length: nil, playing: true, list: p.list)
        XCTAssertEqual(p.place(of: a)?.seconds, 10, "left before the player knew where it stood")
        p.leave(b, at: .nan, length: 20, playing: true, list: p.list)
        XCTAssertNil(p.place(of: b))
        // Without a length (a WebM from a browser) only the start counts
        p.leave(b, at: 50, length: nil, playing: true, list: p.list)
        XCTAssertEqual(p.place(of: b)?.seconds, 50)
    }

    func testAnotherFolderClearsTheMemory() {
        var p = positions()
        p.leave(a, at: 10, length: 20, playing: true, list: p.list)
        p.enter(URL(fileURLWithPath: "/tmp/videos/"))   // the same folder (read again)
        XCTAssertEqual(p.place(of: a)?.seconds, 10, "the same folder keeps it")
        let first = p.list
        p.enter(URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertNil(p.place(of: a))
        XCTAssertNotEqual(p.list, first)
        p.enter(folder)
        XCTAssertNil(p.place(of: a), "back in the folder: from the beginning")
        // A video whose view went after the folder changed belongs to none
        p.leave(a, at: 10, length: 20, playing: true, list: first)
        XCTAssertNil(p.place(of: a))
    }

    func testThePlacesFollowRenames() {
        var p = positions()
        p.leave(a, at: 10, length: 20, playing: true, list: p.list)
        p.leave(b, at: 5, length: 20, playing: true, list: p.list)
        let renamed = folder.appendingPathComponent("c.mp4")
        p.follow(FileChanges([.moved(a, to: renamed), .removed(b)]))
        XCTAssertEqual(p.place(of: renamed)?.seconds, 10)
        XCTAssertNil(p.place(of: a))
        XCTAssertNil(p.place(of: b), "trashed")
        // The folder itself renamed: the same list under its new name
        let moved = URL(fileURLWithPath: "/tmp/clips", isDirectory: true)
        let list = p.list
        p.follow(FileChanges([.moved(folder, to: moved)]))
        p.enter(moved)
        XCTAssertEqual(p.list, list)
        XCTAssertEqual(p.place(of: moved.appendingPathComponent("c.mp4"))?.seconds, 10)
    }

    // MARK: Through the model

    func testThePaneRemembersUntilItOpensAnotherFolder() async throws {
        let tree = try TempTree(self)
        let videos = try tree.folder("videos")
        let other = try tree.folder("other")
        let clip = try tree.file("videos/a.mp4")
        let m = makeModel()
        await openAndWait(m, videos)
        let player = PlayerSpy()
        player.lengthSeconds = 20
        player.playedSeconds = 9.5
        player.isPlaying = true
        m.videoLeft(clip, player: player, list: m.playbackPositions.list)
        XCTAssertEqual(m.playbackPositions.place(of: clip), .init(seconds: 9.5, playing: true))
        m.refresh()   // the listing read again
        await waitUntil { !m.isLoading }
        XCTAssertNotNil(m.playbackPositions.place(of: clip), "read again: the same folder")

        await openAndWait(m, other)
        XCTAssertNil(m.playbackPositions.place(of: clip))
        m.navigateBack()
        await waitUntil { m.isAt(videos) }
        XCTAssertNil(m.playbackPositions.place(of: clip), "back in the folder: from the beginning")

        // Each pane its own memory
        let second = makeModel()
        await openAndWait(second, videos)
        m.videoLeft(clip, player: player, list: m.playbackPositions.list)
        XCTAssertNotNil(m.playbackPositions.place(of: clip))
        XCTAssertNil(second.playbackPositions.place(of: clip))
    }

    func testARenameInTheFolderKeepsThePlace() async throws {
        let tree = try TempTree(self)
        let videos = try tree.folder("videos")
        let clip = try tree.file("videos/a.mp4")
        let m = makeModel()
        await openAndWait(m, videos)
        let player = PlayerSpy()
        player.lengthSeconds = 20
        player.playedSeconds = 7
        m.videoLeft(clip, player: player, list: m.playbackPositions.list)
        let renamed = videos.appendingPathComponent("b.mp4")
        m.apply(.moved(clip, to: renamed))
        XCTAssertEqual(m.playbackPositions.place(of: renamed)?.seconds, 7)
    }
}
