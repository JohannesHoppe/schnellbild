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
@MainActor
public struct MapProxy {
    public let viewport: MapViewport
    fileprivate let link: MapLink

    public var camera: MapCamera { viewport.camera }
    public var size: CGSize { viewport.size }

    public func point(for coordinate: Coordinate) -> CGPoint { viewport.point(for: coordinate) }
    public func coordinate(at point: CGPoint) -> Coordinate { viewport.coordinate(at: point) }

    /// Moves the map to the camera, gliding unless `animated` is false (or Reduce motion is on).
    public func move(to camera: MapCamera, animated: Bool = true) {
        guard let surface = link.surface else { return }
        if animated { surface.animate(to: camera) } else { surface.camera = camera; surface.onCameraChange?(surface.viewport.clamped()) }
    }

    /// Zooms in (positive) or out by whole steps about a point of the view (the middle when nil).
    public func zoom(by steps: Double, at point: CGPoint? = nil) { link.surface?.zoom(by: steps, at: point) }
}

/// Ties the SwiftUI view to its map surface (the zoom buttons and the proxy act on it).
@MainActor
final class MapLink {
    weak var surface: MapSurfaceView?
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
    @State private var attributionCollapsed = false
    @Environment(\.colorScheme) private var colorScheme

    public init(camera: Binding<MapCamera>, markers: [MapMarker] = [], interactive: Bool = true,
                renderer: MapRenderer? = .shared, @ViewBuilder overlay: @escaping (MapProxy) -> Overlay) {
        _camera = camera
        self.markers = markers
        self.interactive = interactive
        self.renderer = renderer
        self.overlay = overlay
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let proxy = MapProxy(viewport: MapViewport(camera: camera, size: size), link: link)
            ZStack(alignment: .topLeading) {
                MapSurface(camera: $camera, interactive: interactive, renderer: renderer, link: link,
                           keepFree: keepFree(in: size),
                           onInteraction: { withAnimation(Motion.animation) { attributionCollapsed = true } })
                markerLayer(proxy)
                overlay(proxy)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomTrailing) {
                MapAttribution(collapsed: $attributionCollapsed).padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if interactive { zoomButtons.padding(8) }
            }
            .clipped()
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(Motion.animation) { attributionCollapsed = true }
        }
    }

    /// Where labels stay away: the credit and the buttons.
    private func keepFree(in size: CGSize) -> [CGRect] {
        var boxes = [CGRect(x: size.width - 130, y: size.height - 30, width: 130, height: 30)]
        if interactive { boxes.append(CGRect(x: size.width - 44, y: 0, width: 44, height: 76)) }
        return boxes
    }

    private func markerLayer(_ proxy: MapProxy) -> some View {
        let palette = MapPalette.appearance(dark: colorScheme == .dark)
        return ForEach(markers) { marker in
            Circle()
                .fill(Color(cgColor: palette.accent.cgColor))
                .overlay(Circle().stroke(Color(cgColor: (palette.isDark ? MapColor("#121212") : MapColor("#ffffff")).cgColor), lineWidth: 2))
                .frame(width: 12, height: 12)
                .position(proxy.point(for: marker.coordinate))
        }
        .allowsHitTesting(false)
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            Button { link.surface?.zoom(by: 1) } label: {
                Image(systemName: "plus").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .help(Text("Zoom in"))
            .accessibilityLabel(Text("Zoom in"))
            Divider().frame(width: 20)
            Button { link.surface?.zoom(by: -1) } label: {
                Image(systemName: "minus").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .help(Text("Zoom out"))
            .accessibilityLabel(Text("Zoom out"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 0.5))
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
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.25)
    }
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
