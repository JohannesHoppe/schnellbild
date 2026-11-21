import CoreGraphics
import Foundation
import Metal

/// Square tiles of one size kept in the slices of one texture array (each
/// with its own mipmaps), with an index texture the fragment shader looks
/// them up in: per level of tiles (the index texture's mip levels: level 0
/// the finest) and tile, the slice holding it plus one, 0 for none. A tile
/// is made once (`request`: off the calling thread, the most wanted first)
/// and kept until its slice is needed for a tile wanted now (the one wanted
/// longest ago goes), so moving the view makes only the tiles that come into
/// it. A slice is taken out of the index before a new tile is copied into
/// it and put in once the copy is done, so a frame never shows a tile half
/// copied or in the wrong place.
final class TileAtlas: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        /// The index texture's mip level (0: the finest tiles)
        var level: Int
        var x, y: Int
    }

    let side: Int
    let capacity: Int
    /// The index's size at level 0 (tiles across, down)
    let columns, rows: Int
    let levels: Int
    let slots: MTLTexture
    let index: MTLTexture
    /// Bytes the atlas holds (the slices with their mipmaps, the index)
    let bytes: Int

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let make: (Key) -> CGContext?
    private let changed: () -> Void
    private let lock = NSLock()
    private let work: OperationQueue
    private var resident: [Key: Int] = [:]
    private var slotKey: [Key?]
    /// When each tile was last wanted (`stamp` of that request)
    private var lastWanted: [Key: Int] = [:]
    private var stamp = 0
    private var wanted: Set<Key> = []
    private var queued: [Key: Operation] = [:]
    private var running: Set<Key> = []
    /// Tiles that can't be made (not in the data): never asked for again
    private var missing: Set<Key> = []
    /// How many tiles were made (tests)
    private(set) var madeCount = 0
    private(set) var madeKeys: [Key] = []

    /// `make` draws a tile into a context of `side` × `side` pixels (BGRA,
    /// premultiplied, the first row the tile's top), nil when there is none;
    /// it runs on up to `concurrency` threads at once. `changed` reports a
    /// tile that came into the index.
    init?(device: MTLDevice, queue: MTLCommandQueue, side: Int, capacity: Int, columns: Int, rows: Int, levels: Int, concurrency: Int,
          name: String, make: @escaping (Key) -> CGContext?, changed: @escaping () -> Void) {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = GlobeRenderer.colorFormat
        d.width = side
        d.height = side
        d.arrayLength = capacity
        d.mipmapLevelCount = Self.mipLevels(side)
        d.usage = .shaderRead
        d.storageMode = .private
        let i = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: columns, height: rows, mipmapped: levels > 1)
        i.mipmapLevelCount = levels
        i.usage = .shaderRead
        i.storageMode = .shared
        guard let slots = device.makeTexture(descriptor: d), let index = device.makeTexture(descriptor: i) else { return nil }
        slots.label = name
        self.device = device
        self.queue = queue
        self.side = side
        self.capacity = capacity
        self.columns = columns
        self.rows = rows
        self.levels = levels
        self.slots = slots
        self.index = index
        self.make = make
        self.changed = changed
        slotKey = Array(repeating: nil, count: capacity)
        work = OperationQueue()
        work.name = name
        work.maxConcurrentOperationCount = concurrency
        work.qualityOfService = .userInitiated
        var mipBytes = 0, s = side
        for _ in 0..<d.mipmapLevelCount { mipBytes += s * s * 4; s = max(1, s / 2) }
        bytes = mipBytes * capacity + columns * rows * 2 * 4 / 3
        for level in 0..<levels {
            let w = max(1, columns >> level), h = max(1, rows >> level)
            let zeros = [UInt16](repeating: 0, count: w * h)
            index.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level, withBytes: zeros, bytesPerRow: w * 2)
        }
    }

    static func mipLevels(_ side: Int) -> Int { Int(log2(Double(side))) + 1 }

    /// Starts making the tiles wanted (most wanted first) that aren't kept
    /// or under way; tiles queued earlier and no longer wanted are dropped.
    /// At most `capacity` are kept: the rest of the list is left out.
    func request(_ list: [Key]) {
        let list = Array(list.prefix(capacity))
        lock.lock()
        stamp += 1
        wanted = Set(list)
        for key in list { lastWanted[key] = stamp }
        for (key, op) in queued where !wanted.contains(key) {
            op.cancel()
            queued[key] = nil
        }
        var start: [(Key, Operation)] = []
        for key in list where resident[key] == nil && queued[key] == nil && !running.contains(key) && !missing.contains(key) {
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, unowned op] in
                guard !op.isCancelled else { return }
                self?.makeTile(key, op)
            }
            queued[key] = op
            start.append((key, op))
        }
        lock.unlock()
        for (_, op) in start { work.addOperation(op) }
    }

    /// Whether every one of the tiles is kept (or can't be made).
    func has(_ keys: [Key]) -> Bool {
        lock.withLock { keys.prefix(capacity).allSatisfy { resident[$0] != nil || missing.contains($0) } }
    }

    /// The tiles kept now (tests).
    var kept: Set<Key> { lock.withLock { Set(resident.keys) } }

    /// Waits until no tile is being made (tests).
    func waitUntilIdle() { work.waitUntilAllOperationsAreFinished() }

    private func makeTile(_ key: Key, _ op: Operation) {
        // A slice: a free one, else the one whose tile was wanted longest ago and isn't wanted now
        let slot: Int? = lock.withLock {
            if queued[key] === op { queued[key] = nil }
            guard wanted.contains(key), resident[key] == nil, !running.contains(key) else { return nil }
            var slot = slotKey.firstIndex { $0 == nil }
            if slot == nil {
                var oldest = Int.max
                for (k, s) in resident where !wanted.contains(k) {
                    let t = lastWanted[k] ?? 0
                    if t < oldest { oldest = t; slot = s }
                }
            }
            guard let slot else { return nil }
            if let old = slotKey[slot] {
                resident[old] = nil
                lastWanted[old] = nil
                setIndex(old, 0)
            }
            slotKey[slot] = key
            running.insert(key)
            return slot
        }
        guard let slot else { return }
        guard let ctx = make(key), let data = ctx.data, let staging = staging(), let buffer = queue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder() else {
            lock.withLock {
                running.remove(key)
                if slotKey[slot] == key { slotKey[slot] = nil }
                missing.insert(key)
            }
            return
        }
        staging.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        blit.generateMipmaps(for: staging)
        blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0, to: slots, destinationSlice: slot, destinationLevel: 0,
                  sliceCount: 1, levelCount: slots.mipmapLevelCount)
        blit.endEncoding()
        buffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let shown: Bool = self.lock.withLock {
                self.running.remove(key)
                guard self.slotKey[slot] == key else { return false }
                self.resident[key] = slot
                self.setIndex(key, UInt16(slot + 1))
                self.madeCount += 1
                self.madeKeys.append(key)
                return true
            }
            if shown { self.changed() }
        }
        buffer.commit()
    }

    private func staging() -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GlobeRenderer.colorFormat, width: side, height: side, mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// (under the lock)
    private func setIndex(_ key: Key, _ value: UInt16) {
        var v = value
        index.replace(region: MTLRegionMake2D(key.x, key.y, 1, 1), mipmapLevel: key.level, withBytes: &v, bytesPerRow: 2)
    }
}

/// Which tiles a view of the globe needs, worked out from the view itself:
/// points a few dozen apart over the view (and a margin around it) are
/// placed on the Earth through the projection, and how much ground lies
/// under one pixel there (on the screen's pixels, 2 per point; the shorter
/// way, as the GPU's anisotropic filtering samples, at most 8 : 1) says the
/// coarsest tiles that are still sharp: the satellite picture's whole-Earth
/// texture, its level 1 (45° tiles) or level 2 (22.5° tiles); the map's
/// world texture (zoom 3) or its tiles at zoom 4 … 6. The view's own tiles
/// come first (the coarser before the finer, then by the distance from the
/// view's middle), then the margin's, then those of the cameras ahead
/// (where a throw or a drag is carrying the view).
enum GlobeTilePlan {
    struct Plan: Sendable {
        /// The view's own tiles (all of them shown: the scene is ready)
        var satelliteRequired: [TileAtlas.Key] = []
        var mapRequired: [TileAtlas.Key] = []
        /// Everything to keep, the most wanted first
        var satellite: [TileAtlas.Key] = []
        var map: [TileAtlas.Key] = []
    }

    /// The satellite tiles: level 0 of the index the 16 × 8 tiles of 22.5°, level 1 the 8 × 4 of 45°
    static let satelliteColumns = 16, satelliteRows = 8, satelliteLevels = 2
    /// Degrees per texel: the whole-Earth texture (2700 px), level 1, level 2 (1350 px tiles)
    static let satelliteTexels = (base: 360.0 / 2700, level1: 45.0 / 1350, level2: 22.5 / 1350)
    /// The map's tiles: zoom `mapFinest` at level 0 of the index, down to zoom 4
    static let mapFinest = 6, mapLevels = 3
    /// Pixels per tile of the map (256 points at 2×)
    static let mapTileSide = 512

    /// From this flatness on the satellite picture's share is small enough for its whole-Earth texture
    static let satelliteFlatness = 0.85

    /// The margin around the view, as a share of its size on each side
    static let margin = 0.15

    struct Sample {
        var coordinate: Coordinate
        /// Ground under a pixel: degrees (the satellite picture), the Mercator square's units (the map)
        var degrees: Double
        var mercator: Double
        var distance: Double
        var inView: Bool
    }

    /// The view's points on the Earth with the ground under a pixel there.
    static func samples(of projection: GlobeProjection, margin: Double, offset: Double = 0) -> [Sample] {
        let w = Double(projection.size.width), h = Double(projection.size.height)
        guard w > 0, h > 0 else { return [] }
        // About 2 500 points; 1 200 while the globe flattens, where each is found by Newton's method
        let step = max(24, (w * h / (projection.flatness > 0 ? 1200 : 2500)).squareRoot())
        // Points on the view's corner and a whole number of steps from it, so the view's own are the same with any margin
        let before = (margin * w / step).rounded(.up), above = (margin * h / step).rounded(.up)
        let x0 = -before * step, y0 = -above * step
        let cols = Int(before + ((1 + margin) * w / step).rounded(.up)), rows = Int(above + ((1 + margin) * h / step).rounded(.up))
        var grid = [Coordinate?](repeating: nil, count: (cols + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...cols {
                grid[j * (cols + 1) + i] = projection.coordinate(at: CGPoint(x: x0 + Double(i) * step, y: y0 + Double(j) * step))
            }
        }
        let pixels = step * 2
        func apart(_ a: Coordinate, _ b: Coordinate) -> (Double, Double) {
            let dLon = Astronomy.wrap180(b.longitude - a.longitude), dLat = b.latitude - a.latitude
            let ua = WebMercator.unitPoint(a), ub = WebMercator.unitPoint(b)
            var dx = Double(ub.x - ua.x)
            dx -= dx.rounded()
            return (hypot(dLon, dLat) / pixels, hypot(dx, Double(ub.y - ua.y)) / pixels)
        }
        var out: [Sample] = []
        out.reserveCapacity(grid.count)
        for j in 0...rows {
            for i in 0...cols {
                guard let c = grid[j * (cols + 1) + i] else { continue }
                func at(_ i: Int, _ j: Int) -> Coordinate? {
                    guard i >= 0, i <= cols, j >= 0, j <= rows else { return nil }
                    return grid[j * (cols + 1) + i]
                }
                guard let across = at(i + 1, j) ?? at(i - 1, j), let down = at(i, j + 1) ?? at(i, j - 1) else { continue }
                let a = apart(c, across), d = apart(c, down)
                func footprint(_ p: Double, _ q: Double) -> Double { max(min(p, q), max(p, q) / 8) }
                let x = x0 + Double(i) * step, y = y0 + Double(j) * step
                out.append(Sample(coordinate: c, degrees: footprint(a.0, d.0), mercator: footprint(a.1, d.1),
                                  distance: hypot(x - w / 2, y - h / 2) + offset, inView: x >= 0 && x <= w && y >= 0 && y <= h))
            }
        }
        return out
    }

    /// The satellite tile a sample needs (nil: the whole-Earth texture is
    /// sharp enough there). While the globe flattens the map's colours take
    /// over: past half way level 1 is enough, and from `satelliteFlatness` none.
    static func satelliteTile(_ s: Sample, flatness: Double = 0) -> TileAtlas.Key? {
        let t = satelliteTexels
        guard s.degrees < t.base, flatness < satelliteFlatness else { return nil }
        let level = s.degrees < t.level1 && flatness <= 0.5 ? 0 : 1
        let cols = satelliteColumns >> level, rows = satelliteRows >> level
        let u = (s.coordinate.longitude + 180) / 360, v = (90 - s.coordinate.latitude) / 180
        let x = min(cols - 1, max(0, Int(u * Double(cols)))), y = min(rows - 1, max(0, Int(v * Double(rows))))
        return TileAtlas.Key(level: level, x: x, y: y)
    }

    /// The map tile a sample needs at most at zoom `finest` (nil: the world texture is sharp enough there).
    static func mapTile(_ s: Sample, finest: Int) -> TileAtlas.Key? {
        let zoom = min(finest, Int((log2(1 / (Double(mapTileSide) * max(s.mercator, 1e-12))) - 0.05).rounded(.up)))
        guard zoom > GlobeTextures.baseZoom else { return nil }
        let z = max(mapFinest - mapLevels + 1, zoom)
        let n = 1 << z
        let u = WebMercator.unitPoint(s.coordinate)
        let x = min(n - 1, max(0, Int(Double(u.x) * Double(n)))), y = min(n - 1, max(0, Int(Double(u.y) * Double(n))))
        return TileAtlas.Key(level: mapFinest - z, x: x, y: y)
    }

    /// The map's finest zoom for a view: the zoom shown rounded up, at most the flat zoom's (and `mapFinest`).
    static func finestMapZoom(for projection: GlobeProjection) -> Int {
        min(mapFinest, Int((projection.flatZoom - 1e-9).rounded(.up)), Int((projection.camera.zoom - 1e-9).rounded(.up)))
    }

    static func plan(for scene: GlobeScene, ahead: [MapCamera] = [], satellite: Bool, map: Bool,
                     satelliteCapacity: Int, mapCapacity: Int) -> Plan {
        var plan = Plan()
        let projection = scene.projection
        let flatness = projection.flatness
        let wantsSatellite = satellite && flatness < satelliteFlatness
        guard wantsSatellite || map else { return plan }
        var samples = samples(of: projection, margin: margin)
        for (k, camera) in ahead.enumerated() {
            var s = scene
            s.camera = camera
            // After every sample of the view itself
            samples += Self.samples(of: s.projection, margin: 0, offset: 1e6 * Double(k + 1)).map { var a = $0; a.inView = false; return a }
        }
        func ordered(_ tile: (Sample) -> TileAtlas.Key?, capacity: Int) -> (required: [TileAtlas.Key], all: [TileAtlas.Key]) {
            var best: [TileAtlas.Key: (inView: Bool, distance: Double)] = [:]
            for s in samples {
                guard let key = tile(s) else { continue }
                let rank = (inView: s.inView, distance: s.inView ? s.distance : s.distance + 1e5)
                if let have = best[key], have.distance <= rank.distance { continue }
                best[key] = rank
            }
            // The view's own tiles first, the coarser before the finer, then by the distance from the middle
            let sorted = best.sorted { a, b in
                if a.value.inView != b.value.inView { return a.value.inView }
                if a.value.inView, a.key.level != b.key.level { return a.key.level > b.key.level }
                return a.value.distance < b.value.distance
            }
            let all = Array(sorted.prefix(capacity))
            return (all.filter { best[$0.key]!.inView }.map(\.key), all.map(\.key))
        }
        if wantsSatellite {
            let s = ordered({ satelliteTile($0, flatness: flatness) }, capacity: satelliteCapacity)
            plan.satelliteRequired = s.required
            plan.satellite = s.all
        }
        if map {
            let finest = finestMapZoom(for: projection)
            let m = ordered({ mapTile($0, finest: finest) }, capacity: mapCapacity)
            plan.mapRequired = m.required
            plan.map = m.all
        }
        return plan
    }
}
