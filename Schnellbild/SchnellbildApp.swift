import SwiftUI
import OfflineMap
import AppKit
import MediaToolbox
import VideoToolbox
import VLCFrames

@main
struct SchnellbildApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The first window of one or two panes (more with ⌘N, each its own
    /// `WindowModel`); menus act on the active pane of the window in front.
    @StateObject private var first: WindowModel
    @StateObject private var focus = WindowFocus.shared
    /// The keys the menu items show and answer to (Settings → Keyboard).
    @StateObject private var shortcuts = Shortcuts.shared
    private let defaults: UserDefaults
    private var window: WindowModel { focus.current ?? first }
    private var model: BrowserModel { window.active }
    /// Off while another window of the app (Settings, About) has the keys:
    /// the menu items acting on a browser window are disabled then, so a key
    /// typed there (⌘⌫ in a search field) never reaches the window behind it.
    private var away: Bool { !focus.browserInFront }

    init() {
        // Before anything starts VLC
        VLCSafety.forgetInjectedOptions()
        _ = VLCPlaybackControl.testLog
        // UI tests: the map and the globe as with Reduce motion on (`--reduce-motion`) or off
        if TestSwitches.on { MapMotion.reduceOverride = TestSwitches.has("--reduce-motion") }
        MainThreadWatch.start()
        // Media Extensions the user has turned on in System Settings (format
        // readers and video decoders, Apple's own for ProRes RAW too, or
        // another app's for MKV, AVI …) open those videos in AVKit, and
        // Quick Look makes the grid's thumbnails with them (macOS 26), but
        // only for an app that opts in, as Finder does:
        // https://github.com/Marginal/QuickLookVideo/issues/191,
        // https://github.com/Marginal/QuickLookVideo/issues/197.
        // Each extension runs in a sandboxed process of its own, outside the app.
        // Before AVFoundation or Quick Look is first asked.
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        let defaults = BrowserModel.makeDefaults()
        self.defaults = defaults
        AppAppearance.defaults = defaults
        // The folders opened to the app before (App Sandbox), before any is read
        FolderAccess.shared.defaults = defaults
        FolderAccess.shared.restore()
        // Archive passwords: the login keychain; UI tests keep theirs in
        // their own preferences (`--reset-state` clears them)
        ArchiveStore.shared.passwords = TestSwitches.on
            ? .defaults(defaults) : .keychain()
        // Each pane watches the folder it shows for changes outside the app;
        // volumes coming and going and the app turning active reach them too
        BrowserModel.watchFoldersByDefault = true
        DiskEvents.start()
        VideoBarPlacement.shared.use(defaults)
        // The Inspector's map and place names, from the map data the app carries
        OfflineGeography.provider = BundledGeography.make()
        let left = BrowserModel(defaults: defaults)
        _first = StateObject(wrappedValue: WindowModel(left: left, defaults: defaults) {
            BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        })
    }

    var body: some Scene {
        WindowGroup(id: "browser") {
            WindowRoot(first: first, defaults: defaults)
        }
        // Files from the Finder open in the window in front (`OpenedFiles`),
        // never in a window of their own
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Schnellbild") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
                Button("Open Folder…") { model.chooseFolder() }
                    .keyboardShortcut(shortcuts.menuShortcut(.openFolder))
                    .disabled(window.anySheetOpen || model.presenting || away)
            }
            CommandGroup(replacing: .undoRedo) {
                UndoCommands(history: model.undoHistory, window: window, model: model)
                    .disabled(away)
            }
            CommandMenu("Go") {
                Group {
                    Button("Start Slideshow") { model.startSlideshow() }
                        .keyboardShortcut(shortcuts.menuShortcut(.startSlideshow))
                        .disabled(model.folderURL == nil || window.anySheetOpen)
                    Divider()
                    Button("Back") { model.navigateBack() }
                        .keyboardShortcut(shortcuts.menuShortcut(.back))
                        .disabled(!model.canGoBack || window.anySheetOpen)
                    Button("Forward") { model.navigateForward() }
                        .keyboardShortcut(shortcuts.menuShortcut(.forward))
                        .disabled(!model.canGoForward || window.anySheetOpen)
                    Button("Enclosing Folder") { model.goToParentFolder() }
                        .keyboardShortcut(shortcuts.menuShortcut(.enclosingFolder))
                        .disabled(!model.canGoUp || window.anySheetOpen)
                    Divider()
                    // (not in a slideshow or the tour: the search bar is hidden there)
                    Button("Search") { model.focusSearch() }
                        .keyboardShortcut(shortcuts.menuShortcut(.search))
                        .disabled(window.anySheetOpen || model.presenting)
                }
                .disabled(away)
            }
            CommandMenu("Video") {
                VideoCommands(model: model, window: window, shortcuts: shortcuts)
                    .disabled(away)
            }
            CommandMenu("Bookmarks") {
                BookmarkItems(model: model, shortcuts: true)
                    .disabled(window.anySheetOpen || model.presenting || away)
            }
            CommandMenu("Actions") {
                Group {
                    // Not during a slideshow or the tour: the selection is in the
                    // hidden grid, not what's on screen.
                    Button("New Folder") { model.beginNewFolder() }
                        .keyboardShortcut(shortcuts.menuShortcut(.newFolder))
                        .disabled(!model.canCreateFolder)
                    Button("Rename…") { model.beginRename() }
                        .keyboardShortcut(shortcuts.menuShortcut(.gridRename))
                        .disabled(model.presenting || window.anySheetOpen || !(model.selectedEntry.map(model.canRename) ?? false))
                    // The Inspector, as the Finder's ⌘I (also I without ⌘)
                    Button("Get Info") { model.showInspector.toggle() }
                        .keyboardShortcut(shortcuts.menuShortcut(.info))
                        .disabled(model.folderURL == nil || window.anySheetOpen)
                    Button("Reveal in Finder") { model.revealInFinder() }
                        .keyboardShortcut(shortcuts.menuShortcut(.reveal))
                        .disabled(model.presenting || window.anySheetOpen)
                    Button("Open with Default App") { model.openInDefaultApp() }
                        .keyboardShortcut(shortcuts.menuShortcut(.openDefault))
                        .disabled(model.presenting || window.anySheetOpen || !model.selectionIsChangeable)
                    Divider()
                    // The dual pane (D): the marked items into the other pane's folder
                    // (also F5 / F6, as in Norton Commander)
                    Button("Copy to Other Pane") { _ = window.sendToOtherPane(how: .copy) }
                        .keyboardShortcut(shortcuts.menuShortcut(.copyToOther))
                        .disabled(!window.dual || model.presenting || window.anySheetOpen)
                    Button("Move to Other Pane") { _ = window.sendToOtherPane(how: .move) }
                        .keyboardShortcut(shortcuts.menuShortcut(.moveToOther))
                        .disabled(!window.dual || model.presenting || window.anySheetOpen)
                    Divider()
                    Button("Move to Trash…") { model.moveSelectionToTrash() }
                        .keyboardShortcut(shortcuts.menuShortcut(.trash))
                        .disabled(!model.canTrash || window.anySheetOpen)
                }
                .disabled(away)
            }
            CommandGroup(after: .toolbar) {
                Group {
                    // The folder read again: changes outside the app show by
                    // themselves where the system reports them (not on every share)
                    Button("Reload") { model.reload() }
                        .keyboardShortcut(shortcuts.menuShortcut(.reload))
                        .disabled(model.folderURL == nil || model.isLoading || model.presenting || window.anySheetOpen)
                    Divider()
                    // (as the views' key: not during a slideshow or the tour)
                    Toggle("as Grid", isOn: Binding(get: { model.viewMode == .grid }, set: { if $0 { model.viewMode = .grid } }))
                        .disabled(model.presenting)
                    Toggle("as List", isOn: Binding(get: { model.viewMode == .list }, set: { if $0 { model.viewMode = .list } }))
                        .disabled(model.presenting)
                    Toggle("as Atlas", isOn: Binding(get: { model.viewMode == .atlas }, set: { if $0 { model.viewMode = .atlas } }))
                        .disabled(model.folderURL == nil || model.presenting)
                    Button("Play Tour") { model.startTour() }
                        .keyboardShortcut(shortcuts.menuShortcut(.startTour))
                        .disabled(model.folderURL == nil || model.mode != .grid || model.presenting || window.anySheetOpen)
                    Divider()
                    Toggle("Dual Pane", isOn: Binding(get: { window.dual }, set: { window.setDual($0) }))
                        // As the key: not during a slideshow, not over a sheet (of either pane)
                        .disabled(window.panes.contains { $0.slideshow != nil || $0.anySheetOpen })
                    Toggle("Mini Keyboard", isOn: Binding(get: { model.showMiniKeyboard }, set: { model.showMiniKeyboard = $0 }))
                }
                .disabled(away)
                // As in the Finder (⇧⌘.); also in Settings → General: app-wide
                Toggle("Show Hidden Files", isOn: Binding(get: { window.showHiddenFiles }, set: { window.showHiddenFiles = $0 }))
                    .keyboardShortcut(shortcuts.menuShortcut(.hiddenFiles))
                    .disabled(window.anySheetOpen)
                Divider()
                Group {
                    // (the key monitor takes ⌘+ / ⌘− first: in the full view they zoom)
                    Button("Larger Thumbnails") { model.growThumbnails() }
                        .keyboardShortcut(shortcuts.menuShortcut(.largerThumbnails))
                    Button("Smaller Thumbnails") { model.shrinkThumbnails() }
                        .keyboardShortcut(shortcuts.menuShortcut(.smallerThumbnails))
                    Divider()
                    SortChoices(model: model, shortcuts: true)
                        .disabled(model.presenting)
                }
                .disabled(away)
            }
            CommandGroup(replacing: .help) {
                Button("Schnellbild Help") { window.openHelp() }
                    .keyboardShortcut(shortcuts.menuShortcut(.help))
                    .disabled(window.anySheetOpen || away)
                if KeyGlyphsTestMenu.shown {
                    Divider()
                    KeyGlyphsTestMenu()
                }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(window)
        }
    }
}

/// One window: its own model (the first window's while no other window
/// shows that one), tied to its AppKit window.
struct WindowRoot: View {
    @StateObject private var window: WindowModel
    @Environment(\.openWindow) private var openWindow

    init(first: WindowModel, defaults: UserDefaults) {
        _window = StateObject(wrappedValue: WindowModel.claim(first, defaults: defaults))
    }

    var body: some View {
        ContentView()
            .environmentObject(window)
            // As narrow as the toolbar keeps all its items (the full view's included)
            .frame(minWidth: 800, minHeight: 520)
            .background(WindowAttach(window: window))
            // A key set for New Window opens one as the menu item does
            .onAppear { WindowOpener.open = { [openWindow] in openWindow(id: "browser") } }
    }
}

/// File → New Window (⌘N): another window, e.g. for another display.
struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var shortcuts = Shortcuts.shared

    var body: some View {
        Button("New Window") { openWindow(id: "browser") }
            .keyboardShortcut(shortcuts.menuShortcut(.newWindow))
    }
}

/// Without a `.app` bundle, a SwiftPM executable otherwise launches as a
/// background process with no window focus. This turns it into a normal
/// foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Light or dark as chosen in Settings, before the first window shows.
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Windows, no tabs: a tab of its own is a new window anyway (⌘N)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Files opened with Schnellbild from the Finder (Open With, a double
    /// click where it is the default app, a drop onto the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenedFiles.open(urls.filter(\.isFileURL)) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserModel.confirmRestore(in: BrowserModel.makeDefaults())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Hidden by the boss key: a click on the Dock icon brings the app
    /// forward with every window still invisible (only the boss key three
    /// times shows them).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard BossKey.engaged else { return true }
            BossKey.broughtForward()
            return false
        }
    }

    /// Not in the middle of a copy or move: the app quits once it is done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard BrowserModel.transfersUnderWay > 0 else { return .terminateNow }
        guard NSAlert.confirm(String(localized: "Copying or moving is still under way."),
                              detail: String(localized: "Schnellbild quits once it is done. Quitting now would leave files half copied."),
                              yes: String(localized: "Quit When Done")) else { return .terminateCancel }
        // Done while the alert was open
        guard BrowserModel.transfersUnderWay > 0 else { return .terminateNow }
        BrowserModel.onTransfersDone = { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// Files the Finder opens with Schnellbild (`AppDelegate.application(_:open:)`):
/// shown as a drop onto the window shows them (`BrowserModel.openDropped`:
/// a picture or video in the full view, inside its folder, a folder or
/// archive opened), in the window in front. Opened at launch, before a
/// window has started, they wait for it and open instead of the last folder
/// (`take`).
@MainActor
enum OpenedFiles {
    /// A window has started (its folder or these files opened).
    private static var launched = false
    private static var waiting: [URL] = []

    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard launched, let window = WindowModel.current else { waiting = urls; return }
        NSApp.activate(ignoringOtherApps: true)
        window.nsWindow?.makeKeyAndOrderFront(nil)
        window.active.openDropped(urls)
    }

    /// At the first window's start: the files that came before it, opened
    /// in `model`; false when none came.
    static func take(into model: BrowserModel) -> Bool {
        let urls = waiting
        waiting = []
        guard !urls.isEmpty else { return false }
        model.openDropped(urls)
        return true
    }

    /// A window has started: files from now on open at once, and any that
    /// came meanwhile open in it.
    static func started(_ window: WindowModel) {
        launched = true
        if !waiting.isEmpty { open(waiting) }
    }
}

/// The Video menu: subtitles, audio track and speed of the video on screen
/// (keys without ⌘ or ⌃, such as V, < and >, are taught by F1 and the mini
/// keyboard; ⌃⌘S, ⌃⌘A as in IINA).
struct VideoCommands: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var window: WindowModel
    @ObservedObject var shortcuts: Shortcuts

    var body: some View {
        let off = model.shownMediaEntry?.kind != .video || window.anySheetOpen
        Group {
            Toggle("Show Subtitles", isOn: Binding(get: { model.showSubtitles }, set: { _ in model.toggleSubtitles() }))
                .keyboardShortcut(shortcuts.menuShortcut(.subtitles))
            Button("Next Subtitle Track") { model.nextSubtitleTrack() }
                .keyboardShortcut(shortcuts.menuShortcut(.nextSubtitle))
            Menu("Subtitles") { VideoMenus.subtitlePicker(model) }
                .disabled(model.videoTracks.subtitles.isEmpty)
            Divider()
            Button("Next Audio Track") { model.nextAudioTrack() }
                .keyboardShortcut(shortcuts.menuShortcut(.nextAudio))
            Menu("Audio Track") { VideoMenus.audioPicker(model) }
                .disabled(model.videoTracks.audio.count < 2)
            Divider()
            Button("Faster") { model.changeSpeed(by: +1) }
                .keyboardShortcut(shortcuts.menuShortcut(.faster))
            Button("Slower") { model.changeSpeed(by: -1) }
                .keyboardShortcut(shortcuts.menuShortcut(.slower))
            Button("Normal Speed") { model.setSpeed(1) }
                .keyboardShortcut(shortcuts.menuShortcut(.normalSpeed))
            Menu("Speed") { VideoMenus.speedPicker(model) }
            Divider()
            Button("Reset Control Bar Position") { model.resetVideoBarPosition() }
        }
        .disabled(off)
    }
}
