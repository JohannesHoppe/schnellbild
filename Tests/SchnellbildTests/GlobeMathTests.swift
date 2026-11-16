import CoreGraphics
import Foundation
import simd
import XCTest
@testable import OfflineMap

/// The globe's arithmetic without a GPU: the Sun's place, the sidereal time
/// and the precession against Jean Meeus' worked examples (Astronomical
/// Algorithms, 2nd ed.) and the 2024 solstice and equinox; the subsolar point
/// against USNO's approximate method; the projection from globe to flat map
/// (round trips, the far side, zooming about the pointer, the hand-over to
/// `MapViewport`); the heightmap's file format and the bundled globe data.
final class GlobeMathTests: XCTestCase {

    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: Sun, sidereal time, precession

    func testTheSunAsMeeusExample25a() {
        // 1992 October 13.0 TD: apparent δ −7°47′01″ = −7.78507°, α 13h13m31.4s = 198.38083°
        let sun = Astronomy.sun(julianDay: 2_448_908.5)
        XCTAssertEqual(sun.declination, -7.785_07, accuracy: 0.01)
        XCTAssertEqual(sun.rightAscension, 198.380_83, accuracy: 0.01)
        // Meeus example 28.b, the same day: the equation of time 13m42.6s
        XCTAssertEqual(sun.equationOfTime, 13.71, accuracy: 0.05)
    }

    func testSolsticeAndEquinox() {
        // June solstice 2024-06-20 20:51 UTC: the Sun at its northernmost (obliquity 23.4362°)
        XCTAssertEqual(Astronomy.sun(at: date("2024-06-20T20:51:00Z")).declination, 23.436, accuracy: 0.01)
        // March equinox 2024-03-20 03:06 UTC
        XCTAssertEqual(Astronomy.sun(at: date("2024-03-20T03:06:00Z")).declination, 0, accuracy: 0.01)
        // December solstice 2024-12-21 09:20 UTC
        XCTAssertEqual(Astronomy.sun(at: date("2024-12-21T09:20:00Z")).declination, -23.436, accuracy: 0.01)
    }

    func testTheSubsolarPointAgreesWithUSNOsMethod() {
        // Computed with USNO's approximate solar coordinates and GMST (aa.usno.navy.mil/faq/sun_approx)
        let expected: [(String, Double, Double)] = [
            ("2024-06-20T20:51:00Z", 23.436, -132.304),
            ("2024-03-20T03:06:00Z", 0.001, 135.356),
            ("2026-11-15T12:00:00Z", -18.552, -3.856),
            ("2025-02-11T06:30:00Z", -13.920, 86.049),
        ]
        for (iso, lat, lon) in expected {
            let p = Astronomy.subsolarPoint(at: date(iso))
            XCTAssertEqual(p.latitude, lat, accuracy: 0.02, iso)
            XCTAssertEqual(Astronomy.wrap180(p.longitude - lon), 0, accuracy: 0.05, iso)
        }
        // The same point from right ascension and sidereal time
        let d = date("2026-07-01T17:45:00Z")
        let ra = Astronomy.sun(at: d).rightAscension
        XCTAssertEqual(Astronomy.wrap180(Astronomy.subsolarPoint(at: d).longitude - (ra - Astronomy.siderealTime(at: d))), 0, accuracy: 0.02)
    }

    func testSiderealTimeAsMeeusExamples12() {
        // 1987 April 10, 0h UT: 13h10m46.3668s
        XCTAssertEqual(Astronomy.siderealTime(julianDay: 2_446_895.5), 197.693_195, accuracy: 1e-4)
        // 1987 April 10, 19h21m00s UT: 8h34m57.0896s
        XCTAssertEqual(Astronomy.siderealTime(julianDay: 2_446_896.306_25), 128.737_873_4, accuracy: 1e-4)
    }

    func testPrecessionAsMeeusExample21b() {
        // θ Persei, proper motion applied: α0 41.054063°, δ0 49.227750° (J2000) to 2028 November 13.19 TD
        let p = Astronomy.precessed(rightAscension: 41.054_063, declination: 49.227_750, julianDay: 2_462_088.69)
        XCTAssertEqual(p.ra, 41.547_214, accuracy: 2e-4)
        XCTAssertEqual(p.dec, 49.348_483, accuracy: 2e-4)
    }

    func testAStarStandsInTheZenithAtRightAscensionMinusSiderealTime() {
        let d = date("2026-03-01T22:10:00Z")
        let m = Astronomy.celestialToEarth(at: d)
        // A star on the celestial equator at the equinox of the date (precession undone)
        let jd = Astronomy.julianDay(d)
        let star = m * simd_transpose(Astronomy.precession(julianDay: jd)) * GlobeGeometry.unitVector(latitude: 0, longitude: 100)
        let zenith = GlobeGeometry.coordinate(star)
        XCTAssertEqual(zenith.latitude, 0, accuracy: 1e-9)
        XCTAssertEqual(Astronomy.wrap180(zenith.longitude - (100 - Astronomy.siderealTime(at: d))), 0, accuracy: 1e-9)
    }

    // MARK: Projection

    let size = CGSize(width: 960, height: 640)

    func testTheGlobeRoundTripsAndHidesItsFarSide() {
        let p = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 48, longitude: 11), zoom: 2), size: size)
        XCTAssertEqual(p.flatness, 0)
        XCTAssertEqual(p.radius, WebMercator.worldSize(zoom: 2) / (2 * .pi), accuracy: 1e-9)
        // The centre in the middle, a point 90° away on the rim
        XCTAssertEqual(p.point(for: Coordinate(latitude: 48, longitude: 11)).x, 480, accuracy: 1e-9)
        XCTAssertEqual(p.point(for: Coordinate(latitude: 48, longitude: 11)).y, 320, accuracy: 1e-9)
        let north = p.point(for: Coordinate(latitude: 60, longitude: 11))
        XCTAssertLessThan(north.y, 320, "north is up")
        let east = p.point(for: Coordinate(latitude: 48, longitude: 30))
        XCTAssertGreaterThan(east.x, 480, "east is right")
        for c in [Coordinate(latitude: 10, longitude: -20), Coordinate(latitude: 70, longitude: 60), Coordinate(latitude: 40, longitude: 12)] {
            XCTAssertTrue(p.isVisible(c))
            let back = try! XCTUnwrap(p.coordinate(at: p.point(for: c)))
            XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-6)
            XCTAssertEqual(Astronomy.wrap180(back.longitude - c.longitude), 0, accuracy: 1e-6)
        }
        XCTAssertFalse(p.isVisible(Coordinate(latitude: -48, longitude: -169)), "the antipode")
        XCTAssertFalse(p.isVisible(Coordinate(latitude: -30, longitude: 150)))
        XCTAssertNil(p.coordinate(at: CGPoint(x: 2, y: 2)), "space")
    }

    func testWhileFlatteningPointsRoundTrip() {
        let flatZoom = GlobeProjection.flatZoom(for: size), start = GlobeProjection.morphStart(for: size)
        let p = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: (flatZoom + start) / 2), size: size)
        XCTAssertEqual(p.flatness, 0.5, accuracy: 1e-9)
        for c in [Coordinate(latitude: 47, longitude: 10), Coordinate(latitude: 40, longitude: -2), Coordinate(latitude: 55, longitude: 20)] {
            let point = p.point(for: c)
            let back = try! XCTUnwrap(p.coordinate(at: point), "\(c)")
            XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-5)
            XCTAssertEqual(Astronomy.wrap180(back.longitude - c.longitude), 0, accuracy: 1e-5)
        }
    }

    func testAtTheFlatZoomTheGlobeIsTheFlatMap() {
        let camera = MapCamera(center: Coordinate(latitude: 62.1, longitude: 7.2), zoom: GlobeProjection.flatZoom(for: size))
        let globe = GlobeProjection(camera: camera, size: size), flat = MapViewport(camera: camera, size: size)
        XCTAssertTrue(globe.isFlat)
        XCTAssertEqual(globe.flatness, 1)
        for c in [Coordinate(latitude: 60, longitude: 5), Coordinate(latitude: 64, longitude: 12), Coordinate(latitude: 62.1, longitude: 7.2)] {
            XCTAssertEqual(globe.point(for: c).x, flat.point(for: c).x, accuracy: 1e-6)
            XCTAssertEqual(globe.point(for: c).y, flat.point(for: c).y, accuracy: 1e-6)
        }
        // Just before it, the scale in the middle is the flat map's (the sphere's radius grows by the Mercator stretch)
        var near = camera
        near.zoom -= 0.001
        let a = GlobeProjection(camera: near, size: size).point(for: Coordinate(latitude: 62.2, longitude: 7.3))
        let b = MapViewport(camera: near, size: size).point(for: Coordinate(latitude: 62.2, longitude: 7.3))
        XCTAssertEqual(a.x, b.x, accuracy: 0.05)
        XCTAssertEqual(a.y, b.y, accuracy: 0.05)
    }

    func testZoomingKeepsThePlaceUnderThePointer() {
        // Zooming far out a place near the rim can't stay where it was (north stays up), so out from nearer the middle
        for (zoom, to, anchor) in [(2.0, 3.0, CGPoint(x: 600, y: 250)), (3.0, 4.3, CGPoint(x: 600, y: 250)), (4.2, 5.1, CGPoint(x: 600, y: 250)),
                                   (5.3, 4.6, CGPoint(x: 600, y: 250)), (2.5, 2.0, CGPoint(x: 530, y: 290))] {
            let p = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 40, longitude: 0), zoom: zoom), size: size)
            let fixed = try! XCTUnwrap(p.coordinate(at: anchor))
            let next = GlobeProjection(camera: p.zoomed(to: to, keeping: anchor), size: size)
            XCTAssertEqual(next.camera.zoom, to, accuracy: 1e-9)
            let moved = next.point(for: fixed)
            XCTAssertEqual(moved.x, anchor.x, accuracy: 0.5, "\(zoom) → \(to)")
            XCTAssertEqual(moved.y, anchor.y, accuracy: 0.5, "\(zoom) → \(to)")
        }
        // Held between the globe's smallest zoom and the map's largest
        let p = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 2), size: size)
        XCTAssertEqual(p.zoomed(to: -5, keeping: CGPoint(x: 480, y: 320)).zoom, GlobeProjection.minZoom(for: size), accuracy: 1e-9)
        XCTAssertEqual(p.zoomed(to: 30, keeping: CGPoint(x: 480, y: 320)).zoom, MapViewport.maxZoom, accuracy: 1e-9)
    }

    func testDraggingTurnsTheGlobeUnderThePointer() {
        let p = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 20, longitude: 10), zoom: 2.5), size: size)
        let under = p.coordinate(at: CGPoint(x: 480, y: 320))!
        // A drag of 30 points to the right: the place that was in the middle is now 30 points right of it
        let next = GlobeProjection(camera: p.rotated(by: 30, 0), size: size)
        XCTAssertEqual(next.point(for: under).x, 510, accuracy: 0.5)
        // (turning about the axis, it follows its circle of latitude: a little up)
        XCTAssertEqual(next.point(for: under).y, 320, accuracy: 1.5)
        let down = GlobeProjection(camera: p.rotated(by: 0, 40), size: size)
        XCTAssertEqual(down.point(for: under).y, 360, accuracy: 0.5)
        // Across the antimeridian
        let pacific = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 179), zoom: 2.5), size: size)
        XCTAssertEqual(pacific.rotated(by: -100, 0).center.longitude, Astronomy.wrap180(179 + 100 / pacific.radius * 180 / .pi), accuracy: 1e-9)
        XCTAssertLessThan(pacific.rotated(by: -100, 0).center.longitude, 0, "east of the antimeridian")
    }

    func testTheSkyFadesAsTheEarthFillsTheView() {
        let far = GlobeScene(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: GlobeProjection.minZoom(for: size)), size: size)
        XCTAssertEqual(far.skyOpacity, 1, accuracy: 1e-9)
        let close = GlobeScene(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 4), size: size)
        XCTAssertEqual(close.skyOpacity, 0, accuracy: 1e-9)
    }

    // MARK: The tilted camera

    func testATiltedCameraLooksAheadAtTheHorizon() {
        let alps = Coordinate(latitude: 46, longitude: 9)
        let p = GlobeProjection(camera: MapCamera(center: alps, zoom: 5.4, pitch: 72, heading: 0), size: size)
        XCTAssertEqual(p.perspective, 1)
        XCTAssertEqual(p.flatness, 0, "a tilted globe never flattens")
        // The target in the middle, the ground ahead higher up and smaller, behind lower down
        XCTAssertEqual(p.point(for: alps).x, 480, accuracy: 1e-6)
        XCTAssertEqual(p.point(for: alps).y, 320, accuracy: 1e-6)
        let ahead = p.point(for: Coordinate(latitude: 49, longitude: 9)), behind = p.point(for: Coordinate(latitude: 43, longitude: 9))
        XCTAssertLessThan(ahead.y, 320)
        XCTAssertGreaterThan(behind.y, 320)
        XCTAssertLessThan(320 - ahead.y, behind.y - 320, "foreshortened ahead")
        // Space above the horizon, the ground below; the far side behind the horizon
        XCTAssertNil(p.coordinate(at: CGPoint(x: 480, y: 2)))
        XCTAssertNotNil(p.coordinate(at: CGPoint(x: 480, y: 638)))
        XCTAssertFalse(p.isVisible(Coordinate(latitude: 75, longitude: 9)))
        XCTAssertTrue(p.isVisible(Coordinate(latitude: 52, longitude: 9)))
        for c in [Coordinate(latitude: 47, longitude: 11), Coordinate(latitude: 44, longitude: 5), Coordinate(latitude: 52, longitude: 14)] {
            let back = try! XCTUnwrap(p.coordinate(at: p.point(for: c)), "\(c)")
            XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-5)
            XCTAssertEqual(Astronomy.wrap180(back.longitude - c.longitude), 0, accuracy: 1e-5)
        }
        // Heading east: the east is ahead (up), the north on the left
        let east = GlobeProjection(camera: MapCamera(center: alps, zoom: 5.4, pitch: 60, heading: 90), size: size)
        XCTAssertLessThan(east.point(for: Coordinate(latitude: 46, longitude: 13)).y, 320)
        XCTAssertLessThan(east.point(for: Coordinate(latitude: 49, longitude: 9)).x, 480)
    }

    func testTiltingBlendsFromStraightDown() {
        let camera = MapCamera(center: Coordinate(latitude: 30, longitude: 20), zoom: 3)
        let straight = GlobeProjection(camera: camera, size: size)
        var slightly = camera
        slightly.pitch = 1e-6
        // The first degrees blend smoothly from the orthographic picture
        let c = Coordinate(latitude: 40, longitude: 30)
        XCTAssertEqual(GlobeProjection(camera: slightly, size: size).point(for: c).x, straight.point(for: c).x, accuracy: 1e-3)
        XCTAssertEqual(GlobeProjection(camera: slightly, size: size).point(for: c).y, straight.point(for: c).y, accuracy: 1e-3)
        for pitch in [3.0, 6.0, 9.0] {
            var tilted = camera
            tilted.pitch = pitch
            let p = GlobeProjection(camera: tilted, size: size)
            XCTAssertGreaterThan(p.perspective, 0)
            XCTAssertLessThan(p.perspective, 1)
            let back = try! XCTUnwrap(p.coordinate(at: p.point(for: c)), "pitch \(pitch)")
            XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-4)
            XCTAssertEqual(back.longitude, c.longitude, accuracy: 1e-4)
        }
    }

    func testTheCameraIsHeldWithinItsLimits() {
        let c = Coordinate(latitude: 10, longitude: 10)
        let held = GlobeProjection.held(MapCamera(center: c, zoom: 10, pitch: 90, heading: 190), size: size)
        XCTAssertEqual(held.pitch, GlobeProjection.maxPitch)
        XCTAssertEqual(held.heading, -170, accuracy: 1e-9)
        XCTAssertEqual(held.zoom, GlobeProjection.tiltedMaxZoom, "a tilted camera comes no closer than low orbit")
        XCTAssertEqual(GlobeProjection.held(MapCamera(center: c, zoom: 10, pitch: -5), size: size).pitch, 0)
        XCTAssertEqual(GlobeProjection.held(MapCamera(center: c, zoom: 10), size: size).zoom, 10, "straight down to the flat map")
    }

    func testZoomingATiltedCameraKeepsThePlaceUnderThePointer() {
        for (pitch, heading, zoom, to) in [(60.0, 0.0, 5.0, 5.6), (72.0, 48.0, 5.4, 6.2), (40.0, -120.0, 4.0, 3.4)] {
            let p = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 41, longitude: 16), zoom: zoom, pitch: pitch, heading: heading), size: size)
            let anchor = CGPoint(x: 600, y: 420)
            let fixed = try! XCTUnwrap(p.coordinate(at: anchor))
            let next = GlobeProjection(camera: p.zoomed(to: to, keeping: anchor), size: size)
            XCTAssertEqual(next.camera.pitch, pitch)
            XCTAssertEqual(next.camera.heading, heading)
            XCTAssertEqual(next.point(for: fixed).x, anchor.x, accuracy: 0.5, "\(pitch)° \(zoom) → \(to)")
            XCTAssertEqual(next.point(for: fixed).y, anchor.y, accuracy: 0.5, "\(pitch)° \(zoom) → \(to)")
        }
    }

    func testDraggingATiltedGlobeFollowsTheHeading() {
        // Heading east: a drag down brings the ground ahead (east) nearer, so the centre moves east
        let p = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 4, pitch: 50, heading: 90), size: size)
        let next = p.rotated(by: 0, 40)
        XCTAssertGreaterThan(next.center.longitude, 0.5)
        XCTAssertEqual(next.center.latitude, 0, accuracy: 1e-9)
        XCTAssertEqual(next.pitch, 50)
        XCTAssertEqual(next.heading, 90)
    }

    func testACameraSavedWithoutTiltReadsStraightDown() throws {
        let old = Data(#"{"center":{"latitude":48,"longitude":11},"zoom":3}"#.utf8)
        let camera = try JSONDecoder().decode(MapCamera.self, from: old)
        XCTAssertEqual(camera.pitch, 0)
        XCTAssertEqual(camera.heading, 0)
        let tilted = MapCamera(center: Coordinate(latitude: 48, longitude: 11), zoom: 5, pitch: 60, heading: -30)
        XCTAssertEqual(try JSONDecoder().decode(MapCamera.self, from: JSONEncoder().encode(tilted)), tilted)
    }

    func testTheSkyShowsAboveATiltedHorizonAndCloudsThinOut() {
        let close = MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 6)
        XCTAssertEqual(GlobeScene(camera: close, size: size).skyOpacity, 0, accuracy: 1e-9)
        var tilted = close
        tilted.pitch = 60
        XCTAssertEqual(GlobeScene(camera: tilted, size: size).skyOpacity, 1, accuracy: 1e-9)
        let far = GlobeScene(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 2), size: size, clouds: 0.65)
        XCTAssertEqual(far.cloudOpacity, 0.65, accuracy: 1e-9)
        XCTAssertLessThan(GlobeScene(camera: tilted, size: size, clouds: 0.65).cloudOpacity, 0.4, "thinner in low orbit")
        XCTAssertEqual(GlobeScene(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: GlobeProjection.flatZoom(for: size)), size: size,
                                  clouds: 0.65).cloudOpacity, 0, "none on the flat map")
        XCTAssertEqual(GlobeScene(camera: tilted, size: size, exaggerated: false).reliefFactor, 1)
        XCTAssertLessThan(GlobeScene(camera: tilted, size: size).reliefFactor, GlobeScene(camera: MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 2), size: size).reliefFactor)
    }

    // MARK: Data

    func testABrokenTilePackThrows() {
        XCTAssertThrowsError(try SatelliteTiles(data: Data("SBHM\u{0}\u{0}\u{0}\u{0}".utf8)))
        // One entry whose bytes lie beyond the end
        var pack = Data("SBTL".utf8) + Data([1, 0, 0, 0, 4]) + Data("base".utf8)
        pack += Data([0, 1, 0, 0, 0, 0, 0, 0]) + Data([0, 1, 0, 0])
        XCTAssertThrowsError(try SatelliteTiles(data: pack))
        XCTAssertThrowsError(try SatelliteTiles(data: Data("SBTL".utf8) + Data([200, 0, 0, 0])), "more entries than the header holds")
    }

    func testTheHeightmapFormatRoundTrips() throws {
        let map = Heightmap(width: 4, height: 2, metres: [1, -2, 3, -4, 8_848, -10_994, 0, 7])
        let read = try Heightmap(data: map.fileData)
        XCTAssertEqual(read.width, 4)
        XCTAssertEqual(read.height, 2)
        XCTAssertEqual(read.metres, map.metres)
        // Cell (1, 0) is centred on 45° N, 45° W
        XCTAssertEqual(read.metres(at: Coordinate(latitude: 45, longitude: -45)), -2, accuracy: 1e-9)
        XCTAssertThrowsError(try Heightmap(data: Data("SBHM".utf8)))
        XCTAssertThrowsError(try Heightmap(data: map.fileData.prefix(20)))
        XCTAssertThrowsError(try Heightmap(data: Data(repeating: 0, count: 64)))
    }

    static let globeFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Vendor/Globe")

    func testTheGlobeData() throws {
        let data = GlobeData.load(folder: Self.globeFolder)
        let heights = try XCTUnwrap(data.heightmap, "Scripts/fetch_globe.sh puts the globe's data into Vendor/Globe")
        XCTAssertEqual(heights.width, 2880)
        XCTAssertEqual(heights.height, 1440)
        // Averages over cells of 1/8° (about 14 km): the summits lower than they are
        XCTAssertGreaterThan(heights.metres(at: Coordinate(latitude: 27.99, longitude: 86.93)), 5_000, "Everest")
        XCTAssertLessThan(heights.metres(at: Coordinate(latitude: 11.35, longitude: 142.2)), -9_000, "Challenger Deep")
        XCTAssertEqual(heights.metres(at: Coordinate(latitude: 48.14, longitude: 11.58)), 520, accuracy: 120, "Munich")
        XCTAssertLessThan(heights.metres(at: Coordinate(latitude: 31.5, longitude: 35.5)), -150, "the Dead Sea")
        XCTAssertGreaterThan(heights.metres(at: Coordinate(latitude: -89.9, longitude: 0)), 2_500, "the South Pole")
        XCTAssertLessThan(heights.metres(at: Coordinate(latitude: 89.9, longitude: 0)), -3_000, "the North Pole")
        let sky = try XCTUnwrap(data.sky)
        XCTAssertEqual(sky.width, 2 * sky.height)
        let lights = try XCTUnwrap(data.cityLights)
        XCTAssertEqual(lights.width, 2 * lights.height)
        let clouds = try XCTUnwrap(data.clouds)
        XCTAssertEqual(clouds.width, 2 * clouds.height)
        // The satellite picture: the whole Earth, then 8 × 4 and 16 × 8 tiles of 1350 pixels
        let satellite = try XCTUnwrap(data.satellite)
        XCTAssertEqual(satellite.names.count, 1 + 32 + 128)
        let base = try XCTUnwrap(satellite.image(named: "base"))
        XCTAssertEqual(base.width, 2 * base.height)
        for name in ["1-0-0", "1-3-7", "2-0-0", "2-7-15"] {
            let tile = try XCTUnwrap(satellite.image(named: name), name)
            XCTAssertEqual(tile.width, 1350, name)
            XCTAssertEqual(tile.height, 1350, name)
        }
        XCTAssertNil(satellite.image(named: "2-8-0"))
    }
}
