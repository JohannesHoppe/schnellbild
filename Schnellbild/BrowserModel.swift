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

/// Single source of truth for all browsing.
@MainActor
final class BrowserModel: ObservableObject {
    enum Mode { case grid, detail }
    enum SortKey { case name, date, size }
    enum SearchScope: Hashable { case folder, subfolders }
    enum KeyInput: Equatable {
        case left, right, up, down, space, enter, escape, backspace, home, end
        case char(Character)
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

    // Search
    @Published var searchText: String = ""
    @Published var searchScope: SearchScope = .folder
    @Published var searchActive = false
    @Published private(set) var isSearching = false
    /// The full, unfiltered set of the current folder. `entries` is the
    /// currently visible (possibly search-filtered) view of it.
    private var allEntries: [GridEntry] = []
    private var searchTask: Task<Void, Never>?

    @Published private(set) var slideshowOn = false
    private var slideshowTask: Task<Void, Never>?

    /// Weak reference to the running video player — for keyboard
    /// control (pause/seek). Set by VideoDetailView.
    weak var activePlayer: AVPlayer?

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

    func open(folder url: URL, selecting target: URL? = nil, thenDetail: Bool = false) {
        folderURL = url
        entries = []
        allEntries = []
        selection = nil
        mode = .grid
        searchText = ""
        searchTask?.cancel()
        isSearching = false
        resetTransforms()
        stopSlideshow()
        isLoading = true
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
        Task {
            var full = await Self.scan(url)
            let parent = url.deletingLastPathComponent()
            if parent != url {
                full.insert(GridEntry(url: parent, kind: .parent), at: 0)
            }
            let sorted = Self.sortEntries(full, key: self.sortKey, ascending: self.sortAscending)
            self.allEntries = sorted
            self.entries = sorted
            if let target,
               let idx = sorted.firstIndex(where: {
                   $0.kind != .parent &&
                   $0.url.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path
               }) {
                self.selection = idx
                if thenDetail, sorted[idx].isMedia {
                    self.resetTransforms()
                    self.mode = .detail
                }
            } else {
                self.selection = sorted.firstIndex(where: { $0.kind != .parent }) ?? (sorted.isEmpty ? nil : 0)
            }
            self.isLoading = false
        }
    }

    /// Reopen the last folder on launch (if it still exists).
    func restoreLastFolder() {
        guard folderURL == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastFolderKey) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            open(folder: URL(fileURLWithPath: path))
        }
    }

    /// CLI / UI-test seam: `--open <path>` opens a folder (grid) or a file
    /// (straight into the full-size view) on launch — same rules as drag & drop.
    @discardableResult
    func openFromLaunchArguments() -> Bool {
        let args = ProcessInfo.processInfo.arguments
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
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            )) ?? []

            var result: [GridEntry] = []
            for item in contents {
                let vals = try? item.resourceValues(forKeys: keys)
                let isDir = vals?.isDirectory ?? false
                let date = vals?.contentModificationDate
                if isDir {
                    result.append(GridEntry(url: item, kind: .folder, modDate: date, byteSize: nil))
                    continue
                }
                let ext = item.pathExtension.lowercased()
                if imageExtensions.contains(ext) {
                    result.append(GridEntry(url: item, kind: .image, modDate: date, byteSize: vals?.fileSize))
                } else if videoExtensions.contains(ext) {
                    result.append(GridEntry(url: item, kind: .video, modDate: date, byteSize: vals?.fileSize))
                }
            }
            return result
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

    // MARK: - Search

    /// Recompute the visible `entries` from the query and scope. Called by the
    /// view whenever the search text or scope changes.
    func applyFilter() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            isSearching = false
            entries = allEntries
            selection = allEntries.firstIndex { $0.kind != .parent } ?? (allEntries.isEmpty ? nil : 0)
            return
        }
        mode = .grid
        let matches = allEntries.filter {
            $0.kind != .parent && $0.name.localizedCaseInsensitiveContains(query)
        }
        entries = Self.sortEntries(matches, key: sortKey, ascending: sortAscending)
        selection = entries.isEmpty ? nil : 0

        guard searchScope == .subfolders, let root = folderURL else {
            isSearching = false
            return
        }
        isSearching = true
        let key = sortKey, ascending = sortAscending
        searchTask = Task { [weak self] in
            let deep = await Self.recursiveMatches(under: root, query: query)
            guard let self, !Task.isCancelled else { return }
            var seen = Set(matches.map { $0.url.resolvingSymlinksInPath().path })
            var merged = matches
            for entry in deep where seen.insert(entry.url.resolvingSymlinksInPath().path).inserted {
                merged.append(entry)
            }
            self.entries = Self.sortEntries(merged, key: key, ascending: ascending)
            self.selection = self.entries.isEmpty ? nil : 0
            self.isSearching = false
        }
    }

    /// Deep filename match under `root`. Skips hidden files and package
    /// contents; checks `Task.isCancelled` so a new keystroke abandons it.
    nonisolated static func recursiveMatches(under root: URL, query: String) async -> [GridEntry] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [GridEntry] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return result }
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
            let vals = try? url.resourceValues(forKeys: keys)
            if vals?.isDirectory == true {
                result.append(GridEntry(url: url, kind: .folder, modDate: vals?.contentModificationDate))
            } else {
                let ext = url.pathExtension.lowercased()
                if imageExtensions.contains(ext) {
                    result.append(GridEntry(url: url, kind: .image,
                                            modDate: vals?.contentModificationDate, byteSize: vals?.fileSize))
                } else if videoExtensions.contains(ext) {
                    result.append(GridEntry(url: url, kind: .video,
                                            modDate: vals?.contentModificationDate, byteSize: vals?.fileSize))
                }
            }
        }
        return result
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

    /// "Go back": leave the full-size view, or go up one folder level in the grid.
    func goBack() { mode == .detail ? closeDetail() : goToParentFolder() }

    func goToParentFolder() {
        guard let current = folderURL else { return }
        let parent = current.deletingLastPathComponent()
        guard parent != current else { return }
        open(folder: parent, selecting: current)
    }

    // MARK: - Keyboard dispatch

    /// Single source of truth for key bindings. Returns true if the key was
    /// handled (and should be consumed). Pure enough to unit-test exhaustively.
    @discardableResult
    func handleKey(_ key: KeyInput, command: Bool) -> Bool {
        switch key {
        case .backspace:
            goBack(); return true
        case .escape:
            guard mode == .detail else { return false }
            closeDetail(); return true
        case .enter:
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
            if command { mode = .grid; searchActive = true } else { toggleFullScreen() }
            return true
        default:
            break
        }
        guard mode == .detail else { return false }
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
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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
        guard let url = selectedEntry?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInDefaultApp() {
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        NSWorkspace.shared.open(entry.url)
    }

    func moveSelectionToTrash() {
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(entry.name)” to the Trash?"
        alert.informativeText = "The file will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
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
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Video control

    func togglePlayPause() {
        guard let p = activePlayer else { return }
        if p.rate != 0 { p.pause() } else { p.play() }
    }

    func seekVideo(by seconds: Double) {
        guard let p = activePlayer, let item = p.currentItem else { return }
        let now = CMTimeGetSeconds(p.currentTime())
        var target = max(0, now + seconds)
        let duration = CMTimeGetSeconds(item.duration)
        if duration.isFinite, duration > 0 { target = min(target, duration) }
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Window

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}
