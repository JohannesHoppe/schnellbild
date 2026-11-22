import Foundation

/// The Quite OK Image format (qoiformat.org, specification 1.0 of
/// 2022-01-05): a 14-byte header ("qoif", width and height big endian,
/// channels 3 or 4, colour space 0 sRGB / 1 linear), chunks, and an end
/// marker of seven 0x00 and one 0x01. Decoded here, no library.
enum QOIDecoder {
    struct Header: Equatable {
        let width: Int
        let height: Int
        let channels: Int
        let linear: Bool
    }

    static let headerSize = 14

    /// The header, when `data` starts with a valid one within the limits.
    static func header(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        let b = data.startIndex
        guard data[b] == 0x71, data[b + 1] == 0x6F, data[b + 2] == 0x69, data[b + 3] == 0x66 else { return nil }   // "qoif"
        func be32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(data[b + at + $1]) } }
        let width = be32(4), height = be32(8), channels = Int(data[b + 12]), colorspace = data[b + 13]
        guard channels == 3 || channels == 4, colorspace <= 1,
              DecodedPicture.fits(width: width, height: height) else { return nil }
        return Header(width: width, height: height, channels: channels, linear: colorspace == 1)
    }

    /// The picture, as far as the chunks reach: a file cut short keeps the
    /// pixels decoded (the rest transparent); nil without a valid header or
    /// without a single pixel.
    static func decode(_ data: Data) -> DecodedPicture? {
        guard let header = header(data) else { return nil }
        let count = header.width * header.height
        var picture = DecodedPicture(width: header.width, height: header.height,
                                     hasAlpha: header.channels == 4, linear: header.linear)
        var decoded = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            // The end marker's 8 bytes are no chunks
            let end = max(headerSize, bytes.count - 8)
            var p = headerSize
            var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255
            var index = [UInt8](repeating: 0, count: 64 * 4)
            var run = 0
            picture.pixels.withUnsafeMutableBufferPointer { out in
                decoding: while decoded < count {
                    if run > 0 {
                        run -= 1
                    } else {
                        guard p < end else { break decoding }
                        let tag = bytes[p]
                        if tag == 0xFE {                     // QOI_OP_RGB
                            guard p + 4 <= end else { break decoding }
                            r = bytes[p + 1]; g = bytes[p + 2]; b = bytes[p + 3]
                            p += 4
                        } else if tag == 0xFF {              // QOI_OP_RGBA
                            guard p + 5 <= end else { break decoding }
                            r = bytes[p + 1]; g = bytes[p + 2]; b = bytes[p + 3]; a = bytes[p + 4]
                            p += 5
                        } else {
                            switch tag >> 6 {
                            case 0:                          // QOI_OP_INDEX
                                let at = Int(tag & 0x3F) * 4
                                r = index[at]; g = index[at + 1]; b = index[at + 2]; a = index[at + 3]
                                p += 1
                            case 1:                          // QOI_OP_DIFF, bias 2
                                r = r &+ ((tag >> 4) & 3) &- 2
                                g = g &+ ((tag >> 2) & 3) &- 2
                                b = b &+ (tag & 3) &- 2
                                p += 1
                            case 2:                          // QOI_OP_LUMA, bias 32 and 8
                                guard p + 2 <= end else { break decoding }
                                let second = bytes[p + 1]
                                let dg = (tag & 0x3F) &- 32
                                r = r &+ dg &+ (second >> 4) &- 8
                                g = g &+ dg
                                b = b &+ dg &+ (second & 0x0F) &- 8
                                p += 2
                            default:                         // QOI_OP_RUN, bias -1: 1 … 62
                                run = Int(tag & 0x3F)
                                p += 1
                            }
                        }
                        let at = (Int(r) &* 3 &+ Int(g) &* 5 &+ Int(b) &* 7 &+ Int(a) &* 11) % 64 * 4
                        index[at] = r; index[at + 1] = g; index[at + 2] = b; index[at + 3] = a
                    }
                    let o = decoded * 4
                    out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = a
                    decoded += 1
                }
            }
        }
        return decoded > 0 ? picture : nil
    }
}
