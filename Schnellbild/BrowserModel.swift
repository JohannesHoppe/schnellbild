import SwiftUI
import AppKit
import AVFoundation

/// A grid entry: ".." (parent level), subfolder, image, or video.
struct GridEntry: Identifiable, Hashable {
    enum Kind { case parent, folder, image, video }
    let url: URL
    let kind: Kind
    var modDate: Date? = nil
    var byteSize: Int? = nil

    var id: URL { url }
    var name: String { kind == .parent ? ".." : url.lastPathComponent }
    var isMedia: Bool { kind == .image || kind == .video }
    var isGIF: Bool { kind == .image && url.pathExtension.lowercased() == "gif" }
}

/// Transport control of the video currently on screen. Implemented for AVKit
/// and for VLCKit, so the keyboard drives both players the same way.
@MainActor
protocol PlaybackControl: AnyObject {
    func play()
    func pause()
    func seek(by seconds: Double)
}

/// Side effects on the file system and the workspace. Injectable, so tests
/// can observe them without touching Finder, the Trash, or modal alerts.
struct FileActions {
    var reveal: @MainActor (URL) -> Void
    var openInDefaultApp: @MainActor (URL) -> Void
    var confirmTrash: @MainActor (_ name: String) -> Bool
    var trash: @MainActor (URL) throws -> Void
    var move: @MainActor (_ from: URL, _ to: URL) throws -> Void

    static let live = FileActions(
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        openInDefaultApp: { NSWorkspace.shared.open($0) },
        confirmTrash: { name in
            let alert = NSAlert()
            alert.messageText = "Move “\(name)” to the Trash?"
            alert.informativeText = "The item will be moved to the Trash."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        },
        trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        move: { from, to in
            let fm = FileManager.default
            // FileManager refuses a case-only rename ("photos" → "Photos") on
            // case-insensitive volumes, because the target "exists"; go via a
            // temporary name.
            if from.path != to.path, from.path.lowercased() == to.path.lowercased() {
                let temp = from.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: from, to: temp)
                try fm.moveItem(at: temp, to: to)
            } else {
                try fm.moveItem(at: from, to: to)
            }
        }
    )
}

/// Why a folder rename was rejected.
enum RenameError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case alreadyExists(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:            return "Please enter a name."
        case .invalidName:          return "Names can't contain “/” or “:”, and can't be “.” or “..”."
        case .alreadyExists(let n): return "An item named “\(n)” already exists here."
        case .failed(let reason):   return reason
        }
    }
}

/// Single source of truth for all browsing.
@MainActor
final class BrowserModel: ObservableObject {
    enum Mode { case grid, detail }
    enum SortKey { case name, date, size }
    enum KeyInput: Equatable {
        case left, right, up, down, space, enter, escape, backspace, home, end, f1, f2
        case char(Character)
    }

    /// A place in the navigation history: a folder, the search shown in it,
    /// and the selected item.
    struct Location: Equatable {
        var folder: URL
        var query: String = ""
        var selected: URL? = nil
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var entries: [GridEntry] = [] {
        didSet { recomputeDerived() }
    }
    @Published var selection: Int?
    @Published var mode: Mode = .grid
    @Published var showInspector = false
    @Published var showHelp = false
    @Published private(set) var isLoading = false

    /// Set by the grid based on window width — for row-accurate ↑/↓.
    @Published var columnCount: Int = 1
    /// Tile size in the grid (⌘+/⌘-).
    @Published var thumbnailSide: CGFloat = 150

    /// Zoom of the image full-size view (1 = fit to window).
    @Published var zoom: CGFloat = 1
    /// Set by the full-size view: factor that corresponds to 100 % actual pixels.
    @Published var actualSizeFactor: CGFloat = 1
    /// View-only rotation in degrees (multiples of 90) — never written to disk.
    @Published var rotation: Double = 0
    private let maxZoom: CGFloat = 8

    @Published var sortKey: SortKey = .name
    @Published var sortAscending = true

    // MARK: Search state

    /// The query. Every change re-runs the search over folder and file names
    /// in the current folder and all its subfolders.
    @Published var searchText: String = "" {
        didSet { if searchText != oldValue { applyFilter() } }
    }
    /// Whether the (always visible) search field has keyboard focus.
    @Published var searchFocused = false
    @Published private(set) var isSearching = false
    /// Delay before walking subfolders, so fast typing doesn't start a full
    /// tree walk per keystroke.
    var searchDebounce: Duration = .milliseconds(120)
    /// The full, unfiltered set of the current folder. `entries` is the
    /// currently visible (possibly search-filtered) view of it.
    private var allEntries: [GridEntry] = []
    private var searchTask: Task<Void, Never>?
    /// A result to select as soon as the search produces it (history restore).
    private var pendingResultSelection: URL?

    // MARK: History

    @Published private(set) var backStack: [Location] = []
    @Published private(set) var forwardStack: [Location] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { folderURL.flatMap(Self.parentFolder(of:)) != nil }

    /// The enclosing folder; nil at the file system root.
    nonisolated static func parentFolder(of url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        guard path != "/" else { return nil }
        return url.standardizedFileURL.deletingLastPathComponent()
    }

    // MARK: Rename

    /// The folder whose rename sheet is open.
    @Published var renameTarget: GridEntry?

    // MARK: Slideshow / video

    @Published private(set) var slideshowOn = false
    var slideshowInterval: Duration = .seconds(3)
    private var slideshowTask: Task<Void, Never>?

    /// The player of the video on screen — for keyboard control
    /// (play/pause/seek). Set by the video views.
    weak var activePlayer: PlaybackControl? {
        didSet { videoPaused = false }
    }
    /// Whether the user paused the current video (videos autoplay).
    @Published private(set) var videoPaused = false

    // MARK: Dependencies

    let defaults: UserDefaults
    var fileActions: FileActions

    static let lastFolderKey = "lastFolderPath"

    nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp",
        "webp", "psd", "pdf", "cr2", "cr3", "nef", "arw", "dng", "raf",
        "orf", "rw2", "raw", "icns", "svg"
    ]
    nonisolated static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "m2ts", "mts",
        "mpg", "mpeg", "3gp", "wmv", "flv", "ogv"
    ]

    init(defaults: UserDefaults = .standard, fileActions: FileActions = .live) {
        self.defaults = defaults
        self.fileActions = fileActions
    }

    /// `--ui-testing` keeps UI-test runs out of the user's real preferences;
    /// `--reset-state` starts such a run from empty preferences.
    static func makeDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard arguments.contains("--ui-testing") else { return .standard }
        let suite = "art.haushoppe.schnellbild.uitests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        if arguments.contains("--reset-state") { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Choosing / loading a folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder with media"
        if panel.runModal() == .OK, let url = panel.url {
            open(folder: url)
        }
    }

    /// Navigate to a folder. Records the current location in the history.
    func open(folder url: URL, selecting target: URL? = nil, thenDetail: Bool = false) {
        recordHistory()
        load(Location(folder: url, selected: target), thenDetail: thenDetail)
    }

    private func load(_ location: Location, thenDetail: Bool = false) {
        isLoading = true            // first: keeps the searchText reset below from searching
        searchTask?.cancel()
        isSearching = false
        pendingResultSelection = nil
        folderURL = location.folder
        entries = []
        allEntries = []
        selection = nil
        mode = .grid
        searchText = location.query
        resetTransforms()
        stopSlideshow()
        defaults.set(location.folder.path, forKey: Self.lastFolderKey)
        let url = location.folder
        let target = location.selected
        Task {
            var full = await Self.scan(url)
            guard self.folderURL == url else { return }   // a newer navigation won
            if let parent = Self.parentFolder(of: url) {
                full.insert(GridEntry(url: parent, kind: .parent), at: 0)
            }
            let sorted = Self.sortEntries(full, key: self.sortKey, ascending: self.sortAscending)
            self.allEntries = sorted
            self.isLoading = false
            if !self.searchText.isEmpty {
                // Restoring a search (history) or the user typed while loading.
                self.pendingResultSelection = target
                self.applyFilter()
                return
            }
            self.entries = sorted
            if let target, let idx = sorted.firstIndex(where: {
                $0.kind != .parent && Self.samePath($0.url, target)
            }) {
                self.selection = idx
                if thenDetail, sorted[idx].isMedia {
                    self.resetTransforms()
                    self.mode = .detail
                }
            } else {
                self.selection = Self.defaultSelection(in: sorted)
            }
        }
    }

    /// Reopen the last folder on launch (if it still exists).
    func restoreLastFolder() {
        guard folderURL == nil,
              let path = defaults.string(forKey: Self.lastFolderKey) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            open(folder: URL(fileURLWithPath: path))
        }
    }

    /// CLI / UI-test seam: `--open <path>` opens a folder (grid) or a file
    /// (straight into the full-size view) on launch — same rules as drag & drop.
    @discardableResult
    func openFromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return false }
        let url = URL(fileURLWithPath: args[i + 1])
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        openDropped([url])
        return true
    }

    /// Read a directory — including hidden entries, with date/size.
    /// Runs off the main thread; metadata is prefetched during
    /// enumeration (no extra round-trips).
    nonisolated static func scan(_ url: URL) async -> [GridEntry] {
        await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            )) ?? []
            return contents.compactMap { entry(for: $0, keys: keys) }
        }.value
    }

    /// Classify one file system item; nil for non-media files.
    nonisolated private static func entry(for item: URL, keys: Set<URLResourceKey>) -> GridEntry? {
        let vals = try? item.resourceValues(forKeys: keys)
        let date = vals?.contentModificationDate
        if vals?.isDirectory == true {
            return GridEntry(url: item, kind: .folder, modDate: date)
        }
        let ext = item.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return GridEntry(url: item, kind: .image, modDate: date, byteSize: vals?.fileSize)
        }
        if videoExtensions.contains(ext) {
            return GridEntry(url: item, kind: .video, modDate: date, byteSize: vals?.fileSize)
        }
        return nil
    }

    /// The media files a folder tile previews: the first `limit` by name,
    /// read from one shallow, non-recursive directory listing.
    nonisolated static func folderPreviewFiles(in folder: URL, limit: Int = 3) async -> [URL] {
        await Task.detached(priority: .utility) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents
                .filter {
                    let ext = $0.pathExtension.lowercased()
                    return imageExtensions.contains(ext) || videoExtensions.contains(ext)
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .prefix(limit)
                .map { $0 }
        }.value
    }

    /// Sorted: ".." on top, then folders, then media — each group by key.
    nonisolated static func sortEntries(_ entries: [GridEntry], key: SortKey, ascending: Bool) -> [GridEntry] {
        var parents: [GridEntry] = []
        var folders: [GridEntry] = []
        var media:   [GridEntry] = []
        for entry in entries {
            switch entry.kind {
            case .parent:        parents.append(entry)
            case .folder:        folders.append(entry)
            case .image, .video: media.append(entry)
            }
        }
        func asc(_ a: GridEntry, _ b: GridEntry) -> Bool {
            switch key {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: return (a.modDate ?? .distantPast) < (b.modDate ?? .distantPast)
            case .size: return (a.byteSize ?? 0) < (b.byteSize ?? 0)
            }
        }
        let cmp: (GridEntry, GridEntry) -> Bool = ascending ? { asc($0, $1) } : { asc($1, $0) }
        return parents + folders.sorted(by: cmp) + media.sorted(by: cmp)
    }

    func setSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
        let keepURL = selectedEntry?.url
        allEntries = Self.sortEntries(allEntries, key: sortKey, ascending: sortAscending)
        entries = Self.sortEntries(entries, key: sortKey, ascending: sortAscending)
        if let keepURL { selection = entries.firstIndex { $0.url == keepURL } }
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    /// A comparable path: symlinks resolved, and macOS's /private/var,
    /// /private/tmp and /private/etc folded onto /var, /tmp and /etc — also for
    /// paths that no longer exist (after a rename), which can't be resolved.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static func defaultSelection(in list: [GridEntry]) -> Int? {
        list.firstIndex { $0.kind != .parent } ?? (list.isEmpty ? nil : 0)
    }

    // MARK: - Search

    /// Recompute the visible `entries` from the query: name matches (folders
    /// and files) in the current folder appear at once, matches from all
    /// subfolders stream in while the tree walk runs.
    func applyFilter() {
        searchTask?.cancel()
        guard !isLoading else { return }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            isSearching = false
            pendingResultSelection = nil
            let keep = selectedEntry?.url
            entries = allEntries
            selection = keep.flatMap { url in allEntries.firstIndex { $0.url == url } }
                ?? Self.defaultSelection(in: allEntries)
            return
        }
        mode = .grid
        let local = allEntries.filter {
            $0.kind != .parent && $0.name.localizedCaseInsensitiveContains(query)
        }
        showResults(local, initial: true)

        guard let root = folderURL else { isSearching = false; return }
        isSearching = true
        let debounce = searchDebounce
        searchTask = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            var seen = Set(local.map { Self.canonicalPath($0.url) })
            var merged = local
            for await batch in Self.recursiveMatches(under: root, query: query) {
                guard let self, !Task.isCancelled else { return }
                let fresh = batch.filter { seen.insert(Self.canonicalPath($0.url)).inserted }
                guard !fresh.isEmpty else { continue }
                merged += fresh
                self.showResults(merged, initial: false)
            }
            guard let self, !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    /// Publish search results, keeping the selected item selected while
    /// results stream in.
    private func showResults(_ results: [GridEntry], initial: Bool) {
        let keep = initial ? nil : selectedEntry?.url
        entries = Self.sortEntries(results, key: sortKey, ascending: sortAscending)
        if let pending = pendingResultSelection,
           let idx = entries.firstIndex(where: { Self.samePath($0.url, pending) }) {
            selection = idx
            pendingResultSelection = nil
        } else if let keep, let idx = entries.firstIndex(where: { $0.url == keep }) {
            selection = idx
        } else {
            selection = entries.isEmpty ? nil : 0
        }
    }

    /// Deep name match (folders and files) under `root`, delivered in batches
    /// so results appear while a large or slow tree is still being walked.
    /// Skips hidden items and package contents; stops when the consumer
    /// cancels.
    nonisolated static func recursiveMatches(under root: URL, query: String) -> AsyncStream<[GridEntry]> {
        AsyncStream { continuation in
            let walker = Task.detached(priority: .userInitiated) {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continuation.finish(); return }

                var batch: [GridEntry] = []
                var lastFlush = ContinuousClock.now
                while let url = enumerator.nextObject() as? URL {
                    if Task.isCancelled { break }
                    if url.lastPathComponent.localizedCaseInsensitiveContains(query),
                       let match = entry(for: url, keys: keys) {
                        batch.append(match)
                    }
                    if !batch.isEmpty, batch.count >= 64 || ContinuousClock.now - lastFlush > .milliseconds(200) {
                        continuation.yield(batch)
                        batch.removeAll()
                        lastFlush = .now
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in walker.cancel() }
        }
    }

    /// Where a search result lives, relative to the searched folder
    /// ("vacation/2024"); nil for items directly in it.
    func relativeLocation(of entry: GridEntry) -> String? {
        guard let root = folderURL, entry.kind != .parent else { return nil }
        let rootPath = Self.canonicalPath(root)
        let dirPath = Self.canonicalPath(entry.url.deletingLastPathComponent())
        guard dirPath != rootPath, dirPath.hasPrefix(rootPath + "/") else { return nil }
        return String(dirPath.dropFirst(rootPath.count + 1))
    }

    /// Keys typed while the search field has focus. Escape clears the query
    /// (or leaves the field when it's empty); ↓ moves into the results;
    /// Return opens the selected result.
    @discardableResult
    func handleSearchFieldKey(_ key: KeyInput) -> Bool {
        switch key {
        case .escape:
            if searchText.isEmpty { searchFocused = false } else { searchText = "" }
            return true
        case .down:
            searchFocused = false
            mode = .grid
            if selection == nil, !entries.isEmpty { selection = 0 }
            return true
        case .enter:
            searchFocused = false
            if mode == .grid { activateSelection() }
            return true
        default:
            return false
        }
    }

    /// Drag & drop: open a folder; for a file → open the parent folder and select it.
    func openDropped(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            open(folder: first)
        } else {
            open(folder: first.deletingLastPathComponent(), selecting: first, thenDetail: true)
        }
    }

    // MARK: - History (back / forward)

    private var currentLocation: Location? {
        guard let folderURL else { return nil }
        return Location(folder: folderURL, query: searchText, selected: selectedEntry?.url)
    }

    private func recordHistory() {
        guard let current = currentLocation else { return }
        if backStack.last != current { backStack.append(current) }
        forwardStack.removeAll()
    }

    func navigateBack() {
        guard let target = backStack.popLast() else { return }
        if let current = currentLocation { forwardStack.append(current) }
        load(target)
    }

    func navigateForward() {
        guard let target = forwardStack.popLast() else { return }
        if let current = currentLocation { backStack.append(current) }
        load(target)
    }

    // MARK: - Selection / navigation

    var selectedEntry: GridEntry? {
        guard let i = selection, entries.indices.contains(i) else { return nil }
        return entries[i]
    }

    var selectedMediaEntry: GridEntry? {
        guard let entry = selectedEntry, entry.isMedia else { return nil }
        return entry
    }

    func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selection = index
    }

    func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let current = selection ?? 0
        selection = min(max(current + delta, 0), entries.count - 1)
    }

    func stepRow(_ direction: Int) {
        guard !entries.isEmpty else { return }
        let current = selection ?? 0
        let target = current + direction * columnCount
        guard target >= 0, target < entries.count else { return }
        selection = target
    }

    // MARK: - Counters / media

    /// Recomputed once whenever `entries` changes — avoids walking the array
    /// (three filters + a firstIndex) on every render of the status bar / badge.
    private(set) var folderCount = 0
    private(set) var imageCount = 0
    private(set) var videoCount = 0
    private var firstMediaIndex: Int?

    private func recomputeDerived() {
        var folders = 0, images = 0, videos = 0
        var first: Int?
        for (idx, entry) in entries.enumerated() {
            switch entry.kind {
            case .folder: folders += 1
            case .image:  images += 1; if first == nil { first = idx }
            case .video:  videos += 1; if first == nil { first = idx }
            case .parent: break
            }
        }
        folderCount = folders
        imageCount = images
        videoCount = videos
        firstMediaIndex = first
    }

    var mediaCount: Int {
        guard let first = firstMediaIndex else { return 0 }
        return entries.count - first
    }
    var currentMediaNumber: Int? {
        guard let first = firstMediaIndex, let sel = selection, sel >= first else { return nil }
        return sel - first + 1
    }

    /// In the full-size view: page through media only (skip folders).
    func stepMedia(_ delta: Int) {
        guard let first = firstMediaIndex else { return }
        let current = selection ?? first
        selection = min(max(current + delta, first), entries.count - 1)
        resetTransforms()
    }

    // MARK: - Zoom (full-size view)

    func zoomIn()        { zoom = min(zoom * 1.25, maxZoom) }
    func zoomOut()       { zoom = max(zoom / 1.25, 1) }
    func zoomReset()     { zoom = 1 }
    func zoomActualSize(){ zoom = min(max(actualSizeFactor, 1), maxZoom) }
    func applyPinch(_ factor: CGFloat) { zoom = min(max(zoom * factor, 1), maxZoom) }

    // MARK: - Rotation (view-only — the file on disk is never modified)

    func rotateLeft()  { rotation = (rotation - 90).truncatingRemainder(dividingBy: 360) }
    func rotateRight() { rotation = (rotation + 90).truncatingRemainder(dividingBy: 360) }

    /// Reset the view transforms (zoom + rotation) when switching media.
    private func resetTransforms() { zoom = 1; rotation = 0 }

    // MARK: - Grid tile size

    func growThumbnails()   { thumbnailSide = min(thumbnailSide + 30, 320) }
    func shrinkThumbnails() { thumbnailSide = max(thumbnailSide - 30, 80) }

    /// Mode-aware "+"/"−": zoom the image in the full-size view, resize tiles in the grid.
    func scaleUp()   { mode == .detail ? zoomIn()  : growThumbnails() }
    func scaleDown() { mode == .detail ? zoomOut() : shrinkThumbnails() }

    // MARK: - Activation / navigation

    func activateSelection() {
        guard let entry = selectedEntry else { return }
        switch entry.kind {
        case .parent:
            goToParentFolder()
        case .folder:
            open(folder: entry.url)
        case .image, .video:
            resetTransforms()
            mode = .detail
        }
    }

    func closeDetail() {
        stopSlideshow()
        resetTransforms()
        mode = .grid
    }

    /// Backspace: leave the full-size view, or go up one folder level in the grid.
    func leaveDetailOrGoUp() { mode == .detail ? closeDetail() : goToParentFolder() }

    func goToParentFolder() {
        guard let current = folderURL, let parent = Self.parentFolder(of: current) else { return }
        open(folder: parent, selecting: current)
    }

    // MARK: - Keyboard dispatch

    /// Single source of truth for key bindings. Returns true if the key was
    /// handled (and should be consumed). Pure enough to unit-test exhaustively.
    /// ⌘⌫ and ⌘↩ return false so they reach their menu items.
    @discardableResult
    func handleKey(_ key: KeyInput, command: Bool) -> Bool {
        switch key {
        case .f1:
            showHelp.toggle(); return true
        case .f2:
            return beginRename()
        case .backspace:
            guard !command else { return false }
            leaveDetailOrGoUp(); return true
        case .escape:
            if mode == .detail { closeDetail(); return true }
            if !searchText.isEmpty { searchText = ""; return true }
            return false
        case .enter:
            guard !command else { return false }
            mode == .detail ? closeDetail() : activateSelection()
            return true
        case .space:
            if mode == .detail {
                (selectedMediaEntry?.kind == .video) ? togglePlayPause() : stepMedia(+1)
            } else {
                activateSelection()
            }
            return true
        case .left:
            if command, mode == .detail, selectedMediaEntry?.kind == .video { seekVideo(by: -10) }
            else if mode == .detail { stepMedia(-1) }
            else { step(-1) }
            return true
        case .right:
            if command, mode == .detail, selectedMediaEntry?.kind == .video { seekVideo(by: +10) }
            else if mode == .detail { stepMedia(+1) }
            else { step(+1) }
            return true
        case .up:
            if command { goToParentFolder(); return true }
            mode == .detail ? stepMedia(-1) : stepRow(-1); return true
        case .down:
            mode == .detail ? stepMedia(+1) : stepRow(+1); return true
        case .home:
            guard mode == .grid else { return false }
            select(0); return true
        case .end:
            guard mode == .grid, !entries.isEmpty else { return false }
            select(entries.count - 1); return true
        case .char(let character):
            return handleCharacter(character, command: command)
        }
    }

    private func handleCharacter(_ character: Character, command: Bool) -> Bool {
        let c = Character(character.lowercased())
        switch c {
        case "+", "=": scaleUp();   return true
        case "-":      scaleDown(); return true
        case "f":
            if command { searchFocused = true } else { toggleFullScreen() }
            return true
        case "[" where command: navigateBack();    return true
        case "]" where command: navigateForward(); return true
        default:
            break
        }
        guard mode == .detail, !command else { return false }
        switch c {
        case "0": zoomReset();            return true
        case "1": zoomActualSize();       return true
        case "[": rotateLeft();           return true
        case "]": rotateRight();          return true
        case "i": showInspector.toggle(); return true
        case "s": toggleSlideshow();      return true
        default:  return false
        }
    }

    // MARK: - Slideshow

    func toggleSlideshow() {
        if slideshowOn { stopSlideshow() } else { startSlideshow() }
    }
    private func startSlideshow() {
        guard mode == .detail, firstMediaIndex != nil else { return }
        slideshowOn = true
        slideshowTask?.cancel()
        let interval = slideshowInterval
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.slideshowOn, self.mode == .detail else { return }
                self.advanceSlideshow()
            }
        }
    }
    private func stopSlideshow() {
        slideshowOn = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }
    private func advanceSlideshow() {
        guard let first = firstMediaIndex else { return }
        let current = selection ?? first
        selection = (current + 1 >= entries.count) ? first : current + 1
        resetTransforms()
    }

    // MARK: - File actions

    func revealInFinder() {
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        fileActions.reveal(entry.url)
    }

    func openInDefaultApp() {
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        fileActions.openInDefaultApp(entry.url)
    }

    func moveSelectionToTrash() {
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        guard fileActions.confirmTrash(entry.name) else { return }
        do {
            try fileActions.trash(entry.url)
        } catch {
            NSSound.beep()
            return
        }
        allEntries.removeAll { $0.url == entry.url }
        if let idx = entries.firstIndex(of: entry) {
            entries.remove(at: idx)
            if entries.isEmpty {
                selection = nil
            } else if let sel = selection {
                selection = min(sel, entries.count - 1)
            }
        }
        if mode == .detail, selectedMediaEntry == nil {
            mode = .grid
        }
    }

    // MARK: - Rename folder

    /// Open the rename sheet for the selected folder (grid only).
    @discardableResult
    func beginRename() -> Bool {
        guard mode == .grid, let entry = selectedEntry, entry.kind == .folder else { return false }
        renameTarget = entry
        return true
    }

    /// Rename a folder in place. Updates the grid, the selection and every
    /// history entry that points into the folder.
    @discardableResult
    func renameFolder(_ entry: GridEntry, to rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.emptyName }
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw RenameError.invalidName
        }
        let old = entry.url
        guard name != old.lastPathComponent else { renameTarget = nil; return old }
        let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        // A case-only change ("photos" → "Photos") points at the same item on
        // case-insensitive volumes and is allowed.
        let caseOnlyChange = name.lowercased() == old.lastPathComponent.lowercased()
        if FileManager.default.fileExists(atPath: new.path), !caseOnlyChange {
            throw RenameError.alreadyExists(name)
        }
        do {
            try fileActions.move(old, new)
        } catch {
            throw RenameError.failed(error.localizedDescription)
        }

        let renamed = GridEntry(url: new, kind: .folder, modDate: entry.modDate)
        let keep = selectedEntry?.url
        func withRenamed(_ list: [GridEntry]) -> [GridEntry] {
            Self.sortEntries(list.map { $0.url == old ? renamed : $0 }, key: sortKey, ascending: sortAscending)
        }
        allEntries = withRenamed(allEntries)
        entries = withRenamed(entries)
        if let keep {
            let target = keep == old ? new : keep
            selection = entries.firstIndex { $0.url == target }
        }
        backStack = backStack.map { Self.rebase($0, from: old, to: new) }
        forwardStack = forwardStack.map { Self.rebase($0, from: old, to: new) }
        renameTarget = nil
        return new
    }

    /// Point a history location at the renamed folder (or inside it).
    private static func rebase(_ location: Location, from old: URL, to new: URL) -> Location {
        func fix(_ url: URL) -> URL {
            let oldPath = canonicalPath(old)
            let path = canonicalPath(url)
            if path == oldPath { return new }
            guard path.hasPrefix(oldPath + "/") else { return url }
            return URL(fileURLWithPath: canonicalPath(new) + path.dropFirst(oldPath.count))
        }
        var result = location
        result.folder = fix(location.folder)
        result.selected = location.selected.map(fix)
        return result
    }

    // MARK: - Video control

    func togglePlayPause() {
        guard let p = activePlayer else { return }
        if videoPaused { p.play() } else { p.pause() }
        videoPaused.toggle()
    }

    func seekVideo(by seconds: Double) {
        activePlayer?.seek(by: seconds)
    }

    // MARK: - Window

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

/// AVKit playback, driven by the keyboard.
@MainActor
final class AVPlaybackControl: PlaybackControl {
    let player: AVPlayer

    init(player: AVPlayer) { self.player = player }

    func play()  { player.play() }
    func pause() { player.pause() }

    func seek(by seconds: Double) {
        guard let item = player.currentItem else { return }
        let now = CMTimeGetSeconds(player.currentTime())
        var target = max(0, now + seconds)
        let duration = CMTimeGetSeconds(item.duration)
        if duration.isFinite, duration > 0 { target = min(target, duration) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
