import XCTest
import CoreImage
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

    // MARK: ASS override tags

    private let script = ASSStyles.parse("""
        [Script Info]
        PlayResX: 1280
        PlayResY: 720

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,40,40,30,1
        Style: Sign,Courier New,30,&H0000FFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,1,0,8,10,10,10,1
        """)

    func testASSStylesWithMarginsAndResolution() {
        XCTAssertEqual(script.playResX, 1280)
        XCTAssertEqual(script.playResY, 720)
        let sign = script.style("Sign")
        XCTAssertEqual(sign.alignment, 8)
        XCTAssertEqual(sign.marginL, 10)
        XCTAssertTrue(sign.bold)
        // libass's defaults: PlayResX from PlayResY (4:3) and the other way round
        XCTAssertEqual(ASSStyles.parse("[Script Info]\nPlayResY: 720").playResX, 960)
        XCTAssertEqual(ASSStyles.parse("[Script Info]\nPlayResX: 640").playResY, 480)
        XCTAssertEqual(ASSStyles.parse("").playResX, 384)
        // SSA's alignments: 5 top left, 10 middle centre
        XCTAssertEqual(ASSStyles.numpad(ssa: 5), 7)
        XCTAssertEqual(ASSStyles.numpad(ssa: 10), 5)
    }

    func testASSOverrideTags() {
        let text = ASSText.parse("{\\an8\\pos(100,50)\\an2\\pos(1,1)}A {\\b1\\c&H0000FF&}bold{\\b0\\fs+2}\\Nnext{\\fnCourier New\\i1\\u1\\s1\\bord4\\shad3\\3c&HFF0000&\\alpha&H80&}x{\\r}y\\hz",
                                 style: "Default", in: script)
        // The first \an and \pos count
        XCTAssertEqual(text.alignment, 8)
        XCTAssertEqual(text.position, ASSText.Point(x: 100, y: 50))
        XCTAssertEqual(text.lines.count, 2)
        XCTAssertEqual(text.lines[0].map(\.text), ["A ", "bold"])
        let bold = text.lines[0][1].style
        XCTAssertTrue(bold.bold)
        XCTAssertEqual(bold.primary, ASSStyles.RGBA(r: 1, g: 0, b: 0, a: 1), "&HBBGGRR&: red")
        XCTAssertEqual(text.lines[1].map(\.text), ["next", "x", "y\u{00A0}z"])
        let next = text.lines[1][0].style
        XCTAssertFalse(next.bold)
        XCTAssertEqual(next.size, 48 * 1.2, accuracy: 0.001, "\\fs+2: two tenths more, as libass")
        let x = text.lines[1][1].style
        XCTAssertEqual(x.font, "Courier New")
        XCTAssertTrue(x.italic && x.underline && x.strikeOut)
        XCTAssertEqual(x.outline, 4)
        XCTAssertEqual(x.shadow, 3)
        XCTAssertEqual(x.outlineColour.b, 1)
        XCTAssertEqual(x.primary.a, 1 - 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(x.primary.r, 1, "\\alpha leaves the colour")
        // \r: back to the event's style
        XCTAssertEqual(text.lines[1][2].style, ASSText.RunStyle(script.style("Default")))
    }

    func testASSTagsWithoutValuesAndOthers() {
        let text = ASSText.parse("{\\b1\\fs60}a{\\b\\fs\\rSign}b{\\k20\\t(0,500,\\fs80)\\move(1,2,3,4)\\fad(100,100)}c{\\p1}m 0 0 l 10 10{\\p0}d\\ne",
                                 style: "Default", in: script)
        XCTAssertEqual(text.lines.count, 1, "\\n is a space unless WrapStyle 2")
        XCTAssertEqual(text.lines[0].map(\.text), ["a", "bcd e"], "the drawing left out, the other tags passed over")
        XCTAssertEqual(text.lines[0][1].style, ASSText.RunStyle(script.style("Sign")), "\\b and \\fs without values, then \\rSign")
        XCTAssertEqual(text.alignment, 2, "the event's style's, not the \\r one's")
        XCTAssertNil(text.position)
        XCTAssertEqual(ASSText.parse("{\\q2}a\\nb", style: nil, in: script).lines.count, 2, "\\q2: \\n breaks the line")
        XCTAssertEqual(ASSText.parse("{\\a6}a", style: nil, in: script).alignment, 8, "SSA's top centre")
    }

    func testASSEventsFromTheFixture() throws {
        let read = try XCTUnwrap(SubtitleReader.lines(of: fixture("asstags.mkv"), subtitleIndex: 1, from: 2.5, to: 2.5))
        let running = read.lines.filter { $0.start <= 2.5 && 2.5 < $0.end }
        XCTAssertEqual(running.map(\.text), [["TOP LINE"], ["LEFT", "POS"]])
        XCTAssertEqual(running.first?.ass?.text, "{\\an8\\fs60\\b1\\c&H0000FF&\\3c&HFFFFFF&\\bord3}TOP LINE")
        guard case .ass(let styles) = read.kind else { return XCTFail("ASS: \(read.kind)") }
        XCTAssertEqual(styles.playResX, 1280)
        XCTAssertEqual(styles.style(running.first?.style).marginV, 30)
    }

    // MARK: The overlay

    /// What the overlay drew: the box of its pixels more than a quarter
    /// opaque (y down), and the colour at a point.
    private struct Drawn {
        let x0, x1, y0, y1: Int
        let pixel: (Int, Int) -> (r: Int, g: Int, b: Int, a: Int)
    }

    private func draw(_ events: [String], width: Int = 1280, height: Int = 720) throws -> Drawn {
        let lines = events.map { SubtitleLine(start: 0, end: 2, text: SubtitleReader.assText($0), style: "Default", ass: ASSEvent(text: $0)) }
        let image = try XCTUnwrap(SubtitleOverlay.image(lines, kind: .ass(script), width: width, height: height, decoded: nil))
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?)), row = cg.bytesPerRow
        var x0 = Int.max, x1 = -1, y0 = Int.max, y1 = -1
        for y in 0..<cg.height { for x in 0..<cg.width where bytes[y * row + x * 4 + 3] > 64 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        return Drawn(x0: x0, x1: x1, y0: y0, y1: y1) { x, y in
            let i = y * row + x * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
    }

    /// Where libass (VLC) put the same events, measured from VLC's pictures
    /// at 1280 × 720 (the pixels away from the grey by more than 40): the
    /// overlay within 2 px.
    func testTheOverlayPlacesASSLinesAsLibass() throws {
        func check(_ events: [String], _ libass: (Int, Int, Int, Int), _ what: String) throws {
            let d = try draw(events)
            XCTAssertEqual(Double(d.x0), Double(libass.0), accuracy: 2, "\(what): left")
            XCTAssertEqual(Double(d.x1), Double(libass.1), accuracy: 2, "\(what): right")
            XCTAssertEqual(Double(d.y0), Double(libass.2), accuracy: 2, "\(what): top")
            XCTAssertEqual(Double(d.y1), Double(libass.3), accuracy: 2, "\(what): bottom")
        }
        try check(["PLAIN LINE"], (525, 757, 648, 684), "the style alone")
        try check(["{\\an8\\fs60\\b1\\c&H0000FF&\\3c&HFFFFFF&\\bord3}TOP LINE"], (514, 765, 36, 83), "\\an8")
        try check(["{\\pos(320,500)\\an1\\i1\\u1\\fnCourier New\\fs40\\shad4}LEFT\\NPOS"], (318, 412, 427, 504), "\\pos")
        try check(["A {\\b1}bold{\\b0} {\\i1}italic{\\i0} {\\s1}struck{\\s0} {\\c&HFF0000&}blue{\\r} back"], (362, 919, 648, 685), "runs")
        try check(["This is a long line of subtitle text that runs well over the width between the margins of the picture"],
                  (170, 1110, 599, 693), "wrapped into two lines")
    }

    func testTheOverlayDrawsTheTagsColours() throws {
        let top = try draw(["{\\an8\\fs60\\b1\\c&H0000FF&\\3c&HFFFFFF&\\bord3}TOP LINE"])
        // The middle of the T's stem, red; the outline around it white
        var red = 0, white = 0
        for y in top.y0...top.y1 { for x in top.x0...(top.x0 + 60) {
            let p = top.pixel(x, y)
            if p.a > 250, p.r > 220, p.g < 40, p.b < 40 { red += 1 }
            if p.a > 250, p.r > 220, p.g > 220, p.b > 220 { white += 1 }
        } }
        XCTAssertGreaterThan(red, 100, "\\c&H0000FF&: red")
        XCTAssertGreaterThan(white, 100, "\\3c&HFFFFFF&: a white outline")
        let half = try draw(["{\\an5\\alpha&H80&\\bord0\\shad0}MIDDLE"])
        XCTAssertTrue((half.y0 + half.y1) / 2 > 340 && (half.y0 + half.y1) / 2 < 380, "\\an5: the middle of the picture")
        var most = 0
        for y in half.y0...half.y1 { for x in half.x0...half.x1 { most = max(most, half.pixel(x, y).a) } }
        XCTAssertEqual(Double(most), 127, accuracy: 3, "\\alpha&H80&: half see-through")
    }

    func testTheOverlayStacksEventsAtTheBottom() throws {
        let one = try draw(["PLAIN LINE"])
        let two = try draw(["PLAIN LINE", "PLAIN LINE"])
        XCTAssertEqual(two.y1, one.y1, "the first stays where it was")
        XCTAssertLessThan(two.y0, one.y0 - 40, "the second above it")
    }
}
