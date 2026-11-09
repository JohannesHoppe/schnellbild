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
                // For the UI tests only (VoiceOver would read it): the columns the keys
                // step by, and as laid out
                .accessibilityIdentifier("grid")
                .accessibilityValue(VideoDetailView.uiTesting ? "\(model.columnCount) columns, \(count) laid out, selection \(model.selection.map(String.init) ?? "none")" : "")
                // Also when the grid first appears (a folder loaded, Back from a
                // subfolder): the selection may be far down, so show it at once.
                .onChange(of: model.selection, initial: true) { oldValue, newValue in
                    guard let newValue, model.entries.indices.contains(newValue) else { return }
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
            let archive = ArchiveName.format(of: entry.name) != nil && !ArchivePath.isInside(entry.url)
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
/// their first media files fanned over the folder icon, like Finder.
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
                .font(.system(size: side * (previews.isEmpty ? 0.36 : 0.5)))
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

    /// Thumbnails fanned out over the lower part of the folder body.
    private var fan: some View {
        let thumb = side * 0.34
        let angles: [Double] = previews.count == 1 ? [0] : previews.count == 2 ? [-7, 7] : [-10, 0, 10]
        return ZStack {
            ForEach(Array(previews.enumerated()), id: \.offset) { i, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumb, height: thumb * 0.75)
                    .clipped()
                    .border(Color.white, width: 2)
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
                group.addTask { @MainActor in (i, await ThumbnailCache.previews.thumbnail(for: file, side: thumbSide)) }
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

    func files(in folder: URL) async -> [URL] {
        if let cached = files.object(forKey: key(folder)) as? [URL] { return cached }
        let found = await BrowserModel.folderPreviewFiles(in: folder)
        files.setObject(found as NSArray, forKey: key(folder))
        return found
    }

    /// nil when cancelled before it knew.
    func containsMedia(_ folder: URL) async -> Bool? {
        if let cached = hasMedia.object(forKey: key(folder)) { return cached.boolValue }
        // The preview listing usually answers it already
        guard let found = await files(in: folder).isEmpty ? await BrowserModel.containsMedia(folder) : true else { return nil }
        hasMedia.setObject(NSNumber(value: found), forKey: key(folder))
        return found
    }

    func forgetAll() {
        files.removeAllObjects()
        hasMedia.removeAllObjects()
    }

    /// Forget what is known about these folders (canonical paths).
    func forget(_ paths: [String]) {
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
        VStack(alignment: .leading, spacing: 4) {
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

    /// The files of a drop: all of a tile drag (several marked items),
    /// else the file URLs (from the Finder).
    static func loadURLs(_ providers: [NSItemProvider], then use: @escaping @MainActor ([URL]) -> Void) {
        if let own = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) {
            own.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let urls = data.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) } } ?? []
                DispatchQueue.main.async { MainActor.assumeIsolated { use(urls) } }
            }
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { use(urls) } }
    }

    private var inArchive: Bool { ArchivePath.split(entry.url) != nil }
    private var acceptsDrops: Bool {
        (entry.kind == .folder || entry.kind == .parent) && !inArchive && ArchiveName.format(of: entry.name) == nil
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .onDrag {
                // A marked tile takes all the marked ones along (the Finder
                // gets the one dragged)
                let paths = model.isMarked(entry) ? model.actionEntries.map(\.url.path) : [entry.url.path]
                let provider = NSItemProvider(object: entry.url as NSURL)
                provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { done in
                    done(Data(paths.joined(separator: "\n").utf8), nil)
                    return nil
                }
                return provider
            }
            .modifier(FolderDrop(entry: entry, accepts: acceptsDrops, targeted: $targeted))
    }
}

/// What a tile or a list row does: click (⌘ / ⇧ mark), double click (open),
/// drag (onto folders, the other pane, the Finder), the context menu.
struct EntryInteractions: ViewModifier {
    let entry: GridEntry
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        content
            .modifier(TileDrag(entry: entry))
            .onTapGesture(count: 2) {
                model.searchFocused = false
                guard model.select(entry) else { return }
                model.activateSelection()
            }
            .onTapGesture(count: 1) {
                model.searchFocused = false
                model.click(entry, command: false, shift: false)
            }
            // SwiftUI's tap gestures don't fire while ⌘ is held: ⌘- and
            // ⇧-clicks go to a view of their own
            .overlay(ModifierClickCatcher { flags in
                model.searchFocused = false
                model.click(entry, command: flags.contains(.command), shift: flags.contains(.shift))
            })
            .contextMenu {
                if entry.kind != .parent {
                    if entry.kind == .folder {
                        Button("Start Slideshow of This Folder") {
                            model.select(entry)
                            model.startSlideshow(over: entry.url)
                        }
                    }
                    // Inside an archive nothing is changed
                    if !ArchivePath.isInside(entry.url) {
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
                            guard model.select(entry) else { return }
                            model.moveSelectionToTrash()
                        }
                    }
                }
            }
    }
}

/// The drop target of a tile. A folder tile (or "..") takes what is dropped
/// into it; any other tile passes it on to the pane's folder (the dual pane:
/// dragged across from the other pane). Every tile has one: tiles with and
/// without a drop target side by side kept ⌘-clicks from arriving.
private struct FolderDrop: ViewModifier {
    let entry: GridEntry
    let accepts: Bool
    @Binding var targeted: Bool
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL], isTargeted: accepts ? $targeted : .constant(false)) { providers in
            let target = accepts ? entry.url : model.folderURL
            guard let folder = target, ArchivePath.split(folder) == nil,
                  !model.isFiltering || entry.kind == .folder || !accepts else { return false }
            TileDrag.loadURLs(providers) { urls in model.move(urls, into: folder) }
            return true
        }
    }
}

/// Takes the clicks made with ⌘ or ⇧ held and lets every other click
/// (plain, right, drag) through to the views below.
private struct ModifierClickCatcher: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags) -> Void

    final class CatcherView: NSView {
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
                  !event.modifierFlags.intersection([.command, .shift]).isEmpty else { return nil }
            return super.hitTest(point)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            onClick?(event.modifierFlags)
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }
    func updateNSView(_ view: CatcherView, context: Context) { view.onClick = onClick }
}
