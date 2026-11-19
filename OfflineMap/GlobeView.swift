import AppKit
import SwiftUI

/// The Earth as a globe in space that flattens into the offline map when
/// zooming in (`GlobeProjection`): the same camera, markers and overlay as
/// `MapView`, so what is placed on the map (the Atlas view's thumbnails and
/// clusters) is placed on the globe too; on the globe an overlay asks
/// `MapProxy.isVisible` to leave out what lies on the far side (markers do
/// so by themselves). Buttons: + / −, the tilted view (also ⌥-drag, ⌥ with
/// two fingers, two fingers turning), day and night by the Sun's place at
/// `sunDate` (now when nil), the clouds, and the relief exaggerated or at
/// true scale. Needs Metal; without it the flat map shows.
public struct GlobeView<Overlay: View>: View {
    @Binding var camera: MapCamera
    let markers: [MapMarker]
    let interactive: Bool
    let renderer: MapRenderer?
    let overlay: (MapProxy) -> Overlay
    @State private var lighting: Bool
    @State private var exaggerated: Bool
    @State private var showsClouds: Bool
    let sunDate: Date?
    @State private var link = MapLink()

    public init(camera: Binding<MapCamera>, markers: [MapMarker] = [], interactive: Bool = true,
                lighting: Bool = false, exaggerated: Bool = true, clouds: Bool = true, sunDate: Date? = nil,
                renderer: MapRenderer? = .shared, @ViewBuilder overlay: @escaping (MapProxy) -> Overlay) {
        _camera = camera
        self.markers = markers
        self.interactive = interactive
        self.renderer = renderer
        self.overlay = overlay
        _lighting = .init(initialValue: lighting)
        _exaggerated = .init(initialValue: exaggerated)
        _showsClouds = .init(initialValue: clouds)
        self.sunDate = sunDate
    }

    public var body: some View {
        MapChrome(camera: camera, markers: markers, interactive: interactive, link: link, onGlobe: true, buttonsHeight: 150,
                  surface: { keepFree, onInteraction in
                      GlobeSurface(camera: $camera, interactive: interactive, lighting: lighting, exaggerated: exaggerated,
                                   clouds: showsClouds ? 0.65 : 0, sunDate: sunDate, renderer: renderer, link: link,
                                   keepFree: keepFree, onInteraction: onInteraction)
                  },
                  buttons: { buttons }, overlay: overlay)
    }

    /// Below + / −: the tilt, day and night, the clouds, the relief.
    private var buttons: some View {
        VStack(spacing: 0) {
            mapButton(camera.pitch > 1 ? "view.2d" : "view.3d", title: camera.pitch > 1 ? "Look straight down" : "Tilt the view") {
                link.globe?.toggleTilt()
            }
            Divider().frame(width: 20)
            mapButton(lighting ? "sun.max.fill" : "sun.max", title: lighting ? "Hide day and night" : "Show day and night") { lighting.toggle() }
            Divider().frame(width: 20)
            mapButton(showsClouds ? "cloud.fill" : "cloud", title: showsClouds ? "Hide the clouds" : "Show the clouds") { showsClouds.toggle() }
            Divider().frame(width: 20)
            mapButton(exaggerated ? "mountain.2.fill" : "mountain.2",
                      title: exaggerated ? "Show the relief at true scale" : "Exaggerate the relief") { exaggerated.toggle() }
        }
        .modifier(MapButtonGroup())
    }
}

extension GlobeView where Overlay == EmptyView {
    public init(camera: Binding<MapCamera>, markers: [MapMarker] = [], interactive: Bool = true,
                lighting: Bool = false, exaggerated: Bool = true, clouds: Bool = true, sunDate: Date? = nil,
                renderer: MapRenderer? = .shared) {
        self.init(camera: camera, markers: markers, interactive: interactive, lighting: lighting, exaggerated: exaggerated,
                  clouds: clouds, sunDate: sunDate,
                  renderer: renderer) { _ in EmptyView() }
    }
}

/// The SwiftUI face of `GlobeSurfaceView`.
struct GlobeSurface: NSViewRepresentable {
    @Binding var camera: MapCamera
    let interactive: Bool
    let lighting: Bool
    let exaggerated: Bool
    let clouds: Double
    let sunDate: Date?
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
        view.clouds = clouds
        if view.date != sunDate { view.date = sunDate }
        view.keepFree = keepFree
        view.onCameraChange = { next in if camera != next { camera = next } }
        view.ownerCamera = { camera }
        view.onInteraction = onInteraction
        if view.camera != camera { view.camera = camera }
        link.globe = view
    }
}
