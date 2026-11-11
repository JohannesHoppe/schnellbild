import Foundation

/// Random access to a file's bytes (the media extension's byte source, or a
/// file or memory in tests).
protocol ByteReading: AnyObject, Sendable {
    var length: Int64 { get }
    /// Up to `count` bytes from `offset` (fewer at the end of the file).
    func read(at offset: Int64, count: Int) throws -> Data
}

/// What a format reader needs to know about a Matroska / WebM file, read in
/// parts: the time scale and duration, the video tracks with their codec
/// setup, the clusters (blocks of frames) with their start time and place,
/// and each cluster's frames when first asked. Frame data itself is never
/// read here; macOS reads it where `Frame.offset` says. Every size and
/// offset is checked against the file, so a broken or hostile file ends
/// with an error, never a read out of bounds; no element may be larger than
/// `MatroskaIndex.largestRead`.
final class MatroskaIndex: @unchecked Sendable {
    struct Track {
        var number: UInt64 = 0
        var type: UInt64 = 0          // 1 video, 2 audio
        var codecID = ""
        var codecPrivate = Data()
        var width = 0
        var height = 0
        var defaultDuration: UInt64 = 0   // nanoseconds per frame, 0 if not given
        /// Its frames are compressed or encrypted (ContentEncodings: header
        /// stripping, zlib …): not as the decoder takes them.
        var encoded = false
    }
    struct Cluster {
        let offset: Int64       // of its contents (after its header)
        let end: Int64
        let time: Int64         // in timestamp units
    }
    struct Frame {
        let offset: Int64
        let length: Int
        let time: Int64         // presentation time, in timestamp units
        let keyframe: Bool
    }

    enum ParseError: Error, Equatable { case notMatroska, damaged, tooLarge }

    /// Nanoseconds per timestamp unit (1 000 000 by default: milliseconds).
    private(set) var timestampScale: UInt64 = 1_000_000
    private(set) var duration: Double = 0   // in timestamp units
    private(set) var tracks: [Track] = []
    private(set) var clusters: [Cluster] = []

    /// The most read in one go: a header element, or one cluster's frame list.
    static let largestRead = 64 << 20

    private let source: ByteReading
    private let lock = NSLock()
    private var framesByCluster: [Int: [UInt64: [Frame]]] = [:]

    init(_ source: ByteReading) throws {
        self.source = source
        var position: Int64 = 0
        guard let ebml = try header(at: &position), ebml.id == 0x1A45DFA3, let ebmlSize = ebml.size else { throw ParseError.notMatroska }
        position += Int64(ebmlSize)
        guard let segment = try header(at: &position), segment.id == 0x18538067 else { throw ParseError.notMatroska }
        let segmentEnd = segment.size.map { min(position + Int64($0), source.length) } ?? source.length
        // The top level of the segment: Info and Tracks read whole, clusters only by their head
        while position < segmentEnd, let element = try header(at: &position) {
            let start = position
            switch element.id {
            case 0x1549A966: try parseInfo(try body(element, at: start))
            case 0x1654AE6B: try parseTracks(try body(element, at: start))
            case 0x1F43B675:
                let time = try clusterTime(at: start)
                guard let size = element.size else {
                    // Written live, size unknown: it runs to the next cluster
                    let next = try nextCluster(after: start, before: segmentEnd)
                    clusters.append(Cluster(offset: start, end: next, time: time))
                    position = next
                    continue
                }
                clusters.append(Cluster(offset: start, end: min(start + Int64(size), segmentEnd), time: time))
            default: break
            }
            guard let size = element.size else { break }
            position = start + Int64(size)
        }
        guard !tracks.isEmpty else { throw ParseError.damaged }
    }

    // MARK: Frames

    /// The frames of one track in a cluster, in file (decode) order; the
    /// cluster is read on first use.
    func frames(inCluster index: Int, track: UInt64) throws -> [Frame] {
        if let known = lock.withLock({ framesByCluster[index] }) { return known[track] ?? [] }
        let cluster = clusters[index]
        let length = cluster.end - cluster.offset
        guard length >= 0, length <= Int64(Self.largestRead) else { throw ParseError.tooLarge }
        let data = try source.read(at: cluster.offset, count: Int(length))
        var frames: [UInt64: [Frame]] = [:]
        var reader = DataReader(data: data)
        while let element = reader.element() {
            switch element.id {
            case 0xA3:
                if let frame = try reader.block(element, base: cluster.offset, clusterTime: cluster.time, keyframe: nil) {
                    frames[frame.track, default: []].append(frame.frame)
                }
            case 0xA0:
                // A BlockGroup: its Block is a keyframe unless it refers to another
                let end = try reader.end(of: element)
                var block: (DataReader.Element, Int)?
                var references = false
                while reader.position < end, let child = reader.element() {
                    if child.id == 0xA1 { block = (child, reader.position) }
                    if child.id == 0xFB { references = true }
                    try reader.skip(child)
                }
                if let (child, start) = block {
                    var sub = reader
                    sub.position = start
                    if let frame = try sub.block(child, base: cluster.offset, clusterTime: cluster.time, keyframe: !references) {
                        frames[frame.track, default: []].append(frame.frame)
                    }
                }
            default: try reader.skip(element)
            }
        }
        lock.withLock { framesByCluster[index] = frames }
        return frames[track] ?? []
    }

    /// The cluster that holds `time` (the last one starting at or before it).
    func cluster(at time: Int64) -> Int {
        var low = 0, high = clusters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if clusters[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: Reading the file

    private struct Header { let id: UInt32; let size: UInt64? }

    /// The element header at `position`, which then points at its contents.
    private func header(at position: inout Int64) throws -> Header? {
        guard position < source.length else { return nil }
        let bytes = try source.read(at: position, count: 12)
        var reader = DataReader(data: bytes)
        guard let element = reader.element(checkingSize: false) else { return nil }
        position += Int64(reader.position)
        return Header(id: element.id, size: element.size)
    }

    private func body(_ header: Header, at start: Int64) throws -> Data {
        guard let size = header.size, size <= UInt64(Self.largestRead) else { throw ParseError.tooLarge }
        let data = try source.read(at: start, count: Int(size))
        guard data.count == Int(size) else { throw ParseError.damaged }
        return data
    }

    /// A cluster's Timestamp, its first child in every muxer seen.
    private func clusterTime(at start: Int64) throws -> Int64 {
        var reader = DataReader(data: try source.read(at: start, count: 32))
        while let element = reader.element(checkingSize: false) {
            if element.id == 0xE7, let size = element.size, size <= 8, reader.position + Int(size) <= reader.data.count {
                return Int64(clamping: try reader.uint(element))
            }
            guard let size = element.size, reader.position + Int(size) <= reader.data.count else { break }
            reader.position += Int(size)
        }
        return clusters.last?.time ?? 0
    }

    /// For a cluster of unknown size: where the next one starts.
    private func nextCluster(after start: Int64, before end: Int64) throws -> Int64 {
        var offset = start
        while offset < end {
            let chunk = try source.read(at: offset, count: 1 << 20)
            guard chunk.count >= 4 else { return end }
            for i in 0..<(chunk.count - 3) where chunk[chunk.startIndex + i] == 0x1F
                && chunk[chunk.startIndex + i + 1] == 0x43 && chunk[chunk.startIndex + i + 2] == 0xB6 && chunk[chunk.startIndex + i + 3] == 0x75 {
                return offset + Int64(i)
            }
            offset += Int64(chunk.count - 3)
        }
        return end
    }

    private func parseInfo(_ data: Data) throws {
        var reader = DataReader(data: data)
        while let element = reader.element() {
            switch element.id {
            case 0x2AD7B1: timestampScale = max(1, try reader.uint(element))
            case 0x4489: duration = try reader.float(element)
            default: try reader.skip(element)
            }
        }
    }

    private func parseTracks(_ data: Data) throws {
        var reader = DataReader(data: data)
        while let entry = reader.element() {
            guard entry.id == 0xAE else { try reader.skip(entry); continue }
            var track = Track()
            let end = try reader.end(of: entry)
            while reader.position < end, let element = reader.element() {
                switch element.id {
                case 0xD7: track.number = try reader.uint(element)
                case 0x83: track.type = try reader.uint(element)
                case 0x86: track.codecID = try reader.string(element)
                case 0x63A2: track.codecPrivate = try reader.bytes(element)
                case 0x23E383: track.defaultDuration = try reader.uint(element)
                case 0x6D80: track.encoded = true; try reader.skip(element)
                case 0xE0:
                    let videoEnd = try reader.end(of: element)
                    while reader.position < videoEnd, let video = reader.element() {
                        switch video.id {
                        case 0xB0: track.width = Int(clamping: try reader.uint(video))
                        case 0xBA: track.height = Int(clamping: try reader.uint(video))
                        default: try reader.skip(video)
                        }
                    }
                default: try reader.skip(element)
                }
            }
            tracks.append(track)
        }
    }
}

/// EBML in memory: elements with variable-length ids and sizes.
struct DataReader {
    struct Element {
        let id: UInt32
        let size: UInt64?        // nil: unknown size
    }
    let data: Data
    var position = 0

    /// A variable-length integer with its marker bit removed, and its length.
    func vint(at offset: Int) -> (UInt64, Int)? {
        guard offset >= 0, offset < data.count else { return nil }
        let first = data[data.startIndex + offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard offset + length <= data.count else { return nil }
        var value = UInt64(first) & ((1 << (8 - length)) - 1)
        for i in 1..<length { value = value << 8 | UInt64(data[data.startIndex + offset + i]) }
        return (value, length)
    }

    /// The next element's header; nil at the end or on garbage. With
    /// `checkingSize`, an element larger than what is left ends the read too.
    mutating func element(checkingSize: Bool = true) -> Element? {
        guard position < data.count else { return nil }
        let first = data[data.startIndex + position]
        guard first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, position + idLength <= data.count else { return nil }
        var id: UInt32 = 0
        for i in 0..<idLength { id = id << 8 | UInt32(data[data.startIndex + position + i]) }
        guard let (size, sizeLength) = vint(at: position + idLength) else { return nil }
        let unknown = size == (UInt64(1) << (7 * sizeLength)) - 1
        let start = position + idLength + sizeLength
        if checkingSize, !unknown, size > UInt64(data.count - min(start, data.count)) { return nil }
        position = start
        return Element(id: id, size: unknown ? nil : size)
    }

    func end(of element: Element) throws -> Int {
        guard let size = element.size else { return data.count }
        guard size <= UInt64(data.count - position) else { throw MatroskaIndex.ParseError.damaged }
        return position + Int(size)
    }

    mutating func skip(_ element: Element) throws { position = try end(of: element) }

    mutating func bytes(_ element: Element) throws -> Data {
        let end = try end(of: element)
        defer { position = end }
        return data.subdata(in: (data.startIndex + position)..<(data.startIndex + end))
    }

    mutating func uint(_ element: Element) throws -> UInt64 {
        let raw = try bytes(element)
        guard raw.count <= 8 else { throw MatroskaIndex.ParseError.damaged }
        return raw.reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func float(_ element: Element) throws -> Double {
        let raw = try bytes(element)
        let bits = raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch raw.count {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8: return Double(bitPattern: bits)
        default: return 0
        }
    }

    mutating func string(_ element: Element) throws -> String {
        String(decoding: try bytes(element).prefix { $0 != 0 }, as: UTF8.self)
    }

    /// A SimpleBlock or Block: its track and frame, the frame's place in the
    /// file (`base` is where this data starts). Laced blocks (several frames
    /// in one, audio in practice) are left out.
    mutating func block(_ element: Element, base: Int64, clusterTime: Int64,
                        keyframe: Bool?) throws -> (track: UInt64, frame: MatroskaIndex.Frame)? {
        let start = position
        let end = try end(of: element)
        position = end
        guard let (track, numberLength) = vint(at: start), start + numberLength + 3 <= end else {
            throw MatroskaIndex.ParseError.damaged
        }
        let at = data.startIndex + start + numberLength
        let relative = Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
        let flags = data[at + 2]
        guard flags & 0x06 == 0 else { return nil }
        let headerEnd = start + numberLength + 3
        return (track, MatroskaIndex.Frame(offset: base + Int64(headerEnd), length: end - headerEnd,
                                           time: clusterTime + Int64(relative),
                                           keyframe: keyframe ?? (flags & 0x80 != 0)))
    }
}
