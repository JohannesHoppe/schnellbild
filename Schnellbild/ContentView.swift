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
    /// The keys the tooltips name (Settings → Keyboard).
    @ObservedObject private var shortcuts = Shortcuts.shared
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
            .animation(Motion.animation(.easeOut(duration: 0.2)), value: model.showMiniKeyboard)
        }
        .overlay(alignment: .bottom) {
            // In a slideshow: while the mouse moves, then it slides away
            if model.showMiniKeyboard, model.slideshow != nil, slideshowKeysShown {
                MiniKeyboard().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.animation(.easeOut(duration: 0.25)), value: slideshowKeysShown)
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
        .toolbar(model.presenting ? .hidden : .visible, for: .windowToolbar)
        // The slideshow fills the whole screen, also where the (hidden) title
        // bar would be.
        .background(model.slideshow == nil ? Color.clear : Color.black)
        .ignoresSafeArea(.container, edges: model.presenting ? .all : [])
        .onAppear {
            if !launched {
                launched = true
                if window.left.folderURL == nil {
                    if window.number == 1 {
                        // The first launch: the Pictures folder, not an empty window
                        if !window.left.openFromLaunchArguments() { window.left.restoreLastFolder { BrowserModel.defaultFolder } }
                    } else {
                        // A new window: its own last folder, else the one it was opened from
                        let start = window.startFolder
                        window.left.restoreLastFolder { start }
                    }
                }
            }
            installKeyMonitor()
        }
        .toolbar { toolbarContent }
        .modifier(FolderTitle(model: model))
        .environmentObject(model)
    }

    /// One pane, or both side by side with the active one outlined and a
    /// divider between them to drag (`WindowModel.split`, remembered; a
    /// double click puts it back in the middle). A slideshow takes the whole
    /// window. The left pane keeps its place in the view tree either way, so
    /// D doesn't rebuild it (a video playing in it goes on).
    private var panes: some View {
        let rightShows = model.presenting && model === window.right
        let showsLeft = !(window.dual && rightShows)
        let showsRight = window.dual && (!model.presenting || rightShows)
        let both = showsLeft && showsRight && window.right != nil
        return GeometryReader { geometry in
            let total = geometry.size.width
            let leftWidth = PaneDivider.leftWidth(total: total, split: window.split)
            HStack(spacing: 0) {
                if showsLeft { pane(window.left).frame(width: both ? leftWidth : nil) }
                if showsRight, let right = window.right {
                    if showsLeft { PaneDivider(window: window, total: total) }
                    pane(right)
                }
            }
        }
        .coordinateSpace(name: PaneDivider.space)
    }

    private func pane(_ pane: BrowserModel) -> some View {
        PaneView()
            .environmentObject(pane)
            .overlay {
                if window.dual, !model.presenting, pane === model {
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
    /// ⌘O unless changed) are the Mac's usual ones, in the tooltips and menus, and a
    /// narrow window has no room for more (the sort menu would drop into
    /// the overflow).
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.navigateBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .help(shortcuts.tip(String(localized: "Back"), .back))
            .disabled(!model.canGoBack)
            .accessibilityIdentifier("backButton")

            Button { model.navigateForward() } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .help(shortcuts.tip(String(localized: "Forward"), .forward))
            .disabled(!model.canGoForward)
            .accessibilityIdentifier("forwardButton")

            Button { model.goToParentFolder() } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
            }
            .help(shortcuts.tip(String(localized: "Enclosing folder"), .enclosingFolder))
            .disabled(!model.canGoUp)
            .accessibilityIdentifier("upButton")

            Button { model.chooseFolder() } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .help(shortcuts.tip(String(localized: "Open another folder"), .openFolder))

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
                    ShortcutLabel("Grid", systemImage: "square.grid.2x2", action: .closeFullView, showsTitle: true)
                }
                .help(shortcuts.tip(String(localized: "Back to the grid"), .closeFullView))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // Two panes side by side, as in the file commanders (D, ⌃O)
            Toggle(isOn: Binding(get: { window.dual }, set: { window.setDual($0) })) {
                ShortcutLabel("Dual Pane", systemImage: "rectangle.split.2x1", action: .toggleDual)
            }
            .toggleStyle(.button)
            .help(shortcuts.tip(window.dual ? String(localized: "Back to one pane") : String(localized: "Dual pane: two folders side by side"), .toggleDual)
                   + "\n" + String(localized: "\(shortcuts.hint(.switchPane)) switches, \(shortcuts.hint(.copyToOther)) copies, \(shortcuts.hint(.moveToOther)) moves to the other"))
            .accessibilityIdentifier("dualPaneButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.enhance) {
                ShortcutLabel("Auto Enhance", systemImage: "wand.and.stars", action: .enhance)
            }
            .toggleStyle(.button)
            .help(shortcuts.tip(model.enhance ? String(localized: "Auto enhance off: the files as they are") : String(localized: "Auto enhance: sets exposure, contrast, saturation and sharpness per picture or video, for display only; files are not changed"), .enhance))
            .accessibilityIdentifier("enhanceButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showAdjustments.toggle() } label: {
                ShortcutLabel("Adjust", systemImage: "slider.horizontal.3", action: .adjust)
            }
            .help(shortcuts.tip(String(localized: "Exposure, contrast, saturation and sharpness by hand"), .adjust))
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
                ShortcutLabel("Slideshow", systemImage: "play.fill", action: .startSlideshow, showsTitle: true)
            }
            .buttonStyle(.borderedProminent)
            .help(shortcuts.tip(String(localized: "Slideshow of all pictures and videos in this folder and its subfolders; while searching: of the results"), .startSlideshow))
            .disabled(model.folderURL == nil)
            .accessibilityIdentifier("slideshowButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                SortChoices(model: model, shortcuts: false)
            } label: {
                // No key cap here: a toolbar menu with a label of its own
                // drops out of the accessibility tree (its keys: tooltip, help)
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
            .help(Shortcuts.tip(String(localized: "Sort by name, kind, date, size or distance; choosing the same again reverses the order"), keys: HelpKeys.range(ShortcutAction.sorts).text(shortcuts)))
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
        // Once for the app's life, for all its windows (each key goes to the
        // window it was typed in): a view rebuilt must neither add a second
        // monitor nor take one away
        guard !Self.monitorsInstalled else { return }
        Self.monitorsInstalled = true
        ModifierClicks.start()
        TileDrag.start()
        // For the UI tests: when the mouse went down and up (a drag's end), next to the keys
        if TestSwitches.testLog != nil {
            _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                BrowserModel.testLog("\(Date().timeIntervalSince1970) mouse \(event.type == .leftMouseDown ? "down" : "up") "
                                     + "clicks=\(event.clickCount) window=\(event.window.map { String(describing: type(of: $0)) } ?? "nil")")
                return event
            }
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Hidden by the boss key: every key is its (X X X brings the app back)
            if MainActor.assumeIsolated({ BossKey.engaged }) {
                MainActor.assumeIsolated { BossKey.typed(event) }
                return nil
            }
            // ⌘Z / ⇧⌘Z while text is typed (the search, a name in a sheet)
            // undo the typing, not the file action Edit → Undo names
            if ContentView.isUndoKey(event), MainActor.assumeIsolated({ NSApp.keyWindow?.firstResponder is NSText }) {
                let redo = event.modifierFlags.contains(.shift)
                _ = MainActor.assumeIsolated { NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil) }
                return nil
            }
            // A modal dialog (the Trash confirmation, the open panel) keeps
            // its keys: Return confirms it, Esc cancels it.
            if NSApp.modalWindow != nil || event.window is NSSavePanel {
                BrowserModel.testLog("\(Date().timeIntervalSince1970) key \(event.charactersIgnoringModifiers.debugDescription) passed on: a modal window")
                return event
            }
            // The browser window the key was typed in; the Adjustments
            // popover passes its keys on to the window in front; another
            // window of the app (the About panel) keeps its keys
            let popover = event.window.map { NSStringFromClass(type(of: $0)).contains("Popover") } ?? false
            guard let window = MainActor.assumeIsolated({ WindowModel.of(event.window) ?? (popover ? WindowModel.current : nil) })
            else {
                BrowserModel.testLog("\(Date().timeIntervalSince1970) key \(event.charactersIgnoringModifiers.debugDescription) passed on: "
                                     + "window=\(event.window.map { String(describing: type(of: $0)) } ?? "nil")")
                return event
            }
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
                   NSApp.keyWindow === window.nsWindow, !model.anySheetOpen, !model.showAdjustments,
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
                let letter = LatinKeys.letter(of: event)
                if control, command, letter == "f" { model.toggleFullScreen(); return true }
                // The keys as set in Settings → Keyboard: a key given to an
                // action carries it out, a key taken from one does nothing;
                // Schnellbild's own keys go on to the key bindings below
                if let chord = KeyChord.from(event),
                   let handled = window.handleTyped(chord, physical: KeyChord.physical(event), textEditing: typing, repeating: event.isARepeat) { return handled }
                // X: the boss key (everywhere but while typing)
                if letter == "x", !typing, !command, !control, !event.modifierFlags.contains(.option) {
                    BossKey.press()
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
                if !typing, !command, !model.presenting, !model.anySheetOpen {
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
                                       option: option, textEditing: typing, repeating: event.isARepeat)
            }
            // For the UI tests: where each key went
            BrowserModel.testLog("\(Date().timeIntervalSince1970) key \(chars.debugDescription) handled \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - event.timestamp)) s after it was typed consumed=\(consume) window=\(event.window.map { String(describing: type(of: $0)) } ?? "nil") "
                                 + "keyWindowIsMain=\(MainActor.assumeIsolated { NSApp.keyWindow === window.nsWindow }) "
                                 + "firstResponder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            return consume ? nil : event
        }
        // Trackpad pinch on a video (AVKit's player view would take it for
        // itself) and on the grid (the tile size), caught here like the
        // keys: `WindowModel.pinch`. Pictures use their own gesture.
        _ = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            let magnification = event.magnification, began = event.phase.contains(.began)
            let used = MainActor.assumeIsolated { () -> Bool in
                // In a main window only (not over a sheet)
                guard let window = WindowModel.of(event.window), let main = window.nsWindow,
                      let width = main.contentView?.bounds.width else { return false }
                return window.pinch(magnification, began: began, atX: event.locationInWindow.x, width: width)
            }
            return used ? nil : event
        }
    }

}

extension ContentView {
    /// ⌘Z or ⇧⌘Z, no ⌃ or ⌥: the letter the layout types (on a layout
    /// without Latin letters the user's Latin one), as the menus read it.
    static func isUndoKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard flags == .command || flags == [.command, .shift] else { return false }
        return LatinKeys.letter(of: event) == "z"
    }

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
    /// The keys the status bar names (Settings → Keyboard).
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        // One container, not a Group: a Group hands its modifiers to each
        // branch, so the search bar and the sheets would be made anew each
        // time the list turns empty or not (a field rebuilt while typing)
        HStack(spacing: 0) {
        ZStack {
            // (the Atlas of the subfolders shows while they are read)
            if model.entries.isEmpty && model.slideshow == nil && !(model.viewMode == .atlas && model.showsDeep) {
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
                        switch model.viewMode {
                        case .grid: ThumbnailGridView()
                        case .list: EntryListView()
                        case .atlas: AtlasView(atlas: model.atlas)
                        }
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
                // The slideshow's playlist (P), over the picture or beside it
                .modifier(PlaylistLayout())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The Inspector (I, ⌘I, Get Info): a sidebar about the item selected or shown
            if model.showInspector {
                Divider()
                if let entry = model.inspectedEntry {
                    InspectorView(entry: entry)
                } else {
                    Text("Select an item to see its info.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .frame(width: InspectorView.width)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .accessibilityIdentifier("inspector")
                }
            }
        }
        .overlay {
            // A folder without media or subfolders still shows its ".." tile.
            if model.mode == .grid, !model.isLoading, !model.isFiltering,
               model.folderCount + model.archiveCount + model.mediaCount == 0, model.otherFiles.isEmpty, !model.showsDeep {
                EmptyStateView(isLoading: false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.slideshow != nil, model.showAdjustments {
                AdjustmentsView()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(24)
                    // left of the playlist
                    .padding(.trailing, model.showPlaylist ? CGFloat(model.playlistWidth) : 0)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // One identity per pane, so the field is kept across updates
            if !model.presenting {
                searchBar.id(ObjectIdentifier(model))
                    .modifier(CoversTiles(pane: ObjectIdentifier(model), view: "searchBar"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, !model.presenting, model.folderURL != nil {
                statusBar.modifier(CoversTiles(pane: ObjectIdentifier(model), view: "statusBar"))
            } else if model.mode == .detail, !model.presenting, model.accessLimited {
                // The file dropped alone, in the full view: why ← → find
                // nothing, and how to see its folder
                accessLimitedBar
            }
        }
        .sheet(isPresented: $model.showHelp) { ShortcutsHelpView() }
        .sheet(item: $model.renameTarget) { RenameView(entry: $0) }
        .sheet(item: $model.renameFileTarget) { RenameView(file: $0) }
        .sheet(item: $model.passwordRequest) { PasswordView(request: $0) }
        .sheet(isPresented: $model.newFolderRequested) { NewFolderView() }
        .sheet(isPresented: $model.distanceOriginRequested) { DistanceOriginView(start: model.distanceOrigin) }
        .alert(Text(verbatim: model.locationMissing.map { String(localized: "“\($0)” has no location") } ?? ""),
               isPresented: Binding(get: { model.locationMissing != nil }, set: { if !$0 { model.locationMissing = nil } })) {
            Button("OK") { model.locationMissing = nil }
        } message: {
            Text("Only photos and videos with GPS data in their metadata have one.")
        }
    }

    // MARK: - Search bar (always visible)

    private var searchBar: some View {
        HStack(spacing: 8) {
            SearchField(
                text: $model.searchText,
                isFocused: $model.searchFocused,
                // Short enough for half a window (the dual pane) in every language; the whole in the tooltip
                placeholder: String(localized: "Search names, also in subfolders"),
                isEnabled: model.folderURL != nil,
                onKey: { model.handleSearchFieldKey($0) }
            )
            .help(shortcuts.tip(String(localized: "Search names of folders, archives, pictures and videos (incl. subfolders)"), .search))
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

    /// The counts come first and are never cut off. The first of these rows
    /// that fits is shown: the counts with the folder's path (cut at its
    /// start, at least 60 pt), the counts alone, the counts over two lines,
    /// broken between their parts (half a window in Portuguese, Spanish,
    /// French or Japanese).
    private var statusBar: some View {
        ViewThatFits(in: .horizontal) {
            statusRow(path: true, wrap: false)
            statusRow(path: false, wrap: false)
            statusRow(path: false, wrap: true)
        }
        .statusBarStyle()
    }

    /// The full view of a file shown alone (`accessLimited`): the status
    /// bar's note and its "Allow Access…".
    private var accessLimitedBar: some View {
        HStack(spacing: 8) {
            accessLimitedNote
            Spacer(minLength: 0)
        }
        .statusBarStyle()
    }

    /// Only the file dropped can be read: why, and the way to its folder.
    @ViewBuilder private var accessLimitedNote: some View {
        Text("Only the file you opened is shown here.").foregroundStyle(.secondary)
        Button("Allow Access…") { model.allowAccess() }
            .buttonStyle(.link)
            .help("Choose the folder in the open panel, so Schnellbild may show all of it")
            .accessibilityIdentifier("allowAccess")
    }

    private func statusRow(path: Bool, wrap: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if wrap {
                    let parts = statusParts
                    StatusFlow {
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            Text(verbatim: index < parts.count - 1 ? part + " ·" : part).fixedSize()
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(statusText)
                } else {
                    Text(statusText).lineLimit(1).fixedSize()
                }
            }
            .foregroundStyle(.secondary)
            .layoutPriority(1)
            .help(statusText)
            .accessibilityIdentifier("statusText")
            if model.isSearching {
                Text("Searching subfolders…").foregroundStyle(.secondary).lineLimit(1)
            }
            if model.transfersRunning > 0 {
                ProgressView().controlSize(.small)
                Text("Copying or moving…").foregroundStyle(.secondary).lineLimit(1)
            }
            // Sorting by distance: the places of many files being read (another sort stops it)
            if let progress = model.locationProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 60)
                Text("Reading locations: \(progress.done) of \(progress.total)")
                    .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .accessibilityIdentifier("locationProgress")
            }
            if model.accessLimited { accessLimitedNote }
            if path {
                folderPath
            } else {
                Spacer(minLength: 0)
            }
            // Tiles, a list or the Atlas (L: the next one)
            Picker("", selection: $model.viewMode) {
                Image(systemName: "square.grid.2x2").tag(BrowserModel.ViewMode.grid)
                    .accessibilityLabel(Text("as Grid"))
                Image(systemName: "list.bullet").tag(BrowserModel.ViewMode.list)
                    .accessibilityLabel(Text("as List"))
                Image(systemName: "map").tag(BrowserModel.ViewMode.atlas)
                    .accessibilityLabel(Text("as Atlas"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(shortcuts.tip(String(localized: "Grid, list or Atlas (the map)"), .toggleList))
            .accessibilityIdentifier("viewModePicker")
            if let key = shortcuts.keys(.toggleList).first { KeyCap(key) }
            // The mini keyboard's switch (here, not in the toolbar: that has
            // no room left in a narrow window)
            Button { model.showMiniKeyboard.toggle() } label: {
                ShortcutLabel("Keyboard", systemImage: "keyboard", action: .miniKeyboard)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.showMiniKeyboard ? Color.accentColor : Color.secondary)
            .help(shortcuts.tip(model.showMiniKeyboard ? String(localized: "Hide the mini keyboard") : String(localized: "Mini keyboard: the keys of what's on screen, clickable"), .miniKeyboard))
            .accessibilityIdentifier("keyboardButton")
        }
    }

    /// The folder's path, cut at its start; right-click (or ⌃-click) copies
    /// it or reveals the folder, the tooltip shows it whole. VoiceOver gets
    /// the same items as actions.
    private var folderPath: some View {
        let shown = model.shownPath ?? ""
        return Text(verbatim: shown)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(minWidth: 60, idealWidth: 60, maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .help(Text(verbatim: shown + "\n") + Text("Right-click to copy"))
            .contextMenu { pathMenu }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Path"))
            .accessibilityValue(Text(verbatim: shown))
            .accessibilityAction(named: Text("Copy Path")) { model.copyFolderPath() }
            .accessibilityAction(named: Text("Copy Path of Selected Item")) { model.copySelectedItemPath() }
            .accessibilityAction(named: Text("Reveal in Finder")) { model.revealFolderInFinder() }
            .accessibilityIdentifier("statusPath")
    }

    /// The path's context menu.
    @ViewBuilder private var pathMenu: some View {
        Button("Copy Path") { model.copyFolderPath() }
            .disabled(model.shownPath == nil)
        Button("Copy Path of Selected Item") { model.copySelectedItemPath() }
            .disabled(model.selectedItemPath == nil)
        Divider()
        Button("Reveal in Finder") { model.revealFolderInFinder() }
            .disabled(!model.canRevealFolder)
    }

    private var statusText: String { statusParts.joined(separator: " · ") }

    /// The status bar's text in parts, which it keeps whole when it breaks
    /// the text over two lines.
    private var statusParts: [String] {
        if model.passwordRequest != nil { return [String(localized: "Password required")] }
        // Not "Empty" before the listing is there, nor for one that failed
        if model.isLoading { return [String(localized: "Loading folder…")] }
        if let error = model.loadError {
            return [error.archive ? String(localized: "This archive can't be read") : String(localized: "This folder can't be read")]
        }
        var parts: [String] = []
        if model.folderCount > 0 { parts.append(String(localized: "\(model.folderCount) folders")) }
        if model.archiveCount > 0 { parts.append(String(localized: "\(model.archiveCount) archives")) }
        if model.imageCount  > 0 { parts.append(String(localized: "\(model.imageCount) pictures")) }
        if model.videoCount  > 0 { parts.append(String(localized: "\(model.videoCount) videos")) }
        // (the folder's other files: not searched, not shown during a search)
        if !model.otherFiles.isEmpty, !model.isFiltering { parts.append(String(localized: "Other files: \(model.otherFiles.count)")) }
        let summary = parts.isEmpty ? [String(localized: "Empty")] : parts
        guard model.isFiltering else { return summary }
        let query = model.query
        let count = model.entries.count
        let results = String(localized: "\(count) results")
        return [String(localized: "\(results) for “\(query)”")] + (count > 0 ? summary : [])
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
        .overlay { if entry.kind == .video { VolumeDisplay() } }
        // The control bar (over the badge)
        .overlay { if entry.kind == .video { VideoChrome() } }
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

    /// "3 / 12 · name" (a PDF: "· Page 2 / 9"); in a slideshow "Slideshow · 3 / 57 · name" ("57 so
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
            // A PDF: the page on screen
            if let pdf = model.pdfPosition, pdf.url == entry.url {
                text += "  ·  " + String(localized: "Page \(pdf.page + 1) / \(pdf.count)")
            }
        }
        if entry.kind == .video && model.videoPaused { text += "  ·  " + String(localized: "Paused") }
        if entry.kind == .video && model.playbackSpeed != 1 { text += "  ·  " + PlaybackSpeed.text(model.playbackSpeed) }
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
    @ObservedObject private var shortcuts = Shortcuts.shared

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
            } else if let failure = model.loadError, failure.needsAccess {
                Image(systemName: "lock.open")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Schnellbild needs your permission for this folder")
                    .font(.title2)
                    .multilineTextAlignment(.center)
                Button("Allow Access…") { model.allowAccess() }
                    .keyboardShortcut(.defaultAction)
                    .help("Choose the folder in the open panel, so Schnellbild may show all of it")
                    .accessibilityIdentifier("allowAccess")
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
                // The Pictures folder opened at the first launch, empty: how to get to the pictures
                if model.folderURL.map(BrowserModel.canonicalPath) == BrowserModel.defaultFolder.map(BrowserModel.canonicalPath) {
                    Text(shortcuts.keys(.openFolder).first.map { String(localized: "Drag a folder here, press \($0.text), or click Open Another Folder…") }
                         ?? String(localized: "Drag a folder here or click Open Another Folder…"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("dropHint.empty")
                }
                if model.canGoUp, let up = shortcuts.keys(.enclosingFolder).first {
                    Text(String(localized: "\(up.text) goes up one folder level."))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button { model.chooseFolder() } label: {
                    HStack(spacing: 6) { Text("Open Another Folder…"); if let key = shortcuts.keys(.openFolder).first { KeyCap(key) } }
                }
                .help(shortcuts.tip(String(localized: "Open another folder"), .openFolder))
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("No folder open")
                    .font(.title2)
                Text(shortcuts.keys(.openFolder).first.map { String(localized: "Drag a folder here, press \($0.text), or click Open Folder…") }
                     ?? String(localized: "Drag a folder here or click Open Folder…"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let missing = model.unavailableRestore {
                    let name = (missing as NSString).lastPathComponent
                    Text("“\(name)” isn't available: its disk or server isn't connected. It opens once it is.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("unavailableRestore")
                }
                if let skipped = model.skippedRestore {
                    let name = (skipped as NSString).lastPathComponent
                    Text("Schnellbild quit unexpectedly last time while showing “\(name)”, so it wasn't opened again.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("skippedRestore")
                }
                Button { model.chooseFolder() } label: {
                    HStack(spacing: 6) { Text("Open Folder…"); if let key = shortcuts.keys(.openFolder).first { KeyCap(key) } }
                }
                .help(shortcuts.tip(String(localized: "Open a folder"), .openFolder))
            }
        }
        .padding(40)
    }
}

/// The sort choices, in the View menu (with ⌘1 … ⌘6 unless changed) and in the toolbar.
/// Choosing the current key again reverses the direction; Distance without
/// a place to measure from opens the sheet that asks for one.
struct SortChoices: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var keys = Shortcuts.shared
    let shortcuts: Bool

    var body: some View {
        ForEach(Array(BrowserModel.SortKey.allCases.enumerated()), id: \.element) { index, key in
            let toggle = Toggle(key.title, isOn: Binding(
                get: { model.sortKey == key },
                set: { _ in model.setSort(key) }))
            if shortcuts {
                toggle.keyboardShortcut(keys.menuShortcut(ShortcutAction.sorts[index]))
            } else {
                toggle
            }
        }
        Button("Distance from Coordinates or Map Link…") { model.requestDistanceOrigin() }
            .disabled(model.anySheetOpen || model.presenting)
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
    func dropEntered(info: DropInfo) {
        BrowserModel.testLog("\(Date().timeIntervalSince1970) window drop entered at \(info.location)")
        // Only a drag from outside: the app's own tile drags aren't read
        if FinderDrop.isFromFinder(info) { FinderDrop.peek() }
        zone = zone(at: info)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if FinderDrop.isFromFinder(info) { FinderDrop.peek() }
        zone = Self.zone(atX: info.location.x, width: width, mouseDown: NSEvent.pressedMouseButtons != 0)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info)
        zone = nil
        // Once more after AppKit has finished the drag session.
        DispatchQueue.main.async { [zone = $zone] in zone.wrappedValue = nil }
        BrowserModel.testLog("\(Date().timeIntervalSince1970) window drop at \(info.location)")
        return FinderDrop.fileURLs(info) { urls in onDrop(urls, target) }
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
                .help(Shortcuts.shared.tip(String(localized: "Sets the four values below for each picture or video"), .enhance))
                .accessibilityIdentifier("autoSwitch")
            slider("Exposure", \.exposure, -1...1, id: "exposure", help: String(localized: "Darker or lighter"))
            slider("Contrast", \.contrast, -1...1, id: "contrast", help: String(localized: "Flatter or with more contrast"))
            slider("Saturation", \.saturation, -1...1, id: "saturation", help: String(localized: "Paler or more colourful"))
            slider("Sharpness", \.sharpness, 0...1, id: "sharpness", help: String(localized: "Sharpens edges"))
            // Note and button side by side where both fit whole; in languages
            // with a longer button (de, es, ru …) the note goes above it
            ViewThatFits(in: .horizontal) {
                HStack {
                    filesNote
                    Spacer()
                    resetButton
                }
                VStack(alignment: .trailing, spacing: 8) {
                    filesNote.frame(maxWidth: .infinity, alignment: .leading)
                    resetButton
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var filesNote: some View {
        Text("Files are not changed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resetButton: some View {
        Button("Reset to original") { model.resetLook() }
            .disabled(model.enhancement == .off)
            .help("Auto enhance off, every slider at 0")
            .accessibilityIdentifier("resetLook")
    }

    private func slider(_ title: LocalizedStringKey, _ key: WritableKeyPath<Look, Double>,
                        _ range: ClosedRange<Double>, id: String, help: String) -> some View {
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
            .help(help)
            .accessibilityLabel(Text(title))
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
    /// The letter on the key, as the menus read it: what the layout types
    /// when it is Latin, else what the user's Latin layout types there.
    static func letter(_ typed: String, keyCode: UInt16) -> String {
        typed.unicodeScalars.allSatisfy(\.isASCII) ? typed : (character(for: keyCode, shift: false) ?? typed)
    }

    /// `letter` of the key typed, without its modifiers, in lower case.
    static func letter(of event: NSEvent) -> String {
        letter(event.charactersIgnoringModifiers?.lowercased() ?? "", keyCode: event.keyCode)
    }

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
                // The UI tests read the number as "42 %" in every language, as the
                // label: XCUITest gets no value from a group like this one
                .accessibilityLabel(test: "\(Int((progress * 100).rounded())) %", spoken: String(localized: "Played"))
                .accessibilityValue(test: "", spoken: min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0))))
                // The time left, once the length is known
                if let length = model.activePlayer?.lengthSeconds, model.activePlayer?.progress != nil {
                    let left = "−" + Self.clock(length * (1 - min(max(progress, 0), 1)))
                    Text(verbatim: left)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("videoTimeLeft")
                        // UI tests: where the player stands, with the app's clock at that
                        // moment, so a test measures the speed without its own delays
                        .accessibilityLabel(test: Self.playerClock(model.activePlayer?.playedSeconds), spoken: left)
                }
            }
        }
    }

    /// "played 8.432 s at 1234.567 s": the player's place and the system's
    /// uptime when it was read (UI tests).
    static func playerClock(_ played: Double?) -> String {
        String(format: "played %.3f s at %.3f s", played ?? -1, ProcessInfo.processInfo.systemUptime)
    }

    /// "1:05", "1:02:05" (rounded up: the last second shows as 0:01)
    static func clock(_ seconds: Double) -> String {
        // Held in Int's range (a crafted length may be anything)
        let total = seconds.isFinite ? Int(min(max(seconds, 0), 1e15).rounded(.up)) : 0
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A key as it looks on the keyboard: the shortcut of a button, shown on
/// it so it is learnt by using the button.
/// A chord is a cap per key, joined by "+" (`KeyCaps`).
struct KeyCap: View {
    let caps: KeyCaps
    /// One key ("esc", "↩").
    init(_ key: String) { caps = KeyCaps([.cap(key)]) }
    init(_ chord: KeyChord) { caps = chord.buttonCaps }

    var body: some View {
        KeyCapsView(caps, style: .button)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A button's icon (with its title when `showsTitle`) and the action's
/// first key as set (Settings → Keyboard); none when it has no key.
struct ShortcutLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: ShortcutAction
    var showsTitle = false
    @ObservedObject private var shortcuts = Shortcuts.shared

    init(_ title: LocalizedStringKey, systemImage: String, action: ShortcutAction, showsTitle: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
        self.showsTitle = showsTitle
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsTitle {
                Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
            } else {
                Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            }
            if let key = shortcuts.keys(action).first { KeyCap(key) }
        }
    }
}

/// The volume, shown a moment while ↑ / ↓ change it.
struct VolumeDisplay: View {
    /// How long it stays; UI tests (`--hold-volume-display`, the README
    /// screenshots) keep it long enough to photograph.
    static let shownFor: Duration = TestSwitches.has("--hold-volume-display") ? .seconds(15) : .seconds(1.2)
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        BriefNotice(trigger: model.volumeChange, animation: .easeOut(duration: 0.15)) { _ in
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
            .noticePlate()
            .accessibilityIdentifier("volumeDisplay")
                // The UI tests read "volume 80 %" in every language, as the label
            .accessibilityLabel(test: "volume \(Int((model.volume * 100).rounded())) %", spoken: String(localized: "Volume"))
            .accessibilityValue(test: "", spoken: model.volume.formatted(.percent.precision(.fractionLength(0))))
        }
    }
}

/// What a key just changed (the volume, the speed, a track), shown a
/// moment (`VolumeDisplay.shownFor`); each new `trigger` shows it again.
struct BriefNotice<Trigger: Equatable, Content: View>: View {
    let trigger: Trigger?
    let animation: Animation?
    @ViewBuilder let content: (Trigger) -> Content
    @State private var shown: Trigger?
    @State private var hide: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let shown {
                content(shown).transition(.opacity)
            }
        }
        .animation(animation, value: shown)
        .onChange(of: trigger) { _, new in
            guard let new else { return }
            shown = new
            hide?.cancel()
            hide = Task { @MainActor in
                try? await Task.sleep(for: VolumeDisplay.shownFor)
                guard !Task.isCancelled else { return }
                shown = nil
            }
        }
    }
}

extension View {
    /// The status bar's look, also the bar of a file shown alone.
    func statusBarStyle() -> some View {
        font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
    }

    /// A `BriefNotice`'s plate: material behind it, one element for VoiceOver.
    func noticePlate() -> some View {
        padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
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
                    // A folder granted itself: the folder holding it is asked for first
                    guard model.canRenameCurrentFolder || model.allowRenamingCurrentFolder() else { return }
                    name = current
                    editing = true
                    focused = true
                } label: {
                    Text(verbatim: current).font(.headline).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(model.canRenameCurrentFolder || model.renameNeedsAccess ? Text("Click to rename this folder") : Text(verbatim: current))
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
        BrowserModel.testLog("\(Date().timeIntervalSince1970) drop into the pane")
        TileDrag.loadURLs(info.itemProviders(for: [TileDrag.type])) { urls in
            BrowserModel.testLog("\(Date().timeIntervalSince1970) drop: moving \(urls.count)")
            pane.move(urls, into: folder)
        }
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
        // The UI tests read the mode's name
        .accessibilityValue(test: model.searchMode.rawValue,
                            spoken: model.searchMode == .ignoringCase ? String(localized: "Ignore case")
                                : model.searchMode == .matchingCase ? String(localized: "Match case") : String(localized: "Regular expression"))
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
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        let marked = model.folderURL.map(bookmarks.contains) ?? false
        Menu {
            BookmarkItems(model: model, shortcuts: false)
        } label: {
            Label("Bookmarks", systemImage: marked ? "star.fill" : "star")
        }
        .help(String(localized: "Bookmarks (\(shortcuts.hint(.bookmark)): this folder; \(HelpKeys.range(ShortcutAction.bookmarks).text(shortcuts) ?? String(localized: "no key")): go)"))
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

    /// The zone under the pointer in the window.
    private static func zone(in window: WindowModel, mouseDown: Bool) -> DropZone? {
        guard let appWindow = window.nsWindow ?? BrowserModel.appWindow, let content = appWindow.contentView else { return nil }
        return DropZoneDelegate.zone(atX: appWindow.mouseLocationOutsideOfEventStream.x,
                                     width: content.bounds.width, mouseDown: mouseDown)
    }

    static func update(_ window: WindowModel) {
        peek()
        guard window.active.slideshow == nil else { return }
        window.dropZone = zone(in: window, mouseDown: NSEvent.pressedMouseButtons != 0)
    }

    static func perform(_ info: DropInfo, _ window: WindowModel) -> Bool {
        let target = zone(in: window, mouseDown: true) ?? .browse
        window.dropZone = nil
        DispatchQueue.main.async { window.dropZone = nil }   // once more after AppKit ends the session
        BrowserModel.testLog("\(Date().timeIntervalSince1970) Finder drop onto a pane at \(info.location)")
        return fileURLs(info) { urls in window.active.openDropped(urls, slideshow: target == .slideshow) }
    }

    /// The files dropped, read from the drag pasteboard: while the drag is
    /// over the window (`peek`) and again as it is dropped. On CI (macOS 15)
    /// a Finder drop now and then found the pasteboard written anew during
    /// the drag (its change count two higher than while the files were read
    /// on the way), with the file URL's type but no data for it (neither
    /// from the pasteboard nor from its item provider, NSItemProviderErrorDomain
    /// -1000, nor a second later): the drop did nothing. Then the files read
    /// on the way, during the last `seenFor`, are the ones dropped. The item
    /// providers are the way only when neither has a file URL.
    static func fileURLs(_ info: DropInfo, then open: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        var urls = read(pasteboard)
        let onTheWay = Date().timeIntervalSince(seen.at) < seenFor ? seen.urls : []
        BrowserModel.testLog("\(Date().timeIntervalSince1970) drop: \(urls.map(\.lastPathComponent)) from the drag pasteboard (change \(pasteboard.changeCount)), "
                             + "seen on the way \(onTheWay.map(\.lastPathComponent)) (change \(seen.change))")
        if urls.isEmpty { urls = onTheWay }
        seen = (-1, [], .distantPast)
        if !urls.isEmpty {
            DispatchQueue.main.async { open(urls) }
            return true
        }
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            BrowserModel.testLog("\(Date().timeIntervalSince1970) drop: \(url?.lastPathComponent ?? "no URL, \(String(describing: error))") from its item provider")
            guard let url else { return }
            DispatchQueue.main.async { open([url]) }
        }
        return true
    }

    /// The files of the drag going on, by its pasteboard's change count,
    /// and when they were read.
    @MainActor private static var seen: (change: Int, urls: [URL], at: Date) = (-1, [], .distantPast)
    /// How long the files read on the way stand for a drop without its own:
    /// one drag over the window, not the one before it.
    static let seenFor: TimeInterval = 30

    /// Reads the files of a drag from outside while it is over the window,
    /// once per drag (until it has them), off the main thread: the read waits
    /// for the drag's source to hand the data over.
    @MainActor static func peek() {
        let change = NSPasteboard(name: .drag).changeCount
        guard change != seen.change, change != reading else { return }
        reading = change
        BrowserModel.testLog("\(Date().timeIntervalSince1970) drag over the window: reading its files (change \(change))")
        DispatchQueue.global(qos: .userInitiated).async {
            let pasteboard = NSPasteboard(name: .drag)
            let urls = read(pasteboard), now = pasteboard.changeCount
            DispatchQueue.main.async {
                reading = -1
                guard !urls.isEmpty, now == change else { return }
                seen = (change, urls, Date())
                BrowserModel.testLog("\(Date().timeIntervalSince1970) drag over the window: \(urls.map(\.lastPathComponent)) (change \(change))")
            }
        }
    }

    /// The change count of the drag pasteboard being read (`peek`), -1: none.
    @MainActor private static var reading = -1

    nonisolated private static func read(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

extension WindowModel {
    /// The pane at `x` in a window `width` wide, as the panes are laid out
    /// (the divider where `split` puts it); the active one when it is alone
    /// (a single pane, a slideshow over the window).
    func pane(atX x: CGFloat, width: CGFloat) -> BrowserModel {
        guard dual, active.slideshow == nil, let right else { return active }
        return x >= PaneDivider.leftWidth(total: width, split: split) + PaneDivider.width / 2 ? right : left
    }

    /// A trackpad pinch at `x` in a window `width` wide: the pane under the
    /// fingers takes it (`BrowserModel.pinch`); false: the event goes on.
    func pinch(_ magnification: CGFloat, began: Bool, atX x: CGFloat, width: CGFloat) -> Bool {
        pane(atX: x, width: width).pinch(magnification, began: began)
    }
}

/// The line between the two panes: dragged, it gives one pane more of the
/// window; a double click shares it equally again.
struct PaneDivider: View {
    @ObservedObject var window: WindowModel
    let total: CGFloat
    static let width: CGFloat = 7
    static let space = "panes"

    /// The left pane's width in a window `total` wide: its share (`split`),
    /// each pane keeping room for its toolbar-less grid.
    static func leftWidth(total: CGFloat, split: Double) -> CGFloat {
        let minimum = min(220, total / 3)
        return min(max(total * split, minimum), max(minimum, total - minimum - width))
    }
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Divider()
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { drag in
                    guard total > 0 else { return }
                    window.setSplit(Double(drag.location.x / total))
                }
                .onEnded { _ in window.setSplit(window.split, remember: true) }
        )
        .modifier(Clicks(single: {}, double: { window.setSplit(0.5, remember: true) }))
        .accessibilityElement()
        .accessibilityIdentifier("paneDivider")
        .accessibilityLabel("Divider between the panes")
        .help("Drag to give one pane more room; double-click to share equally")
    }
}

/// Lays its views out in lines, left to right, starting a new line where the
/// next one doesn't fit (the status bar's counts in a narrow pane).
struct StatusFlow: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if !line.indices.isEmpty, needed > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}
