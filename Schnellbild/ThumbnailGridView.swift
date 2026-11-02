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
                        ForEach(Array(model.entries.enumerated()), id: \.element) { index, entry in
                            cell(entry: entry, index: index, side: side)
                        }
                    }
                    .padding(padding)
                }
                .onChange(of: model.selection) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onChange(of: count, initial: true) { _, newCount in
                model.columnCount = newCount
            }
        }
    }

    private func cell(entry: GridEntry, index: Int, side: CGFloat) -> some View {
        let selected = model.selection == index
        let location = model.searchText.isEmpty ? nil : model.relativeLocation(of: entry)
        return VStack(spacing: 2) {
            tile(for: entry, side: side, selected: selected)
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
        .id(index)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tile.\(entry.name)")
        .accessibilityValue(selected ? "selected" : "")
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
        .accessibilityLabel(folder == nil ? "Parent folder" : "Folder")
        .accessibilityValue("\(previews.count) previews")
        .accessibilityIdentifier("folderTile")
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
        let files = await BrowserModel.folderPreviewFiles(in: folder)
        var images: [NSImage] = []
        for file in files {
            if Task.isCancelled { return }
            if let image = await ThumbnailCache.shared.thumbnail(for: file, side: side * 0.4) {
                images.append(image)
            }
        }
        if !Task.isCancelled { previews = images }
    }
}
