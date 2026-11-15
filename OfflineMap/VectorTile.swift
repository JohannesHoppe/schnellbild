import CoreGraphics
import Foundation

/// Reads protocol buffer fields from bytes; every read is checked against
/// the end, a malformed message throws.
struct ProtoReader {
    enum ReadError: Error { case truncated, malformed }

    let bytes: UnsafeRawBufferPointer
    var position: Int
    let end: Int

    init(_ bytes: UnsafeRawBufferPointer, from: Int = 0, to: Int? = nil) {
        self.bytes = bytes
        position = from
        end = to ?? bytes.count
    }

    var hasMore: Bool { position < end }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < end else { throw ReadError.truncated }
            let b = bytes[position]
            position += 1
            guard shift < 64 else { throw ReadError.malformed }
            result |= UInt64(b & 0x7F) << shift
            if b < 0x80 { return result }
            shift += 7
        }
    }

    mutating func key() throws -> (field: Int, wire: Int) {
        let k = try varint()
        return (Int(truncatingIfNeeded: k >> 3), Int(k & 7))
    }

    /// The length-delimited field that follows, as a reader of its own.
    mutating func message() throws -> ProtoReader {
        let length = try varint()
        guard length <= UInt64(end - position) else { throw ReadError.truncated }
        let sub = ProtoReader(bytes, from: position, to: position + Int(length))
        position += Int(length)
        return sub
    }

    mutating func string() throws -> String {
        let sub = try message()
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[sub.position..<sub.end]), as: UTF8.self)
    }

    mutating func fixed32() throws -> UInt32 {
        guard end - position >= 4 else { throw ReadError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[position + i]) << (8 * UInt32(i)) }
        position += 4
        return v
    }

    mutating func fixed64() throws -> UInt64 {
        guard end - position >= 8 else { throw ReadError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[position + i]) << (8 * UInt64(i)) }
        position += 8
        return v
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: guard end - position >= 8 else { throw ReadError.truncated }; position += 8
        case 2: _ = try message()
        case 5: guard end - position >= 4 else { throw ReadError.truncated }; position += 4
        default: throw ReadError.malformed
        }
    }
}

@inline(__always) func zigzag(_ v: UInt64) -> Int {
    Int(truncatingIfNeeded: v >> 1) ^ -Int(truncatingIfNeeded: v & 1)
}

/// A Mapbox Vector Tile (https://github.com/mapbox/vector-tile-spec, version 2):
/// its layers with their features, geometry decoded to points in the tile's
/// own coordinates (0 to `extent`).
public struct VectorTile: Sendable {
    public enum Value: Equatable, Sendable {
        case string(String), double(Double), int(Int), bool(Bool)

        public var string: String? { if case .string(let s) = self { return s }; return nil }
        public var number: Double? {
            switch self {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }
    }

    public enum GeometryType: Int, Sendable { case unknown = 0, point = 1, line = 2, polygon = 3 }

    public struct Feature: Sendable {
        public var type: GeometryType
        public var properties: [String: Value]
        /// All parts' points one after the other; `partEnds[i]` is where part i ends.
        public var points: [CGPoint]
        public var partEnds: [Int]
        /// The points' bounding box
        public var bounds: CGRect
        /// Each part's bounding box
        public var partBounds: [CGRect]

        public subscript(key: String) -> Value? { properties[key] }

        /// The points of part `i`.
        public func part(_ i: Int) -> ArraySlice<CGPoint> {
            points[(i == 0 ? 0 : partEnds[i - 1])..<partEnds[i]]
        }
    }

    public struct Layer: Sendable {
        public var name: String
        public var extent: Double
        public var features: [Feature]
    }

    public var layers: [String: Layer]

    public init(layers: [String: Layer]) { self.layers = layers }

    /// Decodes a tile (unpacked). Only the layers named in `wanted` when given.
    public init(data: Data, wanted: Set<String>? = nil) throws {
        layers = try data.withUnsafeBytes { raw in
            var top = ProtoReader(raw)
            var out: [String: Layer] = [:]
            while top.hasMore {
                let (field, wire) = try top.key()
                guard field == 3, wire == 2 else { try top.skip(wire); continue }
                if let layer = try Self.layer(try top.message(), wanted: wanted) { out[layer.name] = layer }
            }
            return out
        }
    }

    private static func layer(_ message: ProtoReader, wanted: Set<String>?) throws -> Layer? {
        var reader = message
        var name = "", extent = 4096.0
        var keys: [String] = [], values: [Value] = [], features: [ProtoReader] = []
        while reader.hasMore {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2): name = try reader.string()
            case (2, 2): features.append(try reader.message())
            case (3, 2): keys.append(try reader.string())
            case (4, 2): values.append(try value(try reader.message()))
            case (5, 0): extent = Double(try reader.varint())
            default: try reader.skip(wire)
            }
        }
        if let wanted, !wanted.contains(name) { return nil }
        guard extent > 0 else { throw ProtoReader.ReadError.malformed }
        var decoded: [Feature] = []
        decoded.reserveCapacity(features.count)
        for message in features {
            if let feature = try feature(message, keys: keys, values: values) { decoded.append(feature) }
        }
        return Layer(name: name, extent: extent, features: decoded)
    }

    private static func value(_ message: ProtoReader) throws -> Value {
        var reader = message
        var result = Value.int(0)
        while reader.hasMore {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2): result = .string(try reader.string())
            case (2, 5): result = .double(Double(Float(bitPattern: try reader.fixed32())))
            case (3, 1): result = .double(Double(bitPattern: try reader.fixed64()))
            case (4, 0), (5, 0): result = .int(Int(truncatingIfNeeded: try reader.varint()))
            case (6, 0): result = .int(zigzag(try reader.varint()))
            case (7, 0): result = .bool(try reader.varint() != 0)
            default: try reader.skip(wire)
            }
        }
        return result
    }

    private static func feature(_ message: ProtoReader, keys: [String], values: [Value]) throws -> Feature? {
        var reader = message
        var type = GeometryType.unknown
        var properties: [String: Value] = [:]
        var geometry: ProtoReader?
        while reader.hasMore {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (2, 2):
                var tags = try reader.message()
                while tags.hasMore {
                    let k = Int(truncatingIfNeeded: try tags.varint())
                    guard tags.hasMore else { throw ProtoReader.ReadError.truncated }
                    let v = Int(truncatingIfNeeded: try tags.varint())
                    guard keys.indices.contains(k), values.indices.contains(v) else { throw ProtoReader.ReadError.malformed }
                    properties[keys[k]] = values[v]
                }
            case (3, 0): type = GeometryType(rawValue: Int(truncatingIfNeeded: try reader.varint())) ?? .unknown
            case (4, 2): geometry = try reader.message()
            default: try reader.skip(wire)
            }
        }
        guard var g = geometry else { return nil }
        var points: [CGPoint] = []
        var partEnds: [Int] = []
        var x = 0, y = 0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        while g.hasMore {
            let command = try g.varint()
            let id = Int(command & 7), count = Int(truncatingIfNeeded: command >> 3)
            switch id {
            case 1, 2:   // MoveTo starts a part, LineTo continues it
                guard count <= (g.end - g.position) / 2 + 1 else { throw ProtoReader.ReadError.malformed }
                for _ in 0..<count {
                    x &+= zigzag(try g.varint())
                    y &+= zigzag(try g.varint())
                    if id == 1, !points.isEmpty, partEnds.last != points.count { partEnds.append(points.count) }
                    points.append(CGPoint(x: x, y: y))
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            case 7:   // ClosePath: back to the part's first point
                let start = partEnds.last ?? 0
                if points.count > start { points.append(points[start]) }
            default:
                throw ProtoReader.ReadError.malformed
            }
        }
        guard !points.isEmpty else { return nil }
        if partEnds.last != points.count { partEnds.append(points.count) }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        var partBounds: [CGRect] = []
        partBounds.reserveCapacity(partEnds.count)
        var start = 0
        for end in partEnds {
            var x0 = CGFloat.greatestFiniteMagnitude, y0 = x0, x1 = -x0, y1 = -x0
            for p in points[start..<end] {
                x0 = min(x0, p.x); x1 = max(x1, p.x); y0 = min(y0, p.y); y1 = max(y1, p.y)
            }
            partBounds.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            start = end
        }
        return Feature(type: type, properties: properties, points: points, partEnds: partEnds, bounds: bounds, partBounds: partBounds)
    }
}
