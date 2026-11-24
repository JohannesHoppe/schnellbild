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
/// and each cluster's frames when first asked, from the headers of its
/// elements (`Window`: small reads, however large the cluster). Frame data
/// itself is never read here; macOS reads it where `Frame.offset` says.
/// Every size and offset is checked against the file, so a broken or
/// hostile file ends with an error, never a read out of bounds; no header
/// element (Info, Tracks) may be larger than `MatroskaIndex.largestRead`.
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

        /// The time from one frame to the next in timestamp units, within
        /// 1 ... `largestTime`.
        func frameDuration(timestampScale: UInt64) -> Int64 {
            max(1, min(Int64(clamping: defaultDuration / max(1, timestampScale)), MatroskaIndex.largestTime))
        }
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

    /// The most read in one go: a header element (Info, Tracks).
    static let largestRead = 64 << 20
    /// Times and durations are held within this many timestamp units either
    /// way, so the sums and differences the reader works out never overflow.
    static let largestTime: Int64 = 1 << 52

    /// The duration in timestamp units, within 0 ... `largestTime` (0 when
    /// the file gives none, or not a number).
    var durationUnits: Int64 { duration.isFinite ? Int64(min(max(duration, 0), Double(Self.largestTime))) : 0 }
    /// The duration in seconds, always a finite number.
    var durationSeconds: Double { Double(durationUnits) * Double(timestampScale) / 1e9 }
    /// CoreMedia's time scale for the file's times, with `ticksPerUnit`:
    /// a timestamp unit of `timestampScale` ns is exactly `ticksPerUnit`
    /// ticks of 1 / `timescale` s (10⁹ ns and the scale, each divided by
    /// their greatest common divisor), so a scale that doesn't divide 10⁹
    /// (1 000 003 ns) loses nothing. 1 000 at the default of 1 ms, a tick a unit.
    var timescale: Int32 { Int32(1_000_000_000 / commonDivisor) }
    /// CoreMedia ticks per timestamp unit (at least 1).
    var ticksPerUnit: Int64 { Int64(clamping: max(1, timestampScale) / commonDivisor) }

    private var commonDivisor: UInt64 {
        var a: UInt64 = 1_000_000_000, b = max(1, timestampScale)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// A time in timestamp units as CoreMedia ticks, held within
    /// ±`largestTime` (a product beyond it saturates).
    func ticks(_ units: Int64) -> Int64 {
        let (product, overflow) = units.multipliedReportingOverflow(by: ticksPerUnit)
        if overflow { return units < 0 ? -Self.largestTime : Self.largestTime }
        return min(max(product, -Self.largestTime), Self.largestTime)
    }

    /// CoreMedia ticks as timestamp units (rounded down).
    func units(ofTicks ticks: Int64) -> Int64 {
        let per = ticksPerUnit
        let (quotient, remainder) = ticks.quotientAndRemainder(dividingBy: per)
        return remainder < 0 ? quotient - 1 : quotient
    }

    /// The time from one frame of a track to the next in CoreMedia ticks,
    /// within 1 ... `largestTime`: its DefaultDuration (nanoseconds) where
    /// given, else one timestamp unit.
    func frameTicks(of track: Track) -> Int64 {
        guard track.defaultDuration > 0 else { return max(1, ticks(1)) }
        return max(1, min(Int64(clamping: track.defaultDuration / commonDivisor), Self.largestTime))
    }

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
        while position < segmentEnd, let (element, after) = try headerAndAfter(at: &position) {
            let start = position
            switch element.id {
            case 0x1549A966: try parseInfo(try body(element, at: start))
            case 0x1654AE6B: try parseTracks(try body(element, at: start))
            case 0x1F43B675:
                // Its Timestamp from the bytes read with its header: one read a cluster
                let time = try clusterTime(at: start, read: after)
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
    /// cluster's element headers are read on first use (its frames' data
    /// passed over), so a cluster of any size gives its frames.
    func frames(inCluster index: Int, track: UInt64) throws -> [Frame] {
        if let known = lock.withLock({ framesByCluster[index] }) { return known[track] ?? [] }
        let cluster = clusters[index]
        guard cluster.end >= cluster.offset else { throw ParseError.damaged }
        var window = Window(source: source, end: cluster.end)
        var frames: [UInt64: [Frame]] = [:]
        var position = cluster.offset
        while position < cluster.end, let (element, start, end) = try window.element(at: position) {
            position = end
            switch element.id {
            case 0xA3:
                if let frame = try window.block(from: start, to: end, clusterTime: cluster.time, keyframe: nil) {
                    frames[frame.track, default: []].append(frame.frame)
                }
            case 0xA0:
                // A BlockGroup: its Block is a keyframe unless it refers to another
                var block: (start: Int64, end: Int64)?
                var references = false
                var child = start
                while child < end, let (element, childStart, childEnd) = try window.element(at: child, within: end) {
                    if element.id == 0xA1 { block = (childStart, childEnd) }
                    if element.id == 0xFB { references = true }
                    child = childEnd
                }
                if let block, let frame = try window.block(from: block.start, to: block.end, clusterTime: cluster.time, keyframe: !references) {
                    frames[frame.track, default: []].append(frame.frame)
                }
            default: break
            }
        }
        lock.withLock {
            if framesByCluster.count >= Self.cachedClusters { framesByCluster.removeAll() }
            framesByCluster[index] = frames
        }
        return frames[track] ?? []
    }

    /// Reads a cluster's element headers through a small window of the file,
    /// read again only where a header lies outside it: a frame's data is
    /// passed over, not read.
    private struct Window {
        let source: ByteReading
        /// Where the cluster ends: nothing at or after it is read.
        let end: Int64
        static let size = 16 << 10
        private var start: Int64 = 0
        private var data = Data()

        init(source: ByteReading, end: Int64) {
            self.source = source
            self.end = end
        }

        /// Up to `count` bytes from `offset`, within the cluster.
        mutating func bytes(at offset: Int64, count: Int) throws -> Data {
            let wanted = min(Int64(count), end - offset)
            guard wanted > 0 else { return Data() }
            if offset < start || offset + wanted > start + Int64(data.count) {
                start = offset
                data = try source.read(at: offset, count: Int(min(Int64(Self.size), end - offset)))
            }
            let from = Int(offset - start)
            let to = min(data.count, from + Int(wanted))
            guard from <= to else { return Data() }
            return data.subdata(in: (data.startIndex + from)..<(data.startIndex + to))
        }

        /// The element whose header is at `offset`: its header, where its
        /// contents start and end; nil at garbage, an unknown size, or an
        /// element running past `limit` (the cluster's end by default).
        mutating func element(at offset: Int64, within limit: Int64? = nil) throws -> (DataReader.Element, Int64, Int64)? {
            var reader = DataReader(data: try bytes(at: offset, count: 12))
            guard let element = reader.element(checkingSize: false), let size = element.size else { return nil }
            let contents = offset + Int64(reader.position)
            guard size <= UInt64(min(limit ?? end, end) - contents) else { return nil }
            return (element, contents, contents + Int64(size))
        }

        /// A SimpleBlock or Block from its header: its track and frame.
        /// Laced blocks (several frames in one, audio in practice) are left out.
        mutating func block(from start: Int64, to end: Int64, clusterTime: Int64,
                            keyframe: Bool?) throws -> (track: UInt64, frame: Frame)? {
            let head = try bytes(at: start, count: 11)
            let reader = DataReader(data: head)
            guard let (track, numberLength) = reader.vint(at: 0), start + Int64(numberLength) + 3 <= end,
                  numberLength + 3 <= head.count else {
                throw ParseError.damaged
            }
            let at = head.startIndex + numberLength
            let relative = Int16(bitPattern: UInt16(head[at]) << 8 | UInt16(head[at + 1]))
            let flags = head[at + 2]
            guard flags & 0x06 == 0 else { return nil }
            let headerEnd = start + Int64(numberLength) + 3
            return (track, Frame(offset: headerEnd, length: Int(end - headerEnd), time: clusterTime.saturatingAdd(Int64(relative)),
                                 keyframe: keyframe ?? (flags & 0x80 != 0)))
        }
    }

    /// Whether the track has a frame in the first `clusterLimit` clusters
    /// (those that can be read): deciding whether to offer a track reads
    /// no more than these, however long the file.
    func hasFrames(track: UInt64, clusterLimit: Int = MatroskaIndex.clustersLookedAt) -> Bool {
        (0..<min(clusters.count, max(0, clusterLimit))).contains { !((try? frames(inCluster: $0, track: track)) ?? []).isEmpty }
    }

    /// How many clusters' frame lists are kept at most.
    static let cachedClusters = 64
    /// How many clusters `hasFrames` reads at most.
    static let clustersLookedAt = 16
    /// How many clusters' frame lists are kept now.
    var cachedClusterCount: Int { lock.withLock { framesByCluster.count } }

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
        try headerAndAfter(at: &position)?.header
    }

    /// The same, with the bytes read after the header (a cluster's
    /// Timestamp, its first child, is among them).
    private func headerAndAfter(at position: inout Int64) throws -> (header: Header, after: Data)? {
        guard position < source.length else { return nil }
        let bytes = try source.read(at: position, count: 44)
        var reader = DataReader(data: bytes)
        guard let element = reader.element(checkingSize: false) else { return nil }
        position += Int64(reader.position)
        return (Header(id: element.id, size: element.size), bytes.subdata(in: (bytes.startIndex + reader.position)..<bytes.endIndex))
    }

    private func body(_ header: Header, at start: Int64) throws -> Data {
        guard let size = header.size, size <= UInt64(Self.largestRead) else { throw ParseError.tooLarge }
        let data = try source.read(at: start, count: Int(size))
        guard data.count == Int(size) else { throw ParseError.damaged }
        return data
    }

    /// A cluster's Timestamp, its first child in every muxer seen: from
    /// `read` (the bytes at `start` read already), else read from the file.
    private func clusterTime(at start: Int64, read: Data) throws -> Int64 {
        if let time = Self.timestamp(in: read) { return time }
        return Self.timestamp(in: try source.read(at: start, count: 32)) ?? clusters.last?.time ?? 0
    }

    private static func timestamp(in data: Data) -> Int64? {
        var reader = DataReader(data: data)
        while let element = reader.element(checkingSize: false) {
            if element.id == 0xE7, let size = element.size, size <= 8, reader.position + Int(size) <= reader.data.count,
               let value = try? reader.uint(element) {
                return min(Int64(clamping: value), Self.largestTime)
            }
            guard let size = element.size, size <= UInt64(reader.data.count - reader.position) else { break }
            reader.position += Int(size)
        }
        return nil
    }

    /// For a cluster of unknown size: where the next one starts.
    private func nextCluster(after start: Int64, before end: Int64) throws -> Int64 {
        var offset = start
        // Small first (a cluster written live is short), larger as it goes on
        var step = 64 << 10
        while offset < end {
            let chunk = try source.read(at: offset, count: step)
            step = min(step * 4, 1 << 20)
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
}

extension Int64 {
    /// The sum, held at Int64's bounds instead of overflowing.
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }

    /// The difference, held at Int64's bounds instead of overflowing.
    func saturatingSubtract(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other < 0 ? .max : .min) : difference
    }
}
