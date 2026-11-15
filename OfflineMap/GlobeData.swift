import CoreGraphics
import Foundation
import ImageIO
import simd

/// Elevation and ocean depth of the whole Earth on a grid of whole degrees'
/// fractions, in metres, for the globe's relief.
///
/// The file format ("SBHM", little-endian throughout):
///
///     4 bytes  magic "SBHM"
///     2 bytes  version, 1
///     2 bytes  flags, 0
///     4 bytes  width (cells around the equator)
///     4 bytes  height (cells from pole to pole)
///     then width × height int16: metres above (below 0: under) sea level,
///     row by row from the north, each row from 180° W eastwards; cell
///     (i, j) is centred on longitude −180 + (i + ½) · 360 / width and
///     latitude 90 − (j + ½) · 180 / height.
///
/// 1/8° is 2880 × 1440 cells (8.3 MB), the bundled model (NOAA ETOPO 2022,
/// `GlobeData`). Without it `placeholder` makes a coarse stand-in from the
/// map's coastlines.
public struct Heightmap: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major from the north, metres
    public let metres: [Int16]

    public enum ReadError: Error { case notAHeightmap, unsupportedVersion, truncated }

    public init(width: Int, height: Int, metres: [Int16]) {
        precondition(metres.count == width * height)
        self.width = width
        self.height = height
        self.metres = metres
    }

    public init(data: Data) throws {
        guard data.count >= 16, data.prefix(4) == Data("SBHM".utf8) else { throw ReadError.notAHeightmap }
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard u16(4) == 1 else { throw ReadError.unsupportedVersion }
        let w = u32(8), h = u32(12)
        guard w > 0, h > 0, w <= 1 << 16, h <= 1 << 15, data.count >= 16 + w * h * 2 else { throw ReadError.truncated }
        var values = [Int16](repeating: 0, count: w * h)
        values.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { raw in
                out.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[16..<(16 + w * h * 2)]))
            }
        }
        self.init(width: w, height: h, metres: values.map { Int16(littleEndian: $0) })
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    /// The file's bytes (the format above).
    public var fileData: Data {
        var d = Data("SBHM".utf8)
        func put(_ v: Int, _ bytes: Int) { for i in 0..<bytes { d.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        put(1, 2); put(0, 2); put(width, 4); put(height, 4)
        metres.withUnsafeBufferPointer { b in
            for v in b { put(Int(UInt16(bitPattern: v)), 2) }
        }
        return d
    }

    /// The height at a coordinate, bilinear between the cells' centres (metres).
    public func metres(at c: Coordinate) -> Double {
        let x = (c.longitude + 180) / 360 * Double(width) - 0.5
        let y = (90 - c.latitude) / 180 * Double(height) - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        func at(_ i: Int, _ j: Int) -> Double {
            let ii = ((i % width) + width) % width, jj = min(height - 1, max(0, j))
            return Double(metres[jj * width + ii])
        }
        let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
        let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// A coarse stand-in for a real elevation model, made from the map's
    /// land and water (light palette, zoom 2) on a grid of half degrees:
    /// land rises gently from the coast, Antarctica's ice higher, the sea floor
    /// falls from a shelf to the deep ocean. No mountains: it only shows the
    /// relief's machinery where the elevation data is missing.
    public static func placeholder(from renderer: MapRenderer, width: Int = 720, height: Int = 360) -> Heightmap {
        let z = 2, n = 1 << z, side = 256, px = side * n
        var mask = [UInt8](repeating: 0, count: px * px)   // 0 water, 1 land
        let palette = MapPalette.light
        func distance(_ r: Int, _ g: Int, _ b: Int, _ c: MapColor) -> Int {
            let dr = r - Int(c.red * 255), dg = g - Int(c.green * 255), db = b - Int(c.blue * 255)
            return dr * dr + dg * dg + db * db
        }
        for ty in 0..<n {
            for tx in 0..<n {
                guard let ctx = MapRenderer.context(width: side, height: side) else { continue }
                ctx.translateBy(x: 0, y: CGFloat(side))
                ctx.scaleBy(x: 1, y: -1)
                renderer.drawTile(TileKey(z: z, x: tx, y: ty), in: ctx, palette: palette, tolerance: 0.5)
                guard let data = ctx.data else { continue }
                let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * side)
                for y in 0..<side {
                    for x in 0..<side {
                        let o = y * ctx.bytesPerRow + x * 4   // BGRA
                        let b = Int(bytes[o]), g = Int(bytes[o + 1]), r = Int(bytes[o + 2])
                        let water = distance(r, g, b, palette.water), land = distance(r, g, b, palette.land)
                        mask[(ty * side + y) * px + tx * side + x] = water < land ? 0 : 1
                    }
                }
            }
        }
        // The class of each half-degree cell (beyond ±85°: Arctic sea, Antarctic ice)
        var cls = [UInt8](repeating: 0, count: width * height)
        for j in 0..<height {
            let lat = 90 - (Double(j) + 0.5) * 180 / Double(height)
            for i in 0..<width {
                if lat > WebMercator.maxLatitude { cls[j * width + i] = 0; continue }
                if lat < -WebMercator.maxLatitude { cls[j * width + i] = 2; continue }
                let lon = -180 + (Double(i) + 0.5) * 360 / Double(width)
                let u = WebMercator.unitPoint(Coordinate(latitude: lat, longitude: lon))
                let x = min(px - 1, Int(Double(u.x) * Double(px))), y = min(px - 1, Int(Double(u.y) * Double(px)))
                // Land south of 60° S is the Antarctic ice sheet
                cls[j * width + i] = mask[y * px + x] == 0 ? 0 : (lat < -60 ? 2 : 1)
            }
        }
        // Distance to the coast in cells north–south (two-pass chamfer, wrapping east–west; a step east or
        // west is as long as the row's cosine), for land and for sea
        let steps: [(Double, Double)] = (0..<height).map { j in
            let c = cos((90 - (Double(j) + 0.5) * 180 / Double(height)) * .pi / 180) * Double(height) * 2 / Double(width)
            return (c, (1 + c * c).squareRoot())
        }
        func distances(inside: (UInt8) -> Bool) -> [Double] {
            var d = cls.map { inside($0) ? Double.greatestFiniteMagnitude : 0 }
            func relax(_ i: Int, _ j: Int, _ di: Int, _ dj: Int, _ cost: Double) {
                let jj = j + dj
                guard jj >= 0, jj < height else { return }
                let ii = ((i + di) % width + width) % width
                let o = d[jj * width + ii] + cost
                if o < d[j * width + i] { d[j * width + i] = o }
            }
            for j in 0..<height { for i in 0..<width where d[j * width + i] > 0 {
                let (ew, diag) = steps[j]
                relax(i, j, -1, 0, ew); relax(i, j, 0, -1, 1); relax(i, j, -1, -1, diag); relax(i, j, 1, -1, diag)
            } }
            for j in stride(from: height - 1, through: 0, by: -1) { for i in stride(from: width - 1, through: 0, by: -1) where d[j * width + i] > 0 {
                let (ew, diag) = steps[j]
                relax(i, j, 1, 0, ew); relax(i, j, 0, 1, 1); relax(i, j, 1, 1, diag); relax(i, j, -1, 1, diag)
            } }
            return d
        }
        let landDistance = distances { $0 != 0 }, seaDistance = distances { $0 == 0 }
        var out = [Int16](repeating: 0, count: width * height)
        var smooth = [Double](repeating: 0, count: width * height)
        for k in 0..<out.count {
            let value: Double
            switch cls[k] {
            case 1: value = 100 + 900 * (1 - exp(-landDistance[k] / 14))
            case 2: value = 300 + 2_500 * (1 - exp(-landDistance[k] / 8))
            default: value = -(100 + 4_400 * (1 - exp(-seaDistance[k] / 7)))
            }
            smooth[k] = value
        }
        // Each row averaged over about the same distance east–west as one cell
        // north–south (cells narrow towards the poles), so no wedges meet there
        for j in 0..<height {
            let lat = 90 - (Double(j) + 0.5) * 180 / Double(height)
            let reach = min(width / 2, Int(1 / max(0.001, cos(lat * .pi / 180))) / 2)
            guard reach > 0 else { continue }
            let row = Array(smooth[(j * width)..<((j + 1) * width)])
            var sum = 0.0
            for di in -reach...reach { sum += row[(di + width) % width] }
            for i in 0..<width {
                smooth[j * width + i] = sum / Double(2 * reach + 1)
                sum += row[(i + reach + 1) % width] - row[(i - reach + width) % width]
            }
        }
        // Softened twice by a 3 × 3 box, so the coast is no step
        for _ in 0..<2 {
            var next = smooth
            for j in 0..<height {
                for i in 0..<width {
                    var sum = 0.0
                    for dj in -1...1 {
                        let jj = min(height - 1, max(0, j + dj))
                        for di in -1...1 { sum += smooth[jj * width + ((i + di) % width + width) % width] }
                    }
                    next[j * width + i] = sum / 9
                }
            }
            smooth = next
        }
        for k in 0..<out.count { out[k] = Int16(max(-11_000, min(9_000, smooth[k]))) }
        return Heightmap(width: width, height: height, metres: out)
    }
}

/// The globe's data in the app's resources (`Globe/`, fetched by
/// Scripts/fetch_globe.sh; made by Scripts/build_globe_data.py): the
/// elevation model (`*.sbhm`, NOAA ETOPO 2022 in cells of 1/8°), the night
/// sky (`schnellbild-sky-*.jpg`, NASA SVS's Deep Star Maps 2020, equirectangular
/// in right ascension and declination, 0h in the middle, increasing to the
/// left) and the lights of the night side (`schnellbild-citylights-*.jpg`,
/// NASA's Black Marble 2016, grey, equirectangular, 180° W at the left edge,
/// the North Pole at the top). What is missing is left out: the placeholder
/// relief, no sky, no lights.
public struct GlobeData: @unchecked Sendable {
    public var heightmap: Heightmap?
    public var sky: CGImage?
    public var cityLights: CGImage?

    public init(heightmap: Heightmap? = nil, sky: CGImage? = nil, cityLights: CGImage? = nil) {
        self.heightmap = heightmap
        self.sky = sky
        self.cityLights = cityLights
    }

    /// The files in a folder (the app's `Resources/Globe`, or `Vendor/Globe` for tests).
    public static func load(folder: URL) -> GlobeData {
        var data = GlobeData()
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        func image(_ url: URL?) -> CGImage? {
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        data.heightmap = files.last { $0.pathExtension == "sbhm" }.flatMap { try? Heightmap(url: $0) }
        data.sky = image(files.last { $0.lastPathComponent.hasPrefix("schnellbild-sky-") })
        data.cityLights = image(files.last { $0.lastPathComponent.hasPrefix("schnellbild-citylights-") })
        return data
    }

    public static func bundled(in bundle: Bundle = .main) -> GlobeData {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Globe") else { return GlobeData() }
        return load(folder: folder)
    }

    public static let shared = GlobeData.bundled()
}
