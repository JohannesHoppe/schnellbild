import Compression
import Foundation

/// Unpacks gzip (RFC 1952) with the system's zlib (Compression's raw deflate),
/// as PMTiles stores its directories and tiles. Returns nil for anything that
/// isn't a whole, well-formed gzip member; never reads outside the bytes given.
enum Gzip {
    /// Unpacked tiles and directories larger than this are refused (a tile of
    /// the bundled map is at most a few MB unpacked).
    static let largestOutput = 64 << 20

    static func decompress(_ bytes: UnsafeRawBufferPointer) -> Data? {
        let n = bytes.count
        guard n >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var p = 10
        if flags & 4 != 0 {   // FEXTRA
            guard p + 2 <= n else { return nil }
            p += 2 + (Int(bytes[p]) | Int(bytes[p + 1]) << 8)
        }
        for flag in [UInt8(8), 16] where flags & flag != 0 {   // FNAME, FCOMMENT: zero-terminated
            while p < n, bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 2 != 0 { p += 2 }   // FHCRC
        guard p < n - 8 else { return nil }
        let size = Int(bytes[n - 4]) | Int(bytes[n - 3]) << 8 | Int(bytes[n - 2]) << 16 | Int(bytes[n - 1]) << 24
        guard size <= largestOutput else { return nil }
        if size == 0 { return Data() }
        var out = Data(count: size + 1)
        let produced = out.withUnsafeMutableBytes { dst -> Int in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                      bytes.bindMemory(to: UInt8.self).baseAddress! + p, n - p - 8,
                                      nil, COMPRESSION_ZLIB)
        }
        // ISIZE is the size modulo 2^32: exactly that much, else it isn't this member
        guard produced == size else { return nil }
        out.count = size
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        data.withUnsafeBytes { decompress($0) }
    }
}
