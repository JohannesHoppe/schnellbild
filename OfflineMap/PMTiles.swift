import Foundation

/// A PMTiles v3 archive (https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md),
/// memory-mapped: the header and root directory are read at opening, leaf
/// directories when first needed (kept), tiles on every request. Reading
/// never goes outside the file; a malformed directory or tile reads as
/// missing. Safe to use from several threads.
public final class PMTilesArchive: @unchecked Sendable {
    public enum Compression: UInt8, Sendable { case unknown = 0, none = 1, gzip = 2, brotli = 3, zstd = 4 }

    public struct Header: Equatable, Sendable {
        public var rootOffset, rootLength, metadataOffset, metadataLength: UInt64
        public var leafOffset, leafLength, dataOffset, dataLength: UInt64
        public var addressedTiles, tileEntries, tileContents: UInt64
        public var clustered: Bool
        public var internalCompression, tileCompression: Compression
        public var tileType: UInt8
        public var minZoom, maxZoom: Int
    }

    /// One directory entry: a run of `runLength` tiles from `tileID` with the
    /// same bytes, or (run length 0) a leaf directory.
    struct Entry: Equatable {
        var tileID: UInt64
        var offset: UInt64
        var length: UInt32
        var runLength: UInt32
    }

    public enum ArchiveError: Error, Equatable {
        case notPMTiles, unsupportedVersion(UInt8), malformed(String)
    }

    public let header: Header
    private let data: Data
    private let root: [Entry]
    private var leaves: [UInt64: [Entry]] = [:]
    private let lock = NSLock()

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 127 else { throw ArchiveError.notPMTiles }
        let magic = data.prefix(7)
        guard magic.elementsEqual("PMTiles".utf8) else { throw ArchiveError.notPMTiles }
        let version = data[data.startIndex + 7]
        guard version == 3 else { throw ArchiveError.unsupportedVersion(version) }
        func u64(_ at: Int) -> UInt64 {
            data.withUnsafeBytes { raw in
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(raw[at + i]) << (8 * UInt64(i)) }
                return v
            }
        }
        func u8(_ at: Int) -> UInt8 { data[data.startIndex + at] }
        let h = Header(rootOffset: u64(8), rootLength: u64(16), metadataOffset: u64(24), metadataLength: u64(32),
                       leafOffset: u64(40), leafLength: u64(48), dataOffset: u64(56), dataLength: u64(64),
                       addressedTiles: u64(72), tileEntries: u64(80), tileContents: u64(88),
                       clustered: u8(96) == 1,
                       internalCompression: Compression(rawValue: u8(97)) ?? .unknown,
                       tileCompression: Compression(rawValue: u8(98)) ?? .unknown,
                       tileType: u8(99), minZoom: Int(u8(100)), maxZoom: Int(u8(101)))
        header = h
        guard [.none, .gzip].contains(h.internalCompression) else { throw ArchiveError.malformed("directory compression") }
        guard let rootBytes = Self.slice(data, h.rootOffset, h.rootLength),
              let rootData = Self.unpack(rootBytes, h.internalCompression),
              let entries = Self.parseDirectory(rootData) else { throw ArchiveError.malformed("root directory") }
        root = entries
    }

    /// The metadata JSON, unpacked.
    public var metadata: [String: Any] {
        guard let bytes = Self.slice(data, header.metadataOffset, header.metadataLength),
              let json = Self.unpack(bytes, header.internalCompression),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [:] }
        return object
    }

    /// The tile's bytes as stored (still compressed with `header.tileCompression`).
    public func storedTile(z: Int, x: Int, y: Int) -> Data? {
        guard z >= 0, z <= 26, x >= 0, y >= 0, x < 1 << z, y < 1 << z else { return nil }
        let id = Self.tileID(z: z, x: x, y: y)
        var directory = root
        for _ in 0..<4 {   // the spec allows at most three levels of leaves
            guard let entry = Self.find(id, in: directory) else { return nil }
            if entry.runLength > 0 {
                return Self.slice(data, header.dataOffset &+ entry.offset, UInt64(entry.length))
            }
            guard let leaf = leaf(at: entry.offset, length: UInt64(entry.length)) else { return nil }
            directory = leaf
        }
        return nil
    }

    /// The tile's bytes, unpacked.
    public func tile(z: Int, x: Int, y: Int) -> Data? {
        guard let stored = storedTile(z: z, x: x, y: y) else { return nil }
        return Self.unpack(stored, header.tileCompression)
    }

    private func leaf(at offset: UInt64, length: UInt64) -> [Entry]? {
        lock.lock()
        if let cached = leaves[offset] { lock.unlock(); return cached }
        lock.unlock()
        guard let bytes = Self.slice(data, header.leafOffset &+ offset, length),
              let unpacked = Self.unpack(bytes, header.internalCompression),
              let entries = Self.parseDirectory(unpacked) else { return nil }
        lock.lock()
        leaves[offset] = entries
        lock.unlock()
        return entries
    }

    // MARK: Format

    static func slice(_ data: Data, _ offset: UInt64, _ length: UInt64) -> Data? {
        guard length > 0, offset < UInt64(data.count), length <= UInt64(data.count) - offset else { return nil }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<start + Int(length))
    }

    static func unpack(_ data: Data, _ compression: Compression) -> Data? {
        switch compression {
        case .none: return data
        case .gzip: return Gzip.decompress(data)
        default: return nil
        }
    }

    /// The entry holding `id`: the last one starting at or before it, if its
    /// run reaches it (a leaf directory reaches everything up to the next entry).
    static func find(_ id: UInt64, in entries: [Entry]) -> Entry? {
        var lo = 0, hi = entries.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].tileID <= id { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let entry = entries[found]
        if entry.runLength == 0 { return entry }
        return id - entry.tileID < UInt64(entry.runLength) ? entry : nil
    }

    static func parseDirectory(_ data: Data) -> [Entry]? {
        data.withUnsafeBytes { raw -> [Entry]? in
            var reader = ProtoReader(raw)
            guard let count = try? reader.varint(), count <= UInt64(raw.count) else { return nil }
            let n = Int(count)
            var entries = [Entry](repeating: Entry(tileID: 0, offset: 0, length: 0, runLength: 0), count: n)
            do {
                var last: UInt64 = 0
                for i in 0..<n { last = last &+ (try reader.varint()); entries[i].tileID = last }
                for i in 0..<n { entries[i].runLength = UInt32(truncatingIfNeeded: try reader.varint()) }
                for i in 0..<n { entries[i].length = UInt32(truncatingIfNeeded: try reader.varint()) }
                for i in 0..<n {
                    let v = try reader.varint()
                    if v == 0 && i > 0 {
                        entries[i].offset = entries[i - 1].offset &+ UInt64(entries[i - 1].length)
                    } else {
                        guard v > 0 else { return nil }
                        entries[i].offset = v - 1
                    }
                }
            } catch { return nil }
            return entries
        }
    }

    /// The tile's id: tiles of all lower zooms first, then the Hilbert curve's
    /// index within its zoom.
    public static func tileID(z: Int, x: Int, y: Int) -> UInt64 {
        var acc: UInt64 = 0
        for level in 0..<z { acc += UInt64(1) << UInt64(2 * level) }
        let n = 1 << z
        var x = x, y = y, d: UInt64 = 0
        var s = n >> 1
        while s > 0 {
            let rx = (x & s) > 0 ? 1 : 0
            let ry = (y & s) > 0 ? 1 : 0
            d += UInt64(s) * UInt64(s) * UInt64((3 * rx) ^ ry)
            if ry == 0 {
                if rx == 1 { x = s - 1 - x; y = s - 1 - y }
                swap(&x, &y)
            }
            s >>= 1
        }
        return acc + d
    }
}
