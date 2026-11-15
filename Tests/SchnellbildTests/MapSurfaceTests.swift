import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import OfflineMap

/// The interactive map view off screen: its tile layers and label layer
/// fill in from the tile store, follow the camera, and the SwiftUI view
/// lays out with its credit. The pictures go to MAP_SNAPSHOT_DIR as well.
@MainActor
final class MapSurfaceTests: XCTestCase {

    func renderer() throws -> MapRenderer {
        let folder = OfflineMapTests.mapFolder
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let map = try XCTUnwrap(files.first { $0.pathExtension == "pmtiles" })
        let places = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("schnellbild-places-") })
        return MapRenderer(archive: try PMTilesArchive(url: map), places: try PlaceIndex(url: places))
    }

    /// Runs the main run loop until `done` or the time is up.
    func wait(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// The view's layers as an image (CALayer's own drawing, contents included).
    func picture(of view: NSView) -> CGImage? {
        let scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx)
        return ctx.makeImage()
    }

    func save(_ image: CGImage?, _ name: String) throws {
        guard let image, let dir = ProcessInfo.processInfo.environment["MAP_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    func testTheSurfaceFillsInAndFollowsTheCamera() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let surface = MapSurfaceView(renderer: try renderer())
        window.contentView = surface
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        var reported: MapCamera?
        surface.onCameraChange = { reported = $0 }
        surface.camera = MapCamera(center: Coordinate(latitude: 62.1, longitude: 7.2), zoom: 8.4)
        func tiles() -> [CALayer] { surface.layer?.sublayers?.first?.sublayers ?? [] }
        wait(10) { !tiles().isEmpty && tiles().allSatisfy { $0.contents != nil } && surface.layer?.sublayers?.last?.contents != nil }
        XCTAssertFalse(tiles().isEmpty)
        XCTAssertTrue(tiles().allSatisfy { $0.contents != nil }, "every tile drawn")
        let labels = try XCTUnwrap(surface.layer?.sublayers?.last)
        XCTAssertNotNil(labels.contents, "the labels drawn")
        try save(picture(of: surface), "surface-geiranger")
        // Tiles cover the view without gaps
        let covered = tiles().filter { $0.zPosition == 0 }.reduce(CGRect.null) { $0.union($1.frame) }
        XCTAssertTrue(covered.contains(surface.bounds), "\(covered)")

        // Gliding one zoom in about the middle (the labels follow, then are drawn anew)
        surface.zoom(by: 1)
        wait(3) { abs(surface.camera.zoom - 9.4) < 1e-6 }
        XCTAssertEqual(surface.camera.zoom, 9.4, accuracy: 1e-6)
        XCTAssertEqual(reported?.zoom ?? 0, 9.4, accuracy: 1e-6)
        XCTAssertEqual(surface.camera.center.latitude, 62.1, accuracy: 1e-6)
        wait(10) { tiles().allSatisfy { $0.contents != nil } }
        try save(picture(of: surface), "surface-geiranger-zoomed")

        // Across the antimeridian: tiles from both sides
        surface.camera = MapCamera(center: Coordinate(latitude: -17, longitude: 180), zoom: 5)
        wait(10) { tiles().allSatisfy { $0.contents != nil } && surface.layer?.sublayers?.last?.contents != nil }
        XCTAssertTrue(tiles().allSatisfy { $0.contents != nil })
        try save(picture(of: surface), "surface-antimeridian")

        // The world fills the view's width at the smallest zoom
        surface.camera = MapCamera(center: Coordinate(latitude: 0, longitude: 0), zoom: 0)
        XCTAssertEqual(surface.viewport.clamped().zoom, MapViewport.minZoom(for: surface.bounds.size), accuracy: 1e-9)

        // The dark appearance draws the dark palette
        window.appearance = NSAppearance(named: .darkAqua)
        surface.camera = MapCamera(center: Coordinate(latitude: 48.137, longitude: 11.575), zoom: 9)
        wait(10) { tiles().allSatisfy { $0.contents != nil } && surface.layer?.sublayers?.last?.contents != nil }
        try save(picture(of: surface), "surface-munich-dark")
        XCTAssertEqual(surface.layer?.backgroundColor, MapPalette.dark.water.cgColor)
    }

    func testTheSwiftUIViewLaysOutWithItsCredit() throws {
        let renderer = try renderer()
        struct Holder: View {
            @State var camera = MapCamera(center: Coordinate(latitude: 35.68, longitude: 139.7), zoom: 9)
            let renderer: MapRenderer
            var body: some View {
                MapView(camera: $camera, markers: [MapMarker(id: "shibuya", coordinate: Coordinate(latitude: 35.658, longitude: 139.7016))],
                        renderer: renderer) { proxy in
                    // An overlay placed through the proxy, as the Atlas view's thumbnails will be
                    let p = proxy.point(for: Coordinate(latitude: 35.68, longitude: 139.7))
                    Text(verbatim: "Overlay").position(p).accessibilityIdentifier("overlay")
                }
            }
        }
        let host = NSHostingView(rootView: Holder(renderer: renderer))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        wait(3) { false }
        func find(_ view: NSView) -> MapSurfaceView? {
            if let surface = view as? MapSurfaceView { return surface }
            for sub in view.subviews { if let s = find(sub) { return s } }
            return nil
        }
        let surface = try XCTUnwrap(find(host), "the map surface is in the view")
        XCTAssertEqual(surface.frame.size, CGSize(width: 600, height: 400))
        XCTAssertEqual(surface.camera.zoom, 9, accuracy: 1e-9)
        XCTAssertEqual(surface.keepFree.count, 2, "labels keep clear of the credit and the buttons")
        try save(picture(of: host), "mapview-tokyo")
    }
}
