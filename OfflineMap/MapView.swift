import AppKit
import SwiftUI

/// A point on the map, drawn as a dot in the accent colour.
public struct MapMarker: Identifiable, Equatable, Sendable {
    public var id: String
    public var coordinate: Coordinate

    public init(id: String, coordinate: Coordinate) {
        self.id = id
        self.coordinate = coordinate
    }
}

/// What an overlay needs to place its views on the map: where a coordinate
/// is in the map view (origin top left) and back, the camera, and moving it.
/// The same for the flat `MapView` and the `GlobeView`: on the globe a
/// coordinate on the far side is not visible (`isVisible`), and a point
/// off the Earth gives the nearest place on its rim.
@MainActor
public struct MapProxy {
    public let viewport: MapViewport
    let link: MapLink
    /// Set for the globe
    var globe: GlobeProjection? = nil

    public var camera: MapCamera { viewport.camera }
    public var size: CGSize { viewport.size }

    public func point(for coordinate: Coordinate) -> CGPoint { globe?.point(for: coordinate) ?? viewport.point(for: coordinate) }

    public func coordinate(at point: CGPoint) -> Coordinate {
        guard let globe else { return viewport.coordinate(at: point) }
        if let c = globe.coordinate(at: point) { return c }
        // Off the Earth: the place on its rim in that direction
        let dx = Double(point.x - size.width / 2), dy = Double(point.y - size.height / 2), d = max(1e-9, hypot(dx, dy))
        let r = globe.radius * 0.999
        return globe.coordinate(at: CGPoint(x: Double(size.width) / 2 + dx / d * r, y: Double(size.height) / 2 + dy / d * r)) ?? camera.center
    }

    /// Whether a coordinate can be seen (on the globe: not on its far side).
    public func isVisible(_ coordinate: Coordinate) -> Bool { globe?.isVisible(coordinate) ?? true }

    /// Moves the map to the camera, gliding unless `animated` is false (or Reduce motion is on).
    public func move(to camera: MapCamera, animated: Bool = true) {
        if let globe = link.globe {
            globe.move(to: camera, animated: animated)
            return
        }
        guard let surface = link.surface else { return }
        if animated { surface.animate(to: camera) } else { surface.camera = camera; surface.onCameraChange?(surface.viewport.clamped()) }
    }

    /// Zooms in (positive) or out by whole steps about a point of the view (the middle when nil).
    public func zoom(by steps: Double, at point: CGPoint? = nil) {
        if let globe = link.globe { globe.zoom(by: steps, at: point) } else { link.surface?.zoom(by: steps, at: point) }
    }
}

/// Ties the SwiftUI view to its map surface or globe (the zoom buttons and the proxy act on it).
@MainActor
final class MapLink {
    weak var surface: MapSurfaceView?
    weak var globe: GlobeSurfaceView?
}

/// The offline map as a SwiftUI view: the bundled OpenStreetMap data, drawn
/// in the app's light or dark appearance, with the user's markers and an
/// overlay of the caller's views (thumbnails, clusters) placed through a
/// `MapProxy`. Drag or two-finger scroll moves it; pinch, ⌘-scroll, double
/// click and the + / − buttons zoom, from the whole world to about zoom 12.
/// The map data's credit sits in a corner, as the OpenStreetMap Foundation's
/// attribution guidelines allow for a small map: "© OpenStreetMap", which
/// becomes an ⓘ after 5 s or the first move; the ⓘ shows the credit with
/// a link to openstreetmap.org/copyright (the browser goes online).
public struct MapView<Overlay: View>: View {
    @Binding var camera: MapCamera
    let markers: [MapMarker]
    let interactive: Bool
    let renderer: MapRenderer?
    let overlay: (MapProxy) -> Overlay
    @State private var link = MapLink()

    public init(camera: Binding<MapCamera>, markers: [MapMarker] = [], interactive: Bool = true,
                renderer: MapRenderer? = .shared, @ViewBuilder overlay: @escaping (MapProxy) -> Overlay) {
        _camera = camera
        self.markers = markers
        self.interactive = interactive
        self.renderer = renderer
        self.overlay = overlay
    }

    public var body: some View {
        MapChrome(camera: camera, markers: markers, interactive: interactive, link: link, onGlobe: false, buttonsHeight: 76,
                  surface: { keepFree, onInteraction in
                      MapSurface(camera: $camera, interactive: interactive, renderer: renderer, link: link,
                                 keepFree: keepFree, onInteraction: onInteraction)
                  },
                  buttons: { EmptyView() }, overlay: overlay)
    }
}

extension MapView where Overlay == EmptyView {
    public init(camera: Binding<MapCamera>, markers: [MapMarker] = [], interactive: Bool = true, renderer: MapRenderer? = .shared) {
        self.init(camera: camera, markers: markers, interactive: interactive, renderer: renderer) { _ in EmptyView() }
    }
}

/// Animations of the map's own controls: none with Reduce motion.
enum Motion {
    static var animation: Animation? {
        MapMotion.reduced ? nil : .easeInOut(duration: 0.25)
    }
}

/// Whether the map and the globe move on their own (glides, a drag's throw,
/// the globe fading out over the flat map): not with Reduce motion. The UI
/// tests set `reduceOverride` (the app's `--reduce-motion`) and read what
/// moved in `counts`.
public enum MapMotion {
    /// Set: taken instead of the system's Reduce motion (set once at launch)
    nonisolated(unsafe) public static var reduceOverride: Bool?
    public static var reduced: Bool { reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where the map and the globe say what they did when (the app's test log under `--test-log`)
    nonisolated(unsafe) public static var trace: ((String) -> Void)?

    /// How often each kind of movement began ("glide", "throw", "fade"; on the main thread)
    nonisolated(unsafe) public private(set) static var counts: [String: Int] = [:]
    static func began(_ kind: String) { counts[kind, default: 0] += 1 }

    /// How far throws carried the map after the mouse came up, in points of
    /// the drag, all added up (not folded into a turn of the globe; on the main thread)
    nonisolated(unsafe) public private(set) static var thrownPoints = 0.0
    static func threw(_ points: Double) { thrownPoints += points }
}

/// The credit for the map data: "© OpenStreetMap" in the corner, an ⓘ once
/// collapsed; either opens the full credit with the link to the copyright page.
struct MapAttribution: View {
    @Binding var collapsed: Bool
    @State private var showing = false

    static let copyrightPage = URL(string: "https://www.openstreetmap.org/copyright")!

    var body: some View {
        Button { showing.toggle() } label: {
            Group {
                if collapsed {
                    Image(systemName: "info.circle").font(.system(size: 13))
                        .frame(width: 20, height: 20)
                } else {
                    Text(verbatim: "© OpenStreetMap").font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                }
            }
            .foregroundStyle(.secondary)
            .background(.regularMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("Map credits"))
        .accessibilityLabel(Text("Map credits"))
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Map data © OpenStreetMap contributors")
                Link(destination: Self.copyrightPage) { Text(verbatim: "openstreetmap.org/copyright") }
                Text("Opens in your browser (online)").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(12)
            .fixedSize()
        }
    }
}

/// The SwiftUI face of `MapSurfaceView`.
struct MapSurface: NSViewRepresentable {
    @Binding var camera: MapCamera
    let interactive: Bool
    let renderer: MapRenderer?
    let link: MapLink
    let keepFree: [CGRect]
    let onInteraction: () -> Void

    func makeNSView(context: Context) -> MapSurfaceView {
        let view = MapSurfaceView(renderer: renderer)
        view.camera = camera
        link.surface = view
        return view
    }

    func updateNSView(_ view: MapSurfaceView, context: Context) {
        view.interactive = interactive
        view.keepFree = keepFree
        view.onCameraChange = { next in if camera != next { camera = next } }
        view.ownerCamera = { camera }
        view.onInteraction = onInteraction
        if view.camera != camera { view.camera = camera }
        link.surface = view
    }
}
