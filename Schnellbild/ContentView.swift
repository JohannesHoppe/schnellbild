import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var searchFieldFocused: Bool
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
        // Drag & drop: drag a folder (or media file) onto the window.
        .dropDestination(for: URL.self) { urls, _ in
            model.openDropped(urls)
            return !urls.isEmpty
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .overlay { if isDropTargeted { dropHighlight } }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.mode == .grid, model.searchActive { searchBar }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, model.folderURL != nil { statusBar }
        }
        .onAppear {
            if !model.openFromLaunchArguments() { model.restoreLastFolder() }
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: model.searchText) { _, _ in if !model.isLoading { model.applyFilter() } }
        .onChange(of: model.searchScope) { _, _ in if !model.isLoading { model.applyFilter() } }
        .onChange(of: model.searchActive) { _, active in
            if active { DispatchQueue.main.async { searchFieldFocused = true } }
        }
        .toolbar { toolbarContent }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "Schnellbild")
        .sheet(isPresented: $model.showHelp) { ShortcutsHelpView() }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
            .padding(6)
            .allowsHitTesting(false)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by name", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
            Picker("Scope", selection: $model.searchScope) {
                Text("This Folder").tag(BrowserModel.SearchScope.folder)
                Text("Subfolders").tag(BrowserModel.SearchScope.subfolders)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            Button {
                model.searchText = ""
                model.searchActive = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(statusText).foregroundStyle(.secondary)
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
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    // MARK: - Full-size view (image / GIF / video)

    @ViewBuilder
    private func detail(entry: GridEntry) -> some View {
        ZStack {
            if entry.kind == .video {
                VideoDetailView(url: entry.url)
            } else if entry.isGIF {
                ZStack { Color.black; AnimatedImageView(url: entry.url) }
            } else {
                FullImageView(url: entry.url)
            }
        }
        .overlay(alignment: .bottom) { positionBadge(entry: entry) }
        .overlay(alignment: .topTrailing) {
            if model.showInspector { InspectorView(entry: entry).padding(12) }
        }
    }

    private func positionBadge(entry: GridEntry) -> some View {
        Text("\(model.currentMediaNumber ?? 0) / \(model.mediaCount)  ·  \(entry.name)")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 16)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.chooseFolder() } label: {
                Label("Open Folder", systemImage: "folder")
            }
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
    /// of SwiftUI focus (which kept losing the Backspace/arrow keys). The
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
                if code == 122 { model.showHelp.toggle(); return true }   // F1 → help
                // Let the search field and the help sheet handle their own keys.
                if NSApp.keyWindow?.firstResponder is NSText { return false }
                if model.showHelp { return false }
                let key: BrowserModel.KeyInput?
                switch code {
                case 51:     key = .backspace
                case 53:     key = .escape
                case 36, 76: key = .enter
                case 49:     key = .space
                case 123:    key = .left
                case 124:    key = .right
                case 125:    key = .down
                case 126:    key = .up
                case 115:    key = .home
                case 119:    key = .end
                default:     key = chars.first.map(BrowserModel.KeyInput.char)
                }
                guard let key else { return false }
                return model.handleKey(key, command: command)
            }
            return consume ? nil : event
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
            } else if !model.searchText.isEmpty {
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
                    Text("Nothing named “\(model.searchText)” in this folder\(model.searchScope == .subfolders ? " or its subfolders" : "").")
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
