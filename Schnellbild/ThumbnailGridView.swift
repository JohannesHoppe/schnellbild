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
            model.select(index)
            model.activateSelection()
        }
        .onTapGesture(count: 1) {
            model.searchFocused = false
            model.select(index)
        }
        .contextMenu {
            if entry.kind != .parent {
                if entry.kind == .folder {
                    Button("Rename Folder…") {
                        model.select(index)
                        model.beginRename()
                    }
                }
                Button("Reveal in Finder") {
                    model.select(index)
                    model.revealInFinder()
                }
                Button("Move to Trash…") {
                    model.select(index)
                    model.moveSelectionToTrash()
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
            FolderTile(folder: entry.url, side: side, isSelected: selected)
        case .image, .video:
            ThumbnailView(url: entry.url, side: side, isSelected: selected, isVideo: entry.kind == .video)
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

    @State private var previews: [NSImage] = []

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .font(.system(size: side * (previews.isEmpty ? 0.36 : 0.5)))
                .foregroundStyle(Color.accentColor)
            if !previews.isEmpty { fan }
        }
        .tileChrome(side: side, isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TileChrome.selectionLabel(isSelected)), \(folder == nil ? "parent folder" : "folder"), \(previews.count) previews")
        .task(id: folder) { await loadPreviews() }
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
        if !Task.isCancelled { previews = files.indices.compactMap { loaded[$0] } }
    }
}

/// Which files each folder tile previews, remembered per folder: scrolling
/// recreates tiles, and listing a large folder on a network share again for
/// every appearance would compete with the thumbnails.
@MainActor
final class FolderPreviewCache {
    static let shared = FolderPreviewCache()
    private let cache = NSCache<NSURL, NSArray>()

    init() { cache.countLimit = 1024 }

    func files(in folder: URL) async -> [URL] {
        if let cached = cache.object(forKey: folder as NSURL) as? [URL] { return cached }
        let files = await BrowserModel.folderPreviewFiles(in: folder)
        cache.setObject(files as NSArray, forKey: folder as NSURL)
        return files
    }
}
