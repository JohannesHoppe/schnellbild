import SwiftUI
import OfflineMap

/// What the distance sheet holds: the text typed or pasted, a point
/// clicked on the map, or the Mac's position asked for once. The field
/// always shows the point (clicking the map or Use My Location writes its
/// coordinates there), so there is one place it comes from.
@MainActor
final class OriginPicker: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { textChanged() } } }
    /// The town near the point, from the offline place index.
    @Published private(set) var placeName: String?
    /// Waiting for macOS to say where the Mac is.
    @Published private(set) var locating = false
    /// Why Use My Location found nothing.
    @Published private(set) var locationProblem: String?

    private let location: LocationProvider
    private let geography: @MainActor () -> OfflineGeographyProvider?
    private var nameTask: Task<Void, Never>?

    init(location: LocationProvider, geography: (@MainActor () -> OfflineGeographyProvider?)? = nil) {
        self.location = location
        self.geography = geography ?? { OfflineGeography.provider }
    }

    var point: GeoPoint? { GeoPoint.parse(text) }

    /// A click on the map: that place.
    func pick(_ point: GeoPoint) {
        text = point.decimalPair
    }

    /// The coordinate under a click at `spot` in a map of `size` looking through `camera`.
    nonisolated static func point(at spot: CGPoint, camera: MapCamera, size: CGSize) -> GeoPoint? {
        let c = MapViewport(camera: camera, size: size).coordinate(at: spot)
        return GeoPoint(latitude: c.latitude, longitude: c.longitude)
    }

    /// Use My Location: one request to macOS, only now.
    func useMyLocation() async {
        guard !locating else { return }
        locating = true
        locationProblem = nil
        let result = await location.currentLocation()
        locating = false
        switch result {
        case .success(let point): pick(point)
        case .failure(let failure): locationProblem = failure.message
        }
    }

    private func textChanged() {
        nameTask?.cancel()
        placeName = nil
        guard let point, let geography = geography() else { return }
        nameTask = Task { [weak self] in
            let name = await geography.placeName(near: point)
            guard !Task.isCancelled else { return }
            self?.placeName = name
        }
    }

    /// Waits until the place name for the current point is read (tests).
    func placeNameRead() async { await nameTask?.value }
}

/// The place to sort by distance from: coordinates in any common form or a
/// map link, pasted or typed (`GeoPoint.parse`), a click on the offline map,
/// or Use My Location (Core Location, asked only when clicked). Shows what it
/// read and the town near it before ↩ sorts; nothing goes online.
struct DistanceOriginView: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject private var picker: OriginPicker
    @FocusState private var fieldFocused: Bool
    @State private var camera: MapCamera

    @MainActor init(location: LocationProvider? = nil, start: GeoPoint? = nil) {
        _picker = StateObject(wrappedValue: OriginPicker(location: location ?? BrowserModel.liveLocation))
        let center = start.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
        _camera = State(initialValue: center.map { MapCamera(center: $0, zoom: 5) } ?? .world)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sort by Distance").font(.headline)
            Text("Coordinates (48.137, 11.575 or 48°8′14″N 11°34′27″E) or a link from Apple Maps, Google Maps or OpenStreetMap:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Coordinates or map link", text: $picker.text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("distanceOriginField")
                .onSubmit(sort)
            parsed
            if let renderer = MapRenderer.shared {
                map(renderer)
            }
            HStack(spacing: 8) {
                Button { Task { await picker.useMyLocation() } } label: {
                    Label("Use My Location", systemImage: "location")
                }
                .disabled(picker.locating)
                .help("Asks macOS once for where this Mac is. The position stays on this Mac.")
                .accessibilityIdentifier("useMyLocation")
                if picker.locating {
                    ProgressView().controlSize(.small)
                    Text("Finding your location…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let problem = picker.locationProblem {
                Label {
                    Text(problem).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "location.slash")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("locationProblem")
            }
            HStack {
                Spacer()
                Button { model.distanceOriginRequested = false } label: { HStack(spacing: 6) { Text("Cancel"); KeyCap("esc") } }
                    .keyboardShortcut(.cancelAction)
                Button(action: sort) { HStack(spacing: 6) { Text("Sort"); KeyCap("↩") } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picker.point == nil)
                    .accessibilityIdentifier("distanceOriginSort")
            }
        }
        .padding(20)
        .frame(width: 480)
        // (the pasteboard isn't read by itself: macOS asks the user before an app reads it)
        .onAppear { fieldFocused = true }
        .onChange(of: picker.point) { _, point in
            // Typed or found elsewhere: the map goes there (a click keeps the view)
            guard let point, !clicked else { clicked = false; return }
            camera = MapCamera(center: Coordinate(latitude: point.latitude, longitude: point.longitude), zoom: max(camera.zoom, 5))
        }
    }

    @State private var clicked = false

    @ViewBuilder
    private var parsed: some View {
        Group {
            if let point = picker.point {
                VStack(alignment: .leading, spacing: 2) {
                    Label(point.text, systemImage: "mappin.and.ellipse").foregroundStyle(.primary)
                    if let place = picker.placeName {
                        Text(verbatim: place).foregroundStyle(.secondary).accessibilityIdentifier("distanceOriginPlace")
                    }
                }
            } else if GeoPoint.isShortMapLink(picker.text) {
                Text("A short link only says where it leads once it is opened online. Open it in the browser and paste the full address.")
                    .foregroundStyle(.secondary)
            } else if !picker.text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No coordinates found").foregroundStyle(.secondary)
            } else {
                Text(verbatim: " ")
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("distanceOriginParsed")
    }

    /// The offline map: a click picks the place under it; drag moves the
    /// map, + / − zoom.
    private func map(_ renderer: MapRenderer) -> some View {
        let markers = picker.point.map { [MapMarker(id: "origin", coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude))] } ?? []
        return VStack(alignment: .leading, spacing: 3) {
            MapView(camera: $camera, markers: markers, interactive: true, renderer: renderer) { proxy in
                MapPickLayer(camera: $camera, size: proxy.size) { spot in
                    guard let point = OriginPicker.point(at: spot, camera: camera, size: proxy.size) else { return }
                    clicked = true
                    picker.pick(point)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("distanceOriginMap")
            Text("Click the map to choose a place.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sort() {
        guard let point = picker.point else { return }
        model.distanceOriginRequested = false
        model.setDistanceOrigin(point)
    }
}

/// Over the sheet's map: a click (the mouse moved less than 4 points) picks
/// the place, a drag moves the map.
private struct MapPickLayer: View {
    @Binding var camera: MapCamera
    let size: CGSize
    let picked: (CGPoint) -> Void
    @State private var dragStart: MapCamera?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? camera
                    dragStart = start
                    guard hypot(drag.translation.width, drag.translation.height) >= 4 else { return }
                    let middle = CGPoint(x: size.width / 2 - drag.translation.width, y: size.height / 2 - drag.translation.height)
                    camera = MapCamera(center: MapViewport(camera: start, size: size).coordinate(at: middle), zoom: start.zoom)
                }
                .onEnded { drag in
                    dragStart = nil
                    if hypot(drag.translation.width, drag.translation.height) < 4 { picked(drag.location) }
                })
            .accessibilityElement()
            .accessibilityLabel(Text("Click the map to choose a place."))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("distanceOriginMapPick")
    }
}
