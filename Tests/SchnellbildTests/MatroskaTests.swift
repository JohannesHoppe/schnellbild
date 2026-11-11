import XCTest
@testable import Matroska

/// The media extension's Matroska parser: what it reads from real files,
/// how little it reads, and that broken or hostile files end in an error,
/// never a crash or a read out of bounds.
final class MatroskaTests: XCTestCase {
    /// Bytes from memory, counting what is read.
    final class MemoryBytes: ByteReading, @unchecked Sendable {
        let data: Data
        private(set) var reads = 0, bytesRead = 0
        var length: Int64 { Int64(data.count) }
        init(_ data: Data) { self.data = data }
        func read(at offset: Int64, count: Int) throws -> Data {
            reads += 1
            guard offset >= 0, offset < length, count > 0 else { return Data() }
            let end = min(data.count, Int(offset) + count)
            bytesRead += end - Int(offset)
            return data.subdata(in: Int(offset)..<end)
        }
    }

    private func clip(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Videos"))
        return try Data(contentsOf: url)
    }

    private func allFrames(_ index: MatroskaIndex, track: UInt64) throws -> [MatroskaIndex.Frame] {
        try index.clusters.indices.flatMap { try index.frames(inCluster: $0, track: track) }
    }

    func testAnH264MKV() throws {
        let bytes = MemoryBytes(try clip("clip.mkv"))
        let index = try MatroskaIndex(bytes)
        XCTAssertEqual(index.timestampScale, 1_000_000)
        XCTAssertEqual(index.duration, 2000, accuracy: 1)
        let track = try XCTUnwrap(index.tracks.first)
        XCTAssertEqual(track.codecID, "V_MPEG4/ISO/AVC")
        XCTAssertEqual([track.width, track.height], [128, 96])
        XCTAssertFalse(track.codecPrivate.isEmpty, "the avcC setup")
        XCTAssertLessThan(bytes.bytesRead, 2048, "only the heads are read for the index")
        let frames = try allFrames(index, track: track.number)
        XCTAssertEqual(frames.count, 50)
        XCTAssertEqual(frames.filter(\.keyframe).count, 5)
        XCTAssertTrue(frames.first?.keyframe ?? false)
        XCTAssertNotEqual(frames.map(\.time), frames.map(\.time).sorted(), "B-frames: decode order isn't presentation order")
        for frame in frames {
            XCTAssertGreaterThan(frame.length, 0)
            XCTAssertLessThanOrEqual(frame.offset + Int64(frame.length), bytes.length)
        }
        XCTAssertEqual(index.cluster(at: 0), 0)
        XCTAssertEqual(index.cluster(at: 1999), index.clusters.count - 1)
    }

    func testWebMIsReadButIsVP9() throws {
        let index = try MatroskaIndex(MemoryBytes(try clip("clip.webm")))
        XCTAssertEqual(index.tracks.first?.codecID, "V_VP9")
        XCTAssertEqual(try allFrames(index, track: 1).count, 50)
    }

    func testOtherFilesAreRefused() throws {
        for name in ["clip.mp4", "clip.avi"] {
            XCTAssertThrowsError(try MatroskaIndex(MemoryBytes(try clip(name))), name)
        }
        XCTAssertThrowsError(try MatroskaIndex(MemoryBytes(Data())))
    }

    /// Cut anywhere: an error or fewer frames, never a crash.
    func testTruncatedFiles() throws {
        let data = try clip("clip.mkv")
        for cut in stride(from: 0, to: data.count, by: 97) {
            if let index = try? MatroskaIndex(MemoryBytes(data.prefix(cut))) {
                for c in index.clusters.indices { _ = try? index.frames(inCluster: c, track: 1) }
            }
        }
    }

    /// Hostile files: random bytes changed (sizes, ids, flags); every
    /// frame found must still lie inside the file.
    func testScrambledFiles() throws {
        let data = try clip("clip.mkv")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var bad = data
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                bad[Int.random(in: 0..<bad.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            let bytes = MemoryBytes(bad)
            guard let index = try? MatroskaIndex(bytes) else { continue }
            for c in index.clusters.indices {
                for track in index.tracks {
                    for frame in (try? index.frames(inCluster: c, track: track.number)) ?? [] {
                        XCTAssertGreaterThanOrEqual(frame.offset, 0)
                        XCTAssertLessThanOrEqual(frame.offset + Int64(frame.length), bytes.length)
                    }
                }
            }
        }
    }
}
