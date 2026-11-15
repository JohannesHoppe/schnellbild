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
    /// Where each item is in `items`.
    private var itemIndex: [URL: Int] = [:]

    private var media: [URL: GridEntry] = [:]
    /// Only the small facts (time, place, a video's route of at most 500
    /// points), never pictures: a tree of 100 000 photos stays a few tens of MB.
    private var known: [URL: CaptureFacts] = [:]
    /// What waits to be read, by folder (in the order the pane lists them).
    private var pending: [String: [(url: URL, modified: Date?)]] = [:]
    private var pendingFolders: [String] = []
    private var pendingCount = 0
    private var pendingURLs: Set<URL> = []
    /// A known place of each folder: its other items come first while it is in view.
    private var folderPlaces: [String: Coordinate] = [:]
    private var readTask: Task<Void, Never>?
    private var done = 0, total = 0
    /// The folder and query the items belong to: another one starts afresh.
    private var context = ""

    /// The pane's list changed (or the Atlas is shown): read what is new.
    func entriesChanged(_ entries: [GridEntry], context newContext: String) {
        startContext(newContext)
        var next: [URL: GridEntry] = [:]
        next.reserveCapacity(entries.count)
        for entry in entries where entry.isMedia { next[entry.url] = entry }
        media = next
        queue(entries.filter { $0.isMedia && known[$0.url] == nil })
        rebuild()
    }

    /// Items added to the pane's list (the walk of the subfolders): only
    /// they are looked at, not the whole list again.
    func entriesAdded(_ added: [GridEntry], context newContext: String) {
        guard newContext == context else { return }
        let fresh = added.filter { $0.isMedia && media[$0.url] == nil }
        for entry in fresh { media[entry.url] = entry }
        queue(fresh.filter { known[$0.url] == nil })
        if fresh.contains(where: { known[$0.url] != nil }) { rebuild() }
    }

    private func startContext(_ newContext: String) {
        guard newContext != context else { return }
        context = newContext
        readTask?.cancel()
        readTask = nil
        pending = [:]
        pendingFolders = []
        pendingCount = 0
        pendingURLs = []
        sampled = []
        done = 0
        total = 0
        range = nil
        tourWanted = false
        needsFit = true
        userMovedMap = false
        if tour != nil { endTour() }
    }

    /// Puts files to be read by their folder; reading starts if it rests.
    private func queue(_ entries: [GridEntry]) {
        for entry in entries where pendingURLs.insert(entry.url).inserted {
            let folder = entry.url.deletingLastPathComponent().path
            if pending[folder] == nil { pending[folder] = []; pendingFolders.append(folder) }
            pending[folder]!.append((entry.url, entry.modDate))
            pendingCount += 1
            total += 1
        }
        if readTask == nil, pendingCount > 0 { startReading() }
    }

    /// Stops reading (another view chosen); what is known stays.
    func pause() {
        readTask?.cancel()
        readTask = nil
        pending = [:]
        pendingFolders = []
        pendingCount = 0
        pendingURLs = []
        sampled = []
        tourWanted = false
        progress = nil
        done = 0
        total = 0
    }

    /// Files read per step.
    nonisolated static let chunk = 64

    /// The next files to read, the most wanted first: the selected item's
    /// folder; then one file of every folder not yet sampled (so every place
    /// shows early); then the folders with a place in view; then the rest
    /// in the pane's order.
    func nextChunk(size: Int = AtlasModel.chunk) -> [(url: URL, modified: Date?)] {
        var chunk: [(url: URL, modified: Date?)] = []
        func take(from folder: String, count: Int) {
            guard var list = pending[folder], !list.isEmpty, count > 0 else { return }
            let n = min(count, list.count, size - chunk.count)
            chunk += list.prefix(n)
            for file in list.prefix(n) { pendingURLs.remove(file.url) }
            list.removeFirst(n)
            pendingCount -= n
            pending[folder] = list.isEmpty ? nil : list
        }
        if let selected = browser?.selectedEntry, selected.isMedia {
            take(from: selected.url.deletingLastPathComponent().path, count: size)
        }
        for folder in pendingFolders where chunk.count < size && folderPlaces[folder] == nil && !sampled.contains(folder) {
            sampled.insert(folder)
            take(from: folder, count: 1)
        }
        if chunk.count < size, mapSize.width > 0 {
            let bounds = CGRect(origin: .zero, size: mapSize)
            for folder in pendingFolders where chunk.count < size {
                guard let place = folderPlaces[folder], let p = point(for: place), bounds.contains(p) else { continue }
                take(from: folder, count: size)
            }
        }
        for folder in pendingFolders where chunk.count < size { take(from: folder, count: size) }
        pendingFolders.removeAll { pending[$0] == nil }
        return chunk
    }
    /// Folders a file was read from already for the first places.
    private var sampled: Set<String> = []

    private func startReading() {
        readTask = Task { [weak self] in
            var lastRebuild = Date.distantPast
            while let self, !Task.isCancelled {
                let chunk = self.nextChunk()
                if chunk.isEmpty { break }
                if self.total > Self.chunk { self.progress = BrowserModel.Progress(done: self.done, total: self.total) }
                let found = await self.readFacts(chunk)
                guard !Task.isCancelled else { return }
                self.known.merge(found) { _, new in new }
                for (url, facts) in found {
                    if let point = facts.place?.location.point {
                        self.folderPlaces[url.deletingLastPathComponent().path] = Coordinate(latitude: point.latitude, longitude: point.longitude)
                    }
                }
                self.done += chunk.count
                if self.progress != nil { self.progress = BrowserModel.Progress(done: self.done, total: self.total) }
                if self.pendingCount == 0 || Date().timeIntervalSince(lastRebuild) > 0.5 {
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
        }
    }

    /// Items known already, without a pane (tests).
    func load(_ given: [AtlasItem]) {
        apply(AtlasItems.prepared(given))
    }

    /// Whether every item's facts are read (and the items made of them shown).
    var isComplete: Bool { readTask == nil && pendingCount == 0 && !rebuilding }

    /// The pane's walk of the subfolders is still bringing items.
    @Published var walking = false { didSet { if !walking { fitIfNeeded() } } }

    private var rebuilding = false
    private var rebuildAgain = false

    /// The items made of what is known, off the main thread (100 000 items
    /// sort there, not under the user's hands), one making at a time.
    private func rebuild() {
        guard !rebuilding else { rebuildAgain = true; return }
        rebuilding = true
        rebuildAgain = false
        let entries = Array(media.values), known = self.known
        Task { [weak self] in
            let made = await Blocking.run(.userInitiated) {
                AtlasItems.prepared(entries.compactMap { entry -> AtlasItem? in
                    guard let facts = known[entry.url] else { return nil }
                    return AtlasItem.make(url: entry.url, isVideo: entry.kind == .video, facts: facts, modified: entry.modDate)
                })
            }
            guard let self else { return }
            self.rebuilding = false
            self.apply(made)
            if self.rebuildAgain { self.rebuild() }
        }
    }

    private func apply(_ made: [AtlasItem]) {
        items = made
        var index: [URL: Int] = [:]
        index.reserveCapacity(made.count)
        for (i, item) in made.enumerated() { index[item.url] = i }
        itemIndex = index
        if let range, let span, !(span.overlaps(range)) { self.range = nil }
        filter()
        // T while the places were read: the tour, once they are all there
        if tourWanted, isComplete {
            tourWanted = false
            startTour()
        }
    }

    // MARK: Timeline

    /// The timeline's from–to; nil: the whole span.
    @Published var range: ClosedRange<Date>? { didSet { if range != oldValue { filter() } } }

    /// From the first item's time to the last's (the items are in the order of time).
    var span: ClosedRange<Date>? {
        guard let first = items.first, let last = items.last else { return nil }
        return first.date...last.date
    }

    /// What the timeline lets through.
    var shown: [AtlasItem] { placed + unplaced }

    /// The time zone a moment is shown in: the clock of the item taken nearest it.
    func zone(at date: Date) -> TimeZone {
        AtlasTimeline.nearest(to: date, sorted: items[...])?.zone ?? .current
    }

    /// The items in the range: a slice found by binary search (they are in
    /// the order of time), so narrowing stays quick with 100 000.
    private func filter() {
        let shown = AtlasTimeline.slice(items, to: range)
        var onMap: [AtlasItem] = [], off: [AtlasItem] = []
        onMap.reserveCapacity(shown.count)
        for item in shown { if item.coordinate != nil { onMap.append(item) } else { off.append(item) } }
        placed = onMap
        unplaced = off
        fitIfNeeded()
        scheduleClusters()
    }

    /// A click on the timeline: the item nearest that time selected, the map on it.
    func jump(to date: Date) {
        guard let item = AtlasTimeline.nearest(to: date, sorted: AtlasTimeline.slice(items, to: range)) else { return }
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
            if let set = cameraSet, newValue != set, newValue != held(set), tour == nil {
                if Date().timeIntervalSince(cameraSetAt) < 0.3, let before = cameraBeforeSet, Self.near(newValue, held(before)) {
                    // The view's own camera, held in its new size and reported after the
                    // layout pass that set ours: ours stands
                    DispatchQueue.main.async { [weak self] in self?.setCamera(set) }
                } else {
                    userMovedMap = true
                }
            }
            if needsClusters(at: newValue) { scheduleClusters() }
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
    /// Moved by the user: it stays where they put it, no fit to the items any more.
    private(set) var userMovedMap = false { didSet { if userMovedMap { needsFit = false } } }

    /// The map moved as by the user (tests; the view's gestures come through `camera`).
    func moveByUser(to next: MapCamera) {
        userMovedMap = true
        setCamera(held(next))
    }

    /// For the UI tests (`--ui-testing`): the map's zoom and size, the clusters, the fit.
    var testState: String {
        String(format: "zoom %.2f, size %.0f×%.0f, clusters %d at %.2f, fit %@, moved %@",
               camera.zoom, mapSize.width, mapSize.height, clusters.count, clusterZoom ?? -1,
               needsFit ? "pending" : "done", userMovedMap ? "yes" : "no")
    }
    private var cameraSet: MapCamera?
    private var cameraSetAt = Date.distantPast
    /// The camera before the last one set here: the map view may report it
    /// once more, held in its new size, after the layout pass.
    private var cameraBeforeSet: MapCamera?

    private func setCamera(_ next: MapCamera) {
        cameraBeforeSet = camera
        cameraSet = next
        cameraSetAt = Date()
        camera = next
    }

    private static func near(_ a: MapCamera, _ b: MapCamera) -> Bool {
        abs(a.zoom - b.zoom) < 1e-6 && abs(a.center.latitude - b.center.latitude) < 1e-6
            && abs(a.center.longitude - b.center.longitude) < 1e-6
    }

    /// The camera within the map's limits: zoomed out, the globe's
    /// (`GlobeProjection.minZoom`); from the flat zoom on, the flat map's.
    func held(_ c: MapCamera) -> MapCamera {
        guard mapSize.width > 0, mapSize.height > 0 else { return c }
        var next = c
        next.zoom = min(MapViewport.maxZoom, max(GlobeProjection.minZoom(for: mapSize), c.zoom))
        if GlobeProjection(camera: next, size: mapSize).isFlat { next = MapViewport(camera: next, size: mapSize).panned(by: 0, 0) }
        return next
    }

    /// Where a place is in the map view, on the globe or the flat map; nil on the globe's far side.
    func point(for coordinate: Coordinate) -> CGPoint? {
        let projection = GlobeProjection(camera: camera, size: mapSize)
        return projection.isVisible(coordinate) ? projection.point(for: coordinate) : nil
    }

    /// The map shows the globe (or is flattening into the flat map).
    var showsGlobe: Bool { mapSize.width > 0 && !GlobeProjection(camera: camera, size: mapSize).isFlat }

    private func fitIfNeeded() {
        let done = isComplete && !walking
        guard tour == nil, mapSize.width > 40, mapSize.height > 40, !placed.isEmpty, needsFit || (!done && !userMovedMap) else { return }
        fitAll()
        if done { needsFit = false }
    }

    /// Shows every item on the map.
    func fitAll() {
        guard let fitted = MapCamera.fitting(placed.compactMap(\.coordinate), in: mapSize, padding: 70, maxZoom: 11) else { return }
        setCamera(held(fitted))
    }

    /// Moves the map so the place is in view (at once when it already is).
    func reveal(_ coordinate: Coordinate) {
        guard mapSize.width > 0 else { return }
        if let p = point(for: coordinate), CGRect(origin: .zero, size: mapSize).insetBy(dx: 40, dy: 40).contains(p) { return }
        setCamera(held(MapCamera(center: coordinate, zoom: camera.zoom)))
    }

    /// A double click on a cluster: the map zooms until its items part.
    func zoom(into cluster: AtlasCluster) {
        let coordinates = cluster.ids.compactMap { item($0)?.coordinate }
        let fitted = MapCamera.fitting(coordinates, in: mapSize, padding: 90, maxZoom: MapViewport.maxZoom)
        let zoom = max(camera.zoom + 2, fitted?.zoom ?? 0)
        let target = held(MapCamera(center: fitted?.center ?? cluster.coordinate, zoom: min(MapViewport.maxZoom, zoom)))
        userMovedMap = true
        setCamera(target)
    }

    /// + / − in the Atlas: the map zooms a step about its middle.
    func zoomStep(_ steps: Double) {
        guard mapSize.width > 0 else { return }
        userMovedMap = true
        setCamera(held(MapCamera(center: camera.center, zoom: camera.zoom + steps)))
    }

    // MARK: Clusters (off the main thread)

    @Published private(set) var clusters: [AtlasCluster] = []
    /// The zoom the clusters were made for (on the flat map moving needs no new ones).
    private(set) var clusterZoom: Double?
    /// The camera they were made for on the globe (turning it changes what is close on screen).
    private var clusterCamera: MapCamera?
    private var clustering = false
    private var clusterAgain = false

    /// On the flat map in world points at the zoom, on the globe on screen
    /// (what lies on the far side left out).
    private func needsClusters(at c: MapCamera) -> Bool {
        if mapSize.width > 0, !GlobeProjection(camera: c, size: mapSize).isFlat { return c != clusterCamera }
        return clusterCamera != nil || abs(c.zoom - (clusterZoom ?? -1)) > 0.001
    }

    private nonisolated static func make(_ points: [(id: URL, coordinate: Coordinate)], camera: MapCamera,
                                         size: CGSize) -> [AtlasCluster] {
        guard size.width > 0 else { return AtlasClustering.clusters(of: points, zoom: camera.zoom) }
        let projection = GlobeProjection(camera: camera, size: size)
        if projection.isFlat { return AtlasClustering.clusters(of: points, zoom: camera.zoom) }
        return AtlasClustering.clusters(of: points) { projection.isVisible($0) ? projection.point(for: $0) : nil }
    }

    private func scheduleClusters() {
        guard !clustering else { clusterAgain = true; return }
        clustering = true
        clusterAgain = false
        let points = placed.map { (id: $0.url, coordinate: $0.coordinate!) }
        let camera = self.camera, size = mapSize
        let onGlobe = showsGlobe
        Task { [weak self] in
            let made = await Blocking.run(.userInitiated) { AtlasModel.make(points, camera: camera, size: size) }
            guard let self else { return }
            self.clusters = made
            self.clusterZoom = camera.zoom
            self.clusterCamera = onGlobe ? camera : nil
            self.clustering = false
            if self.clusterAgain || self.needsClusters(at: self.camera) { self.scheduleClusters() }
        }
    }

    /// Made at once (tests).
    func clusterNow() {
        let onGlobe = showsGlobe
        clusters = Self.make(placed.map { (id: $0.url, coordinate: $0.coordinate!) }, camera: camera, size: mapSize)
        clusterZoom = camera.zoom
        clusterCamera = onGlobe ? camera : nil
    }

    // MARK: Selection

    /// The item selected in the pane (the grid's and the list's selection).
    var selectedURL: URL? {
        guard let entry = browser?.selectedEntry, entry.isMedia else { return nil }
        return entry.url
    }

    func item(_ url: URL) -> AtlasItem? { itemIndex[url].map { items[$0] } }

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
        let bounds = CGRect(origin: .zero, size: mapSize).insetBy(dx: -margin, dy: -margin)
        return clusters.compactMap { cluster in
            guard let p = point(for: cluster.coordinate), bounds.contains(p) else { return nil }
            return (cluster, p)
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
    /// The place stands left of the middle (at `TourFlight.placeShare` of
    /// the width), where the card with its photo leaves the map free.
    func camera(for station: TourStation) -> MapCamera {
        let centred = MapViewport(camera: MapCamera(center: station.coordinate, zoom: TourFlight.zoom(for: station, size: mapSize)),
                                  size: mapSize)
        let middle = centred.coordinate(at: CGPoint(x: mapSize.width * (1 - TourFlight.placeShare), y: mapSize.height / 2))
        return held(MapCamera(center: middle, zoom: centred.camera.zoom))
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
