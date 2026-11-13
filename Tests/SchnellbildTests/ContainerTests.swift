import XCTest
@testable import VideoContainers

/// The media extension's container parsers (Matroska, MPEG transport
/// streams): what they read from real files, how little they read, and that
/// broken or hostile files end in an error, never a crash or a read out of
/// bounds.
final class ContainerTests: XCTestCase {
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

    // MARK: Transport streams (AVCHD)

    func testAnAVCHDClip() throws {
        for name in ["clip.m2ts", "clip.mts"] {
            let bytes = MemoryBytes(try clip(name))
            let index = try TransportIndex(bytes)
            XCTAssertEqual(index.packetSize, 192, "AVCHD: a time code before each packet")
            XCTAssertEqual(index.codec, .h264)
            XCTAssertEqual(Double(index.duration) / 90_000, 2, accuracy: 0.05)
            XCTAssertEqual(index.frameDuration, 3600, "25 frames a second")
            XCTAssertLessThanOrEqual(bytes.reads, 2, "the head (and the tail) for the index")
            let frames = try (0..<index.chunkCount).flatMap { try index.frames(inChunk: $0) }
            XCTAssertEqual(frames.count, 50)
            XCTAssertEqual(frames.filter(\.keyframe).count, 5)
            XCTAssertNotEqual(frames.map(\.time), frames.map(\.time).sorted(), "B-frames: decode order isn't presentation order")
            XCTAssertTrue(frames.allSatisfy { $0.decodeTime <= $0.time })
            let key = try XCTUnwrap(frames.first)
            let data = try index.annexB(of: key)
            let sets = try XCTUnwrap(TransportIndex.parameterSets(data, codec: .h264))
            XCTAssertEqual(sets.map { $0[0] & 0x1F }, [7, 8])
            // Length-prefixed: every NAL unit after its length, no delimiter
            let prefixed = [UInt8](TransportIndex.lengthPrefixed(data, codec: .h264))
            var at = 0, types: [UInt8] = []
            while at + 4 <= prefixed.count {
                let size = prefixed[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
                types.append(prefixed[at + 4] & 0x1F)
                at += 4 + size
            }
            XCTAssertEqual(at, prefixed.count)
            XCTAssertFalse(types.contains(9))
            XCTAssertTrue(types.contains(5), "the IDR picture")
            XCTAssertEqual(index.chunk(at: 90_000), 0)
        }
    }

    func testTransportStreamsWithoutH264OrHEVCAreRefused() throws {
        // clip.ts carries MPEG-2 video (macOS reads that itself)
        XCTAssertThrowsError(try TransportIndex(MemoryBytes(try clip("clip.ts"))))
        for name in ["clip.mkv", "clip.mp4", "clip.mpg"] {
            XCTAssertThrowsError(try TransportIndex(MemoryBytes(try clip(name))), name)
        }
        XCTAssertThrowsError(try TransportIndex(MemoryBytes(Data())))
    }

    /// Cut anywhere or with bytes changed: an error or fewer frames, every
    /// frame inside the file, never a crash.
    func testDamagedTransportStreams() throws {
        let data = try clip("clip.m2ts")
        func exercise(_ bytes: MemoryBytes) {
            guard let index = try? TransportIndex(bytes) else { return }
            for chunk in 0..<index.chunkCount {
                for frame in (try? index.frames(inChunk: chunk)) ?? [] {
                    XCTAssertGreaterThanOrEqual(frame.offset, 0)
                    XCTAssertLessThanOrEqual(frame.offset + Int64(frame.length), bytes.length)
                    if let annexB = try? index.annexB(of: frame) {
                        _ = TransportIndex.lengthPrefixed(annexB, codec: index.codec)
                        _ = TransportIndex.parameterSets(annexB, codec: index.codec)
                    }
                }
            }
            _ = index.chunk(at: 90_000)
        }
        for cut in stride(from: 0, to: data.count, by: 191) { exercise(MemoryBytes(data.prefix(cut))) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var bad = data
            for _ in 0..<Int.random(in: 1...12, using: &generator) {
                bad[Int.random(in: 0..<bad.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            exercise(MemoryBytes(bad))
        }
    }

    /// A track whose frames are compressed in the file (here header
    /// stripping) is marked: the decoder couldn't take its frames as they lie.
    func testAnEncodedTrackIsMarked() throws {
        func element(_ id: [UInt8], _ body: [UInt8]) -> [UInt8] {
            precondition(body.count < 0x7F)
            return id + [0x80 | UInt8(body.count)] + body
        }
        let compression = element([0x50, 0x34], element([0x42, 0x54], [3]) + element([0x42, 0x55], [0, 0, 0, 1]))
        let encodings = element([0x6D, 0x80], element([0x62, 0x40], compression))
        let video = element([0xE0], element([0xB0], [64]) + element([0xBA], [48]))
        let entry = element([0xAE], element([0xD7], [1]) + element([0x83], [1]) + element([0x86], Array("V_MPEG4/ISO/AVC".utf8))
                            + element([0x63, 0xA2], [1, 2, 3]) + video + encodings)
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], entry)
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], [0]) + element([0xA3], [0x81, 0, 0, 0x80, 1, 2]))
        let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
        let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + tracks + cluster
        let index = try MatroskaIndex(MemoryBytes(Data(header + segment)))
        XCTAssertEqual(index.tracks.first?.encoded, true)
        let plain = try MatroskaIndex(MemoryBytes(try clip("clip.mkv")))
        XCTAssertEqual(plain.tracks.first?.encoded, false)
    }

    // MARK: Times out of range

    private func element(_ id: [UInt8], _ body: [UInt8]) -> [UInt8] {
        precondition(body.count < 0x7F)
        return id + [0x80 | UInt8(body.count)] + body
    }

    /// A Matroska file with one H.264 track and one cluster of one frame,
    /// with the given Info children, frame duration, cluster time and the
    /// frame's time relative to it.
    private func matroska(info: [UInt8], defaultDuration: [UInt8], clusterTime: [UInt8], relative: Int16) -> Data {
        let video = element([0xE0], element([0xB0], [64]) + element([0xBA], [48]))
        let entry = element([0xAE], element([0xD7], [1]) + element([0x83], [1]) + element([0x86], Array("V_MPEG4/ISO/AVC".utf8))
                            + element([0x63, 0xA2], [1, 2, 3]) + element([0x23, 0xE3, 0x83], defaultDuration) + video)
        let r = UInt16(bitPattern: relative)
        let block = element([0xA3], [0x81, UInt8(r >> 8), UInt8(r & 0xFF), 0x80, 1, 2])
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], clusterTime) + block)
        let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
        let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            + element([0x15, 0x49, 0xA9, 0x66], info) + element([0x16, 0x54, 0xAE, 0x6B], entry) + cluster
        return Data(header + segment)
    }

    private func float(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.bigEndian, Array.init)
    }

    /// Durations that aren't numbers or don't fit, the largest time scale,
    /// frame duration and cluster time: every time the reader works with
    /// stays in range (the format reader turns them into Int64 and adds
    /// them up).
    func testTimesOutOfRangeAreHeldInRange() throws {
        let largest = MatroskaIndex.largestTime
        let all: [UInt8] = Array(repeating: 0xFF, count: 8)
        for duration in [Double.nan, .infinity, -.infinity, 1e300, -1e300, Double(Int64.max)] {
            let data = matroska(info: element([0x2A, 0xD7, 0xB1], all) + element([0x44, 0x89], float(duration)),
                                defaultDuration: all, clusterTime: all, relative: .max)
            let index = try MatroskaIndex(MemoryBytes(data))
            XCTAssertEqual(index.timestampScale, UInt64.max)
            XCTAssertTrue((0...largest).contains(index.durationUnits), "\(duration)")
            XCTAssertTrue(index.durationSeconds.isFinite, "\(duration)")
            XCTAssertGreaterThanOrEqual(index.timescale, 1)
            let track = try XCTUnwrap(index.tracks.first)
            XCTAssertEqual(track.frameDuration(timestampScale: index.timestampScale), 1)
            XCTAssertEqual(index.clusters.first?.time, largest)
            let frame = try XCTUnwrap(index.frames(inCluster: 0, track: 1).first)
            XCTAssertEqual(frame.time, largest + Int64(Int16.max))
            XCTAssertEqual(index.cluster(at: .max), 0)
        }
        // Nanoseconds, a frame duration of 2^64 - 1 ns: held at the largest time
        let data = matroska(info: element([0x2A, 0xD7, 0xB1], [1]) + element([0x44, 0x89], float(2e9)),
                            defaultDuration: all, clusterTime: [0], relative: .min)
        let index = try MatroskaIndex(MemoryBytes(data))
        XCTAssertEqual(index.durationUnits, 2_000_000_000)
        XCTAssertEqual(index.durationSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(index.timescale, 1_000_000_000)
        XCTAssertEqual(index.tracks.first?.frameDuration(timestampScale: index.timestampScale), largest)
        XCTAssertEqual(try index.frames(inCluster: 0, track: 1).first?.time, Int64(Int16.min))
    }

    func testSaturatingArithmetic() {
        XCTAssertEqual(Int64.max.saturatingAdd(1), .max)
        XCTAssertEqual(Int64.min.saturatingAdd(-1), .min)
        XCTAssertEqual(Int64(5).saturatingAdd(-7), -2)
        XCTAssertEqual(Int64.max.saturatingSubtract(-1), .max)
        XCTAssertEqual(Int64.min.saturatingSubtract(1), .min)
        XCTAssertEqual(Int64(0).saturatingSubtract(.min), .max)
        XCTAssertEqual(Int64(5).saturatingSubtract(7), -2)
    }
}

