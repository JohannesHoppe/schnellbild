import Foundation

// MARK: - Bytes

/// Random access to a file's bytes, or for tests to bytes in memory.
protocol ByteSource {
    var size: UInt64 { get }
    /// Exactly `count` bytes from `offset`, nil when they aren't all there.
    func read(at offset: UInt64, count: Int) -> [UInt8]?
}

struct MemoryBytes: ByteSource {
    let bytes: [UInt8]
    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var size: UInt64 { UInt64(bytes.count) }
    func read(at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
        let start = Int(offset)
        return Array(bytes[start..<start + count])
    }
}

/// A file read in parts (a movie's index sits anywhere in it, often at the end).
final class FileBytes: ByteSource {
    private let handle: FileHandle
    let size: UInt64

    init?(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return nil }
        self.handle = handle
        size = end
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
              data.count == count else { return nil }
        return [UInt8](data)
    }
}

/// Big-endian numbers out of a byte array, every read checked against its end.
extension Array where Element == UInt8 {
    func u8(_ i: Int) -> UInt8? { i >= 0 && i < count ? self[i] : nil }
    func u16(_ i: Int) -> UInt16? {
        guard i >= 0, i <= count - 2 else { return nil }
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }
    func u32(_ i: Int) -> UInt32? {
        guard i >= 0, i <= count - 4 else { return nil }
        return (i..<i + 4).reduce(0) { $0 << 8 | UInt32(self[$1]) }
    }
    func u64(_ i: Int) -> UInt64? {
        guard i >= 0, i <= count - 8 else { return nil }
        return (i..<i + 8).reduce(0) { $0 << 8 | UInt64(self[$1]) }
    }
    /// Four bytes as a box or key name ("moov", "©xyz" as "\u{A9}xyz").
    func fourCC(_ i: Int) -> String? {
        guard i >= 0, i <= count - 4 else { return nil }
        return String(self[i..<i + 4].map { Character(Unicode.Scalar($0)) })
    }
}

// MARK: - MP4 / QuickTime boxes

/// What Schnellbild reads from an MP4 or QuickTime file's boxes itself
/// (ISO/IEC 14496-12, Apple's QuickTime File Format), next to what
/// AVFoundation reads: the movie header's creation time, the user data's
/// ISO 6709 location (`©xyz`, as Android writes it), XMP (`moov/udta/XMP_`
/// and the top-level `uuid` box, XMP Specification Part 3) and GoPro's GPMF
/// telemetry track (`gpmd`). Every size and offset is checked against its
/// box and the file; a malformed box ends the reading of its level.
enum MP4Boxes {
    struct Box: Equatable {
        let type: String
        /// The payload's range in the bytes it was found in.
        let payload: Range<Int>
    }

    /// The top-level `uuid` box's id for XMP (XMP Specification Part 3, 1.2.6).
    static let xmpUUID: [UInt8] = [0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC]
    /// A movie index larger than this isn't read (GoPro's are a few MB).
    static let largestIndex = 64 << 20
    static let largestXMP = 16 << 20
    static let largestBoxCount = 100_000
    static let deepest = 12
    /// Telemetry samples (GPMF payloads) larger than this are skipped.
    static let largestSample = 4 << 20
    static let largestSampleCount = 1_000_000

    struct Movie: Equatable {
        /// The movie header's creation time (UTC by ISO/IEC 14496-12).
        var created: Date?
        /// `moov/udta/©xyz`.
        var location: MediaLocation?
        /// `moov/udta/XMP_` or the top-level XMP `uuid` box.
        var xmp: [UInt8]?
        /// Where each telemetry sample of a `gpmd` track lies.
        var telemetry: [Range<UInt64>] = []
        /// When each telemetry sample starts, in seconds into the movie
        /// (empty when the track's timing doesn't add up).
        var telemetryStarts: [Double] = []
    }

    /// The children of a box (or of the file's bytes) between `range`'s bounds.
    static func boxes(in bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var found: [Box] = []
        var at = range.lowerBound
        let end = min(range.upperBound, bytes.count)
        while at <= end - 8, found.count < largestBoxCount {
            guard let size32 = bytes.u32(at), let type = bytes.fourCC(at + 4) else { break }
            var header = 8
            var size: Int
            switch size32 {
            case 0: size = end - at
            case 1:
                guard let size64 = bytes.u64(at + 8), size64 <= UInt64(Int.max) else { return found }
                header = 16
                size = Int(size64)
            default: size = Int(size32)
            }
            guard size >= header, size <= end - at else { break }
            found.append(Box(type: type, payload: at + header..<at + size))
            at += size
        }
        return found
    }

    static func child(_ type: String, of box: Box, in bytes: [UInt8]) -> Box? {
        boxes(in: bytes, box.payload).first { $0.type == type }
    }

    /// The boxes along a path below `box` ("mdia", "minf", "stbl").
    static func descend(_ path: [String], from box: Box, in bytes: [UInt8]) -> Box? {
        var current = box
        for type in path {
            guard let next = child(type, of: current, in: bytes) else { return nil }
            current = next
        }
        return current
    }

    /// Reads a movie's facts; nil when the file isn't made of boxes.
    static func read(_ source: ByteSource) -> Movie? {
        var at: UInt64 = 0
        var movieIndex: Range<UInt64>?
        var xmpBox: Range<UInt64>?
        var count = 0
        var sawFileType = false
        while at < source.size, count < largestBoxCount {
            count += 1
            guard let head = source.read(at: at, count: min(32, Int(source.size - at))), head.count >= 8,
                  let size32 = head.u32(0), let type = head.fourCC(4) else { break }
            var header: UInt64 = 8
            var size: UInt64
            switch size32 {
            case 0: size = source.size - at
            case 1:
                guard let size64 = head.u64(8) else { return nil }
                header = 16
                size = size64
            default: size = UInt64(size32)
            }
            guard size >= header, size <= source.size - at else { break }
            if count == 1 { sawFileType = ["ftyp", "moov", "mdat", "wide", "free", "skip", "pnot"].contains(type) }
            if type == "moov" { movieIndex = at + header..<at + size }
            if type == "uuid", size - header >= 16, head.count >= Int(header) + 16,
               Array(head[Int(header)..<Int(header) + 16]) == xmpUUID {
                xmpBox = at + header + 16..<at + size
            }
            at += size
        }
        guard sawFileType else { return nil }
        var movie = Movie()
        if let xmpBox, xmpBox.count <= largestXMP, let bytes = source.read(at: xmpBox.lowerBound, count: Int(xmpBox.count)) {
            movie.xmp = bytes
        }
        guard let movieIndex, movieIndex.count <= largestIndex,
              let bytes = source.read(at: movieIndex.lowerBound, count: Int(movieIndex.count)) else { return movie }
        readIndex(bytes, into: &movie, fileSize: source.size)
        return movie
    }

    /// The `moov` box's payload.
    static func readIndex(_ bytes: [UInt8], into movie: inout Movie, fileSize: UInt64) {
        for box in boxes(in: bytes, 0..<bytes.count) {
            switch box.type {
            case "mvhd":
                movie.created = creationTime(bytes, box)
            case "udta":
                for item in boxes(in: bytes, box.payload) {
                    if item.type == "\u{A9}xyz", movie.location == nil { movie.location = userDataLocation(bytes, item) }
                    if item.type == "XMP_", movie.xmp == nil, item.payload.count <= largestXMP { movie.xmp = Array(bytes[item.payload]) }
                }
            case "trak":
                if movie.telemetry.isEmpty, let samples = telemetrySamples(bytes, track: box, fileSize: fileSize) {
                    movie.telemetry = samples
                    let starts = sampleStarts(bytes, track: box)
                    movie.telemetryStarts = starts.count >= samples.count ? Array(starts.prefix(samples.count)) : []
                }
            default: break
            }
        }
    }

    /// Seconds since 1904-01-01 00:00 UTC (version 0: 32 bits, 1: 64 bits);
    /// zero is "not set".
    static func creationTime(_ bytes: [UInt8], _ box: Box) -> Date? {
        let at = box.payload.lowerBound
        guard let version = bytes.u8(at) else { return nil }
        let seconds: UInt64?
        if version == 1 {
            seconds = box.payload.count >= 12 ? bytes.u64(at + 4) : nil
        } else {
            seconds = box.payload.count >= 8 ? bytes.u32(at + 4).map(UInt64.init) : nil
        }
        guard let seconds, seconds > 0, seconds < 10_000_000_000 else { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds) - 2_082_844_800)
        // Clocks never set write their first seconds (1904, 1970)
        return date.timeIntervalSince1970 > 315_532_800 ? date : nil   // after 1980
    }

    /// `©xyz`: a 16-bit text length, a 16-bit language code, then the ISO
    /// 6709 text ("+48.8584+002.2945/").
    static func userDataLocation(_ bytes: [UInt8], _ box: Box) -> MediaLocation? {
        let at = box.payload.lowerBound
        guard let length = bytes.u16(at), box.payload.count >= 4 else { return nil }
        let end = min(box.payload.upperBound, at + 4 + Int(length))
        guard end > at + 4 else { return nil }
        let text = String(decoding: bytes[(at + 4)..<end], as: UTF8.self)
        guard let found = GeoPoint.iso6709(text), !(found.point.latitude == 0 && found.point.longitude == 0) else { return nil }
        return MediaLocation(point: found.point, altitude: found.altitude)
    }

    /// Each sample's start in seconds, from the media header's time scale and
    /// the time-to-sample table (`mdhd`, `stts`).
    static func sampleStarts(_ bytes: [UInt8], track: Box) -> [Double] {
        guard let media = child("mdia", of: track, in: bytes), let header = child("mdhd", of: media, in: bytes),
              let version = bytes.u8(header.payload.lowerBound),
              let scale = bytes.u32(header.payload.lowerBound + (version == 1 ? 20 : 12)), scale > 0,
              header.payload.count >= (version == 1 ? 24 : 16),
              let table = descend(["minf", "stbl", "stts"], from: media, in: bytes), table.payload.count >= 8,
              let count = bytes.u32(table.payload.lowerBound + 4), Int(count) <= (table.payload.count - 8) / 8 else { return [] }
        var starts: [Double] = []
        var time: UInt64 = 0
        for i in 0..<Int(count) {
            guard let samples = bytes.u32(table.payload.lowerBound + 8 + 8 * i),
                  let delta = bytes.u32(table.payload.lowerBound + 12 + 8 * i) else { return [] }
            for _ in 0..<samples {
                guard starts.count < largestSampleCount else { return starts }
                starts.append(Double(time) / Double(scale))
                time += UInt64(delta)
            }
        }
        return starts
    }

    /// The file ranges of a GPMF track's samples (`hdlr` "meta", sample
    /// description "gpmd"), from its sample table (`stsz`, `stco` / `co64`,
    /// `stsc`); nil for any other track or a table that doesn't add up.
    static func telemetrySamples(_ bytes: [UInt8], track: Box, fileSize: UInt64) -> [Range<UInt64>]? {
        guard let media = child("mdia", of: track, in: bytes),
              let handler = child("hdlr", of: media, in: bytes),
              bytes.fourCC(handler.payload.lowerBound + 8) == "meta",
              let table = descend(["minf", "stbl"], from: media, in: bytes),
              let description = child("stsd", of: table, in: bytes),
              description.payload.count >= 16,
              bytes.fourCC(description.payload.lowerBound + 12) == "gpmd" else { return nil }
        let children = boxes(in: bytes, table.payload)
        // Sizes
        guard let stsz = children.first(where: { $0.type == "stsz" }), stsz.payload.count >= 12,
              let fixedSize = bytes.u32(stsz.payload.lowerBound + 4),
              let sampleCount32 = bytes.u32(stsz.payload.lowerBound + 8) else { return nil }
        let sampleCount = Int(sampleCount32)
        guard sampleCount > 0, sampleCount <= largestSampleCount else { return nil }
        var sizes: [UInt64] = []
        if fixedSize > 0 {
            sizes = Array(repeating: UInt64(fixedSize), count: sampleCount)
        } else {
            guard (stsz.payload.count - 12) / 4 >= sampleCount else { return nil }
            sizes.reserveCapacity(sampleCount)
            for i in 0..<sampleCount {
                guard let size = bytes.u32(stsz.payload.lowerBound + 12 + 4 * i) else { return nil }
                sizes.append(UInt64(size))
            }
        }
        // Chunk offsets
        var chunks: [UInt64] = []
        if let stco = children.first(where: { $0.type == "stco" || $0.type == "co64" }), stco.payload.count >= 8,
           let count32 = bytes.u32(stco.payload.lowerBound + 4) {
            let wide = stco.type == "co64"
            let step = wide ? 8 : 4
            let count = Int(count32)
            guard count > 0, count <= largestSampleCount, (stco.payload.count - 8) / step >= count else { return nil }
            chunks.reserveCapacity(count)
            for i in 0..<count {
                let at = stco.payload.lowerBound + 8 + step * i
                guard let offset = wide ? bytes.u64(at) : bytes.u32(at).map(UInt64.init) else { return nil }
                chunks.append(offset)
            }
        } else {
            return nil
        }
        // Samples per chunk: runs of (first chunk, samples per chunk), first chunks rising from 1
        var runs: [(first: Int, perChunk: Int)] = []
        if let stsc = children.first(where: { $0.type == "stsc" }), stsc.payload.count >= 8,
           let count32 = bytes.u32(stsc.payload.lowerBound + 4) {
            let count = Int(count32)
            guard count > 0, count <= largestSampleCount, (stsc.payload.count - 8) / 12 >= count else { return nil }
            for i in 0..<count {
                let at = stsc.payload.lowerBound + 8 + 12 * i
                guard let first = bytes.u32(at), let perChunk = bytes.u32(at + 4), first >= 1,
                      perChunk <= UInt32(largestSampleCount) else { return nil }
                if let last = runs.last, Int(first) <= last.first { return nil }
                runs.append((Int(first), Int(perChunk)))
            }
        } else {
            runs = [(1, 1)]
        }
        var ranges: [Range<UInt64>] = []
        ranges.reserveCapacity(sampleCount)
        var run = 0
        for (index, chunkOffset) in chunks.enumerated() where ranges.count < sampleCount {
            let chunk = index + 1
            while run + 1 < runs.count, runs[run + 1].first <= chunk { run += 1 }
            guard runs[run].first <= chunk else { continue }
            var offset = chunkOffset
            for _ in 0..<runs[run].perChunk where ranges.count < sampleCount {
                let size = sizes[ranges.count]
                // A sample outside the file ends the table
                guard offset <= fileSize, size <= fileSize - offset else { return ranges.isEmpty ? nil : ranges }
                ranges.append(offset..<offset + size)
                offset += size
            }
        }
        return ranges.isEmpty ? nil : ranges
    }
}
