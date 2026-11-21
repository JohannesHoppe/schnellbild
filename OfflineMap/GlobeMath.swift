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
        let c1: Double = sin(mr) * (1.914_602 - t * (0.004_817 + 0.000_014 * t))
        let c2: Double = sin(2 * mr) * (0.019_993 - 0.000_101 * t)
        let c: Double = c1 + c2 + sin(3 * mr) * 0.000_289
        let trueLongitude = l0 + c
        let omega = radians(125.04 - 1_934.136 * t)
        let lambda = radians(trueLongitude - 0.005_69 - 0.004_78 * sin(omega))
        let seconds: Double = 21.448 - t * (46.815 + t * (0.000_59 - t * 0.001_813))
        let eps0: Double = 23 + (26 + seconds / 60) / 60
        let eps = radians(eps0 + 0.002_56 * cos(omega))
        let declination = degrees(asin(sin(eps) * sin(lambda)))
        let rightAscension = wrap360(degrees(atan2(cos(eps) * sin(lambda), cos(lambda))))
        // The equation of time (Meeus 28.3, with the mean obliquity's correction as NOAA has it)
        let y = pow(tan(eps / 2), 2), l0r = radians(l0)
        let e1: Double = y * sin(2 * l0r) - 2 * e * sin(mr)
        let e2: Double = 4 * e * y * sin(mr) * cos(2 * l0r)
        let e3: Double = 0.5 * y * y * sin(4 * l0r) + 1.25 * e * e * sin(2 * mr)
        let eot: Double = e1 + e2 - e3
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
        let days: Double = jd - 2_451_545
        let angle: Double = 280.460_618_37 + 360.985_647_366_29 * days
        return wrap360(angle + 0.000_387_933 * t * t - t * t * t / 38_710_000)
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
/// Far out and looking straight down the Earth is a sphere seen from space
/// (orthographic, the camera's centre in the middle, `MapCamera.heading`
/// up); between `morphStart` and `flatZoom` each point slides from its
/// place on the sphere to its place on the flat Web Mercator map
/// (`MapViewport`), so at `flatZoom` the two are the same picture and the
/// flat `MapSurfaceView` takes over. The sphere's radius grows with the zoom
/// like the flat map's width (256 · 2^zoom points around the equator) and,
/// while it flattens, by the Mercator stretch of the centre's latitude, so
/// the scale in the middle matches the flat map's.
///
/// Tilted (`MapCamera.pitch`, 0 … `maxPitch`°) the camera is a perspective
/// one: it looks at the centre from the south (heading 0), from a distance
/// that gives the centre the same scale as the sphere's radius, through a
/// lens of `fieldOfView`; the horizon and the curve of the Earth show. The
/// camera's pitch and heading are the tilt and turn chosen; the picture
/// shows them in full up to `fullTiltZoom` (low orbit) and eases them out
/// towards straight down with north up by `straightZoom` (`shownPitch`,
/// `shownHeading`, `tiltShare`), so zooming in tilted goes on into the flat
/// map without a stop, and zooming out brings the tilt chosen back. The
/// first `perspectiveRamp`° of the tilt shown blend the orthographic picture
/// into the perspective one, and the same ramp holds the flattening back: a
/// globe shown tilted doesn't flatten, and as the tilt shown goes to
/// straight down at a flat zoom it flattens.
public struct GlobeProjection: Equatable, Sendable {
    public var camera: MapCamera
    public var size: CGSize
    /// The lens's vertical angle of view (degrees): `fieldOfView` in the app,
    /// wider for a rendered picture (Scripts/render_globe_hero.sh).
    public var lens: Double

    /// The camera's tilt and heading shown as they are at every zoom (a
    /// picture rendered outside the app, Scripts/render_globe_hero.sh), not
    /// eased out between `fullTiltZoom` and `straightZoom`.
    public var freeTilt: Bool

    public init(camera: MapCamera, size: CGSize, lens: Double = GlobeProjection.fieldOfView, freeTilt: Bool = false) {
        self.camera = camera
        self.size = size
        self.lens = lens
        self.freeTilt = freeTilt
    }

    /// The most the camera tilts from straight down (degrees).
    public static let maxPitch = 72.0
    /// The tilted camera's lens: its vertical angle of view (degrees).
    public static let fieldOfView = 40.0
    /// The tilt over which the picture turns from orthographic to perspective (degrees).
    public static let perspectiveRamp = 10.0
    /// Up to this zoom the tilt chosen shows in full: low orbit (zoom 7:
    /// about 600 km above the ground at the largest tilt).
    public static let fullTiltZoom = 7.0
    /// From this zoom on the camera looks straight down with north up,
    /// whatever tilt and heading are chosen. Between `fullTiltZoom` and here
    /// they ease out (smoothstep) over one and a half zoom steps; the
    /// flattening (the last `perspectiveRamp`° of tilt shown) comes at the
    /// end, over about the last half step at a large tilt.
    public static let straightZoom = 8.5

    /// How much of the tilt and heading chosen a camera at `zoom` shows: 1 up
    /// to `fullTiltZoom`, 0 from `straightZoom` on, smoothly in between.
    public static func tiltShare(zoom: Double) -> Double {
        1 - smoothstep((zoom - fullTiltZoom) / (straightZoom - fullTiltZoom))
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

    static func smoothstep(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    /// The share of the tilt and heading chosen the picture shows (`tiltShare`; 1 with `freeTilt`).
    public var tiltShare: Double { freeTilt ? 1 : Self.tiltShare(zoom: camera.zoom) }
    /// The tilt the picture shows (degrees): the camera's, eased out with the zoom.
    public var shownPitch: Double { camera.pitch * tiltShare }
    /// The heading the picture shows (degrees clockwise from north): the camera's, eased towards north the short way.
    public var shownHeading: Double { freeTilt ? camera.heading : Astronomy.wrap180(camera.heading) * tiltShare }

    /// How much the picture is a perspective one: 0 straight down, 1 from `perspectiveRamp`° of tilt shown on.
    public var perspective: Double { Self.smoothstep(shownPitch / Self.perspectiveRamp) }

    /// How flat the map is: 0 a sphere, 1 the flat map (smoothstep between
    /// the zooms; held back by the tilt).
    public var flatness: Double {
        Self.smoothstep((camera.zoom - morphStart) / (flatZoom - morphStart)) * (1 - perspective)
    }

    public var isFlat: Bool { flatness >= 1 - 1e-9 }

    /// The flat map's width in points at this zoom.
    public var worldSize: Double { WebMercator.worldSize(zoom: camera.zoom) }

    /// The sphere's radius in points (the scale in the middle of the view):
    /// the flat map's width / 2π, turning to the Mercator scale of the
    /// centre's latitude (÷ cos latitude) as the map flattens, and with a
    /// tilt chosen as the tilt eases out between `fullTiltZoom` and
    /// `straightZoom`: the globe has the flat map's scale before it
    /// flattens there, so the flattening at the end changes no scale.
    public var radius: Double {
        let t = max(flatness, 1 - tiltShare)
        return worldSize / (2 * .pi) / (1 + (cos(camera.center.latitude * .pi / 180) - 1) * t)
    }

    /// The lens's focal length in points.
    public var focalLength: Double { Double(size.height) / 2 / tan(lens / 2 * .pi / 180) }

    /// The camera in the Earth-fixed frame (Earth radii): where it is, where
    /// it looks (`forward`), the view's right and up, and the target (the
    /// centre on the ground).
    public struct Frame: Equatable, Sendable {
        public var position, forward, right, up, target: SIMD3<Double>
        /// Points per Earth radius at unit distance
        public var focal: Double
        /// The orthographic picture's axes (straight down, turned by the heading)
        public var flatRight, flatUp, flatToward: SIMD3<Double>
    }

    public var frame: Frame {
        let (east, north, up) = GlobeGeometry.basis(camera.center)
        let psi = shownHeading * .pi / 180, theta = shownPitch * .pi / 180
        // Ahead (the heading on the ground) and to the right
        let ahead = north * cos(psi) + east * sin(psi)
        let right = east * cos(psi) - north * sin(psi)
        let f = focalLength
        let distance = f / radius
        let back = up * cos(theta) - ahead * sin(theta)
        return Frame(position: up + distance * back, forward: -back, right: right,
                     up: ahead * cos(theta) + up * sin(theta), target: up, focal: f,
                     flatRight: right, flatUp: ahead, flatToward: up)
    }

    /// The sphere's picture of a point on it (origin in the middle, y up) and
    /// how far it faces the viewer (positive: seen), the orthographic and the
    /// perspective picture blended by the tilt.
    func sphere(_ v: SIMD3<Double>, _ fr: Frame) -> (x: Double, y: Double, facing: Double, inFront: Bool) {
        let s = perspective, r = radius
        let ox = r * simd_dot(v, fr.flatRight), oy = r * simd_dot(v, fr.flatUp), of = simd_dot(v, fr.flatToward)
        guard s > 0 else { return (ox, oy, of, true) }
        let q = v - fr.position
        let z = simd_dot(q, fr.forward)
        let px = fr.focal * simd_dot(q, fr.right) / max(z, 1e-9), py = fr.focal * simd_dot(q, fr.up) / max(z, 1e-9)
        // Seen: on the side of the horizon facing the camera
        let distance = simd_length(fr.position)
        let pf = (simd_dot(v, fr.position) - 1) / max(1e-9, distance - 1)
        return (ox + (px - ox) * s, oy + (py - oy) * s, of + (pf - of) * s, z > 1e-6)
    }

    /// Where a coordinate lands (origin top left) and its depth: positive
    /// facing the viewer, below 0 behind the Earth (blended towards 1 as the
    /// map flattens, as the renderer does).
    public func project(_ c: Coordinate) -> (point: CGPoint, depth: Double) {
        let t = flatness, w = worldSize
        let v = GlobeGeometry.unitVector(c)
        let sp = sphere(v, frame)
        let sx = sp.x, sy = -sp.y
        let dLon = Astronomy.wrap180(c.longitude - camera.center.longitude)
        let fx = dLon / 360 * w
        let fy = (GlobeGeometry.mercatorY(c.latitude) - GlobeGeometry.mercatorY(camera.center.latitude)) * w
        let x = sx + (fx - sx) * t, y = sy + (fy - sy) * t
        let depth = sp.inFront ? sp.facing * (1 - t) + t : -1
        return (CGPoint(x: Double(size.width) / 2 + x, y: Double(size.height) / 2 + y), depth)
    }

    /// Where a coordinate lands in the view (origin top left).
    public func point(for c: Coordinate) -> CGPoint { project(c).point }

    /// Whether a coordinate faces the viewer (not hidden behind the Earth).
    public func isVisible(_ c: Coordinate) -> Bool { project(c).depth > 0 }

    /// The coordinate under a point of the view, nil off the Earth.
    public func coordinate(at p: CGPoint) -> Coordinate? {
        let t = flatness, s = perspective
        if t >= 1 - 1e-9 { return MapViewport(camera: camera, size: size).coordinate(at: p) }
        let fr = frame
        let x = Double(p.x) - Double(size.width) / 2, y = -(Double(p.y) - Double(size.height) / 2)
        var guess: Coordinate?
        if s >= 1 - 1e-9 {
            // The ray from the camera through the point
            let ray = simd_normalize(fr.focal * fr.forward + x * fr.right + y * fr.up)
            let b = simd_dot(fr.position, ray), cc = simd_length_squared(fr.position) - 1
            let disc = b * b - cc
            guard disc >= 0 else { return nil }
            let hit = fr.position + (-b - sqrt(disc)) * ray
            return GlobeGeometry.coordinate(hit)
        }
        let ox = x / radius, oy = y / radius
        if ox * ox + oy * oy <= 1 {
            guess = GlobeGeometry.coordinate(ox * fr.flatRight + oy * fr.flatUp + sqrt(max(0, 1 - ox * ox - oy * oy)) * fr.flatToward)
            if t <= 1e-9 && s <= 1e-9 { return guess }
        } else if t <= 1e-9 && s <= 1e-9 {
            return nil
        } else {
            guess = GlobeGeometry.coordinate(simd_normalize(ox * fr.flatRight + oy * fr.flatUp))
        }
        // Flattening or tilting: solve point(for: c) == p by Newton's method on (latitude, longitude)
        guard let start = guess, let solved = Self.solve(start: start, target: p, { self.project($0).point }) else { return nil }
        return project(solved).depth > 0 ? solved : nil
    }

    /// The camera turned by a drag of (dx, dy) points: the Earth follows the pointer.
    public func rotated(by dx: Double, _ dy: Double) -> MapCamera {
        if isFlat { return MapViewport(camera: camera, size: size).panned(by: dx, dy) }
        let t = flatness, w = worldSize, r = radius
        let cosLat = max(0.05, cos(camera.center.latitude * .pi / 180))
        // The drag in the view's directions (right, ahead), ahead foreshortened by the tilt
        let psi = shownHeading * .pi / 180
        let alongRight = -dx, alongAhead = dy / max(0.3, cos(shownPitch * .pi / 180 * perspective))
        let toEast = alongRight * cos(psi) + alongAhead * sin(psi)
        let toNorth = -alongRight * sin(psi) + alongAhead * cos(psi)
        // Points per radian at the centre, east and north
        let perLon = r * cosLat + (w / (2 * .pi) - r * cosLat) * t
        let perLat = r + (w / (2 * .pi * cosLat) - r) * t
        var next = camera
        next.center = Coordinate(latitude: min(85, max(-85, camera.center.latitude + toNorth / perLat * 180 / .pi)),
                                 longitude: Astronomy.wrap180(camera.center.longitude + toEast / perLon * 180 / .pi))
        return next
    }

    /// The camera at `zoom` (held between the globe's smallest zoom and the
    /// flat map's largest, tilted or not), with the coordinate under
    /// `anchor` kept there; the tilt and heading chosen stay (what of them
    /// shows follows the zoom).
    public func zoomed(to zoom: Double, keeping anchor: CGPoint) -> MapCamera {
        var held = camera
        held.zoom = zoom
        held = Self.held(held, size: size)
        let z = held.zoom
        var next = GlobeProjection(camera: held, size: size, lens: lens, freeTilt: freeTilt)
        guard let fixed = coordinate(at: anchor) else { return next.camera }
        if isFlat && next.isFlat {
            var flat = MapViewport(camera: camera, size: size).zoomed(to: z, keeping: anchor)
            flat.pitch = camera.pitch
            flat.heading = camera.heading
            return flat
        }
        // The centre that brings the fixed coordinate back under the anchor:
        // exact on the orthographic sphere, else found from there
        let size = size
        let sphereCenter = next.perspective <= 0 ? next.sphereCenter(placing: fixed, at: anchor) : nil
        if next.flatness <= 0, next.perspective <= 0, let center = sphereCenter {
            next.camera.center = Coordinate(latitude: min(85, max(-85, center.latitude)), longitude: Astronomy.wrap180(center.longitude))
        } else if let center = Self.solve(start: sphereCenter ?? camera.center, target: anchor, { c in
            var moved = held
            moved.center = c
            return GlobeProjection(camera: moved, size: size, lens: lens, freeTilt: freeTilt).project(fixed).point
        }) {
            next.camera.center = Coordinate(latitude: min(85, max(-85, center.latitude)), longitude: Astronomy.wrap180(center.longitude))
        }
        if next.isFlat {
            var flat = MapViewport(camera: next.camera, size: size).panned(by: 0, 0)
            flat.pitch = next.camera.pitch
            flat.heading = next.camera.heading
            next.camera = flat
        }
        return next.camera
    }

    /// The camera within the globe's limits: the zoom between the globe's
    /// smallest and the flat map's largest (tilted too: the tilt shown eases
    /// out on the way, `tiltShare`), the tilt within 0 … `maxPitch`, the
    /// heading in -180 ..< 180.
    public static func held(_ c: MapCamera, size: CGSize) -> MapCamera {
        var next = c
        next.pitch = min(maxPitch, max(0, c.pitch))
        next.heading = Astronomy.wrap180(c.heading)
        next.zoom = min(MapViewport.maxZoom, max(minZoom(for: size), c.zoom))
        return next
    }

    /// Below this zoom the camera shows the globe, from it on the flat map:
    /// `flatZoom` straight down, `straightZoom` with a tilt chosen (the
    /// flat zoom when that is larger).
    public var globeZoom: Double {
        camera.pitch > 0 && !freeTilt ? max(flatZoom, Self.straightZoom) : flatZoom
    }

    /// The camera (straight down, north up) at `zoom` that shows `q` at the
    /// view's point `p`, in the projection that zoom has: on the sphere, while
    /// flattening, or on the flat map. Where no centre does it (the point off
    /// the sphere, or a latitude the sphere's rim doesn't reach at that point
    /// of the view), the flat map's.
    public static func camera(placing q: Coordinate, at p: CGPoint, zoom: Double, size: CGSize) -> MapCamera {
        let middle = CGPoint(x: Double(size.width) / 2, y: Double(size.height) / 2)
        let centred = MapViewport(camera: MapCamera(center: q, zoom: zoom), size: size)
        let flat = MapCamera(center: centred.coordinate(at: CGPoint(x: 2 * middle.x - p.x, y: 2 * middle.y - p.y)), zoom: zoom)
        let projection = GlobeProjection(camera: flat, size: size)
        if projection.isFlat { return flat }
        let sphere = projection.sphereCenter(placing: q, at: p)
        if projection.flatness <= 0, let sphere { return MapCamera(center: sphere, zoom: zoom) }
        let solved = solve(start: sphere ?? flat.center, target: p) { c in
            GlobeProjection(camera: MapCamera(center: c, zoom: zoom), size: size).project(q).point
        }
        guard let solved else { return flat }
        return MapCamera(center: Coordinate(latitude: min(85, max(-85, solved.latitude)), longitude: Astronomy.wrap180(solved.longitude)),
                         zoom: zoom)
    }

    /// The centre for which the orthographic sphere (this radius and
    /// heading) shows `q` at the view's point `p`; nil when `p` lies off the
    /// sphere or no centre does it. Of the two latitudes that do, the one
    /// nearer the camera's.
    func sphereCenter(placing q: Coordinate, at p: CGPoint) -> Coordinate? {
        let r = radius, psi = shownHeading * .pi / 180
        let sx = (Double(p.x) - Double(size.width) / 2) / r, sy = -(Double(p.y) - Double(size.height) / 2) / r
        // The view's axes are east and north turned by the heading
        let x = sx * cos(psi) + sy * sin(psi), y = -sx * sin(psi) + sy * cos(psi)
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
    static func solve(start: Coordinate, target: CGPoint, _ f: (Coordinate) -> CGPoint) -> Coordinate? {
        var c = start
        for _ in 0..<32 {
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
