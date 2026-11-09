import SwiftUI

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
        let selected = model.selection == index
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
        .onTapGesture(count: 2) {
            model.searchFocused = false
            guard model.select(entry) else { return }
            model.activateSelection()
        }
        .onTapGesture(count: 1) {
            model.searchFocused = false
            model.select(entry)
        }
        .contextMenu {
            if entry.kind != .parent {
                if entry.kind == .folder {
                    Button("Play Slideshow") {
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
        .help(location.map { "\($0)/\(entry.name)" } ?? "")
    }

    @ViewBuilder
    private func tile(for entry: GridEntry, side: CGFloat, selected: Bool) -> some View {
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
