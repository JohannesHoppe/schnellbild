import Foundation

/// Reads what a format reader needs from a Matroska / WebM file: the time
/// scale, the duration, the video tracks with their codec setup, and where
/// each frame lies in the file. Only reads; every length and offset is
/// checked against the data, so a broken or hostile file ends the parse
/// with an error instead of reading out of bounds.
struct MKVFile {
    struct Track {
        var number: UInt64 = 0
        var type: UInt64 = 0          // 1 video, 2 audio
        var codecID = ""
        var codecPrivate = Data()
        var width = 0
        var height = 0
        var defaultDuration: UInt64 = 0   // nanoseconds per frame, 0 if not given
    }
    struct Sample {
        let offset: Int64       // in the file
        let length: Int
        let time: Int64         // presentation time, in units of `timescale`
        let keyframe: Bool
    }

    /// Nanoseconds per timestamp unit (Matroska's TimestampScale, 1 000 000 by default).
    var timestampScale: UInt64 = 1_000_000
    var duration: Double = 0    // in timestamp units
    var tracks: [Track] = []
    var samples: [UInt64: [Sample]] = [:]   // by track number, in file (decode) order

    enum ParseError: Error { case notMatroska, truncated }

    init(_ data: Data) throws {
        var reader = Reader(data: data)
        guard let header = reader.element(), header.id == 0x1A45DFA3 else { throw ParseError.notMatroska }
        reader.skip(header)
        guard let segment = reader.element(), segment.id == 0x18538067 else { throw ParseError.notMatroska }
        let segmentEnd = segment.size.map { min(reader.position + Int($0), data.count) } ?? data.count
        while reader.position < segmentEnd, let element = reader.element() {
            switch element.id {
            case 0x1549A966: try parseInfo(&reader, element)
            case 0x1654AE6B: try parseTracks(&reader, element)
            case 0x1F43B675: try parseCluster(&reader, element, segmentEnd: segmentEnd)
            default: reader.skip(element)
            }
        }
    }

    private mutating func parseInfo(_ reader: inout Reader, _ info: Reader.Element) throws {
        let end = try reader.end(of: info)
        while reader.position < end, let element = reader.element() {
            switch element.id {
            case 0x2AD7B1: timestampScale = try reader.uint(element)
            case 0x4489: duration = try reader.float(element)
            default: reader.skip(element)
            }
        }
    }

    private mutating func parseTracks(_ reader: inout Reader, _ tracksElement: Reader.Element) throws {
        let end = try reader.end(of: tracksElement)
        while reader.position < end, let entry = reader.element() {
            guard entry.id == 0xAE else { reader.skip(entry); continue }
            var track = Track()
            let entryEnd = try reader.end(of: entry)
            while reader.position < entryEnd, let element = reader.element() {
                switch element.id {
                case 0xD7: track.number = try reader.uint(element)
                case 0x83: track.type = try reader.uint(element)
                case 0x86: track.codecID = try reader.string(element)
                case 0x63A2: track.codecPrivate = try reader.bytes(element)
                case 0x23E383: track.defaultDuration = try reader.uint(element)
                case 0xE0:
                    let videoEnd = try reader.end(of: element)
                    while reader.position < videoEnd, let video = reader.element() {
                        switch video.id {
                        case 0xB0: track.width = Int(clamping: try reader.uint(video))
                        case 0xBA: track.height = Int(clamping: try reader.uint(video))
                        default: reader.skip(video)
                        }
                    }
                default: reader.skip(element)
                }
            }
            tracks.append(track)
        }
    }

    private mutating func parseCluster(_ reader: inout Reader, _ cluster: Reader.Element, segmentEnd: Int) throws {
        // A cluster of unknown size (written live) runs to the next cluster or the end
        let end = cluster.size == nil ? segmentEnd : try reader.end(of: cluster)
        var clusterTime: Int64 = 0
        while reader.position < end, let element = reader.element() {
            switch element.id {
            case 0xE7: clusterTime = Int64(clamping: try reader.uint(element))
            case 0xA3: try block(&reader, element, clusterTime: clusterTime, simple: true, keyframe: nil)
            case 0xA0:
                // A BlockGroup: a Block, keyframe unless it references another
                let groupEnd = try reader.end(of: element)
                var blockElement: (Reader.Element, Int)?
                var references = false
                while reader.position < groupEnd, let child = reader.element() {
                    if child.id == 0xA1 { blockElement = (child, reader.position) }
                    if child.id == 0xFB { references = true }
                    reader.skip(child)
                }
                if let (blockEl, start) = blockElement {
                    var sub = reader
                    sub.position = start
                    try block(&sub, blockEl, clusterTime: clusterTime, simple: false, keyframe: !references)
                }
            case 0x1F43B675 where cluster.size == nil:
                // The next cluster after one of unknown size
                reader.position -= element.headerLength
                return
            default: reader.skip(element)
            }
        }
    }

    private mutating func block(_ reader: inout Reader, _ element: Reader.Element, clusterTime: Int64,
                                simple: Bool, keyframe: Bool?) throws {
        let start = reader.position
        let end = try reader.end(of: element)
        guard let (trackNumber, numberLength) = reader.vint(at: start) else { throw ParseError.truncated }
        let headerEnd = start + numberLength + 3
        guard headerEnd <= end else { throw ParseError.truncated }
        let relative = Int16(bitPattern: UInt16(reader.data[reader.base + start + numberLength]) << 8
                             | UInt16(reader.data[reader.base + start + numberLength + 1]))
        let flags = reader.data[reader.base + start + numberLength + 2]
        reader.position = end
        // Laced blocks (several frames in one) are audio in practice: not taken
        guard flags & 0x06 == 0 else { return }
        let isKey = simple ? flags & 0x80 != 0 : (keyframe ?? false)
        samples[trackNumber, default: []].append(Sample(offset: Int64(headerEnd), length: end - headerEnd,
                                                        time: clusterTime + Int64(relative), keyframe: isKey))
    }

    /// EBML: elements with variable-length ids and sizes.
    struct Reader {
        struct Element {
            let id: UInt32
            let size: UInt64?        // nil: unknown size
            let headerLength: Int
        }
        let data: Data
        let base: Int
        var position = 0

        init(data: Data) {
            self.data = data
            base = data.startIndex
        }

        /// A variable-length integer with its marker bit removed, and its length.
        func vint(at offset: Int) -> (UInt64, Int)? {
            guard offset < data.count else { return nil }
            let first = data[base + offset]
            guard first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard offset + length <= data.count else { return nil }
            var value = UInt64(first) & ((1 << (8 - length)) - 1)
            for i in 1..<length { value = value << 8 | UInt64(data[base + offset + i]) }
            return (value, length)
        }

        mutating func element() -> Element? {
            guard position < data.count else { return nil }
            let first = data[base + position]
            guard first != 0 else { return nil }
            let idLength = first.leadingZeroBitCount + 1
            guard idLength <= 4, position + idLength <= data.count else { return nil }
            var id: UInt32 = 0
            for i in 0..<idLength { id = id << 8 | UInt32(data[base + position + i]) }
            guard let (size, sizeLength) = vint(at: position + idLength) else { return nil }
            let unknown = size == (UInt64(1) << (7 * sizeLength)) - 1
            position += idLength + sizeLength
            return Element(id: id, size: unknown ? nil : size, headerLength: idLength + sizeLength)
        }

        func end(of element: Element) throws -> Int {
            guard let size = element.size else { return data.count }
            guard size <= UInt64(data.count - position) else { throw ParseError.truncated }
            return position + Int(size)
        }

        mutating func skip(_ element: Element) {
            guard let size = element.size, size <= UInt64(data.count - position) else { position = data.count; return }
            position += Int(size)
        }

        mutating func bytes(_ element: Element) throws -> Data {
            let end = try end(of: element)
            defer { position = end }
            return data.subdata(in: (base + position)..<(base + end))
        }

        mutating func uint(_ element: Element) throws -> UInt64 {
            let raw = try bytes(element)
            guard raw.count <= 8 else { throw ParseError.truncated }
            return raw.reduce(0) { $0 << 8 | UInt64($1) }
        }

        mutating func float(_ element: Element) throws -> Double {
            let raw = try bytes(element)
            let bits = raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            switch raw.count {
            case 4: return Double(Float(bitPattern: UInt32(bits)))
            case 8: return Double(bitPattern: bits)
            default: return 0
            }
        }

        mutating func string(_ element: Element) throws -> String {
            String(decoding: try bytes(element).prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
