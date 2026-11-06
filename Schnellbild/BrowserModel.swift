import SwiftUI
import AppKit
import AVFoundation
import ImageIO

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
    /// The player's real state, so the keyboard stays in step with the
    /// player's own on-screen controls and with the end of the video.
    var isPlaying: Bool { get }
    /// Position in the video, 0 (start) … 1 (end); nil while the length
    /// isn't known yet.
    var progress: Double? { get }
    func play()
    func pause()
    /// Jump to a position (0 … 1). From the end, playing resumes.
    func seek(toProgress progress: Double)
}

/// Side effects on the file system and the workspace. Injectable, so tests
/// can observe them without touching Finder, the Trash, or modal alerts.
struct FileActions {
    var reveal: @MainActor (URL) -> Void
    var openInDefaultApp: @MainActor (URL) -> Void
    var confirmTrash: @MainActor (_ name: String) -> Bool
    var trash: @MainActor (URL) throws -> Void
    var move: @MainActor (_ from: URL, _ to: URL) throws -> Void
    /// Whether `target` exists as an item other than `source`. On a
    /// case-insensitive volume "Photos" is the same item as "photos"; on a
    /// case-sensitive one (many NAS shares) it may be a different folder.
    var conflicts: @MainActor (_ target: URL, _ source: URL) -> Bool

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
                do {
                    try fm.moveItem(at: temp, to: to)
                } catch {
                    try? fm.moveItem(at: temp, to: from)   // never leave the folder under the hidden name
                    throw error
                }
            } else {
                try fm.moveItem(at: from, to: to)
            }
        },
        conflicts: { target, source in
            guard FileManager.default.fileExists(atPath: target.path) else { return false }
            let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
            guard let a = try? target.resourceValues(forKeys: key).fileResourceIdentifier,
                  let b = try? source.resourceValues(forKeys: key).fileResourceIdentifier else { return true }
            return !a.isEqual(b)
        }
    )
}

/// Why a folder rename was rejected.
enum RenameError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case alreadyExists(String)
    case changesKind(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:            return "Please enter a name."
        case .invalidName:          return "Names can't contain “/” or “:”, and can't be “.” or “..”."
        case .alreadyExists(let n): return "An item named “\(n)” already exists here."
        case .changesKind(let ext): return "Keep the extension “.\(ext)”, so the file stays a picture or video Schnellbild shows."
        case .failed(let reason):   return reason
        }
    }
}

/// A change the app made on disk (rename, trash). One value is applied to
/// every list the model holds — the folder, the search results, results
/// still streaming in, the history — so they all agree.
struct FileChange {
    private enum Kind { case moved(to: String), removed }
    private let path: String
    private let kind: Kind

    static func moved(_ old: URL, to new: URL) -> FileChange {
        FileChange(path: BrowserModel.canonicalPath(old), kind: .moved(to: BrowserModel.canonicalPath(new)))
    }
    static func removed(_ url: URL) -> FileChange {
        FileChange(path: BrowserModel.canonicalPath(url), kind: .removed)
    }

    /// The changed item and every folder above it, as canonical paths: their
    /// contents (and so their previews and emptiness) changed.
    var affectedFolders: [String] {
        var result: [String] = []
        var paths = [path]
        if case .moved(let to) = kind { paths.append(to) }
        for start in paths {
            var current = start
            while !current.isEmpty, current != "/" {
                result.append(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }
        return result
    }

    /// `url` after the change; nil if it was removed (or lay inside what was).
    func apply(to url: URL) -> URL? {
        let current = BrowserModel.canonicalPath(url)
        guard BrowserModel.isSameOrInside(current, path) else { return url }
        switch kind {
        case .removed:         return nil
        case .moved(let to):   return URL(fileURLWithPath: to + current.dropFirst(path.count))
        }
    }

    func apply(to entry: GridEntry) -> GridEntry? {
        guard entry.kind != .parent else { return entry }
        guard let url = apply(to: entry.url) else { return nil }
        guard url != entry.url else { return entry }
        return GridEntry(url: url, kind: entry.kind, modDate: entry.modDate, byteSize: entry.byteSize)
    }

    /// A removed folder stays in the history (it then shows as empty).
    func apply(to location: BrowserModel.Location) -> BrowserModel.Location {
        var result = location
        result.folder = apply(to: location.folder) ?? location.folder
        result.selected = location.selected.flatMap { apply(to: $0) }
        result.results = location.results?.compactMap { apply(to: $0) }
        return result
    }
}

/// Single source of truth for all browsing.
@MainActor
final class BrowserModel: ObservableObject {
    enum Mode { case grid, detail }
    enum SortKey: String, CaseIterable {
        case name, kind, modified, captured, size

        var title: String {
            switch self {
            case .name:     return "Name"
            case .kind:     return "Kind"
            case .modified: return "Date Modified"
            case .captured: return "Date Taken"
            case .size:     return "Size"
            }
        }
        /// Like Finder: names A→Z, but dates and sizes newest/largest first.
        var startsAscending: Bool { self == .name || self == .kind }
    }
    enum KeyInput: Equatable {
        case left, right, up, down, space, enter, escape, backspace, home, end, f1, f2
        case char(Character)
    }

    /// A place in the navigation history: a folder, the search shown in it
    /// with its results, and the selected item. Going back to a search shows
    /// exactly these results again (with any renames applied) instead of
    /// searching anew, so the list stays stable.
    struct Location {
        var folder: URL
        var query: String = ""
        var selected: URL? = nil
        var results: [GridEntry]? = nil
    }

    @Published private(set) var folderURL: URL? {
        didSet { folderPath = folderURL.map(Self.canonicalPath) }
    }
    /// `canonicalPath(folderURL)`, kept so grid cells don't recompute it.
    private var folderPath: String?
    @Published private(set) var entries: [GridEntry] = [] {
        didSet { recomputeDerived(); readCaptureDatesIfNeeded() }
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

    @Published private(set) var sortKey: SortKey = .name
    @Published private(set) var sortAscending = true
    /// When each photo or video was taken (EXIF / QuickTime metadata), read
    /// only while sorting by `.captured`. Files without it sort by their
    /// modification date.
    private var captureDates: [URL: Date] = [:]
    /// Files whose capture date was already read (found or not).
    private var captureDatesRead: Set<URL> = []
    private var captureDateTask: Task<Void, Never>?

    // MARK: Search state

    /// The query. Every change re-runs the search over folder and file names
    /// in the current folder and all its subfolders.
    @Published var searchText: String = "" {
        didSet { if Self.trimmed(searchText) != Self.trimmed(oldValue) { applyFilter() } }
    }
    /// The query as searched: `searchText` without surrounding blanks.
    var query: String { Self.trimmed(searchText) }
    /// Whether a (non-blank) query filters the grid.
    var isFiltering: Bool { !query.isEmpty }
    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
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
    /// A result to select as soon as the search produces it.
    private var pendingResultSelection: URL?
    /// Everything the running search has found so far; streamed batches are
    /// appended here.
    private var searchResults: [GridEntry] = []
    /// Canonical paths in `searchResults`, so nothing shows up twice.
    private var searchSeen: Set<String> = []
    /// Changes made while the running search walks the tree, in order. The
    /// walk may still report paths it read before such a change; they are
    /// replayed on arrival. Reset by every new search.
    private var searchChanges: [FileChange] = []
    /// Identifies the newest `load`, so an older scan that finishes late is ignored.
    private var loadGeneration = 0

    // MARK: History

    @Published private(set) var backStack: [Location] = []
    @Published private(set) var forwardStack: [Location] = []
    /// Each step can hold a full result list; older steps are dropped.
    static let historyLimit = 50
    /// From the full view, Back first returns to the grid it was opened from.
    var canGoBack: Bool { mode == .detail || !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { folderURL.flatMap(Self.parentFolder(of:)) != nil }

    /// The enclosing folder; nil at the file system root.
    nonisolated static func parentFolder(of url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        guard path != "/" else { return nil }
        return url.standardizedFileURL.deletingLastPathComponent()
    }

    // MARK: Rename

    /// The folder or file whose rename sheet is open.
    @Published var renameTarget: GridEntry?

    // MARK: Slideshow / video

    @Published private(set) var slideshowOn = false
    var slideshowInterval: Duration = .seconds(3)
    private var slideshowTask: Task<Void, Never>?

    /// The player of the video on screen — for keyboard control
    /// (play/pause, skimming). Set by the video views.
    weak var activePlayer: PlaybackControl? {
        didSet { videoPaused = false }
    }
    /// Whether the current video is paused (or has ended). Videos autoplay;
    /// the players report changes via `playbackStateChanged`.
    @Published private(set) var videoPaused = false

    // MARK: Dependencies

    let defaults: UserDefaults
    var fileActions: FileActions

    static let lastFolderKey = "lastFolderPath"
    static let sortKeyKey = "sortKey"
    static let sortAscendingKey = "sortAscending"

    nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp",
        "webp", "psd", "pdf", "cr2", "cr3", "nef", "arw", "dng", "raf",
        "orf", "rw2", "raw", "icns", "svg"
    ]
    nonisolated static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "m2ts", "mts",
        "mpg", "mpeg", "3gp", "wmv", "flv", "ogv"
    ]

    /// The one rule for which files the app shows: image, video, or nil.
    nonisolated static func mediaKind(of url: URL) -> GridEntry.Kind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    init(defaults: UserDefaults = .standard, fileActions: FileActions = .live) {
        self.defaults = defaults
        self.fileActions = fileActions
        if let raw = defaults.string(forKey: Self.sortKeyKey), let key = SortKey(rawValue: raw) {
            sortKey = key
            sortAscending = defaults.object(forKey: Self.sortAscendingKey) as? Bool ?? key.startsAscending
        }
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
        loadGeneration += 1
        let generation = loadGeneration
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
            guard self.loadGeneration == generation else { return }   // a newer navigation won
            if let parent = Self.parentFolder(of: url) {
                full.insert(GridEntry(url: parent, kind: .parent), at: 0)
            }
            self.allEntries = self.sorted(full)
            self.isLoading = false
            if self.isFiltering {
                if let results = location.results, self.searchText == location.query {
                    // History: show the remembered results as they were.
                    self.entries = self.sorted(results)
                    self.selection = self.index(of: target) ?? (self.entries.isEmpty ? nil : 0)
                } else {
                    // The user typed while the folder loaded.
                    self.pendingResultSelection = target
                    self.applyFilter()
                }
                return
            }
            self.entries = self.allEntries
            if let idx = self.index(of: target) {
                self.selection = idx
                if thenDetail, self.entries[idx].isMedia {
                    self.resetTransforms()
                    self.mode = .detail
                }
            } else {
                self.selection = Self.defaultSelection(in: self.entries)
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
        guard let kind = mediaKind(of: item) else { return nil }
        return GridEntry(url: item, kind: kind, modDate: date, byteSize: vals?.fileSize)
    }

    /// Whether a photo or video lies anywhere below `folder`. Stops at the
    /// first one, so only folders that are really empty are walked to the
    /// end. Hidden files (".DS_Store", "._…") and anything that isn't a
    /// picture or video ("Thumbs.db", "desktop.ini") don't count.
    nonisolated static func containsMedia(_ folder: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
            for case let url as URL in walk where mediaKind(of: url) != nil { return true }
            return false
        }.value
    }

    /// Folders known to hold no photos or videos at any depth, as canonical
    /// paths. Filled by the folder tiles as they find out; the grid greys
    /// them out.
    @Published private(set) var emptyFolders: Set<String> = []

    func isEmptyFolder(_ entry: GridEntry) -> Bool {
        entry.kind == .folder && emptyFolders.contains(Self.canonicalPath(entry.url))
    }

    func noteFolder(_ url: URL, empty: Bool) {
        let path = Self.canonicalPath(url)
        if empty { emptyFolders.insert(path) } else { emptyFolders.remove(path) }
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
            // One pass keeping the `limit` first names, instead of sorting a
            // possibly huge listing to take three.
            func before(_ a: URL, _ b: URL) -> Bool {
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            var first: [URL] = []
            for url in contents where mediaKind(of: url) != nil {
                guard first.count < limit || before(url, first[first.count - 1]) else { continue }
                first.insert(url, at: first.firstIndex { before(url, $0) } ?? first.count)
                if first.count > limit { first.removeLast() }
            }
            return first
        }.value
    }

    /// Sorted: ".." on top, then folders, then media — each group by key.
    /// Ties (same kind, date or size) fall back to the name, so the order is
    /// stable. `captured` holds the capture dates read so far.
    nonisolated static func sortEntries(_ entries: [GridEntry], key: SortKey, ascending: Bool,
                                        captured: [URL: Date] = [:]) -> [GridEntry] {
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
        func byName(_ a: GridEntry, _ b: GridEntry) -> ComparisonResult {
            a.name.localizedStandardCompare(b.name)
        }
        func compare(_ a: GridEntry, _ b: GridEntry) -> ComparisonResult {
            func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
                x < y ? .orderedAscending : (y < x ? .orderedDescending : .orderedSame)
            }
            switch key {
            case .name:
                return .orderedSame
            case .kind:
                return a.url.pathExtension.lowercased().localizedStandardCompare(b.url.pathExtension.lowercased())
            case .modified:
                return order(a.modDate ?? .distantPast, b.modDate ?? .distantPast)
            case .captured:
                return order(captured[a.url] ?? a.modDate ?? .distantPast,
                             captured[b.url] ?? b.modDate ?? .distantPast)
            case .size:
                return order(a.byteSize ?? 0, b.byteSize ?? 0)
            }
        }
        func before(_ a: GridEntry, _ b: GridEntry) -> Bool {
            var result = compare(a, b)
            if result == .orderedSame { result = byName(a, b) }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return parents + folders.sorted(by: before) + media.sorted(by: before)
    }

    /// Choose the sort order. The same key again reverses the direction; a
    /// new key starts in its natural direction. Remembered across launches.
    func setSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = key.startsAscending }
        defaults.set(key.rawValue, forKey: Self.sortKeyKey)
        defaults.set(sortAscending, forKey: Self.sortAscendingKey)
        resort()
        readCaptureDatesIfNeeded()
    }

    /// Sort the lists again, keeping the selection.
    private func resort() {
        let keep = selectedEntry?.url
        allEntries = sorted(allEntries)
        entries = sorted(entries)
        selection = index(of: keep) ?? selection
    }

    /// While sorting by capture date, read the dates of the media on screen
    /// that aren't known yet (off the main thread, a few files at a time)
    /// and sort again once they're in.
    func readCaptureDatesIfNeeded() {
        guard sortKey == .captured else { return }
        let missing = Set((allEntries + entries).filter { $0.isMedia }.map(\.url)).subtracting(captureDatesRead)
        guard !missing.isEmpty else { return }
        captureDatesRead.formUnion(missing)
        let previous = captureDateTask
        captureDateTask = Task { [weak self] in
            await previous?.value
            let found = await Self.captureDates(of: Array(missing))
            guard let self, !Task.isCancelled else { return }
            self.captureDates.merge(found) { _, new in new }
            if self.sortKey == .captured { self.resort() }
        }
    }

    /// Capture dates of the given files, read in parallel (8 at a time).
    nonisolated static func captureDates(of urls: [URL]) async -> [URL: Date] {
        await withTaskGroup(of: (URL, Date?).self) { group in
            var result: [URL: Date] = [:]
            var pending = urls[...]
            func addNext() {
                guard let url = pending.popFirst() else { return }
                group.addTask { (url, await captureDate(of: url)) }
            }
            for _ in 0..<8 { addNext() }
            for await (url, date) in group {
                if let date { result[url] = date }
                addNext()
            }
            return result
        }
    }

    /// When a photo or video was taken: EXIF DateTimeOriginal for images
    /// (only the header is read), the QuickTime creation date for videos.
    nonisolated static func captureDate(of url: URL) async -> Date? {
        switch mediaKind(of: url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(
                      source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
            else { return nil }
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal]
                              ?? exif?[kCGImagePropertyExifDateTimeDigitized]
                              ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else { return nil }
            return exifDateFormatter.date(from: text)
        case .video:
            let asset = AVURLAsset(url: url)
            guard let item = try? await asset.load(.creationDate) else { return nil }
            return try? await item.load(.dateValue)
        default:
            return nil
        }
    }

    /// EXIF dates: "2024:07:14 18:32:05", in the camera's local time.
    nonisolated private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private func sorted(_ list: [GridEntry]) -> [GridEntry] {
        Self.sortEntries(list, key: sortKey, ascending: sortAscending, captured: captureDates)
    }

    /// Where `url` is in the visible list.
    private func index(of url: URL?) -> Int? {
        guard let url else { return nil }
        let path = Self.canonicalPath(url)
        return entries.firstIndex { Self.canonicalPath($0.url) == path }
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    /// A comparable path: standardized, with macOS's /private/var,
    /// /private/tmp and /private/etc folded onto /var, /tmp and /etc. Pure
    /// string work without file system access, because it runs per entry on
    /// the main thread and must stay fast on network volumes. Entries are
    /// listed under the folder's own path, so they compare consistently.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// `path` is `ancestor` or lies inside it ("/a/photos" is not inside "/a/photo").
    nonisolated static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
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
        let query = self.query
        searchChanges = []
        guard !query.isEmpty else {
            isSearching = false
            pendingResultSelection = nil
            searchResults = []
            searchSeen = []
            let keep = selectedEntry?.url
            entries = allEntries
            selection = index(of: keep) ?? Self.defaultSelection(in: allEntries)
            return
        }
        mode = .grid
        let local = allEntries.filter {
            $0.kind != .parent && $0.name.localizedCaseInsensitiveContains(query)
        }
        searchResults = local
        searchSeen = Set(local.map { Self.canonicalPath($0.url) })
        showResults(initial: true)

        guard let root = folderURL else { isSearching = false; return }
        isSearching = true
        let debounce = searchDebounce
        searchTask = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            for await batch in Self.recursiveMatches(under: root, query: query) {
                guard let self, !Task.isCancelled else { return }
                self.appendSearchBatch(batch)
            }
            guard let self, !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    /// Add a streamed batch to the running search's results. Internal so
    /// tests can deliver a batch the walk read before a rename or trash.
    func appendSearchBatch(_ batch: [GridEntry]) {
        var fresh: [GridEntry] = []
        for found in batch {
            guard let entry = searchChanges.reduce(Optional(found), { entry, change in
                entry.flatMap { change.apply(to: $0) }
            }) else { continue }
            if searchSeen.insert(Self.canonicalPath(entry.url)).inserted { fresh.append(entry) }
        }
        guard !fresh.isEmpty else { return }
        searchResults += fresh
        showResults(initial: false)
    }

    /// Publish search results, keeping the selected item selected while
    /// results stream in.
    private func showResults(initial: Bool) {
        let keep = initial ? nil : selectedEntry?.url
        entries = sorted(searchResults)
        if let idx = index(of: pendingResultSelection) {
            selection = idx
            pendingResultSelection = nil
        } else {
            selection = index(of: keep) ?? (entries.isEmpty ? nil : 0)
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
        guard let rootPath = folderPath, entry.kind != .parent else { return nil }
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

    /// The place on screen. Results are remembered only once the search has
    /// finished; an unfinished one runs again when the user comes back.
    private var currentLocation: Location? {
        guard let folderURL else { return nil }
        let complete = isFiltering && !isLoading && !isSearching
        return Location(folder: folderURL, query: searchText, selected: selectedEntry?.url,
                        results: complete ? entries : nil)
    }

    private func recordHistory() {
        guard let current = currentLocation else { return }
        if let last = backStack.last, Self.sameSpot(last, current) {
            backStack[backStack.count - 1] = current
        } else {
            push(current, onto: &backStack)
        }
        forwardStack.removeAll()
    }

    /// Same folder, query and selection; the result lists aren't compared.
    private static func sameSpot(_ a: Location, _ b: Location) -> Bool {
        samePath(a.folder, b.folder) && a.query == b.query
            && a.selected.map(canonicalPath) == b.selected.map(canonicalPath)
    }

    private func push(_ location: Location, onto stack: inout [Location]) {
        stack.append(location)
        if stack.count > Self.historyLimit { stack.removeFirst(stack.count - Self.historyLimit) }
    }

    /// Back. The full view isn't a history step of its own (it opens in
    /// place, over the folder or the search results), so from there Back
    /// returns to that grid, with the search and its results as they were.
    func navigateBack() {
        if mode == .detail { closeDetail(); return }
        travel(from: &backStack, to: &forwardStack)
    }
    func navigateForward() { travel(from: &forwardStack, to: &backStack) }

    private func travel(from source: inout [Location], to other: inout [Location]) {
        guard let target = source.popLast() else { return }
        if let current = currentLocation { push(current, onto: &other) }
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
            // The full view takes the keys, also when it was opened with the
            // mouse while the search field had focus.
            searchFocused = false
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
    /// ⌘⌫ and ⌘↩ return false so they reach their menu items. While a text
    /// field is being edited (`textEditing`) or a sheet is open, keys belong
    /// to them — except F1 and F2.
    @discardableResult
    func handleKey(_ key: KeyInput, command: Bool, textEditing: Bool = false) -> Bool {
        let sheetOpen = showHelp || renameTarget != nil
        switch key {
        case .f1:
            // Not over the rename sheet: a second sheet can't open on top of it.
            guard renameTarget == nil else { return false }
            showHelp.toggle(); return true
        case .f2:
            // Also while typing in the search field.
            guard !sheetOpen else { return false }
            return beginRename()
        default:
            guard !textEditing, !sheetOpen else { return false }
        }
        switch key {
        case .f1, .f2:
            return false   // handled above
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
        case .left, .right:
            // ⌘←/⌘→ always page; plain ←/→ skim through a video first.
            let direction = key == .right ? 1 : -1
            if mode == .grid { step(direction) }
            else if command { stepMedia(direction) }
            else { skim(direction) }
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
            // The search field is disabled without a folder; a focus request
            // then would stay pending and grab focus later.
            if command { focusSearch() } else { toggleFullScreen() }
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

    /// Focus the search field — only when it is enabled (a folder is open);
    /// a request on the disabled field would grab focus later.
    func focusSearch() { searchFocused = folderURL != nil }

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
        apply(.removed(entry.url))
        if mode == .detail, selectedMediaEntry == nil {
            mode = .grid
        }
    }

    // MARK: - Rename

    /// Open the rename sheet for the selected folder or file, in the grid or
    /// the full view.
    @discardableResult
    func beginRename() -> Bool {
        guard let entry = selectedEntry, entry.kind != .parent else { return false }
        searchFocused = false   // F2 works while typing in the search field
        renameTarget = entry
        return true
    }

    /// Rename a folder or file in place. Updates the grid, the selection and
    /// every history entry that points to it (or, for a folder, into it).
    @discardableResult
    func rename(_ entry: GridEntry, to rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.emptyName }
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw RenameError.invalidName
        }
        let old = entry.url
        guard name != old.lastPathComponent else { renameTarget = nil; return old }
        let isFolder = entry.kind == .folder
        let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isFolder)
        if !isFolder, Self.mediaKind(of: new) != entry.kind {
            throw RenameError.changesKind(old.pathExtension)
        }
        if fileActions.conflicts(new, old) { throw RenameError.alreadyExists(name) }
        do {
            try fileActions.move(old, new)
        } catch {
            throw RenameError.failed(error.localizedDescription)
        }

        // Stay where we are: same folder, same query, same results (and the
        // full view stays open) — only the renamed item and, for a folder,
        // everything listed inside it get the new path.
        apply(.moved(old, to: new))
        renameTarget = nil
        return new
    }

    /// Bring every list the model holds in line with a change on disk, and
    /// keep the selection on the same item (or near it, if it's gone).
    private func apply(_ change: FileChange) {
        // What the folders around the change contain is no longer known.
        for path in change.affectedFolders { emptyFolders.remove(path) }
        FolderPreviewCache.shared.forget(change.affectedFolders)
        let keep = selectedEntry.flatMap { change.apply(to: $0.url) }
        let previous = selection
        allEntries = sorted(allEntries.compactMap { change.apply(to: $0) })
        searchResults = searchResults.compactMap { change.apply(to: $0) }
        searchSeen = Set(searchResults.map { Self.canonicalPath($0.url) })
        if isSearching { searchChanges.append(change) }
        pendingResultSelection = pendingResultSelection.flatMap { change.apply(to: $0) }
        backStack = backStack.map { change.apply(to: $0) }
        forwardStack = forwardStack.map { change.apply(to: $0) }
        entries = sorted(entries.compactMap { change.apply(to: $0) })
        selection = index(of: keep)
            ?? (entries.isEmpty ? nil : previous.map { min($0, entries.count - 1) })
    }

    // MARK: - Video control

    /// Decides from the player's real state, not from the last key press.
    func togglePlayPause() {
        guard let p = activePlayer else { return }
        let playing = p.isPlaying
        if playing { p.pause() } else { p.play() }
        videoPaused = playing
    }

    /// Called by the players when playback starts, pauses or ends — also
    /// through their own on-screen controls.
    func playbackStateChanged(_ player: PlaybackControl, isPlaying: Bool) {
        guard player === activePlayer else { return }
        videoPaused = !isPlaying
    }

    /// One ←/→ step in a video: a tenth of its length.
    static let videoJump = 0.1

    /// ←/→ in the full view. Images: previous/next item. Videos: jump a tenth
    /// of the length; past the end → next item, at the start → previous one.
    /// So one key pages through images and skims through videos.
    func skim(_ direction: Int) {
        guard selectedMediaEntry?.kind == .video, let player = activePlayer,
              let progress = player.progress else {
            stepMedia(direction); return
        }
        if direction > 0 {
            let target = progress + Self.videoJump
            if target >= 0.999 { stepMedia(+1) } else { player.seek(toProgress: target) }
        } else {
            // Close to the start counts as the start, so a playing video
            // doesn't keep catching the key.
            if progress < Self.videoJump / 4 { stepMedia(-1) }
            else { player.seek(toProgress: max(progress - Self.videoJump, 0)) }
        }
    }

    // MARK: - Window

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

/// AVKit playback, driven by the keyboard. Reports state changes from any
/// source (keys, the player's controls, the end of the video) to the model.
@MainActor
final class AVPlaybackControl: PlaybackControl {
    let player: AVPlayer
    private var observation: NSKeyValueObservation?

    init(player: AVPlayer, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void = { _, _ in }) {
        self.player = player
        observation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self else { return }
                onStateChange(self, playing)
            }
        }
    }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    /// At the end, playing starts over.
    func play() {
        if let item = player.currentItem {
            let duration = CMTimeGetSeconds(item.duration)
            if duration.isFinite, duration > 0, CMTimeGetSeconds(player.currentTime()) >= duration - 0.05 {
                player.seek(to: .zero)
            }
        }
        player.play()
    }

    func pause() { player.pause() }

    private var duration: Double? {
        guard let item = player.currentItem else { return nil }
        let seconds = CMTimeGetSeconds(item.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    var progress: Double? {
        guard let duration else { return nil }
        return min(max(CMTimeGetSeconds(player.currentTime()) / duration, 0), 1)
    }

    func seek(toProgress progress: Double) {
        guard let duration else { return }
        let ended = !isPlaying && (self.progress ?? 0) >= 0.999
        player.seek(to: CMTime(seconds: duration * min(max(progress, 0), 1), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if ended { player.play() }
    }
}
