import SwiftUI
import UniformTypeIdentifiers

/// The list view (L): a row per item with a small preview, the whole name
/// and its attributes. A click on a column's header sorts by it, again
/// reverses it — the same sort as the sort menu and ⌘1 … ⌘5. Rows act like
/// tiles (`EntryInteractions`); the files the app doesn't show follow, grey.
struct EntryListView: View {
    @EnvironmentObject var model: BrowserModel

    static let kindWidth: CGFloat = 90
    static let dateWidth: CGFloat = 150
    static let sizeWidth: CGFloat = 80
    private static let previewSide: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let filtering = model.isFiltering
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, index: index, filtering: filtering)
                        }
                        if !filtering {
                            ForEach(model.otherFiles) { file in otherRow(file) }
                        }
                    }
                }
                .onChange(of: model.selection, initial: true) { _, newValue in
                    guard let newValue, model.entries.indices.contains(newValue) else { return }
                    if model.clickedSelection == newValue { model.clickedSelection = nil; return }
                    proxy.scrollTo(model.entries[newValue].id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list")
        .onAppear { model.columnCount = 1 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            headerButton("Name", key: .name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton("Kind", key: .kind).frame(width: Self.kindWidth, alignment: .leading)
            headerButton("Date Modified", key: .modified).frame(width: Self.dateWidth, alignment: .leading)
            headerButton("Date Taken", key: .captured).frame(width: Self.dateWidth, alignment: .leading)
            headerButton("Size", key: .size).frame(width: Self.sizeWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func headerButton(_ title: LocalizedStringKey, key: BrowserModel.SortKey) -> some View {
        Button { model.setSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortKey == key {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .foregroundStyle(model.sortKey == key ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("column.\(key.rawValue)")
        .accessibilityValue(model.sortKey == key ? (model.sortAscending ? String(localized: "ascending") : String(localized: "descending")) : "")
    }

    // MARK: Rows

    private func row(_ entry: GridEntry, index: Int, filtering: Bool) -> some View {
        let selected = model.selection == index || model.isMarked(entry)
        let location = filtering ? model.relativeLocation(of: entry) : nil
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                preview(entry).frame(width: Self.previewSide, height: Self.previewSide)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    if let location {
                        Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(kind(of: entry)).frame(width: Self.kindWidth, alignment: .leading)
            Text(entry.modDate.map(Self.format) ?? "").frame(width: Self.dateWidth, alignment: .leading)
            Text(model.knownCaptureDate(of: entry.url).map(Self.format) ?? "").frame(width: Self.dateWidth, alignment: .leading)
            Text(size(of: entry)).monospacedDigit().frame(width: Self.sizeWidth, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(selected ? Color.white : (model.isEmptyFolder(entry) ? Color.secondary : Color.primary))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor : (index % 2 == 1 ? Color.primary.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .modifier(EntryInteractions(entry: entry))
        .onAppear { if entry.isMedia { model.wantCaptureDate(of: entry.url) } }
        .id(entry.id)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("row.\(entry.name)")
        // (spoken, so translated; the UI tests find rows by their identifier)
        .accessibilityLabel((selected ? String(localized: "selected") : String(localized: "not selected")) + ", " + entry.name)
    }

    private func otherRow(_ file: OtherFile) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: OtherFilesList.icon(for: file)).resizable()
                    .frame(width: 20, height: 20).frame(width: Self.previewSide)
                Text(file.name).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: file.url.pathExtension.uppercased()).frame(width: Self.kindWidth, alignment: .leading)
            Text("").frame(width: Self.dateWidth)
            Text("").frame(width: Self.dateWidth)
            Text(file.byteSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
                .monospacedDigit().frame(width: Self.sizeWidth, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("other.\(file.name)")
    }

    @ViewBuilder
    private func preview(_ entry: GridEntry) -> some View {
        switch entry.kind {
        case .parent:
            Image(systemName: "arrow.up.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
        case .folder:
            let archive = entry.isArchive
            Image(systemName: archive ? "archivebox.fill" : "folder.fill").font(.title3)
                .foregroundStyle(Color.accentColor)
                .opacity(model.isEmptyFolder(entry) ? 0.4 : 1)
        case .image, .video:
            ThumbnailView(url: entry.url, side: Self.previewSide, isSelected: false, isVideo: false, modified: entry.modDate)
        }
    }

    private func kind(of entry: GridEntry) -> String {
        switch entry.kind {
        case .parent: return ""
        case .folder:
            return entry.isArchive
                ? String(localized: "Archive") : String(localized: "Folder")
        case .image: return String(localized: "Picture")
        case .video: return String(localized: "Video")
        }
    }

    private func size(of entry: GridEntry) -> String {
        guard entry.isMedia || entry.isArchive, let bytes = entry.byteSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func format(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}
