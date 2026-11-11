import SwiftUI
import UniformTypeIdentifiers

/// The grid. Lazy so only visible tiles are loaded. ".." and
/// folders first, then images/videos.
struct ThumbnailGridView: View {
    @EnvironmentObject var model: BrowserModel

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
        // The selection, and every marked item (⌘ / ⇧ / Insert), carry the ring
        let selected = model.selection == index || model.isMarked(entry)
        let location = filtering ? model.relativeLocation(of: entry) : nil
        return VStack(spacing: 2) {
            tile(for: entry, side: side, selected: selected)
                .accessibilityIdentifier("tile.\(entry.name)")
            Text(entry.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side)
                .foregroundStyle(selected ? .primary : .secondary)
                .opacity(model.isEmptyFolder(entry) ? 0.5 : 1)
            if let location {
                // Search results from subfolders: where they live.
                Text(location)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: side)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .modifier(EntryInteractions(entry: entry))
        .help(location.map { "\($0)/\(entry.name)" } ?? "")
    }

    @ViewBuilder
    func tile(for entry: GridEntry, side: CGFloat, selected: Bool) -> some View {
        switch entry.kind {
        case .parent:
            FolderTile(folder: nil, side: side, isSelected: selected, systemImage: "arrow.up.circle.fill")
        case .folder:
            let archive = entry.isArchive
            FolderTile(folder: entry.url, side: side, isSelected: selected,
                       systemImage: archive ? "archivebox.fill" : "folder.fill",
                       isEmpty: model.isEmptyFolder(entry), kindLabel: archive ? "archive" : "folder")
        case .image, .video:
            ThumbnailView(url: entry.url, side: side, isSelected: selected, isVideo: entry.kind == .video,
                          modified: entry.modDate)
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
    let isSelected: Bool
    var systemImage: String = "folder.fill"
    /// Nothing below it is a photo or video: drawn greyed out.
    var isEmpty = false
    /// What the accessibility label calls it ("folder", "archive").
    var kindLabel = "folder"

    @EnvironmentObject var model: BrowserModel
    @State private var previews: [NSImage] = []

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .font(.system(size: side * (previews.isEmpty ? (small ? 0.6 : 0.36) : (small ? 0.75 : 0.5))))
                .foregroundStyle(Color.accentColor)
            if !previews.isEmpty { fan }
        }
        .saturation(isEmpty ? 0 : 1)
        .opacity(isEmpty ? 0.4 : 1)
        .tileChrome(side: side, isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TileChrome.selectionLabel(isSelected)), \(folder == nil ? "parent folder" : isEmpty ? "empty \(kindLabel)" : kindLabel), \(previews.count) previews")
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
        let angles: [Double] = previews.count == 1 ? [0] : previews.count == 2 ? [-7, 7] : [-10, 0, 10]
        return ZStack {
            ForEach(Array(previews.enumerated()), id: \.offset) { i, image in
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
        previews = []
        guard let folder else { return }
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
        previews = files.indices.compactMap { loaded[$0] }
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
/// recreates tiles, and listing a large folder on a network share again for
/// every appearance would compete with the thumbnails.
/// The same for whether a folder holds any media at all (a walk of the whole
/// tree when it doesn't).
@MainActor
final class FolderPreviewCache {
    static let shared = FolderPreviewCache()
    private let files = NSCache<NSString, NSArray>()
    private let hasMedia = NSCache<NSString, NSNumber>()

    init() {
        files.countLimit = 1024
        hasMedia.countLimit = 4096
    }

    private func key(_ folder: URL) -> NSString { BrowserModel.canonicalPath(folder) as NSString }

    /// Counts the forgets: a listing read before one isn't kept.
    private var generation = 0
    /// Listings under way, shared by the tiles that wait for them; one
    /// nobody waits for any more is stopped.
    private var running: [NSString: (task: Task<[URL], Never>, waiters: Int)] = [:]

    func files(in folder: URL) async -> [URL] {
        let key = key(folder)
        if let cached = files.object(forKey: key) as? [URL] { return cached }
        let started = generation
        let task: Task<[URL], Never>
        if let under = running[key] {
            task = under.task
            running[key]?.waiters += 1
        } else {
            task = Task.detached(priority: .utility) { await BrowserModel.folderPreviewFiles(in: folder) }
            running[key] = (task, 1)
        }
        let found = await withTaskCancellationHandler { await task.value } onCancel: { Task { @MainActor in self.leave(key, task) } }
        let current = generation == started
        if running[key]?.task == task, !task.isCancelled { running[key] = nil }
        if current, !task.isCancelled { files.setObject(found as NSArray, forKey: key) }
        return found
    }

    private func leave(_ key: NSString, _ task: Task<[URL], Never>) {
        guard running[key]?.task == task else { return }
        running[key]?.waiters -= 1
        if running[key]?.waiters == 0 {
            task.cancel()
            running[key] = nil
        }
    }

    /// nil when cancelled before it knew.
    func containsMedia(_ folder: URL) async -> Bool? {
        if let cached = hasMedia.object(forKey: key(folder)) { return cached.boolValue }
        let started = generation
        // The preview listing usually answers it already
        guard let found = await files(in: folder).isEmpty ? await BrowserModel.containsMedia(folder) : true else { return nil }
        let current = generation == started
        if current { hasMedia.setObject(NSNumber(value: found), forKey: key(folder)) }
        return found
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
                ModifierClicks.place(key, frame: frame) { flags in
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
                            model.startSlideshow(over: entry.url)
                        }
                        Button(Bookmarks.shared.contains(entry.url) ? "Remove Bookmark" : "Add Bookmark") {
                            Bookmarks.shared.toggle(entry.url)
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
                    if !ArchivePath.isInside(entry.url) {
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
        let target = accepts ? entry.url : model.paneDropFolder
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
    private static var frames: [String: (frame: CGRect, action: (NSEvent.ModifierFlags) -> Void)] = [:]

    static func enter(_ key: String, action: @escaping (NSEvent.ModifierFlags) -> Void) {
        hovered = (key, action)
    }
    static func leave(_ key: String) {
        if hovered?.key == key { hovered = nil }
    }
    static func place(_ key: String, frame: CGRect, action: @escaping (NSEvent.ModifierFlags) -> Void) {
        frames[key] = (frame, action)
    }
    static func remove(_ key: String) {
        frames[key] = nil
        leave(key)
    }

    /// The tile under a point of the main window, by the frames reported.
    private static func tile(at event: NSEvent) -> ((NSEvent.ModifierFlags) -> Void)? {
        guard let content = event.window?.contentView else { return nil }
        let local = content.convert(event.locationInWindow, from: nil)
        let point = content.isFlipped ? local : NSPoint(x: local.x, y: content.bounds.height - local.y)
        return frames.values.first { $0.frame.contains(point) }?.action
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
            guard !flags.isEmpty, event.window === BrowserModel.appWindow,
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
