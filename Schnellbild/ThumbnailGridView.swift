import SwiftUI
import UniformTypeIdentifiers

/// The grid. Lazy so only visible tiles are loaded. ".." and
/// folders first, then images/videos.
struct ThumbnailGridView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorSchemeContrast) private var contrast

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let side = model.thumbnailSide
            let available = geo.size.width - padding * 2
            let count = max(1, Int((available + spacing) / (side + spacing)))
            let columns = Array(repeating: GridItem(.fixed(side), spacing: spacing), count: count)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        // Identity is the file URL only: an index-based id makes the lazy
                        // grid keep showing stale cells when the list changes in place
                        // (search, sort, rename).
                        let filtering = model.isFiltering
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            cell(entry: entry, index: index, side: side, filtering: filtering)
                        }
                    }
                    .padding(padding)
                    // The files the grid doesn't show, by name: a folder with
                    // only these isn't empty
                    if !model.isFiltering, !model.otherFiles.isEmpty {
                        OtherFilesList(files: model.otherFiles)
                            .padding(.horizontal, padding)
                            .padding(.bottom, padding)
                    }
                }
                // Undo / Redo also where there is no tile (a tile's own menu has them on top)
                .contentShape(Rectangle())
                .contextMenu { UndoMenuItems(history: model.undoHistory, model: model) }
                // For the UI tests only (VoiceOver would read it): the columns the keys
                // step by, and as laid out
                .accessibilityIdentifier("grid")
                .accessibilityValue(VideoDetailView.uiTesting ? "\(model.columnCount) columns, \(count) laid out, selection \(model.selection.map(String.init) ?? "none")" : "")
                // Also when the grid first appears (a folder loaded, Back from a
                // subfolder): the selection may be far down, so show it at once.
                .onChange(of: model.selection, initial: true) { oldValue, newValue in
                    guard let newValue, model.entries.indices.contains(newValue) else { return }
                    if model.clickedSelection == newValue { model.clickedSelection = nil; return }
                    let id = model.entries[newValue].id
                    if oldValue == newValue {
                        proxy.scrollTo(id, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: count, initial: true) { _, newCount in
                model.columnCount = newCount
            }
        }
    }

    private func cell(entry: GridEntry, index: Int, side: CGFloat, filtering: Bool) -> some View {
        // The cursor has the ring; marked items (⌘ / ⇧ / Insert) a tint and a checkmark
        let cursor = model.selection == index
        let marked = model.isMarked(entry)
        let location = filtering ? model.relativeLocation(of: entry) : nil
        return VStack(spacing: 2) {
            tile(for: entry, side: side, cursor: cursor, marked: marked)
                .modifier(EntryAccessibility(entry: entry, selected: cursor || marked, location: location))
                .accessibilityIdentifier("tile.\(entry.name)")
            // VoiceOver reads the tile (name and kind); the UI tests find the names
            Text(entry.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side)
                .foregroundStyle(cursor || marked ? .primary : .secondary)
                .opacity(model.isEmptyFolder(entry) ? (contrast == .increased ? 0.8 : 0.5) : 1)
                .accessibilityHidden(!VideoDetailView.uiTesting)
            if let location {
                // Search results from subfolders: where they live.
                Text(location)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: side)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(!VideoDetailView.uiTesting)
            }
        }
        .contentShape(Rectangle())
        .modifier(EntryInteractions(entry: entry))
        .help(location.map { "\($0)/\(entry.name)" } ?? "")
    }

    @ViewBuilder
    func tile(for entry: GridEntry, side: CGFloat, cursor: Bool, marked: Bool) -> some View {
        switch entry.kind {
        case .parent:
            FolderTile(folder: nil, side: side, isSelected: cursor, isMarked: marked, systemImage: "arrow.up.circle.fill")
        case .folder:
            let archive = entry.isArchive
            if let drive = FolderTile.driveImage(entry.url) {
                FolderTile(folder: entry.url, side: side, isSelected: cursor, isMarked: marked, systemImage: drive,
                           kindLabel: "drive", previews: false)
            } else {
                FolderTile(folder: entry.browseURL, side: side, isSelected: cursor, isMarked: marked,
                           systemImage: archive ? "archivebox.fill" : "folder.fill",
                           isEmpty: model.isEmptyFolder(entry), kindLabel: archive ? "archive" : "folder")
            }
        case .image, .video:
            ThumbnailView(url: entry.url, side: side, isSelected: cursor, isMarked: marked, isVideo: entry.kind == .video,
                          modified: entry.modDate)
        }
    }
}

/// A tile or a list row as one element for VoiceOver: "name, kind" (and
/// where a search found it), selected or marked as the trait, Open as an
/// action.
struct EntryAccessibility: ViewModifier {
    let entry: GridEntry
    let selected: Bool
    var location: String? = nil
    @EnvironmentObject var model: BrowserModel

    /// "a.jpg, Picture", "album, Folder without pictures or videos".
    static func label(_ entry: GridEntry, emptyFolder: Bool, location: String?) -> String {
        let kind: String
        switch entry.kind {
        case .parent: return String(localized: "Enclosing Folder")
        case .folder:
            if FolderTile.driveImage(entry.url) != nil {
                kind = String(localized: "Drive")
            } else if entry.isArchive {
                kind = emptyFolder ? String(localized: "Archive without pictures or videos") : String(localized: "Archive")
            } else {
                kind = emptyFolder ? String(localized: "Folder without pictures or videos") : String(localized: "Folder")
            }
        case .image: kind = String(localized: "Picture")
        case .video: kind = String(localized: "Video")
        }
        return [entry.name, kind, location.map { String(localized: "in \($0)") }].compactMap { $0 }.joined(separator: ", ")
    }

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(Self.label(entry, emptyFolder: model.isEmptyFolder(entry), location: location))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction { model.click(entry, command: false, shift: false) }
            .accessibilityAction(named: Text("Open")) {
                model.searchFocused = false
                guard model.select(entry) else { return }
                model.activateSelection()
            }
    }
}

/// Tile for ".." or a subfolder. Subfolders show up to three thumbnails of
/// their first media files fanned over the folder icon, like Finder. The list
/// view's rows show it small.
struct FolderTile: View {
    /// nil for the ".." tile (no previews).
    let folder: URL?
    let side: CGFloat
    /// The cursor is on it (the ring).
    let isSelected: Bool
    /// Marked: tinted, with a checkmark.
    var isMarked = false
    var systemImage: String = "folder.fill"
    /// Nothing below it is a photo or video: drawn greyed out.
    var isEmpty = false
    /// What the UI tests' state calls it ("folder", "archive", "drive").
    var kindLabel = "folder"
    /// A drive on the drives' level: its icon, nothing read from it (a
    /// network share would be walked for a preview).
    var previews = true

    /// A drive's icon, for an item of the drives' level (`/Volumes`): the
    /// startup disk (its link to "/") or another; nil for anything else.
    static func driveImage(_ url: URL) -> String? {
        guard BrowserModel.isDrivesLevel(url.deletingLastPathComponent()) else { return nil }
        // By name, not by following the link: asked on every redraw, and a
        // network share that doesn't answer would hold the main thread
        return url.lastPathComponent == startupDiskName ? "internaldrive.fill" : "externaldrive.fill"
    }

    /// The startup disk's name as /Volumes lists it ("Macintosh HD"), read once.
    private static let startupDiskName: String? =
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName

    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var previewImages: [NSImage]

    init(folder: URL?, side: CGFloat, isSelected: Bool, isMarked: Bool = false, systemImage: String = "folder.fill",
         isEmpty: Bool = false, kindLabel: String = "folder", previews: Bool = true) {
        self.folder = folder
        self.side = side
        self.isSelected = isSelected
        self.isMarked = isMarked
        self.systemImage = systemImage
        self.isEmpty = isEmpty
        self.kindLabel = kindLabel
        self.previews = previews
        // Scrolled back into view: its previews at once from memory, not a
        // bare folder that fills in again
        let files = previews ? folder.flatMap(FolderPreviewCache.shared.knownFiles(in:)) ?? [] : []
        let images = files.compactMap { ThumbnailCache.previews.cached(for: $0, side: side * 0.4, modified: nil) }
        _previewImages = State(initialValue: images.count == files.count ? images : [])
    }

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .font(.system(size: side * (previewImages.isEmpty ? (small ? 0.6 : 0.36) : (small ? 0.75 : 0.5))))
                .foregroundStyle(Color.accentColor)
            if !previewImages.isEmpty { fan }
        }
        .saturation(isEmpty ? 0 : 1)
        .opacity(isEmpty ? (contrast == .increased ? 0.7 : 0.4) : 1)
        .tileChrome(side: side, isSelected: isSelected, isMarked: isMarked)
        .accessibilityElement(children: .ignore)
        // The label ("name, kind") comes from the grid's cell; the UI tests
        // read the tile's state here
        .accessibilityValue(VideoDetailView.uiTesting
            ? "\(TileChrome.selectionLabel(isSelected || isMarked)), \(folder == nil ? "parent folder" : isEmpty ? "empty \(kindLabel)" : kindLabel), \(previewImages.count) previews"
            : TileChrome.spokenState(marked: isMarked))
        // Again after a change made inside the folder (trash, rename): what
        // it previews may have gone.
        .task(id: FolderKey(folder: folder, changes: model.folderChanges)) { await loadPreviews() }
    }

    /// A list row's preview: the thumbnails take more of it, or they would
    /// be specks
    private var small: Bool { side < 60 }

    /// Thumbnails fanned out over the lower part of the folder body.
    private var fan: some View {
        let thumb = side * (small ? 0.5 : 0.34)
        let angles: [Double] = previewImages.count == 1 ? [0] : previewImages.count == 2 ? [-7, 7] : [-10, 0, 10]
        return ZStack {
            ForEach(Array(previewImages.enumerated()), id: \.offset) { i, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumb, height: thumb * 0.75)
                    .clipped()
                    .border(Color.white, width: small ? 1 : 2)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .rotationEffect(.degrees(angles[i]))
                    .offset(x: CGFloat(angles[i]) * side * 0.012)
            }
        }
        .offset(y: side * 0.06)
    }

    private func loadPreviews() async {
        // (what the tile shows stays until the new previews are there: no flicker)
        guard previews, let folder else { previewImages = []; return }
        let files = await FolderPreviewCache.shared.files(in: folder)
        let thumbSide = side * 0.4
        // Requested together: on a network volume one after another would
        // take three round-trips.
        let loaded = await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (i, file) in files.enumerated() {
                group.addTask {
                    // The date the listing read along (no extra trip): a
                    // picture replaced under the same name gets a new preview
                    let modified = ArchivePath.isInside(file) ? nil
                        : (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    return (i, await ThumbnailCache.previews.thumbnail(for: file, side: thumbSide, modified: modified))
                }
            }
            var byIndex: [Int: NSImage] = [:]
            for await (i, image) in group { byIndex[i] = image }
            return byIndex
        }
        guard !Task.isCancelled else { return }
        previewImages = files.indices.compactMap { loaded[$0] }
        if files.isEmpty {
            guard let found = await FolderPreviewCache.shared.containsMedia(folder), !Task.isCancelled else { return }
            model.noteFolder(folder, empty: !found)
        } else {
            model.noteFolder(folder, empty: false)
        }
    }
}

private struct FolderKey: Hashable {
    let folder: URL?
    let changes: Int
}

/// Which files each folder tile previews, remembered per folder: scrolling
/// recreates tiles, going back (out of a search, up a folder) shows the same
/// folders again, and listing them anew on a network share each time would
/// compete with the thumbnails. The same for whether a folder holds any
/// media at all (a walk of the whole tree when it doesn't).
/// Kept as long as the folder's modification date stays the same: checked
/// (one stat, off the main thread) when a tile asks and the last check is
/// older than `recheckAfter`. A folder's date changes with what it holds
/// directly, not with what changes deeper down; the app's own changes forget
/// the folders around them (`forget`).
@MainActor
final class FolderPreviewCache {
    static let shared = FolderPreviewCache()

    /// What is known of one folder, the folder's date it was found with
    /// (nil: not known yet, taken at the next check) and when that was checked.
    @MainActor
    final class Known<Value>: NSObject {
        let value: Value
        var stamp: Date?
        var checked: Date
        init(_ value: Value, stamp: Date?) {
            self.value = value
            self.stamp = stamp
            checked = Date()
        }
    }

    private let files = NSCache<NSString, Known<[URL]>>()
    private let hasMedia = NSCache<NSString, Known<Bool>>()
    let recheckAfter: TimeInterval

    init(recheckAfter: TimeInterval = 30) {
        self.recheckAfter = recheckAfter
        files.countLimit = 4096
        hasMedia.countLimit = 8192
    }

    private func key(_ folder: URL) -> NSString { BrowserModel.canonicalPath(folder) as NSString }

    /// Counts the forgets: a listing read before one isn't kept.
    private var generation = 0
    /// Listings under way, shared by the tiles that wait for them; one
    /// nobody waits for any more is stopped.
    private var running: [NSString: (task: Task<(files: [URL], stamp: Date?), Never>, waiters: Int)] = [:]

    /// The folder's modification date (inside an archive: none, the archive's
    /// index is kept by its own version).
    nonisolated static func stamp(of folder: URL) async -> Date? {
        guard !ArchivePath.isInside(folder) else { return .distantPast }
        // A URL keeps the values it read once: asked afresh
        let path = folder.path
        return await Blocking.run(.utility) {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// Whether what is known still holds: checked lately, or the folder's date unchanged.
    private func holds<Value>(_ known: Known<Value>, for folder: URL) async -> Bool {
        if Date().timeIntervalSince(known.checked) < recheckAfter { return true }
        let now = await Self.stamp(of: folder)
        guard let now else { return false }
        if known.stamp == nil { known.stamp = now }
        guard known.stamp == now else { return false }
        known.checked = Date()
        return true
    }

    /// The files known for the folder, without reading anything (a tile
    /// shows them at once; `files(in:)` checks them).
    func knownFiles(in folder: URL) -> [URL]? {
        files.object(forKey: key(folder))?.value
    }

    func files(in folder: URL) async -> [URL] {
        let key = key(folder)
        if let known = files.object(forKey: key) {
            if await holds(known, for: folder) { return known.value }
            if files.object(forKey: key) === known { files.removeObject(forKey: key) }
            hasMedia.removeObject(forKey: key)
        }
        let started = generation
        let task: Task<(files: [URL], stamp: Date?), Never>
        if let under = running[key] {
            task = under.task
            running[key]?.waiters += 1
        } else {
            // The date first: a change during the listing makes the next check list again
            task = Task.detached(priority: .utility) {
                let stamp = await Self.stamp(of: folder)
                return (await BrowserModel.folderPreviewFiles(in: folder), stamp)
            }
            running[key] = (task, 1)
        }
        let found = await withTaskCancellationHandler { await task.value } onCancel: { Task { @MainActor in self.leave(key, task) } }
        let current = generation == started
        if running[key]?.task == task, !task.isCancelled { running[key] = nil }
        if current, !task.isCancelled { files.setObject(Known(found.files, stamp: found.stamp), forKey: key) }
        return found.files
    }

    private func leave(_ key: NSString, _ task: Task<(files: [URL], stamp: Date?), Never>) {
        guard running[key]?.task == task else { return }
        running[key]?.waiters -= 1
        if running[key]?.waiters == 0 {
            task.cancel()
            running[key] = nil
        }
    }

    /// nil when cancelled before it knew.
    func containsMedia(_ folder: URL) async -> Bool? {
        let key = key(folder)
        if let known = hasMedia.object(forKey: key) {
            if await holds(known, for: folder) { return known.value }
            if hasMedia.object(forKey: key) === known { hasMedia.removeObject(forKey: key) }
        }
        let started = generation
        // The preview listing usually answers it already
        guard let found = await files(in: folder).isEmpty ? await BrowserModel.containsMedia(folder) : true else { return nil }
        if generation == started {
            hasMedia.setObject(Known(found, stamp: files.object(forKey: key)?.stamp), forKey: key)
        }
        return found
    }

    /// What a search's walk found out (it went through the folder anyway).
    func learn(_ folder: URL, hasMedia: Bool) {
        self.hasMedia.setObject(Known(hasMedia, stamp: nil), forKey: key(folder))
    }

    func learn(_ folder: URL, files: [URL]) {
        self.files.setObject(Known(files, stamp: nil), forKey: key(folder))
    }

    func forgetAll() {
        generation += 1
        running.removeAll()
        files.removeAllObjects()
        hasMedia.removeAllObjects()
    }

    /// Forget what is known about these folders (canonical paths).
    func forget(_ paths: [String]) {
        generation += 1
        for path in paths { running[path as NSString] = nil }
        for path in paths {
            files.removeObject(forKey: path as NSString)
            hasMedia.removeObject(forKey: path as NSString)
        }
    }
}

/// The files of a folder that aren't pictures, videos or archives, by name
/// and size, under the grid.
struct OtherFilesList: View {
    let files: [OtherFile]

    var body: some View {
        // Lazy: a camera folder can hold thousands of sidecar files
        LazyVStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 6)
            Text("Other files, not pictures or videos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(files) { file in
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(for: file))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    if let size = file.byteSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .modifier(OtherFileInteractions(file: file))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("other.\(file.name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("otherFiles")
    }

    /// The icon of the file's type (no file system access: also fast on a
    /// network share, also for a file inside an archive).
    static func icon(for file: OtherFile) -> NSImage {
        let type = UTType(filenameExtension: file.url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// What an other file's row does: the context menu (rename, reveal, trash)
/// and dragging onto a folder, the other pane or the Finder. Nothing inside
/// an archive changes.
struct OtherFileInteractions: ViewModifier {
    let file: OtherFile
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        let changeable = !ArchivePath.isInside(file.url)
        content
            .onDrag {
                let provider = NSItemProvider(object: file.url as NSURL)
                if changeable {
                    let paths = [file.url.path]
                    provider.registerDataRepresentation(forTypeIdentifier: TileDrag.type.identifier, visibility: .ownProcess) { done in
                        done(try? PropertyListEncoder().encode(paths), nil)
                        return nil
                    }
                }
                return provider
            }
            // Opened like a document in the Finder, but only documents (no apps, no scripts)
            .onTapGesture(count: 2) { model.open(file) }
            .contextMenu {
                UndoMenuItems(history: model.undoHistory, model: model)
                if changeable {
                    Button("Open") { model.open(file) }
                        .disabled(!LiveFiles.canOpenOtherFile(file.url))
                    Divider()
                    Button("Rename…") { model.beginRename(file) }
                }
                Button("Reveal in Finder") { model.reveal(file) }
                if changeable {
                    Button("Move to Trash…") { model.moveToTrash(file) }
                }
            }
    }
}

/// A tile as a drag source (its file, for folder tiles and the Finder) and,
/// for a folder tile or "..", a drop target: what is dropped moves into it
/// (copied when on another volume). Nothing inside archives takes part.
struct TileDrag: ViewModifier {
    let entry: GridEntry
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false

    /// Marks drags that start on a tile, so the window's drop zones
    /// (Browse / Slideshow) stay out of the way; carries every item dragged.
    static let type = UTType(exportedAs: "art.haushoppe.schnellbild.tile")

    /// The files of a tile drag (every marked item it carries). Only drags
    /// from the app's own tiles are taken this way: a drop from the Finder
    /// goes to the window's drop zones (browse / slideshow), never moves.
    static func loadURLs(_ providers: [NSItemProvider], then use: @escaping @MainActor ([URL]) -> Void) {
        guard let own = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return }
        own.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            let paths = data.flatMap { try? PropertyListDecoder().decode([String].self, from: $0) } ?? []
            let urls = paths.map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { use(urls) } }
        }
    }

    /// Inside an archive (not the archive itself, which drags like a file).
    private var inArchive: Bool { ArchivePath.isInside(entry.url) }
    /// ".." and what lies inside an archive don't drag (".." is the folder
    /// around the one shown; an archive's items have no file of their own).
    private var drags: Bool { entry.kind != .parent && !inArchive }
    private var acceptsDrops: Bool {
        (entry.kind == .folder || entry.kind == .parent) && !inArchive && !entry.isArchive
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .modifier(TileDragSource(entry: entry, drags: drags))
            .modifier(FolderDrop(entry: entry, accepts: acceptsDrops, targeted: $targeted))
    }
}

/// What a tile or a list row does: click (⌘ / ⇧ mark), double click (open),
/// drag (onto folders, the other pane, the Finder), the context menu.
struct EntryInteractions: ViewModifier {
    let entry: GridEntry
    @EnvironmentObject var model: BrowserModel
    @EnvironmentObject var window: WindowModel

    private var key: String { "\(ObjectIdentifier(model).hashValue)|\(entry.url.path)" }

    private func hover() {
        let entry = entry, model = model
        ModifierClicks.enter(key) { flags in
            // Not on the grid kept under the full view or a slideshow
            guard model.mode == .grid, model.slideshow == nil else { return }
            model.searchFocused = false
            model.click(entry, command: flags.contains(.command), shift: flags.contains(.shift))
        }
    }

    func body(content: Content) -> some View {
        content
            .modifier(TileDrag(entry: entry))
            .onTapGesture(count: 2) {
                model.searchFocused = false
                guard model.select(entry) else { return }
                model.activateSelection()
            }
            // At once, not after the double-click interval: a key pressed
            // right after the click must find it done
            .simultaneousGesture(TapGesture().onEnded {
                // ⌘- and ⇧-clicks are ModifierClicks'
                guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
                model.searchFocused = false
                model.click(entry, command: false, shift: false)
            })
            // SwiftUI's tap gestures don't fire while ⌘ is held: ⌘- and
            // ⇧-clicks go to the tile under the pointer at mouse-down
            .onHover { inside in
                if inside { hover() } else { ModifierClicks.leave(key) }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                let entry = entry, model = model
                ModifierClicks.place(key, frame: frame, in: window) { flags in
                    guard model.mode == .grid, model.slideshow == nil else { return }
                    model.searchFocused = false
                    model.click(entry, command: flags.contains(.command), shift: flags.contains(.shift))
                }
            }
            .onDisappear { ModifierClicks.remove(key) }
            .contextMenu {
                UndoMenuItems(history: model.undoHistory, model: model)
                if entry.kind != .parent {
                    if entry.kind == .folder {
                        Button("Start Slideshow of This Folder") {
                            model.select(entry)
                            model.startSlideshow(over: entry.browseURL)
                        }
                        Button(Bookmarks.shared.contains(entry.browseURL) ? "Remove Bookmark" : "Add Bookmark") {
                            Bookmarks.shared.toggle(entry.browseURL)
                        }
                        // The dual pane: this folder (or archive) in the other half
                        if window.dual, let other = window.panes.first(where: { $0 !== model }) {
                            Button("Open in Other Pane") { other.open(folder: entry.browseURL) }
                        }
                    }
                    // Inside an archive nothing is changed
                    if model.canRename(entry) {
                        Button("Rename…") {
                            guard model.select(entry) else { return }
                            model.beginRename()
                        }
                    }
                    Button("Reveal in Finder") {
                        guard model.select(entry) else { return }
                        model.revealInFinder()
                    }
                    if model.canChange(entry) {
                        Button("Move to Trash…") {
                            // The marked items when this is one of them, else this one
                            if !model.isMarked(entry) { model.clearMarks() }
                            guard model.select(entry) else { return }
                            model.moveSelectionToTrash()
                        }
                    }
                }
            }
    }
}

/// The drag of a tile: the file for the Finder, and for the app's own drop
/// targets every marked item along (when the dragged tile is marked).
private struct TileDragSource: ViewModifier {
    let entry: GridEntry
    let drags: Bool
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        if drags {
            content.onDrag {
                let paths = model.isMarked(entry) ? model.actionEntries.map(\.url.path) : [entry.url.path]
                let provider = NSItemProvider(object: entry.url as NSURL)
                provider.registerDataRepresentation(forTypeIdentifier: TileDrag.type.identifier, visibility: .ownProcess) { done in
                    done(try? PropertyListEncoder().encode(paths), nil)
                    return nil
                }
                return provider
            }
        } else {
            content
        }
    }
}

/// The drop target of a tile, for the app's own tile drags only. A folder
/// tile (or "..") takes what is dropped into it; any other tile passes it on
/// to the pane's folder (the dual pane: dragged across from the other pane),
/// but not while results are shown (their folder is not the one searched).
/// Every tile has one, so ⌘-clicks meet the same views on every tile.
private struct FolderDrop: ViewModifier {
    let entry: GridEntry
    let accepts: Bool
    @Binding var targeted: Bool
    @EnvironmentObject var model: BrowserModel
    @EnvironmentObject var window: WindowModel

    func body(content: Content) -> some View {
        content.onDrop(of: [TileDrag.type, .fileURL],
                       delegate: TileDropDelegate(entry: entry, accepts: accepts, targeted: $targeted, model: model, window: window))
    }
}

/// A folder tile outlines itself; any other tile outlines the pane (its
/// folder takes the drop). A drag from the Finder goes on to the window's
/// zones (`FinderDrop`).
private struct TileDropDelegate: DropDelegate {
    let entry: GridEntry
    let accepts: Bool
    @Binding var targeted: Bool
    let model: BrowserModel
    let window: WindowModel

    private func over(_ on: Bool) {
        if accepts {
            targeted = on
            if on { model.dropIntoFolderTargeted = false }
        } else {
            model.dropIntoFolderTargeted = on && model.paneDropFolder != nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        FinderDrop.isFromFinder(info) || info.hasItemsConforming(to: [TileDrag.type])
    }
    func dropEntered(info: DropInfo) {
        if FinderDrop.isFromFinder(info) { FinderDrop.update(window) } else { over(true) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if FinderDrop.isFromFinder(info) { FinderDrop.update(window); return DropProposal(operation: .copy) }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if FinderDrop.isFromFinder(info) { window.dropZone = nil } else { over(false) }
    }
    func performDrop(info: DropInfo) -> Bool {
        if FinderDrop.isFromFinder(info) { return FinderDrop.perform(info, window) }
        over(false)
        model.dropIntoFolderTargeted = false
        let target = accepts ? entry.browseURL : model.paneDropFolder
        guard let folder = target, ArchivePath.split(folder) == nil else { return false }
        TileDrag.loadURLs(info.itemProviders(for: [TileDrag.type])) { urls in model.move(urls, into: folder) }
        return true
    }
}

/// ⌘- and ⇧-clicks on tiles and rows. SwiftUI's tap gestures don't fire
/// while ⌘ is held, so a monitor acts on the tile the pointer is over (tiles
/// report it by hovering). It acts when the button comes up near where it
/// went down: a ⌘- or ⇧-drag of marked tiles still drags.
@MainActor
enum ModifierClicks {
    private static var hovered: (key: String, action: (NSEvent.ModifierFlags) -> Void)?
    private static var pending: (action: (NSEvent.ModifierFlags) -> Void, flags: NSEvent.ModifierFlags, at: NSPoint)?
    private static var monitor: Any?
    /// Where each tile or row on screen is (in the window's content, top
    /// left origin): the click goes to the one under the pointer even when
    /// the grid moved under a still pointer (a re-sort, a search batch, a
    /// scroll to the selection), which sends no hover.
    private static var frames: [String: (frame: CGRect, window: ObjectIdentifier, action: (NSEvent.ModifierFlags) -> Void)] = [:]

    static func enter(_ key: String, action: @escaping (NSEvent.ModifierFlags) -> Void) {
        hovered = (key, action)
    }
    static func leave(_ key: String) {
        if hovered?.key == key { hovered = nil }
    }
    static func place(_ key: String, frame: CGRect, in window: WindowModel, action: @escaping (NSEvent.ModifierFlags) -> Void) {
        frames[key] = (frame, ObjectIdentifier(window), action)
    }
    static func remove(_ key: String) {
        frames[key] = nil
        leave(key)
    }

    /// The tile under a point of a browser window, by the frames its tiles reported.
    private static func tile(at event: NSEvent) -> ((NSEvent.ModifierFlags) -> Void)? {
        guard let content = event.window?.contentView, let window = WindowModel.of(event.window) else { return nil }
        let local = content.convert(event.locationInWindow, from: nil)
        let point = content.isFlipped ? local : NSPoint(x: local.x, y: content.bounds.height - local.y)
        return frames.values.first { $0.window == ObjectIdentifier(window) && $0.frame.contains(point) }?.action
    }

    /// The grid moved under a still pointer (a key scrolled it): which tile
    /// is under it is known again once the pointer moves.
    static func forgetHover() { hovered = nil }

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel]) { event in
            MainActor.assumeIsolated { handle(event) }
            return event
        }
    }

    private static func handle(_ event: NSEvent) {
        // Scrolled: the tile under the pointer is another one, known again
        // once the pointer moves
        if event.type == .scrollWheel { hovered = nil; return }
        if event.type == .leftMouseDown {
            pending = nil
            let flags = event.modifierFlags.intersection([.command, .shift])
            guard !flags.isEmpty, WindowModel.of(event.window) != nil,
                  let action = tile(at: event) ?? hovered?.action else { return }
            pending = (action, flags, event.locationInWindow)
            return
        }
        guard let click = pending else { return }
        pending = nil
        let moved = hypot(event.locationInWindow.x - click.at.x, event.locationInWindow.y - click.at.y)
        if moved < 4 { click.action(click.flags) }
    }
}
