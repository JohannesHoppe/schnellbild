import SwiftUI
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
    private let defaults: UserDefaults
    private var window: WindowModel { focus.current ?? first }
    private var model: BrowserModel { window.active }

    init() {
        // Before anything starts VLC
        VLCSafety.forgetInjectedOptions()
        // Media Extensions the user has turned on in System Settings (format
        // readers and video decoders, Apple's own for ProRes RAW too, or
        // another app's for MKV, AVI …) open those videos in AVKit, and
        // Quick Look makes the grid's thumbnails with them (macOS 26) — but
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
        ArchiveStore.shared.passwords = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            ? .defaults(defaults) : .keychain()
        // Each pane watches the folder it shows for changes outside the app;
        // volumes coming and going and the app turning active reach them too
        BrowserModel.watchFoldersByDefault = true
        DiskEvents.start()
        let left = BrowserModel(defaults: defaults)
        _first = StateObject(wrappedValue: WindowModel(left: left, defaults: defaults) {
            BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        })
    }

    var body: some Scene {
        WindowGroup(id: "browser") {
            WindowRoot(first: first, defaults: defaults)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Schnellbild") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
                Button("Open Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(window.anySheetOpen)
            }
            CommandMenu("Go") {
                Button("Start Slideshow") { model.startSlideshow() }
                    .disabled(model.folderURL == nil || window.anySheetOpen)
                Divider()
                Button("Back") { model.navigateBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack || window.anySheetOpen)
                Button("Forward") { model.navigateForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward || window.anySheetOpen)
                Button("Enclosing Folder") { model.goToParentFolder() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp || window.anySheetOpen)
                Divider()
                // (not in a slideshow: the search bar is hidden there)
                Button("Search") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(window.anySheetOpen || model.slideshow != nil)
            }
            CommandMenu("Bookmarks") {
                BookmarkItems(model: model, shortcuts: true)
                    .disabled(window.anySheetOpen || model.slideshow != nil)
            }
            CommandMenu("Actions") {
                // Not during a slideshow: the selection is in the hidden grid,
                // not what's on screen.
                Button("New Folder") { model.beginNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.canCreateFolder)
                Button("Rename…") { model.beginRename() }
                    .disabled(model.slideshow != nil || window.anySheetOpen || !(model.selectedEntry.map(model.canRename) ?? false))
                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.slideshow != nil || window.anySheetOpen)
                Button("Open with Default App") { model.openInDefaultApp() }
                    .keyboardShortcut(.return)
                    .disabled(model.slideshow != nil || window.anySheetOpen || !model.selectionIsChangeable)
                Divider()
                // The dual pane (D): the marked items into the other pane's folder
                // (also F5 / F6, as in Norton Commander)
                Button("Copy to Other Pane") { _ = window.sendToOtherPane(how: .copy) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!window.dual || model.slideshow != nil || window.anySheetOpen)
                Button("Move to Other Pane") { _ = window.sendToOtherPane(how: .move) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!window.dual || model.slideshow != nil || window.anySheetOpen)
                Divider()
                Button("Move to Trash…") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete)
                    .disabled(!model.canTrash || window.anySheetOpen)
            }
            CommandGroup(after: .toolbar) {
                // The folder read again: changes outside the app show by
                // themselves where the system reports them (not on every share)
                Button("Reload") { model.reload() }
                    .keyboardShortcut("r")
                    .disabled(model.folderURL == nil || model.isLoading || model.slideshow != nil || window.anySheetOpen)
                Divider()
                Toggle("as Grid", isOn: Binding(get: { model.viewMode == .grid }, set: { if $0 { model.viewMode = .grid } }))
                Toggle("as List", isOn: Binding(get: { model.viewMode == .list }, set: { if $0 { model.viewMode = .list } }))
                Divider()
                Toggle("Dual Pane", isOn: Binding(get: { window.dual }, set: { window.setDual($0) }))
                    // As the key: not during a slideshow, not over a sheet (of either pane)
                    .disabled(window.panes.contains { $0.slideshow != nil || $0.anySheetOpen })
                Toggle("Mini Keyboard", isOn: Binding(get: { model.showMiniKeyboard }, set: { model.showMiniKeyboard = $0 }))
                Divider()
                // (the key monitor takes ⌘+ / ⌘− first: in the full view they zoom)
                Button("Larger Thumbnails") { model.growThumbnails() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Thumbnails") { model.shrinkThumbnails() }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                SortChoices(model: model, shortcuts: true)
            }
            CommandGroup(replacing: .help) {
                Button("Schnellbild Help") { model.openHelp() }
                    .keyboardShortcut("?", modifiers: .command)
                    .disabled(model.otherSheetOpen)
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

    init(first: WindowModel, defaults: UserDefaults) {
        _window = StateObject(wrappedValue: WindowModel.claim(first, defaults: defaults))
    }

    var body: some View {
        ContentView()
            .environmentObject(window)
            // As narrow as the toolbar keeps all its items (the full view's included)
            .frame(minWidth: 800, minHeight: 520)
            .background(WindowAttach(window: window))
    }
}

/// File → New Window (⌘N): another window, e.g. for another display.
struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") { openWindow(id: "browser") }
            .keyboardShortcut("n")
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

    func applicationWillTerminate(_ notification: Notification) {
        BrowserModel.confirmRestore(in: BrowserModel.makeDefaults())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Hidden by the boss key: a click on the Dock icon brings every window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard BossKey.engaged else { return true }
        MainActor.assumeIsolated { BossKey.release() }
        return false
    }

    /// Not in the middle of a copy or move: the app quits once it is done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard BrowserModel.transfersUnderWay > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Copying or moving is still under way.")
        alert.informativeText = String(localized: "Schnellbild quits once it is done. Quitting now would leave files half copied.")
        alert.addButton(withTitle: String(localized: "Quit When Done"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // Done while the alert was open
        guard BrowserModel.transfersUnderWay > 0 else { return .terminateNow }
        BrowserModel.onTransfersDone = { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
