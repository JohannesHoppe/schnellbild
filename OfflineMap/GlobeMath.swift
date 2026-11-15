import CoreGraphics
import Foundation
import simd

/// Where the Sun and the stars stand for a moment, computed offline: the
/// subsolar point after NOAA's solar calculator (Jean Meeus, Astronomical
/// Algorithms, ch. 25 and 28, the low-accuracy method: about 0.01°), the
/// Greenwich mean sidereal time (Meeus 12.4) and the precession of the
/// equinox from J2000 (Meeus 21.2–21.4, IAU 1976). `GlobeMathTests` check
/// them against Meeus' worked examples and the solstices and equinoxes.
public enum Astronomy {
    /// The Julian day of a moment (UTC; the difference to Terrestrial Time,
    /// about a minute, moves the Sun by less than 0.001°).
    public static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// Julian centuries since J2000.0.
    static func centuries(_ jd: Double) -> Double { (jd - 2_451_545) / 36_525 }

    static func degrees(_ r: Double) -> Double { r * 180 / .pi }
    static func radians(_ d: Double) -> Double { d * .pi / 180 }

    /// An angle in 0 ..< 360.
    static func wrap360(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// An angle in -180 ..< 180.
    static func wrap180(_ d: Double) -> Double { wrap360(d + 180) - 180 }

    /// The Sun's apparent place: declination and right ascension in degrees,
    /// the equation of time in minutes (apparent minus mean solar time).
    public struct Sun: Equatable, Sendable {
        public var declination: Double
        public var rightAscension: Double
        public var equationOfTime: Double
    }

    public static func sun(at date: Date) -> Sun { sun(julianDay: julianDay(date)) }

    public static func sun(julianDay jd: Double) -> Sun {
        let t = centuries(jd)
        let l0 = wrap360(280.466_46 + t * (36_000.769_83 + 0.000_303_2 * t))
        let m = 357.529_11 + t * (35_999.050_29 - 0.000_153_7 * t)
        let e = 0.016_708_634 - t * (0.000_042_037 + 0.000_000_126_7 * t)
        let mr = radians(m)
        let c = sin(mr) * (1.914_602 - t * (0.004_817 + 0.000_014 * t))
            + sin(2 * mr) * (0.019_993 - 0.000_101 * t) + sin(3 * mr) * 0.000_289
        let trueLongitude = l0 + c
        let omega = radians(125.04 - 1_934.136 * t)
        let lambda = radians(trueLongitude - 0.005_69 - 0.004_78 * sin(omega))
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.000_59 - t * 0.001_813))) / 60) / 60
        let eps = radians(eps0 + 0.002_56 * cos(omega))
        let declination = degrees(asin(sin(eps) * sin(lambda)))
        let rightAscension = wrap360(degrees(atan2(cos(eps) * sin(lambda), cos(lambda))))
        // The equation of time (Meeus 28.3, with the mean obliquity's correction as NOAA has it)
        let y = pow(tan(eps / 2), 2), l0r = radians(l0)
        let eot = y * sin(2 * l0r) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l0r)
            - 0.5 * y * y * sin(4 * l0r) - 1.25 * e * e * sin(2 * mr)
        return Sun(declination: declination, rightAscension: rightAscension, equationOfTime: 4 * degrees(eot))
    }

    /// The point on Earth where the Sun stands in the zenith.
    public static func subsolarPoint(at date: Date) -> Coordinate {
        let jd = julianDay(date)
        let sun = sun(julianDay: jd)
        // Hours since midnight UTC; the Sun crosses the meridian at 12 h minus the equation of time
        let hours = ((jd + 0.5) - (jd + 0.5).rounded(.down)) * 24
        let longitude = wrap180(-15 * (hours - 12 + sun.equationOfTime / 60))
        return Coordinate(latitude: sun.declination, longitude: longitude)
    }

    /// Greenwich mean sidereal time in degrees (Meeus 12.4).
    public static func siderealTime(julianDay jd: Double) -> Double {
        let t = centuries(jd)
        return wrap360(280.460_618_37 + 360.985_647_366_29 * (jd - 2_451_545) + 0.000_387_933 * t * t - t * t * t / 38_710_000)
    }

    public static func siderealTime(at date: Date) -> Double { siderealTime(julianDay: julianDay(date)) }

    /// The rotation that takes equatorial coordinates of J2000 to those of
    /// the mean equinox of the date (Meeus 21.2–21.4).
    public static func precession(julianDay jd: Double) -> simd_double3x3 {
        let t = centuries(jd)
        let arcsec = 1.0 / 3600
        let zeta = radians((2306.2181 * t + 0.301_88 * t * t + 0.017_998 * t * t * t) * arcsec)
        let z = radians((2306.2181 * t + 1.094_68 * t * t + 0.018_203 * t * t * t) * arcsec)
        let theta = radians((2004.3109 * t - 0.426_65 * t * t - 0.041_833 * t * t * t) * arcsec)
        return rotationZ(-z) * rotationY(theta) * rotationZ(-zeta)
    }

    /// Turning the axes about z by `a` (a vector's coordinates in the turned frame).
    static func rotationZ(_ a: Double) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(cos(a), sin(a), 0), SIMD3(-sin(a), cos(a), 0), SIMD3(0, 0, 1)])
    }

    /// Turning the axes about y by `a`.
    static func rotationY(_ a: Double) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(cos(a), 0, -sin(a)), SIMD3(0, 1, 0), SIMD3(sin(a), 0, cos(a))])
    }

    /// Right ascension and declination (degrees, J2000) as of the date's equinox.
    public static func precessed(rightAscension ra: Double, declination dec: Double, julianDay jd: Double) -> (ra: Double, dec: Double) {
        let v = precession(julianDay: jd) * GlobeGeometry.unitVector(latitude: dec, longitude: ra)
        return (wrap360(degrees(atan2(v.y, v.x))), degrees(asin(max(-1, min(1, v.z)))))
    }

    /// The rotation from J2000 equatorial directions to the Earth-fixed frame
    /// of the moment (x towards 0° N 0° E, z towards the North Pole): the
    /// precession to the date, then the Earth turned by the sidereal time.
    /// A star at right ascension α and declination δ then stands in the
    /// zenith at latitude δ, longitude α − GMST.
    public static func celestialToEarth(at date: Date) -> simd_double3x3 {
        let jd = julianDay(date)
        return rotationZ(radians(siderealTime(julianDay: jd))) * precession(julianDay: jd)
    }
}

/// Unit vectors in the Earth-fixed frame: x towards 0° N 0° E, y towards
/// 0° N 90° E, z towards the North Pole.
public enum GlobeGeometry {
    public static func unitVector(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let p = latitude * .pi / 180, l = longitude * .pi / 180
        return SIMD3(cos(p) * cos(l), cos(p) * sin(l), sin(p))
    }

    public static func unitVector(_ c: Coordinate) -> SIMD3<Double> { unitVector(latitude: c.latitude, longitude: c.longitude) }

    public static func coordinate(_ v: SIMD3<Double>) -> Coordinate {
        let n = simd_normalize(v)
        return Coordinate(latitude: asin(max(-1, min(1, n.z))) * 180 / .pi, longitude: atan2(n.y, n.x) * 180 / .pi)
    }

    /// The view's axes for a camera above `center`: east (screen right),
    /// north (screen up) and up (towards the viewer).
    public static func basis(_ center: Coordinate) -> (east: SIMD3<Double>, north: SIMD3<Double>, up: SIMD3<Double>) {
        let p = center.latitude * .pi / 180, l = center.longitude * .pi / 180
        return (SIMD3(-sin(l), cos(l), 0), SIMD3(-sin(p) * cos(l), -sin(p) * sin(l), cos(p)), SIMD3(cos(p) * cos(l), cos(p) * sin(l), sin(p)))
    }

    /// Web Mercator's y in the unit square (0 north, 1 south), held at ±85.05°.
    public static func mercatorY(_ latitude: Double) -> Double { Double(WebMercator.unitPoint(Coordinate(latitude: latitude, longitude: 0)).y) }
}

/// The globe on a view: where coordinates land and back, for one camera.
/// Far out the Earth is a sphere seen from space (orthographic, north up,
/// the camera's centre in the middle); between `morphStart` and `flatZoom`
/// each point slides from its place on the sphere to its place on the flat
/// Web Mercator map (`MapViewport`), so at `flatZoom` the two are the same
/// picture and the flat `MapSurfaceView` takes over. The sphere's radius
/// grows with the zoom like the flat map's width (256 · 2^zoom points
/// around the equator) and, while it flattens, by the Mercator stretch of the
/// centre's latitude, so the scale in the middle matches the flat map's.
public struct GlobeProjection: Equatable, Sendable {
    public var camera: MapCamera
    public var size: CGSize

    public init(camera: MapCamera, size: CGSize) {
        self.camera = camera
        self.size = size
    }

    /// From this zoom on the map is flat (the flat map view takes over);
    /// at least 1.5 steps above the flat map's smallest zoom for the view.
    public static func flatZoom(for size: CGSize) -> Double { max(5, MapViewport.minZoom(for: size) + 1.5) }
    /// Where the sphere starts to flatten.
    public static func morphStart(for size: CGSize) -> Double { flatZoom(for: size) - 1.5 }
    /// The smallest zoom: the Earth a third as wide as the view's shorter side.
    public static func minZoom(for size: CGSize) -> Double {
        log2(max(60, Double(min(size.width, size.height))) / 3 * .pi / WebMercator.tileSize)
    }
    /// A zoom where the Earth fills most of the view, with space around it.
    public static func overviewZoom(for size: CGSize) -> Double {
        log2(max(60, Double(min(size.width, size.height))) * 0.8 * .pi / WebMercator.tileSize)
    }

    public var flatZoom: Double { Self.flatZoom(for: size) }
    public var morphStart: Double { Self.morphStart(for: size) }

    /// How flat the map is: 0 a sphere, 1 the flat map (smoothstep between the zooms).
    public var flatness: Double {
        let x = min(1, max(0, (camera.zoom - morphStart) / (flatZoom - morphStart)))
        return x * x * (3 - 2 * x)
    }

    public var isFlat: Bool { camera.zoom >= flatZoom - 1e-9 }

    /// The flat map's width in points at this zoom.
    public var worldSize: Double { WebMercator.worldSize(zoom: camera.zoom) }

    /// The sphere's radius in points.
    public var radius: Double {
        let t = flatness
        return worldSize / (2 * .pi) / (1 + (cos(camera.center.latitude * .pi / 180) - 1) * t)
    }

    /// Where a coordinate lands (origin top left) and its depth: 1 facing the
    /// viewer, 0 on the rim, below 0 behind the Earth (blended towards 1 as
    /// the map flattens, as the renderer does).
    public func project(_ c: Coordinate) -> (point: CGPoint, depth: Double) {
        let t = flatness, r = radius, w = worldSize
        let (east, north, up) = GlobeGeometry.basis(camera.center)
        let v = GlobeGeometry.unitVector(c)
        let sx = r * simd_dot(v, east), sy = -r * simd_dot(v, north)
        let dLon = Astronomy.wrap180(c.longitude - camera.center.longitude)
        let fx = dLon / 360 * w
        let fy = (GlobeGeometry.mercatorY(c.latitude) - GlobeGeometry.mercatorY(camera.center.latitude)) * w
        let x = sx + (fx - sx) * t, y = sy + (fy - sy) * t
        let depth = simd_dot(v, up) * (1 - t) + t
        return (CGPoint(x: Double(size.width) / 2 + x, y: Double(size.height) / 2 + y), depth)
    }

    /// Where a coordinate lands in the view (origin top left).
    public func point(for c: Coordinate) -> CGPoint { project(c).point }

    /// Whether a coordinate faces the viewer (not hidden behind the Earth).
    public func isVisible(_ c: Coordinate) -> Bool { project(c).depth > 0 }

    /// The coordinate under a point of the view, nil off the Earth.
    public func coordinate(at p: CGPoint) -> Coordinate? {
        let t = flatness
        if t >= 1 - 1e-9 { return MapViewport(camera: camera, size: size).coordinate(at: p) }
        let r = radius
        let x = (Double(p.x) - Double(size.width) / 2) / r, y = -(Double(p.y) - Double(size.height) / 2) / r
        let (east, north, up) = GlobeGeometry.basis(camera.center)
        var guess: Coordinate
        if x * x + y * y <= 1 {
            guess = GlobeGeometry.coordinate(x * east + y * north + sqrt(max(0, 1 - x * x - y * y)) * up)
            if t <= 1e-9 { return guess }
        } else if t <= 1e-9 {
            return nil
        } else {
            let rim = simd_normalize(x * east + y * north)
            guess = GlobeGeometry.coordinate(rim)
        }
        // Flattening: solve point(for: c) == p by Newton's method on (latitude, longitude)
        guard let solved = solve(start: guess, target: p, { self.project($0).point }) else { return nil }
        return project(solved).depth > 0 ? solved : nil
    }

    /// The camera turned by a drag of (dx, dy) points: the Earth follows the pointer.
    public func rotated(by dx: Double, _ dy: Double) -> MapCamera {
        if isFlat { return MapViewport(camera: camera, size: size).panned(by: dx, dy) }
        let t = flatness, w = worldSize, r = radius
        let cosLat = max(0.05, cos(camera.center.latitude * .pi / 180))
        // Points per radian at the centre, east and north
        let perLon = r * cosLat + (w / (2 * .pi) - r * cosLat) * t
        let perLat = r + (w / (2 * .pi * cosLat) - r) * t
        let lat = min(85, max(-85, camera.center.latitude + dy / perLat * 180 / .pi))
        let lon = Astronomy.wrap180(camera.center.longitude - dx / perLon * 180 / .pi)
        return MapCamera(center: Coordinate(latitude: lat, longitude: lon), zoom: camera.zoom)
    }

    /// The camera at `zoom` (held between the globe's smallest zoom and the
    /// flat map's largest), with the coordinate under `anchor` kept there.
    public func zoomed(to zoom: Double, keeping anchor: CGPoint) -> MapCamera {
        let z = min(MapViewport.maxZoom, max(Self.minZoom(for: size), zoom))
        var next = GlobeProjection(camera: MapCamera(center: camera.center, zoom: z), size: size)
        guard let fixed = coordinate(at: anchor) else { return next.camera }
        if isFlat && next.isFlat {
            return MapViewport(camera: camera, size: size).zoomed(to: z, keeping: anchor)
        }
        // The centre that brings the fixed coordinate back under the anchor:
        // exact on the sphere, else found from there
        let size = size
        let sphereCenter = next.sphereCenter(placing: fixed, at: anchor)
        if next.flatness <= 0, let center = sphereCenter {
            next.camera.center = Coordinate(latitude: min(85, max(-85, center.latitude)), longitude: Astronomy.wrap180(center.longitude))
        } else if let center = solve(start: sphereCenter ?? camera.center, target: anchor, { c in
            GlobeProjection(camera: MapCamera(center: c, zoom: z), size: size).project(fixed).point
        }) {
            next.camera.center = Coordinate(latitude: min(85, max(-85, center.latitude)), longitude: Astronomy.wrap180(center.longitude))
        }
        if next.isFlat { next.camera = MapViewport(camera: next.camera, size: size).panned(by: 0, 0) }
        return next.camera
    }

    /// The centre for which the sphere (orthographic, north up, this radius)
    /// shows `q` at the view's point `p`; nil when `p` lies off the sphere or
    /// no centre does it. Of the two latitudes that do, the one nearer the
    /// camera's.
    func sphereCenter(placing q: Coordinate, at p: CGPoint) -> Coordinate? {
        let r = radius
        let x = (Double(p.x) - Double(size.width) / 2) / r, y = -(Double(p.y) - Double(size.height) / 2) / r
        guard x * x + y * y < 1 else { return nil }
        let z = sqrt(1 - x * x - y * y)
        // q.z = y cos φ + z sin φ = ρ cos(φ − α)
        let rho = hypot(y, z), alpha = atan2(z, y)
        let s = sin(q.latitude * .pi / 180) / rho
        guard abs(s) <= 1 else { return nil }
        let candidates = [alpha + acos(s), alpha - acos(s)].map { atan2(sin($0), cos($0)) }.filter { abs($0) <= .pi / 2 }
        guard let phi = candidates.min(by: { abs($0 * 180 / .pi - camera.center.latitude) < abs($1 * 180 / .pi - camera.center.latitude) })
        else { return nil }
        let lambda = q.longitude * .pi / 180 - atan2(x, -y * sin(phi) + z * cos(phi))
        return Coordinate(latitude: phi * 180 / .pi, longitude: Astronomy.wrap180(lambda * 180 / .pi))
    }

    /// Newton's method for the coordinate `c` with `f(c) == target`, the
    /// Jacobian by finite differences; nil when it doesn't converge.
    private func solve(start: Coordinate, target: CGPoint, _ f: (Coordinate) -> CGPoint) -> Coordinate? {
        var c = start
        for _ in 0..<24 {
            let p = f(c)
            let ex = Double(target.x - p.x), ey = Double(target.y - p.y)
            if ex * ex + ey * ey < 1e-6 { return c }
            let h = 1e-4
            let pLat = f(Coordinate(latitude: c.latitude + h, longitude: c.longitude))
            let pLon = f(Coordinate(latitude: c.latitude, longitude: c.longitude + h))
            let a = Double(pLat.x - p.x) / h, b = Double(pLon.x - p.x) / h
            let cc = Double(pLat.y - p.y) / h, d = Double(pLon.y - p.y) / h
            let det = a * d - b * cc
            guard abs(det) > 1e-12 else { return nil }
            var dLat = (d * ex - b * ey) / det, dLon = (-cc * ex + a * ey) / det
            // Steps of at most 20° keep it on the near side
            let step = max(abs(dLat), abs(dLon))
            if step > 20 { dLat *= 20 / step; dLon *= 20 / step }
            c = Coordinate(latitude: min(89.999, max(-89.999, c.latitude + dLat)), longitude: c.longitude + dLon)
        }
        let p = f(c)
        let e = hypot(Double(target.x - p.x), Double(target.y - p.y))
        return e < 0.01 ? c : nil
    }
}
