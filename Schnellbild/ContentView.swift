import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var focused: Bool
    @FocusState private var searchFieldFocused: Bool
    @State private var isDropTargeted = false
    @State private var showInspector = false
    @State private var searchBarVisible = false

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
            if model.mode == .grid, searchBarVisible { searchBar }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, model.folderURL != nil { statusBar }
        }
        // Keyboard focus sits on the whole content (but not while searching).
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; if !model.openFromLaunchArguments() { model.restoreLastFolder() } }
        .onChange(of: model.entries) { _, _ in
            if model.searchText.isEmpty && !searchFieldFocused { focused = true }
        }
        .onChange(of: model.searchText) { _, _ in if !model.isLoading { model.applyFilter() } }
        .onChange(of: model.searchScope) { _, _ in if !model.isLoading { model.applyFilter() } }
        // Handle Backspace separately — the catch-all onKeyPress doesn't deliver
        // it reliably. Full-size view: go back (like Esc). List: go up a level.
        .onKeyPress(.delete) {
            model.goBack()
            return .handled
        }
        .onKeyPress { press in handle(press) }
        .toolbar { toolbarContent }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "Schnellbild")
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
                searchBarVisible = false
                focused = true
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
            if showInspector { InspectorView(entry: entry).padding(12) }
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

    // MARK: - Keyboard

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        let isVideo = model.selectedMediaEntry?.kind == .video

        // f = full screen (without Command, regardless of mode).
        if !cmd, press.characters == "f" {
            model.toggleFullScreen(); return .handled
        }

        // ⌘ shortcuts: zoom/tile size (⌘+/⌘-) and video seek (⌘←/⌘→), like
        // Phiewer. All other ⌘ combos are left to the menus.
        if cmd {
            switch press.key {
            case "+", "=":
                model.scaleUp(); return .handled
            case "-":
                model.scaleDown(); return .handled
            case .leftArrow:
                if model.mode == .detail && isVideo { model.seekVideo(by: -10) }
                else if model.mode == .detail { model.stepMedia(-1) }
                else { model.step(-1) }
                return .handled
            case .rightArrow:
                if model.mode == .detail && isVideo { model.seekVideo(by: +10) }
                else if model.mode == .detail { model.stepMedia(+1) }
                else { model.step(+1) }
                return .handled
            case "f":                       // ⌘F → reveal & focus the search bar
                model.mode = .grid
                searchBarVisible = true
                // Focus on the next tick — the field must exist first.
                DispatchQueue.main.async { searchFieldFocused = true }
                return .handled
            default:
                return .ignored
            }
        }

        switch model.mode {
        case .grid:
            switch press.characters {
            case "+", "=": model.scaleUp();   return .handled
            case "-":      model.scaleDown(); return .handled
            default:       break
            }
            switch press.key {
            case .return, .space: model.activateSelection(); return .handled
            case .rightArrow:     model.step(+1);   return .handled
            case .leftArrow:      model.step(-1);   return .handled
            case .downArrow:      model.stepRow(+1); return .handled
            case .upArrow:        model.stepRow(-1); return .handled
            case .home:           model.select(0); return .handled
            case .end:            model.select(model.entries.count - 1); return .handled
            default:              return .ignored
            }

        case .detail:
            // Bare arrows ALWAYS page (even in a video) — like Phiewer.
            switch press.characters {
            case "+", "=": model.scaleUp();         return .handled
            case "-":      model.scaleDown();       return .handled
            case "0":      model.zoomReset();       return .handled
            case "1":      model.zoomActualSize();  return .handled
            case "[":      model.rotateLeft();      return .handled
            case "]":      model.rotateRight();     return .handled
            case "i":      showInspector.toggle();  return .handled
            case "s":      model.toggleSlideshow(); return .handled
            default:       break
            }
            switch press.key {
            case .escape, .return:
                model.closeDetail(); return .handled
            case .space:
                isVideo ? model.togglePlayPause() : model.stepMedia(+1)
                return .handled
            case .rightArrow, .downArrow: model.stepMedia(+1); return .handled
            case .leftArrow,  .upArrow:   model.stepMedia(-1); return .handled
            default: return .ignored
            }
        }
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
