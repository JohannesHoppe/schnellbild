import SwiftUI
import AppKit
import OfflineMap

/// The Atlas view of one pane (W): the pane's photos and videos (the
/// folder's, or a search's from every subfolder) at their places on the
/// offline map, the timeline under it and the tour. The items are the
/// pane's `entries`, so the selection is the grid's and the list's.
/// Times and places come from `LocationCache` (`CaptureFacts`), read off
/// the main thread eight files at a time while the Atlas is shown.
@MainActor
final class AtlasModel: ObservableObject {
    weak var browser: BrowserModel?

    /// Reads the facts of files (tests stand in).
    typealias FactsReader = @Sendable ([(url: URL, modified: Date?)]) async -> [URL: CaptureFacts]
    let readFacts: FactsReader

    init(browser: BrowserModel?, readFacts: @escaping FactsReader = AtlasModel.liveFacts) {
        self.browser = browser
        self.readFacts = readFacts
    }

    /// Through `LocationCache` (by path, the file's and its companions' dates), eight at a time.
    nonisolated static let liveFacts: FactsReader = { files in
        await withTaskGroup(of: (URL, CaptureFacts).self) { group in
            var result: [URL: CaptureFacts] = [:]
            var pending = files[...]
            func addNext() {
                guard !Task.isCancelled, let file = pending.popFirst() else { return }
                group.addTask {
                    // Archives are only read for what is shown, not for their headers
                    guard !ArchivePath.isInside(file.url) else { return (file.url, CaptureFacts()) }
                    return (file.url, await LocationCache.shared.facts(of: file.url, modified: file.modified))
                }
            }
            for _ in 0..<8 { addNext() }
            for await (url, facts) in group {
                if !Task.isCancelled { result[url] = facts }
                addNext()
            }
            return result
        }
    }

    // MARK: Items

    /// Every photo and video whose facts are read, in the order of time.
    @Published private(set) var items: [AtlasItem] = []
    /// What the timeline lets through: on the map (`placed`) or in the strip under it (`unplaced`).
    @Published private(set) var placed: [AtlasItem] = []
    @Published private(set) var unplaced: [AtlasItem] = []
    /// While facts are read: how many of how many.
    @Published private(set) var progress: BrowserModel.Progress?

    private var media: [URL: GridEntry] = [:]
    private var known: [URL: CaptureFacts] = [:]
    private var pending: [(url: URL, modified: Date?)] = []
    private var readTask: Task<Void, Never>?
    private var done = 0, total = 0
    /// The folder and query the items belong to: another one starts afresh.
    private var context = ""

    /// The pane's list changed (or the Atlas is shown): read what is new.
    func entriesChanged(_ entries: [GridEntry], context newContext: String) {
        if newContext != context {
            context = newContext
            readTask?.cancel()
            readTask = nil
            pending = []
            done = 0
            total = 0
            range = nil
            tourWanted = false
            needsFit = true
            userMovedMap = false
            if tour != nil { endTour() }
        }
        var next: [URL: GridEntry] = [:]
        for entry in entries where entry.isMedia { next[entry.url] = entry }
        media = next
        let queued = Set(pending.map(\.url))
        for entry in entries where entry.isMedia && known[entry.url] == nil && !queued.contains(entry.url) {
            pending.append((entry.url, entry.modDate))
            total += 1
        }
        rebuild()
        if readTask == nil, !pending.isEmpty { startReading() }
    }

    /// Stops reading (another view chosen); what is known stays.
    func pause() {
        readTask?.cancel()
        readTask = nil
        pending = []
        tourWanted = false
        progress = nil
        done = 0
        total = 0
    }

    private func startReading() {
        readTask = Task { [weak self] in
            var lastRebuild = Date.distantPast
            while let self, !Task.isCancelled {
                let chunk = Array(self.pending.prefix(64))
                if chunk.isEmpty { break }
                self.pending.removeFirst(chunk.count)
                if self.total > 64 { self.progress = BrowserModel.Progress(done: self.done, total: self.total) }
                let found = await self.readFacts(chunk)
                guard !Task.isCancelled else { return }
                self.known.merge(found) { _, new in new }
                self.done += chunk.count
                if self.progress != nil { self.progress = BrowserModel.Progress(done: self.done, total: self.total) }
                if self.pending.isEmpty || Date().timeIntervalSince(lastRebuild) > 0.4 {
                    lastRebuild = Date()
                    self.rebuild()
                }
            }
            guard let self else { return }
            self.readTask = nil
            self.progress = nil
            self.done = 0
            self.total = 0
            self.rebuild()
            if self.tourWanted {
                self.tourWanted = false
                self.startTour()
            }
        }
    }

    /// Items known already, without a pane (tests).
    func load(_ given: [AtlasItem]) {
        items = AtlasItems.prepared(given)
        filter()
    }

    /// Whether every item's facts are read.
    var isComplete: Bool { readTask == nil && pending.isEmpty }

    private func rebuild() {
        let built = media.values.compactMap { entry -> AtlasItem? in
            guard let facts = known[entry.url] else { return nil }
            return AtlasItem.make(url: entry.url, isVideo: entry.kind == .video, facts: facts, modified: entry.modDate)
        }
        items = AtlasItems.prepared(built)
        if let range, let span, !(span.overlaps(range)) { self.range = nil }
        filter()
    }

    // MARK: Timeline

    /// The timeline's from–to; nil: the whole span.
    @Published var range: ClosedRange<Date>? { didSet { if range != oldValue { filter() } } }

    /// From the first item's time to the last's.
    var span: ClosedRange<Date>? { AtlasTimeline.span(of: items) }

    /// What the timeline lets through.
    var shown: [AtlasItem] { placed + unplaced }

    private func filter() {
        let shown = AtlasTimeline.filter(items, to: range)
        placed = shown.filter { $0.coordinate != nil }
        unplaced = shown.filter { $0.coordinate == nil }
        fitIfNeeded()
        scheduleClusters()
    }

    /// A click on the timeline: the item nearest that time selected, the map on it.
    func jump(to date: Date) {
        guard let item = AtlasTimeline.nearest(to: date, in: shown) else { return }
        select(item.url)
        if let coordinate = item.coordinate { reveal(coordinate) }
    }

    // MARK: Map

    /// Where the map looks. Kept in an object of its own: only the map
    /// follows it while it moves, not the timeline and the strip.
    final class CameraState: ObservableObject {
        @Published var camera = MapCamera.world
    }
    let cameraState = CameraState()

    var camera: MapCamera {
        get { cameraState.camera }
        set {
            guard newValue != cameraState.camera else { return }
            cameraState.camera = newValue
            // Moved by the user (drag, scroll, pinch, buttons), not only held in the view's limits
            if let set = cameraSet, newValue != set, newValue != MapViewport(camera: set, size: mapSize).clamped(), tour == nil {
                userMovedMap = true
            }
            if abs(newValue.zoom - (clusterZoom ?? -1)) > 0.001 { scheduleClusters() }
        }
    }
    /// The map's size in points (the view reports it). A new size fits the
    /// map again until the user moves it (the view's first sizes are passing ones).
    var mapSize: CGSize = .zero {
        didSet {
            guard mapSize != oldValue else { return }
            if !userMovedMap, tour == nil { needsFit = true }
            fitIfNeeded()
        }
    }
    /// The map is fitted to the items once per folder (again while they come in, until the user moves it).
    private var needsFit = true
    private(set) var userMovedMap = false

    /// For the UI tests (`--ui-testing`): the map's zoom and size, the clusters, the fit.
    var testState: String {
        String(format: "zoom %.2f, size %.0f×%.0f, clusters %d at %.2f, fit %@, moved %@",
               camera.zoom, mapSize.width, mapSize.height, clusters.count, clusterZoom ?? -1,
               needsFit ? "pending" : "done", userMovedMap ? "yes" : "no")
    }
    private var cameraSet: MapCamera?

    private func setCamera(_ next: MapCamera) {
        cameraSet = next
        camera = next
    }

    private func fitIfNeeded() {
        guard tour == nil, mapSize.width > 40, mapSize.height > 40, !placed.isEmpty, needsFit || (!isComplete && !userMovedMap) else { return }
        fitAll()
        if isComplete { needsFit = false }
    }

    /// Shows every item on the map.
    func fitAll() {
        guard let fitted = MapCamera.fitting(placed.compactMap(\.coordinate), in: mapSize, padding: 70, maxZoom: 11) else { return }
        setCamera(MapViewport(camera: fitted, size: mapSize).clamped())
    }

    /// Moves the map so the place is in view (at once when it already is).
    func reveal(_ coordinate: Coordinate) {
        let viewport = MapViewport(camera: camera, size: mapSize)
        let p = viewport.point(for: coordinate)
        guard mapSize.width > 0, !CGRect(origin: .zero, size: mapSize).insetBy(dx: 40, dy: 40).contains(p) else { return }
        setCamera(MapViewport(camera: MapCamera(center: coordinate, zoom: camera.zoom), size: mapSize).clamped())
    }

    /// A double click on a cluster: the map zooms until its items part.
    func zoom(into cluster: AtlasCluster) {
        let coordinates = cluster.ids.compactMap { id in placed.first { $0.url == id }?.coordinate }
        let fitted = MapCamera.fitting(coordinates, in: mapSize, padding: 90, maxZoom: MapViewport.maxZoom)
        let zoom = max(camera.zoom + 2, fitted?.zoom ?? 0)
        let target = MapViewport(camera: MapCamera(center: fitted?.center ?? cluster.coordinate, zoom: min(MapViewport.maxZoom, zoom)),
                                 size: mapSize).clamped()
        userMovedMap = true
        setCamera(target)
    }

    /// + / − in the Atlas: the map zooms a step about its middle.
    func zoomStep(_ steps: Double) {
        guard mapSize.width > 0 else { return }
        userMovedMap = true
        let viewport = MapViewport(camera: camera, size: mapSize)
        setCamera(viewport.zoomed(to: camera.zoom + steps, keeping: CGPoint(x: mapSize.width / 2, y: mapSize.height / 2)))
    }

    // MARK: Clusters (off the main thread)

    @Published private(set) var clusters: [AtlasCluster] = []
    /// The zoom the clusters were made for.
    private(set) var clusterZoom: Double?
    private var clustering = false
    private var clusterAgain = false

    private func scheduleClusters() {
        guard !clustering else { clusterAgain = true; return }
        clustering = true
        clusterAgain = false
        let points = placed.map { (id: $0.url, coordinate: $0.coordinate!) }
        let zoom = camera.zoom
        Task { [weak self] in
            let made = await Blocking.run(.userInitiated) { AtlasClustering.clusters(of: points, zoom: zoom) }
            guard let self else { return }
            self.clusters = made
            self.clusterZoom = zoom
            self.clustering = false
            if self.clusterAgain || abs(self.camera.zoom - zoom) > 0.001 { self.scheduleClusters() }
        }
    }

    /// Made at once (tests).
    func clusterNow() {
        clusters = AtlasClustering.clusters(of: placed.map { (id: $0.url, coordinate: $0.coordinate!) }, zoom: camera.zoom)
        clusterZoom = camera.zoom
    }

    // MARK: Selection

    /// The item selected in the pane (the grid's and the list's selection).
    var selectedURL: URL? {
        guard let entry = browser?.selectedEntry, entry.isMedia else { return nil }
        return entry.url
    }

    func item(_ url: URL) -> AtlasItem? { items.first { $0.url == url } }

    /// The file's date as listed (the thumbnail cache's key).
    func modified(_ url: URL) -> Date? { media[url]?.modDate }

    /// Selects the item in the pane.
    func select(_ url: URL) {
        guard let browser, let entry = media[url] else { return }
        browser.select(entry)
    }

    /// Space, or a double click on a single item: the full view.
    func open(_ url: URL) {
        select(url)
        browser?.activateSelection()
    }

    /// A tile clicked: its cluster's first item, or the selection when it is inside already.
    func click(_ cluster: AtlasCluster) {
        if let selected = selectedURL, cluster.ids.contains(selected) { return }
        select(cluster.ids[0])
    }

    /// The cluster the selection is in.
    var selectedCluster: AtlasCluster? {
        guard let selected = selectedURL else { return nil }
        return clusters.first { $0.ids.contains(selected) }
    }

    /// The clusters on screen with their points.
    func visibleClusters(margin: CGFloat = 0) -> [(cluster: AtlasCluster, point: CGPoint)] {
        let viewport = MapViewport(camera: camera, size: mapSize)
        let bounds = CGRect(origin: .zero, size: mapSize).insetBy(dx: -margin, dy: -margin)
        return clusters.compactMap { cluster in
            let p = viewport.point(for: cluster.coordinate)
            return bounds.contains(p) ? (cluster, p) : nil
        }
    }

    /// The arrow keys: to the nearest tile on screen that way; down from the
    /// lowest tile into the strip of items without a place, up out of it.
    /// Without a selection on screen, the tile nearest the middle.
    func move(_ direction: AtlasDirection) {
        let visible = visibleClusters()
        if let selected = selectedURL, let index = unplaced.firstIndex(where: { $0.url == selected }) {
            switch direction {
            case .left:  if index > 0 { select(unplaced[index - 1].url) }
            case .right: if index + 1 < unplaced.count { select(unplaced[index + 1].url) }
            case .up:
                let bottom = CGPoint(x: mapSize.width / 2, y: mapSize.height)
                if let nearest = visible.min(by: { distance($0.point, bottom) < distance($1.point, bottom) }) {
                    select(nearest.cluster.ids[0])
                }
            case .down: break
            }
            return
        }
        let current = visible.first { item in selectedURL.map(item.cluster.ids.contains) ?? false }
        guard let current else {
            let middle = CGPoint(x: mapSize.width / 2, y: mapSize.height / 2)
            if let nearest = visible.min(by: { distance($0.point, middle) < distance($1.point, middle) }) {
                select(nearest.cluster.ids[0])
            } else if let first = unplaced.first {
                select(first.url)
            }
            return
        }
        let others = visible.filter { $0.cluster.id != current.cluster.id }
        if let index = AtlasNavigation.next(from: current.point, among: others.map(\.point), direction) {
            select(others[index].cluster.ids[0])
        } else if direction == .down, let first = unplaced.first {
            select(first.url)
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

    // MARK: Tour

    @Published private(set) var tour: TourPlayer? {
        didSet { if (tour == nil) != (oldValue == nil) { browser?.objectWillChange.send() } }
    }
    /// The route drawn so far and where each station is reached on it.
    @Published private(set) var route: [Coordinate] = []
    private(set) var arrivals: [Int] = []
    private var tourTask: Task<Void, Never>?
    /// Counts the steps: a key that jumps (← →) makes the running step give way.
    private var tourStep = 0
    private var tourEnteredFullScreen = false
    /// Asked for while the places were still being read.
    private var tourWanted = false

    /// The stations of the tour as it would run now (the timeline's range).
    var stations: [TourStation] { TourPlanner.stations(from: placed) }

    /// Play: the stations in the order of time, full screen. False when no
    /// item has a place (the tour has nowhere to go).
    @discardableResult
    func startTour() -> Bool {
        guard tour == nil else { return true }
        let stations = self.stations
        // T before the places are read (the Atlas just opened): it starts once they are
        if stations.isEmpty, !isComplete { tourWanted = true; return true }
        guard !stations.isEmpty else { NSSound.beep(); return false }
        let way = TourPlanner.route(through: stations)
        route = way.points
        arrivals = way.arrivals
        tour = TourPlayer(stations: stations)
        tourEnteredFullScreen = browser?.setFullScreen(true) ?? false
        runTour()
        return true
    }

    /// Esc, or the last station's last item done: back to the Atlas with
    /// the item shown last selected.
    func endTour() {
        tourTask?.cancel()
        tourTask = nil
        let last = tour?.currentItem ?? tour?.currentStation?.items.first
        tour = nil
        route = []
        arrivals = []
        if tourEnteredFullScreen { _ = browser?.setFullScreen(false) }
        tourEnteredFullScreen = false
        if let last { select(last.url) }
    }

    func togglePause() { tour?.paused.toggle() }

    func nextStation() {
        guard tour != nil else { return }
        tour?.next()
        tourStep += 1
        if tour?.finished == true { endTour() }
    }

    func previousStation() {
        guard tour != nil else { return }
        tour?.previous()
        tourStep += 1
    }

    /// The camera that shows a station.
    func camera(for station: TourStation) -> MapCamera {
        MapViewport(camera: MapCamera(center: station.coordinate, zoom: TourFlight.zoom(for: station, size: mapSize)),
                    size: mapSize).clamped()
    }

    /// The route up to where the tour is: to the station it flies to or shows.
    var routeSoFar: [Coordinate] {
        guard let tour, arrivals.indices.contains(tour.station) else { return [] }
        let end = tour.station + 1 < arrivals.count ? arrivals[tour.station + 1] : route.count
        return Array(route.prefix(tour.phase == .flying ? arrivals[tour.station] + 1 : end))
    }

    /// Steps the tour: each step (a flight, an item shown) lasts its time,
    /// not counting the time paused; the flight moves the camera on the way
    /// (cut with Reduce motion).
    private func runTour() {
        tourTask?.cancel()
        tourTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.tour else { return }
                if player.finished { self.endTour(); return }
                let step = self.tourStep
                let reduced = Motion.reduced
                let duration = player.duration(reducedMotion: reduced)
                let from = self.camera
                let to = player.currentStation.map(self.camera(for:)) ?? from
                if player.phase == .flying, reduced { self.setCamera(to) }
                var elapsed = 0.0
                let tick = 1.0 / 60
                while elapsed < duration {
                    try? await Task.sleep(for: .seconds(tick))
                    if Task.isCancelled || self.tourStep != step || self.tour == nil { break }
                    if self.tour?.paused == false { elapsed += tick }
                    if player.phase == .flying, !reduced {
                        self.setCamera(TourFlight.camera(from: from, to: to, at: min(1, elapsed / duration), size: self.mapSize))
                    }
                }
                if Task.isCancelled || self.tour == nil { return }
                if self.tourStep == step {
                    self.tour?.advance()
                    self.tourStep += 1
                }
            }
        }
    }

    /// The keys while the tour runs: Space pauses, ← → go a station back
    /// or on, Esc ends; F (full screen), the boss key and F1 as ever.
    func handleTourKey(_ key: BrowserModel.KeyInput, command: Bool) -> Bool {
        guard !command else { return false }
        switch key {
        case .space: togglePause(); return true
        case .left: previousStation(); return true
        case .right: nextStation(); return true
        case .escape, .backspace: endTour(); return true
        case .char(let c) where c.lowercased() == "t": endTour(); return true
        default: return false
        }
    }
}

// MARK: - The pane's keys in the Atlas

extension BrowserModel {
    /// The Atlas's own meaning of the grid's keys: the arrows move among
    /// the tiles on screen (and the strip under the map), + / − zoom the
    /// map, Home / End the first / last item in time. Nil: as in the grid
    /// (Space opens, ↩ renames, Esc unmarks …).
    func atlasKey(_ key: KeyInput, command: Bool, shift: Bool) -> Bool? {
        switch key {
        case .left where !command:  atlas.move(.left); return true
        case .right where !command: atlas.move(.right); return true
        case .up where !command:    atlas.move(.up); return true
        case .down where !command:  atlas.move(.down); return true
        case .home:
            if let first = atlas.shown.min(by: { $0.date < $1.date }) { atlas.select(first.url); first.coordinate.map(atlas.reveal) }
            return true
        case .end:
            if let last = atlas.shown.max(by: { $0.date < $1.date }) { atlas.select(last.url); last.coordinate.map(atlas.reveal) }
            return true
        case .char(let c) where c == "+" || c == "=":
            atlas.zoomStep(1); return true
        case .char("-"):
            atlas.zoomStep(-1); return true
        default:
            return nil
        }
    }

    /// The keys while the tour runs (`AtlasModel.handleTourKey`); F and K
    /// as ever, nothing else of the pane's.
    func tourKey(_ key: KeyInput, command: Bool, atlas: AtlasModel) -> Bool {
        if atlas.handleTourKey(key, command: command) { return true }
        guard !command, case .char(let raw) = key else { return false }
        switch Character(raw.lowercased()) {
        case "f": toggleFullScreen(); return true
        case "k": showMiniKeyboard.toggle(); return true
        default: return false
        }
    }
}
