import AppKit
import SwiftUI

/// The Earth as a globe in space that flattens into the offline map when
/// zooming in (`GlobeProjection`): the same camera, markers and overlay as
/// `MapView`, so what is placed on the map (the Atlas view's thumbnails and
/// clusters) is placed on the globe too; on the globe an overlay asks
/// `MapProxy.isVisible` to leave out what lies on the far side (markers do
/// so by themselves). Buttons: + / −, day and night by the Sun's place now,
/// and the relief exaggerated or at true scale. Needs Metal; without it the
/// flat map shows.
public struct GlobeView<Overlay: View>: View {
    @Binding var camera: MapCamera
    let markers: [MapMarker]
    let interactive: Bool
    let renderer: MapRenderer?
    let overlay: (MapProxy) -> Overlay
    @State private var lighting: Bool
    @State private var exaggerated: Bool
    @State private var link = MapLink()
    @State private var attributionCollapsed = false
    @Environment(\.colorScheme) private var colorScheme

    public init(camera: Binding<MapCamera>, markers: [MapMarker] = [], interactive: Bool = true,
                lighting: Bool = false, exaggerated: Bool = true,
                renderer: MapRenderer? = .shared, @ViewBuilder overlay: @escaping (MapProxy) -> Overlay) {
        _camera = camera
        self.markers = markers
        self.interactive = interactive
        self.renderer = renderer
        self.overlay = overlay
        _lighting = .init(initialValue: lighting)
        _exaggerated = .init(initialValue: exaggerated)
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let proxy = MapProxy(viewport: MapViewport(camera: camera, size: size), link: link,
                                 globe: GlobeProjection(camera: camera, size: size))
            ZStack(alignment: .topLeading) {
                GlobeSurface(camera: $camera, interactive: interactive, lighting: lighting, exaggerated: exaggerated,
                             renderer: renderer, link: link, keepFree: keepFree(in: size),
                             onInteraction: { withAnimation(Motion.animation) { attributionCollapsed = true } })
                markerLayer(proxy)
                overlay(proxy)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomTrailing) {
                MapAttribution(collapsed: $attributionCollapsed).padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if interactive { buttons.padding(8) }
            }
            .clipped()
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(Motion.animation) { attributionCollapsed = true }
        }
    }

    private func keepFree(in size: CGSize) -> [CGRect] {
        var boxes = [CGRect(x: size.width - 130, y: size.height - 30, width: 130, height: 30)]
        if interactive { boxes.append(CGRect(x: size.width - 44, y: 0, width: 44, height: 150)) }
        return boxes
    }

    private func markerLayer(_ proxy: MapProxy) -> some View {
        let palette = MapPalette.appearance(dark: colorScheme == .dark)
        return ForEach(markers.filter { proxy.isVisible($0.coordinate) }) { marker in
            Circle()
                .fill(Color(cgColor: palette.accent.cgColor))
                .overlay(Circle().stroke(Color(cgColor: (palette.isDark ? MapColor("#121212") : MapColor("#ffffff")).cgColor), lineWidth: 2))
                .frame(width: 12, height: 12)
                .position(proxy.point(for: marker.coordinate))
        }
        .allowsHitTesting(false)
    }

    private func button(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                button("plus", "Zoom in") { link.globe?.zoom(by: 1) }
                Divider().frame(width: 20)
                button("minus", "Zoom out") { link.globe?.zoom(by: -1) }
            }
            .modifier(MapButtonGroup())
            VStack(spacing: 0) {
                button(lighting ? "sun.max.fill" : "sun.max", lighting ? "Hide day and night" : "Show day and night") { lighting.toggle() }
                Divider().frame(width: 20)
                button(exaggerated ? "mountain.2.fill" : "mountain.2",
                       exaggerated ? "Show the relief at true scale" : "Exaggerate the relief") { exaggerated.toggle() }
            }
            .modifier(MapButtonGroup())
        }
    }
}

extension GlobeView where Overlay == EmptyView {
    public init(camera: Binding<MapCamera>, markers: [MapMarker] = [], interactive: Bool = true,
                lighting: Bool = false, exaggerated: Bool = true, renderer: MapRenderer? = .shared) {
        self.init(camera: camera, markers: markers, interactive: interactive, lighting: lighting, exaggerated: exaggerated,
                  renderer: renderer) { _ in EmptyView() }
    }
}

/// The look of the map's button groups: small, on material, outlined.
struct MapButtonGroup: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 0.5))
    }
}

/// The SwiftUI face of `GlobeSurfaceView`.
struct GlobeSurface: NSViewRepresentable {
    @Binding var camera: MapCamera
    let interactive: Bool
    let lighting: Bool
    let exaggerated: Bool
    let renderer: MapRenderer?
    let link: MapLink
    let keepFree: [CGRect]
    let onInteraction: () -> Void

    func makeNSView(context: Context) -> GlobeSurfaceView {
        let view = GlobeSurfaceView(map: renderer)
        view.camera = camera
        link.globe = view
        return view
    }

    func updateNSView(_ view: GlobeSurfaceView, context: Context) {
        view.interactive = interactive
        view.lighting = lighting
        view.exaggerated = exaggerated
        view.keepFree = keepFree
        view.onCameraChange = { next in if camera != next { camera = next } }
        view.onInteraction = onInteraction
        if view.camera != camera { view.camera = camera }
        link.globe = view
    }
}
