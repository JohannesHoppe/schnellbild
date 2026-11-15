import XCTest
@testable import Schnellbild

/// The subtitle lines the app reads itself (`SubtitleReader`), from the UI
/// tests' fixtures: `tracks.mkv` (SubRip and ASS, a line every 2 s for
/// 20 s), `tracks.mp4` (two 3GPP timed text tracks), `ramp.mkv` (SubRip).
final class SubtitleLinesTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITests/Fixtures/\(name)")
    }

    func testMatroskaSubRipLinesAroundATime() throws {
        let read = try XCTUnwrap(SubtitleReader.lines(of: fixture("tracks.mkv"), subtitleIndex: 0, from: 5.3, to: 9))
        XCTAssertEqual(read.kind, .text)
        XCTAssertEqual(read.lines.first?.start ?? -1, 4, accuracy: 0.001, "the line running at 5.3 s began at 4 s")
        XCTAssertEqual(read.lines.first?.end ?? -1, 6, accuracy: 0.001)
        XCTAssertEqual(read.lines.first?.text, ["SUBTITLE ONE"])
        XCTAssertEqual(read.lines.map(\.start), [4, 6, 8])
    }

    func testMatroskaASSLinesWithTheirStyle() throws {
        let read = try XCTUnwrap(SubtitleReader.lines(of: fixture("tracks.mkv"), subtitleIndex: 1, from: 3, to: 3))
        XCTAssertEqual(read.lines.first?.text, ["UNTERTITEL ZWEI"])
        XCTAssertEqual(read.lines.first?.start ?? -1, 2, accuracy: 0.001)
        guard case .ass(let styles) = read.kind else { return XCTFail("ASS: \(read.kind)") }
        XCTAssertEqual(styles.playResY, 288)
        let style = styles.style(read.lines.first?.style)
        XCTAssertEqual(style.font, "Arial")
        XCTAssertEqual(style.size, 16)
        XCTAssertEqual(style.outline, 1)
        XCTAssertEqual(style.shadow, 0)
        XCTAssertEqual(style.marginV, 10)
        XCTAssertEqual(style.alignment, 2)
        XCTAssertEqual(style.primary, ASSStyles.RGBA(r: 1, g: 1, b: 1, a: 1))
    }

    func testMP4TimedTextLines() throws {
        let english = try XCTUnwrap(SubtitleReader.lines(of: fixture("tracks.mp4"), subtitleIndex: 0, from: 7.5, to: 7.5))
        XCTAssertEqual(english.lines.first?.text, ["SUBTITLE ONE"])
        XCTAssertEqual(english.lines.first?.start ?? -1, 6, accuracy: 0.01)
        XCTAssertEqual(english.lines.first?.end ?? -1, 8, accuracy: 0.01)
        let german = try XCTUnwrap(SubtitleReader.lines(of: fixture("tracks.mp4"), subtitleIndex: 1, from: 0.5, to: 0.5))
        XCTAssertEqual(german.lines.first?.text, ["UNTERTITEL ZWEI"])
    }

    func testNoTrackNoLines() {
        XCTAssertNil(SubtitleReader.lines(of: fixture("tracks.mkv"), subtitleIndex: 2, from: 1, to: 2))
        XCTAssertNil(SubtitleReader.lines(of: fixture("clip.mp4"), subtitleIndex: 0, from: 1, to: 2))
    }

    func testTextWithoutTags() {
        XCTAssertEqual(SubtitleReader.plainText("<i>Hello</i>\r\n<font color=\"red\">you</font>"), ["Hello", "you"])
        XCTAssertEqual(SubtitleReader.assText("{\\i1}Hello{\\i0}\\Nyou\\hthere"), ["Hello", "you there"])
    }

    func testASSColours() {
        XCTAssertEqual(ASSStyles.colour("&H00FFFFFF"), ASSStyles.RGBA(r: 1, g: 1, b: 1, a: 1))
        XCTAssertEqual(ASSStyles.colour("&H000000FF")?.r, 1)
        XCTAssertEqual(ASSStyles.colour("&H80000000")?.a ?? 0, 1 - 128.0 / 255, accuracy: 0.001)
    }
}
