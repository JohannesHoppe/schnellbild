import AppKit
import CoreGraphics
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers
import XCTest
@testable import OfflineMap

/// The globe drawn by Metal off screen: its pictures (light and dark, day and
/// night, relief, the sky, flattening, flat) go to MAP_SNAPSHOT_DIR as
/// `globe-*.png`; the sky's stars where the sidereal time puts them; the Sun
/// lighting the subsolar point and not its antipode; the picture at the flat
/// zoom matching the flat map's tiles; a frame within 60 fps' budget. Skipped
/// where there is no Metal device.
final class GlobeRenderTests: XCTestCase {
    nonisolated(unsafe) static var shared: GlobeRenderer?

    func renderer() throws -> GlobeRenderer { try Self.renderer() }

    static func renderer() throws -> GlobeRenderer {
        if let shared { return shared }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let files = try FileManager.default.contentsOfDirectory(at: OfflineMapTests.mapFolder, includingPropertiesForKeys: nil)
        let map = try XCTUnwrap(files.first { $0.pathExtension == "pmtiles" })
        let renderer = try XCTUnwrap(GlobeRenderer(device: device, map: MapRenderer(archive: try PMTilesArchive(url: map), places: nil),
                                                   data: GlobeData.load(folder: GlobeMathTests.globeFolder)), "the shaders compile")
        print("Globe: Metal device \(device.name)")
        shared = renderer
        return renderer
    }

    let size = CGSize(width: 960, height: 640)
    let summer = ISO8601DateFormatter().date(from: "2026-06-21T09:00:00Z")!

    func picture(_ scene: GlobeScene, _ name: String? = nil) throws -> CGImage {
        let r = try renderer()
        r.textures.prepareAndWait(for: scene)
        XCTAssertTrue(r.textures.isReady(for: scene))
        let (image, _) = try XCTUnwrap(r.snapshot(scene))
        if let name { try save(image, name) }
        return image
    }

    func save(_ image: CGImage, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MAP_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The pixels as RGBA bytes, rows from the top.
    func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// The mean brightness (0 ... 255) of a square of pixels around a point (in points, scale 2).
    func brightness(_ image: CGImage, at p: CGPoint, radius: Int = 3) -> Double {
        let px = pixels(image), cx = Int(p.x * 2), cy = Int(p.y * 2)
        var sum = 0.0, n = 0.0
        for y in max(0, cy - radius)...min(image.height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(image.width - 1, cx + radius) {
                let o = (y * image.width + x) * 4
                sum += 0.2126 * Double(px[o]) + 0.7152 * Double(px[o + 1]) + 0.0722 * Double(px[o + 2])
                n += 1
            }
        }
        return sum / n
    }

    func testTheGlobesPictures() throws {
        let over = GlobeProjection.overviewZoom(for: size)
        let europe = MapCamera(center: Coordinate(latitude: 30, longitude: 10), zoom: over)
        let light = try picture(GlobeScene(camera: europe, size: size, dark: false, date: summer), "globe-light")
        let dark = try picture(GlobeScene(camera: europe, size: size, dark: true, date: summer), "globe-dark")
        _ = try picture(GlobeScene(camera: europe, size: size, dark: false, lighting: true, date: summer), "globe-light-lit")
        _ = try picture(GlobeScene(camera: europe, size: size, dark: true, lighting: true, date: summer), "globe-dark-lit")
        _ = try picture(GlobeScene(camera: europe, size: size, dark: false, exaggerated: false, date: summer), "globe-light-true-scale")
        let himalaya = MapCamera(center: Coordinate(latitude: 30, longitude: 85), zoom: 3.4)
        _ = try picture(GlobeScene(camera: himalaya, size: size, dark: false, date: summer), "globe-relief-himalaya")
        _ = try picture(GlobeScene(camera: himalaya, size: size, dark: true, lighting: true, date: summer), "globe-relief-himalaya-dark-lit")
        let far = MapCamera(center: Coordinate(latitude: 20, longitude: -40), zoom: GlobeProjection.minZoom(for: size))
        _ = try picture(GlobeScene(camera: far, size: size, dark: true, lighting: true, date: summer), "globe-sky")
        let alps = Coordinate(latitude: 46, longitude: 9)
        let flatZoom = GlobeProjection.flatZoom(for: size)
        _ = try picture(GlobeScene(camera: MapCamera(center: alps, zoom: flatZoom - 0.75), size: size, date: summer), "globe-flattening")
        _ = try picture(GlobeScene(camera: MapCamera(center: alps, zoom: flatZoom), size: size, date: summer), "globe-flat")
        _ = try picture(GlobeScene(camera: MapCamera(center: Coordinate(latitude: -17, longitude: 180), zoom: over), size: size, date: summer),
                        "globe-antimeridian")
        // The middle shows the satellite picture's desert (Libya) in both appearances, space around the Earth darker
        let libya = brightness(light, at: CGPoint(x: 480, y: 330))
        XCTAssertGreaterThan(libya, 110, "the desert")
        XCTAssertEqual(brightness(dark, at: CGPoint(x: 480, y: 330)), libya, accuracy: 10, "the same picture in the dark")
        XCTAssertLessThan(brightness(light, at: CGPoint(x: 15, y: 15), radius: 20), libya - 50, "space")
    }

    func testTheSunLightsItsSideOnly() throws {
        let sun = Astronomy.subsolarPoint(at: summer)
        let zoom = GlobeProjection.overviewZoom(for: size)
        let antipode = Coordinate(latitude: -sun.latitude, longitude: Astronomy.wrap180(sun.longitude + 180))
        let day = try picture(GlobeScene(camera: MapCamera(center: sun, zoom: zoom), size: size, lighting: true, date: summer))
        let dayOff = try picture(GlobeScene(camera: MapCamera(center: sun, zoom: zoom), size: size, lighting: false, date: summer))
        let night = try picture(GlobeScene(camera: MapCamera(center: antipode, zoom: zoom), size: size, lighting: true, date: summer))
        let nightOff = try picture(GlobeScene(camera: MapCamera(center: antipode, zoom: zoom), size: size, lighting: false, date: summer))
        let middle = CGPoint(x: 480, y: 320)
        XCTAssertGreaterThan(brightness(day, at: middle, radius: 20), 0.85 * brightness(dayOff, at: middle, radius: 20), "the subsolar point lit")
        XCTAssertLessThan(brightness(night, at: middle, radius: 20), 0.35 * brightness(nightOff, at: middle, radius: 20), "its antipode in the night")
    }

    /// The mean colour (0 ... 255 per channel) of a square of pixels around a point (in points, scale 2).
    func colour(_ image: CGImage, at p: CGPoint, radius: Int = 3) -> SIMD3<Double> {
        let px = pixels(image), cx = Int(p.x * 2), cy = Int(p.y * 2)
        var sum = SIMD3<Double>(0, 0, 0), n = 0.0
        for y in max(0, cy - radius)...min(image.height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(image.width - 1, cx + radius) {
                let o = (y * image.width + x) * 4
                sum += SIMD3(Double(px[o]), Double(px[o + 1]), Double(px[o + 2]))
                n += 1
            }
        }
        return sum / n
    }

    func testTheAtmosphereGlowsBlueAroundTheEarth() throws {
        let sun = Astronomy.subsolarPoint(at: summer)
        let antipode = Coordinate(latitude: -sun.latitude, longitude: Astronomy.wrap180(sun.longitude + 180))
        for (name, center) in [("day", sun), ("night", antipode)] {
            let scene = GlobeScene(camera: MapCamera(center: center, zoom: 2), size: size, dark: true, lighting: true, date: summer)
            let image = try picture(scene, "globe-atmosphere-\(name)")
            let rim = scene.projection.radius
            // Just beyond the limb a blue haze, far out space
            let haze = colour(image, at: CGPoint(x: 480 + rim + 2, y: 320)), space = colour(image, at: CGPoint(x: 480 + rim + 120, y: 320))
            XCTAssertGreaterThan(haze.z, space.z + 20, "\(name): the haze over space")
            XCTAssertGreaterThan(haze.z, haze.x + 10, "\(name): blue")
            XCTAssertGreaterThan(haze.z, colour(image, at: CGPoint(x: 480 + rim + 15, y: 320)).z, "\(name): thin")
        }
        // The Sun behind the Earth lights the ring from behind
        let backlit = try picture(GlobeScene(camera: MapCamera(center: antipode, zoom: 2), size: size, dark: true, lighting: true, date: summer))
        let frontlit = try picture(GlobeScene(camera: MapCamera(center: sun, zoom: 2), size: size, dark: true, lighting: true, date: summer))
        let rim = GlobeProjection(camera: MapCamera(center: sun, zoom: 2), size: size).radius
        let p = CGPoint(x: 480 + rim + 2, y: 320)
        XCTAssertGreaterThan(brightness(backlit, at: p), brightness(frontlit, at: p) + 50)
    }

    /// The Sun's place in the view of a tilted camera.
    func sunPoint(_ scene: GlobeScene) -> CGPoint {
        let fr = scene.projection.frame
        let dir = GlobeGeometry.unitVector(Astronomy.subsolarPoint(at: scene.date))
        let z = simd_dot(dir, fr.forward)
        return CGPoint(x: Double(scene.size.width) / 2 + fr.focal * simd_dot(dir, fr.right) / z,
                       y: Double(scene.size.height) / 2 - fr.focal * simd_dot(dir, fr.up) / z)
    }

    func testTheSunRisesOverATiltedHorizon() throws {
        // Low over Italy at dawn, looking north-east: the Sun just above the curved horizon, stars above, the night side below
        let dawn = ISO8601DateFormatter().date(from: "2026-06-21T02:12:00Z")!
        let scene = GlobeScene(camera: MapCamera(center: Coordinate(latitude: 41, longitude: 16), zoom: 5.4, pitch: 72, heading: 48),
                               size: size, dark: true, lighting: true, date: dawn, clouds: 0.65)
        let image = try picture(scene, "globe-tilted-dawn")
        let sun = sunPoint(scene)
        XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 50, dy: 50).contains(sun), "the Sun in the view: \(sun)")
        XCTAssertGreaterThan(brightness(image, at: sun), 250, "the Sun's disc")
        let horizon = try XCTUnwrap((0..<640).first { scene.projection.coordinate(at: CGPoint(x: sun.x, y: Double($0))) != nil }, "the ground")
        XCTAssertGreaterThan(Double(horizon), sun.y, "the Sun above the horizon")
        XCTAssertLessThan(Double(horizon) - sun.y, 80, "and near it")
        XCTAssertLessThan(brightness(image, at: CGPoint(x: 480, y: 600), radius: 20), 60, "the night below")
        // Seen from straight above, the same place shows no sky
        var straight = scene
        straight.camera.pitch = 0
        XCTAssertNotNil(straight.projection.coordinate(at: CGPoint(x: 480, y: 20)))
        _ = try picture(GlobeScene(camera: MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: 6.5, pitch: 60), size: size,
                                   dark: true, lighting: true, date: summer, clouds: 0.65), "globe-tilted-alps")
    }

    func testTheSkyStandsAsTheSiderealTimeSays() throws {
        // Orion behind the Earth: Procyon and the Pleiades on either side, where the sidereal time and precession put them
        let gmst = Astronomy.siderealTime(at: summer)
        let camera = MapCamera(center: Coordinate(latitude: 1, longitude: Astronomy.wrap180(83.8 - gmst + 180)),
                               zoom: GlobeProjection.minZoom(for: size))
        let image = try picture(GlobeScene(camera: camera, size: size, dark: true, date: summer), "globe-sky-orion")
        let m = Astronomy.celestialToEarth(at: summer)
        let (e, n, u) = GlobeGeometry.basis(camera.center)
        let f = Double(min(size.width, size.height)) / 2 / tan(45 * Double.pi / 180)
        func place(_ ra: Double, _ dec: Double) -> CGPoint {
            let d = m * GlobeGeometry.unitVector(latitude: dec, longitude: ra)
            let forward = -simd_dot(d, u)
            return CGPoint(x: Double(size.width) / 2 + simd_dot(d, e) * f / forward, y: Double(size.height) / 2 - simd_dot(d, n) * f / forward)
        }
        let background = brightness(image, at: CGPoint(x: 100, y: 600), radius: 30)
        for (name, ra, dec) in [("Procyon", 114.825, 5.225), ("Pleiades", 56.75, 24.12)] {
            let p = place(ra, dec)
            XCTAssertGreaterThan(brightness(image, at: p, radius: 4), background + 25, "\(name) at \(p)")
            // Mirrored east–west it would be elsewhere
            let mirrored = CGPoint(x: size.width - p.x, y: p.y)
            XCTAssertLessThan(brightness(image, at: mirrored, radius: 4), brightness(image, at: p, radius: 4), "\(name) not mirrored")
        }
    }

    func testAtTheFlatZoomTheGlobeShowsTheFlatMapsTiles() throws {
        let camera = MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: GlobeProjection.flatZoom(for: size))
        let globe = try picture(GlobeScene(camera: camera, size: size, date: summer))
        // The flat map's own drawing of the same view, without labels
        let r = try renderer()
        let map = try XCTUnwrap(r.textures.map)
        let ctx = try XCTUnwrap(MapRenderer.context(width: Int(size.width * 2), height: Int(size.height * 2)))
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        map.draw(MapViewport(camera: camera, size: size), in: ctx, palette: .light, labels: false)
        let flat = try XCTUnwrap(ctx.makeImage())
        try save(flat, "globe-flat-reference")
        let a = pixels(globe), b = pixels(flat)
        var difference = 0.0
        for k in stride(from: 0, to: a.count, by: 4) {
            difference += abs(Double(a[k]) - Double(b[k])) + abs(Double(a[k + 1]) - Double(b[k + 1])) + abs(Double(a[k + 2]) - Double(b[k + 2]))
        }
        let mean = difference / Double(a.count / 4 * 3)
        print("Globe: flat hand-over differs by \(mean) per channel on average")
        XCTAssertLessThan(mean, 3, "the hand-over to the flat map shows no jump")
    }

    func testAFrameFitsIntoSixtyFramesASecond() throws {
        let r = try renderer()
        let window = CGSize(width: 1200, height: 800)
        for (name, camera) in [("globe", MapCamera(center: Coordinate(latitude: 30, longitude: 10), zoom: GlobeProjection.overviewZoom(for: window))),
                               ("flattening", MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: GlobeProjection.flatZoom(for: window) - 0.7)),
                               ("tilted", MapCamera(center: Coordinate(latitude: 41, longitude: 16), zoom: 5.4, pitch: 72, heading: 48))] {
            let scene = GlobeScene(camera: camera, size: window, dark: true, lighting: true, date: summer, clouds: 0.65)
            r.textures.prepareAndWait(for: scene)
            let seconds = try XCTUnwrap(r.frameTime(scene, scale: 2))
            print("Globe: \(name) frame at 2400 × 1600 px: \(String(format: "%.2f", seconds * 1000)) ms on the GPU")
            XCTAssertLessThan(seconds, 1.0 / 60, "\(name)")
        }
    }

    func testTheTexturesAreMadeSoon() throws {
        let r = try renderer()
        let scene = GlobeScene(camera: MapCamera(center: Coordinate(latitude: 10, longitude: 120), zoom: 4.2), size: size, dark: true)
        // Once, on the wall clock (drawn on several threads; again they would be kept)
        TimeBudget.check("Globe: textures for a new view", under: 5, runs: 1, clock: .wall) { r.textures.prepareAndWait(for: scene) }
    }
}

/// The globe's view in a window: the globe while far out, the flat map once
/// at the flat zoom (the globe fading out over it once its tiles are drawn),
/// and back; the overlay's proxy hiding the far side.
@MainActor
final class GlobeSurfaceTests: XCTestCase {

    func wait(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testTheGlobeHandsOverToTheFlatMapAndBack() throws {
        let renderer = try GlobeRenderTests.renderer()
        let size = CGSize(width: 800, height: 500)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let surface = GlobeSurfaceView(map: renderer.textures.map)
        surface.attach(renderer)
        window.contentView = surface
        surface.frame = NSRect(origin: .zero, size: size)
        var reported: MapCamera?
        surface.onCameraChange = { reported = $0 }
        let metal = try XCTUnwrap(surface.subviews.last)
        surface.camera = MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: 2.5)
        XCTAssertFalse(metal.isHidden, "the globe")
        XCTAssertTrue(surface.flat.isHidden)

        // Zoomed in to the flat zoom: the flat map, the globe gone once its tiles are drawn
        surface.move(to: MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: GlobeProjection.flatZoom(for: size) + 0.5), animated: false)
        XCTAssertEqual(reported?.zoom ?? 0, GlobeProjection.flatZoom(for: size) + 0.5, accuracy: 1e-9)
        XCTAssertFalse(surface.flat.isHidden, "the flat map")
        XCTAssertEqual(surface.flat.camera, surface.camera)
        wait(10) { surface.flat.allTilesShown && metal.isHidden }
        XCTAssertTrue(surface.flat.allTilesShown)
        XCTAssertTrue(metal.isHidden, "the globe hands over")

        // On the flat map near the flat zoom the globe's textures for the way out are made ahead
        var handover = surface.scene
        handover.camera.zoom = GlobeProjection.flatZoom(for: size) - 0.01
        wait(30) { renderer.textures.isReady(for: handover) }
        XCTAssertTrue(renderer.textures.isReady(for: handover), "the globe's textures made ahead")

        // Zoomed out again: the globe draws under the flat map, which stays
        // on top until the globe's frame is there (at most `revealTimeout`):
        // never neither of them
        surface.move(to: MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: 3), animated: false)
        XCTAssertFalse(metal.isHidden)
        XCTAssertEqual(metal.alphaValue, 1)
        XCTAssertTrue(surface.revealPending)
        XCTAssertFalse(surface.flat.isHidden, "the flat map until the globe's frame is on screen")
        XCTAssertTrue(surface.subviews.last === surface.flat, "over the globe meanwhile")
        wait(GlobeSurfaceView.revealTimeout + 2) { surface.flat.isHidden }
        XCTAssertTrue(surface.flat.isHidden, "the globe shown")
        XCTAssertFalse(surface.revealPending)
        XCTAssertTrue(surface.subviews.last === metal, "the globe on top again")

        // Held within the globe's zoom limits
        surface.move(to: MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: -3), animated: false)
        XCTAssertEqual(surface.camera.zoom, GlobeProjection.minZoom(for: size), accuracy: 1e-9)
    }

    func testPinchAndScrollZoomOrTurn() throws {
        let surface = GlobeSurfaceView(map: nil)
        surface.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        surface.camera = MapCamera(center: Coordinate(latitude: 40, longitude: 10), zoom: 2.5)
        let middle = CGPoint(x: 400, y: 250)
        // A pinch to twice the size: one step in
        surface.pinch(by: 1, at: middle)
        XCTAssertEqual(surface.camera.zoom, 3.5, accuracy: 1e-9)
        // A mouse's wheel (4 lines): one step; ⌘ with a trackpad: a hundredth per point
        surface.scroll(dx: 0, dy: -4, precise: false, command: false, at: middle)
        XCTAssertEqual(surface.camera.zoom, 2.5, accuracy: 1e-9)
        surface.scroll(dx: 0, dy: 50, precise: true, command: true, at: middle)
        XCTAssertEqual(surface.camera.zoom, 3, accuracy: 1e-9)
        // Two fingers on a trackpad turn it
        let before = surface.camera
        surface.scroll(dx: 40, dy: 0, precise: true, command: false, at: middle)
        XCTAssertEqual(surface.camera.zoom, before.zoom, accuracy: 1e-9)
        XCTAssertLessThan(surface.camera.center.longitude, before.center.longitude)
    }

    func testANewSizeKeepsTheOwnersCamera() {
        let surface = GlobeSurfaceView(map: nil)
        surface.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let small = GlobeProjection.minZoom(for: CGSize(width: 400, height: 300))
        surface.camera = MapCamera(center: Coordinate(latitude: 10, longitude: 20), zoom: small)
        // The owner sets another camera while the view grows (its smallest zoom rises, the old camera is held)
        var owner = MapCamera(center: Coordinate(latitude: 50, longitude: 8), zoom: 3)
        var reported: [MapCamera] = []
        surface.ownerCamera = { owner }
        surface.onCameraChange = { reported.append($0); owner = $0 }
        surface.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        surface.camera = owner
        wait(1) { false }
        XCTAssertEqual(surface.camera, owner, "the owner's camera stands")
        XCTAssertTrue(reported.isEmpty, "no stale camera reported: \(reported)")
        // Without an owner the held camera is reported, as before
        let lone = GlobeSurfaceView(map: nil)
        lone.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        lone.camera = MapCamera(center: Coordinate(latitude: 10, longitude: 20), zoom: small)
        var loneReported: MapCamera?
        lone.onCameraChange = { loneReported = $0 }
        lone.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        wait(1) { loneReported != nil }
        XCTAssertEqual(loneReported?.zoom ?? 0, GlobeProjection.minZoom(for: CGSize(width: 1200, height: 900)), accuracy: 1e-9)
    }

    /// The globe's renderer (and with it every texture: about 300 MB of
    /// memory shared with the GPU in the app) is kept while a globe view is
    /// in a window, a moment longer, then let go; the next globe makes it again.
    func testTheTexturesGoWhenNoGlobeIsShown() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let keep = GlobeRenderer.keepUnused
        GlobeRenderer.keepUnused = 0.3
        defer { GlobeRenderer.keepUnused = keep }
        let map: MapRenderer? = nil   // (the globe without the map's tiles: the same renderer, the same keeping)
        let size = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        let first = GlobeSurfaceView(map: map), second = GlobeSurfaceView(map: map)
        first.frame = size
        second.frame = size
        window.contentView = first
        other.contentView = second
        wait(30) { first.renderer != nil && second.renderer != nil }
        weak var made = first.renderer
        XCTAssertNotNil(made)
        XCTAssertTrue(first.renderer === second.renderer, "one renderer per map")

        // One globe leaves its window: it lets go of the renderer, the other keeps it
        window.contentView = nil
        XCTAssertNil(first.renderer)
        wait(1) { false }
        XCTAssertTrue(GlobeRenderer.isKept(for: map), "another globe still shows it")
        XCTAssertNotNil(made)

        // The last one leaves: a moment later it is gone, textures and all
        other.contentView = nil
        XCTAssertNil(second.renderer)
        wait(5) { made == nil }
        XCTAssertFalse(GlobeRenderer.isKept(for: map))
        XCTAssertNil(made, "the renderer and its textures are let go")

        // Shown again: made again
        window.contentView = first
        wait(30) { first.renderer != nil }
        XCTAssertNotNil(first.renderer)
        window.contentView = nil
    }

    func testTheProxyHidesTheFarSide() {
        let size = CGSize(width: 800, height: 500)
        let camera = MapCamera(center: Coordinate(latitude: 48, longitude: 11), zoom: 2)
        let proxy = MapProxy(viewport: MapViewport(camera: camera, size: size), link: MapLink(), globe: GlobeProjection(camera: camera, size: size))
        XCTAssertTrue(proxy.isVisible(Coordinate(latitude: 52.5, longitude: 13.4)), "Berlin")
        XCTAssertFalse(proxy.isVisible(Coordinate(latitude: -33.9, longitude: 151.2)), "Sydney, on the far side")
        XCTAssertEqual(proxy.point(for: camera.center).x, 400, accuracy: 1e-9)
        // A point in space gives the place on the rim in its direction
        let rim = proxy.coordinate(at: CGPoint(x: 799, y: 250))
        XCTAssertTrue(proxy.isVisible(rim))
        XCTAssertGreaterThan(proxy.point(for: rim).x, 400)
        // The flat map's proxy sees everything
        let flat = MapProxy(viewport: MapViewport(camera: camera, size: size), link: MapLink())
        XCTAssertTrue(flat.isVisible(Coordinate(latitude: -33.9, longitude: 151.2)))
    }
}
