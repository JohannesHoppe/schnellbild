import CoreGraphics
import Foundation

/// A place on Earth in degrees (WGS 84).
public struct Coordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The same place with the longitude in -180 ..< 180.
    public var normalized: Coordinate {
        var lon = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        return Coordinate(latitude: min(90, max(-90, latitude)), longitude: lon - 180)
    }

    /// Great-circle distance in metres (haversine, mean Earth radius).
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_008.8
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = p2 - p1, dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

/// Web Mercator (EPSG:3857) as map tiles use it: the world as a square from
/// (0, 0) at the north-west to (1, 1) at the south-east, latitudes beyond
/// ±85.05° held at the edge. At zoom z the square is 256 · 2^z points wide.
public enum WebMercator {
    public static let maxLatitude = 85.051_128_779_806_59
    public static let tileSize = 256.0

    /// The coordinate's place in the unit square.
    public static func unitPoint(_ c: Coordinate) -> CGPoint {
        let lat = min(maxLatitude, max(-maxLatitude, c.latitude)) * .pi / 180
        let x = (c.longitude + 180) / 360
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2
        return CGPoint(x: x, y: y)
    }

    /// The coordinate at a place in the unit square (x outside 0 ... 1 wraps around).
    public static func coordinate(unit p: CGPoint) -> Coordinate {
        let lon = Double(p.x) * 360 - 180
        let n = Double.pi * (1 - 2 * Double(p.y))
        let lat = atan(sinh(n)) * 180 / .pi
        return Coordinate(latitude: lat, longitude: lon).normalized
    }

    /// The world's width in points at zoom z.
    public static func worldSize(zoom: Double) -> Double { tileSize * pow(2, zoom) }

    /// The coordinate's place in points at zoom z, from the world's north-west corner.
    public static func worldPoint(_ c: Coordinate, zoom: Double) -> CGPoint {
        let u = unitPoint(c), s = worldSize(zoom: zoom)
        return CGPoint(x: u.x * s, y: u.y * s)
    }
}

/// Where the map looks: its centre and zoom (0 shows the world as one tile
/// of 256 points; each step doubles).
public struct MapCamera: Equatable, Sendable, Codable {
    public var center: Coordinate
    public var zoom: Double
    /// The globe's tilt from straight down, degrees (the flat map ignores it)
    public var pitch: Double
    /// The globe's view direction, degrees clockwise from north (the flat map ignores it)
    public var heading: Double

    public init(center: Coordinate, zoom: Double, pitch: Double = 0, heading: Double = 0) {
        self.center = center
        self.zoom = zoom
        self.pitch = pitch
        self.heading = heading
    }

    private enum CodingKeys: String, CodingKey { case center, zoom, pitch, heading }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        center = try c.decode(Coordinate.self, forKey: .center)
        zoom = try c.decode(Double.self, forKey: .zoom)
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        heading = try c.decodeIfPresent(Double.self, forKey: .heading) ?? 0
    }

    public static let world = MapCamera(center: Coordinate(latitude: 20, longitude: 0), zoom: 1)

    /// The camera that shows all the coordinates in a view of this size,
    /// with `padding` points to spare on each side, at most at `maxZoom`.
    public static func fitting(_ coordinates: [Coordinate], in size: CGSize, padding: CGFloat = 40,
                               maxZoom: Double = MapViewport.maxZoom) -> MapCamera? {
        guard let first = coordinates.first, size.width > 0, size.height > 0 else { return nil }
        // Longitudes: the narrowest span that holds them all (it may cross the antimeridian)
        let lons = coordinates.map { $0.normalized.longitude }.sorted()
        var gapStart = lons.last! - 360, widest = 0.0
        for (i, lon) in lons.enumerated() {
            let previous = i == 0 ? lons.last! - 360 : lons[i - 1]
            if lon - previous > widest { widest = lon - previous; gapStart = previous }
        }
        let west = gapStart + widest, east = gapStart + 360
        let units = coordinates.map { WebMercator.unitPoint($0) }
        let minY = units.map(\.y).min()!, maxY = units.map(\.y).max()!
        let spanX = coordinates.count == 1 ? 0 : (east - west) / 360, spanY = Double(maxY - minY)
        let width = max(1, Double(size.width - 2 * padding)), height = max(1, Double(size.height - 2 * padding))
        var zoom = maxZoom
        if spanX > 0 { zoom = min(zoom, log2(width / (spanX * WebMercator.tileSize))) }
        if spanY > 0 { zoom = min(zoom, log2(height / (spanY * WebMercator.tileSize))) }
        let centerUnit = CGPoint(x: (west + (coordinates.count == 1 ? 0 : (east - west) / 2) + 180) / 360,
                                 y: Double(minY + maxY) / 2)
        var center = WebMercator.coordinate(unit: centerUnit)
        if coordinates.count == 1 { center = first.normalized }
        return MapCamera(center: center, zoom: max(0, zoom))
    }
}

/// A camera on a view of a given size: where coordinates land on screen and
/// back. The world repeats to the left and right (the antimeridian has no seam).
public struct MapViewport: Equatable, Sendable {
    public static let maxZoom = 12.0

    public var camera: MapCamera
    public var size: CGSize

    public init(camera: MapCamera, size: CGSize) {
        self.camera = camera
        self.size = size
    }

    /// The smallest zoom: the whole world as wide as the view.
    public static func minZoom(for size: CGSize) -> Double {
        max(0, log2(max(1, Double(size.width)) / WebMercator.tileSize))
    }

    public var worldSize: Double { WebMercator.worldSize(zoom: camera.zoom) }

    /// The camera's centre in world points.
    public var centerWorld: CGPoint { WebMercator.worldPoint(camera.center, zoom: camera.zoom) }

    /// Where the coordinate lands in the view (origin top left), taking the
    /// copy of the world nearest the centre.
    public func point(for coordinate: Coordinate) -> CGPoint {
        let w = WebMercator.worldPoint(coordinate, zoom: camera.zoom), c = centerWorld, s = worldSize
        var dx = Double(w.x - c.x)
        dx -= (dx / s).rounded() * s
        return CGPoint(x: Double(size.width) / 2 + dx, y: Double(size.height) / 2 + Double(w.y - c.y))
    }

    /// The coordinate under a point of the view.
    public func coordinate(at point: CGPoint) -> Coordinate {
        let c = centerWorld, s = worldSize
        let wx = Double(c.x) + Double(point.x) - Double(size.width) / 2
        let wy = Double(c.y) + Double(point.y) - Double(size.height) / 2
        return WebMercator.coordinate(unit: CGPoint(x: wx / s, y: min(1, max(0, wy / s))))
    }

    /// The camera moved by a drag of (dx, dy) points (the map follows the pointer).
    public func panned(by dx: Double, _ dy: Double) -> MapCamera {
        let c = centerWorld, s = worldSize
        var y = Double(c.y) - dy
        // Keep the world's top and bottom edges from moving inside the view when it is taller
        let half = Double(size.height) / 2
        y = s > Double(size.height) ? min(s - half, max(half, y)) : s / 2
        let unit = CGPoint(x: (Double(c.x) - dx) / s, y: y / s)
        return MapCamera(center: WebMercator.coordinate(unit: unit), zoom: camera.zoom, pitch: camera.pitch, heading: camera.heading)
    }

    /// The camera zoomed to `zoom` (held within the limits), keeping the
    /// coordinate under `anchor` where it is.
    public func zoomed(to zoom: Double, keeping anchor: CGPoint) -> MapCamera {
        let z = min(Self.maxZoom, max(Self.minZoom(for: size), zoom))
        let fixed = coordinate(at: anchor)
        var next = MapViewport(camera: MapCamera(center: camera.center, zoom: z, pitch: camera.pitch, heading: camera.heading), size: size)
        let moved = next.point(for: fixed)
        next.camera = next.panned(by: Double(anchor.x - moved.x), Double(anchor.y - moved.y))
        return next.camera
    }

    /// The camera held within the zoom limits and with the world filling the view vertically.
    public func clamped() -> MapCamera {
        var next = self
        next.camera.zoom = min(Self.maxZoom, max(Self.minZoom(for: size), camera.zoom))
        return next.panned(by: 0, 0)
    }

    /// The visible span in the unit square (x may run beyond 0 ... 1).
    public var unitBounds: CGRect {
        let c = centerWorld, s = worldSize
        return CGRect(x: (Double(c.x) - Double(size.width) / 2) / s, y: (Double(c.y) - Double(size.height) / 2) / s,
                      width: Double(size.width) / s, height: Double(size.height) / s)
    }
}
