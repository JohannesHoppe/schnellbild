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
                            VStack(spacing: 4) {
                                tile(for: entry, side: side, selected: model.selection == index)
                                Text(entry.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: side)
                                    .foregroundStyle(model.selection == index ? .primary : .secondary)
                            }
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                model.select(index)
                                model.activateSelection()
                            }
                            .onTapGesture(count: 1) {
                                model.select(index)
                            }
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

    @ViewBuilder
    private func tile(for entry: GridEntry, side: CGFloat, selected: Bool) -> some View {
        switch entry.kind {
        case .parent:
            FolderTile(side: side, isSelected: selected, systemImage: "arrow.up.circle.fill")
        case .folder:
            FolderTile(side: side, isSelected: selected)
        case .image:
            ThumbnailView(url: entry.url, side: side, isSelected: selected)
        case .video:
            ThumbnailView(url: entry.url, side: side, isSelected: selected)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 26))
                        .padding(6)
                }
        }
    }
}

/// Tile for ".." or a subfolder.
struct FolderTile: View {
    let side: CGFloat
    let isSelected: Bool
    var systemImage: String = "folder.fill"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            Image(systemName: systemImage)
                .font(.system(size: side * 0.36))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
    }
}
