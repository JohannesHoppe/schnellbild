import XCTest
import CoreImage
@testable import Schnellbild

/// Subtitles from files someone else made (`SubtitleReader`, `ASSStyles`,
/// `ASSText`, `SubtitleOverlay`): crafted Matroska files whose offsets and
/// times run past UInt64's and Int64's range, ASS events with NaN and
/// infinite numbers, and thousands of damaged copies of the fixtures from a
/// fixed seed. None may trap; what is read stays finite.
final class SubtitleReaderFuzzTests: XCTestCase {
    /// A fixed-seed generator, so a failure can be run again.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Counts the reads that reach the bytes (each one a round trip on a share).
    private final class CountedBytes: ByteSource {
        let bytes: MemoryBytes
        var reads = 0
        init(_ bytes: [UInt8]) { self.bytes = MemoryBytes(bytes) }
        var size: UInt64 { bytes.size }
        func read(at offset: UInt64, count: Int) -> [UInt8]? {
            reads += 1
            return bytes.read(at: offset, count: count)
        }
    }

    private func fixture(_ name: String) throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITests/Fixtures/\(name)")
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: Matroska built element by element

    /// An element with an eight-byte size.
    private func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
        var bytes = Array(withUnsafeBytes(of: id.bigEndian, Array.init).drop(while: { $0 == 0 }))
        bytes.append(0x01)
        bytes += withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init).dropFirst()
        return bytes + payload
    }

    private func number(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        element(id, withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    private struct Cluster {
        var time: UInt64
        /// (start relative to the cluster, duration, text) of track 1.
        var lines: [(Int16, UInt64, String)] = []
        /// Video frames of track 2, each this many bytes.
        var frames = 0
        var frameSize = 0
    }

    /// A Matroska file: track 1 subtitles (`codec`), track 2 video,
    /// optionally a SeekHead and Cues, then the clusters (of unknown size,
    /// as a live recording writes them, with `unknownSizes`).
    private func matroska(codec: String = "S_TEXT/UTF8", codecPrivate: String? = nil,
                          seekHead: [UInt8]? = nil, cues: [UInt8]? = nil, clusters: [Cluster],
                          unknownSizes: Bool = false) -> [UInt8] {
        let header = element(0x1A45DFA3, number(0x4282, 0))
        let info = element(0x1549A966, number(0x2AD7B1, 1_000_000))
        var subtitle = number(0xD7, 1) + number(0x83, 0x11) + element(0x86, Array(codec.utf8))
        if let codecPrivate { subtitle += element(0x63A2, Array(codecPrivate.utf8)) }
        let video = number(0xD7, 2) + number(0x83, 1) + element(0x86, Array("V_MPEG4/ISO/AVC".utf8))
        let tracks = element(0x1654AE6B, element(0xAE, subtitle) + element(0xAE, video))
        var body = info + tracks
        if let seekHead { body += seekHead }
        if let cues { body += cues }
        for cluster in clusters {
            var content = number(0xE7, cluster.time)
            for (start, duration, text) in cluster.lines {
                let block = [0x81] + withUnsafeBytes(of: start.bigEndian, Array.init) + [0x00] + Array(text.utf8)
                content += element(0xA0, element(0xA1, block) + number(0x9B, duration))
            }
            for _ in 0..<cluster.frames {
                content += element(0xA3, [0x82, 0, 0, 0x80] + [UInt8](repeating: 0x55, count: cluster.frameSize))
            }
            body += unknownSizes ? [0x1F, 0x43, 0xB6, 0x75, 0x01] + [UInt8](repeating: 0xFF, count: 7) + content
                                 : element(0x1F43B675, content)
        }
        return header + element(0x18538067, body)
    }

    private func seekHeadToCues(at position: [UInt8]) -> [UInt8] {
        element(0x114D9B74, element(0x4DBB, element(0x53AB, [0x1C, 0x53, 0xBB, 0x6B]) + element(0x53AC, position)))
    }

    private func cue(time: UInt64, position: [UInt8]) -> [UInt8] {
        element(0x1C53BB6B, element(0xBB, number(0xB3, time) + element(0xB7, number(0xF7, 1) + element(0xF1, position))))
    }

    private let twoLines = [Cluster(time: 0, lines: [(1000, 1000, "ONE"), (3000, 1000, "TWO")])]

    /// A SeekHead whose Cues lie at 2⁶⁴ − 1 bytes into the segment: the
    /// place is dropped, the lines are read from the first cluster.
    func testASeekHeadPastUInt64DoesNotTrap() throws {
        let file = matroska(seekHead: seekHeadToCues(at: [UInt8](repeating: 0xFF, count: 8)), clusters: twoLines)
        let read = try XCTUnwrap(SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 1.5, to: 5))
        XCTAssertEqual(read.lines.map(\.text), [["ONE"], ["TWO"]])
    }

    /// A cue at time 0 whose cluster lies at 2⁶⁴ − 1: the same.
    func testACuePastUInt64DoesNotTrap() throws {
        let file = matroska(cues: cue(time: 0, position: [UInt8](repeating: 0xFF, count: 8)), clusters: twoLines)
        let read = try XCTUnwrap(SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 1.5, to: 5))
        XCTAssertEqual(read.lines.map(\.text), [["ONE"], ["TWO"]])
        // And one that points past the file
        let past = matroska(cues: cue(time: 0, position: [0x7F, 0, 0, 0, 0, 0, 0, 0]), clusters: twoLines)
        XCTAssertEqual(SubtitleReader.lines(in: MemoryBytes(past), subtitleIndex: 0, from: 1.5, to: 5)?.lines.count, 2)
    }

    /// A cluster time beyond Int64 (and a block going back from it) gives
    /// a line at a finite time, not a trap.
    func testAClusterTimePastInt64DoesNotTrap() {
        for time in [UInt64.max, UInt64(Int64.max), UInt64(Int64.max) + 1] {
            let file = matroska(clusters: [Cluster(time: time, lines: [(-32768, 1000, "LATE"), (32767, 1000, "LATER")])])
            let read = SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 0, to: .greatestFiniteMagnitude)
            for line in read?.lines ?? [] {
                XCTAssertTrue(line.start.isFinite && line.end.isFinite, "\(time): \(line)")
            }
        }
        // Times asked for that are no times
        for from in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            _ = SubtitleReader.lines(in: MemoryBytes(matroska(clusters: twoLines)), subtitleIndex: 0, from: from, to: from)
        }
    }

    /// ASS events whose numbers are NaN, infinite or past Int's range: the
    /// event reads with ReadOrder 0 and the style's margins.
    func testASSNumbersThatAreNoNumbersDoNotTrap() throws {
        let script = """
            [Script Info]
            PlayResX: nan
            PlayResY: inf

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,1e999,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,nan,inf,2,-inf,1e308,nan,1
            """
        let events = ["nan,0,Default,,0,0,0,,NAN", "inf,0,Default,,nan,inf,1e400,,INF", "1e999,0,Default,,1e18,-1e18,0,,BIG",
                      "-9223372036854775809,0,Default,,0,0,0,,{\\fsnan\\pos(nan,inf)\\bord1e999\\shadinf\\fs+1e300}TAGS"]
        let file = matroska(codec: "S_TEXT/ASS", codecPrivate: script,
                            clusters: [Cluster(time: 0, lines: events.enumerated().map { (Int16($0.offset * 1000), 1000, $0.element) })])
        let read = try XCTUnwrap(SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 0, to: 10))
        XCTAssertEqual(read.lines.count, 4)
        for line in read.lines {
            let event = try XCTUnwrap(line.ass)
            XCTAssertEqual(event.readOrder, 0, line.text.joined())
            XCTAssertTrue(event.marginL.isFinite && event.marginR.isFinite && event.marginV.isFinite)
        }
        guard case .ass(let styles) = read.kind else { return XCTFail("ASS") }
        XCTAssertTrue(styles.playResX.isFinite && styles.playResX > 0 && styles.playResY.isFinite && styles.playResY > 0)
        let style = styles.style("Default")
        for value in [style.size, style.outline, style.shadow, style.marginL, style.marginR, style.marginV] {
            XCTAssertTrue(value.isFinite, "\(style)")
        }
        let tags = ASSText.parse(events[3].components(separatedBy: ",,").last ?? "", style: "Default", in: styles)
        XCTAssertNil(tags.position, "no \\pos of NaN")
        for run in tags.lines.flatMap({ $0 }) { XCTAssertTrue(run.style.size.isFinite && run.style.outline.isFinite) }
        // Drawn without trapping
        _ = SubtitleOverlay.image(read.lines, kind: read.kind, width: 320, height: 180, decoded: nil)
    }

    // MARK: Damaged fixtures

    func testDamagedSubtitleFilesNeverTrap() throws {
        var random = SplitMix(state: 1117)
        let fixtures = [("tracks.mkv", 2), ("asstags.mkv", 2), ("ramp.mkv", 1), ("tracks.mp4", 2)]
        for (name, tracks) in fixtures {
            let original = try fixture(name)
            for round in 0..<600 {
                var damaged = original
                for _ in 0..<(1 + round % 24) {
                    let at = Int.random(in: 0..<damaged.count, using: &random)
                    // Some runs of 0xFF (sizes, offsets and times at their largest), else any byte
                    if round % 3 == 0 {
                        for i in at..<min(at + 8, damaged.count) { damaged[i] = 0xFF }
                    } else {
                        damaged[at] = UInt8.random(in: 0...255, using: &random)
                    }
                }
                if round % 7 == 0 { damaged = Array(damaged.prefix(Int.random(in: 0..<damaged.count, using: &random))) }
                let from = Double.random(in: -5...25, using: &random)
                let read = SubtitleReader.lines(in: MemoryBytes(damaged), subtitleIndex: round % tracks, from: from, to: from + 60)
                for line in read?.lines ?? [] {
                    XCTAssertTrue(line.start.isFinite && line.end.isFinite, "\(name) round \(round): \(line)")
                }
                if round % 50 == 0, let read {
                    _ = SubtitleOverlay.image(read.lines.prefix(3).map { $0 }, kind: read.kind, width: 160, height: 90, decoded: nil)
                }
            }
        }
    }

    /// Random ASS headers and override blocks made of the characters that matter.
    func testRandomASSScriptsAndTagsNeverTrap() {
        var random = SplitMix(state: 42)
        let pieces = ["\\fs", "\\pos(", ",", ")", "\\an", "\\a", "\\b", "\\c&H", "&", "\\alpha", "\\bord", "\\shad", "\\r", "\\q",
                      "\\p", "\\N", "\\n", "\\h", "{", "}", "nan", "inf", "-", "+", "1e999", "9", "0", ".", "FF", "Sign", " "]
        func noise(_ count: Int) -> String {
            (0..<count).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &random)] }.joined()
        }
        for _ in 0..<2_000 {
            let styles = ASSStyles.parse("""
                [Script Info]
                PlayResX: \(noise(2))
                PlayResY: \(noise(2))
                WrapStyle: \(noise(1))

                [V4+ Styles]
                Format: Name, Fontname, Fontsize, PrimaryColour, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
                Style: Default,Arial,\(noise(2)),\(noise(2)),\(noise(2)),\(noise(2)),\(noise(1)),\(noise(2)),\(noise(2)),\(noise(2))
                """)
            XCTAssertTrue(styles.playResX.isFinite && styles.playResY.isFinite)
            let text = ASSText.parse(noise(12), style: "Default", in: styles)
            if let position = text.position { XCTAssertTrue(position.x.isFinite && position.y.isFinite) }
            for run in text.lines.flatMap({ $0 }) { XCTAssertTrue(run.style.size.isFinite) }
        }
    }

    // MARK: Reading little, in time

    /// A file without Cues, the lines asked for near its end: the clusters
    /// before are passed by their heads, one read each, not block by block.
    func testWithoutCuesTheClustersArePassedByTheirHeads() throws {
        let clusters = (0..<400).map { second in
            Cluster(time: UInt64(second) * 1000, lines: [(100, 800, "LINE \(second)")], frames: 30, frameSize: 3_000)
        }
        let source = CountedBytes(matroska(clusters: clusters))
        let read = try XCTUnwrap(SubtitleReader.lines(in: source, subtitleIndex: 0, from: 380.5, to: 382.5))
        XCTAssertEqual(read.lines.map(\.text), [["LINE 380"], ["LINE 381"], ["LINE 382"]])
        print("\(source.reads) reads for 400 clusters of 31 blocks")
        // 360 clusters passed with one read each; the last 40 s (reach) read
        // through the window: about 1.5 reads a cluster
        XCTAssertLessThan(source.reads, 360 + 40 * 4, "the clusters before the time are passed by their heads")
    }

    /// Clusters of unknown size (a live recording): each ends where the
    /// next begins, the lines of every cluster are read.
    func testClustersOfUnknownSizeAreReadOneAfterTheOther() throws {
        let clusters = (0..<4).map { second in
            Cluster(time: UInt64(second) * 1000, lines: [(100, 800, "LINE \(second)")], frames: 3, frameSize: 100)
        }
        let file = matroska(clusters: clusters, unknownSizes: true)
        let read = try XCTUnwrap(SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 0, to: 4))
        XCTAssertEqual(read.lines.map(\.text), [["LINE 0"], ["LINE 1"], ["LINE 2"], ["LINE 3"]])
    }

    /// Past its budget (or cancelled) a read gives up: VLC takes the track.
    func testAReadPastItsBudgetGivesNoLines() async throws {
        let file = matroska(clusters: twoLines)
        XCTAssertNotNil(SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 1.5, to: 5))
        XCTAssertNil(SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 1.5, to: 5, budget: -1))
        XCTAssertNil(SubtitleReader.lines(in: MemoryBytes(try fixture("tracks.mp4")), subtitleIndex: 0, from: 1, to: 5, budget: -1))
        let cancelled = await Task.detached { () -> SubtitleTrackLines? in
            withUnsafeCurrentTask { $0?.cancel() }
            return SubtitleReader.lines(in: MemoryBytes(file), subtitleIndex: 0, from: 1.5, to: 5)
        }.value
        XCTAssertNil(cancelled, "cancelled: none")
    }
}
