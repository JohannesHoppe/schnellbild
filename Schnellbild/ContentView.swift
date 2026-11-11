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
    @State private var width: CGFloat = 0
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
        // (the panes and tiles take such drags too, and pass them on: `FinderDrop`)
        .onDrop(of: [.fileURL], delegate: DropZoneDelegate(zone: $window.dropZone, width: width) { urls, zone in
            model.openDropped(urls, slideshow: zone == .slideshow)
        })
        .overlay { if let dropZone = window.dropZone, model.slideshow == nil { DropZonesView(highlighted: dropZone) } }
        // Starting a slideshow or opening a folder ends any drag shown;
        // AppKit does not always send "exited" once the window goes full screen.
        .onChange(of: model.slideshow?.id) { window.dropZone = nil }
        .onChange(of: model.folderURL) { window.dropZone = nil }
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
        .toolbar { toolbarContent }
        .modifier(FolderTitle(model: model))
        .environmentObject(model)
    }

    /// One pane, or both side by side with the active one outlined. A
    /// slideshow takes the whole window. The left pane keeps its place in
    /// the view tree either way, so D doesn't rebuild it (a video playing
    /// in it goes on).
    private var panes: some View {
        let rightShows = model.slideshow != nil && model === window.right
        let showsLeft = !(window.dual && rightShows)
        let showsRight = window.dual && (model.slideshow == nil || rightShows)
        return HStack(spacing: 0) {
            if showsLeft { pane(window.left) }
            if showsRight, let right = window.right {
                if showsLeft { Divider() }
                pane(right)
            }
        }
    }

    private func pane(_ pane: BrowserModel) -> some View {
        PaneView()
            .environmentObject(pane)
            .overlay {
                if window.dual, model.slideshow == nil, pane === model {
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2).allowsHitTesting(false)
                }
            }
            // Dragged tiles over it: where they will land
            .overlay { PaneDropHint(pane: pane) }
            // A click anywhere in a pane makes it the active one
            .simultaneousGesture(TapGesture().onEnded { window.activate(pane) })
            // Tiles dropped onto a pane's free space go into its folder (the
            // whole pane takes drops, also where nothing is drawn)
            .contentShape(Rectangle())
            .onDrop(of: [TileDrag.type, .fileURL], delegate: PaneDrop(pane: pane, window: window))
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
            .help("Enclosing folder (⌘↑)")
            .disabled(!model.canGoUp)
            .accessibilityIdentifier("upButton")

            Button { model.chooseFolder() } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .help("Open folder (⌘O)")

            // The folder's name, where the window's title stands; a click
            // makes it editable to rename the folder
            FolderNameField(model: model)

            BookmarksButton(model: model)
        }
        // Back to the grid, first in the row of actions: a centred item
        // would push the others to the window's right edge
        ToolbarItemGroup(placement: .primaryAction) {
            if model.mode == .detail {
                Button { model.closeDetail() } label: {
                    ShortcutLabel("Grid", systemImage: "square.grid.2x2", keys: "esc", showsTitle: true)
                }
            }
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
                // Bounded: the sort key's name is long in some languages
                // ("Date de prise de vue"), and the toolbar is full
                Label {
                    Text(verbatim: "\(model.sortKey.title) \(model.sortAscending ? "↑" : "↓")")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 130)
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .labelStyle(.titleAndIcon)
            }
            .help("Sort by (⌘1 … ⌘5; press again to reverse)")
            .accessibilityIdentifier("sortMenu")
            .accessibilityLabel("Sort: \(model.sortKey.title) \(model.sortAscending ? "↑" : "↓")")
        }
    }

    // MARK: - Keyboard (one NSEvent monitor — focus-independent)

    /// All shortcuts run through a local key monitor, so they work regardless
    /// of SwiftUI focus, which can swallow Backspace and the arrow keys. The
    /// bindings live in `WindowModel.handleWindowKey` and the active pane's
    /// `BrowserModel.handleKey` (unit-tested); F9, F10 and ⌃⌘F here.
    private func installKeyMonitor() {
        // Once for the app's life (it quits with its window): a view rebuilt
        // must neither add a second monitor nor take one away
        guard !Self.monitorsInstalled else { return }
        Self.monitorsInstalled = true
        ModifierClicks.start()
        let window = self.window
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Hidden by the boss key: every key is its (X X X brings the app back)
            if MainActor.assumeIsolated({ BossKey.engaged }) {
                MainActor.assumeIsolated { BossKey.typed(event) }
                return nil
            }
            // A modal dialog (the Trash confirmation, the open panel) keeps
            // its keys: Return confirms it, Esc cancels it.
            if NSApp.modalWindow != nil || event.window is NSSavePanel { return event }
            // Another window of the app (the About panel) keeps its keys;
            // the Adjustments popover passes them on, as the main window
            if let other = event.window, other !== BrowserModel.appWindow,
               !NSStringFromClass(type(of: other)).contains("Popover") { return event }
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
                // field that merely holds the keyboard without being edited.
                let typing = editor != nil || NSApp.keyWindow?.firstResponder is FocusGatedSearchField
                // The search has the focus, but its field is just being made
                // again (SwiftUI rebuilt the bar) and has no editor yet: the
                // letter goes into the search, not to D, E …
                if editor == nil, model.searchFocused, !command, !control,
                   // the main window itself has the keys (no sheet, no popover)
                   NSApp.keyWindow === BrowserModel.appWindow, !model.anySheetOpen, !model.showAdjustments,
                   let typed = event.characters, typed.count == 1,
                   let scalar = typed.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F,
                   !(0xF700...0xF8FF).contains(scalar.value) {   // not an arrow or function key
                    BrowserModel.testLog("typed into the search while its field was made again: \(typed)")
                    model.searchText += typed
                    return true
                }
                // ⌘⌫ / ⌘↩ while typing are the text field's (delete to the
                // line start): menu key equivalents would run first and
                // trash or open the selected tile.
                if let editor, ContentView.textFieldTakes(code: code, command: command) {
                    editor.keyDown(with: event)
                    return true
                }
                // ⌃⌘F: full screen, as the system's shortcut; other ⌃
                // combinations are the system's.
                // (by the letter on the key, as the menus read it, on any layout)
                let plain = event.charactersIgnoringModifiers?.lowercased() ?? ""
                let letter = plain.unicodeScalars.allSatisfy(\.isASCII) ? plain : (LatinKeys.character(for: code, shift: false) ?? plain)
                if control, command, letter == "f" { model.toggleFullScreen(); return true }
                // X: the boss key (everywhere but while typing)
                if letter == "x", !typing, !command, !control, !event.modifierFlags.contains(.option) {
                    BossKey.engage()
                    return true
                }
                // ⌃O: the commanders' "panels on / off" (the dual pane)
                if control, !command, letter == "o", !typing {
                    return window.handleWindowKey(.char("o"), command: false, control: true, textEditing: false)
                }
                // A key that moves the selection or the search scrolls the
                // grid under the still pointer: the hovered tile is no longer known
                if typing || [115, 116, 119, 121, 123, 124, 125, 126].contains(code) { ModifierClicks.forgetHover() }
                // ⌥ makes other characters ("∂", "ß"): the app's only ⌥ keys
                // are ⌥← / ⌥→ (turn the picture)
                let option = event.modifierFlags.contains(.option)
                if option, code != 123, code != 124 { return false }
                guard !control, let key = ContentView.keyInput(code: code, characters: chars, latin: {
                    LatinKeys.character(for: code, shift: event.modifierFlags.contains(.shift))
                }) else { return false }
                // F9 / F10 as in Norton Commander: the app's menus, quit (after asking)
                // The other pane's sheet (a password asked for) keeps the keys
                if window.panes.contains(where: { $0 !== model && $0.anySheetOpen }) { return false }
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
                if option {
                    return model.handleKey(key, command: command, shift: event.modifierFlags.contains(.shift),
                                           option: true, textEditing: typing, repeating: event.isARepeat)
                }
                return model.handleKey(key, command: command, shift: event.modifierFlags.contains(.shift),
                                       textEditing: typing, repeating: event.isARepeat)
            }
            // For the UI tests: where each key went
            BrowserModel.testLog("\(Date().timeIntervalSince1970) key \(chars.debugDescription) handled \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - event.timestamp)) s after it was typed consumed=\(consume) window=\(event.window.map { String(describing: type(of: $0)) } ?? "nil") "
                                 + "keyWindowIsMain=\(NSApp.keyWindow === BrowserModel.appWindow) "
                                 + "firstResponder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            return consume ? nil : event
        }
        // Trackpad pinch on a video: AVKit's player view would take it for
        // itself, so it's caught here, like the keys. Pictures use their own
        // gesture.
        _ = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            let magnification = event.magnification
            let used = MainActor.assumeIsolated { () -> Bool in
                // The pane under the fingers (the two halves are equally wide),
                // in the main window only (not over a sheet)
                guard let main = BrowserModel.appWindow, event.window === main,
                      let width = main.contentView?.bounds.width else { return false }
                let model = window.active.slideshow != nil || !window.dual ? window.active
                    : event.locationInWindow.x >= width / 2 ? (window.right ?? window.left) : window.left
                guard model.shownMediaEntry?.kind == .video, !model.anySheetOpen else { return false }
                model.applyPinch(1 + magnification)
                return true
            }
            return used ? nil : event
        }
    }

}

extension ContentView {
    /// Keys that go straight to the text field being edited, ahead of the
    /// menu: ⌘⌫, ⌘↩ and ⌘ with an arrow.
    static func textFieldTakes(code: UInt16, command: Bool) -> Bool {
        // ⌘⌫ ⌘↩ edit, ⌘← ⌘→ ⌘↑ ⌘↓ move the cursor
        command && [51, 36, 76, 123, 124, 125, 126].contains(code)
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

    var body: some View {
        // One container, not a Group: a Group hands its modifiers to each
        // branch, so the search bar and the sheets would be made anew each
        // time the list turns empty or not (a field rebuilt while typing)
        ZStack {
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
            // One identity per pane, so the field is kept across updates
            if model.slideshow == nil { searchBar.id(ObjectIdentifier(model)) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, model.slideshow == nil, model.folderURL != nil { statusBar }
        }
        .sheet(isPresented: $model.showHelp) { ShortcutsHelpView() }
        .sheet(item: $model.renameTarget) { RenameView(entry: $0) }
        .sheet(item: $model.renameFileTarget) { RenameView(file: $0) }
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
            SearchModePicker(model: model)
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
            if model.transfersRunning > 0 {
                ProgressView().controlSize(.small)
                Text("Copying or moving…").foregroundStyle(.secondary)
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
        if model.passwordRequest != nil { return String(localized: "Password required") }
        // Not "Empty" before the listing is there, nor for one that failed
        if model.isLoading { return String(localized: "Loading folder…") }
        if let error = model.loadError {
            return error.archive ? String(localized: "This archive can't be read") : String(localized: "This folder can't be read")
        }
        var parts: [String] = []
        if model.folderCount > 0 { parts.append(String(localized: "\(model.folderCount) folders")) }
        if model.archiveCount > 0 { parts.append(String(localized: "\(model.archiveCount) archives")) }
        if model.imageCount  > 0 { parts.append(String(localized: "\(model.imageCount) pictures")) }
        if model.videoCount  > 0 { parts.append(String(localized: "\(model.videoCount) videos")) }
        // (the folder's other files: not searched, not shown during a search)
        if !model.otherFiles.isEmpty, !model.isFiltering { parts.append(String(localized: "Other files: \(model.otherFiles.count)")) }
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

    /// "3 / 12 · name"; in a slideshow "Slideshow · 3 / 57 · name" ("57 so
    /// far" while subfolders are still being walked).
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
                    Text(!model.matcher.isValid ? "“\(model.query)” is not a valid regular expression."
                         : model.searchStopped ? "Search stopped. No matches so far."
                         : model.searchMode == .regex ? "No folder, archive, picture or video whose name matches “\(model.query)”, in this folder or its subfolders."
                         : "No folder, archive, picture or video whose name contains “\(model.query)”, in this folder or its subfolders.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if model.passwordRequest != nil {
                Image(systemName: "lock")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("This archive needs a password")
                    .font(.title2)
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
                if let skipped = model.skippedRestore {
                    let name = (skipped as NSString).lastPathComponent
                    Text("Schnellbild quit unexpectedly last time while showing “\(name)”, so it wasn't opened again.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("skippedRestore")
                }
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
                                        UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
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
            HStack(spacing: 8) {
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
                // The time left, once the length is known
                if let length = model.activePlayer?.lengthSeconds, model.activePlayer?.progress != nil {
                    Text(verbatim: "−" + Self.clock(length * (1 - min(max(progress, 0), 1))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("videoTimeLeft")
                }
            }
        }
    }

    /// "1:05", "1:02:05" (rounded up: the last second shows as 0:01)
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.up))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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

/// The window title: the folder's name, for the Window menu and Mission
/// Control. In the title bar itself the name is `FolderNameField` (it can be
/// clicked to rename), so the toolbar leaves out the window's own title,
/// and with it the room the title takes (the toolbar is full).
private struct FolderTitle: ViewModifier {
    @ObservedObject var model: BrowserModel

    func body(content: Content) -> some View {
        content
            .navigationTitle(model.folderURL?.lastPathComponent ?? "Schnellbild")
            .toolbar(removing: .title)
    }
}

/// The folder's name in the title bar, after the navigation buttons. A click (where the
/// folder can be renamed) turns it into a field: ↩ renames the folder shown,
/// Esc keeps the name.
private struct FolderNameField: View {
    @ObservedObject var model: BrowserModel
    @State private var editing = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let current = model.folderURL?.lastPathComponent ?? "Schnellbild"
        Group {
            if editing {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($focused)
                    .onSubmit {
                        editing = false
                        Task { await model.renameCurrentFolder(to: name) }
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { editing = false } }
                    .accessibilityIdentifier("folderTitleField")
                    .onAppear { focused = true }
            } else {
                Button {
                    guard model.canRenameCurrentFolder else { return }
                    name = current
                    editing = true
                    focused = true
                } label: {
                    Text(verbatim: current).font(.headline).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(model.canRenameCurrentFolder ? Text("Click to rename this folder") : Text(verbatim: current))
                .accessibilityIdentifier("folderTitle")
            }
        }
        .frame(maxWidth: 150)
        // Room before the end of the toolbar's group, as its buttons have
        .padding(.trailing, 8)
        .onChange(of: model.folderURL) { editing = false }
    }
}

/// Tiles dropped onto a pane's free space: into its folder (not while it
/// shows results, whose folder is not the one searched). Only the app's own
/// tile drags: a drop from the Finder goes to the window's drop zones.
private struct PaneDrop: DropDelegate {
    let pane: BrowserModel
    let window: WindowModel

    /// Not into an archive (only read), as a tile there refuses it too.
    private var target: URL? { pane.paneDropFolder }
    func validateDrop(info: DropInfo) -> Bool {
        FinderDrop.isFromFinder(info) || (target != nil && info.hasItemsConforming(to: [TileDrag.type]))
    }
    func dropEntered(info: DropInfo) {
        if FinderDrop.isFromFinder(info) { FinderDrop.update(window); return }
        pane.dropIntoFolderTargeted = target != nil
    }
    func dropExited(info: DropInfo) {
        if FinderDrop.isFromFinder(info) { window.dropZone = nil; return }
        pane.dropIntoFolderTargeted = false
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if FinderDrop.isFromFinder(info) { FinderDrop.update(window); return DropProposal(operation: .copy) }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        if FinderDrop.isFromFinder(info) { return FinderDrop.perform(info, window) }
        pane.dropIntoFolderTargeted = false
        guard let folder = target else { return false }
        let pane = pane
        TileDrag.loadURLs(info.itemProviders(for: [TileDrag.type])) { urls in pane.move(urls, into: folder) }
        window.activate(pane)
        return true
    }
}

/// Beside the search field: how names are matched (ignoring case, with the
/// case as typed, or as a regular expression).
private struct SearchModePicker: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        Picker("", selection: $model.searchMode) {
            Text(verbatim: "abc").help("Ignore case").tag(NameMatcher.Mode.ignoringCase)
            Text(verbatim: "Aa").help("Match case").tag(NameMatcher.Mode.matchingCase)
            Text(verbatim: ".*").help("Regular expression").tag(NameMatcher.Mode.regex)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .font(.system(.callout, design: .monospaced))
        .fixedSize()
        .help(model.searchMode == .ignoringCase ? "Ignore case"
              : model.searchMode == .matchingCase ? "Match case" : "Regular expression")
        .accessibilityLabel("Search mode")
        .accessibilityValue(model.searchMode.rawValue)
        .accessibilityIdentifier("searchMode")
    }
}

/// While tiles are dragged over a pane where they would land in the folder
/// it shows: the pane outlined, the folder named at its foot.
private struct PaneDropHint: View {
    @ObservedObject var pane: BrowserModel

    var body: some View {
        if pane.dropIntoFolderTargeted, let folder = pane.paneDropFolder {
            ZStack(alignment: .bottom) {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 4)
                Text("Into “\(folder.lastPathComponent)”")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.bottom, 44)
                    .accessibilityIdentifier("dropHint")
            }
            .allowsHitTesting(false)
        }
    }
}

/// The star in the toolbar: the bookmarks (filled when the folder shown is one).
private struct BookmarksButton: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var bookmarks = Bookmarks.shared

    var body: some View {
        let marked = model.folderURL.map(bookmarks.contains) ?? false
        Menu {
            BookmarkItems(model: model, shortcuts: false)
        } label: {
            Label("Bookmarks", systemImage: marked ? "star.fill" : "star")
        }
        .help("Bookmarks (⌘D: this folder; ⌃1 … ⌃9: go)")
        .accessibilityIdentifier("bookmarksMenu")
        .accessibilityValue(marked ? "bookmarked" : "")
    }
}

/// A folder or file from the Finder, dropped where a pane or a tile takes
/// drops of the app's own tiles: those views would swallow it, so they pass
/// it on to the window's zones (Browse / Slideshow), by where the pointer
/// is in the window.
@MainActor
enum FinderDrop {
    static func isFromFinder(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !info.hasItemsConforming(to: [TileDrag.type])
    }

    /// The zone under the pointer in the main window.
    private static func zone(mouseDown: Bool) -> DropZone? {
        guard let appWindow = BrowserModel.appWindow, let content = appWindow.contentView else { return nil }
        return DropZoneDelegate.zone(atX: appWindow.mouseLocationOutsideOfEventStream.x,
                                     width: content.bounds.width, mouseDown: mouseDown)
    }

    static func update(_ window: WindowModel) {
        guard window.active.slideshow == nil else { return }
        window.dropZone = zone(mouseDown: NSEvent.pressedMouseButtons != 0)
    }

    static func perform(_ info: DropInfo, _ window: WindowModel) -> Bool {
        let target = zone(mouseDown: true) ?? .browse
        window.dropZone = nil
        DispatchQueue.main.async { window.dropZone = nil }   // once more after AppKit ends the session
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { window.active.openDropped([url], slideshow: target == .slideshow) }
        }
        return true
    }
}

