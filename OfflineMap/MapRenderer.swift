import CoreGraphics
import CoreText
import Foundation

/// A tile of the map's square grid at a zoom: x from the antimeridian
/// eastwards, y from the north; at zoom z there are 2^z × 2^z.
public struct TileKey: Hashable, Sendable {
    public var z, x, y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
}

/// Draws the bundled map with CoreGraphics and CoreText: tiles of geometry
/// (land, water, glaciers, borders, roads) up to zoom 12 from the archive's
/// tiles (up to zoom 7, enlarged beyond), and labels for a view (places from
/// the place index, seas and lakes from the tiles) placed by importance
/// without overlapping. Safe to use from several threads at once; decoded
/// tiles are kept for the next drawing.
public final class MapRenderer: @unchecked Sendable {
    public let archive: PMTilesArchive
    public let places: PlaceIndex?
    public var sourceMaxZoom: Int { archive.header.maxZoom }

    private var decoded: [TileKey: VectorTile] = [:]
    private var decodedOrder: [TileKey] = []
    private var decoding: [TileKey: NSLock] = [:]
    private let lock = NSLock()
    /// Decoded tiles kept (a dense tile at zoom 7 holds a few MB of points)
    static let decodedLimit = 40
    /// Tiles drawn for `image(of:)`, by tile, pixel size and palette: a view
    /// drawn again (the Inspector's map, a new appearance and back) draws only
    /// its labels anew
    private let viewTiles: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 96 << 20
        return cache
    }()
    /// The raster tiles the map's views made (`MapTileStore`), kept for
    /// every view of the map: a map shown again has its tiles at once
    let rasterTiles: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 192 << 20
        return cache
    }()
    let labelLines = LabelLines()

    public init(archive: PMTilesArchive, places: PlaceIndex?) {
        self.archive = archive
        self.places = places
    }

    /// The map files in the app's resources (`Map/schnellbild-map-*.pmtiles`
    /// and `Map/schnellbild-places-*.bin`, fetched by Scripts/fetch_map.sh).
    public static func bundled(in bundle: Bundle = .main) -> MapRenderer? {
        guard let urls = bundled(files: bundle), let archive = try? PMTilesArchive(url: urls.map) else { return nil }
        return MapRenderer(archive: archive, places: urls.places.flatMap { try? PlaceIndex(url: $0) })
    }

    static func bundled(files bundle: Bundle) -> (map: URL, places: URL?)? {
        guard let map = bundle.urls(forResourcesWithExtension: "pmtiles", subdirectory: "Map")?.sorted(by: { $0.path < $1.path }).last
        else { return nil }
        let places = bundle.urls(forResourcesWithExtension: "bin", subdirectory: "Map")?
            .filter { $0.lastPathComponent.hasPrefix("schnellbild-places-") }.sorted(by: { $0.path < $1.path }).last
        return (map, places)
    }

    /// The shared renderer of the bundled map (nil when the app has no map files).
    public static let shared: MapRenderer? = bundled()

    // MARK: Source tiles

    /// The archive's tile, decoded (nil where the archive has none).
    func sourceTile(_ key: TileKey) -> VectorTile? {
        lock.lock()
        if let tile = decoded[key] { lock.unlock(); return tile }
        let gate = decoding[key] ?? NSLock()
        decoding[key] = gate
        lock.unlock()
        // One thread decodes a tile; the others asking for it meanwhile wait for it
        gate.lock()
        defer { gate.unlock() }
        lock.lock()
        if let tile = decoded[key] { lock.unlock(); return tile }
        lock.unlock()
        let tile = archive.tile(z: key.z, x: key.x, y: key.y).flatMap { try? VectorTile(data: $0) }
        lock.lock()
        decoding[key] = nil
        if let tile {
            decoded[key] = tile
            decodedOrder.append(key)
            if decodedOrder.count > Self.decodedLimit { decoded[decodedOrder.removeFirst()] = nil }
        }
        lock.unlock()
        return tile
    }

    /// The source tile a tile of zoom z is drawn from, and where it lies in it.
    func source(for key: TileKey) -> (key: TileKey, sub: Int, ox: Int, oy: Int) {
        let s = min(key.z, sourceMaxZoom), d = key.z - s
        let sx = key.x >> d, sy = key.y >> d
        return (TileKey(z: s, x: sx, y: sy), 1 << d, key.x - (sx << d), key.y - (sy << d))
    }

    // MARK: Geometry

    /// Draws tile `key`'s geometry into a context whose space is the tile:
    /// 256 × 256 points, origin top left, y down. `tolerance` is the
    /// distance in the context's points below which vertices are dropped.
    /// `bleed` draws that far beyond the tile's edges (in its points), so
    /// tiles drawn side by side into one context leave no seam of half
    /// covered pixels; then the background is the caller's.
    public func drawTile(_ key: TileKey, in ctx: CGContext, palette: MapPalette, tolerance: Double = 0.5, bleed: Double = 0) {
        if bleed == 0 {
            ctx.setFillColor(palette.water.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        let n = 1 << key.z
        let wrapped = TileKey(z: key.z, x: ((key.x % n) + n) % n, y: key.y)
        guard key.y >= 0, key.y < n else { return }
        let (sourceKey, sub, ox, oy) = source(for: wrapped)
        guard let tile = sourceTile(sourceKey) else { return }
        let zoom = Double(key.z)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -bleed, y: -bleed, width: 256 + 2 * bleed, height: 256 + 2 * bleed))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // What of the source tile this tile shows (in its coordinates, with
        // room for wide lines), set per layer by `each`
        var visible = CGRect.zero
        func each(_ layerName: String, _ body: (VectorTile.Feature, Transform) -> Void) {
            guard let layer = tile.layers[layerName] else { return }
            let f = 256 * Double(sub) / layer.extent
            let transform = Transform(scale: f, dx: -Double(ox) * 256, dy: -Double(oy) * 256, tolerance: tolerance)
            let cell = layer.extent / Double(sub), margin = cell * 0.08
            visible = CGRect(x: Double(ox) * cell - margin, y: Double(oy) * cell - margin,
                                 width: cell + 2 * margin, height: cell + 2 * margin)
            for feature in layer.features where feature.bounds.intersects(visible) || feature.bounds.isEmpty && visible.contains(feature.bounds.origin) {
                body(feature, transform)
            }
        }

        // Land, glaciers, lakes and seas
        let land = CGMutablePath()
        each("earth") { feature, t in if feature.type == .polygon { t.add(feature, to: land, close: true, within: visible) } }
        ctx.setFillColor(palette.land.cgColor)
        ctx.addPath(land)
        ctx.fillPath(using: .winding)

        let ice = CGMutablePath()
        each("landuse") { feature, t in
            if feature.type == .polygon, feature["kind"]?.string == "glacier" { t.add(feature, to: ice, close: true, within: visible) }
        }
        if !ice.isEmpty {
            ctx.setFillColor(palette.glacier.cgColor)
            ctx.addPath(ice)
            ctx.fillPath(using: .winding)
            if palette.glacierOutline != palette.glacier, zoom >= 5 {
                ctx.setStrokeColor(palette.glacierOutline.cgColor)
                ctx.setLineWidth(0.6)
                ctx.addPath(ice)
                ctx.strokePath()
            }
        }

        let water = CGMutablePath(), rivers = CGMutablePath()
        each("water") { feature, t in
            switch feature.type {
            case .polygon: t.add(feature, to: water, close: true, within: visible)
            case .line:
                let kind = feature["kind"]?.string ?? ""
                if kind == "river" || (kind == "canal" && zoom >= 9) || (kind == "stream" && zoom >= 11) {
                    t.add(feature, to: rivers, close: false, within: visible)
                }
            default: break
            }
        }
        ctx.setFillColor(palette.water.cgColor)
        ctx.addPath(water)
        ctx.fillPath(using: .winding)
        if !rivers.isEmpty {
            ctx.setStrokeColor(palette.water.cgColor)
            ctx.setLineWidth(MapStyle.riverWidth(zoom))
            ctx.addPath(rivers)
            ctx.strokePath()
        }

        // Borders: regions dashed, countries solid (disputed ones dashed)
        let regions = CGMutablePath(), countries = CGMutablePath(), disputed = CGMutablePath()
        each("boundaries") { feature, t in
            let level = feature["kind_detail"]?.number ?? 0
            let kind = feature["kind"]?.string ?? ""
            let isDisputed = feature["disputed"].map { $0 == .bool(true) || $0 == .int(1) || $0.string == "yes" } ?? false
            if kind == "country" || level == 2 {
                t.add(feature, to: isDisputed ? disputed : countries, close: false, within: visible)
            } else if (kind == "region" || level == 4) && zoom >= 4 {
                t.add(feature, to: regions, close: false, within: visible)
            }
        }
        let borderScale = zoom < 4 ? 0.8 : 1
        if !regions.isEmpty {
            ctx.setStrokeColor(palette.regionBorder.cgColor)
            ctx.setLineWidth(0.8)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            ctx.addPath(regions)
            ctx.strokePath()
        }
        ctx.setStrokeColor(palette.countryBorder.cgColor)
        ctx.setLineWidth(1.2 * borderScale)
        if !disputed.isEmpty {
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addPath(disputed)
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        if !countries.isEmpty {
            ctx.addPath(countries)
            ctx.strokePath()
        }

        // Roads by class, each line part stroked on its own: one path of
        // thousands of crossing parts makes CoreGraphics resolve every
        // overlap (seconds for Tokyo)
        let factor = MapStyle.widthFactor(zoom)
        var byKind: [String: [CGPath]] = [:]
        each("roads") { feature, t in
            guard feature.type == .line, let kind = feature["kind"]?.string,
                  let style = MapStyle.roads.first(where: { $0.kind == kind }), zoom >= style.fromZoom else { return }
            for i in feature.partEnds.indices where feature.partBounds[i].intersects(visible) {
                let path = CGMutablePath()
                t.add(feature.part(i), to: path, close: false)
                if !path.isEmpty { byKind[kind, default: []].append(path) }
            }
        }
        for style in MapStyle.roads {
            guard let paths = byKind[style.kind] else { continue }
            ctx.setStrokeColor(palette[keyPath: style.color].cgColor)
            ctx.setLineWidth(style.width * factor)
            for path in paths {
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// Tile `key` as an image of 256 × 256 points at `scale` pixels per point.
    public func renderTile(_ key: TileKey, scale: CGFloat, palette: MapPalette) -> CGImage? {
        let px = Int(256 * scale)
        guard let ctx = Self.context(width: px, height: px) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: 256)
        ctx.scaleBy(x: 1, y: -1)
        drawTile(key, in: ctx, palette: palette, tolerance: 0.5)
        return ctx.makeImage()
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: MapColor.sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    // MARK: Views

    /// The tiles (at the zoom the view's geometry is drawn from) covering the
    /// viewport, with where each one's top left corner lands and its side in
    /// points. x may run outside 0 ..< 2^z (the world repeats).
    public static func tiles(for viewport: MapViewport, zoom tileZoom: Int) -> [(key: TileKey, origin: CGPoint, side: Double)] {
        let side = 256 * pow(2, viewport.camera.zoom - Double(tileZoom))
        let c = viewport.centerWorld
        let left = Double(c.x) - Double(viewport.size.width) / 2, top = Double(c.y) - Double(viewport.size.height) / 2
        let n = 1 << tileZoom
        let x0 = Int(floor(left / side)), x1 = Int(floor((left + Double(viewport.size.width)) / side))
        let y0 = max(0, Int(floor(top / side))), y1 = min(n - 1, Int(floor((top + Double(viewport.size.height)) / side)))
        guard y0 <= y1, x0 <= x1 else { return [] }
        var out: [(TileKey, CGPoint, Double)] = []
        for y in y0...y1 {
            for x in x0...x1 {
                out.append((TileKey(z: tileZoom, x: x, y: y), CGPoint(x: Double(x) * side - left, y: Double(y) * side - top), side))
            }
        }
        return out
    }

    /// The zoom of the tiles a view at `zoom` is drawn from: the whole zoom
    /// at or below it (a vector drawing is sharp at any size; the tiles of
    /// the zoom above would only add detail to draw). Raster tiles on
    /// screen take the nearest zoom (`MapTileCache`), so they are never
    /// enlarged by more than √2.
    public static func tileZoom(for zoom: Double) -> Int {
        min(Int(MapViewport.maxZoom), max(0, Int(floor(zoom + 1e-9))))
    }

    /// Draws the whole view (geometry, then labels) into a context whose
    /// space is the view: origin top left, y down.
    public func draw(_ viewport: MapViewport, in ctx: CGContext, palette: MapPalette, languages: MapLanguages = .system,
                     labels: Bool = true) {
        ctx.setFillColor(palette.water.cgColor)
        ctx.fill(CGRect(origin: .zero, size: viewport.size))
        let z = Self.tileZoom(for: viewport.camera.zoom)
        for (key, origin, side) in Self.tiles(for: viewport, zoom: z) {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            let k = side / 256
            ctx.scaleBy(x: k, y: k)
            drawTile(key, in: ctx, palette: palette, tolerance: 0.5 / k, bleed: 1 / k)
            ctx.restoreGState()
        }
        if labels { drawLabels(viewport, in: ctx, palette: palette, languages: languages) }
    }

    /// The view as an image at `scale` pixels per point.
    /// The tiles are drawn side by side on several threads, each into its
    /// own whole pixels of the view (so nothing is resampled) and kept for the
    /// next drawing at the same size, then the labels.
    public func image(of viewport: MapViewport, scale: CGFloat, palette: MapPalette, languages: MapLanguages = .system,
                      labels: Bool = true) -> CGImage? {
        let width = Int((viewport.size.width * scale).rounded()), height = Int((viewport.size.height * scale).rounded())
        guard width > 0, height > 0, let ctx = Self.context(width: width, height: height) else { return nil }
        ctx.setFillColor(palette.water.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let tiles = Self.tiles(for: viewport, zoom: Self.tileZoom(for: viewport.camera.zoom))
        let view = CGRect(x: 0, y: 0, width: width, height: height)
        // Each tile's pixels (y down from the view's top), on the pixel grid
        let rects = tiles.map { tile -> CGRect in
            let x0 = (Double(tile.origin.x) * Double(scale)).rounded(), y0 = (Double(tile.origin.y) * Double(scale)).rounded()
            let x1 = ((Double(tile.origin.x) + tile.side) * Double(scale)).rounded()
            let y1 = ((Double(tile.origin.y) + tile.side) * Double(scale)).rounded()
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        let images = UnsafeMutableBufferPointer<CGImage?>.allocate(capacity: tiles.count)
        images.initialize(repeating: nil)
        defer { images.deallocate() }
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            let r = rects[i]
            guard r.intersects(view), r.width >= 1, r.height >= 1 else { return }
            // A tile drawn at this very size before is taken as it is
            let n = 1 << tiles[i].key.z
            let name = "\(tiles[i].key.z)/\(((tiles[i].key.x % n) + n) % n)/\(tiles[i].key.y)/\(Int(r.width))x\(Int(r.height))/\(palette.isDark)" as NSString
            if let cached = viewTiles.object(forKey: name) { images[i] = cached; return }
            guard let tileContext = Self.context(width: Int(r.width), height: Int(r.height)) else { return }
            let sx = r.width / 256, sy = r.height / 256
            tileContext.translateBy(x: 0, y: r.height)
            tileContext.scaleBy(x: sx, y: -sy)
            drawTile(tiles[i].key, in: tileContext, palette: palette, tolerance: 0.5 * Double(scale) / Double(sx))
            if let image = tileContext.makeImage() {
                images[i] = image
                viewTiles.setObject(image, forKey: name, cost: image.bytesPerRow * image.height)
            }
        }
        ctx.saveGState()
        ctx.clip(to: view)
        for (i, r) in rects.enumerated() {
            guard let image = images[i] else { continue }
            ctx.draw(image, in: CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
        }
        ctx.restoreGState()
        if labels {
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: viewport.size.height)
            ctx.scaleBy(x: 1, y: -1)
            drawLabels(viewport, in: ctx, palette: palette, languages: languages)
        }
        return ctx.makeImage()
    }

    /// The labels of a view as a transparent image at `scale` pixels per point.
    public func labelImage(of viewport: MapViewport, scale: CGFloat, palette: MapPalette, languages: MapLanguages = .system,
                           avoiding: [CGRect] = []) -> CGImage? {
        guard let ctx = Self.context(width: Int(viewport.size.width * scale), height: Int(viewport.size.height * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: viewport.size.height)
        ctx.scaleBy(x: 1, y: -1)
        drawLabels(viewport, in: ctx, palette: palette, languages: languages, avoiding: avoiding)
        return ctx.makeImage()
    }
}

/// Source tile coordinates to the drawing's points, dropping vertices closer
/// than `tolerance` to the last one kept (the tiles carry far more detail
/// than a view shows; the last vertex of a part is always kept).
struct Transform {
    var scale, dx, dy, tolerance: Double

    @inline(__always) func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Double(p.x) * scale + dx, y: Double(p.y) * scale + dy)
    }

    func add(_ feature: VectorTile.Feature, to path: CGMutablePath, close: Bool) {
        for i in feature.partEnds.indices { add(feature.part(i), to: path, close: close) }
    }

    /// The parts of the feature that reach `visible` (a polygon's holes are
    /// parts too: a hole outside the visible area changes nothing inside it).
    func add(_ feature: VectorTile.Feature, to path: CGMutablePath, close: Bool, within visible: CGRect) {
        for i in feature.partEnds.indices where feature.partBounds[i].intersects(visible) {
            add(feature.part(i), to: path, close: close)
        }
    }

    func add(_ points: ArraySlice<CGPoint>, to path: CGMutablePath, close: Bool) {
        guard points.count > 1 else { return }
        var last = apply(points[points.startIndex])
        path.move(to: last)
        let lastIndex = points.endIndex - 1
        for i in (points.startIndex + 1)...lastIndex {
            let p = apply(points[i])
            if abs(p.x - last.x) + abs(p.y - last.y) >= tolerance || i == lastIndex {
                path.addLine(to: p)
                last = p
            }
        }
        if close { path.closeSubpath() }
    }
}
