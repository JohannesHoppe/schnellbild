import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The list view (L): a row per item with a small preview, the whole name
/// and its attributes. A click on a column's header sorts by it, again
/// reverses it — the same sort as the sort menu and ⌘1 … ⌘6 (the Distance
/// column only while sorting by distance). Rows act like
/// tiles (`EntryInteractions`); the files the app doesn't show follow, grey.
struct EntryListView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorSchemeContrast) private var contrast

    static let kindWidth = ColumnWidth.kind
    static let dateWidth = ColumnWidth.date
    static let sizeWidth: CGFloat = 80
    static let distanceWidth: CGFloat = 80
    private static let previewSide: CGFloat = 30
    private static let top = "listTop"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // The header pinned inside the scroll view: as wide as the
                    // rows, so its columns stand over theirs also beside a
                    // scroll bar that is always shown
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        // The list's top, for the first row to be scrolled to
                        // below the header
                        Color.clear.frame(height: 0).id(Self.top)
                        Section {
                            let filtering = model.isFiltering
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, index: index, filtering: filtering)
                            }
                            if !filtering {
                                ForEach(model.otherFiles) { file in otherRow(file) }
                            }
                        } header: {
                            VStack(spacing: 0) {
                                header
                                Divider()
                            }
                            // A ⌘- or ⇧-click on it is the header's, not the row under it
                            .modifier(CoversTiles(pane: ObjectIdentifier(model), view: "listHeader"))
                        }
                    }
                }
                // Undo / Redo also below the rows (a row's own menu has them on top)
                .contentShape(Rectangle())
                .contextMenu { UndoMenuItems(history: model.undoHistory, model: model) }
                .modifier(ClickableArea(pane: ObjectIdentifier(model), view: "list"))
                .onChange(of: model.selection, initial: true) { oldValue, newValue in
                    guard let newValue, model.entries.indices.contains(newValue) else { return }
                    if model.clickedSelection == newValue { model.clickedSelection = nil; return }
                    // The pinned header lies over the rows' top: a row scrolled
                    // into view upwards would stand under it, so going up the
                    // row before it is scrolled to (for the first, the list's top)
                    if newValue == 0 {
                        proxy.scrollTo(Self.top)
                    } else if let oldValue, newValue < oldValue {
                        proxy.scrollTo(model.entries[newValue - 1].id)
                    } else {
                        proxy.scrollTo(model.entries[newValue].id)
                    }
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
            headerButton("Name", key: .name, width: nil, alignment: .leading)
            headerButton("Kind", key: .kind, width: Self.kindWidth, alignment: .leading)
            headerButton("Date Modified", key: .modified, width: Self.dateWidth, alignment: .leading)
            headerButton("Date Taken", key: .captured, width: Self.dateWidth, alignment: .leading)
            headerButton("Size", key: .size, width: Self.sizeWidth, alignment: .trailing)
            // Only while sorting by distance (it needs a place to measure from)
            if model.sortKey == .distance {
                headerButton("Distance", key: .distance, width: Self.distanceWidth, alignment: .trailing)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .background(.bar)
    }

    /// A column's header: the whole of its width and height is the button.
    private func headerButton(_ title: LocalizedStringKey, key: BrowserModel.SortKey,
                              width: CGFloat?, alignment: Alignment) -> some View {
        Button { model.setSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortKey == key {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .foregroundStyle(model.sortKey == key ? Color.primary : Color.secondary)
            .padding(.vertical, 5)
            .frame(maxWidth: width ?? .infinity, alignment: alignment)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("column.\(key.rawValue)")
        .accessibilityValue(model.sortKey == key ? (model.sortAscending ? String(localized: "ascending") : String(localized: "descending")) : "")
    }

    // MARK: Rows

    private func row(_ entry: GridEntry, index: Int, filtering: Bool) -> some View {
        // The cursor's row is filled; a marked one tinted, with a checkmark
        let cursor = model.selection == index
        let marked = model.isMarked(entry)
        let location = filtering ? model.relativeLocation(of: entry) : nil
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(cursor ? Color.accentColor : .white, cursor ? Color.white : Color.accentColor)
                    .opacity(marked ? 1 : 0)
                    .frame(width: 14)
                preview(entry).frame(width: Self.previewSide, height: Self.previewSide)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        if let note = entry.unfinishedNote {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(cursor ? Color.white : Color.secondary)
                                .help(note)
                                .accessibilityHidden(true)
                        }
                    }
                    if let location {
                        Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(kind(of: entry), width: Self.kindWidth)
            cell(entry.modDate.map(Self.format) ?? "", width: Self.dateWidth)
            cell(model.knownCaptureDate(of: entry.url).map(Self.format) ?? "", width: Self.dateWidth)
            Text(size(of: entry)).monospacedDigit().frame(width: Self.sizeWidth, alignment: .trailing)
            if model.sortKey == .distance {
                Text(model.knownDistance(of: entry.url).map(GeoPoint.describeDistance) ?? "")
                    .monospacedDigit().lineLimit(1).frame(width: Self.distanceWidth, alignment: .trailing)
            }
        }
        .font(.callout)
        .foregroundStyle(cursor ? Color.white : (model.isEmptyFolder(entry) && !marked ? Color.secondary : Color.primary))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(cursor ? Color.accentColor
                    : marked ? Color.accentColor.opacity(contrast == .increased ? 0.45 : 0.25)
                    : (index % 2 == 1 ? Color.primary.opacity(contrast == .increased ? 0.1 : 0.04) : Color.clear))
        .contentShape(Rectangle())
        .modifier(EntryInteractions(entry: entry))
        .onAppear { if entry.isMedia { model.wantCaptureDate(of: entry.url) } }
        // A folder with no photo or video at any depth is greyed out here
        // too (the grid's folder tiles find it out the same way)
        .task(id: entry.kind == .folder && !entry.isArchive ? entry.url : nil) {
            guard entry.kind == .folder, !entry.isArchive, FolderTile.driveImage(entry.url) == nil,
                  let found = await FolderPreviewCache.shared.containsMedia(entry.browseURL), !Task.isCancelled else { return }
            model.noteFolder(entry.browseURL, empty: !found)
        }
        .id(entry.id)
        .accessibilityElement(children: .ignore)
        .modifier(EntryAccessibility(entry: entry, selected: cursor || marked, location: location))
        .accessibilityValue(TileChrome.spokenState(marked: marked))
        .accessibilityIdentifier("row.\(entry.name)")
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
            if model.sortKey == .distance { Text("").frame(width: Self.distanceWidth) }
        }
        .font(.callout)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .modifier(OtherFileInteractions(file: file))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("other.\(file.name)")
    }

    /// A kind or date: one line, its whole text as the tooltip should the
    /// column still be too narrow for it.
    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func preview(_ entry: GridEntry) -> some View {
        switch entry.kind {
        case .parent:
            Image(systemName: "arrow.up.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
        case .folder:
            let archive = entry.isArchive
            if let drive = FolderTile.driveImage(entry.url) {
                FolderTile(folder: entry.url, side: Self.previewSide, isSelected: false, systemImage: drive,
                           kindLabel: "drive", previews: false)
            } else {
                FolderTile(folder: entry.browseURL, side: Self.previewSide, isSelected: false,
                           systemImage: archive ? "archivebox.fill" : "folder.fill",
                           isEmpty: model.isEmptyFolder(entry), kindLabel: archive ? "archive" : "folder")
            }
        case .image, .video:
            ThumbnailView(url: entry.url, side: Self.previewSide, isSelected: false, isVideo: false, modified: entry.previewDate)
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

/// The kind and date columns as wide as their longest text in the user's
/// language, so every row stays on one line: "Archivo comprimido",
/// "2025年8月16日 上午 10:05" need more than "Archive", "Aug 16, 2025, 10:05 AM".
/// Worked out once from the row font (`.callout`) and the header font, within
/// bounds; a value still wider (another calendar's month) is cut off with
/// its whole text as the tooltip.
enum ColumnWidth {
    static let kind: CGFloat = fitting(
        cells: [String(localized: "Folder"), String(localized: "Archive"),
                String(localized: "Picture"), String(localized: "Video")],
        header: String(localized: "Kind"), within: 90...180)

    static let date: CGFloat = fitting(
        cells: sampleDates.map(EntryListView.format),
        headers: [String(localized: "Date Modified"), String(localized: "Date Taken")], within: 150...260)

    /// One date per month and hour: the longest month name and day period
    /// ("清晨", "下午", "a.m.") are among them, with two-digit days and minutes.
    private static var sampleDates: [Date] {
        var calendar = Calendar.current
        calendar.timeZone = .current
        return (1...12).flatMap { month in
            (0..<24).compactMap { hour in
                calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: hour, minute: 48))
            }
        }
    }

    private static func fitting(cells: [String], header: String, within bounds: ClosedRange<CGFloat>) -> CGFloat {
        fitting(cells: cells, headers: [header], within: bounds)
    }

    private static func fitting(cells: [String], headers: [String], within bounds: ClosedRange<CGFloat>) -> CGFloat {
        let cellFont = NSFont.preferredFont(forTextStyle: .callout)
        let headerFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)
        let cell = cells.map { width(of: $0, in: cellFont) }.max() ?? 0
        // The header's sort chevron and the gap before it
        let header = headers.map { width(of: $0, in: headerFont) + 14 }.max() ?? 0
        return min(max(max(cell, header) + 4, bounds.lowerBound), bounds.upperBound)
    }

    private static func width(of text: String, in font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
