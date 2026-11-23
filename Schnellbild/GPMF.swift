import Foundation

/// GoPro's GPMF telemetry (github.com/gopro/gpmf-parser, README "GPMF Deeper
/// Dive"): key, length, value, big-endian, 32-bit aligned. The length is a
/// type character, a structure size (bytes per sample) and a repeat count
/// (samples); type 0 nests more KLV. Within a stream (`STRM`) the properties
/// before a key apply to it (`SCAL` divides, `TYPE` describes a `?`
/// structure). GPS: `GPS5` (latitude, longitude, altitude, 2D and 3D speed)
/// with `GPSU` (UTC time, "yymmddhhmmss.sss"), `GPSF` (fix: 0 none, 2 or 3)
/// and `GPSP` (dilution of precision × 100); `GPS9` (HERO11 on) carries per
/// sample also days since 2000, seconds since midnight, DOP and fix.
/// Huffman-compressed payloads (`#`) are skipped.
enum GPMF {
    /// One GPS sample.
    struct Fix: Equatable, Sendable {
        var point: GeoPoint
        var altitude: Double?
        /// UTC, when the sample or its payload says.
        var time: Date?
        /// 0 none, 2 two-dimensional, 3 three-dimensional; nil unknown.
        var fix: Int?
        /// Dilution of precision (GPSP / 100, or GPS9's own).
        var dilution: Double?
        /// Its place among its stream's samples in the payload, and their
        /// number: the samples are spread evenly over the payload's time.
        var sample = 0
        var samples = 1

        /// A 2D or 3D lock where the camera says.
        var isLocked: Bool { fix.map { $0 >= 2 } ?? true }

        /// Locked, with a dilution under 5 where it is known (GoPro: "under
        /// 500 is good" for GPSP).
        var isGood: Bool { isLocked && (dilution.map { $0 < 5 } ?? true) }
    }

    struct Item {
        let key: String
        let type: UInt8
        let structSize: Int
        let repeatCount: Int
        /// The data's range (without the padding).
        let data: Range<Int>
    }

    static let deepest = 8
    static let largestItems = 200_000

    /// The KLV items between `range`'s bounds, one level.
    static func items(_ bytes: [UInt8], _ range: Range<Int>) -> [Item] {
        var found: [Item] = []
        var at = range.lowerBound
        let end = min(range.upperBound, bytes.count)
        while at <= end - 8, found.count < largestItems {
            guard let key = bytes.fourCC(at), key != "\0\0\0\0",
                  let type = bytes.u8(at + 4), let size = bytes.u8(at + 5), let repeatCount = bytes.u16(at + 6) else { break }
            let length = Int(size) * Int(repeatCount)
            guard length <= end - at - 8 else { break }
            found.append(Item(key: key, type: type, structSize: Int(size), repeatCount: Int(repeatCount), data: at + 8..<at + 8 + length))
            at += 8 + ((length + 3) & ~3)
        }
        return found
    }

    /// Every GPS sample in one payload (one MP4 sample of the track).
    static func fixes(in bytes: [UInt8]) -> [Fix] {
        var result: [Fix] = []
        collect(bytes, 0..<bytes.count, depth: 0, into: &result)
        return result
    }

    private static func collect(_ bytes: [UInt8], _ range: Range<Int>, depth: Int, into result: inout [Fix]) {
        guard depth < deepest else { return }
        let level = items(bytes, range)
        if level.contains(where: { $0.key == "GPS5" || $0.key == "GPS9" }) {
            result += stream(bytes, level)
        }
        for item in level where item.type == 0 {
            collect(bytes, item.data, depth: depth + 1, into: &result)
        }
    }

    /// One stream's GPS samples, its properties applied in order.
    static func stream(_ bytes: [UInt8], _ level: [Item]) -> [Fix] {
        var scale: [Double] = []
        var structure: [UInt8]?
        var fixState: Int?
        var dilution: Double?
        var utc: Date?
        var result: [Fix] = []
        for item in level {
            switch item.key {
            case "SCAL":
                scale = numbers(bytes, item) ?? []
            case "TYPE":
                structure = expandType(Array(bytes[item.data]))
            case "GPSF":
                fixState = numbers(bytes, item)?.first.flatMap(whole)
            case "GPSP":
                dilution = numbers(bytes, item)?.first.map { $0 / 100 }
            case "GPSU":
                utc = gpsTime(Array(bytes[item.data]))
            case "GPS5", "GPS9":
                let types: [UInt8]
                if item.type == UInt8(ascii: "?") {
                    guard let structure else { continue }
                    types = structure
                } else {
                    guard let size = typeSize(item.type), size > 0 else { continue }
                    types = Array(repeating: item.type, count: item.structSize / size)
                }
                guard types.count >= 3, types.reduce(0, { $0 + (typeSize($1) ?? 1_000) }) == item.structSize else { continue }
                for sample in 0..<item.repeatCount {
                    let start = item.data.lowerBound + sample * item.structSize
                    guard var values = decode(bytes, at: start, types: types) else { break }
                    var usable = true
                    for i in values.indices {
                        let divisor = scale.isEmpty ? 1 : (scale.count == 1 ? scale[0] : (i < scale.count ? scale[i] : 1))
                        guard divisor != 0, divisor.isFinite else { usable = false; break }
                        values[i] /= divisor
                    }
                    guard usable, let point = GeoPoint(latitude: values[0], longitude: values[1]),
                          !(values[0] == 0 && values[1] == 0) else { continue }
                    var fix = Fix(point: point, altitude: values[2].isFinite ? values[2] : nil,
                                  time: sample == 0 ? utc : nil, fix: fixState, dilution: dilution,
                                  sample: sample, samples: item.repeatCount)
                    if item.key == "GPS9", values.count >= 9 {
                        let days = values[5], seconds = values[6]
                        if days.isFinite, seconds.isFinite, days > 0, days < 100_000, seconds >= 0, seconds < 86_401 {
                            fix.time = Date(timeIntervalSinceReferenceDate: 0)
                                .addingTimeInterval(-31_622_400 + days * 86_400 + seconds)   // 2000-01-01 UTC
                        }
                        fix.dilution = values[7].isFinite ? values[7] : nil
                        fix.fix = whole(values[8])
                    }
                    result.append(fix)
                }
            default:
                break
            }
        }
        return result
    }

    /// A whole number in Int's range, nil for anything else (NaN, ±∞, 1e300).
    static func whole(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        return Int(value.rounded())
    }

    /// Bytes per value of a type character; nil for one not a number here.
    static func typeSize(_ type: UInt8) -> Int? {
        switch Character(Unicode.Scalar(type)) {
        case "b", "B", "c": return 1
        case "s", "S": return 2
        case "l", "L", "f", "q": return 4
        case "d", "j", "J", "Q": return 8
        default: return nil
        }
    }

    /// A `TYPE` string with GPMF's repeat syntax expanded ("l[3]S" → "lllS").
    static func expandType(_ text: [UInt8]) -> [UInt8]? {
        var result: [UInt8] = []
        var i = 0
        while i < text.count, result.count <= 255 {
            let c = text[i]
            if c == 0 { break }
            if c == UInt8(ascii: "[") {
                guard let last = result.last else { return nil }
                var j = i + 1, count = 0
                while j < text.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(text[j]), count < 256 {
                    count = count * 10 + Int(text[j] - UInt8(ascii: "0"))
                    j += 1
                }
                guard j < text.count, text[j] == UInt8(ascii: "]"), count >= 1 else { return nil }
                result += Array(repeating: last, count: min(count - 1, 255))
                i = j + 1
                continue
            }
            result.append(c)
            i += 1
        }
        return result.count <= 255 ? result : nil
    }

    /// The values of a simple item (`SCAL`, `GPSF`, `GPSP`): every sample's
    /// elements in order.
    static func numbers(_ bytes: [UInt8], _ item: Item) -> [Double]? {
        guard let size = typeSize(item.type), size > 0, item.structSize % size == 0 else { return nil }
        let perSample = item.structSize / size
        let count = min(perSample * item.repeatCount, 4_096)
        return decode(bytes, at: item.data.lowerBound, types: Array(repeating: item.type, count: count))
    }

    /// Values of the given types from `at` on; nil when they run past the end.
    static func decode(_ bytes: [UInt8], at start: Int, types: [UInt8]) -> [Double]? {
        var values: [Double] = []
        values.reserveCapacity(types.count)
        var at = start
        for type in types {
            let value: Double
            switch Character(Unicode.Scalar(type)) {
            case "b": guard let v = bytes.u8(at) else { return nil }; value = Double(Int8(bitPattern: v))
            case "B", "c": guard let v = bytes.u8(at) else { return nil }; value = Double(v)
            case "s": guard let v = bytes.u16(at) else { return nil }; value = Double(Int16(bitPattern: v))
            case "S": guard let v = bytes.u16(at) else { return nil }; value = Double(v)
            case "l": guard let v = bytes.u32(at) else { return nil }; value = Double(Int32(bitPattern: v))
            case "L": guard let v = bytes.u32(at) else { return nil }; value = Double(v)
            case "f": guard let v = bytes.u32(at) else { return nil }; value = Double(Float(bitPattern: v))
            case "q": guard let v = bytes.u32(at) else { return nil }; value = Double(Int32(bitPattern: v)) / 65_536
            case "d": guard let v = bytes.u64(at) else { return nil }; value = Double(bitPattern: v)
            case "j": guard let v = bytes.u64(at) else { return nil }; value = Double(Int64(bitPattern: v))
            case "J": guard let v = bytes.u64(at) else { return nil }; value = Double(v)
            case "Q": guard let v = bytes.u64(at) else { return nil }; value = Double(Int64(bitPattern: v)) / 4_294_967_296
            default: return nil
            }
            values.append(value)
            at += typeSize(type) ?? 1
        }
        return values
    }

    /// `GPSU`: "yymmddhhmmss.sss" in UTC, years 2000 to 2099.
    static func gpsTime(_ text: [UInt8]) -> Date? {
        guard text.count >= 12 else { return nil }
        let string = String(decoding: text.prefix(16), as: UTF8.self)
        let pattern = #"^(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d(?:\.\d{1,3})?)"#
        guard let match = string.range(of: pattern, options: .regularExpression) else { return nil }
        let digits = String(string[match])
        func int(_ from: Int, _ length: Int) -> Int? {
            let start = digits.index(digits.startIndex, offsetBy: from)
            return Int(digits[start..<digits.index(start, offsetBy: length)])
        }
        guard let year = int(0, 2), let month = int(2, 2), let day = int(4, 2), let hour = int(6, 2), let minute = int(8, 2),
              let seconds = Double(digits.dropFirst(10)), (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, seconds < 61 else { return nil }
        var components = DateComponents(year: 2000 + year, month: month, day: day, hour: hour, minute: minute, second: 0)
        components.timeZone = TimeZone(identifier: "UTC")
        guard let base = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        return base.addingTimeInterval(seconds)
    }
}
