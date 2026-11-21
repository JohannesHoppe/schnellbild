import CoreGraphics
import Metal
import simd
import XCTest
@testable import OfflineMap

/// The globe's tiles (`TileAtlas`, `GlobeTilePlan`): a move makes only the
/// tiles coming into view, nothing kept is made again, the tiles ahead of a
/// throw are made before it gets there; and the relief stays on the Earth
/// while the globe turns (the mesh's vertices on whole degrees of the Earth,
/// probed through the vertex shader's own `meshPoint` and `place`). Skipped
/// where there is no Metal device.
final class GlobeTileTests: XCTestCase {
    func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        return device
    }

    /// An atlas of small tiles whose `make` counts what it is asked for.
    final class Counting: @unchecked Sendable {
        let lock = NSLock()
        var made: [TileAtlas.Key] = []
        func make(_ key: TileAtlas.Key) -> CGContext? {
            lock.withLock { made.append(key) }
            let ctx = MapRenderer.context(width: 16, height: 16)
            ctx?.setFillColor(CGColor(red: CGFloat(key.x) / 16, green: CGFloat(key.y) / 16, blue: 0.5, alpha: 1))
            ctx?.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            return ctx
        }
    }

    func atlas(capacity: Int, _ counting: Counting) throws -> TileAtlas {
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        return try XCTUnwrap(TileAtlas(device: device, queue: queue, side: 16, capacity: capacity, columns: 16, rows: 8, levels: 2,
                                       concurrency: 4, name: "test", make: counting.make, changed: {}))
    }

    func waitFor(_ atlas: TileAtlas, _ keys: [TileAtlas.Key]) {
        let end = Date().addingTimeInterval(10)
        while !atlas.has(keys), Date() < end { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(atlas.has(keys))
    }

    func key(_ x: Int, _ y: Int = 0) -> TileAtlas.Key { TileAtlas.Key(level: 0, x: x, y: y) }

    func testAMoveMakesOnlyTheTilesComingIntoView() throws {
        let counting = Counting()
        let atlas = try atlas(capacity: 8, counting)
        let first = (0..<4).map { key($0) }
        atlas.request(first)
        waitFor(atlas, first)
        XCTAssertEqual(Set(counting.made), Set(first))

        // One column further: one new tile, the three still in view not made again
        let moved = (1..<5).map { key($0) }
        atlas.request(moved)
        waitFor(atlas, moved)
        XCTAssertEqual(counting.made.count, 5, "only the new tile")
        XCTAssertEqual(counting.made.last, key(4))

        // Back: the tile left behind is still kept
        atlas.request(first)
        waitFor(atlas, first)
        XCTAssertEqual(counting.made.count, 5, "nothing kept is made again")
    }

    func testTheTileWantedLongestAgoMakesRoom() throws {
        let counting = Counting()
        let atlas = try atlas(capacity: 4, counting)
        for x in 0..<4 {
            atlas.request([key(x)])
            waitFor(atlas, [key(x)])
        }
        XCTAssertEqual(atlas.kept, Set((0..<4).map { key($0) }))
        // Tile 1 wanted again: tile 0 is the one wanted longest ago
        atlas.request([key(1)])
        atlas.request([key(1), key(4)])
        waitFor(atlas, [key(1), key(4)])
        XCTAssertEqual(atlas.kept, Set([key(1), key(2), key(3), key(4)]))
        // Never one wanted now: four wanted, all of them kept
        let wanted = [key(1), key(4), key(5), key(6)]
        atlas.request(wanted)
        waitFor(atlas, wanted)
        XCTAssertEqual(atlas.kept, Set(wanted))
        XCTAssertEqual(counting.made.count, 7)
    }

    func testTheIndexSaysWhereEachTileIs() throws {
        let counting = Counting()
        let atlas = try atlas(capacity: 4, counting)
        let keys = [key(3, 2), TileAtlas.Key(level: 1, x: 1, y: 1)]
        atlas.request(keys)
        waitFor(atlas, keys)
        func entry(_ k: TileAtlas.Key) -> UInt16 {
            var v: UInt16 = 0
            atlas.index.getBytes(&v, bytesPerRow: 2, from: MTLRegionMake2D(k.x, k.y, 1, 1), mipmapLevel: k.level)
            return v
        }
        XCTAssertNotEqual(entry(keys[0]), 0)
        XCTAssertNotEqual(entry(keys[1]), 0)
        XCTAssertNotEqual(entry(keys[0]), entry(keys[1]), "each in its own slice")
        XCTAssertEqual(entry(key(0, 0)), 0, "none where no tile is")
    }

    // MARK: Plans

    let size = CGSize(width: 1200, height: 800)

    func plan(_ camera: MapCamera, ahead: [MapCamera] = []) -> GlobeTilePlan.Plan {
        let scene = GlobeScene(camera: camera, size: size)
        return GlobeTilePlan.plan(for: scene, ahead: ahead, satellite: true, map: GlobeTextures.needsMap(scene, satellite: true),
                                  satelliteCapacity: GlobeTextures.satelliteCapacity, mapCapacity: GlobeTextures.mapCapacity)
    }

    func testTurningALittleNeedsFewNewTiles() {
        let camera = MapCamera(center: Coordinate(latitude: 40, longitude: 10), zoom: 5.5, pitch: 60)
        let here = plan(camera)
        XCTAssertFalse(here.satelliteRequired.isEmpty)
        XCTAssertTrue(here.satelliteRequired.contains { $0.level == 0 }, "level 2 near the camera")
        XCTAssertTrue(here.satelliteRequired.contains { $0.level == 1 }, "level 1 further away")
        var turned = camera
        turned.center.longitude += 5
        let there = plan(turned)
        let new = Set(there.satelliteRequired).subtracting(here.satellite)
        print("Globe tiles: \(here.satelliteRequired.count) in view, \(new.count) new after turning 5°")
        XCTAssertLessThanOrEqual(new.count, 2, "the margin holds what comes into view")
    }

    func testFarOutTheWholeEarthsTexturesAreEnough() {
        let p = plan(MapCamera(center: Coordinate(latitude: 30, longitude: 10), zoom: 2))
        XCTAssertTrue(p.satellite.isEmpty)
        XCTAssertTrue(p.map.isEmpty)
    }

    func testTheMapsTilesWhileFlattening() {
        let camera = MapCamera(center: Coordinate(latitude: 46, longitude: 9), zoom: GlobeProjection.flatZoom(for: size) - 0.3)
        let p = plan(camera)
        XCTAssertFalse(p.mapRequired.isEmpty)
        // The middle of the view at the zoom shown rounded up
        let finest = GlobeTilePlan.finestMapZoom(for: GlobeScene(camera: camera, size: size).projection)
        let n = 1 << finest
        let u = WebMercator.unitPoint(camera.center)
        let middle = TileAtlas.Key(level: GlobeTilePlan.mapFinest - finest, x: Int(Double(u.x) * Double(n)), y: Int(Double(u.y) * Double(n)))
        XCTAssertTrue(p.mapRequired.contains(middle))
        XCTAssertLessThanOrEqual(p.map.count, GlobeTextures.mapCapacity)
    }

    func testTheTilesAheadOfAThrowAreMadeBeforeItGetsThere() throws {
        let r = try GlobeRenderTests.renderer()
        let start = MapCamera(center: Coordinate(latitude: 30, longitude: -40), zoom: 6, pitch: 60)
        let projection = GlobeScene(camera: start, size: size).projection
        let end = projection.rotated(by: 1200, 0)
        XCTAssertGreaterThan(abs(Astronomy.wrap180(end.center.longitude - start.center.longitude)), 30, "a long throw")
        let scene = GlobeScene(camera: start, size: size)
        r.textures.prepareAndWait(for: scene)
        let deadline = Date().addingTimeInterval(20)
        let arrival = GlobeScene(camera: end, size: size)
        var ready = false
        while !ready, Date() < deadline {
            r.textures.prepare(for: scene, ahead: [end])
            let target = try XCTUnwrap(GlobeTilePlan.plan(for: arrival, satellite: true, map: false, satelliteCapacity: 99, mapCapacity: 0)
                .satelliteRequired as [TileAtlas.Key]?)
            ready = r.textures.satelliteTiles.map { atlas in target.allSatisfy { atlas.kept.contains($0) } } ?? false
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(ready, "the throw's end is sharp before the view is there")
        XCTAssertTrue(r.textures.isReady(for: scene), "and the view itself still is")
    }

    // MARK: The relief

    static let probe = #"""
    kernel void probeMesh(device float4 *out [[buffer(0)]], constant Uniforms &u [[buffer(1)]], device const float2 *points [[buffer(2)]],
                          texture2d<float> heights [[texture(0)]], sampler hs [[sampler(0)]], uint id [[thread_position_in_grid]]) {
        float3 v;
        float lonRel;
        float3 p = meshPoint(points[id], u, heights, hs, v, lonRel);
        out[2 * id] = float4(p, 0);
        out[2 * id + 1] = place(p, v, lonRel, points[id].y, u);
    }
    """#

    /// Where the vertex shader puts the mesh's vertex at a whole degree of the Earth: the raised point and its place in the view.
    func vertex(atLongitude lon: Double, latitude lat: Double, scenes: [GlobeScene]) throws -> [(point: SIMD3<Float>, clip: SIMD4<Float>)] {
        let r = try GlobeRenderTests.renderer()
        let library = try r.device.makeLibrary(source: GlobeShaders.source + Self.probe, options: nil)
        let pipeline = try r.device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "probeMesh")))
        let heights = try XCTUnwrap(r.textures.heightTexture)
        var result: [(SIMD3<Float>, SIMD4<Float>)] = []
        for scene in scenes {
            var u = r.uniforms(for: scene)
            let middle = GlobeRenderer.meshMiddle(forCenterLongitude: scene.camera.center.longitude)
            // The mesh's own vertex there: a whole number of degrees from its middle
            var point = SIMD2<Float>(Float(lon - middle), Float(lat))
            XCTAssertEqual(Double(point.x), (lon - middle).rounded(), "a vertex of the mesh")
            let out = try XCTUnwrap(r.device.makeBuffer(length: 32, options: .storageModeShared))
            let buffer = try XCTUnwrap(r.queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(buffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(out, offset: 0, index: 0)
            encoder.setBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
            encoder.setBytes(&point, length: 8, index: 2)
            encoder.setTexture(heights, index: 0)
            encoder.setSamplerState(r.heightSampler, index: 0)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            let v = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
            result.append((SIMD3(v[0].x, v[0].y, v[0].z), v[1]))
        }
        return result
    }

    func testTheReliefStaysOnTheEarthWhileTheGlobeTurns() throws {
        // Looking north at the Himalaya, the globe turned east in small steps across two of the mesh middle's steps
        let scenes = (0...48).map { k in
            GlobeScene(camera: MapCamera(center: Coordinate(latitude: 24, longitude: 86.2 + Double(k) * 0.025), zoom: 6, pitch: 60),
                       size: size)
        }
        // A vertex near Everest (28° N, 87° E)
        let probes = try vertex(atLongitude: 87, latitude: 28, scenes: scenes)
        let height = (simd_length(probes[0].point) - 1) * 6371
        XCTAssertGreaterThan(height, 20, "raised by the exaggerated relief (km)")
        for p in probes {
            XCTAssertLessThan(simd_distance(p.point, probes[0].point), 1e-6, "the same point of the Earth at the same height")
        }
        // On the screen it moves steadily the other way as the globe turns
        let xs = probes.map { Double($0.clip.x / $0.clip.w) * size.width / 2 }
        let steps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        XCTAssertTrue(steps.allSatisfy { $0 < 0 }, "always further west on the screen: \(steps)")
        let mean = steps.reduce(0, +) / Double(steps.count)
        for s in steps { XCTAssertEqual(s, mean, accuracy: abs(mean) * 0.2, "without jumps: \(steps)") }
    }

    func testTheMeshsStepIsInvisible() throws {
        // Just before and after the mesh's middle moves to the next whole degree: the same picture
        let r = try GlobeRenderTests.renderer()
        func picture(_ lon: Double) throws -> [UInt8] {
            let scene = GlobeScene(camera: MapCamera(center: Coordinate(latitude: 24, longitude: lon), zoom: 6, pitch: 60),
                                   size: CGSize(width: 600, height: 400))
            r.textures.prepareAndWait(for: scene)
            let image = try XCTUnwrap(r.snapshot(scene, scale: 1)).image
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        XCTAssertEqual(GlobeRenderer.meshMiddle(forCenterLongitude: 86.4999), 86)
        XCTAssertEqual(GlobeRenderer.meshMiddle(forCenterLongitude: 86.5001), 87)
        let a = try picture(86.4999), b = try picture(86.5001)
        let mean = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        print("Globe: the mesh's step changes the picture by \(mean) per channel")
        XCTAssertLessThan(mean, 0.5)
    }
}
