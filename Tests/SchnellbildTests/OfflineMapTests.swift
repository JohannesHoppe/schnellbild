import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OfflineMap

/// The offline map: the PMTiles reader and the vector tile decoder on files
/// made here, the projection, label placement, the style's contrasts, and,
/// on the bundled data (Vendor/Map, Scripts/fetch_map.sh), reverse lookups
/// and drawing with its time budgets. With MAP_SNAPSHOT_DIR set, the sample
/// views are written there as PNGs (CI keeps them as the artifact map-snapshots).
final class OfflineMapTests: XCTestCase {

    // MARK: Writing test files

    /// Protocol buffer pieces for hand-made tiles.
    struct Proto {
        var bytes: [UInt8] = []

        mutating func varint(_ v: UInt64) {
            var v = v
            while v >= 0x80 { bytes.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            bytes.append(UInt8(v))
        }
        mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }
        mutating func bytesField(_ field: Int, _ data: [UInt8]) { key(field, 2); varint(UInt64(data.count)); bytes += data }
        mutating func string(_ field: Int, _ s: String) { bytesField(field, Array(s.utf8)) }
        mutating func uint(_ field: Int, _ v: UInt64) { key(field, 0); varint(v) }
        static func zigzag(_ v: Int) -> UInt64 { UInt64(bitPattern: Int64((v << 1) ^ (v >> 63))) }
        static func packed(_ values: [UInt64]) -> [UInt8] { var p = Proto(); values.forEach { p.varint($0) }; return p.bytes }
    }

    /// A tile with a layer "water": a square polygon (kind "lake", min_zoom 3.5)
    /// and a point named "Lac", and a layer "roads" with a line of two parts.
    static func sampleTile() -> Data {
        var water = Proto()
        water.uint(15, 2)
        water.string(1, "water")
        // Polygon: MoveTo(10,10) LineTo(+20,0)(0,+20)(-20,0) ClosePath
        var polygon = Proto()
        polygon.bytesField(2, Proto.packed([0, 0, 1, 1]))   // kind=lake, min_zoom=3.5
        polygon.uint(3, 3)
        polygon.bytesField(4, Proto.packed([9, Proto.zigzag(10), Proto.zigzag(10), 26,
                                            Proto.zigzag(20), 0, 0, Proto.zigzag(20), Proto.zigzag(-20), 0, 15]))
        water.bytesField(2, polygon.bytes)
        var point = Proto()
        point.bytesField(2, Proto.packed([2, 2]))   // name=Lac
        point.uint(3, 1)
        point.bytesField(4, Proto.packed([9, Proto.zigzag(100), Proto.zigzag(200)]))
        water.bytesField(2, point.bytes)
        water.string(3, "kind"); water.string(3, "min_zoom"); water.string(3, "name")
        var lake = Proto(); lake.string(1, "lake"); water.bytesField(4, lake.bytes)
        var mz = Proto(); mz.key(3, 1); withUnsafeBytes(of: (3.5).bitPattern.littleEndian) { mz.bytes += $0 }; water.bytesField(4, mz.bytes)
        var lac = Proto(); lac.string(1, "Lac"); water.bytesField(4, lac.bytes)
        water.uint(5, 4096)

        var roads = Proto()
        roads.uint(15, 2)
        roads.string(1, "roads")
        var line = Proto()
        line.uint(3, 2)
        // Part 1: (0,0)→(5,5); part 2: (100,0)→(110,0)
        line.bytesField(4, Proto.packed([9, 0, 0, 10, Proto.zigzag(5), Proto.zigzag(5),
                                         9, Proto.zigzag(95), Proto.zigzag(-5), 10, Proto.zigzag(10), 0]))
        roads.bytesField(2, line.bytes)
        roads.uint(5, 4096)

        var tile = Proto()
        tile.bytesField(3, water.bytes)
        tile.bytesField(3, roads.bytes)
        return Data(tile.bytes)
    }

    /// gzip of the bytes (raw deflate from Compression with gzip's header and size).
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        let capacity = data.count + 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&buffer, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        out += buffer[0..<n]
        out += [0, 0, 0, 0]   // CRC32 (not checked)
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { out += $0 }
        return out
    }

    static func directory(_ entries: [(id: UInt64, run: UInt64, length: UInt64, offset: UInt64)]) -> Data {
        var p = Proto()
        p.varint(UInt64(entries.count))
        var last: UInt64 = 0
        for e in entries { p.varint(e.id - last); last = e.id }
        for e in entries { p.varint(e.run) }
        for e in entries { p.varint(e.length) }
        for (i, e) in entries.enumerated() {
            if i > 0, e.offset == entries[i - 1].offset + entries[i - 1].length { p.varint(0) } else { p.varint(e.offset + 1) }
        }
        return Data(p.bytes)
    }

    /// A PMTiles v3 archive: tiles by id (gzip), the root directory pointing at
    /// one leaf directory when `leaf` is set.
    static func archive(_ tiles: [(id: UInt64, run: UInt64, data: Data)], leaf: Bool) -> Data {
        var blob = Data(), entries: [(UInt64, UInt64, UInt64, UInt64)] = []
        for t in tiles {
            let packed = gzip(t.data)
            entries.append((t.id, t.run, UInt64(packed.count), UInt64(blob.count)))
            blob += packed
        }
        var root = gzip(directory(entries)), leaves = Data()
        if leaf {
            leaves = root
            root = gzip(directory([(0, 0, UInt64(leaves.count), 0)]))
        }
        let metadata = gzip(Data(#"{"name":"test"}"#.utf8))
        var header = Data("PMTiles".utf8) + [3]
        let rootOffset = 127, metaOffset = rootOffset + root.count, leafOffset = metaOffset + metadata.count
        let dataOffset = leafOffset + leaves.count
        for v in [rootOffset, root.count, metaOffset, metadata.count, leafOffset, leaves.count, dataOffset, blob.count, tiles.count, tiles.count, tiles.count] {
            withUnsafeBytes(of: UInt64(v).littleEndian) { header += $0 }
        }
        header += [1, 2, 2, 1, 0, 7]
        header += Data(count: 127 - header.count)
        return header + root + metadata + leaves + blob
    }

    // MARK: PMTiles

    func testTileIDsFollowTheHilbertCurve() {
        XCTAssertEqual(PMTilesArchive.tileID(z: 0, x: 0, y: 0), 0)
        XCTAssertEqual(PMTilesArchive.tileID(z: 1, x: 0, y: 0), 1)
        XCTAssertEqual(PMTilesArchive.tileID(z: 1, x: 0, y: 1), 2)
        XCTAssertEqual(PMTilesArchive.tileID(z: 1, x: 1, y: 1), 3)
        XCTAssertEqual(PMTilesArchive.tileID(z: 1, x: 1, y: 0), 4)
        XCTAssertEqual(PMTilesArchive.tileID(z: 2, x: 0, y: 0), 5)
        XCTAssertEqual(PMTilesArchive.tileID(z: 12, x: 3423, y: 1763), 19078479)   // the spec's example
    }

    func testTheReaderFindsTilesRunsAndLeaves() throws {
        let a = Data("tile zero".utf8), b = Data("tiles one to three".utf8)
        for leaf in [false, true] {
            let archive = try PMTilesArchive(data: Self.archive([(0, 1, a), (1, 3, b)], leaf: leaf))
            XCTAssertEqual(archive.header.maxZoom, 7)
            XCTAssertEqual(archive.header.tileCompression, .gzip)
            XCTAssertEqual(archive.tile(z: 0, x: 0, y: 0), a, "leaf \(leaf)")
            XCTAssertEqual(archive.tile(z: 1, x: 0, y: 0), b)   // id 1
            XCTAssertEqual(archive.tile(z: 1, x: 1, y: 1), b)   // id 3, in the run
            XCTAssertNil(archive.tile(z: 1, x: 1, y: 0))        // id 4, past the run
            XCTAssertNil(archive.tile(z: 3, x: 9, y: 0))        // outside the grid
            XCTAssertEqual(archive.metadata["name"] as? String, "test")
        }
    }

    func testMalformedArchivesAreRefusedNotTrusted() throws {
        XCTAssertThrowsError(try PMTilesArchive(data: Data("not a map".utf8)))
        var data = Self.archive([(0, 1, Data("x".utf8))], leaf: false)
        data[7] = 2
        XCTAssertThrowsError(try PMTilesArchive(data: data))
        // A directory pointing beyond the file reads as no tile
        let noise = Data((0..<500).map { UInt8(($0 * 7919) % 251) })   // packs badly: the tile's bytes are the file's end
        let short = Self.archive([(0, 1, noise)], leaf: false).dropLast(40)
        let archive = try PMTilesArchive(data: Data(short))
        XCTAssertNil(archive.tile(z: 0, x: 0, y: 0))
        // gzip that is cut short
        XCTAssertNil(Gzip.decompress(Self.gzip(Data(repeating: 1, count: 1000)).dropLast(10)))
    }

    // MARK: Vector tiles

    func testTheDecoderReadsGeometryAndProperties() throws {
        let tile = try VectorTile(data: Self.sampleTile())
        let water = try XCTUnwrap(tile.layers["water"])
        XCTAssertEqual(water.extent, 4096)
        XCTAssertEqual(water.features.count, 2)
        let polygon = water.features[0]
        XCTAssertEqual(polygon.type, .polygon)
        XCTAssertEqual(polygon["kind"], .string("lake"))
        XCTAssertEqual(polygon["min_zoom"]?.number, 3.5)
        // ClosePath repeats the first point
        XCTAssertEqual(polygon.points, [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30), CGPoint(x: 10, y: 10)])
        XCTAssertEqual(polygon.bounds, CGRect(x: 10, y: 10, width: 20, height: 20))
        XCTAssertEqual(water.features[1].type, .point)
        XCTAssertEqual(water.features[1]["name"]?.string, "Lac")
        XCTAssertEqual(water.features[1].points, [CGPoint(x: 100, y: 200)])

        let line = try XCTUnwrap(tile.layers["roads"]?.features.first)
        XCTAssertEqual(line.partEnds, [2, 4])
        XCTAssertEqual(Array(line.part(1)), [CGPoint(x: 100, y: 0), CGPoint(x: 110, y: 0)])
        XCTAssertEqual(line.partBounds[0], CGRect(x: 0, y: 0, width: 5, height: 5))
        // Only the layers asked for
        XCTAssertEqual(try VectorTile(data: Self.sampleTile(), wanted: ["roads"]).layers.keys.sorted(), ["roads"])
    }

    func testBrokenTilesThrowOrReadLessNeverCrash() {
        let whole = Self.sampleTile()
        var failures = 0
        for n in stride(from: 1, to: whole.count, by: 3) {
            if (try? VectorTile(data: whole.prefix(n))) == nil { failures += 1 }
        }
        XCTAssertGreaterThan(failures, 0)   // cut tiles fail (or read as fewer layers), never crash
        var garbage = Data(whole)
        for i in stride(from: 5, to: garbage.count, by: 7) { garbage[i] = 0xFF }
        _ = try? VectorTile(data: garbage)

        // Two points 2^63 apart (two ten-byte varints): their bounding box doesn't overflow
        var layer = Proto()
        layer.uint(15, 2)
        layer.string(1, "far")
        var feature = Proto()
        feature.uint(3, 2)
        feature.bytesField(4, Proto.packed([9, Proto.zigzag(1 << 62), 0, 10, Proto.zigzag(Int.min), 0]))
        layer.bytesField(2, feature.bytes)
        layer.uint(5, 4096)
        var tile = Proto()
        tile.bytesField(3, layer.bytes)
        let far = try? VectorTile(data: Data(tile.bytes))
        if let bounds = far?.layers["far"]?.features.first?.bounds {
            XCTAssertEqual(Double(bounds.width), pow(2, 63), accuracy: pow(2, 40))
        }
    }

    /// A place index whose unpacked block holds fewer bytes than its places
    /// need is refused when it is opened, not read past its end later.
    func testAPlaceIndexWithAShortBlockIsRefused() throws {
        func index(count: Int, stored: Int, length: Int, packed: Bool) -> Data {
            var data = Data(count: 64 + 24 + stored)
            func put(_ value: Int, at offset: Int) {
                withUnsafeBytes(of: UInt32(value).littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) }
            }
            data.replaceSubrange(0..<8, with: Data("SBPLACE1".utf8))
            put(1, at: 8)               // blocks
            put(count, at: 12)          // places
            put(360, at: 16); put(180, at: 20); put(1_000_000, at: 24)
            put(64, at: 28)             // the block table
            put(64 + 24, at: 32); put(0, at: 36)   // no countries
            put(64 + 24, at: 40); put(0, at: 44)   // no languages
            // The block: cell 0, tier 0, its places right after the table
            data[64 + 5] = packed ? 1 : 0
            put(count, at: 64 + 8); put(64 + 24, at: 64 + 12); put(stored, at: 64 + 16); put(length, at: 64 + 20)
            return data
        }
        XCTAssertThrowsError(try PlaceIndex(data: index(count: 100, stored: 16, length: 1_600, packed: false)),
                             "100 places in 16 bytes as they are stored")
        XCTAssertNotNil(try? PlaceIndex(data: index(count: 1, stored: 16, length: 16, packed: false)), "one place in its 16 bytes")
    }

    // MARK: Projection

    func testWebMercator() {
        let origin = WebMercator.unitPoint(Coordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(origin.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(origin.y, 0.5, accuracy: 1e-12)
        let corner = WebMercator.unitPoint(Coordinate(latitude: WebMercator.maxLatitude, longitude: -180))
        XCTAssertEqual(corner.x, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 0, accuracy: 1e-9)
        // Poles are held at the edge
        XCTAssertEqual(WebMercator.unitPoint(Coordinate(latitude: 90, longitude: 0)).y, 0, accuracy: 1e-9)
        XCTAssertEqual(WebMercator.unitPoint(Coordinate(latitude: -90, longitude: 0)).y, 1, accuracy: 1e-9)
        for c in [Coordinate(latitude: 48.137, longitude: 11.575), Coordinate(latitude: -33.86, longitude: 151.21), Coordinate(latitude: 62.1, longitude: -179.9)] {
            let back = WebMercator.coordinate(unit: WebMercator.unitPoint(c))
            XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-9)
            XCTAssertEqual(back.longitude, c.longitude, accuracy: 1e-9)
        }
        let munich = WebMercator.worldPoint(Coordinate(latitude: 48.137, longitude: 11.575), zoom: 10)
        XCTAssertEqual(Int(munich.x / 256), 544)   // the tile 10/544/355 holds Munich
        XCTAssertEqual(Int(munich.y / 256), 355)
        XCTAssertEqual(Coordinate(latitude: 0, longitude: 0).distance(to: Coordinate(latitude: 0, longitude: 1)), 111_195, accuracy: 10)
    }

    func testTheViewportWrapsAroundTheAntimeridian() {
        let viewport = MapViewport(camera: MapCamera(center: Coordinate(latitude: -17, longitude: 179.9), zoom: 8), size: CGSize(width: 800, height: 600))
        let east = viewport.point(for: Coordinate(latitude: -17, longitude: -179.9))
        XCTAssertGreaterThan(east.x, 400)
        XCTAssertLessThan(east.x, 800)
        let back = viewport.coordinate(at: east)
        XCTAssertEqual(back.longitude, -179.9, accuracy: 1e-6)
        let panned = MapViewport(camera: viewport.panned(by: -300, 0), size: viewport.size)
        XCTAssertLessThan(panned.camera.center.longitude, 0)   // across to the western side
    }

    func testZoomKeepsThePointUnderThePointer() {
        let viewport = MapViewport(camera: MapCamera(center: Coordinate(latitude: 48, longitude: 11), zoom: 6), size: CGSize(width: 800, height: 600))
        let anchor = CGPoint(x: 600, y: 150)
        let fixed = viewport.coordinate(at: anchor)
        let zoomed = MapViewport(camera: viewport.zoomed(to: 8, keeping: anchor), size: viewport.size)
        XCTAssertEqual(zoomed.camera.zoom, 8)
        let p = zoomed.point(for: fixed)
        XCTAssertEqual(p.x, anchor.x, accuracy: 0.01)
        XCTAssertEqual(p.y, anchor.y, accuracy: 0.01)
        // Limits: the whole world as wide as the view, at most zoom 12
        XCTAssertEqual(viewport.zoomed(to: 20, keeping: anchor).zoom, MapViewport.maxZoom)
        XCTAssertEqual(viewport.zoomed(to: -3, keeping: anchor).zoom, MapViewport.minZoom(for: viewport.size), accuracy: 1e-9)
        // The world's edge stays at the view's edge
        let top = MapViewport(camera: MapCamera(center: Coordinate(latitude: 84, longitude: 0), zoom: 3), size: viewport.size).clamped()
        XCTAssertEqual(MapViewport(camera: top, size: viewport.size).unitBounds.minY, 0, accuracy: 1e-9)
    }

    func testFittingCoordinates() throws {
        let size = CGSize(width: 800, height: 600)
        let fiji = try XCTUnwrap(MapCamera.fitting([Coordinate(latitude: -16, longitude: 179), Coordinate(latitude: -18, longitude: -179)], in: size))
        XCTAssertGreaterThan(abs(fiji.center.longitude), 179)   // over the antimeridian, not across the world
        XCTAssertGreaterThan(fiji.zoom, 5)
        let one = try XCTUnwrap(MapCamera.fitting([Coordinate(latitude: 48, longitude: 11)], in: size))
        XCTAssertEqual(one.zoom, MapViewport.maxZoom)
        let viewport = MapViewport(camera: try XCTUnwrap(MapCamera.fitting([Coordinate(latitude: 40, longitude: -5), Coordinate(latitude: 55, longitude: 25)], in: size)), size: size)
        for c in [Coordinate(latitude: 40, longitude: -5), Coordinate(latitude: 55, longitude: 25)] {
            let p = viewport.point(for: c)
            XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 39, dy: 39).contains(p), "\(p)")
        }
    }

    // MARK: Labels

    func testLabelsNeverOverlap() {
        var placer = LabelPlacer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200), keepFree: [CGRect(x: 250, y: 170, width: 50, height: 30)])
        XCTAssertTrue(placer.place(CGRect(x: 10, y: 10, width: 80, height: 14)))
        XCTAssertFalse(placer.place(CGRect(x: 60, y: 15, width: 80, height: 14)))   // overlaps the first
        XCTAssertTrue(placer.place(CGRect(x: 95, y: 10, width: 80, height: 14)))
        XCTAssertFalse(placer.place(CGRect(x: 260, y: 180, width: 20, height: 10)))  // kept free
        XCTAssertFalse(placer.place(CGRect(x: 280, y: 10, width: 40, height: 10)))   // outside
        XCTAssertEqual(placer.placed.count, 2)
        // Across grid cells (64 points)
        XCTAssertTrue(placer.place(CGRect(x: 50, y: 60, width: 100, height: 20)))
        XCTAssertFalse(placer.place(CGRect(x: 140, y: 75, width: 30, height: 20)))
    }

    func testDrawnLabelsDoNotOverlap() throws {
        let renderer = try bundledRenderer()
        let viewport = MapViewport(camera: MapCamera(center: Coordinate(latitude: 48.137, longitude: 11.575), zoom: 9), size: CGSize(width: 960, height: 640))
        let ctx = try XCTUnwrap(MapRenderer.context(width: 960, height: 640))
        let boxes = renderer.drawLabels(viewport, in: ctx, palette: .light, languages: .preferring(["de"]), avoiding: [CGRect(x: 0, y: 0, width: 200, height: 200)])
        XCTAssertGreaterThan(boxes.count, 40)
        for (i, a) in boxes.enumerated() {
            XCTAssertFalse(a.intersects(CGRect(x: 0, y: 0, width: 200, height: 200)))
            for b in boxes[(i + 1)...] where a.intersects(b) {
                // only a dot and its own text may touch
                XCTAssertLessThan(a.intersection(b).width * a.intersection(b).height, 1, "\(a) \(b)")
            }
        }
    }

    // MARK: Style

    func testThePalettesContrast() {
        for palette in [MapPalette.light, .dark] {
            let name = palette.isDark ? "dark" : "light"
            for surface in [palette.land, palette.water] {
                XCTAssertGreaterThanOrEqual(palette.label.contrast(with: surface), 4.5, name)
            }
            XCTAssertGreaterThanOrEqual(palette.mutedLabel.contrast(with: palette.land), 4.5, name)
            XCTAssertGreaterThanOrEqual(palette.waterLabel.contrast(with: palette.water), 4.5, name)
            XCTAssertGreaterThanOrEqual(palette.waterLabel.contrast(with: palette.land), 4.5, name)
            XCTAssertGreaterThanOrEqual(palette.highway.contrast(with: palette.land), 3, name)
            XCTAssertGreaterThanOrEqual(palette.countryBorder.contrast(with: palette.land), 2.9, name)
            XCTAssertGreaterThanOrEqual(palette.accent.contrast(with: palette.land), 3, name)
            XCTAssertGreaterThanOrEqual(palette.accentText.contrast(with: palette.accent), 4.5, name)
            // Land and water apart in lightness (fjords must show)
            XCTAssertGreaterThanOrEqual(palette.land.contrast(with: palette.water), 1.3, name)
        }
        // Glaciers in the light map are white on near white: they get an outline
        XCTAssertNotEqual(MapPalette.light.glacierOutline, MapPalette.light.glacier)
    }

    // MARK: The bundled data

    static let mapFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Vendor/Map")

    nonisolated(unsafe) static var shared: MapRenderer?

    func bundledRenderer() throws -> MapRenderer {
        if let shared = Self.shared { return shared }
        let files = try FileManager.default.contentsOfDirectory(at: Self.mapFolder, includingPropertiesForKeys: nil)
        let map = try XCTUnwrap(files.first { $0.pathExtension == "pmtiles" }, "Scripts/fetch_map.sh puts the map into Vendor/Map")
        let places = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("schnellbild-places-") })
        let renderer = MapRenderer(archive: try PMTilesArchive(url: map), places: try PlaceIndex(url: places))
        Self.shared = renderer
        return renderer
    }

    func testTheBundledArchive() throws {
        let renderer = try bundledRenderer()
        XCTAssertEqual(renderer.archive.header.minZoom, 0)
        XCTAssertEqual(renderer.archive.header.maxZoom, 7)
        let world = try VectorTile(data: XCTUnwrap(renderer.archive.tile(z: 0, x: 0, y: 0)))
        XCTAssertNotNil(world.layers["earth"])
        XCTAssertNotNil(world.layers["water"])
        XCTAssertNil(world.layers["pois"])
        XCTAssertEqual(renderer.archive.metadata["attribution"] as? String, "© OpenStreetMap contributors")
        let places = try XCTUnwrap(renderer.places)
        XCTAssertGreaterThan(places.placeCount, 500_000)
        XCTAssertEqual(places.languages, MapLanguages.supported)
    }

    func nearby(_ lat: Double, _ lon: Double) throws -> NearbyPlace? {
        try XCTUnwrap(bundledRenderer().places).nearby(Coordinate(latitude: lat, longitude: lon))
    }

    func testReverseLookup() throws {
        let english = MapLanguages.preferring(["en"]), us = Locale(identifier: "en_US")
        let munich = try XCTUnwrap(nearby(48.137, 11.575))
        XCTAssertEqual(munich.place.localName, "München")
        XCTAssertEqual(munich.place.label(in: english), "Munich")
        XCTAssertEqual(munich.place.label(in: .preferring(["de-DE"])), "München")
        XCTAssertEqual(munich.place.countryCode, "DE")
        XCTAssertEqual(munich.description(languages: english, locale: us), "near Munich, Germany")

        // A village far from any town: the village, not a town 20 km away
        let geiranger = try XCTUnwrap(nearby(62.1008, 7.2059))
        XCTAssertEqual(geiranger.place.localName, "Geiranger")
        XCTAssertEqual(geiranger.description(languages: english, locale: us), "near Geiranger, Norway")
        // Above it on a viewpoint, 3 km off: still Geiranger
        XCTAssertEqual(try nearby(62.081, 7.24)?.place.localName, "Geiranger")

        // Shinjuku: the city of Tokyo, the more important place a few km away
        let tokyo = try XCTUnwrap(nearby(35.6895, 139.6917))
        XCTAssertEqual(tokyo.place.countryCode, "JP")
        XCTAssertEqual(tokyo.place.label(in: english), "Tokyo")
        XCTAssertEqual(tokyo.place.label(in: .preferring(["de"])), "Tokio")
        XCTAssertEqual(tokyo.place.label(in: .preferring(["ja"])), "東京都")

        // A town next to a city keeps its own name
        XCTAssertEqual(try nearby(48.249, 11.651)?.place.localName, "Garching bei München")

        // The open sea and the poles: nothing
        XCTAssertNil(try nearby(0, -140))
        XCTAssertNil(try nearby(90, 0))
        XCTAssertNil(try nearby(-90, 0))
        XCTAssertNil(try nearby(89.99, 135))

        // Across the antimeridian: Taveuni's village lies at +179.99°
        let fiji = try XCTUnwrap(nearby(-16.80, -179.995))
        XCTAssertEqual(fiji.place.countryCode, "FJ")
        XCTAssertGreaterThan(fiji.place.coordinate.longitude, 179)
        XCTAssertLessThan(fiji.distance, 5_000)

        // Far north
        XCTAssertEqual(try nearby(78.22, 15.65)?.place.localName, "Longyearbyen")
    }

    func testLookupsAreFast() throws {
        let places = try XCTUnwrap(bundledRenderer().places)
        _ = places.nearby(Coordinate(latitude: 48, longitude: 11))
        TimeBudget.check("200 place lookups", under: 200 * 0.020) {
            for i in 0..<200 {
                _ = places.nearby(Coordinate(latitude: 40 + Double(i % 20) * 0.5, longitude: Double(i % 30) * 0.7))
            }
        }
    }

    func testLanguageCodes() {
        XCTAssertEqual(MapLanguages.code(for: "de-DE"), "de")
        XCTAssertEqual(MapLanguages.code(for: "zh-Hant-TW"), "zh-Hant")
        XCTAssertEqual(MapLanguages.code(for: "zh-TW"), "zh-Hant")
        XCTAssertEqual(MapLanguages.code(for: "zh-Hans-CN"), "zh-Hans")
        XCTAssertEqual(MapLanguages.code(for: "pt-PT"), "pt-BR")
        XCTAssertEqual(MapLanguages.code(for: "nn"), "nb")
        XCTAssertNil(MapLanguages.code(for: "ar"))
        XCTAssertEqual(MapLanguages.preferring(["ar", "fr-CA", "en"]).order, ["fr", "en"])
        XCTAssertTrue(MapLanguages.lacksLatin("東京都"))
        XCTAssertFalse(MapLanguages.lacksLatin("Zürich"))
    }

    // MARK: Drawing

    /// The views drawn for the snapshots and the time budget.
    static let samples: [(name: String, camera: MapCamera)] = [
        ("world", MapCamera(center: Coordinate(latitude: 20, longitude: 10), zoom: 1.9)),
        ("munich-country", MapCamera(center: Coordinate(latitude: 50.5, longitude: 10.5), zoom: 5.5)),
        ("munich-region", MapCamera(center: Coordinate(latitude: 48.137, longitude: 11.575), zoom: 9)),
        ("munich-city", MapCamera(center: Coordinate(latitude: 48.137, longitude: 11.575), zoom: 12)),
        ("geiranger-country", MapCamera(center: Coordinate(latitude: 64, longitude: 12), zoom: 4.8)),
        ("geiranger-region", MapCamera(center: Coordinate(latitude: 62.1, longitude: 7.1), zoom: 9.5)),
        ("geiranger-close", MapCamera(center: Coordinate(latitude: 62.1, longitude: 7.2), zoom: 11.5)),
        ("tokyo-region", MapCamera(center: Coordinate(latitude: 35.68, longitude: 139.7), zoom: 9)),
        ("tokyo-city", MapCamera(center: Coordinate(latitude: 35.68, longitude: 139.7), zoom: 11.5)),
        ("alps", MapCamera(center: Coordinate(latitude: 46.5, longitude: 9.5), zoom: 7.5)),
        ("antimeridian", MapCamera(center: Coordinate(latitude: -17, longitude: 180), zoom: 6)),
    ]

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> MapColor {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return MapColor(red: Double(p[0]) / 255, green: Double(p[1]) / 255, blue: Double(p[2]) / 255)
    }

    func testSampleViewsDrawWithinBudget() throws {
        let renderer = try bundledRenderer()
        let folder = ProcessInfo.processInfo.environment["MAP_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var report: [String] = []
        for (name, camera) in Self.samples {
            for palette in [MapPalette.light, .dark] {
                let viewport = MapViewport(camera: camera, size: CGSize(width: 960, height: 640))
                let theme = palette.isDark ? "dark" : "light"
                // The budgets (`TimeBudget`): the first time (tiles read, decoded and
                // drawn on several threads, labels laid out) under a second on the wall
                // clock; drawn again (the tiles kept, the labels laid out and drawn anew
                // on this thread) under 150 ms of CPU time, the best of five. The world
                // is the costliest view (every one-degree cell is asked for labels; the
                // place index reads a record's min_zoom before it decodes the place).
                var drawn: CGImage?
                let first = TimeBudget.check("\(name) \(theme), first", under: 1.0, runs: 1, clock: .wall) {
                    drawn = renderer.image(of: viewport, scale: 2, palette: palette, languages: .preferring(["en"]))
                }
                let image = try XCTUnwrap(drawn)
                let again = TimeBudget.check("\(name) \(theme), again", under: 0.150, runs: 5) {
                    _ = renderer.image(of: viewport, scale: 2, palette: palette, languages: .preferring(["en"]))
                }
                report.append(String(format: "%@-%@: first %.0f ms, again %.0f ms", name, theme, first * 1000, again * 1000))
                XCTAssertEqual(image.width, 1920)
                if let folder {
                    let url = folder.appendingPathComponent("\(name)-\(theme).png")
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
            }
        }
        print("map drawing:\n" + report.joined(separator: "\n"))
    }

    func testLandAndWaterWhereTheyAre() throws {
        let renderer = try bundledRenderer()
        for palette in [MapPalette.light, .dark] {
            // Bavaria west of Munich is land (most of it: a road may cross), the Atlantic west of Portugal water
            let land = try XCTUnwrap(renderer.image(of: MapViewport(camera: MapCamera(center: Coordinate(latitude: 48.0, longitude: 10.8), zoom: 8), size: CGSize(width: 64, height: 64)),
                                                    scale: 1, palette: palette, labels: false))
            let samples = [(8, 8), (56, 8), (32, 32), (8, 56), (56, 56), (20, 44), (44, 20)]
            XCTAssertGreaterThanOrEqual(samples.filter { Self.distance(Self.pixel(land, $0.0, $0.1), palette.land) < 0.05 }.count, 5)
            let sea = try XCTUnwrap(renderer.image(of: MapViewport(camera: MapCamera(center: Coordinate(latitude: 39.5, longitude: -13), zoom: 6), size: CGSize(width: 64, height: 64)),
                                                   scale: 1, palette: palette, labels: false))
            for (x, y) in samples { XCTAssertLessThan(Self.distance(Self.pixel(sea, x, y), palette.water), 0.03) }
            // Overzoom to 12 from zoom 7's tiles: a tile of Munich, land
            let tile = try XCTUnwrap(renderer.renderTile(TileKey(z: 12, x: 2179, y: 1421), scale: 2, palette: palette))
            XCTAssertEqual(tile.width, 512)
        }
    }

    static func distance(_ a: MapColor, _ b: MapColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }

    func testTilesForTheViewDrawWithinBudget() throws {
        let renderer = try bundledRenderer()
        // The interactive view: a screen's raster tiles at the zoom shown, drawn on several threads
        let viewport = MapViewport(camera: MapCamera(center: Coordinate(latitude: 35.68, longitude: 139.7), zoom: 10), size: CGSize(width: 1200, height: 800))
        let keys = MapRenderer.tiles(for: viewport, zoom: 10).map(\.key)
        _ = renderer.renderTile(keys[0], scale: 2, palette: .light)
        // Once, on the wall clock: drawn again, the tiles' decoded data would be kept
        TimeBudget.check("\(keys.count) raster tiles of Tokyo at zoom 10", under: 1.0, runs: 1, clock: .wall) {
            DispatchQueue.concurrentPerform(iterations: keys.count) { i in
                _ = renderer.renderTile(keys[i], scale: 2, palette: .light)
            }
        }
    }
}
