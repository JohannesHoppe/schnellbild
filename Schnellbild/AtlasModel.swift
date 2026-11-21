import SwiftUI
import AppKit
import OfflineMap

/// The Atlas view of one pane (W): the pane's photos and videos (the
/// folder's, or a search's from every subfolder) at their places on the
/// offline map, the timeline under it and the tour. The items are the
/// pane's `entries`, so the selection is the grid's and the list's.
/// Times and places come from `LocationCache` (`CaptureFacts`), read off
/// the main thread eight files at a time while the Atlas is shown.
/// Whatever walks every item (the pane's list taken over, the items made
/// of the facts, the fit of the map, the clusters' input) runs off the main
/// thread; the main thread takes the results and narrows them to the
/// timeline's range by binary search (`work` counts both, for the tests).
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

    /// The passes over every item, by the number of items each walked, on
    /// the main thread or off it.
    final class WorkMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var main = 0, background = 0

        nonisolated func walked(_ count: Int) {
            let onMain = Thread.isMainThread
            lock.withLock { if onMain { main += count } else { background += count } }
        }

        nonisolated var counts: (onMain: Int, offMain: Int) { lock.withLock { (main, background) } }
    }
    nonisolated let work = WorkMeter()

    // MARK: Items

    /// Every photo and video whose facts are read, in the order of time.
    @Published private(set) var items: [AtlasItem] = []
    /// What the timeline lets through: on the map (`placed`) or in the strip
    /// under it (`unplaced`), each a part of all of them in the order of time.
    @Published private(set) var placed: ArraySlice<AtlasItem> = []
    @Published private(set) var unplaced: ArraySlice<AtlasItem> = []
    /// While facts are read: how many of how many.
    @Published private(set) var progress: BrowserModel.Progress?
    /// What the strip under the map shows, in an object of its own: the strip
    /// follows only it, not every change of the Atlas (a step of the reading).
    let strip = StripState()
    final class StripState: ObservableObject {
        @Published fileprivate(set) var items: ArraySlice<AtlasItem> = []
    }

    /// Everything made of the facts at once, off the main thread.
    private struct Made: Sendable {
        var items: [AtlasItem] = []
        /// Where each item is in `items`.
        var index: [URL: Int] = [:]
        /// The items with a place and those without, each in the order of time.
        var placed: [AtlasItem] = []
        var unplaced: [AtlasItem] = []
        /// `placed`'s places, for the clusters and the fit.
        var points: [(id: URL, coordinate: Coordinate)] = []
        /// Where each item without a place is in `unplaced`.
        var unplacedIndex: [URL: Int] = [:]
        /// `unplaced` is the one made before (the strip needn't hear of it).
        var sameUnplaced = false

        nonisolated init() {}

        nonisolated init(_ made: [AtlasItem]) {
            items = made
            index.reserveCapacity(made.count)
            for (i, item) in made.enumerated() {
                index[item.url] = i
                if let coordinate = item.coordinate {
                    placed.append(item)
                    points.append((item.url, coordinate))
                } else {
                    unplacedIndex[item.url] = unplaced.count
                    unplaced.append(item)
                }
            }
        }
    }
    private var made = Made()
    /// `placed`'s places (a part of `made.points`, the same range).
    private var placedPoints: ArraySlice<(id: URL, coordinate: Coordinate)> = []

    /// What is known of a file: its facts and the modification date they were read for.
    private struct Known: Sendable {
        var modified: Date?
        var facts: CaptureFacts
    }

    private var media: [URL: GridEntry] = [:]
    /// Only the small facts (time, place, a video's route of at most 500
    /// points), never pictures: a tree of 100 000 photos stays a few tens of MB.
    private var known: [URL: Known] = [:]
    /// What waits to be read, by folder (in the order the pane lists them).
    private struct Pending: Sendable {
        var lists: [String: [(url: URL, modified: Date?)]] = [:]
        var folders: [String] = []
        var urls: Set<URL> = []
        var count = 0

        nonisolated init() {}

        /// Files put in by their folder, each once.
        nonisolated mutating func add<Files: Sequence<GridEntry>>(_ entries: Files) {
            for entry in entries where urls.insert(entry.url).inserted {
                let folder = entry.url.deletingLastPathComponent().path
                if lists[folder] == nil { lists[folder] = []; folders.append(folder) }
                lists[folder]!.append((entry.url, entry.modDate))
                count += 1
            }
        }
    }
    private var pending = Pending()
    /// A known place of each folder: its other items come first while it is in view.
    private var folderPlaces: [String: Coordinate] = [:]
    private var readTask: Task<Void, Never>?
    private var done = 0, total = 0
    /// The folder and query the items belong to: another one starts afresh.
    private var context = ""
    /// Not shown (another view, the window closed): nothing is read.
    private var paused = true
    /// Folders changed on disk (FSEvents) whose known files are read again
    /// (nil inside: every folder), kept while the Atlas isn't shown.
    private var changedFolders: Set<String>? = []
    /// The pane's list being taken over off the main thread (`refreshMedia`).
    private var mediaGeneration = 0
    private var makingMedia = false
    /// What the walk added meanwhile (it goes in once the list is there).
    private var addedMeanwhile: [GridEntry] = []

    /// The pane's list changed (or the Atlas is shown): read what is new,
    /// what changed on disk since it was read (its modification date) and
    /// what lies in a folder that changed (`foldersChanged`).
    func entriesChanged(_ entries: [GridEntry], context newContext: String) {
        startContext(newContext)
        paused = false
        refreshMedia(from: entries)
    }

    /// Items added to the pane's list (the walk of the subfolders): only
    /// they are looked at, not the whole list again.
    func entriesAdded(_ added: [GridEntry], context newContext: String) {
        guard newContext == context else { return }
        paused = false
        let fresh = added.filter { $0.isMedia && media[$0.url] == nil }
        if makingMedia { addedMeanwhile += fresh }
        for entry in fresh { media[entry.url] = entry }
        queue(fresh.filter { Self.needsReading($0, in: known, changed: changedFolders) })
        if fresh.contains(where: { known[$0.url] != nil }) { rebuild() }
    }

    /// Folders whose contents changed on disk (FSEvents; nil: too many to
    /// name): the files known there are read again, now or once the Atlas
    /// is shown (a sidecar or a GPX track beside them may give another place
    /// or time; unchanged ones come from `LocationCache` at once).
    /// (`folders`: canonical paths, `BrowserModel.canonicalPath`, as FSEvents' are taken)
    func foldersChanged(_ folders: [String]?) {
        if let folders, changedFolders != nil {
            changedFolders!.formUnion(folders)
        } else if folders == nil {
            changedFolders = nil
        }
        guard !paused, !media.isEmpty else { return }
        refreshMedia(from: nil)
    }

    /// Whether a file is read (again): not known, changed since it was
    /// read, or in a folder that changed.
    private nonisolated static func needsReading(_ entry: GridEntry, in known: [URL: Known], changed: Set<String>?) -> Bool {
        guard let read = known[entry.url] else { return true }
        if read.modified != entry.modDate { return true }
        guard let changed else { return true }
        return !changed.isEmpty && changed.contains(BrowserModel.canonicalPath(entry.url.deletingLastPathComponent()))
    }

    /// Takes over the pane's list (`entries`, or the one known when nil)
    /// off the main thread: the media by URL and what is to be read, by folder.
    private func refreshMedia(from entries: [GridEntry]?) {
        mediaGeneration += 1
        let generation = mediaGeneration
        makingMedia = true
        addedMeanwhile = []
        let current = media, known = self.known, changed = changedFolders, work = self.work
        changedFolders = []
        Task { [weak self] in
            let (media, toRead) = await Blocking.run(.userInitiated) { () -> ([URL: GridEntry], Pending) in
                var media: [URL: GridEntry]
                if let entries {
                    work.walked(entries.count)
                    media = [:]
                    media.reserveCapacity(entries.count)
                    for entry in entries where entry.isMedia { media[entry.url] = entry }
                } else {
                    media = current
                }
                work.walked(media.count)
                var toRead = Pending()
                // In the pane's order where it is given
                if let entries {
                    toRead.add(entries.lazy.filter { $0.isMedia && AtlasModel.needsReading($0, in: known, changed: changed) })
                } else {
                    toRead.add(media.values.lazy.filter { AtlasModel.needsReading($0, in: known, changed: changed) })
                }
                return (media, toRead)
            }
            guard let self, self.mediaGeneration == generation else { return }
            var all = media
            var late: [GridEntry] = []
            for entry in self.addedMeanwhile where all[entry.url] == nil {
                all[entry.url] = entry
                late.append(entry)
            }
            self.media = all
            self.makingMedia = false
            self.addedMeanwhile = []
            self.queue(toRead)
            self.queue(late.filter { AtlasModel.needsReading($0, in: self.known, changed: []) })
            self.rebuild()
        }
    }

    private func startContext(_ newContext: String) {
        guard newContext != context else { return }
        context = newContext
        readTask?.cancel()
        readTask = nil
        pending = Pending()
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
        guard !entries.isEmpty else { return }
        let before = pending.count
        pending.add(entries)
        total += pending.count - before
        if readTask == nil, pending.count > 0 { startReading() }
    }

    /// The same for files grouped off the main thread: taken as they are
    /// when nothing waits (the whole list at once), else merged.
    private func queue(_ more: Pending) {
        guard more.count > 0 else { return }
        if pending.count == 0 {
            pending = more
            total += more.count
        } else {
            let before = pending.count
            for folder in more.folders { pending.add(more.lists[folder]!.lazy.compactMap { self.media[$0.url] }) }
            total += pending.count - before
        }
        if readTask == nil, pending.count > 0 { startReading() }
    }

    /// Stops reading (another view chosen); what is known stays.
    func pause() {
        paused = true
        mediaGeneration += 1
        makingMedia = false
        addedMeanwhile = []
        readTask?.cancel()
        readTask = nil
        pending = Pending()
        sampled = []
        tourWanted = false
        progress = nil
        done = 0
        total = 0
    }

    /// The window showing the pane closed: the tour ends without leaving
    /// full screen (another window may be in full screen by now), the
    /// reading stops. A window that takes the model again reads afresh.
    func leaveWindow() {
        tourEnteredFullScreen = false
        if tour != nil { endTour() }
        pause()
    }

    /// Files read per step.
    nonisolated static let chunk = 64

    /// The next files to read, the most wanted first: the selected item's
    /// folder; then one file of every folder not yet sampled (so every place
    /// shows early); then the folders with a place in view; then the rest
    /// in the pane's order.
    func nextChunk() -> [(url: URL, modified: Date?)] {
        let size = Self.chunk
        var chunk: [(url: URL, modified: Date?)] = []
        func take(from folder: String, count: Int) {
            guard var list = pending.lists[folder], !list.isEmpty, count > 0 else { return }
            let n = min(count, list.count, size - chunk.count)
            chunk += list.prefix(n)
            for file in list.prefix(n) { pending.urls.remove(file.url) }
            list.removeFirst(n)
            pending.count -= n
            pending.lists[folder] = list.isEmpty ? nil : list
        }
        if let selected = browser?.selectedEntry, selected.isMedia {
            take(from: selected.url.deletingLastPathComponent().path, count: size)
        }
        for folder in pending.folders where chunk.count < size && folderPlaces[folder] == nil && !sampled.contains(folder) {
            sampled.insert(folder)
            take(from: folder, count: 1)
        }
        if chunk.count < size, mapSize.width > 0 {
            let bounds = CGRect(origin: .zero, size: mapSize)
            for folder in pending.folders where chunk.count < size {
                guard let place = folderPlaces[folder], let p = point(for: place), bounds.contains(p) else { continue }
                take(from: folder, count: size)
            }
        }
        for folder in pending.folders where chunk.count < size { take(from: folder, count: size) }
        // (the lists read apart from the change: one access to `pending` at a time)
        let lists = pending.lists
        pending.folders.removeAll { lists[$0] == nil }
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
                for file in chunk {
                    guard let facts = found[file.url] else { continue }
                    self.known[file.url] = Known(modified: file.modified, facts: facts)
                    if let point = facts.place?.location.point {
                        self.folderPlaces[file.url.deletingLastPathComponent().path] = point.coordinate
                    }
                }
                self.done += chunk.count
                if self.progress != nil { self.progress = BrowserModel.Progress(done: self.done, total: self.total) }
                if self.pending.count == 0 || Date().timeIntervalSince(lastRebuild) > 0.5 {
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
        apply(Made(AtlasItems.prepared(given)))
    }

    /// Whether every item's facts are read (and the items made of them shown).
    var isComplete: Bool { readTask == nil && pending.count == 0 && !makingMedia && !rebuilding && !rebuildAgain }

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
        let media = self.media, known = self.known, work = self.work, before = made.unplaced
        Task { [weak self] in
            let made = await Blocking.run(.userInitiated) { () -> Made in
                work.walked(media.count)
                var made = Made(AtlasItems.prepared(media.values.compactMap { entry -> AtlasItem? in
                    guard let read = known[entry.url] else { return nil }
                    return AtlasItem.make(url: entry.url, isVideo: entry.kind == .video, facts: read.facts, modified: entry.modDate)
                }))
                made.sameUnplaced = made.unplaced == before
                return made
            }
            guard let self else { return }
            self.rebuilding = false
            self.apply(made)
            if self.rebuildAgain { self.rebuild() }
        }
    }

    private func apply(_ next: Made) {
        made = next
        if !next.sameUnplaced { unplacedVersion += 1 }
        items = next.items
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

    /// From the first item's time to the last's (the items are in the order
    /// of time; those without a time are left out).
    var span: ClosedRange<Date>? { AtlasTimeline.span(sorted: items) }

    /// What the timeline lets through (tests; the view counts `shownCount`).
    var shown: [AtlasItem] {
        work.walked(placed.count + unplaced.count)
        return Array(placed) + Array(unplaced)
    }
    var shownCount: Int { placed.count + unplaced.count }

    /// The time zone a moment is shown in: the clock of the item taken nearest it.
    func zone(at date: Date) -> TimeZone {
        AtlasTimeline.nearest(to: date, sorted: items[...])?.zone ?? .current
    }

    /// The items in the range: parts found by binary search (each list is in
    /// the order of time), so narrowing stays quick with 100 000.
    private func filter() {
        let onMap = AtlasTimeline.slice(made.placed, to: range)
        placed = onMap
        placedPoints = made.points[onMap.indices]
        let off = AtlasTimeline.slice(made.unplaced, to: range)
        // (the strip is told only when its part changed)
        if off.indices != unplaced.indices || stripVersion != unplacedVersion {
            unplaced = off
            strip.items = off
            stripVersion = unplacedVersion
        }
        fitInputs += 1
        fitIfNeeded()
        scheduleClusters()
    }
    /// Counts new lists of the items without a place; `stripVersion`: the one the strip shows a part of.
    private var unplacedVersion = 0, stripVersion = 0

    /// Whether an item is in the strip under the map now.
    func isInStrip(_ url: URL) -> Bool {
        guard let index = made.unplacedIndex[url] else { return false }
        return unplaced.indices.contains(index)
    }

    /// A click on the timeline: the item nearest that time selected, the map on it.
    func jump(to date: Date) {
        guard let item = AtlasTimeline.nearest(to: date, sorted: AtlasTimeline.slice(items, to: range)) else { return }
        select(item.url)
        if let coordinate = item.coordinate { reveal(coordinate) }
    }

    /// The first and the last item in time of those shown (Home, End).
    var firstShown: AtlasItem? {
        [placed.first, unplaced.first].compactMap { $0 }.min { $0.date < $1.date }
    }
    var lastShown: AtlasItem? {
        [placed.last, unplaced.last].compactMap { $0 }.max { $0.date < $1.date }
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
                userMovedMap = true
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
            fitInputs += 1
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

    /// For the UI tests (`--ui-testing`): the map's zoom, centre, tilt, heading and size, the clusters, the fit,
    /// the map's own movements and how far its throws carried it (points, all added up: not folded into a turn).
    var testState: String {
        let motion = MapMotion.counts
        return String(format: "zoom %.2f, center %.3f %.3f, pitch %.1f, heading %.1f, size %.0f×%.0f, clusters %d at %.2f, fit %@, moved %@, "
                      + "glides %d, throws %d, fades %d, thrown %.0f",
                      camera.zoom, camera.center.latitude, camera.center.longitude, camera.pitch, camera.heading, mapSize.width, mapSize.height,
                      clusters.count, clusterZoom ?? -1, needsFit ? "pending" : "done", userMovedMap ? "yes" : "no",
                      motion["glide"] ?? 0, motion["throw"] ?? 0, motion["fade"] ?? 0, MapMotion.thrownPoints)
    }
    private var cameraSet: MapCamera?

    private func setCamera(_ next: MapCamera) {
        cameraSet = next
        camera = next
    }

    /// The camera within the map's limits: zoomed out, the globe's
    /// (`GlobeProjection.minZoom`); where the flat map shows (from the flat
    /// zoom straight down, from `GlobeProjection.straightZoom` with a tilt
    /// chosen), the flat map's. A tilt chosen stays at every zoom.
    func held(_ c: MapCamera) -> MapCamera {
        guard mapSize.width > 0, mapSize.height > 0 else { return c }
        var next = GlobeProjection.held(c, size: mapSize)
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

    /// Changes of what the fit depends on (the places shown, the map's size).
    private var fitInputs = 0
    private var fitting = false

    /// Fits the map to the places shown while it should (`needsFit`, or
    /// while they still come in and the user hasn't moved it): worked out
    /// off the main thread, again when the places or the size changed meanwhile.
    private func fitIfNeeded() {
        guard wantsFit else { return }
        if let given = Self.testCamera {
            setCamera(held(given))
            if isComplete && !walking { needsFit = false }
            return
        }
        guard !fitting else { return }
        fitting = true
        let inputs = fitInputs, points = placedPoints, size = mapSize, work = self.work
        Task { [weak self] in
            let fitted = await Blocking.run(.userInitiated) { () -> MapCamera? in
                work.walked(points.count)
                return MapCamera.fitting(points.map(\.coordinate), in: size, padding: 70, maxZoom: 11)
            }
            guard let self else { return }
            self.fitting = false
            guard inputs == self.fitInputs else { self.fitIfNeeded(); return }
            guard self.wantsFit, let fitted else { return }
            self.setCamera(self.held(self.keepingTilt(fitted)))
            if self.isComplete && !self.walking { self.needsFit = false }
        }
    }

    private var wantsFit: Bool {
        let done = isComplete && !walking
        return tour == nil && mapSize.width > 40 && mapSize.height > 40 && !placed.isEmpty && (needsFit || (!done && !userMovedMap))
    }

    /// Shows every item on the map at once (tests; the app fits through
    /// `fitIfNeeded`, off the main thread). Under `--ui-testing`,
    /// `--globe-camera=` shows the camera given instead.
    func fitAll() {
        if let given = Self.testCamera {
            setCamera(held(given))
            return
        }
        work.walked(placed.count)
        guard let fitted = MapCamera.fitting(placed.compactMap(\.coordinate), in: mapSize, padding: 70, maxZoom: 11) else { return }
        setCamera(held(keepingTilt(fitted)))
    }

    /// A fitted camera with the tilt and heading chosen (the tilt is a
    /// setting: what of it shows follows the fitted zoom, `GlobeProjection.tiltShare`).
    private func keepingTilt(_ fitted: MapCamera) -> MapCamera {
        var next = fitted
        next.pitch = camera.pitch
        next.heading = camera.heading
        return next
    }

    /// The screenshots' camera: `--globe-camera=<latitude>,<longitude>,<zoom>,<pitch>,<heading>` (UI tests only).
    static let testCamera: MapCamera? = {
        guard let argument = TestSwitches.value("--globe-camera=") else { return nil }
        let v = argument.split(separator: ",").compactMap { Double($0) }
        guard v.count == 5 else { return nil }
        return MapCamera(center: Coordinate(latitude: v[0], longitude: v[1]), zoom: v[2], pitch: v[3], heading: v[4])
    }()

    /// The screenshots' moment for the Sun: `--globe-date=<ISO 8601>` (UI tests only).
    static let testSunDate: Date? = {
        TestSwitches.value("--globe-date=").flatMap { ISO8601DateFormatter().date(from: $0) }
    }()

    /// Moves the map so the place is in view (at once when it already is).
    func reveal(_ coordinate: Coordinate) {
        guard mapSize.width > 0 else { return }
        if let p = point(for: coordinate), CGRect(origin: .zero, size: mapSize).insetBy(dx: 40, dy: 40).contains(p) { return }
        setCamera(held(MapCamera(center: coordinate, zoom: camera.zoom, pitch: camera.pitch, heading: camera.heading)))
    }

    /// A double click on a cluster: the map zooms until its items part.
    func zoom(into cluster: AtlasCluster) {
        let coordinates = cluster.ids.compactMap { item($0)?.coordinate }
        let fitted = MapCamera.fitting(coordinates, in: mapSize, padding: 90, maxZoom: MapViewport.maxZoom)
        let zoom = max(camera.zoom + 2, fitted?.zoom ?? 0)
        let target = held(MapCamera(center: fitted?.center ?? cluster.coordinate, zoom: min(MapViewport.maxZoom, zoom),
                                    pitch: camera.pitch, heading: camera.heading))
        userMovedMap = true
        setCamera(target)
    }

    /// + / − in the Atlas: the map zooms a step about its middle.
    func zoomStep(_ steps: Double) {
        guard mapSize.width > 0 else { return }
        userMovedMap = true
        setCamera(held(MapCamera(center: camera.center, zoom: camera.zoom + steps, pitch: camera.pitch, heading: camera.heading)))
    }

    // MARK: Clusters (off the main thread)

    @Published private(set) var clusters: [AtlasCluster] = []
    /// The zoom the clusters were made for (on the flat map moving needs no new ones).
    private(set) var clusterZoom: Double?
    /// The camera they were made for on the globe (turning it changes what is close on screen).
    private(set) var clusterCamera: MapCamera?
    private var clustering = false
    private var clusterAgain = false

    /// On the flat map in world points at the zoom, on the globe on screen
    /// (what lies on the far side left out).
    private func needsClusters(at c: MapCamera) -> Bool {
        if mapSize.width > 0, !GlobeProjection(camera: c, size: mapSize).isFlat { return c != clusterCamera }
        return clusterCamera != nil || abs(c.zoom - (clusterZoom ?? -1)) > 0.001
    }

    private nonisolated static func make(_ points: ArraySlice<(id: URL, coordinate: Coordinate)>, camera: MapCamera,
                                         size: CGSize) -> [AtlasCluster] {
        let points = Array(points)
        guard size.width > 0 else { return AtlasClustering.clusters(of: points, zoom: camera.zoom) }
        let projection = GlobeProjection(camera: camera, size: size)
        if projection.isFlat { return AtlasClustering.clusters(of: points, zoom: camera.zoom) }
        return AtlasClustering.clusters(of: points) { projection.isVisible($0) ? projection.point(for: $0) : nil }
    }

    private func scheduleClusters() {
        guard !clustering else { clusterAgain = true; return }
        clustering = true
        clusterAgain = false
        let points = placedPoints, work = self.work
        let camera = self.camera, size = mapSize
        let onGlobe = showsGlobe
        Task { [weak self] in
            let made = await Blocking.run(.userInitiated) { () -> [AtlasCluster] in
                work.walked(points.count)
                return AtlasModel.make(points, camera: camera, size: size)
            }
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
        work.walked(placedPoints.count)
        clusters = Self.make(placedPoints, camera: camera, size: mapSize)
        clusterZoom = camera.zoom
        clusterCamera = onGlobe ? camera : nil
    }

    // MARK: Selection

    /// The item selected in the pane (the grid's and the list's selection).
    var selectedURL: URL? {
        guard let entry = browser?.selectedEntry, entry.isMedia else { return nil }
        return entry.url
    }

    func item(_ url: URL) -> AtlasItem? { made.index[url].map { items[$0] } }

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

    /// A tile clicked: its cluster's first item, or the selection when it is
    /// inside already. Items taken at one place (`staysTogether`: zooming in
    /// doesn't part them) take turns: each click selects the next.
    func click(_ cluster: AtlasCluster) {
        if let selected = selectedURL, let index = cluster.ids.firstIndex(of: selected) {
            if cluster.staysTogether { select(cluster.ids[(index + 1) % cluster.ids.count]) }
            return
        }
        select(cluster.ids[0])
    }

    /// The clusters on screen with their points.
    func visibleClusters() -> [(cluster: AtlasCluster, point: CGPoint)] {
        let bounds = CGRect(origin: .zero, size: mapSize)
        return clusters.compactMap { cluster in
            guard let p = point(for: cluster.coordinate), bounds.contains(p) else { return nil }
            return (cluster, p)
        }
    }

    /// The arrow keys: to the nearest tile on screen that way; down from the
    /// lowest tile into the strip of items without a place, up out of it.
    /// On a tile of items taken at one place, ← → go through them first.
    /// Without a selection on screen, the tile nearest the middle.
    func move(_ direction: AtlasDirection) {
        let visible = visibleClusters()
        if let selected = selectedURL, isInStrip(selected), let index = made.unplacedIndex[selected] {
            switch direction {
            case .left:  if unplaced.indices.contains(index - 1) { select(unplaced[index - 1].url) }
            case .right: if unplaced.indices.contains(index + 1) { select(unplaced[index + 1].url) }
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
        if current.cluster.staysTogether, let selected = selectedURL, let index = current.cluster.ids.firstIndex(of: selected) {
            let next = direction == .right ? index + 1 : direction == .left ? index - 1 : index
            if next != index, current.cluster.ids.indices.contains(next) { select(current.cluster.ids[next]); return }
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
    /// (`placed` is prepared already: grouped in one pass, no sorting again)
    var stations: [TourStation] {
        work.walked(placed.count)
        return TourPlanner.stations(fromPrepared: placed)
    }

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
    /// the width), where the card with its photo leaves the map free: placed
    /// through the projection that zoom shows, the globe's too (on a sphere
    /// a degree of longitude in the north is wider than on the flat map).
    func camera(for station: TourStation) -> MapCamera {
        guard mapSize.width > 0, mapSize.height > 0 else { return MapCamera(center: station.coordinate, zoom: TourFlight.zoom(for: station, size: mapSize)) }
        let zoom = held(MapCamera(center: station.coordinate, zoom: TourFlight.zoom(for: station, size: mapSize))).zoom
        let spot = CGPoint(x: mapSize.width * TourFlight.placeShare, y: mapSize.height / 2)
        return held(GlobeProjection.camera(placing: station.coordinate, at: spot, zoom: zoom, size: mapSize))
    }

    /// The route up to where the tour is: to the station it flies to or shows.
    var routeSoFar: [Coordinate] {
        guard let tour, arrivals.indices.contains(tour.station) else { return [] }
        let end = tour.station + 1 < arrivals.count ? arrivals[tour.station + 1] : route.count
        return Array(route.prefix(tour.phase == .flying ? arrivals[tour.station] + 1 : end))
    }

    /// Steps the tour: each step (a flight, an item shown) lasts its time
    /// on the clock, not counting the time paused; the flight moves the
    /// camera on the way (cut with Reduce motion). The time is read from the
    /// clock at each tick: a tick's sleep can last longer than asked (seen
    /// on CI: about twice as long).
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
                let clock = ContinuousClock()
                var last = clock.now
                while elapsed < duration {
                    try? await Task.sleep(for: .seconds(1.0 / 60))
                    let now = clock.now
                    let passed = (now - last) / .seconds(1)
                    last = now
                    if Task.isCancelled || self.tourStep != step || self.tour == nil { break }
                    if self.tour?.paused == false { elapsed += passed }
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
            if let first = atlas.firstShown { atlas.select(first.url); first.coordinate.map(atlas.reveal) }
            return true
        case .end:
            if let last = atlas.lastShown { atlas.select(last.url); last.coordinate.map(atlas.reveal) }
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
