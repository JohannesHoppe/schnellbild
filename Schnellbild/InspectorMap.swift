import SwiftUI
import OfflineMap

/// The Inspector's offline map and place names from the map data the app
/// carries (`MapRenderer.shared`: the tiles and the place index): a small
/// map around the photo's place with a marker, and "near Geiranger,
/// Norway" from `PlaceIndex.nearby`. Nothing goes online.
struct BundledGeography: OfflineGeographyProvider {
    let renderer: MapRenderer

    /// Nil without the map data (a build without `Vendor/Map`).
    static func make(renderer: MapRenderer? = .shared) -> BundledGeography? {
        renderer.map(BundledGeography.init)
    }

    /// The zoom the Inspector's map starts at: the town and its valley.
    static let zoom = 9.0

    func placeName(near point: GeoPoint) async -> String? {
        guard let places = renderer.places else { return nil }
        let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)
        // The index unpacks its cells on first use: off the main thread
        return await Blocking.run(.userInitiated) { places.nearby(coordinate)?.description() }
    }

    @MainActor func map(around point: GeoPoint) -> AnyView? {
        AnyView(InspectorMap(point: point, renderer: renderer))
    }
}

/// A small map that doesn't take the sidebar's scrolling: centred on the
/// place, with its marker; the camera follows the item shown.
struct InspectorMap: View {
    let point: GeoPoint
    let renderer: MapRenderer
    @State private var camera: MapCamera

    init(point: GeoPoint, renderer: MapRenderer) {
        self.point = point
        self.renderer = renderer
        _camera = State(initialValue: Self.camera(for: point))
    }

    static func camera(for point: GeoPoint) -> MapCamera {
        MapCamera(center: Coordinate(latitude: point.latitude, longitude: point.longitude), zoom: BundledGeography.zoom)
    }

    var body: some View {
        MapView(camera: $camera,
                markers: [MapMarker(id: "photo", coordinate: Coordinate(latitude: point.latitude, longitude: point.longitude))],
                interactive: false, renderer: renderer)
            .onChange(of: point) { _, new in camera = Self.camera(for: new) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Map"))
            .accessibilityIdentifier("inspectorMap")
    }
}
