import SwiftUI
import AppKit
import AVFoundation
import OfflineMap

/// The Atlas view (W): the pane's photos and videos at their places on the
/// offline map, as thumbnails, close ones as one tile with their count;
/// those without a place in a strip under the map; the timeline at the
/// bottom. During the tour the map takes the whole pane (`TourStage`).
/// The map is `GlobeView`: zoomed far out the globe, which flattens into
/// the flat map; its overlay places the tiles through the `MapProxy` and
/// leaves out what lies on the globe's far side. The timeline stays under both.
struct AtlasView: View {
    @ObservedObject var atlas: AtlasModel
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        VStack(spacing: 0) {
            map
            if atlas.tour == nil {
                if !atlas.unplaced.isEmpty {
                    Divider()
                    AtlasStrip(atlas: atlas)
                }
                Divider()
                AtlasTimelineView(atlas: atlas)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("atlas")
    }

    private var map: some View {
        AtlasMap(atlas: atlas, camera: atlas.cameraState, selected: model.selectedEntry?.url)
        .overlay(alignment: .topLeading) {
            if atlas.tour == nil { header.padding(10) }
        }
        .overlay {
            if atlas.tour == nil, atlas.isComplete, atlas.placed.isEmpty {
                Text(atlas.items.isEmpty ? "No photos or videos here" : "None of these photos and videos has a location")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("atlasEmpty")
            }
        }
        .overlay { if atlas.tour != nil { TourStage(atlas: atlas) } }
    }

    /// The count, the reading's progress and Play.
    private var header: some View {
        HStack(spacing: 8) {
            Button { model.startTour() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                    Text("Tour")
                    if let key = shortcuts.keys(.startTour).first { KeyCap(key.capText) }
                }
            }
            .buttonStyle(.borderless)
            .disabled(atlas.placed.isEmpty)
            .help(String(localized: "Play the tour: the places in the order of time, full screen (\(shortcuts.hint(.startTour)))"))
            .accessibilityLabel(Text("Play the tour"))
            .accessibilityIdentifier("tourButton")
            Divider().frame(height: 14)
            Group {
                if let progress = atlas.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 50)
                    Text("Reading locations: \(progress.done) of \(progress.total)")
                } else {
                    Text(countText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("atlasCount")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
    }

    private var countText: String {
        let onMap = atlas.placed.count
        return String(localized: "\(onMap) on the map")
    }
}

// MARK: - The map

/// The map with the tiles (or, during the tour, the route): the one part
/// that follows the camera while it moves.
private struct AtlasMap: View {
    @ObservedObject var atlas: AtlasModel
    @ObservedObject var camera: AtlasModel.CameraState
    let selected: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = MapPalette.appearance(dark: colorScheme == .dark)
        GeometryReader { geometry in
            // Zoomed far out the globe, flattening into the flat map between `GlobeProjection.morphStart` and `flatZoom`
            GlobeView(camera: Binding(get: { camera.camera }, set: { atlas.camera = $0 }), interactive: atlas.tour == nil) { proxy in
                if atlas.tour != nil {
                    TourRoute(atlas: atlas, proxy: proxy, palette: palette)
                } else {
                    AtlasTiles(atlas: atlas, proxy: proxy, palette: palette, selected: selected)
                }
            }
            .onAppear { atlas.mapSize = geometry.size }
            .onChange(of: geometry.size) { _, size in atlas.mapSize = size }
        }
        .overlay(alignment: .bottomLeading) {
            // What the UI tests read about the map (not shown, not for VoiceOver users)
            if VideoDetailView.uiTesting {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: atlas.testState))
                    .accessibilityIdentifier("atlasMapState")
            }
        }
    }
}

// MARK: - Tiles on the map

/// The clusters on screen as thumbnails: one item, or several with their
/// count; the selected one ringed. Only tiles on screen are made.
private struct AtlasTiles: View {
    @ObservedObject var atlas: AtlasModel
    let proxy: MapProxy
    let palette: MapPalette
    let selected: URL?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.cluster.id) { cluster, point in
                let isSelected = selected.map(cluster.ids.contains) ?? false
                AtlasTile(atlas: atlas, cluster: cluster, shown: isSelected ? selected! : cluster.ids[0],
                          selected: isSelected, palette: palette)
                    .position(x: point.x, y: point.y - AtlasTile.side / 2 - 6)
                    .zIndex(isSelected ? 1 : 0)
                AtlasPin(palette: palette).position(point).allowsHitTesting(false)
            }
        }
    }

    private var visible: [(cluster: AtlasCluster, point: CGPoint)] {
        let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: -AtlasTile.side, dy: -AtlasTile.side)
        return atlas.clusters.compactMap { cluster in
            // On the globe: not what lies on its far side
            guard proxy.isVisible(cluster.coordinate) else { return nil }
            let p = proxy.point(for: cluster.coordinate)
            return bounds.contains(p) ? (cluster, p) : nil
        }
    }
}

/// The dot under a tile, where its items were taken.
private struct AtlasPin: View {
    let palette: MapPalette
    var body: some View {
        Circle()
            .fill(Color(cgColor: palette.accent.cgColor))
            .overlay(Circle().stroke(Color(cgColor: palette.frame.cgColor), lineWidth: 1.5))
            .frame(width: 7, height: 7)
    }
}

/// A thumbnail on the map in its frame; several items: the frames of the
/// others behind it and the count in the accent colour.
private struct AtlasTile: View {
    static let side: CGFloat = 52
    @ObservedObject var atlas: AtlasModel
    let cluster: AtlasCluster
    let shown: URL
    let selected: Bool
    let palette: MapPalette

    var body: some View {
        let frame = Color(cgColor: palette.frame.cgColor)
        ZStack(alignment: .topTrailing) {
            if cluster.count > 1 {
                ForEach([6.0, 3.0], id: \.self) { offset in
                    RoundedRectangle(cornerRadius: 6).fill(frame.opacity(0.9))
                        .frame(width: Self.side + 4, height: Self.side + 4)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: offset, y: -offset)
                }
            }
            AtlasThumbnail(url: shown, modified: atlas.modified(shown), side: Self.side, isVideo: atlas.item(shown)?.isVideo == true)
                .padding(2)
                .background(frame, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: selected ? 3 : 0).padding(-2))
            if cluster.count > 1 {
                Text(verbatim: cluster.count.formatted())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(cgColor: palette.accentText.cgColor))
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
                    .background(Color(cgColor: palette.accent.cgColor), in: Capsule())
                    .offset(x: 8, y: -8)
            }
        }
        .frame(width: Self.side + 4, height: Self.side + 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if cluster.count > 1 { atlas.zoom(into: cluster) } else { atlas.open(cluster.ids[0]) }
        }
        .simultaneousGesture(TapGesture().onEnded { atlas.click(cluster) })
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(VideoDetailView.uiTesting ? "\(selected ? "selected" : "not selected"), \(cluster.count) items" : "")
        .accessibilityIdentifier("atlas.\(cluster.ids[0].lastPathComponent)")
        .accessibilityAction { atlas.click(cluster) }
        .accessibilityAction(named: Text(cluster.count > 1 ? "Zoom in" : "Open")) {
            if cluster.count > 1 { atlas.zoom(into: cluster) } else { atlas.open(cluster.ids[0]) }
        }
    }

    private var label: String {
        let name = shown.lastPathComponent
        return cluster.count > 1 ? String(localized: "\(cluster.count) items here, \(name) among them") : name
    }

    private var help: String {
        cluster.count > 1 ? String(localized: "\(cluster.count) items here: double-click to zoom in") : shown.lastPathComponent
    }
}

/// A thumbnail from the grid's cache (made by QuickLook or VLC as there).
struct AtlasThumbnail: View {
    let url: URL
    let modified: Date?
    let side: CGFloat
    var isVideo = false
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: max(7, side / 6)))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .padding(3)
            }
        }
        .task(id: url) {
            if let cached = ThumbnailCache.shared.cached(for: url, side: side, modified: modified) { image = cached; return }
            image = nil
            image = await ThumbnailCache.shared.thumbnail(for: url, side: max(side, 64), modified: modified)
        }
    }
}

// MARK: - Items without a place

/// The strip under the map: the items whose place isn't known, as tiles
/// to select and open like those on the map. None gets a made-up place.
private struct AtlasStrip: View {
    @ObservedObject var atlas: AtlasModel
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Text("No location · \(atlas.unplaced.count)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityIdentifier("atlasStripTitle")
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(atlas.unplaced) { item in
                            let selected = model.selectedEntry?.url == item.url
                            AtlasThumbnail(url: item.url, modified: atlas.modified(item.url), side: 40, isVideo: item.isVideo)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: selected ? 3 : 0).padding(-1))
                                .padding(2)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { atlas.open(item.url) }
                                .simultaneousGesture(TapGesture().onEnded { atlas.select(item.url) })
                                .help(item.name)
                                .id(item.url)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: item.name))
                                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                                .accessibilityValue(VideoDetailView.uiTesting ? (selected ? "selected" : "not selected") : "")
                                .accessibilityIdentifier("atlas.\(item.name)")
                                .accessibilityAction { atlas.select(item.url) }
                                .accessibilityAction(named: Text("Open")) { atlas.open(item.url) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.selectedEntry?.url) { _, url in
                    if let url, atlas.unplaced.contains(where: { $0.url == url }) {
                        withAnimation(Motion.animation(.easeInOut(duration: 0.2))) { scroller.scrollTo(url) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("atlasStrip")
    }
}

// MARK: - Timeline

/// The items by time, always under the map: a thumbnail now and then and a
/// bar per stretch of time; the from–to range (the handles, or a drag
/// across) narrows what the map and the strip show; a click jumps to the
/// item nearest that time. Times are shown as the clocks where the items
/// were taken showed them.
private struct AtlasTimelineView: View {
    @ObservedObject var atlas: AtlasModel
    @EnvironmentObject var model: BrowserModel
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(verbatim: label(of: range?.lowerBound)).accessibilityIdentifier("timeline.from")
                Spacer()
                if atlas.range != nil {
                    Text("\(atlas.shown.count) of \(atlas.items.count)")
                        .accessibilityIdentifier("timeline.count")
                    Button("Show All") { atlas.range = nil }
                        .buttonStyle(.link)
                        .help("The whole span again")
                        .accessibilityIdentifier("timeline.all")
                }
                Spacer()
                Text(verbatim: label(of: range?.upperBound)).accessibilityIdentifier("timeline.to")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GeometryReader { geometry in
                track(width: geometry.size.width)
            }
            .frame(height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline")
    }

    /// The range shown: the one chosen, else the whole span.
    private var range: ClosedRange<Date>? { atlas.range ?? atlas.span }

    private func label(of date: Date?) -> String {
        guard let date else { return "" }
        return AtlasTimeline.text(date, in: AtlasTimeline.zone(at: date, in: atlas.items), time: true)
    }

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        if let span = atlas.span, width > 0 {
            let bins = max(1, Int(width / 4))
            let counts = AtlasTimeline.histogram(atlas.items, span: span, bins: bins)
            let most = max(1, counts.max() ?? 1)
            let lower = AtlasTimeline.fraction(of: range?.lowerBound ?? span.lowerBound, span: span)
            let upper = AtlasTimeline.fraction(of: range?.upperBound ?? span.upperBound, span: span)
            ZStack(alignment: .topLeading) {
                // The chosen range
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: max(2, (upper - lower) * width), height: 44)
                    .offset(x: lower * width)
                thumbnails(span: span, width: width, lower: lower, upper: upper)
                // A bar per stretch of time
                Path { path in
                    let w = width / CGFloat(bins)
                    for (i, count) in counts.enumerated() where count > 0 {
                        let h = max(2, 16 * CGFloat(count) / CGFloat(most))
                        path.addRect(CGRect(x: CGFloat(i) * w + 0.5, y: 44 - h, width: max(1, w - 1), height: h))
                    }
                }
                .fill(Color.secondary.opacity(0.55))
                // The selected item's time
                if let selected = model.selectedEntry.flatMap({ atlas.item($0.url) }) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: 2, height: 44)
                        .offset(x: AtlasTimeline.fraction(of: selected.date, span: span) * width - 1)
                }
                handle(at: lower, width: width, span: span, isStart: true)
                handle(at: upper, width: width, span: span, isStart: false)
            }
            .frame(width: width, height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = Double(drag.location.x / width)
                if dragStart == nil { dragStart = Double(drag.startLocation.x / width) }
                if abs(drag.translation.width) > 3, let start = dragStart {
                    let a = AtlasTimeline.date(at: min(start, f), span: span), b = AtlasTimeline.date(at: max(start, f), span: span)
                    atlas.range = a...b
                }
            }.onEnded { drag in
                dragStart = nil
                if abs(drag.translation.width) <= 3 {
                    atlas.jump(to: AtlasTimeline.date(at: Double(drag.location.x / width), span: span))
                }
            })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timeline.track")
        }
    }

    /// A thumbnail about every 46 points: the first item of that stretch.
    private func thumbnails(span: ClosedRange<Date>, width: CGFloat, lower: Double, upper: Double) -> some View {
        let slots = max(1, Int(width / 46))
        var firsts: [Int: AtlasItem] = [:]
        for item in atlas.items {
            let slot = AtlasTimeline.bin(of: item.date, span: span, bins: slots)
            if firsts[slot] == nil { firsts[slot] = item }
        }
        let slotWidth = width / CGFloat(slots)
        return ForEach(firsts.keys.sorted(), id: \.self) { slot in
            let item = firsts[slot]!
            let f = AtlasTimeline.fraction(of: item.date, span: span)
            AtlasThumbnail(url: item.url, modified: atlas.modified(item.url), side: 22, isVideo: item.isVideo)
                .opacity(f >= lower - 0.001 && f <= upper + 0.001 ? 1 : 0.35)
                .offset(x: min(width - 22, max(0, CGFloat(slot) * slotWidth + (slotWidth - 22) / 2)), y: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// A handle of the range: dragged, or with VoiceOver adjusted by a fiftieth of the span.
    private func handle(at fraction: Double, width: CGFloat, span: ClosedRange<Date>, isStart: Bool) -> some View {
        let date = AtlasTimeline.date(at: fraction, span: span)
        return Capsule()
            .fill(Color.accentColor)
            .frame(width: 6, height: 44)
            .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
            .frame(width: 16, height: 44)
            .contentShape(Rectangle())
            .offset(x: fraction * width - 8)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(1, max(0, Double((fraction * width + drag.translation.width) / width)))
                move(isStart: isStart, to: AtlasTimeline.date(at: f, span: span), span: span)
            })
            .help(isStart ? "Start of the range: drag" : "End of the range: drag")
            .accessibilityElement()
            .accessibilityLabel(Text(isStart ? "Start of the range" : "End of the range"))
            .accessibilityValue(Text(verbatim: label(of: date)))
            .accessibilityAdjustableAction { direction in
                let step = span.upperBound.timeIntervalSince(span.lowerBound) / 50
                let next = date.addingTimeInterval(direction == .increment ? step : -step)
                move(isStart: isStart, to: min(span.upperBound, max(span.lowerBound, next)), span: span)
            }
            .accessibilityIdentifier(isStart ? "timeline.start" : "timeline.end")
    }

    private func move(isStart: Bool, to date: Date, span: ClosedRange<Date>) {
        let current = atlas.range ?? span
        if isStart {
            atlas.range = min(date, current.upperBound)...current.upperBound
        } else {
            atlas.range = current.lowerBound...max(date, current.lowerBound)
        }
        if atlas.range == span { atlas.range = nil }
    }
}

// MARK: - Tour

/// The route so far as a line in the accent colour, the stations as dots.
private struct TourRoute: View {
    @ObservedObject var atlas: AtlasModel
    let proxy: MapProxy
    let palette: MapPalette

    var body: some View {
        let accent = Color(cgColor: palette.accent.cgColor)
        ZStack(alignment: .topLeading) {
            Path { path in
                // Long legs in steps, so they bend with the globe; the far side lifts the pen
                var previous: CGPoint?
                for coordinate in Self.stepped(atlas.routeSoFar) {
                    guard proxy.isVisible(coordinate) else { previous = nil; continue }
                    let p = proxy.point(for: coordinate)
                    // A jump of more than the view's width on the flat map is the antimeridian: lifted there
                    if let previous, abs(p.x - previous.x) <= proxy.size.width * 2 { path.addLine(to: p) } else { path.move(to: p) }
                    previous = p
                }
            }
            .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .shadow(color: Color(cgColor: palette.frame.cgColor).opacity(0.8), radius: 1)
            if let tour = atlas.tour {
                ForEach(Array(tour.stations.enumerated()).filter { proxy.isVisible($0.element.coordinate) }, id: \.offset) { index, station in
                    let current = index == tour.station
                    Circle()
                        .fill(index <= tour.station ? accent : accent.opacity(0.35))
                        .overlay(Circle().stroke(Color(cgColor: palette.frame.cgColor), lineWidth: 2))
                        .frame(width: current ? 14 : 8, height: current ? 14 : 8)
                        .position(proxy.point(for: station.coordinate))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The route with a point every half degree or so on its long legs.
    static func stepped(_ route: [Coordinate]) -> [Coordinate] {
        guard let first = route.first else { return [] }
        var out = [first]
        for (a, b) in zip(route, route.dropFirst()) {
            var dLon = b.longitude - a.longitude
            if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
            let steps = max(1, min(64, Int(max(abs(b.latitude - a.latitude), abs(dLon)) / 0.5)))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                out.append(Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + dLon * t).normalized)
            }
        }
        return out
    }
}

/// Over the map during the tour: the item of the station large (photos one
/// after another, a video a short part without sound), where and when, the
/// controls.
private struct TourStage: View {
    @ObservedObject var atlas: AtlasModel
    @ObservedObject private var shortcuts = Shortcuts.shared
    @State private var place: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let tour = atlas.tour, let item = tour.currentItem {
                    let side = min(geometry.size.width * 0.5, geometry.size.height * 0.66)
                    VStack(spacing: 10) {
                        TourPicture(item: item, side: side, paused: tour.paused, modified: atlas.modified(item.url))
                            .id(item.url)
                            .transition(.opacity)
                        caption(item: item, tour: tour)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                }
            }
            // Right of the place, which stands left of the middle (`TourFlight.placeShare`)
            .frame(width: geometry.size.width * (1 - TourFlight.placeShare * 1.6), height: geometry.size.height)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            .animation(Motion.animation(.easeInOut(duration: 0.35)), value: atlas.tour?.currentItem?.url)
            .overlay(alignment: .bottom) { controls.padding(.bottom, 24) }
            .overlay(alignment: .topLeading) {
                if let tour = atlas.tour, let station = tour.currentStation {
                    Text(verbatim: AtlasTimeline.text(station.start, in: station.items[0].zone, time: false))
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(20)
                        .accessibilityIdentifier("tourDay")
                }
            }
        }
        .task(id: atlas.tour?.currentStation?.coordinate) {
            place = nil
            guard let coordinate = atlas.tour?.currentStation?.coordinate, let provider = OfflineGeography.provider,
                  let point = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude) else { return }
            let found = await provider.placeName(near: point)
            if !Task.isCancelled { place = found }
        }
    }

    private func caption(item: AtlasItem, tour: TourPlayer) -> some View {
        VStack(spacing: 2) {
            if let place { Text(verbatim: place).font(.headline) }
            Text(verbatim: AtlasTimeline.text(item.date, in: item.zone, time: true) + " · " + item.name)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            if let tour = atlas.tour {
                button("backward.fill", "Previous place", .tourPrevious, id: "tour.previous") { atlas.previousStation() }
                button(tour.paused ? "play.fill" : "pause.fill", tour.paused ? "Resume" : "Pause", .tourPause, id: "tour.pause") { atlas.togglePause() }
                button("forward.fill", "Next place", .tourNext, id: "tour.next") { atlas.nextStation() }
                Text("Place \(tour.station + 1) of \(tour.stations.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tourStatus")
                    .accessibilityValue(VideoDetailView.uiTesting
                        ? "station \(tour.station + 1) of \(tour.stations.count), \(tour.phase == .flying ? "flying" : "showing")\(tour.paused ? ", paused" : "")"
                        : "")
                button("xmark", "End the tour", .endTour, id: "tour.end") { atlas.endTour() }
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
    }

    private func button(_ symbol: String, _ title: LocalizedStringKey, _ action: ShortcutAction, id: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(Text(title) + Text(verbatim: " (\(shortcuts.hint(action)))"))
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(id)
    }
}

/// A station's photo large, or its video playing a short part without sound.
private struct TourPicture: View {
    let item: AtlasItem
    let side: CGFloat
    let paused: Bool
    let modified: Date?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
            if item.isVideo, !VideoDetailView.playsInVLC(item.url) {
                TourVideo(url: item.url, paused: paused)
            }
        }
        .frame(maxWidth: side, maxHeight: side)
        .aspectRatio(image.map { $0.size.width / max(1, $0.size.height) } ?? 1.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityIdentifier("tourItem")
        .task(id: item.url) {
            image = ThumbnailCache.shared.image(for: item.url)
            if let large = await ThumbnailCache.shared.thumbnail(for: item.url, side: max(256, side), modified: modified) { image = large }
        }
    }
}

/// A video at a station: from its start, muted, paused with the tour.
private struct TourVideo: NSViewRepresentable {
    let url: URL
    let paused: Bool

    final class PlayerView: NSView {
        let player = AVPlayer()
        private let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
            player.isMuted = true
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        // A movie someone else made: it may not make AVFoundation read other files or the network
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        view.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if !paused { view.player.play() }
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        if paused { view.player.pause() } else if view.player.rate == 0 { view.player.play() }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.player.pause()
        view.player.replaceCurrentItem(with: nil)
    }
}
