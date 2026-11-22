import SwiftUI

/// What the flat map and the globe show around their surface: the markers
/// (none on the globe's far side) and the caller's overlay on it, the credit
/// in the bottom corner (an ⓘ after 5 s or the first move), + / − and the
/// view's own buttons below them in the top corner. The labels keep clear
/// of both corners.
struct MapChrome<Surface: View, Buttons: View, Overlay: View>: View {
    let camera: MapCamera
    let markers: [MapMarker]
    let interactive: Bool
    let link: MapLink
    /// Whether the proxy places on the globe
    let onGlobe: Bool
    /// How far down the buttons reach
    let buttonsHeight: CGFloat
    /// The map or the globe, given the boxes its labels keep clear of and
    /// what the user's first move calls
    let surface: (_ keepFree: [CGRect], _ onInteraction: @escaping () -> Void) -> Surface
    let buttons: () -> Buttons
    let overlay: (MapProxy) -> Overlay
    @State private var attributionCollapsed = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mapZoomKeys) private var zoomKeys

    init(camera: MapCamera, markers: [MapMarker], interactive: Bool, link: MapLink, onGlobe: Bool, buttonsHeight: CGFloat,
         @ViewBuilder surface: @escaping (_ keepFree: [CGRect], _ onInteraction: @escaping () -> Void) -> Surface,
         @ViewBuilder buttons: @escaping () -> Buttons, overlay: @escaping (MapProxy) -> Overlay) {
        self.camera = camera
        self.markers = markers
        self.interactive = interactive
        self.link = link
        self.onGlobe = onGlobe
        self.buttonsHeight = buttonsHeight
        self.surface = surface
        self.buttons = buttons
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let proxy = MapProxy(viewport: MapViewport(camera: camera, size: size), link: link,
                                 globe: onGlobe ? GlobeProjection(camera: camera, size: size) : nil)
            ZStack(alignment: .topLeading) {
                surface(keepFree(in: size)) { withAnimation(Motion.animation) { attributionCollapsed = true } }
                markerLayer(proxy)
                overlay(proxy)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomTrailing) {
                MapAttribution(collapsed: $attributionCollapsed).padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if interactive { allButtons.padding(8) }
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
        if interactive { boxes.append(CGRect(x: size.width - 44, y: 0, width: 44, height: buttonsHeight)) }
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

    private var allButtons: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                mapButton("plus", title: "Zoom in", keys: zoomKeys.zoomIn) { zoom(by: 1) }
                Divider().frame(width: 20)
                mapButton("minus", title: "Zoom out", keys: zoomKeys.zoomOut) { zoom(by: -1) }
            }
            .modifier(MapButtonGroup())
            buttons()
        }
    }

    private func zoom(by steps: Double) {
        if let globe = link.globe { globe.zoom(by: steps) } else { link.surface?.zoom(by: steps) }
    }
}

/// A button of the map's groups; `title` is its help and VoiceOver label
/// (the label "title:" is what LocalizationTests' scanner reads), the help
/// followed by its keys where it has any.
@MainActor
func mapButton(_ symbol: String, title: LocalizedStringKey, keys: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).frame(width: 28, height: 26).contentShape(Rectangle())
    }
    .help(keys.flatMap { $0.isEmpty ? nil : Text("\(Text(title)) (\($0))") } ?? Text(title))
    .accessibilityLabel(Text(title))
}

/// The keys of the map's + and − where the view that shows it has them
/// (the Atlas), as plain text; nil: none named.
public struct MapZoomKeys: Equatable, Sendable {
    public var zoomIn: String?
    public var zoomOut: String?
    public init(zoomIn: String? = nil, zoomOut: String? = nil) {
        self.zoomIn = zoomIn
        self.zoomOut = zoomOut
    }
}

private struct MapZoomKeysKey: EnvironmentKey {
    static let defaultValue = MapZoomKeys()
}

extension EnvironmentValues {
    /// The keys the map's + and − name in their tooltips.
    public var mapZoomKeys: MapZoomKeys {
        get { self[MapZoomKeysKey.self] }
        set { self[MapZoomKeysKey.self] = newValue }
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
