import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var dropZone: DropZone?
    @State private var width: CGFloat = 0
    @State private var keyMonitor: Any?

    var body: some View {
        Group {
            if model.entries.isEmpty {
                EmptyStateView(isLoading: model.isLoading)
            } else {
                // The grid stays alive under the full view, so it keeps its
                // scroll position (and follows the item shown) for the way back.
                let detailEntry = model.shownMediaEntry
                ZStack {
                    ThumbnailGridView()
                        .opacity(detailEntry == nil ? 1 : 0)
                        .allowsHitTesting(detailEntry == nil)
                        .accessibilityHidden(detailEntry != nil)
                    if let detailEntry {
                        detail(entry: detailEntry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // A folder without media or subfolders still shows its ".." tile.
            if model.mode == .grid, !model.isLoading, !model.isFiltering,
               model.folderCount + model.mediaCount == 0 {
                EmptyStateView(isLoading: false)
            }
        }
        // Drag & drop: a folder (or media file) onto the window. The left
        // half browses it, the right half starts a slideshow.
        .background { GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, new in width = new }
        } }
        .onDrop(of: [.fileURL], delegate: DropZoneDelegate(zone: $dropZone, width: width) { urls, zone in
            model.openDropped(urls, slideshow: zone == .slideshow)
        })
        .overlay { if let dropZone { DropZonesView(highlighted: dropZone) } }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.slideshow == nil { searchBar }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, model.slideshow == nil, model.folderURL != nil { statusBar }
        }
        .toolbar(model.slideshow == nil ? .visible : .hidden, for: .windowToolbar)
        .onAppear {
            if !model.openFromLaunchArguments() { model.restoreLastFolder() }
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .toolbar { toolbarContent }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "Schnellbild")
        .sheet(isPresented: $model.showHelp) { ShortcutsHelpView() }
        .sheet(item: $model.renameTarget) { RenameView(entry: $0) }
    }


    // MARK: - Search bar (always visible)

    private var searchBar: some View {
        HStack(spacing: 8) {
            SearchField(
                text: $model.searchText,
                isFocused: $model.searchFocused,
                placeholder: "Search folder and file names, including subfolders",
                isEnabled: model.folderURL != nil,
                onKey: { model.handleSearchFieldKey($0) }
            )
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("statusText")
            if model.isSearching {
                Text("Searching subfolders…").foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.folderURL?.path ?? "")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        var parts: [String] = []
        if model.folderCount > 0 { parts.append("\(model.folderCount) folders") }
        if model.imageCount  > 0 { parts.append("\(model.imageCount) images") }
        if model.videoCount  > 0 { parts.append("\(model.videoCount) videos") }
        let summary = parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
        guard model.isFiltering else { return summary }
        let query = model.query
        let count = model.entries.count
        return "\(count) \(count == 1 ? "result" : "results") for “\(query)”" + (count > 0 ? " · \(summary)" : "")
    }

    // MARK: - Full-size view (image / GIF / video)

    @ViewBuilder
    private func detail(entry: GridEntry) -> some View {
        ZStack {
            if entry.kind == .video {
                VideoDetailView(url: entry.url)
            } else if entry.isGIF {
                ZStack { Color.black; AnimatedImageView(url: entry.url) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("animatedImage")
            } else {
                FullImageView(url: entry.url)
            }
        }
        // Videos keep the bottom edge free for the player's own controls.
        .overlay(alignment: entry.kind == .video ? .top : .bottom) {
            positionBadge(entry: entry, atTop: entry.kind == .video)
        }
        .overlay(alignment: .topTrailing) {
            if model.showInspector { InspectorView(entry: entry).padding(12) }
        }
    }

    private func positionBadge(entry: GridEntry, atTop: Bool) -> some View {
        Text(badgeText(entry: entry))
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(atTop ? .top : .bottom, 16)
            .accessibilityIdentifier("positionBadge")
    }

    /// "3 / 12 · name"; in a slideshow "Slideshow · 3 / 57 · name" (with "+"
    /// while subfolders are still being walked).
    private func badgeText(entry: GridEntry) -> String {
        var text: String
        if let show = model.slideshow {
            text = "Slideshow  ·  \(show.index + 1) / \(show.items.count)\(show.loading ? "+" : "")  ·  \(entry.name)"
            if show.paused { text += "  ·  Paused" }
        } else {
            text = "\(model.currentMediaNumber ?? 0) / \(model.mediaCount)  ·  \(entry.name)"
        }
        if entry.kind == .video && model.videoPaused { text += "  ·  Paused" }
        if model.enhance { text += "  ·  Enhanced" }
        return text
    }

    // MARK: - Toolbar (history, up, open)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.navigateBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .help("Back (⌘[)")
            .disabled(!model.canGoBack)
            .accessibilityIdentifier("backButton")

            Button { model.navigateForward() } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .help("Forward (⌘])")
            .disabled(!model.canGoForward)
            .accessibilityIdentifier("forwardButton")

            Button { model.goToParentFolder() } label: {
                Label("Up", systemImage: "arrow.up")
            }
            .help("Enclosing folder (⌘↑ / Backspace)")
            .disabled(!model.canGoUp)
            .accessibilityIdentifier("upButton")

            Button { model.chooseFolder() } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .help("Open folder (⌘O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.enhance) {
                Label("Enhance", systemImage: "wand.and.stars")
            }
            .toggleStyle(.button)
            .help("Auto enhance: brighten, correct and sharpen photos and videos, without changing the files (E)")
            .accessibilityIdentifier("enhanceButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.startSlideshow() } label: {
                Label("Slideshow", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Slideshow over everything in this folder and its subfolders (S)")
            .disabled(model.folderURL == nil)
            .accessibilityIdentifier("slideshowButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                SortChoices(model: model, shortcuts: false)
            } label: {
                Label("Sort: \(model.sortKey.title) \(model.sortAscending ? "↑" : "↓")",
                      systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .help("Sort order (⌘1 … ⌘5; the same again reverses it)")
            .accessibilityIdentifier("sortMenu")
            .accessibilityLabel("Sort: \(model.sortKey.title) \(model.sortAscending ? "↑" : "↓")")
        }
        if model.mode == .detail {
            ToolbarItem(placement: .principal) {
                Button { model.closeDetail() } label: {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
            }
        }
    }

    // MARK: - Keyboard (one NSEvent monitor — focus-independent)

    /// All shortcuts run through a local key monitor, so they work regardless
    /// of SwiftUI focus, which can swallow Backspace and the arrow keys. The
    /// actual bindings live in `BrowserModel.handleKey` (unit-tested).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let model = self.model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let command = event.modifierFlags.contains(.command)
            let chars = (command ? event.charactersIgnoringModifiers : event.characters) ?? ""
            // Decide on the main actor whether to consume the key.
            let consume = MainActor.assumeIsolated { () -> Bool in
                guard let key = Self.keyInput(code: code, characters: chars) else { return false }
                return model.handleKey(key, command: command,
                                       textEditing: NSApp.keyWindow?.firstResponder is NSText)
            }
            return consume ? nil : event
        }
    }

    /// Hardware key code → key binding input.
    static func keyInput(code: UInt16, characters: String) -> BrowserModel.KeyInput? {
        switch code {
        case 51:     return .backspace
        case 53:     return .escape
        case 36, 76: return .enter
        case 49:     return .space
        case 123:    return .left
        case 124:    return .right
        case 125:    return .down
        case 126:    return .up
        case 115:    return .home
        case 119:    return .end
        case 122:    return .f1
        case 120:    return .f2
        default:     return characters.first.map(BrowserModel.KeyInput.char)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct EmptyStateView: View {
    let isLoading: Bool
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                Text("Loading folder…")
                    .foregroundStyle(.secondary)
            } else if model.isFiltering {
                if model.isSearching {
                    ProgressView()
                    Text("Searching subfolders…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.title2)
                    Text("No folder or file named “\(model.query)” in this folder or its subfolders.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if model.folderURL != nil {
                Image(systemName: "folder")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Nothing to show")
                    .font(.title2)
                Text("No images, videos, or subfolders here.\nBackspace takes you up a level.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Another Folder…") { model.chooseFolder() }
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("No folder open")
                    .font(.title2)
                Text("Drag a folder here — or use ⌘O or the button.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Folder…") { model.chooseFolder() }
            }
        }
        .padding(40)
    }
}

/// The sort choices, in the View menu (with ⌘1 … ⌘5) and in the toolbar.
/// Choosing the current key again reverses the direction.
struct SortChoices: View {
    @ObservedObject var model: BrowserModel
    let shortcuts: Bool

    var body: some View {
        ForEach(Array(BrowserModel.SortKey.allCases.enumerated()), id: \.element) { index, key in
            let toggle = Toggle(key.title, isOn: Binding(
                get: { model.sortKey == key },
                set: { _ in model.setSort(key) }))
            if shortcuts {
                toggle.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            } else {
                toggle
            }
        }
        Divider()
        Toggle("Ascending", isOn: Binding(
            get: { model.sortAscending },
            set: { if $0 != model.sortAscending { model.setSort(model.sortKey) } }))
        Toggle("Descending", isOn: Binding(
            get: { !model.sortAscending },
            set: { if $0 == model.sortAscending { model.setSort(model.sortKey) } }))
    }
}

// MARK: - Drop zones

enum DropZone { case browse, slideshow }

/// While a folder is dragged over the window: two halves, "Browse" and
/// "Slideshow"; the one under the pointer is highlighted.
struct DropZonesView: View {
    let highlighted: DropZone

    var body: some View {
        HStack(spacing: 12) {
            zone(.browse, title: "Browse", systemImage: "square.grid.2x2")
            zone(.slideshow, title: "Slideshow", systemImage: "play.fill")
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
    }

    private func zone(_ zone: DropZone, title: String, systemImage: String) -> some View {
        let on = zone == highlighted
        return VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 44, weight: .semibold))
            Text(title).font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(on ? Color.accentColor : .secondary)
        .background(RoundedRectangle(cornerRadius: 14).fill(on ? Color.accentColor.opacity(0.15) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(on ? Color.accentColor : .secondary.opacity(0.5), style: StrokeStyle(lineWidth: 3, dash: [10])))
    }
}

/// Decides the zone from the pointer's position and loads the dropped URLs.
struct DropZoneDelegate: DropDelegate {
    @Binding var zone: DropZone?
    let width: CGFloat
    let onDrop: ([URL], DropZone) -> Void

    private func zone(at info: DropInfo) -> DropZone {
        info.location.x < width / 2 ? .browse : .slideshow
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { zone = zone(at: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = zone(at: info)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info)
        zone = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { onDrop([url], target) }
        }
        return true
    }
}
