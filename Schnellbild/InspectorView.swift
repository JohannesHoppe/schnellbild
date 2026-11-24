import SwiftUI
import AppKit
import ImageIO
import VLCFrames

/// The Inspector (I, ⌘I, "Get Info" in a tile's or row's menu): a sidebar
/// beside the grid, the list, the full view or the slideshow, about the item
/// selected or shown. Sections: Capture, Location, Picture / Video, File,
/// All Metadata. Everything is read off the main thread from the file's
/// header (`PictureMetadata`, `VideoMetadata`), also inside archives
/// (pictures; a video there gets its player's facts).
struct InspectorView: View {
    let entry: GridEntry
    @EnvironmentObject var model: BrowserModel
    @State private var report: MediaReport?
    @State private var reportRead = false
    @State private var facts: FileFacts?
    @State private var created: Date?
    @State private var playerSize: String?
    @State private var streams: StreamFacts?
    @State private var filter = ""
    @State private var expanded: Set<String> = []
    /// A download not finished whose file is growing (its size changed
    /// between two looks); with its size now.
    @State private var growing = false
    @State private var downloadedSize: Int64?

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    wrongExtensionNote
                    if let report, !report.capture.isEmpty {
                        section("Capture", id: "capture") { rows(report.capture) }
                    }
                    if let report, let location = report.location {
                        section("Location", id: "location") { locationSection(location, report: report) }
                    }
                    if entry.isMedia, !mediaRows.isEmpty {
                        section(entry.kind == .video ? "Video" : "Picture", id: "media") { rows(mediaRows) }
                    }
                    section("File", id: "file") { rows(fileRows) }
                    if !allGroups.isEmpty {
                        section("All Metadata", id: "metadata") { metadataSection }
                    }
                    if entry.isMedia, !reportRead {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
        // (again for the file rewritten in place: its date as listed)
        .task(id: FileKey(url: entry.url, modified: entry.previewDate)) { await load() }
        // (again for another player: a growing download's video opened again)
        .task(id: PlayerKey(url: entry.url, player: model.activePlayer.map(ObjectIdentifier.init))) { await loadFromPlayer() }
        .task(id: entry.url) { await watchDownload() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.name)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.showInspector = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .toolTip(Shortcuts.shared.tip(String(localized: "Hide the info"), .info))
            .accessibilityLabel("Hide the info")
            .accessibilityIdentifier("inspectorClose")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var wrongExtensionNote: some View {
        if let recommended = facts?.recommendedExtension {
            let content = facts?.format ?? ""
            // The text in the primary colour (readable on the material in
            // light and dark), the warning carried by the yellow sign and
            // the tinted box around it.
            let note = String(localized: "The file extension doesn't match the content (\(content)). Recommended: .\(recommended)")
            Label {
                Text(note).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("wrongExtension")
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, id: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("inspector.\(id)")
            content()
        }
    }

    private func rows(_ rows: [InfoRow]) -> some View {
        // The labels' column as wide as its longest label ("Änderungsdatum", "Profondeur de couleur")
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows) { row in
                // (the menus on the cells: a modifier on the GridRow would make it one cell)
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .contextMenu { Button("Copy") { Self.copy(row.value) } }
                        .toolTip(String(localized: "Right-click to copy"))
                    // A value longer than its column wraps, never cut off
                    Text(row.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { Button("Copy") { Self.copy(row.value) } }
                        .toolTip(String(localized: "Right-click to copy"))
                }
            }
        }
        .font(.callout)
    }

    // MARK: Location

    @ViewBuilder
    private func locationSection(_ location: MediaLocation, report: MediaReport) -> some View {
        rows(Self.locationRows(location, report: report))
        OfflineMapSlot(point: location.point)
        HStack(spacing: 8) {
            Button { model.sortByDistance(from: location.point) } label: {
                Label("Sort by Distance from Here", systemImage: "location.circle")
            }
            .toolTip(String(localized: "Sorts the folder by how far each photo or video was taken from this place"))
            .accessibilityIdentifier("inspectorSortByDistance")
        }
        .controlSize(.small)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if let url = location.point.appleMapsURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open in Maps", systemImage: "map")
            }
            .controlSize(.small)
            .toolTip(String(localized: "Opens Apple Maps, which goes online"))
            .accessibilityIdentifier("openInMaps")
            Label("Opens Apple Maps, which goes online", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func locationRows(_ location: MediaLocation, report: MediaReport? = nil) -> [InfoRow] {
        var rows = [InfoRow(label: String(localized: "Coordinates"), value: location.point.text)]
        if let source = report?.placeSource {
            rows.append(InfoRow(label: String(localized: "Source"), value: source.placeText))
        }
        if let accuracy = report?.placeAccuracy {
            rows.append(InfoRow(label: String(localized: "Accuracy"), value: accuracy.text))
        }
        if let altitude = location.altitude {
            let metres = Measurement(value: altitude, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
            rows.append(InfoRow(label: String(localized: "Altitude"), value: metres))
        }
        if let direction = location.direction {
            let degrees = Int(direction.rounded()) % 360
            let value = location.trueNorth ? String(localized: "\(degrees)° from true north") : String(localized: "\(degrees)° from magnetic north")
            rows.append(InfoRow(label: String(localized: "Direction"), value: value))
        }
        if let track = report?.track {
            rows.append(InfoRow(label: String(localized: "Route"), value: GeoPoint.describeDistance(track.length)))
        }
        return rows
    }

    // MARK: Picture / video

    /// From the file's header; a video AVFoundation doesn't read (MKV,
    /// WebM …, or one inside an archive) gets the player's facts.
    private var mediaRows: [InfoRow] {
        if let media = report?.media, !media.isEmpty {
            var rows = media
            if let format = facts?.format, entry.kind == .video { rows.insert(InfoRow(label: String(localized: "Format"), value: format), at: 0) }
            return rows
        }
        var rows: [InfoRow] = []
        if let format = facts?.format, entry.kind == .video { rows.append(InfoRow(label: String(localized: "Format"), value: format)) }
        if let playerSize { rows.append(InfoRow(label: String(localized: "Resolution"), value: playerSize)) }
        if let video = streams?.video { rows.append(InfoRow(label: String(localized: "Video"), value: video)) }
        if let audio = streams?.audio { rows.append(InfoRow(label: String(localized: "Audio"), value: audio)) }
        if let tracks = streams?.tracksText { rows.append(InfoRow(label: String(localized: "Tracks"), value: tracks)) }
        if let seconds = streams?.seconds, seconds.isFinite, seconds > 0 {
            rows.append(InfoRow(label: String(localized: "Duration"), value: Self.duration(seconds)))
        }
        if let bitrate = StreamFacts.bitrate(bytes: entry.byteSize, seconds: streams?.seconds) {
            rows.append(InfoRow(label: String(localized: "Bitrate"), value: StreamFacts.describeBitrate(bitrate)))
        }
        return rows
    }

    // MARK: File

    private var fileRows: [InfoRow] {
        var rows = FileReport.rows(for: entry, format: entry.kind == .image ? facts?.format : nil)
        if entry.isDownloading {
            rows.insert(InfoRow(label: String(localized: "Download"),
                                value: growing ? String(localized: "In progress, the file is growing") : String(localized: "Not finished")),
                        at: 1)
            if let downloadedSize, Int(downloadedSize) != entry.byteSize, let size = rows.firstIndex(where: { $0.label == String(localized: "Size") }) {
                rows[size] = InfoRow(label: String(localized: "Size"), value: FileReport.sizeText(Int(downloadedSize)))
            }
        }
        if let created { rows.append(InfoRow(label: String(localized: "Created"), value: Self.dateText(created))) }
        if let modified = entry.modDate { rows.append(InfoRow(label: String(localized: "Date Modified"), value: Self.dateText(modified))) }
        rows.append(InfoRow(label: String(localized: "Path"), value: entry.url.path))
        return rows
    }

    static func dateText(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    /// "3:05", "1:02:07".
    nonisolated static func duration(_ seconds: Double) -> String {
        // Held in Int's range (a crafted length may be anything)
        let length = Duration.seconds(seconds.isFinite ? Int(min(max(seconds, 0), 1e15).rounded()) : 0)
        return length.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    // MARK: All metadata

    private var allGroups: [MetadataGroup] {
        var groups = report?.groups ?? []
        if let tags = streams?.tags, !tags.isEmpty, report?.groups.isEmpty ?? true { groups.append(MetadataGroup(name: "VLC", entries: tags)) }
        return groups
    }

    private var filteredGroups: [MetadataGroup] {
        Self.filtered(allGroups, by: filter)
    }

    /// The groups with only the keys or values that contain `text`.
    static func filtered(_ groups: [MetadataGroup], by text: String) -> [MetadataGroup] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.name.localizedCaseInsensitiveContains(needle) { return group }
            var kept = group
            kept.entries = group.entries.filter { $0.key.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle) }
            return kept.entries.isEmpty ? nil : kept
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .toolTip(String(localized: "Shows only the entries whose name or value holds this text"))
                    .accessibilityIdentifier("metadataFilter")
                Button("Copy All") { Self.copy(allText) }
                    .toolTip(String(localized: "Copy everything the Inspector shows as text"))
                    .accessibilityIdentifier("copyAllMetadata")
            }
            .controlSize(.small)
            let searching = !filter.trimmingCharacters(in: .whitespaces).isEmpty
            ForEach(filteredGroups) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { searching || expanded.contains(group.name) },
                    set: { open in if open { expanded.insert(group.name) } else { expanded.remove(group.name) } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(group.entries) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: item.key).font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: item.value)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu { Button("Copy") { Self.copy(item.value) } }
                            .toolTip(String(localized: "Right-click to copy"))
                        }
                    }
                    .padding(.leading, 4)
                } label: {
                    Text(verbatim: "\(group.name) (\(group.entries.count))").font(.callout)
                }
                .accessibilityIdentifier("metadataGroup.\(group.name)")
            }
        }
    }

    /// Every section and every metadata key as plain text, for the pasteboard.
    private var allText: String {
        var parts: [String] = [entry.name]
        func add(_ title: String, _ rows: [InfoRow]) {
            guard !rows.isEmpty else { return }
            parts.append("\n" + title)
            parts += rows.map { "\($0.label): \($0.value)" }
        }
        add(String(localized: "Capture"), report?.capture ?? [])
        if let report, let location = report.location { add(String(localized: "Location"), Self.locationRows(location, report: report)) }
        if entry.isMedia { add(entry.kind == .video ? String(localized: "Video") : String(localized: "Picture"), mediaRows) }
        add(String(localized: "File"), fileRows)
        for group in allGroups {
            parts.append("\n[\(group.name)]")
            parts += group.entries.map { "\($0.key): \($0.value)" }
        }
        return parts.joined(separator: "\n")
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Reading

    private func load() async {
        report = nil
        reportRead = false
        facts = nil
        created = nil
        filter = ""
        let url = entry.url
        let kind = entry.kind
        let modified = entry.modDate
        let found = await detachedCancellable(priority: .utility) { () -> (MediaReport?, FileFacts?, Date?) in
            // What waits on the disk runs on `Blocking`'s threads: a share
            // that stalls would otherwise hold Swift's
            let created = await Blocking.run(.utility) { FileReport.created(url) }
            // Time and place from every source, the files beside it too (not inside archives)
            func adopting(_ report: MediaReport?) async -> MediaReport? {
                guard !ArchivePath.isInside(url) else { return report }
                let facts = await LocationCache.shared.facts(of: url, modified: modified)
                guard !facts.isEmpty else { return report }
                var adopted = report ?? MediaReport()
                adopted.adopt(facts)
                return adopted
            }
            switch kind {
            case .image:
                // SVG, PDF: their own size (ImageIO reads neither)
                if VectorPicture.isVector(url) {
                    // A PDF opened once, for its size and whether it is a preview
                    let pages = PDFPages.isPDF(url) ? await PDFPages.open(url) : nil
                    let size = PDFPages.isPDF(url) ? pages?.size(of: 0) : await VectorPicture.size(of: url)
                    guard let size, size.width.isFinite, size.height.isFinite else {
                        return (nil, nil, created)
                    }
                    let shown = "\(Int(max(0, min(size.width, 1e15)))) × \(Int(max(0, min(size.height, 1e15)))) px"
                    // An Illustrator file shown by the picture it carries says so
                    var facts: FileFacts?
                    if pages?.isPreview == true, BrowserModel.shownExtension(of: url) == "ai" {
                        facts = FileFacts(format: FileFacts.previewFormat(of: url))
                    }
                    return (MediaReport(media: [InfoRow(label: String(localized: "Resolution"), value: shown)]), facts, created)
                }
                guard let source = await MediaData.imageSource(url) else { return (nil, nil, created) }
                return (await adopting(PictureMetadata.report(source, named: url)), FileFacts.picture(source, named: url), created)
            case .video:
                // Inside an archive there are no first bytes to read without unpacking
                guard !ArchivePath.isInside(url) else { return (nil, nil, created) }
                // Only a regular file (no first bytes otherwise): AVFoundation
                // would wait for ever for the writer of a FIFO named like a video
                guard let head = await Blocking.run(.utility, { VLCSafety.head(of: url) }) else { return (nil, nil, created) }
                let facts = FileFacts.video(head: head, named: url)
                return (await adopting(await VideoMetadata.report(url)), facts, created)
            default:
                return (nil, nil, created)
            }
        }
        // Paged on meanwhile: the next item's report is on its way
        guard !Task.isCancelled else { return }
        (report, facts, created) = found
        reportRead = true
    }

    private struct FileKey: Hashable {
        let url: URL
        let modified: Date?
    }

    private struct PlayerKey: Hashable {
        let url: URL
        let player: ObjectIdentifier?
    }

    /// A download not finished ("x.mp4.part"): its size looked at every two
    /// seconds; growing while it changes.
    private func watchDownload() async {
        growing = false
        downloadedSize = nil
        guard entry.isDownloading, !ArchivePath.isInside(entry.url) else { return }
        var unchanged = 0
        await DownloadSize.watch(entry.url, every: .seconds(2)) { size in
            if let size, let before = downloadedSize, size != before {
                growing = true
                unchanged = 0
            } else if downloadedSize != nil {
                unchanged += 1
                // (a tool writes in bursts: still for 10 s is no longer growing)
                if unchanged >= 5 { growing = false }
            }
            downloadedSize = size
            return true
        }
    }

    /// A video's size and streams from its player once it has opened the
    /// video: what stands in for the header where AVFoundation can't read it.
    /// (Asked: VLC reports neither its size nor its streams.)
    private func loadFromPlayer() async {
        playerSize = nil
        streams = nil
        guard entry.kind == .video else { return }
        for _ in 0..<40 {
            if model.activePlayerURL == entry.url, let player = model.activePlayer {
                if playerSize == nil, let size = player.videoSize, size.width > 0, size.height > 0 {
                    playerSize = "\(Int(size.width)) × \(Int(size.height)) px"
                }
                if streams == nil, let found = await player.streamFacts(), !found.isEmpty {
                    guard !Task.isCancelled else { return }
                    streams = found
                }
                if playerSize != nil, streams != nil { return }
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }
}

/// A small offline map and the nearest town's name in the Inspector's
/// Location section, from `OfflineGeography.provider` (the app sets
/// `BundledGeography`; without map data it is nil and the slot shows nothing).
struct OfflineMapSlot: View {
    let point: GeoPoint
    @State private var place: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let provider = OfflineGeography.provider {
                if let map = provider.map(around: point) {
                    map.frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let place {
                    Text(verbatim: place).font(.callout).accessibilityIdentifier("inspectorPlace")
                }
            }
        }
        .task(id: point) {
            place = nil
            guard let provider = OfflineGeography.provider else { return }
            let found = await provider.placeName(near: point)
            if !Task.isCancelled { place = found }
        }
    }
}

/// An offline map and the names of towns and cities, for the Inspector's
/// Location section. Must work without the network (the app has none in the
/// App Sandbox) and answer quickly (it is asked for every item shown).
protocol OfflineGeographyProvider: Sendable {
    /// The nearest town or city, in the user's language where known.
    func placeName(near point: GeoPoint) async -> String?
    /// A small map around the point, nil where it has none.
    @MainActor func map(around point: GeoPoint) -> AnyView?
}

enum OfflineGeography {
    /// The provider the Inspector asks; nil: no map, no place names.
    @MainActor static var provider: (any OfflineGeographyProvider)?
}
