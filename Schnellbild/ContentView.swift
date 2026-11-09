import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The window: one pane or two (the dual pane), with what belongs to the
/// window — toolbar, keys, drop zones, the mini keyboard, the slideshow's
/// full screen. It works on the active pane.
struct ContentView: View {
    @EnvironmentObject var window: WindowModel

    var body: some View {
        WindowView(model: window.active)
    }
}

private struct WindowView: View {
    /// Once per app: a rebuilt view must neither add a second monitor nor
    /// remove the one there.
    @MainActor private static var monitorsInstalled = false
    @ObservedObject var model: BrowserModel
    @EnvironmentObject var window: WindowModel
    @State private var dropZone: DropZone?
    @State private var width: CGFloat = 0
    @State private var keyMonitor: Any?
    @State private var pinchMonitor: Any?
    /// The launch folder is opened once; the view can appear again (full
    /// screen, toolbar shown or hidden) and must not reload it then.
    @State private var launched = false
    /// In a slideshow the mini keyboard shows while the mouse moves.
    @State private var slideshowKeysShown = false
    @State private var hideSlideshowKeys: Task<Void, Never>?

    var body: some View {
        panes
        // Drag & drop: a folder (or media file) onto the window. The left
        // half browses it, the right half starts a slideshow.
        .background { GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, new in width = new }
        } }
        .onDrop(of: [.fileURL], delegate: DropZoneDelegate(zone: $dropZone, width: width) { urls, zone in
            model.openDropped(urls, slideshow: zone == .slideshow)
        })
        .overlay { if let dropZone, model.slideshow == nil { DropZonesView(highlighted: dropZone) } }
        // Starting a slideshow or opening a folder ends any drag shown;
        // AppKit does not always send "exited" once the window goes full screen.
        .onChange(of: model.slideshow?.id) { dropZone = nil }
        .onChange(of: model.folderURL) { dropZone = nil }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The mini keyboard slides up under everything (K)
            VStack(spacing: 0) {
                if model.showMiniKeyboard, model.slideshow == nil {
                    MiniKeyboard().transition(.move(edge: .bottom))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.showMiniKeyboard)
        }
        .overlay(alignment: .bottom) {
            // In a slideshow: while the mouse moves, then it slides away
            if model.showMiniKeyboard, model.slideshow != nil, slideshowKeysShown {
                MiniKeyboard().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: slideshowKeysShown)
        .onContinuousHover { phase in
            guard model.slideshow != nil, case .active = phase else { return }
            slideshowKeysShown = true
            hideSlideshowKeys?.cancel()
            hideSlideshowKeys = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                slideshowKeysShown = false
            }
        }
        .toolbar(model.slideshow == nil ? .visible : .hidden, for: .windowToolbar)
        // The slideshow fills the whole screen, also where the (hidden) title
        // bar would be.
        .background(model.slideshow == nil ? Color.clear : Color.black)
        .ignoresSafeArea(.container, edges: model.slideshow == nil ? [] : .all)
        .onAppear {
            if !launched {
                launched = true
                if !window.left.openFromLaunchArguments() { window.left.restoreLastFolder() }
            }
            installKeyMonitor()
        }
        // The monitors stay while the app runs (it quits with its window): a
        // view rebuilt must never take them away
        .toolbar { toolbarContent }
        .modifier(FolderTitle(model: model))
        .environmentObject(model)
    }

    /// One pane, or both side by side with the active one outlined. A
    /// slideshow takes the whole window.
    @ViewBuilder
    private var panes: some View {
        if window.dual, model.slideshow == nil, let right = window.right {
            HStack(spacing: 0) {
                pane(window.left)
                Divider()
                pane(right)
            }
        } else {
            PaneView().environmentObject(model)
        }
    }

    private func pane(_ pane: BrowserModel) -> some View {
        PaneView()
            .environmentObject(pane)
            .overlay {
                if pane === model {
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2).allowsHitTesting(false)
                }
            }
            // A click anywhere in a pane makes it the active one
            .simultaneousGesture(TapGesture().onEnded { window.activate(pane) })
            // Tiles dropped onto a pane's free space go into its folder
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let folder = pane.folderURL else { return false }
                TileDrag.loadURLs(providers) { urls in pane.move(urls, into: folder) }
                window.activate(pane)
                return true
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(pane === window.left ? "pane.left" : "pane.right")
    }

    // MARK: - Toolbar (history, up, open)

    @ToolbarContentBuilder
    /// The navigation buttons carry no key caps: their shortcuts (⌘[ ⌘] ⌘↑
    /// ⌘O) are the Mac's usual ones, in the tooltips and menus, and a
    /// narrow window has no room for more (the sort menu would drop into
    /// the overflow).
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
                Label("Enclosing Folder", systemImage: "arrow.up")
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
            // Two panes side by side, as in the file commanders (D, ⌃O)
            Toggle(isOn: Binding(get: { window.dual }, set: { window.setDual($0) })) {
                ShortcutLabel("Dual Pane", systemImage: "rectangle.split.2x1", keys: "D")
            }
            .toggleStyle(.button)
            .help("Dual pane: two folders side by side; Tab switches, F5 copies, F6 moves to the other (D, ⌃O)")
            .accessibilityIdentifier("dualPaneButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.enhance) {
                ShortcutLabel("Auto Enhance", systemImage: "wand.and.stars", keys: "E")
            }
            .toggleStyle(.button)
            .help("Auto enhance: sets exposure, contrast, saturation and sharpness per picture or video, for display only; files are not changed (E)")
            .accessibilityIdentifier("enhanceButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showAdjustments.toggle() } label: {
                ShortcutLabel("Adjust", systemImage: "slider.horizontal.3", keys: "A")
            }
            .help("Exposure, contrast, saturation and sharpness by hand (A)")
            .accessibilityIdentifier("adjustButton")
            // In the window; during a slideshow the toolbar is hidden, so the
            // sliders show as a panel over the picture instead (see body).
            .popover(isPresented: Binding(get: { model.showAdjustments && model.slideshow == nil },
                                          set: { model.showAdjustments = $0 }), arrowEdge: .bottom) {
                AdjustmentsView().environmentObject(model)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.startSlideshow() } label: {
                ShortcutLabel("Slideshow", systemImage: "play.fill", keys: "S", showsTitle: true)
            }
            .buttonStyle(.borderedProminent)
            .help("Slideshow of all pictures and videos in this folder and its subfolders; while searching: of the results (S)")
            .disabled(model.folderURL == nil)
            .accessibilityIdentifier("slideshowButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                SortChoices(model: model, shortcuts: false)
            } label: {
                // No key cap here: a toolbar menu with a label of its own
                // drops out of the accessibility tree (⌘1 … ⌘5: tooltip, help)
                Label("\(model.sortKey.title) \(model.sortAscending ? "↑" : "↓")",
                      systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .help("Sort by (⌘1 … ⌘5; press again to reverse)")
            .accessibilityIdentifier("sortMenu")
            .accessibilityLabel("Sort: \(model.sortKey.title) \(model.sortAscending ? "↑" : "↓")")
        }
        ToolbarItemGroup(placement: .principal) {
            // Full screen at once, in the middle of the title bar (F, ⌃⌘F)
            Button { model.toggleFullScreen() } label: {
                ShortcutLabel("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", keys: "F")
            }
            .help("Full screen on / off (F, ⌃⌘F)")
            .accessibilityIdentifier("fullScreenButton")
            if model.mode == .detail {
                Button { model.closeDetail() } label: {
                    ShortcutLabel("Grid", systemImage: "square.grid.2x2", keys: "esc", showsTitle: true)
                }
            }
        }
    }

    // MARK: - Keyboard (one NSEvent monitor — focus-independent)

    /// All shortcuts run through a local key monitor, so they work regardless
    /// of SwiftUI focus, which can swallow Backspace and the arrow keys. The
    /// actual bindings live in `BrowserModel.handleKey` (unit-tested).
    private func installKeyMonitor() {
        guard keyMonitor == nil, !Self.monitorsInstalled else { return }
        Self.monitorsInstalled = true
        let window = self.window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A modal dialog (the Trash confirmation, the open panel) keeps
            // its keys: Return confirms it, Esc cancels it.
            if NSApp.modalWindow != nil || event.window is NSSavePanel { return event }
            let code = event.keyCode
            let command = event.modifierFlags.contains(.command)
            let control = event.modifierFlags.contains(.control)
            let chars = (command ? event.charactersIgnoringModifiers : event.characters) ?? ""
            // Decide on the main actor whether to consume the key.
            let consume = MainActor.assumeIsolated { () -> Bool in
                let model = window.active
                let editor = NSApp.keyWindow?.firstResponder as? NSText
                // Typing: a field editor at work, or the search field about to
                // get one (a click makes it first responder before editing
                // starts; its first key must not act as D, E …). Not any text
                // field: the window's editable title is one, and holds the
                // keyboard at launch without being edited.
                let typing = editor != nil || NSApp.keyWindow?.firstResponder is FocusGatedSearchField
                // ⌘⌫ / ⌘↩ while typing are the text field's (delete to the
                // line start): menu key equivalents would run first and
                // trash or open the selected tile.
                if let editor, ContentView.textFieldTakes(code: code, command: command) {
                    editor.keyDown(with: event)
                    return true
                }
                // ⌃⌘F: full screen, as the system's shortcut; other ⌃
                // combinations are the system's.
                if control, command, code == 3 { model.toggleFullScreen(); return true }
                // ⌃O: the commanders' "panels on / off" (the dual pane)
                if control, !command, code == 31, !typing {
                    return window.handleWindowKey(.char("o"), command: false, control: true, textEditing: false)
                }
                guard !control, let key = ContentView.keyInput(code: code, characters: chars, latin: {
                    LatinKeys.character(for: code, shift: event.modifierFlags.contains(.shift))
                }) else { return false }
                // F9 / F10 as in Norton Commander: the app's menus, quit (after asking)
                if !typing, !command, model.slideshow == nil, !model.anySheetOpen {
                    switch key {
                    case .f9:  NortonMenus.showMainMenus(); model.noteKeyPress(key, command: false); return true
                    case .f10: NortonMenus.askToQuit(); return true
                    default:   break
                    }
                }
                // The window's keys first (D, Tab, F5, F6), then the active pane's
                if window.handleWindowKey(key, command: command, control: false,
                                          shift: event.modifierFlags.contains(.shift), textEditing: typing) { return true }
                return model.handleKey(key, command: command, shift: event.modifierFlags.contains(.shift),
                                       textEditing: typing, repeating: event.isARepeat)
            }
            return consume ? nil : event
        }
        // Trackpad pinch on a video: AVKit's player view would take it for
        // itself, so it's caught here, like the keys. Pictures use their own
        // gesture.
        pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            let magnification = event.magnification
            let used = MainActor.assumeIsolated { () -> Bool in
                let model = window.active
                guard model.shownMediaEntry?.kind == .video else { return false }
                model.applyPinch(1 + magnification)
                return true
            }
            return used ? nil : event
        }
    }

}

extension ContentView {
    /// Keys that go straight to the text field being edited, ahead of the
    /// menu: ⌘⌫ and ⌘↩.
    static func textFieldTakes(code: UInt16, command: Bool) -> Bool {
        command && [51, 36, 76].contains(code)
    }

    /// Hardware key code → key binding input. On a layout without Latin
    /// letters (Russian, Greek …) a letter key is read as on the user's Latin
    /// layout (`latin`), as macOS does for menu shortcuts.
    static func keyInput(code: UInt16, characters: String,
                         latin: () -> String? = { nil }) -> BrowserModel.KeyInput? {
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
        case 99:     return .f3
        case 118:    return .f4
        case 96:     return .f5
        case 97:     return .f6
        case 98:     return .f7
        case 100:    return .f8
        case 101:    return .f9
        case 109:    return .f10
        case 114:    return .insert   // Insert / Help on full keyboards
        case 48:     return .tab
        default:
            let typed = characters.first.map { $0.isASCII ? characters : (latin() ?? characters) } ?? ""
            return typed.first.map(BrowserModel.KeyInput.char)
        }
    }

}

/// One pane: its grid or full view, search bar and status bar, its sheets.
/// The window shows one, or two side by side (the dual pane).
struct PaneView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var made = { BrowserModel.testLog("pane view state made"); return true }()

    var body: some View {
        Group {
            if model.entries.isEmpty && model.slideshow == nil {
                EmptyStateView(isLoading: model.isLoading)
            } else {
                // The grid stays alive under the full view, so it keeps its
                // scroll position (and follows the item shown) for the way back.
                // A slideshow still looking for its first item shows black,
                // not the grid (clicking a tile there would end the show).
                let detailEntry = model.shownMediaEntry
                let gridShown = detailEntry == nil && model.slideshow == nil
                ZStack {
                    Group {
                        if model.viewMode == .list { EntryListView() } else { ThumbnailGridView() }
                    }
                        .opacity(gridShown ? 1 : 0)
                        .allowsHitTesting(gridShown)
                        .accessibilityHidden(!gridShown)
                    if let detailEntry {
                        detail(entry: detailEntry)
                    } else if model.slideshow != nil {
                        LoadingSpinner()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("slideshowLoading")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // A folder without media or subfolders still shows its ".." tile.
            if model.mode == .grid, !model.isLoading, !model.isFiltering,
               model.folderCount + model.archiveCount + model.mediaCount == 0, model.otherFiles.isEmpty {
                EmptyStateView(isLoading: false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.slideshow != nil, model.showAdjustments {
                AdjustmentsView()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(24)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.slideshow == nil { searchBar }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, model.slideshow == nil, model.folderURL != nil { statusBar }
        }
        .sheet(isPresented: $model.showHelp) { ShortcutsHelpView() }
        .sheet(item: $model.renameTarget) { RenameView(entry: $0) }
        .sheet(item: $model.passwordRequest) { PasswordView(request: $0) }
        .sheet(isPresented: $model.newFolderRequested) { NewFolderView() }
    }

    // MARK: - Search bar (always visible)

    private var searchBar: some View {
        HStack(spacing: 8) {
            SearchField(
                text: $model.searchText,
                isFocused: $model.searchFocused,
                placeholder: String(localized: "Search names of folders, archives, pictures and videos (incl. subfolders)"),
                isEnabled: model.folderURL != nil,
                onKey: { model.handleSearchFieldKey($0) }
            )
            if model.isSearching {
                ProgressView().controlSize(.small)
                Button { model.stopSearch() } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop search (keeps the results found so far)")
                .accessibilityLabel("Stop search")
                .accessibilityIdentifier("stopSearch")
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
            // Tiles or a list (L)
            Picker("", selection: $model.viewMode) {
                Image(systemName: "square.grid.2x2").tag(BrowserModel.ViewMode.grid)
                Image(systemName: "list.bullet").tag(BrowserModel.ViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Grid or list (L)")
            .accessibilityIdentifier("viewModePicker")
            KeyCap("L")
            // The mini keyboard's switch (here, not in the toolbar: that has
            // no room left in a narrow window)
            Button { model.showMiniKeyboard.toggle() } label: {
                ShortcutLabel("Keyboard", systemImage: "keyboard", keys: "K")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.showMiniKeyboard ? Color.accentColor : Color.secondary)
            .help("Mini keyboard: the keys of what's on screen, clickable (K)")
            .accessibilityIdentifier("keyboardButton")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        var parts: [String] = []
        if model.folderCount > 0 { parts.append(String(localized: "\(model.folderCount) folders")) }
        if model.archiveCount > 0 { parts.append(String(localized: "\(model.archiveCount) archives")) }
        if model.imageCount  > 0 { parts.append(String(localized: "\(model.imageCount) pictures")) }
        if model.videoCount  > 0 { parts.append(String(localized: "\(model.videoCount) videos")) }
        if !model.otherFiles.isEmpty { parts.append(String(localized: "Other files: \(model.otherFiles.count)")) }
        let summary = parts.isEmpty ? String(localized: "Empty") : parts.joined(separator: " · ")
        guard model.isFiltering else { return summary }
        let query = model.query
        let count = model.entries.count
        let results = String(localized: "\(count) results")
        return String(localized: "\(results) for “\(query)”") + (count > 0 ? " · \(summary)" : "")
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
        .overlay { if entry.kind == .video { VolumeDisplay() } }
    }

    private func positionBadge(entry: GridEntry, atTop: Bool) -> some View {
        VStack(spacing: 4) {
            Text(badgeText(entry: entry))
                .font(.callout)
                .accessibilityIdentifier("positionBadge")
            // A video: how far it has played
            if entry.kind == .video { VideoProgressBar() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(atTop ? .top : .bottom, 16)
    }

    /// "3 / 12 · name"; in a slideshow "Slideshow · 3 / 57 · name" (with "+"
    /// while subfolders are still being walked).
    private func badgeText(entry: GridEntry) -> String {
        var text: String
        if let show = model.slideshow {
            // While subfolders are still read the count isn't final: "57 so far"
            let count = show.loading ? String(localized: "\(show.items.count) so far") : "\(show.items.count)"
            text = String(localized: "Slideshow") + "  ·  \(show.index + 1) / \(count)  ·  \(entry.name)"
            if show.paused && entry.kind == .image { text += "  ·  " + String(localized: "Paused") }
        } else {
            text = "\(model.currentMediaNumber ?? 0) / \(model.mediaCount)  ·  \(entry.name)"
        }
        if entry.kind == .video && model.videoPaused { text += "  ·  " + String(localized: "Paused") }
        switch model.enhancement {
        case .auto:   text += "  ·  " + String(localized: "Enhanced")
        case .manual: text += "  ·  " + String(localized: "Adjusted")
        case .off:    break
        }
        return text
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
                    Text(model.searchStopped ? "Search stopped. No matches so far."
                         : "No folder, archive, picture or video whose name contains “\(model.query)”, in this folder or its subfolders.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if let failure = model.loadError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text(failure.archive ? "This archive can't be read" : "This folder can't be read")
                    .font(.title2)
                Text(failure.reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("loadError")
            } else if model.folderURL != nil {
                Image(systemName: "folder")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("This folder is empty")
                    .font(.title2)
                if model.canGoUp {
                    Text("⌘↑ goes up one folder level.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button { model.chooseFolder() } label: { HStack(spacing: 6) { Text("Open Another Folder…"); KeyCap("⌘O") } }
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("No folder open")
                    .font(.title2)
                Text("Drag a folder here, press ⌘O, or click Open Folder…")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button { model.chooseFolder() } label: { HStack(spacing: 6) { Text("Open Folder…"); KeyCap("⌘O") } }
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

    private func zone(_ zone: DropZone, title: LocalizedStringKey, systemImage: String) -> some View {
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

    /// The zone under the pointer: the left half browses, the right half
    /// plays. None once the mouse is up: a late update after the drop must
    /// not bring the zones back.
    static func zone(atX x: CGFloat, width: CGFloat, mouseDown: Bool = true) -> DropZone? {
        guard mouseDown else { return nil }
        return x < width / 2 ? .browse : .slideshow
    }

    private func zone(at info: DropInfo) -> DropZone {
        Self.zone(atX: info.location.x, width: width) ?? .browse
    }

    /// Not for a tile dragged inside the app: that goes onto a folder tile.
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !info.hasItemsConforming(to: [TileDrag.type])
    }
    func dropEntered(info: DropInfo) { zone = zone(at: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = Self.zone(atX: info.location.x, width: width, mouseDown: NSEvent.pressedMouseButtons != 0)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info)
        zone = nil
        // Once more after AppKit has finished the drag session.
        DispatchQueue.main.async { [zone = $zone] in zone.wrappedValue = nil }
        let providers = info.itemProviders(for: [.fileURL])
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { onDrop([url], target) }
        }
        return true
    }
}

// MARK: - Adjustments

/// The look by hand: four sliders and the auto switch. With auto on, the
/// sliders show what it sets for the item on screen; moving one switches
/// auto off and carries on from there.
struct AdjustmentsView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Auto enhance", isOn: $model.enhance)
                .toggleStyle(.switch)
                .accessibilityIdentifier("autoSwitch")
            slider("Exposure", \.exposure, -1...1, id: "exposure")
            slider("Contrast", \.contrast, -1...1, id: "contrast")
            slider("Saturation", \.saturation, -1...1, id: "saturation")
            slider("Sharpness", \.sharpness, 0...1, id: "sharpness")
            HStack {
                Text("Files are not changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to original") { model.resetLook() }
                    .disabled(model.enhancement == .off)
                    .accessibilityIdentifier("resetLook")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func slider(_ title: LocalizedStringKey, _ key: WritableKeyPath<Look, Double>,
                        _ range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.format(model.look[keyPath: key]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { model.look[keyPath: key] },
                set: { value in
                    var look = model.look
                    look[keyPath: key] = value
                    model.adjust(look)
                }), in: range)
            .accessibilityIdentifier("slider.\(id)")
            .accessibilityValue(Self.format(model.look[keyPath: key]))
        }
    }

    /// −100 … +100 for the reader.
    static func format(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }
}

/// What a key types on the user's Latin layout (the one macOS uses for
/// shortcuts while a Cyrillic or Greek layout is active).
enum LatinKeys {
    static func character(for keyCode: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// A thin bar under the position badge: how far the video on screen has
/// played (read from its player four times a second).
struct VideoProgressBar: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let progress = model.activePlayer?.progress ?? 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18))
                    Capsule().fill(Color.primary.opacity(0.75))
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(width: 200, height: 3)   // not the badge's whole width
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("videoProgress")
            .accessibilityLabel("\(Int((progress * 100).rounded())) %")
            .accessibilityValue("\(Int((progress * 100).rounded())) %")
        }
    }
}

/// A key as it looks on the keyboard: the shortcut of a button, shown on
/// it so it is learnt by using the button.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1))
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A button's icon (with its title when `showsTitle`) and its shortcut.
struct ShortcutLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let keys: String
    var showsTitle = false

    init(_ title: LocalizedStringKey, systemImage: String, keys: String, showsTitle: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.keys = keys
        self.showsTitle = showsTitle
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsTitle {
                Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
            } else {
                Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            }
            KeyCap(keys)
        }
    }
}

/// The volume, shown a moment while ↑ / ↓ change it.
struct VolumeDisplay: View {
    /// How long it stays; UI tests (`--hold-volume-display`, the README
    /// screenshots) keep it long enough to photograph.
    static let shownFor: Duration = VideoDetailView.uiTesting
        && ProcessInfo.processInfo.arguments.contains("--hold-volume-display") ? .seconds(15) : .seconds(1.2)
    @EnvironmentObject var model: BrowserModel
    @State private var shown = false
    @State private var hide: Task<Void, Never>?

    var body: some View {
        ZStack {
            if shown {
                HStack(spacing: 10) {
                    Image(systemName: model.volume == 0 ? "speaker.slash.fill"
                          : model.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                        .font(.title2)
                        .frame(width: 30)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.18))
                            Capsule().fill(Color.primary.opacity(0.8)).frame(width: geo.size.width * model.volume)
                        }
                    }
                    .frame(width: 160, height: 6)
                    Text(verbatim: "\(Int((model.volume * 100).rounded())) %")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("volumeDisplay")
                .accessibilityLabel("volume \(Int((model.volume * 100).rounded())) %")
            }
        }
        .animation(.easeOut(duration: 0.15), value: shown)
        .onChange(of: model.volumeChange) { _, change in
            guard change != nil else { return }
            shown = true
            hide?.cancel()
            hide = Task { @MainActor in
                try? await Task.sleep(for: Self.shownFor)
                guard !Task.isCancelled else { return }
                shown = false
            }
        }
    }
}

/// The window title: the folder's name, which a click makes editable to
/// rename the folder in place. Always the same modifier: switching between
/// an editable and a fixed title rebuilt the window's content, and the old
/// content's disappearing removed the key monitor the new one had just
/// installed. Where the folder can't be renamed, confirming beeps.
private struct FolderTitle: ViewModifier {
    @ObservedObject var model: BrowserModel

    func body(content: Content) -> some View {
        content
            // A click on the title shows this menu; Rename makes the title editable
            .toolbarTitleMenu { RenameButton() }
            .navigationTitle(Binding(
            get: { model.folderURL?.lastPathComponent ?? "Schnellbild" },
            set: { name in
                guard name != model.folderURL?.lastPathComponent else { return }
                if model.canRenameCurrentFolder { model.renameCurrentFolder(to: name) } else { NSSound.beep() }
            }))
    }
}
