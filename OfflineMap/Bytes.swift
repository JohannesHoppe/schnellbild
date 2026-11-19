import Compression
import Foundation

/// Little-endian integers in the map's and the globe's files, at a byte
/// offset from the start of the bytes. The caller checks that the bytes
/// reach that far.
extension ContiguousBytes {
    func le16(_ offset: Int) -> Int {
        withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
    }

    func le32(_ offset: Int) -> Int {
        withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
    }

    func le64(_ offset: Int) -> UInt64 {
        withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}

/// Raw deflate (RFC 1951) with the system's zlib (Compression): inside
/// gzip's frame (`Gzip`), the place index's cells, and the app's zlib
/// streams (their two-byte header left off).
public enum RawDeflate {
    /// The unpacked bytes, at most `capacity` of them; empty when nothing
    /// unpacks. A caller that knows the length compares it.
    public static func decode(_ input: some ContiguousBytes, capacity: Int) -> Data {
        guard capacity > 0 else { return Data() }
        var out = Data(count: capacity)
        let produced = input.withUnsafeBytes { src -> Int in
            guard let source = src.bindMemory(to: UInt8.self).baseAddress, !src.isEmpty else { return 0 }
            return out.withUnsafeMutableBytes { dst in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, source, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        out.count = produced
        return out
    }
}
