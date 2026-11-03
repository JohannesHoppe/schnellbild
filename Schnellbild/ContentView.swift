import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var isDropTargeted = false
    @State private var keyMonitor: Any?

    var body: some View {
        Group {
            if model.entries.isEmpty {
                EmptyStateView(isLoading: model.isLoading)
            } else if model.mode == .detail, let entry = model.selectedMediaEntry {
                detail(entry: entry)
            } else {
                ThumbnailGridView()
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
        // Drag & drop: drag a folder (or media file) onto the window.
        .dropDestination(for: URL.self) { urls, _ in
            model.openDropped(urls)
            return !urls.isEmpty
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .overlay { if isDropTargeted { dropHighlight } }
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, model.folderURL != nil { statusBar }
        }
        .onAppear {
            if !model.openFromLaunchArguments() { model.restoreLastFolder() }
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .toolbar { toolbarContent }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "Schnellbild")
        .sheet(isPresented: $model.showHelp) { ShortcutsHelpView() }
        .sheet(item: $model.renameTarget) { RenameFolderView(entry: $0) }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
            .padding(6)
            .allowsHitTesting(false)
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
            if model.slideshowOn {
                Label("Slideshow", systemImage: "play.fill").foregroundStyle(.secondary)
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
        Text("\(model.currentMediaNumber ?? 0) / \(model.mediaCount)  ·  \(entry.name)"
             + (entry.kind == .video && model.videoPaused ? "  ·  Paused" : ""))
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(atTop ? .top : .bottom, 16)
            .accessibilityIdentifier("positionBadge")
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
