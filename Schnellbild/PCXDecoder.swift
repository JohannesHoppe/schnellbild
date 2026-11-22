import Foundation

/// ZSoft's PCX (ZSoft "Technical Reference Manual", PCX file format
/// version 3.0 to 5): a 128-byte header (manufacturer 10, version,
/// encoding 1 = run-length, bits per pixel per plane, the window, the
/// 16-colour palette, the number of planes, the bytes per line of a plane,
/// little endian), then the rows, each plane of a row after the other,
/// run-length encoded (a byte with its two upper bits set repeats the next
/// byte its lower six bits' times). 1, 2, 4 or 8 bits per pixel per plane
/// in 1 to 4 planes: up to 4 bits in all a colour of the header's palette
/// (1 bit: black and white), 8 bits of one plane a colour of the 256-colour
/// palette after the picture (byte 12, then 768 bytes), grey without one;
/// 8 bits in 3 or 4 planes red, green, blue (and alpha). A DCX holds up to
/// 1023 PCX pages: the first is shown. Decoded here, no library.
enum PCXDecoder {
    struct Header: Equatable {
        let version: Int
        let encoded: Bool
        let bitsPerPlane: Int
        let planes: Int
        let width: Int
        let height: Int
        let bytesPerLine: Int
        /// Bits per pixel in all.
        var bitsPerPixel: Int { bitsPerPlane * planes }
        /// Red, green, blue (and alpha) of 8 bits each.
        var isDirectColour: Bool { bitsPerPlane == 8 && planes >= 3 }
    }

    static let headerSize = 128

    static func header(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        let b = data.startIndex
        func le16(_ at: Int) -> Int { Int(data[b + at]) | Int(data[b + at + 1]) << 8 }
        guard data[b] == 0x0A, [0, 2, 3, 4, 5].contains(Int(data[b + 1])), data[b + 2] <= 1 else { return nil }
        let bits = Int(data[b + 3]), planes = Int(data[b + 65])
        guard [1, 2, 4, 8].contains(bits), (1...4).contains(planes) else { return nil }
        // Up to 8 bits a pixel through a palette, or 8 bits in 3 or 4 planes
        guard bits * planes <= 8 || (bits == 8 && planes >= 3) else { return nil }
        let xMin = le16(4), yMin = le16(6), xMax = le16(8), yMax = le16(10)
        guard xMax >= xMin, yMax >= yMin else { return nil }
        let width = xMax - xMin + 1, height = yMax - yMin + 1
        let bytesPerLine = le16(66)
        // A plane's line holds the row's bits; no more than the 16-bit
        // field allows, and the picture within the limits
        guard bytesPerLine >= (width * bits + 7) / 8, DecodedPicture.fits(width: width, height: height) else { return nil }
        return Header(version: Int(data[b + 1]), encoded: data[b + 2] == 1, bitsPerPlane: bits, planes: planes,
                      width: width, height: height, bytesPerLine: bytesPerLine)
    }

    /// The first page of a DCX: its 4-byte id (987654321, little endian),
    /// then the pages' offsets, 0 after the last.
    static func firstDCXPage(_ data: Data) -> Data? {
        guard data.count >= 8 else { return nil }
        let b = data.startIndex
        func le32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[b + at + $1]) << (8 * $1) } }
        guard le32(0) == 987_654_321 else { return nil }
        let offset = le32(4)
        // After the id and the offsets' table, inside the file
        guard offset >= 8, offset < data.count else { return nil }
        let next = data.count >= 12 ? le32(8) : 0
        let end = next > offset && next <= data.count ? next : data.count
        return data.subdata(in: b + offset..<b + end)
    }

    /// The picture as far as its rows reach: a file cut short keeps the
    /// rows decoded (the rest black); nil without a valid header or a
    /// single row.
    static func decode(_ data: Data) -> DecodedPicture? {
        guard let header = header(data) else { return nil }
        let lineBytes = header.bytesPerLine * header.planes
        // Each row decoded into `line`, planes one after the other
        var line = [UInt8](repeating: 0, count: lineBytes)
        let palette = colours(of: header, in: data)
        var picture = DecodedPicture(width: header.width, height: header.height,
                                     hasAlpha: header.isDirectColour && header.planes == 4, linear: false)
        var rows = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var p = headerSize
            // A run may go on into the next row (encoders differ)
            var runLeft = 0
            var runValue: UInt8 = 0
            picture.pixels.withUnsafeMutableBufferPointer { out in
                rowLoop: for y in 0..<header.height {
                    var filled = 0
                    while filled < lineBytes {
                        if runLeft > 0 {
                            let n = min(runLeft, lineBytes - filled)
                            for i in 0..<n { line[filled + i] = runValue }
                            filled += n
                            runLeft -= n
                            continue
                        }
                        guard p < bytes.count else { break rowLoop }
                        let byte = bytes[p]
                        p += 1
                        if header.encoded, byte & 0xC0 == 0xC0 {
                            guard p < bytes.count else { break rowLoop }
                            runLeft = Int(byte & 0x3F)
                            runValue = bytes[p]
                            p += 1
                        } else {
                            line[filled] = byte
                            filled += 1
                        }
                    }
                    writeRow(line, y: y, header: header, palette: palette, into: out)
                    rows += 1
                }
            }
        }
        return rows > 0 ? picture : nil
    }

    /// One row of `line` (the planes' bytes) as RGBA into `out`.
    private static func writeRow(_ line: [UInt8], y: Int, header: Header, palette: [UInt8],
                                 into out: UnsafeMutableBufferPointer<UInt8>) {
        let width = header.width, bpl = header.bytesPerLine
        var o = y * width * 4
        if header.isDirectColour {
            for x in 0..<width {
                out[o] = line[x]
                out[o + 1] = line[bpl + x]
                out[o + 2] = line[2 * bpl + x]
                out[o + 3] = header.planes == 4 ? line[3 * bpl + x] : 255
                o += 4
            }
            return
        }
        let bits = header.bitsPerPlane
        let mask = (1 << bits) - 1
        for x in 0..<width {
            // Plane 0 holds the lowest bits of the colour's number
            var number = 0
            let bit = x * bits
            for plane in 0..<header.planes {
                let byte = Int(line[plane * bpl + (bit >> 3)])
                let value = (byte >> (8 - bits - (bit & 7))) & mask
                number |= value << (plane * bits)
            }
            let c = number * 3
            out[o] = palette[c]; out[o + 1] = palette[c + 1]; out[o + 2] = palette[c + 2]; out[o + 3] = 255
            o += 4
        }
    }

    /// The palette for a picture of up to 8 bits a pixel (256 colours,
    /// red, green, blue): black and white for 1 bit; the header's 16 for
    /// up to 4 bits (the EGA colours where the header holds none); for more
    /// the 256 after the picture (byte 12 before them), else grey.
    static func colours(of header: Header, in data: Data) -> [UInt8] {
        var palette = [UInt8](repeating: 0, count: 768)
        let b = data.startIndex
        guard !header.isDirectColour else { return palette }
        switch header.bitsPerPixel {
        case 1:
            palette[3] = 255; palette[4] = 255; palette[5] = 255
        case 2...4:
            let own = Array(data[b + 16..<b + 64])
            palette.replaceSubrange(0..<48, with: own.allSatisfy { $0 == 0 } ? egaColours : own)
        default:
            if data.count >= headerSize + 769, data[data.endIndex - 769] == 12 {
                palette = Array(data[data.endIndex - 768..<data.endIndex])
            } else {
                // Grey, spread over the colours there are
                let top = (1 << header.bitsPerPixel) - 1
                for i in 0...top {
                    let grey = UInt8(i * 255 / top)
                    palette[i * 3] = grey; palette[i * 3 + 1] = grey; palette[i * 3 + 2] = grey
                }
            }
        }
        return palette
    }

    /// The 16 colours of the EGA's default palette.
    static let egaColours: [UInt8] = [
        0, 0, 0, 0, 0, 170, 0, 170, 0, 0, 170, 170, 170, 0, 0, 170, 0, 170, 170, 85, 0, 170, 170, 170,
        85, 85, 85, 85, 85, 255, 85, 255, 85, 85, 255, 255, 255, 85, 85, 255, 85, 255, 255, 255, 85, 255, 255, 255,
    ]
}
