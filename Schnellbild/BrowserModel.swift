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

/// A file in a folder that the grid doesn't show (not a picture, video or
/// archive): listed by name under the grid, so a folder with only such
/// files doesn't look empty.
struct OtherFile: Identifiable, Hashable {
    let url: URL
    var byteSize: Int? = nil
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// A folder's contents: what the grid shows, and the other files.
struct FolderListing {
    var entries: [GridEntry] = []
    var others: [OtherFile] = []
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
    /// The look as a filter on the picture (see `Look`); with `.auto` the
    /// player measures the video and reports its look through
    /// `BrowserModel.autoLookMeasured`.
    func setEnhancement(_ enhancement: Enhancement)
    /// Plays although its length isn't known (a WebM recorded in a
    /// browser): the slideshow waits for its end instead of skipping it.
    var playsWithoutLength: Bool { get }
    /// The picture's size in pixels as shown, once known (the Inspector).
    var videoSize: CGSize? { get }
    /// The length in seconds, once known.
    var duration: Double? { get }
    /// Sound, 0 … 1 (the app's one volume for all videos).
    func setVolume(_ volume: Double)
}

extension PlaybackControl {
    var playsWithoutLength: Bool { false }
    var videoSize: CGSize? { nil }
    var duration: Double? { nil }
    func setVolume(_ volume: Double) {}
}

/// Side effects on the file system and the workspace. Injectable, so tests
/// can observe them without touching Finder, the Trash, or modal alerts.
struct FileActions {
    var reveal: @MainActor (URL) -> Void
    var openInDefaultApp: @MainActor (URL) -> Void
    /// `detail` says what goes with it (a folder's contents, an archive's parts).
    var confirmTrash: @MainActor (_ name: String, _ detail: String) -> Bool
    var trash: @MainActor (URL) throws -> Void
    var move: @MainActor (_ from: URL, _ to: URL) throws -> Void
    /// Into another folder: moved on the same volume, copied to another
    /// (as the Finder does). Returns whether it was moved.
    var transfer: @MainActor (_ from: URL, _ to: URL) throws -> Bool
    var createFolder: @MainActor (URL) throws -> Void
    var copy: @MainActor (_ from: URL, _ to: URL) throws -> Void
    /// A name already taken in the target folder: true to keep both (the
    /// new one gets a number), false to skip it.
    var askKeepBoth: @MainActor (_ name: String, _ folder: String) -> Bool
    /// Whether `target` exists as an item other than `source`. On a
    /// case-insensitive volume "Photos" is the same item as "photos"; on a
    /// case-sensitive one (many NAS shares) it may be a different folder.
    var conflicts: @MainActor (_ target: URL, _ source: URL) -> Bool
    /// Tells why an action failed (a share without a Trash, no permission),
    /// in the system's words and language.
    var report: @MainActor (Error) -> Void

    static let live = FileActions(
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        openInDefaultApp: { NSWorkspace.shared.open($0) },
        confirmTrash: { name, detail in
            let alert = NSAlert()
            alert.messageText = String(localized: "Move “\(name)” to the Trash?")
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Move to Trash"))
            alert.addButton(withTitle: String(localized: "Cancel"))
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
        transfer: { from, to in
            let key: Set<URLResourceKey> = [.volumeIdentifierKey]
            let a = try? from.resourceValues(forKeys: key).volumeIdentifier
            let b = try? to.deletingLastPathComponent().resourceValues(forKeys: key).volumeIdentifier
            if let a, let b, a.isEqual(b) {
                try FileManager.default.moveItem(at: from, to: to)
                return true
            }
            try FileManager.default.copyItem(at: from, to: to)
            return false
        },
        createFolder: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        askKeepBoth: { name, folder in
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(name)” already exists in “\(folder)”.")
            alert.informativeText = String(localized: "Keep both: the new one gets a number. Skip: it stays where it is.")
            alert.addButton(withTitle: String(localized: "Keep Both"))
            alert.addButton(withTitle: String(localized: "Skip"))
            return alert.runModal() == .alertFirstButtonReturn
        },
        conflicts: { target, source in
            guard FileManager.default.fileExists(atPath: target.path) else { return false }
            let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
            guard let a = try? target.resourceValues(forKeys: key).fileResourceIdentifier,
                  let b = try? source.resourceValues(forKeys: key).fileResourceIdentifier else { return true }
            return !a.isEqual(b)
        },
        report: { NSAlert(error: $0).runModal() }
    )
}

/// Why a folder rename was rejected.
enum RenameError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case alreadyExists(String)
    /// The new name's extension isn't one of the item's kind (picture / video).
    case changesKind(String, video: Bool)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:            return String(localized: "Please enter a name.")
        case .invalidName:          return String(localized: "Names can't contain “/” or “:”, and can't be “.” or “..”.")
        case .alreadyExists(let n): return String(localized: "A folder or file named “\(n)” already exists in this folder.")
        case .changesKind(let ext, false): return String(localized: "The name must end in a picture extension, such as “.\(ext)”.")
        case .changesKind(let ext, true): return String(localized: "The name must end in a video extension, such as “.\(ext)”.")
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
        return result
    }
}

/// One search: what it has found so far and the tree walk adding to it.
/// The history keeps it, so going back shows the same results, and a walk
/// still running goes on in the background.
@MainActor
final class SearchRun {
    let query: String
    private(set) var results: [GridEntry]
    /// Canonical paths in `results`, so nothing shows up twice.
    private var seen: Set<String>
    /// Changes made while the walk runs, in order. The walk may still report
    /// paths it read before such a change; they are replayed on arrival.
    private var changes: [FileChange] = []
    var task: Task<Void, Never>?
    /// The walk is done (or was stopped).
    var finished = false
    /// Stopped to save work (too many running in the history) before the
    /// walk was through: coming back searches again. A search the user
    /// stopped keeps what it found.
    private(set) var stoppedEarly = false

    init(query: String, results: [GridEntry]) {
        self.query = query
        self.results = results
        seen = Set(results.map { BrowserModel.canonicalPath($0.url) })
    }

    /// Adds a batch from the walk; whether anything was new.
    func add(_ batch: [GridEntry]) -> Bool {
        var fresh: [GridEntry] = []
        for found in batch {
            guard let entry = changes.reduce(Optional(found), { entry, change in
                entry.flatMap { change.apply(to: $0) }
            }) else { continue }
            if seen.insert(BrowserModel.canonicalPath(entry.url)).inserted { fresh.append(entry) }
        }
        results += fresh
        return !fresh.isEmpty
    }

    func apply(_ change: FileChange) {
        results = results.compactMap { change.apply(to: $0) }
        seen = Set(results.map { BrowserModel.canonicalPath($0.url) })
        if !finished { changes.append(change) }
    }

    func stop(incomplete: Bool) {
        task?.cancel()
        if !finished && incomplete { stoppedEarly = true }
        finished = true
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
            case .name:     return String(localized: "Name")
            case .kind:     return String(localized: "Kind")
            case .modified: return String(localized: "Date Modified")
            case .captured: return String(localized: "Date Taken")
            case .size:     return String(localized: "Size")
            }
        }
        /// Like Finder: names A→Z, but dates and sizes newest/largest first.
        var startsAscending: Bool { self == .name || self == .kind }
    }
    enum KeyInput: Equatable {
        case left, right, up, down, space, enter, escape, backspace, home, end, f1, f2
        /// The Norton Commander keys, a second way next to the Mac ones:
        /// F3 view, F4 edit (the default app), F5 copy and F6 move to the
        /// other pane (the window's), F6 alone / ⇧F6 rename, F7 new folder,
        /// F8 trash, F9 the menus, F10 quit; Insert marks, Tab switches panes.
        /// (Norton's F2, its user menu, stays rename here: the Mac-style key
        /// comes first.)
        case insert, tab, f3, f4, f5, f6, f7, f8, f9, f10
        case char(Character)
    }

    /// A place in the navigation history: a folder, the search shown in it,
    /// and the selected item. Going back to a search shows its results
    /// again (with any renames applied) instead of searching anew, so the
    /// list stays stable; a search that was still running when the user
    /// left keeps running and shows what it has found by then.
    struct Location {
        var folder: URL
        var query: String = ""
        var selected: URL? = nil
        var search: SearchRun? = nil
    }

    @Published private(set) var folderURL: URL? {
        didSet { folderPath = folderURL.map(Self.canonicalPath) }
    }
    /// `canonicalPath(folderURL)`, kept so grid cells don't recompute it.
    private var folderPath: String?
    @Published private(set) var entries: [GridEntry] = [] {
        didSet { recomputeDerived(); readCaptureDatesIfNeeded() }
    }
    @Published var selection: Int? {
        didSet { selectionChosen = !settingDefaultSelection }
    }
    /// The selection is the user's (or restored from the history), not the
    /// first tile picked on opening a folder: a slideshow starts there.
    private(set) var selectionChosen = false
    private var settingDefaultSelection = false

    private func selectDefault(in list: [GridEntry]) {
        settingDefaultSelection = true
        selection = Self.defaultSelection(in: list)
        settingDefaultSelection = false
    }
    @Published var mode: Mode = .grid {
        didSet { if mode == .grid { refreshIfDeferred() } }
    }
    @Published var showInspector = false
    @Published var showHelp = false
    @Published private(set) var isLoading = false
    /// Counts the changes the app made on disk; folder tiles read their
    /// previews again on each.
    @Published private(set) var folderChanges = 0
    /// Why the current folder or archive couldn't be listed (shown instead
    /// of "This folder is empty").
    struct LoadError: Equatable {
        let archive: Bool
        let reason: String
    }
    @Published private(set) var loadError: LoadError?
    /// The current folder's files the grid doesn't show (not while searching).
    @Published private(set) var otherFiles: [OtherFile] = []
    /// The place `load` is reading, for the history while it loads.
    private var loadingLocation: Location?

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
    @Published var searchFocused = false {
        didSet { if searchFocused { onActivate?() } }
    }
    /// Told when the user turns to this pane (a click, a menu on one of its
    /// tiles, its search field): the window makes it the active one.
    var onActivate: (() -> Void)?
    @Published private(set) var isSearching = false
    /// Delay before walking subfolders, so fast typing doesn't start a full
    /// tree walk per keystroke.
    var searchDebounce: Duration = .milliseconds(120)
    /// The full, unfiltered set of the current folder. `entries` is the
    /// currently visible (possibly search-filtered) view of it.
    private var allEntries: [GridEntry] = []
    /// The search shown; the history can hold more (`Location.search`).
    private var search: SearchRun?
    /// Unfinished searches kept running in the history; older ones stop.
    static let backgroundSearchLimit = 3
    /// A result to select as soon as the search produces it.
    private var pendingResultSelection: URL?
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

    // MARK: Archive passwords

    /// A protected archive none of the remembered passwords opens: the
    /// password sheet asks for one.
    struct PasswordRequest: Identifiable {
        let id = UUID()
        let archive: String
        let location: Location
        let thenDetail: Bool
        /// The password typed last time didn't open it.
        let wrong: Bool
    }
    @Published var passwordRequest: PasswordRequest?

    /// The password sheet's "Open": tried on the archive, and remembered
    /// (for every archive) once it opens it.
    func submitPassword(_ password: String) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        guard !password.isEmpty else { passwordRequest = request; return }
        load(request.location, thenDetail: request.thenDetail, password: password)
    }

    /// The password sheet's "Cancel": back to where the user came from.
    func cancelPassword() {
        passwordRequest = nil
        if canGoBack { navigateBack() } else { goToParentFolder() }
    }

    // MARK: Slideshow / video

    /// A slideshow over every photo and video below a folder, folder by
    /// folder in the sort order (a folder's own media first, then each
    /// subfolder). It starts with the first pictures found while the walk
    /// goes on, and plays in full screen over the grid.
    struct Slideshow {
        var items: [GridEntry] = []
        var index = 0
        /// Still walking subfolders: more items may come.
        var loading = true
        /// Pictures wait (videos pause through their player).
        var paused = false
        /// Stepped past the last item while the walk still runs: the next
        /// batch moves the show on.
        var waitingForMore = false
        /// The item to start at (the one in the full view, or the file
        /// selected in the grid), until it has arrived or the user has moved on.
        var startAt: URL?
        /// The folder to start in (selected in the grid): the first item
        /// from inside it. Canonical path with a trailing "/".
        var startInside: String?
        /// Nothing shown yet: waiting for the item to start at.
        var waitingForStart: Bool { startAt != nil || startInside != nil }
        /// Every item once (search results can hold a folder and files in it).
        var seen: Set<String> = []
        /// Tells this slideshow's walk from an earlier, cancelled one.
        let id = UUID()
        var current: GridEntry? { items.indices.contains(index) ? items[index] : nil }
    }
    @Published private(set) var slideshow: Slideshow? {
        didSet { if slideshow == nil { refreshIfDeferred() } }
    }
    /// How long a picture stays; a video plays to its end.
    var slideshowInterval: Duration = .seconds(3)
    /// How often the slideshow checks that a video plays at all; four checks
    /// without a length skip it (a file nothing can play).
    var slideshowVideoCheck: Duration = .seconds(2)
    private var slideshowTimer: Task<Void, Never>?
    private var slideshowWalk: Task<Void, Never>?
    /// Whether starting the slideshow put the window into full screen.
    private var slideshowEnteredFullScreen = false
    /// Puts the window into (true) or out of (false) full screen; returns
    /// whether that changed anything. Tests replace it.
    var setFullScreen: @MainActor (Bool) -> Bool = { on in
        FullScreenSwitch.shared.set(on, window: BrowserModel.appWindow)
    }

    /// The browser window: the main one (the key window can be the
    /// Adjustments popover's).
    static var appWindow: NSWindow? { NSApp.mainWindow ?? NSApp.keyWindow }

    /// The player of the video on screen — for keyboard control
    /// (play/pause, skimming). Set by the video views.
    weak var activePlayer: PlaybackControl? {
        didSet {
            shownSince = Date()
            videoPaused = false
            if enhancement != .off { activePlayer?.setEnhancement(enhancement) }
            activePlayer?.setVolume(volume)
        }
    }

    static let volumeKey = "videoVolume"
    /// The volume of every video, 0 … 1 (↑ / ↓ on a video, in tenths);
    /// starts at 100 %, remembered.
    @Published private(set) var volume: Double = 1
    /// Changes with every volume step: the volume display shows a while.
    @Published private(set) var volumeChange: UUID?

    /// ↑ / ↓ on what's shown: a video's volume; a zoomed-in picture moves
    /// to show more of its top / bottom; otherwise nothing (paging is ← →).
    private func verticalKey(up: Bool) -> Bool {
        if shownMediaEntry?.kind == .video { changeVolume(by: up ? 0.1 : -0.1); return true }
        guard zoom > 1.01 else { return false }
        panRequest = PanRequest(up: up)
        return true
    }

    /// A step of looking further up or down in a zoomed-in picture (the
    /// picture view moves by part of its height).
    struct PanRequest: Equatable {
        let up: Bool
        let id = UUID()
    }
    @Published private(set) var panRequest: PanRequest?

    /// The volume another pane set (one volume for the window).
    func adoptVolume(_ value: Double) {
        guard value != volume else { return }
        volume = value
        activePlayer?.setVolume(value)
    }

    func changeVolume(by delta: Double) {
        volume = (min(max(volume + delta, 0), 1) * 10).rounded() / 10
        defaults.set(volume, forKey: Self.volumeKey)
        activePlayer?.setVolume(volume)
        volumeChange = UUID()
    }
    /// Auto enhance (E, the wand): works out exposure, contrast, saturation
    /// and sharpness for each photo and, now and then, for the video
    /// playing; the sliders (`look`) follow it. Stays on while paging until
    /// switched off, which shows the files as they are again.
    @Published var enhance = false {
        didSet {
            guard enhance != oldValue else { return }
            if !enhance && !adjustingByHand { manualLook = .neutral; look = .neutral }
            activePlayer?.setEnhancement(enhancement)
        }
    }
    /// The settings shown on the sliders: auto's for the item on screen
    /// while auto enhance is on, else the ones set by hand.
    @Published private(set) var look = Look.neutral
    /// Settings by hand; they stay while paging until reset.
    @Published private(set) var manualLook = Look.neutral
    private var adjustingByHand = false
    /// Whether the adjustment panel is open.
    @Published var showAdjustments = false

    /// What photos and videos show.
    var enhancement: Enhancement {
        enhance ? .auto : manualLook.isNeutral ? .off : .manual(manualLook)
    }

    /// A slider moved by hand: auto enhance goes off, and the look carries
    /// on from what was on screen.
    func adjust(_ new: Look) {
        adjustingByHand = true
        enhance = false
        adjustingByHand = false
        manualLook = new
        look = new
        activePlayer?.setEnhancement(enhancement)
    }

    /// Back to the files as they are.
    func resetLook() {
        enhance = false
        adjust(.neutral)
    }

    /// Auto enhance's look for the item on screen (a photo once, a video
    /// now and then), for the sliders. Ignored from a player no longer shown.
    func autoLookMeasured(_ measured: Look, from player: PlaybackControl? = nil) {
        guard enhance else { return }
        if let player, player !== activePlayer { return }
        // Only a change: every write publishes and redraws the grid behind
        guard look != measured else { return }
        look = measured
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
    /// Prefixes this pane's own settings (last folder, sort): the right pane
    /// of the dual pane remembers its own.
    let settingsPrefix: String
    private var lastFolderKey: String { settingsPrefix + Self.lastFolderKey }
    private var sortKeyKey: String { settingsPrefix + Self.sortKeyKey }
    private var sortAscendingKey: String { settingsPrefix + Self.sortAscendingKey }

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
    /// "._" files are never pictures: macOS keeps a file's extra data in them
    /// on volumes that can't hold it (SMB shares, exFAT, FAT).
    nonisolated static func mediaKind(of url: URL) -> GridEntry.Kind? {
        guard !url.lastPathComponent.hasPrefix("._") else { return nil }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    init(defaults: UserDefaults = .standard, fileActions: FileActions = .live, settingsPrefix: String = "") {
        self.settingsPrefix = settingsPrefix
        self.defaults = defaults
        self.fileActions = fileActions
        // UI tests (`--search-delay=<ms>`): a search that stays running long
        // enough to be watched and stopped
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), let arg = args.first(where: { $0.hasPrefix("--search-delay=") }),
           let ms = Int(arg.dropFirst("--search-delay=".count)) {
            searchDebounce = .milliseconds(ms)
        }
        showMiniKeyboard = defaults.bool(forKey: Self.miniKeyboardKey)
        if let raw = defaults.string(forKey: settingsPrefix + "viewMode"), let mode = ViewMode(rawValue: raw) { viewMode = mode }
        if let stored = defaults.object(forKey: Self.volumeKey) as? Double { volume = min(max(stored, 0), 1) }
        if let raw = defaults.string(forKey: sortKeyKey), let key = SortKey(rawValue: raw) {
            sortKey = key
            sortAscending = defaults.object(forKey: sortAscendingKey) as? Bool ?? key.startsAscending
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
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a folder")
        if panel.runModal() == .OK, let url = panel.url {
            open(folder: url)
        }
    }

    /// Navigate to a folder. Records the current location in the history.
    func open(folder url: URL, selecting target: URL? = nil, thenDetail: Bool = false) {
        recordHistory()
        load(Location(folder: url, selected: target), thenDetail: thenDetail)
    }

    private func load(_ location: Location, thenDetail: Bool = false, password: String? = nil) {
        isLoading = true            // first: keeps the searchText reset below from searching
        loadingLocation = location
        // What folders contain may have changed outside the app (Finder, a
        // camera import): previews and emptiness are found out afresh.
        emptyFolders = []
        FolderPreviewCache.shared.forgetAll()
        loadGeneration += 1
        let generation = loadGeneration
        leaveSearch()
        pendingResultSelection = nil
        folderURL = location.folder
        entries = []
        allEntries = []
        otherFiles = []
        loadError = nil
        clearMarks()
        selection = nil
        mode = .grid
        searchText = location.query
        resetTransforms()
        stopSlideshow()
        defaults.set(location.folder.path, forKey: lastFolderKey)
        let url = location.folder
        let target = location.selected
        Task {
            let scanned = await Self.listing(url, password: password)
            guard self.loadGeneration == generation else { return }   // a newer navigation won
            var full: [GridEntry] = []
            switch scanned {
            case .success(let listing):
                full = listing.entries
                self.otherFiles = listing.others
            case .failure(let error as CocoaError):
                // Not "empty": the folder couldn't be listed (no permission, a share gone)
                self.loadError = LoadError(archive: false, reason: error.localizedDescription)
            case .failure(ArchiveError.needsPassword):
                // Asked once; what is typed is remembered for every archive
                self.passwordRequest = PasswordRequest(archive: ArchivePath.split(url)?.archive.lastPathComponent ?? url.lastPathComponent,
                                                       location: location, thenDetail: thenDetail, wrong: password != nil)
            case .failure(let error):
                self.loadError = LoadError(archive: ArchivePath.split(url) != nil, reason: error.localizedDescription)
            }
            if let parent = Self.parentFolder(of: url) {
                full.insert(GridEntry(url: parent, kind: .parent), at: 0)
            }
            self.allEntries = self.sorted(full)
            self.isLoading = false
            self.loadingLocation = nil
            if self.isFiltering {
                if let run = location.search, run.query == self.query, !run.stoppedEarly {
                    // History: the remembered results; a search still
                    // running goes on adding to them.
                    self.search = run
                    self.isSearching = !run.finished
                    self.entries = self.sorted(run.results)
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
                self.selectDefault(in: self.entries)
            }
        }
    }

    /// UI tests (`--test-log=<path>`): what happened, a line each, for
    /// what the screen doesn't show (how often a rename ran).
    nonisolated static func testLog(_ line: String, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--ui-testing"),
              let arg = arguments.first(where: { $0.hasPrefix("--test-log=") }) else { return }
        let path = String(arg.dropFirst("--test-log=".count))
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// Reopen the last folder on launch (if it still exists).
    /// Checked off the main thread: a share that is mounted but unreachable
    /// (Wi-Fi asleep, VPN down) answers only after its timeout.
    func restoreLastFolder(orElse fallback: @escaping @MainActor () -> URL? = { nil }) {
        guard folderURL == nil else { return }
        guard let path = defaults.string(forKey: lastFolderKey) else {
            if let other = fallback() { open(folder: other) }
            return
        }
        Task {
            let exists = await Task.detached(priority: .userInitiated) {
                // A folder inside an archive: the archive file must still be there
                if let (archive, _) = ArchivePath.splitChecked(URL(fileURLWithPath: path)) {
                    return FileManager.default.fileExists(atPath: archive.path)
                }
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }.value
            // Unless the user opened something meanwhile
            guard folderURL == nil else { return }
            if exists { open(folder: URL(fileURLWithPath: path)) } else if let other = fallback() { open(folder: other) }
        }
    }

    /// CLI / UI-test seam: `--open=<path>` opens a folder (grid) or a file
    /// (straight into the full-size view) on launch — same rules as drag &
    /// drop. One argument: AppKit reads "-name value" pairs as settings, so a
    /// path as an argument of its own can end up unpaired, and AppKit then
    /// takes it for a file to open and shows no window.
    @discardableResult
    func openFromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let arg = args.first(where: { $0.hasPrefix("--open=") }) else { return false }
        let url = URL(fileURLWithPath: String(arg.dropFirst("--open=".count)))
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        openDropped([url])
        return true
    }

    /// Read a directory — including hidden entries, with date/size.
    /// Runs off the main thread; metadata is prefetched during
    /// enumeration (no extra round-trips).
    nonisolated static func scan(_ url: URL) async -> [GridEntry] {
        (try? await scanResult(url).get()) ?? []
    }

    /// A folder's listing, or why it can't be read (an archive that needs
    /// a password; `password` is one just typed for it).
    nonisolated static func scanResult(_ url: URL, password: String? = nil) async -> Result<[GridEntry], Error> {
        await listing(url, password: password).map(\.entries)
    }

    /// What the grid shows of a folder, plus its other files.
    nonisolated static func listing(_ url: URL, password: String? = nil) async -> Result<FolderListing, Error> {
        if await Task.detached(priority: .userInitiated, operation: { ArchivePath.splitChecked(url) }).value != nil {
            do { return .success(try await ArchiveStore.shared.listing(in: url, trying: password)) }
            catch { return .failure(error) }
        }
        do { return .success(try await scanFolder(url)) }
        catch { return .failure(error) }
    }

    nonisolated private static func scanFolder(_ url: URL) async throws -> FolderListing {
        try await Task.detached(priority: .userInitiated) {
            let keys = entryKeys
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            var listing = FolderListing()
            for item in contents {
                if let entry = entry(for: item, keys: keys) { listing.entries.append(entry); continue }
                let vals = try? item.resourceValues(forKeys: keys)
                // Hidden files (".DS_Store", "._…") aren't listed; folders that
                // aren't shown are packages, which count as files
                guard !item.lastPathComponent.hasPrefix("."),
                      vals?.isDirectory != true || vals?.isPackage == true else { continue }
                listing.others.append(OtherFile(url: item, byteSize: vals?.isPackage == true ? nil : vals?.fileSize))
            }
            // A split archive's later volumes belong to its tile
            // (names compared ignoring case: "MOVIE.PART2.RAR" belongs to "MOVIE.PART1.RAR")
            let names = Set(contents.map { $0.lastPathComponent.lowercased() })
            listing.others.removeAll { ArchiveName.firstVolumeNames(of: $0.name).contains { names.contains($0.lowercased()) } }
            listing.others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return listing
        }.value
    }

    /// What `entry(for:keys:)` reads, prefetched by the listings.
    nonisolated static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey
    ]

    /// Classify one file system item; nil for non-media files. Packages
    /// (".photoslibrary", ".app") are single files to the user, as in the
    /// Finder: not a folder to browse, walk in a slideshow or search.
    nonisolated private static func entry(for item: URL, keys: Set<URLResourceKey>) -> GridEntry? {
        let vals = try? item.resourceValues(forKeys: keys)
        let date = vals?.contentModificationDate
        if vals?.isPackage == true { return nil }
        if vals?.isDirectory == true {
            if ArchiveName.format(of: item.lastPathComponent) != nil { ArchivePath.noteFolder(item) }
            return GridEntry(url: item, kind: .folder, modDate: date)
        }
        // An archive opens like a folder
        if ArchiveName.format(of: item.lastPathComponent) != nil {
            return GridEntry(url: item, kind: .folder, modDate: date, byteSize: vals?.fileSize)
        }
        guard let kind = mediaKind(of: item) else { return nil }
        return GridEntry(url: item, kind: kind, modDate: date, byteSize: vals?.fileSize)
    }

    /// Whether a photo or video lies anywhere below `folder`. Stops at the
    /// first one, so only folders that are really empty are walked to the
    /// end. Hidden files (".DS_Store", "._…") and anything that isn't a
    /// picture or video ("Thumbs.db", "desktop.ini") don't count.
    /// nil when cancelled before it knew (the tile went away): no answer to
    /// remember.
    nonisolated static func containsMedia(_ folder: URL) async -> Bool? {
        if ArchivePath.split(folder) != nil, await Task.detached(operation: { ArchivePath.splitChecked(folder) }).value != nil {
            // An archive that needs a password: not known (not greyed out)
            guard let media = try? await ArchiveStore.shared.media(below: folder) else { return nil }
            return !media.isEmpty
        }
        let walk = Task.detached(priority: .utility) { anyMedia(below: folder) }
        return await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
    }

    /// The walk itself, synchronous (a directory enumerator isn't for async
    /// code); nil when its task is cancelled.
    nonisolated private static func anyMedia(below folder: URL) -> Bool? {
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in walk {
            if Task.isCancelled { return nil }
            // An archive opens like a folder; what's in it isn't looked into
            // here (that means unpacking), so it counts as holding something
            if mediaKind(of: url) != nil || ArchiveName.format(of: url.lastPathComponent) != nil, isFile(url) { return true }
        }
        return false
    }

    /// A file, not a folder named like one ("Export.mov"). The enumerators
    /// read this along with the listing.
    nonisolated private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
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
        // Only on a change: every write publishes and redraws the grid
        guard emptyFolders.contains(path) != empty else { return }
        if empty { emptyFolders.insert(path) } else { emptyFolders.remove(path) }
    }

    /// The media files a folder tile previews: the first `limit` by name,
    /// read from one shallow, non-recursive directory listing.
    nonisolated static func folderPreviewFiles(in folder: URL, limit: Int = 3) async -> [URL] {
        if ArchivePath.split(folder) != nil, await Task.detached(operation: { ArchivePath.splitChecked(folder) }).value != nil {
            // An archive: its first pictures at any depth (archives often
            // hold one folder at the top). Not videos: they'd be unpacked.
            let media = (try? await ArchiveStore.shared.media(below: folder)) ?? []
            return Array(media.filter { mediaKind(of: $0) == .image }.prefix(limit))
        }
        return await Task.detached(priority: .utility) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            // One pass keeping the `limit` first names, instead of sorting a
            // possibly huge listing to take three.
            func before(_ a: URL, _ b: URL) -> Bool {
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            var first: [URL] = []
            for url in contents where mediaKind(of: url) != nil && isFile(url) {
                guard first.count < limit || before(url, first[first.count - 1]) else { continue }
                first.insert(url, at: first.firstIndex { before(url, $0) } ?? first.count)
                if first.count > limit { first.removeLast() }
            }
            if !first.isEmpty { return first }
            // None at the top: the first ones further down, so a folder of
            // folders previews what's inside them too
            guard let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var looked = 0
            for case let url as URL in walk {
                looked += 1
                if looked > 20_000 || Task.isCancelled { break }   // a huge tree: give up, not hang
                if mediaKind(of: url) != nil, isFile(url) {
                    first.append(url)
                    if first.count == limit { break }
                }
            }
            return first
        }.value
    }

    /// Sorted: ".." on top, then folders, then media — each group by key.
    /// Ties (same kind, date or size) fall back to the name, always A→Z, so
    /// the order is stable. `captured` holds the capture dates read so far.
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
                return byName(a, b)   // the key itself, reversed with the direction
            case .kind:
                // Folders are all one kind (a dot in a folder name isn't an extension)
                guard a.isMedia, b.isMedia else { return .orderedSame }
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
            let result = compare(a, b)
            // Ties go by name A→Z in either direction, like Finder
            if result == .orderedSame { return byName(a, b) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return parents + folders.sorted(by: before) + media.sorted(by: before)
    }

    /// Choose the sort order. The same key again reverses the direction; a
    /// new key starts in its natural direction. Remembered across launches.
    func setSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = key.startsAscending }
        defaults.set(key.rawValue, forKey: sortKeyKey)
        defaults.set(sortAscending, forKey: sortAscendingKey)
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
        guard sortKey == .captured || viewMode == .list else { return }   // the list shows them
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
        guard !ArchivePath.isInside(url) else { return nil }   // not unpacked for sorting
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
        guard !isLoading else { return }
        searchStopped = false
        clearMarks()
        leaveSearch()
        let query = self.query
        guard !query.isEmpty else {
            pendingResultSelection = nil
            let keep = selectedEntry?.url
            entries = allEntries
            if let kept = index(of: keep) { selection = kept } else { selectDefault(in: allEntries) }
            return
        }
        mode = .grid
        let local = allEntries.filter {
            $0.kind != .parent && $0.name.localizedCaseInsensitiveContains(query)
        }
        let run = SearchRun(query: query, results: local)
        search = run
        showResults(initial: true)

        guard let root = folderURL else { run.finished = true; return }
        isSearching = true
        let debounce = searchDebounce
        run.task = Task { [weak self, weak run] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            for await batch in Self.recursiveMatches(under: root, query: query) {
                guard let self, let run, !Task.isCancelled else { return }
                self.add(batch, to: run)
            }
            guard let self, let run, !Task.isCancelled else { return }
            run.finished = true
            if run === self.search { self.isSearching = false }
        }
    }

    /// The search on screen goes: it keeps running if the history holds
    /// it (the user went into a result and may come back), else it stops.
    private func leaveSearch() {
        if let search, !search.finished, !historySearches.contains(where: { $0 === search }) {
            search.stop(incomplete: true)
        }
        search = nil
        isSearching = false
        // Only the newest few unfinished searches in the history go on.
        let running = historySearches.filter { !$0.finished }
        for old in running.dropLast(Self.backgroundSearchLimit) { old.stop(incomplete: true) }
    }

    /// Every search the history holds, oldest first, each once.
    private var historySearches: [SearchRun] { Self.distinct((backStack + forwardStack.reversed()).compactMap(\.search)) }
    /// The search on screen and those in the history.
    private var allSearches: [SearchRun] { Self.distinct(historySearches + [search].compactMap { $0 }) }
    private static func distinct(_ runs: [SearchRun]) -> [SearchRun] {
        var seen = Set<ObjectIdentifier>()
        return runs.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Stops the running search (the stop button); what it has found stays.
    func stopSearch() {
        guard let search, !search.finished else { return }
        search.stop(incomplete: false)
        isSearching = false
        searchStopped = true
    }

    /// The user stopped the search on screen: "no matches" means none so far.
    @Published private(set) var searchStopped = false

    /// Add a streamed batch to the search on screen. Internal so tests can
    /// deliver a batch the walk read before a rename or trash.
    func appendSearchBatch(_ batch: [GridEntry]) {
        if let search { add(batch, to: search) }
    }

    private func add(_ batch: [GridEntry], to run: SearchRun) {
        guard run.add(batch), run === search else { return }
        showResults(initial: false)
    }

    /// Publish search results, keeping the selected item selected while
    /// results stream in.
    private func showResults(initial: Bool) {
        let keep = initial ? nil : selectedEntry?.url
        entries = sorted(search?.results ?? [])
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
        if ArchivePath.split(root) != nil {
            // In an archive: its list of names, known already
            return AsyncStream { continuation in
                let task = Task.detached(priority: .userInitiated) {
                    if ArchivePath.splitChecked(root) != nil,
                       let found = try? await ArchiveStore.shared.matches(below: root, query: query), !found.isEmpty {
                        continuation.yield(found)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncStream { continuation in
            let walker = Task.detached(priority: .userInitiated) {
                let keys = entryKeys
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

    /// Drag & drop: open a folder; for a file → open the parent folder and
    /// select it. Dropped on the "Slideshow" zone, a slideshow starts over
    /// the folder (for a file: over its folder, at that file), the grid of
    /// that folder behind it.
    func openDropped(_ urls: [URL], slideshow: Bool = false) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir) else { return }
        // An archive opens like a folder
        let opensAsFolder = isDir.boolValue || ArchiveName.format(of: first.lastPathComponent) != nil
        let folder = opensAsFolder ? first : first.deletingLastPathComponent()
        let file = opensAsFolder ? nil : first
        if slideshow {
            open(folder: folder, selecting: file)
            startSlideshow(over: folder, startingAt: file)
        } else if let file {
            open(folder: folder, selecting: file, thenDetail: true)
        } else {
            open(folder: folder)
        }
    }

    // MARK: - History (back / forward)

    /// The place on screen, with its search (finished or still running).
    private var currentLocation: Location? {
        guard let folderURL else { return nil }
        // Still loading: the place being loaded, with its selection and
        // search (the grid has neither yet).
        if isLoading, var loading = loadingLocation {
            if loading.query != searchText { loading.query = searchText; loading.search = nil }
            return loading
        }
        let run = isFiltering && !isLoading ? search : nil
        return Location(folder: folderURL, query: searchText, selected: selectedEntry?.url, search: run)
    }

    private func recordHistory() {
        guard let current = currentLocation else { return }
        if let last = backStack.last, Self.sameSpot(last, current) {
            backStack[backStack.count - 1] = current
        } else {
            let pushed = Self.pushing(current, onto: backStack)
            backStack = pushed.stack
            stopSearches(of: pushed.dropped)
        }
        let dropped = forwardStack
        forwardStack.removeAll()
        stopSearches(of: dropped)
    }

    /// Searches of locations that left the history stop, unless the screen
    /// or another history step still shows them.
    private func stopSearches(of dropped: [Location]) {
        let kept = allSearches
        for run in dropped.compactMap(\.search) where !run.finished && !kept.contains(where: { $0 === run }) {
            run.stop(incomplete: true)
        }
    }

    /// Same folder, query and selection; the result lists aren't compared.
    private static func sameSpot(_ a: Location, _ b: Location) -> Bool {
        samePath(a.folder, b.folder) && a.query == b.query
            && a.selected.map(canonicalPath) == b.selected.map(canonicalPath)
    }

    /// `stack` with `location` on top, at most `historyLimit` deep, and the
    /// steps that fell off the far end (their searches stop once the stack
    /// is stored).
    private static func pushing(_ location: Location, onto stack: [Location]) -> (stack: [Location], dropped: [Location]) {
        let all = stack + [location]
        return (Array(all.suffix(historyLimit)), Array(all.dropLast(historyLimit)))
    }

    /// Back. The full view isn't a history step of its own (it opens in
    /// place, over the folder or the search results), so from there Back
    /// returns to that grid, with the search and its results as they were.
    func navigateBack() {
        if mode == .detail { closeDetail(); return }
        guard let target = backStack.popLast() else { return }
        if let current = currentLocation {
            let pushed = Self.pushing(current, onto: forwardStack)
            forwardStack = pushed.stack
            stopSearches(of: pushed.dropped)
        }
        load(target)
    }

    func navigateForward() {
        guard let target = forwardStack.popLast() else { return }
        if let current = currentLocation {
            let pushed = Self.pushing(current, onto: backStack)
            backStack = pushed.stack
            stopSearches(of: pushed.dropped)
        }
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

    // MARK: Marking several items

    /// Items marked besides the selection (⌘-click, ⇧-click, ⇧-arrows, ⌘A,
    /// Insert), as canonical paths. Empty: the selection alone counts.
    @Published private(set) var marked: Set<String> = []
    /// Where a range (⇧) starts.
    private var markAnchor: Int?

    func isMarked(_ entry: GridEntry) -> Bool { marked.contains(Self.canonicalPath(entry.url)) }

    /// What file actions work on: the marked items in grid order, else the
    /// selected one. Never "..".
    var actionEntries: [GridEntry] {
        if marked.isEmpty { return selectedEntry.map { $0.kind == .parent ? [] : [$0] } ?? [] }
        return entries.filter { $0.kind != .parent && marked.contains(Self.canonicalPath($0.url)) }
    }

    func clearMarks() {
        if !marked.isEmpty { marked = [] }
        markAnchor = nil
    }

    /// A click on a tile: plain selects it (and unmarks), ⌘ marks or unmarks
    /// it, ⇧ marks the range from the last one.
    /// The selection a click just made: that tile is under the pointer, so
    /// the grid doesn't scroll to it (a double click's second click must
    /// meet the same tile).
    var clickedSelection: Int?

    func click(_ entry: GridEntry, command: Bool, shift: Bool) {
        guard let index = index(of: entry.url) else { return }
        onActivate?()
        clickedSelection = selection == index ? nil : index
        if shift { markRange(to: index); return }
        if command {
            // The one selected joins, if the user chose it (not the tile
            // selected by default on opening the folder)
            if marked.isEmpty, selectionChosen, let current = selectedEntry, current.kind != .parent, current.url != entry.url {
                marked.insert(Self.canonicalPath(current.url))   // the one selected joins
            }
            let path = Self.canonicalPath(entry.url)
            if entry.kind != .parent { if marked.contains(path) { marked.remove(path) } else { marked.insert(path) } }
            selection = index
            markAnchor = index
            return
        }
        clearMarks()
        selection = index
        markAnchor = index
    }

    /// Marks everything from the anchor to `index` and moves the selection there.
    func markRange(to index: Int) {
        guard entries.indices.contains(index) else { return }
        // The anchor can be past the end once items left the listing
        let anchor = min(markAnchor ?? selection ?? index, entries.count - 1)
        let range = min(anchor, index)...max(anchor, index)
        marked = Set(entries[range].filter { $0.kind != .parent }.map { Self.canonicalPath($0.url) })
        markAnchor = anchor
        selection = index
    }

    /// Insert (as in the commanders): marks or unmarks the selected item and
    /// moves on to the next.
    func toggleMarkAndAdvance() {
        guard let entry = selectedEntry, let index = selection else { return }
        if entry.kind != .parent {
            let path = Self.canonicalPath(entry.url)
            if marked.contains(path) { marked.remove(path) } else { marked.insert(path) }
        }
        // A range (⇧) goes on from where the cursor is now
        if index + 1 < entries.count { selection = index + 1 }
        markAnchor = selection
    }

    func markAll() {
        marked = Set(entries.filter { $0.kind != .parent }.map { Self.canonicalPath($0.url) })
        markAnchor = selection
    }

    /// Selects an item by its file, wherever it is in the list now (search
    /// results may have moved it since a menu was opened); false if it's gone.
    @discardableResult
    func select(_ entry: GridEntry) -> Bool {
        guard let index = index(of: entry.url) else { return false }
        onActivate?()
        selection = index
        return true
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
    /// Archives, counted apart from folders (they open like folders).
    private(set) var archiveCount = 0
    private(set) var imageCount = 0
    private(set) var videoCount = 0
    private var firstMediaIndex: Int?

    private func recomputeDerived() {
        var folders = 0, archives = 0, images = 0, videos = 0
        var first: Int?
        for (idx, entry) in entries.enumerated() {
            switch entry.kind {
            case .folder:
                if entry.isArchive { archives += 1 } else { folders += 1 }
            case .image:  images += 1; if first == nil { first = idx }
            case .video:  videos += 1; if first == nil { first = idx }
            case .parent: break
            }
        }
        folderCount = folders
        archiveCount = archives
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
    /// Whether the full view or the slideshow is up (zoom keys zoom it).
    private var viewingMedia: Bool { mode == .detail || slideshow != nil }

    func scaleUp()   { viewingMedia ? zoomIn()  : growThumbnails() }
    func scaleDown() { viewingMedia ? zoomOut() : shrinkThumbnails() }

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
    /// Backspace, like a browser's Back: out of the full view, else where
    /// the user was before (also back to a search and its results); with no
    /// history yet, the enclosing folder.
    func leaveDetailOrGoBack() {
        if mode == .detail { closeDetail(); return }
        if canGoBack { navigateBack() } else { goToParentFolder() }
    }

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
    func handleKey(_ key: KeyInput, command: Bool, shift: Bool = false, textEditing: Bool = false,
                   repeating: Bool = false) -> Bool {
        keyRepeating = repeating
        defer { keyRepeating = false }
        let handled = dispatchKey(key, command: command, shift: shift, textEditing: textEditing)
        // The mini keyboard lights up the key that acted, typed or clicked
        if handled { lastKeyPress = KeyPress(key: key, command: command, shift: shift) }
        return handled
    }

    /// A key that acted, for the mini keyboard to light it up.
    struct KeyPress: Equatable {
        let key: KeyInput
        let command: Bool
        let shift: Bool
        let id = UUID()
        /// The same key, whenever pressed (letters in any case).
        func matches(_ key: KeyInput, command: Bool, shift: Bool) -> Bool {
            guard self.command == command, self.shift == shift else { return false }
            if case .char(let a) = self.key, case .char(let b) = key { return a.lowercased() == b.lowercased() }
            return self.key == key
        }
    }
    @Published private(set) var lastKeyPress: KeyPress?

    /// A key the window handled (D, Tab, F5, F6), for the mini keyboard.
    func noteKeyPress(_ key: KeyInput, command: Bool) {
        lastKeyPress = KeyPress(key: key, command: command, shift: false)
    }

    /// Tiles or a list (L): per pane, remembered.
    enum ViewMode: String { case grid, list }
    @Published var viewMode: ViewMode = .grid {
        didSet {
            defaults.set(viewMode.rawValue, forKey: settingsPrefix + "viewMode")
            if viewMode == .list { columnCount = 1; readCaptureDatesIfNeeded() }
        }
    }

    /// A capture date read already (the list's Date Taken column).
    func knownCaptureDate(of url: URL) -> Date? { captureDates[url] }

    static let miniKeyboardKey = "showMiniKeyboard"
    /// The mini keyboard under the window (K): the keys of what's on screen,
    /// clickable, lit up when used. Remembered.
    @Published var showMiniKeyboard = false {
        didSet { defaults.set(showMiniKeyboard, forKey: Self.miniKeyboardKey) }
    }

    private func dispatchKey(_ key: KeyInput, command: Bool, shift: Bool, textEditing: Bool) -> Bool {
        let sheetOpen = anySheetOpen
        switch key {
        case .f1:
            guard !otherSheetOpen else { return false }
            if showHelp { showHelp = false } else { openHelp() }
            return true
        case .f2, .f6:
            // Rename: F2, and Norton's F6 (in a single pane; ⇧F6 anywhere —
            // in the dual pane F6 moves, the window's). Also while typing in
            // the search field; not during a slideshow (the selection is in
            // the hidden grid).
            guard !sheetOpen, slideshow == nil else { return false }
            return beginRename()
        default:
            guard !textEditing, !sheetOpen else { return false }
        }
        // Esc closes the Adjustments popover first, as it would by itself.
        if key == .escape, showAdjustments { showAdjustments = false; return true }
        if slideshow != nil { return handleSlideshowKey(key, command: command, shift: shift) }
        switch key {
        case .f1, .f2:
            return false   // handled above
        case .f9, .f10:
            return false   // the window's: the menus, quit
        case .tab, .f5, .f6:
            return false   // the window's (two panes), F6 above
        case .f3:
            guard mode == .grid, selectedEntry != nil else { return false }
            activateSelection(); return true
        case .f4:
            guard mode == .grid || selectedMediaEntry != nil, selectionIsChangeable else { return false }
            openInDefaultApp(); return true
        case .insert:
            guard mode == .grid else { return false }
            toggleMarkAndAdvance(); return true
        case .f7:
            return beginNewFolder()
        case .f8:
            guard mode == .grid, canTrash else { return false }
            moveSelectionToTrash(); return true
        case .backspace:
            guard !command else { return false }
            leaveDetailOrGoBack(); return true
        case .escape:
            if mode == .detail { closeDetail(); return true }
            if !marked.isEmpty { clearMarks(); return true }   // first the marks
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
            if mode == .grid {
                // ⇧: marks the range on the way
                if shift, let current = selection { markRange(to: min(max(current + direction, 0), entries.count - 1)) }
                else { step(direction) }
            }
            else if command { stepMedia(direction) }
            else if shift { fineSkim(direction) }
            else { skim(direction) }
            return true
        case .up:
            if command { goToParentFolder(); return true }
            if mode == .detail { return verticalKey(up: true) }
            if shift, let current = selection, current - columnCount >= 0 { markRange(to: current - columnCount); return true }
            stepRow(-1); return true
        case .down:
            if mode == .detail { return verticalKey(up: false) }
            if shift, let current = selection, current + columnCount < entries.count { markRange(to: current + columnCount); return true }
            stepRow(+1); return true
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
        case "a" where command:
            guard mode == .grid else { return false }
            markAll(); return true
        case "[" where command: navigateBack();    return true
        case "]" where command: navigateForward(); return true
        case "s" where !command: startSlideshow(); return true
        case "e" where !command: enhance.toggle(); return true
        case "a" where !command: showAdjustments.toggle(); return true
        case "k" where !command: showMiniKeyboard.toggle(); return true
        case "l" where !command: viewMode = viewMode == .grid ? .list : .grid; return true
        default:
            break
        }
        guard viewingMedia, !command else { return false }
        switch c {
        case "0": zoomReset();            return true
        case "1": zoomActualSize();       return true
        case "[": rotateLeft();           return true
        case "]": rotateRight();          return true
        case "i": showInspector.toggle(); return true
        default:  return false
        }
    }

    // MARK: - Slideshow

    /// Focus the search field — only when it is enabled (a folder is open);
    /// a request on the disabled field would grab focus later.
    func focusSearch() {
        searchFocused = folderURL != nil
        Self.testLog("focus search: \(searchFocused)")
    }


    // MARK: - File actions

    func revealInFinder() {
        guard slideshow == nil else { return }   // the selection is in the hidden grid
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        // Inside an archive: the archive file
        fileActions.reveal(ArchivePath.isInside(entry.url) ? ArchivePath.split(entry.url)!.archive : entry.url)
    }

    func openInDefaultApp() {
        guard slideshow == nil else { return }   // the selection is in the hidden grid
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        guard !ArchivePath.isInside(entry.url) else { NSSound.beep(); return }   // not a file other apps can open
        fileActions.openInDefaultApp(entry.url)
    }

    /// Whether the selection is a file on disk the app may change (not
    /// something inside an archive: archives are only read).
    var selectionIsChangeable: Bool {
        guard let entry = selectedEntry, entry.kind != .parent else { return false }
        return !ArchivePath.isInside(entry.url)
    }

    /// What the Trash takes: the marked items (grid), else the selected one.
    private var trashEntries: [GridEntry] {
        guard mode == .grid else { return selectedMediaEntry.map { [$0] } ?? [] }
        return actionEntries.filter { !ArchivePath.isInside($0.url) }
    }

    /// The Trash has something to take (the menu item and ⌘⌫).
    var canTrash: Bool { slideshow == nil && !trashEntries.isEmpty }

    func moveSelectionToTrash() {
        guard slideshow == nil else { return }   // the selection is in the hidden grid
        let items = trashEntries
        // Several (marked): all of them, after one confirmation
        if items.count > 1 { trashMarked(items); return }
        guard let entry = items.first ?? selectedEntry, entry.kind != .parent else { return }
        guard !ArchivePath.isInside(entry.url) else { NSSound.beep(); return }   // archives are only read
        // What goes with it, said exactly: a folder's whole contents (also
        // what the grid doesn't show), all parts of a split archive
        let isArchive = entry.isArchive
        let files = isArchive ? ArchiveName.allFiles(of: entry.url) : [entry.url]
        let detail = entry.kind == .folder && !isArchive
            ? String(localized: "The folder and everything in it, including files Schnellbild doesn't show, will be moved to the Trash.")
            : files.count > 1 ? String(localized: "All parts of this archive will be moved to the Trash.")
            : String(localized: "The file will be moved to the Trash.")
        guard fileActions.confirmTrash(entry.name, detail) else { return }
        do {
            for file in files { try fileActions.trash(file) }
        } catch {
            fileActions.report(error)
            return
        }
        clearMarks()
        apply(.removed(entry.url))
        notifyFolderChanges([entry.url.deletingLastPathComponent()])
        if mode == .detail {
            // The next item comes up as paging shows it: at fit, upright.
            resetTransforms()
            if selectedMediaEntry == nil { mode = .grid }
        }
    }

    /// Every item confirmed goes, also after one that fails (it is reported;
    /// an item inside a folder trashed before it is gone with it).
    private func trashMarked(_ items: [GridEntry]) {
        let names = items.prefix(4).map(\.name).joined(separator: ", ") + (items.count > 4 ? ", …" : "")
        let detail = String(localized: "The marked items will be moved to the Trash, folders with everything in them.")
        guard fileActions.confirmTrash(names, detail) else { return }
        clearMarks()
        var trashed: [URL] = []
        var reported = false
        for item in items {
            let path = Self.canonicalPath(item.url)
            if trashed.contains(where: { path.hasPrefix(Self.canonicalPath($0) + "/") }) { continue }
            let files = item.isArchive ? ArchiveName.allFiles(of: item.url) : [item.url]
            do {
                for file in files { try fileActions.trash(file) }
                trashed.append(item.url)
            } catch {
                if !reported { fileActions.report(error); reported = true }
            }
        }
        for url in trashed { apply(.removed(url)) }
        notifyFolderChanges(Array(Set(trashed.map { $0.deletingLastPathComponent() })))
    }

    // MARK: Changes the other pane must see

    /// Told about every folder whose contents this pane changed on disk (the
    /// window passes it to the other pane).
    var onFoldersChanged: (([URL]) -> Void)?

    private func notifyFolderChanges(_ folders: [URL]) {
        onFoldersChanged?(folders)
    }

    /// The folder shown, read again (another pane changed it): query,
    /// selection and marks stay where they can.
    func refresh() {
        guard folderURL != nil, !isLoading else { return }
        // Not under the full view or a slideshow: read again once back in the grid
        guard mode == .grid, slideshow == nil else { refreshDeferred = true; return }
        guard let folderURL else { return }
        let keepMarks = marked
        let location = Location(folder: folderURL, query: searchText, selected: selectedEntry?.url)
        load(location)
        marked = keepMarks
    }

    private var refreshDeferred = false

    private func refreshIfDeferred() {
        guard refreshDeferred else { return }
        refreshDeferred = false
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Whether a change in `folders` shows here: the folder itself, or one
    /// below it while searching.
    func shows(any folders: [URL]) -> Bool {
        guard let folderPath else { return false }
        return folders.contains { folder in
            let path = Self.canonicalPath(folder)
            return path == folderPath || (isFiltering && path.hasPrefix(folderPath + "/"))
        }
    }

    /// F1 / "Schnellbild Help". Not over the rename sheet: a second sheet
    /// can't open on top of it.
    func openHelp() {
        guard !otherSheetOpen else { return }
        showHelp = true
    }

    /// A sheet other than the help is open (a second sheet can't open on top).
    var otherSheetOpen: Bool { renameTarget != nil || passwordRequest != nil || newFolderRequested }
    /// Any of the sheets is open (they keep their keys).
    var anySheetOpen: Bool { showHelp || otherSheetOpen }

    // MARK: - New folder, moving into folders

    /// The new-folder sheet is open (⇧⌘N): nothing exists until a name is
    /// given and confirmed; Esc leaves no folder behind.
    @Published var newFolderRequested = false

    /// "IMG 2.jpg", "IMG 3.jpg" … for a name taken in `folder`.
    static func freeName(for name: String, in folder: URL, isFolder: Bool = false, taken: (URL) -> Bool) -> URL {
        // As the Finder: a folder's number goes after its whole name
        let stem = isFolder ? name : (name as NSString).deletingPathExtension
        let ext = isFolder ? "" : (name as NSString).pathExtension
        for n in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !taken(candidate) { return candidate }
        }
        return folder.appendingPathComponent(name)
    }

    /// A name as typed, checked: not empty, no "/" or ":", not "." / "..".
    static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.emptyName }
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw RenameError.invalidName
        }
        return name
    }

    /// Whether a folder can be made here: a real folder, not inside an
    /// archive, no slideshow or sheet in the way.
    var canCreateFolder: Bool {
        // In the grid: what it makes is selected there
        guard let folderURL, mode == .grid, slideshow == nil, !isLoading else { return false }
        return !anySheetOpen && ArchivePath.split(folderURL) == nil
    }

    @discardableResult
    func beginNewFolder() -> Bool {
        guard canCreateFolder else { return false }
        searchFocused = false
        newFolderRequested = true
        return true
    }

    /// Makes the folder named in the sheet in the folder shown, and selects it.
    @discardableResult
    func createFolder(named raw: String) throws -> URL {
        guard let folderURL, canCreateFolder || newFolderRequested else { throw RenameError.invalidName }
        let name = try Self.validName(raw)
        let url = folderURL.appendingPathComponent(name, isDirectory: true)
        // Any item of that name there (compared with the folder itself: a
        // different item, so an existing one counts)
        if fileActions.conflicts(url, folderURL) { throw RenameError.alreadyExists(name) }
        do {
            try fileActions.createFolder(url)
        } catch {
            throw RenameError.failed(error.localizedDescription)
        }
        newFolderRequested = false
        notifyFolderChanges([folderURL])
        let entry = GridEntry(url: url, kind: .folder, modDate: Date())
        allEntries = sorted(allEntries + [entry])
        noteFolder(url, empty: true)
        if !isFiltering {
            entries = allEntries
            selection = index(of: url)
        }
        return url
    }

    /// How items go into another folder: dropped (moved on the same
    /// volume, copied to another, as in the Finder), F5 (copied), F6 (moved).
    enum Transfer { case asFinder, copy, move }

    /// Files or folders dropped onto a folder tile (or ".."), or sent to the
    /// other pane (F5 / F6), go into `folder`. A name taken there asks: keep
    /// both (the new one numbered) or skip. Not into archives, not into
    /// themselves.
    func move(_ sources: [URL], into folder: URL, how: Transfer = .asFinder) {
        guard ArchivePath.split(folder) == nil else { NSSound.beep(); return }
        let target = Self.canonicalPath(folder)
        let shown = folderPath
        var changed = [folder]
        for source in sources {
            let path = Self.canonicalPath(source)
            guard !ArchivePath.isInside(source), path != target, !target.hasPrefix(path + "/"),
                  // Never the folder shown or one around it
                  shown.map({ $0 != path && !$0.hasPrefix(path + "/") }) ?? true,
                  Self.canonicalPath(source.deletingLastPathComponent()) != target else { continue }
            // A split archive goes with all its parts
            let files = ArchiveName.format(of: source.lastPathComponent) != nil ? ArchiveName.allFiles(of: source) : [source]
            var destination = folder.appendingPathComponent(source.lastPathComponent)
            if fileActions.conflicts(destination, source) {
                guard fileActions.askKeepBoth(source.lastPathComponent, folder.lastPathComponent) else { continue }
                // Renamed, the parts of a split archive no longer belong together
                guard files.count == 1 else { NSSound.beep(); continue }
                let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                destination = Self.freeName(for: source.lastPathComponent, in: folder, isFolder: isFolder,
                                            taken: { self.fileActions.conflicts($0, source) })
            }
            do {
                var moved = false
                for file in files {
                    let to = file == source ? destination : folder.appendingPathComponent(file.lastPathComponent)
                    switch how {
                    case .asFinder: moved = try fileActions.transfer(file, to)
                    case .copy:     try fileActions.copy(file, to); moved = false
                    case .move:     try fileActions.move(file, to); moved = true
                    }
                }
                if moved {
                    apply(.moved(source, to: destination))
                    changed.append(source.deletingLastPathComponent())
                } else {
                    FolderPreviewCache.shared.forget([target])
                    folderChanges += 1
                }
            } catch {
                fileActions.report(error)
            }
        }
        notifyFolderChanges(changed)
        // What was moved is no longer marked here
        clearMarks()
        guard let shown else { return }
        // Into the folder shown (a drop onto the pane): read it again to show what came
        if target == shown { refresh(); return }
        // What went into a subfolder leaves this folder's listing
        let here: (GridEntry) -> Bool = { $0.kind == .parent || Self.canonicalPath($0.url.deletingLastPathComponent()) == shown }
        let keep = selectedEntry?.url
        allEntries = allEntries.filter(here)
        if !isFiltering {
            entries = allEntries
            if let index = index(of: keep) {
                if selection != index { selection = index }
            } else {
                selectDefault(in: entries)
            }
        }
        // The full view shows media only: back to the grid when what it showed left
        if mode == .detail, selectedMediaEntry == nil { mode = .grid }
    }

    /// Whether the folder shown can be renamed in place (its name in the
    /// title bar): a real folder, not inside an archive, not a volume's top.
    var canRenameCurrentFolder: Bool {
        guard let folderURL, slideshow == nil, !isLoading, ArchivePath.split(folderURL) == nil else { return false }
        return Self.parentFolder(of: folderURL) != nil && folderURL.pathComponents.count > 3   // not "/" or "/Volumes/X"
    }

    /// The folder shown, renamed from its name in the title bar: it stays
    /// open under the new name; history and results follow. A name that
    /// can't be used is reported.
    func renameCurrentFolder(to raw: String) {
        guard canRenameCurrentFolder, let old = folderURL else { return }
        do {
            let name = try Self.validName(raw)
            guard name != old.lastPathComponent else { return }
            let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            if fileActions.conflicts(new, old) { throw RenameError.alreadyExists(name) }
            do { try fileActions.move(old, new) } catch { throw RenameError.failed(error.localizedDescription) }
            apply(.moved(old, to: new))
            folderURL = new
            defaults.set(new.path, forKey: lastFolderKey)
            if let parent = Self.parentFolder(of: new), let i = allEntries.firstIndex(where: { $0.kind == .parent }) {
                allEntries[i] = GridEntry(url: parent, kind: .parent)
                if let j = entries.firstIndex(where: { $0.kind == .parent }) { entries[j] = allEntries[i] }
            }
            notifyFolderChanges([old.deletingLastPathComponent(), new])
        } catch {
            fileActions.report(error)
        }
    }

    // MARK: - Rename

    /// Open the rename sheet for the selected folder or file, in the grid or
    /// the full view.
    @discardableResult
    func beginRename() -> Bool {
        // Not over the help: a second sheet can't open on top of it.
        guard slideshow == nil, !anySheetOpen,
              let entry = selectedEntry, entry.kind != .parent,
              // Archives are only read; a split one is renamed by renaming all its volumes, not here
              !ArchivePath.isInside(entry.url),
              !(entry.isArchive && ArchiveName.allFiles(of: entry.url).count > 1)
        else { return false }
        searchFocused = false   // F2 works while typing in the search field
        renameTarget = entry
        return true
    }

    /// Rename a folder or file in place. Updates the grid, the selection and
    /// every history entry that points to it (or, for a folder, into it).
    @discardableResult
    func rename(_ entry: GridEntry, to rawName: String) throws -> URL {
        Self.testLog("rename \(entry.name) → \(rawName)")
        let name = try Self.validName(rawName)
        let old = entry.url
        guard name != old.lastPathComponent else { renameTarget = nil; return old }
        let isFolder = entry.kind == .folder
        let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isFolder)
        if !isFolder, Self.mediaKind(of: new) != entry.kind {
            throw RenameError.changesKind(old.pathExtension, video: entry.kind == .video)
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
        notifyFolderChanges([old.deletingLastPathComponent()])
        return new
    }

    /// Bring every list the model holds in line with a change on disk, and
    /// keep the selection on the same item (or near it, if it's gone).
    /// A change this pane made on disk: its own lists, then the other panes.
    private func apply(_ change: FileChange) {
        applyHere(change)
        onFileChange?(change)
    }

    /// Told about every change this pane makes on disk (the window hands it
    /// to the other pane, `adopt`).
    var onFileChange: ((FileChange) -> Void)?

    /// A change another pane made on disk: lists and history follow it, and
    /// so does the folder shown when it was moved, renamed or trashed (then
    /// the nearest folder around it that is still there opens).
    func adopt(_ change: FileChange) {
        applyHere(change)
        guard let folderURL else { return }
        if let moved = change.apply(to: folderURL) {
            guard Self.canonicalPath(moved) != Self.canonicalPath(folderURL) else { return }
            self.folderURL = moved
            defaults.set(moved.path, forKey: lastFolderKey)
            refresh()
        } else {
            var parent = Self.parentFolder(of: folderURL)
            while let candidate = parent, change.apply(to: candidate) == nil { parent = Self.parentFolder(of: candidate) }
            if let parent { open(folder: parent) }
        }
    }

    private func applyHere(_ change: FileChange) {
        // What the folders around the change contain is no longer known.
        let affected = Set(change.affectedFolders)
        if !emptyFolders.isDisjoint(with: affected) { emptyFolders.subtract(affected) }
        FolderPreviewCache.shared.forget(change.affectedFolders)
        folderChanges += 1
        let keep = selectedEntry.flatMap { change.apply(to: $0.url) }
        let previous = selection
        if !marked.isEmpty {
            marked = Set(marked.compactMap { change.apply(to: URL(fileURLWithPath: $0)).map(Self.canonicalPath) })
        }
        allEntries = sorted(allEntries.compactMap { change.apply(to: $0) })
        for run in allSearches { run.apply(change) }
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
        // In a slideshow a video that played to its end hands over to the next item.
        if slideshow != nil, !isPlaying, (player.progress ?? 0) >= 0.99 {
            slideshowStep(+1)
        }
    }

    /// The photo or video on screen: the slideshow's, or the full view's.
    var shownMediaEntry: GridEntry? {
        if let slideshow { return slideshow.current }
        return mode == .detail ? selectedMediaEntry : nil
    }

    /// One ←/→ step in a video: a tenth of its length.
    static let videoJump = 0.1

    /// ←/→ in the full view. Images: previous/next item. Videos: jump a tenth
    /// of the length; past the end → next item, at the start → previous one.
    /// So one key pages through images and skims through videos.
    /// The key being handled repeats (held down).
    private var keyRepeating = false
    /// When the item on screen came up: a video's length is unknown at first.
    private var shownSince = Date()
    /// How long a video may take to report its length before ←/→ count it
    /// as unplayable and page on.
    var lengthGrace: TimeInterval = 1.5

    func skim(_ direction: Int) {
        guard shownMediaEntry?.kind == .video else { page(direction); return }
        guard let player = activePlayer, let progress = player.progress else {
            // Length not known yet: wait for it (a key held down would race
            // through video after video); only one that never gets a length
            // is left with ←/→, and not by a repeating key.
            if !keyRepeating, Date().timeIntervalSince(shownSince) > lengthGrace { page(direction) }
            return
        }
        if direction > 0 {
            let target = progress + Self.videoJump
            // At the end: on to the next item, but not with a key held down
            if target >= 0.999 { if !keyRepeating { page(+1) } } else { player.seek(toProgress: target) }
        } else {
            // Close to the start counts as the start, so a playing video
            // doesn't keep catching the key.
            if progress < Self.videoJump / 4 { if !keyRepeating { page(-1) } }
            else { player.seek(toProgress: max(progress - Self.videoJump, 0)) }
        }
    }

    /// ⇧←/⇧→ in a video: a fine step of a hundredth of its length (←/→
    /// jump a tenth), to find a place exactly. Stays in the video at its
    /// start and end (no paging).
    static let fineVideoJump = 0.01

    func fineSkim(_ direction: Int) {
        guard shownMediaEntry?.kind == .video, let player = activePlayer,
              let progress = player.progress else { return }
        let target = min(max(progress + Double(direction) * Self.fineVideoJump, 0), 1)
        player.seek(toProgress: direction > 0 ? min(target, 0.999) : target)
    }

    /// Previous / next item: in the slideshow, or in the full view.
    func page(_ direction: Int) {
        if slideshow != nil { slideshowStep(direction) } else { stepMedia(direction) }
    }

    // MARK: - Slideshow

    /// Start a slideshow. Over `folder` if given (a folder tile's context
    /// menu, the drop zone); otherwise over the search results while
    /// searching, else the current folder — always the whole of it (▶︎ means
    /// "this folder"). It starts at the item the full view shows, or at the
    /// file / in the folder the user selected in the grid (not the tile
    /// selected on opening a folder), and goes on from there, starting over
    /// at the end.
    func startSlideshow(over folder: URL? = nil, startingAt start: URL? = nil) {
        stopSlideshow()
        var roots: [GridEntry] = []
        if let folder {
            roots = [GridEntry(url: folder, kind: .folder)]
        } else if isFiltering {
            roots = entries.filter { $0.kind != .parent }
        } else if let folderURL {
            roots = [GridEntry(url: folderURL, kind: .folder)]
        }
        guard !roots.isEmpty else { NSSound.beep(); return }
        var show = Slideshow()
        show.startAt = start ?? (mode == .detail ? selectedMediaEntry?.url : nil)
        // From the grid (▶︎, S): at the file or in the folder the user selected
        if start == nil, folder == nil, mode == .grid, selectionChosen,
           let chosen = selectedEntry, chosen.kind != .parent {
            if chosen.isMedia { show.startAt = chosen.url }
            else if chosen.kind == .folder { show.startInside = Self.canonicalPath(chosen.url) + "/" }
        }
        if show.waitingForStart { show.index = -1 }   // shown once the start has arrived
        let id = show.id
        searchFocused = false
        slideshow = show
        slideshowEnteredFullScreen = setFullScreen(true)
        let key = sortKey, ascending = sortAscending
        slideshowWalk = Task { [weak self] in
            // Media among the roots (search results) go in together, folders
            // are walked where they stand.
            var media: [GridEntry] = []
            for root in roots {
                if root.isMedia { media.append(root); continue }
                if !media.isEmpty { self?.addToSlideshow(media, id: id); media = [] }
                await Self.walkForSlideshow(root.url, key: key, ascending: ascending) { batch in
                    self?.addToSlideshow(batch, id: id)
                }
                if Task.isCancelled { return }
            }
            if !media.isEmpty { self?.addToSlideshow(media, id: id) }
            if !Task.isCancelled { self?.slideshowWalkFinished(id: id) }
        }
    }

    /// Depth first: a folder's own media in the sort order, then each of its
    /// subfolders in the sort order. Hands over one batch per folder.
    nonisolated static func walkForSlideshow(_ folder: URL, key: SortKey, ascending: Bool,
                                             found: @MainActor ([GridEntry]) -> Void) async {
        guard !Task.isCancelled else { return }
        let contents = await scan(folder)
        var captured: [URL: Date] = [:]
        if key == .captured { captured = await captureDates(of: contents.filter(\.isMedia).map(\.url)) }
        guard !Task.isCancelled else { return }
        let sorted = sortEntries(contents, key: key, ascending: ascending, captured: captured)
        let media = sorted.filter(\.isMedia)
        if !media.isEmpty { await found(media) }
        for sub in sorted where sub.kind == .folder && !sub.name.hasPrefix(".") {
            await walkForSlideshow(sub.url, key: key, ascending: ascending, found: found)
        }
    }

    private func addToSlideshow(_ batch: [GridEntry], id: UUID) {
        guard var show = slideshow, show.id == id else { return }   // from a cancelled walk
        let new = batch.filter { show.seen.insert(Self.canonicalPath($0.url)).inserted }
        guard !new.isEmpty else { return }
        let wasEmpty = show.items.isEmpty
        let offset = show.items.count
        show.items += new
        var moved = wasEmpty && !show.waitingForStart
        if let startAt = show.startAt, let i = new.firstIndex(where: { Self.samePath($0.url, startAt) }) {
            show.index = offset + i   // the item to start at has arrived
            show.startAt = nil
            moved = true
        } else if let inside = show.startInside,
                  let i = new.firstIndex(where: { Self.canonicalPath($0.url).hasPrefix(inside) }) {
            show.index = offset + i   // the first item of the folder to start in
            show.startInside = nil
            moved = true
        } else if show.waitingForMore {
            show.index = offset
            moved = true
        }
        if moved { show.waitingForMore = false }
        slideshow = show
        if moved { showSlideshowItem() }
    }

    private func slideshowWalkFinished(id: UUID) {
        guard var show = slideshow, show.id == id else { return }
        show.loading = false
        // The item to start at never came (gone, or an empty folder): from the first
        let neverStarted = show.index < 0
        show.startAt = nil
        show.startInside = nil
        if neverStarted { show.index = 0 }
        let wrap = show.waitingForMore
        show.waitingForMore = false
        slideshow = show
        if show.items.isEmpty { stopSlideshow(); NSSound.beep() } else if wrap { slideshowStep(+1) }
        else if neverStarted { showSlideshowItem() }
    }

    /// Next / previous item; past the end it starts over (once the walk is done).
    func slideshowStep(_ delta: Int) {
        guard var show = slideshow, !show.items.isEmpty else { return }
        show.startAt = nil   // the user (or the show) has moved on
        show.startInside = nil
        var next = show.index + delta
        if next >= show.items.count {
            if show.loading {
                // Past the end while subfolders are still read: the next batch moves on
                show.waitingForMore = true
                slideshow = show
                return
            }
            next = 0
        }
        if next < 0 { next = show.loading ? 0 : show.items.count - 1 }
        // A show of one video: it stays on screen, so it plays again from the start
        let again = next == show.index && show.current?.kind == .video
        show.index = next
        show.waitingForMore = false
        slideshow = show
        showSlideshowItem()
        if again { activePlayer?.play() }
    }

    /// Show the current item: pictures move on after the interval, videos
    /// when they end (`playbackStateChanged`).
    private func showSlideshowItem() {
        slideshowTimer?.cancel()
        resetTransforms()
        guard let show = slideshow, let item = show.current else { return }
        if item.kind == .video {
            // A video moves on when it ends. One that can't be played (it never
            // gets a length) is skipped after a while instead of halting the show.
            let check = slideshowVideoCheck
            slideshowTimer = Task { [weak self] in
                var unknown = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: check)
                    guard !Task.isCancelled, let self, self.slideshow?.current == item else { return }
                    let player = self.activePlayer
                    let stuck = player?.progress == nil && player?.playsWithoutLength != true
                    unknown = stuck ? unknown + 1 : 0
                    if unknown >= 4 { self.slideshowStep(+1); return }
                }
            }
            return
        }
        guard !show.paused else { return }
        let interval = slideshowInterval
        slideshowTimer = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, self.slideshow != nil else { return }
            self.slideshowStep(+1)
        }
    }

    /// Space: pause or resume. Videos pause through their player.
    func toggleSlideshowPause() {
        guard var show = slideshow else { return }
        if show.current?.kind == .video { togglePlayPause(); return }
        show.paused.toggle()
        slideshow = show
        showSlideshowItem()
    }

    func stopSlideshow() {
        slideshowTimer?.cancel()
        slideshowWalk?.cancel()
        slideshowTimer = nil
        slideshowWalk = nil
        guard slideshow != nil else { return }
        slideshow = nil
        if slideshowEnteredFullScreen { _ = setFullScreen(false) }
        slideshowEnteredFullScreen = false
    }

    /// Keys while the slideshow runs.
    private func handleSlideshowKey(_ key: KeyInput, command: Bool, shift: Bool) -> Bool {
        switch key {
        case .escape, .backspace, .enter:
            stopSlideshow(); return true
        case .space:
            toggleSlideshowPause(); return true
        case .left, .right:
            let direction = key == .right ? 1 : -1
            if command { slideshowStep(direction) } else if shift { fineSkim(direction) } else { skim(direction) }
            return true
        case .up, .down:
            return verticalKey(up: key == .up)
        case .char(let raw):
            let c = Character(raw.lowercased())   // also with Shift or Caps Lock
            switch c {
            case "s" where !command: stopSlideshow(); return true
            case "f" where !command: toggleFullScreen(); return true
            case "i" where !command: showInspector.toggle(); return true
            case "e" where !command: enhance.toggle(); return true
            case "a" where !command: showAdjustments.toggle(); return true
            case "k" where !command: showMiniKeyboard.toggle(); return true
            // No search, history or file actions while the hidden grid's
            // selection isn't what's on screen
            case "f" where command, "[" where command, "]" where command, "a" where command: return true
            default: return handleCharacter(c, command: command)   // zoom, rotate
            }
        default:
            return false
        }
    }

    // MARK: - Window

    func toggleFullScreen() {
        guard let window = Self.appWindow else { return }
        _ = FullScreenSwitch.shared.set(!FullScreenSwitch.shared.isOrBecomesFullScreen(window), window: window)
    }
}

/// Full screen on request, also while the window is still on its way in or
/// out: AppKit ignores a toggle during that animation (an empty slideshow
/// ends at once), so the last request is carried out once it has ended.
@MainActor
final class FullScreenSwitch {
    static let shared = FullScreenSwitch()
    /// Where the window is going while it animates, since when.
    private var moving: (to: Bool, since: Date)?
    /// An animation that never reported its end (it failed) stops counting
    /// after this long.
    private var movingTo: Bool? {
        guard let moving, Date().timeIntervalSince(moving.since) < 3 else { return nil }
        return moving.to
    }
    private var wanted: Bool?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let starts: [(Notification.Name, Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)
        ]
        for (name, target) in starts {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    BrowserModel.testLog("full screen: will \(target ? "enter" : "exit")")
                    FullScreenSwitch.shared.moving = (target, Date())
                }
            })
        }
        let ends: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification
        ]
        for name in ends {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { FullScreenSwitch.shared.ended(window) }
            })
        }
    }

    func isOrBecomesFullScreen(_ window: NSWindow) -> Bool {
        wanted ?? movingTo ?? window.styleMask.contains(.fullScreen)
    }

    /// Returns whether the window ends up changed by this request.
    func set(_ on: Bool, window: NSWindow?) -> Bool {
        BrowserModel.testLog("full screen: set \(on), window \(window != nil), moving \(String(describing: movingTo)), is \(window?.styleMask.contains(.fullScreen) ?? false)")
        guard let window else { return false }
        if let movingTo {
            wanted = on
            return movingTo != on
        }
        guard window.styleMask.contains(.fullScreen) != on else { return false }
        // Moving from now on: AppKit announces the animation only later.
        moving = (on, Date())
        window.toggleFullScreen(nil)
        return true
    }

    private func ended(_ window: NSWindow?) {
        BrowserModel.testLog("full screen: ended, wanted \(String(describing: wanted)), is \(window?.styleMask.contains(.fullScreen) ?? false)")
        moving = nil
        guard let wanted, let window else { return }
        self.wanted = nil
        apply(wanted, to: window, tries: 4)
    }

    /// Right as the animation ends AppKit still ignores a toggle: asked a
    /// moment later, and again until the window is where it was asked to be.
    private func apply(_ on: Bool, to window: NSWindow, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                guard self.movingTo == nil, self.wanted == nil else { return }   // a newer request takes over
                guard window.styleMask.contains(.fullScreen) != on else { return }
                BrowserModel.testLog("full screen: toggling to \(on), \(tries) tries left")
                window.toggleFullScreen(nil)
                if tries > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated {
                            guard self.movingTo == nil, self.wanted == nil,
                                  window.styleMask.contains(.fullScreen) != on else { return }
                            self.apply(on, to: window, tries: tries - 1)
                        }
                    }
                }
            }
        }
    }
}

/// AVKit playback, driven by the keyboard. Reports state changes from any
/// source (keys, the player's controls, the end of the video) to the model.
@MainActor
final class AVPlaybackControl: PlaybackControl {
    let player: AVPlayer
    /// Feeds the player a video inside an archive (held here: the asset
    /// holds it weakly).
    var resourceLoader: ArchiveResourceLoader?
    private var observation: NSKeyValueObservation?

    init(player: AVPlayer, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void = { _, _ in }) {
        self.player = player
        observation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self else { return }
                // A look set after the last frame was drawn (just before the
                // end) reaches the picture it stops on
                if !playing, self.enhancer?.isStale == true { self.redrawIfPaused() }
                onStateChange(self, playing)
            }
        }
    }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    func setVolume(_ volume: Double) { player.volume = Float(volume) }

    var videoSize: CGSize? {
        let size = player.currentItem?.presentationSize ?? .zero
        return size.width > 0 && size.height > 0 ? size : nil
    }

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

    private var composition: AVVideoComposition?
    private var enhancer: VideoEnhancer?
    private var compositionTask: Task<Void, Never>?
    /// Where auto enhance's look goes (the model, for the sliders).
    var onAutoLook: @MainActor (PlaybackControl, Look) -> Void = { _, _ in }

    /// One video composition per video, made the first time a look is
    /// asked for; it reads the current look for every frame. Off, the
    /// composition is taken away so the video plays unfiltered.
    func setEnhancement(_ enhancement: Enhancement) {
        guard let item = player.currentItem else { return }
        BrowserModel.testLog("avkit enhancement \(enhancement), composition \(composition != nil), attached \(item.videoComposition != nil), playing \(isPlaying)")
        if enhancement == .off {
            compositionTask?.cancel()
            compositionTask = nil
            enhancer?.set(.off)
            item.videoComposition = nil
            redrawIfPaused()
            return
        }
        if let enhancer, let composition {
            enhancer.set(enhancement)
            if item.videoComposition == nil {
                // Put back after "off": a paused item takes it only a moment
                // later, so a redraw at once would still draw without it.
                item.videoComposition = composition
                redrawIfPaused(after: .milliseconds(100))
            } else {
                redrawIfPaused()
            }
            return
        }
        let enhancer = self.enhancer ?? VideoEnhancer(report: { [weak self] look in
            Task { @MainActor in
                guard let self else { return }
                self.onAutoLook(self, look)
            }
        })
        self.enhancer = enhancer
        enhancer.set(enhancement)
        guard compositionTask == nil else { return }
        let asset = item.asset
        compositionTask = Task { [weak self] in
            let made = try? await AVVideoComposition.videoComposition(with: asset) { request in
                enhancer.process(request)
            }
            guard let self, !Task.isCancelled else { return }
            self.compositionTask = nil   // also after a failure: the next change tries again
            guard let made else { return }
            self.composition = made
            item.videoComposition = made
            self.redrawIfPaused()   // a paused item doesn't draw its frame again by itself
        }
    }

    /// A paused video shows a new look only once its frame is drawn again.
    /// A seek to the very time it stands at reuses the picture already
    /// composed, so the seek goes 1/600 s off, the other way each time (the
    /// same video frame). Seeks in quick succession (a slider dragged), or a
    /// composition put back just now, can still leave the frame drawn with
    /// an earlier look: a stale frame is drawn again, a little later each time.
    private var nudgeBack = false
    private func redrawIfPaused(after delay: Duration = .zero, attempts: Int = 6) {
        guard !isPlaying else { return }
        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !self.isPlaying else { return }
            let now = self.player.currentTime()
            let step = CMTime(value: 1, timescale: 600)
            self.nudgeBack.toggle()
            var target = self.nudgeBack ? CMTimeSubtract(now, step) : CMTimeAdd(now, step)
            if CMTimeCompare(target, .zero) < 0 { target = CMTimeAdd(now, step) }
            if let duration = self.duration, target.seconds > duration { target = CMTimeSubtract(now, step) }
            BrowserModel.testLog("avkit redraw at \(target.seconds)")
            self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                BrowserModel.testLog("avkit redraw finished \(finished)")
                guard finished else { return }   // a newer seek takes over
                Task { @MainActor in
                    guard let self, attempts > 1, self.enhancer?.isStale == true else { return }
                    self.redrawIfPaused(after: .milliseconds(150), attempts: attempts - 1)
                }
            }
        }
    }

    var duration: Double? {
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
