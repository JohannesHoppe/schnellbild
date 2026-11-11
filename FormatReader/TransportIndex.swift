import Foundation

/// What a format reader needs to know about an MPEG transport stream
/// (AVCHD camcorder clips, `.mts` / `.m2ts`, with 192-byte packets; plain
/// 188-byte streams too), read in parts: its video stream (H.264 or HEVC,
/// from the program tables), the time of its first and last frame, and, a
/// chunk of the file at a time, each frame: the packets it is spread over
/// and its times. A frame's data lies in many packets between those of
/// other streams, so `annexB(of:)` gathers it. Every offset and size is
/// checked against the data read, so a broken or hostile file ends with an
/// error or fewer frames, never a read out of bounds; no frame may span more
/// than `largestFrame` bytes.
final class TransportIndex: @unchecked Sendable {
    enum Codec: Sendable { case h264, hevc }
    struct Frame: Equatable {
        let offset: Int64       // the packet its PES starts in
        let length: Int         // up to the packet the next one starts in
        let time: Int64         // presentation time, 90 kHz, from the first frame's
        let decodeTime: Int64
        let keyframe: Bool
    }
    enum ParseError: Error, Equatable { case notTransportStream, noVideo, tooLarge }

    static let timescale: Int64 = 90_000
    /// The most one frame may span in the file (its packets and the others' between).
    static let largestFrame = 32 << 20

    let packetSize: Int        // 192 (AVCHD: a 4-byte time code before each packet) or 188
    let syncOffset: Int        // where the packet's 0x47 lies
    let videoPID: Int
    let codec: Codec
    let length: Int64
    /// The first frame's presentation time in the stream's own clock (33 bits, 90 kHz).
    private(set) var firstPTS: Int64 = 0
    /// From the first frame to the end of the last, 90 kHz.
    private(set) var duration: Int64 = 0
    /// The smallest step between the first frames' presentation times (90 kHz;
    /// 25 frames a second if they don't tell).
    private(set) var frameDuration: Int64 = 3600
    let chunkBytes: Int64
    var chunkCount: Int { Int((length + chunkBytes - 1) / chunkBytes) }

    private let source: ByteReading
    private let lock = NSLock()
    private var framesByChunk: [Int: [Frame]] = [:]
    private var chunkTimes: [Int: Int64] = [:]

    init(_ source: ByteReading) throws {
        self.source = source
        length = source.length
        // The tables repeat every tenth of a second or so: the first MB holds them and the first frames
        let head = [UInt8](try source.read(at: 0, count: Int(min(length, 1 << 20))))
        guard let (size, sync) = Self.packetLayout(head) else { throw ParseError.notTransportStream }
        packetSize = size
        syncOffset = sync
        chunkBytes = Int64(size) * 10_923   // about 2 MB, whole packets
        guard let (pid, codec) = Self.videoStream(in: head, size: size, sync: sync) else { throw ParseError.noVideo }
        videoPID = pid
        self.codec = codec
        // The first frames' smallest presentation time (frames come in decode order)
        let headTimes = pesStarts(in: head, base: 0).prefix(32).map(\.pts)
        guard let first = headTimes.min() else { throw ParseError.noVideo }
        firstPTS = first
        // The frame duration: the smallest step between those frames' times
        let times = Set(headTimes.map { relative($0) }).sorted()
        frameDuration = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.min() ?? 3600
        // The last frame's, from the end of the file
        let tailStart = max(0, (length - (1 << 20)) / Int64(size) * Int64(size))
        let tail = tailStart == 0 ? head : [UInt8](try source.read(at: tailStart, count: Int(length - tailStart)))
        let last = pesStarts(in: tail, base: tailStart).map { relative($0.pts) }.max() ?? 0
        duration = max(0, last) + frameDuration
    }

    // MARK: Frames

    /// The frames whose PES starts in the chunk, in decode order, read on first use.
    func frames(inChunk chunk: Int) throws -> [Frame] {
        if let known = lock.withLock({ framesByChunk[chunk] }) { return known }
        guard chunk >= 0, chunk < chunkCount else { return [] }
        let start = Int64(chunk) * chunkBytes, stop = min(length, start + chunkBytes)
        var frames: [Frame] = []
        var open: (offset: Int64, pts: Int64, dts: Int64, randomAccess: Bool, head: [UInt8])?
        func close(at end: Int64) {
            guard let o = open else { return }
            open = nil
            frames.append(Frame(offset: o.offset, length: Int(end - o.offset), time: relative(o.pts),
                                decodeTime: relative(o.dts), keyframe: o.randomAccess || Self.startsPicture(o.head, codec: codec)))
        }
        var position = start
        scan: while position < length {
            // The chunk, then beyond it in 1 MB steps until its last frame ends
            let end = position < stop ? stop : min(length, position + (1 << 20))
            let data = [UInt8](try source.read(at: position, count: Int(end - position)))
            var i = 0
            while i + packetSize <= data.count {
                let at = position + Int64(i)
                if let packet = Self.packet(data, at: i, sync: syncOffset), packet.pid == videoPID {
                    if packet.start {
                        close(at: at)
                        if at >= stop { break scan }
                        let payload = Array(data[packet.payload])
                        if let header = Self.pesHeader(payload), let pts = header.pts {
                            open = (at, pts, header.dts ?? pts, packet.randomAccess, Array(payload.dropFirst(header.length)))
                        }
                    } else if open != nil, open!.head.count < 4096 {
                        open!.head += data[packet.payload]
                    }
                }
                i += packetSize
            }
            guard i > 0 else { break }
            position += Int64(i)
            if position >= stop {
                guard let o = open else { break }
                if position - o.offset > Int64(Self.largestFrame) { open = nil; break }
            }
        }
        close(at: min(position, length))
        lock.withLock {
            if framesByChunk.count > 64 { framesByChunk.removeAll() }
            framesByChunk[chunk] = frames
        }
        return frames
    }

    /// The chunk to look in for the frame shown at `time`: the last whose
    /// first frame starts at or before it (a binary search, each step
    /// reading only until a frame starts).
    func chunk(at time: Int64) -> Int {
        var low = 0, high = chunkCount - 1, found = 0
        while low <= high {
            let middle = (low + high) / 2
            if let t = firstTime(inChunk: middle), t <= time { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return found
    }

    /// The first frame's time in a chunk, nil if none starts in it.
    private func firstTime(inChunk chunk: Int) -> Int64? {
        if let known = lock.withLock({ chunkTimes[chunk] }) { return known }
        let start = Int64(chunk) * chunkBytes, stop = min(length, start + chunkBytes)
        var position = start
        while position < stop {
            guard let data = try? [UInt8](source.read(at: position, count: Int(min(stop - position, 64 << 10)))),
                  data.count >= packetSize else { return nil }
            if let first = pesStarts(in: data, base: position).first {
                let time = relative(first.pts)
                lock.withLock { chunkTimes[chunk] = time }
                return time
            }
            position += Int64(data.count / packetSize * packetSize)
        }
        return nil
    }

    /// A frame's data as written (Annex B: NAL units after start codes).
    func annexB(of frame: Frame) throws -> [UInt8] {
        guard frame.length > 0, frame.length <= Self.largestFrame, frame.offset >= 0, frame.offset < length else { throw ParseError.tooLarge }
        let data = [UInt8](try source.read(at: frame.offset, count: frame.length))
        var result: [UInt8] = []
        var i = 0, first = true, limit = Int.max
        while i + packetSize <= data.count {
            if let packet = Self.packet(data, at: i, sync: syncOffset), packet.pid == videoPID {
                var payload = data[packet.payload]
                if first {
                    guard packet.start, let header = Self.pesHeader(Array(payload)), header.length <= payload.count else { return [] }
                    if header.packetLength > 0 { limit = max(0, header.packetLength + 6 - header.length) }
                    payload = payload.dropFirst(header.length)
                    first = false
                } else if packet.start { break }
                result += payload
                if result.count >= limit { result.removeSubrange(limit...); break }
            }
            i += packetSize
        }
        return result
    }

    /// A time of the stream's 33-bit clock, from the first frame's (it may wrap once).
    func relative(_ time: Int64) -> Int64 {
        var difference = (time - firstPTS) & ((1 << 33) - 1)
        if difference >= 1 << 32 { difference -= 1 << 33 }
        return difference
    }

    // MARK: Packets and tables

    struct Packet {
        let pid: Int
        let start: Bool          // a PES or table section starts in it
        let randomAccess: Bool
        let payload: Range<Int>
    }

    /// The packet at `i` in `data`, nil when it isn't one (no sync byte, a
    /// transport error, an adaptation field larger than the packet).
    static func packet(_ data: [UInt8], at i: Int, sync: Int) -> Packet? {
        let s = i + sync
        guard s >= 0, s + 188 <= data.count, data[s] == 0x47, data[s + 1] & 0x80 == 0 else { return nil }
        let pid = Int(data[s + 1] & 0x1F) << 8 | Int(data[s + 2])
        let control = (data[s + 3] >> 4) & 0x3
        var payloadStart = s + 4, randomAccess = false
        if control & 0x2 != 0 {
            let fieldLength = Int(data[s + 4])
            if fieldLength > 0 { randomAccess = data[s + 5] & 0x40 != 0 }
            payloadStart = s + 5 + fieldLength
        }
        guard payloadStart <= s + 188 else { return nil }
        let payload = control & 0x1 != 0 ? payloadStart..<(s + 188) : (s + 188)..<(s + 188)
        return Packet(pid: pid, start: data[s + 1] & 0x40 != 0, randomAccess: randomAccess, payload: payload)
    }

    /// 192-byte packets (sync byte after a 4-byte time code) or 188-byte
    /// ones: the sync byte where it belongs in the first packets.
    static func packetLayout(_ head: [UInt8]) -> (size: Int, sync: Int)? {
        for (size, sync) in [(192, 4), (188, 0)] {
            let count = min(8, head.count / size)
            guard count >= 2 else { continue }
            if (0..<count).allSatisfy({ head[$0 * size + sync] == 0x47 }) { return (size, sync) }
        }
        return nil
    }

    /// The video stream from the program tables (PAT, then the first program's PMT).
    static func videoStream(in head: [UInt8], size: Int, sync: Int) -> (pid: Int, codec: Codec)? {
        guard let pat = section(pid: 0, table: 0x00, in: head, size: size, sync: sync), pat.count >= 12 else { return nil }
        var pmtPID: Int?
        var i = 8
        while i + 4 <= pat.count - 4 {
            let program = Int(pat[i]) << 8 | Int(pat[i + 1])
            if program != 0 { pmtPID = Int(pat[i + 2] & 0x1F) << 8 | Int(pat[i + 3]); break }
            i += 4
        }
        guard let pmtPID, let pmt = section(pid: pmtPID, table: 0x02, in: head, size: size, sync: sync), pmt.count >= 16 else { return nil }
        i = 12 + (Int(pmt[10] & 0x0F) << 8 | Int(pmt[11]))
        while i + 5 <= pmt.count - 4 {
            let type = pmt[i], pid = Int(pmt[i + 1] & 0x1F) << 8 | Int(pmt[i + 2])
            switch type {
            case 0x1B: return (pid, .h264)
            case 0x24: return (pid, .hevc)
            default: break
            }
            i += 5 + (Int(pmt[i + 3] & 0x0F) << 8 | Int(pmt[i + 4]))
        }
        return nil
    }

    /// The first whole table section with this id on this PID (may span packets).
    static func section(pid: Int, table: UInt8, in data: [UInt8], size: Int, sync: Int) -> [UInt8]? {
        var buffer: [UInt8] = [], collecting = false
        var i = 0
        while i + size <= data.count {
            defer { i += size }
            guard let packet = packet(data, at: i, sync: sync), packet.pid == pid else { continue }
            let payload = data[packet.payload]
            if packet.start {
                guard let pointer = payload.first, 1 + Int(pointer) <= payload.count else { continue }
                buffer = Array(payload.dropFirst(1 + Int(pointer)))
                collecting = true
            } else if collecting {
                buffer += payload
            } else { continue }
            guard buffer.count >= 3 else { continue }
            guard buffer[0] == table else { collecting = false; continue }
            let sectionLength = Int(buffer[1] & 0x0F) << 8 | Int(buffer[2])
            if buffer.count >= 3 + sectionLength { return Array(buffer.prefix(3 + sectionLength)) }
        }
        return nil
    }

    /// A PES header: its times (when given) and its length.
    static func pesHeader(_ p: [UInt8]) -> (pts: Int64?, dts: Int64?, length: Int, packetLength: Int)? {
        guard p.count >= 9, p[0] == 0, p[1] == 0, p[2] == 1 else { return nil }
        func time(_ i: Int) -> Int64? {
            guard i + 5 <= p.count else { return nil }
            return Int64((p[i] >> 1) & 0x7) << 30 | Int64(p[i + 1]) << 22 | Int64(p[i + 2] >> 1) << 15
                | Int64(p[i + 3]) << 7 | Int64(p[i + 4] >> 1)
        }
        let flags = p[7]
        return (flags & 0x80 != 0 ? time(9) : nil, flags & 0xC0 == 0xC0 ? time(14) : nil,
                9 + Int(p[8]), Int(p[4]) << 8 | Int(p[5]))
    }

    /// The video PES starts in `data` (read from `base`) with their presentation times.
    private func pesStarts(in data: [UInt8], base: Int64) -> [(offset: Int64, pts: Int64)] {
        var starts: [(Int64, Int64)] = []
        var i = 0
        while i + packetSize <= data.count {
            if let packet = Self.packet(data, at: i, sync: syncOffset), packet.pid == videoPID, packet.start,
               let header = Self.pesHeader(Array(data[packet.payload])), let pts = header.pts {
                starts.append((base + Int64(i), pts))
            }
            i += packetSize
        }
        return starts
    }

    // MARK: NAL units

    /// The NAL units of Annex B data (start codes removed).
    static func nalUnits(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [Int] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var units: [ArraySlice<UInt8>] = []
        for (k, start) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1] - 3 : b.count
            while end > start, b[end - 1] == 0 { end -= 1 }
            if end > start { units.append(b[start..<end]) }
        }
        return units
    }

    static func nalType(_ unit: ArraySlice<UInt8>, codec: Codec) -> UInt8 {
        guard let first = unit.first else { return 0xFF }
        return codec == .h264 ? first & 0x1F : (first >> 1) & 0x3F
    }

    /// Whether the data opens a picture to start decoding at: an IDR (HEVC:
    /// any random access picture), or a sequence's parameter set before it
    /// (camcorders' open GOPs start with an I-picture that isn't IDR).
    static func startsPicture(_ data: [UInt8], codec: Codec) -> Bool {
        nalUnits(data).contains { unit in
            let type = nalType(unit, codec: codec)
            return codec == .h264 ? (type == 5 || type == 7) : (16...21).contains(type) || type == 33
        }
    }

    /// The parameter sets a format description needs (H.264: SPS, PPS;
    /// HEVC: VPS, SPS, PPS), the first of each kind; nil if one is missing.
    static func parameterSets(_ data: [UInt8], codec: Codec) -> [[UInt8]]? {
        let kinds: [UInt8] = codec == .h264 ? [7, 8] : [32, 33, 34]
        let units = nalUnits(data)
        let sets = kinds.compactMap { kind in units.first { nalType($0, codec: codec) == kind }.map(Array.init) }
        return sets.count == kinds.count ? sets : nil
    }

    /// Annex B data as macOS's decoders take it: each NAL unit after its
    /// length (4 bytes, big endian), access unit delimiters left out.
    static func lengthPrefixed(_ data: [UInt8], codec: Codec) -> Data {
        var out = Data()
        for unit in nalUnits(data) where nalType(unit, codec: codec) != (codec == .h264 ? 9 : 35) {
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
            out.append(contentsOf: unit)
        }
        return out
    }
}
