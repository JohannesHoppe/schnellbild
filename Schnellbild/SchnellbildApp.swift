import SwiftUI
import AppKit

@main
struct SchnellbildApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// One window of one or two panes; menus act on the active pane.
    @StateObject private var window: WindowModel
    private var model: BrowserModel { window.active }

    init() {
        let defaults = BrowserModel.makeDefaults()
        // Archive passwords: the login keychain; UI tests keep theirs in
        // their own preferences (`--reset-state` clears them)
        ArchiveStore.shared.passwords = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            ? .defaults(defaults) : .keychain()
        let left = BrowserModel(defaults: defaults)
        _window = StateObject(wrappedValue: WindowModel(left: left, defaults: defaults) {
            BrowserModel(defaults: defaults, settingsPrefix: "rightPane.")
        })
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(window)
                // As narrow as the toolbar keeps all its items (the full view's included)
                .frame(minWidth: 800, minHeight: 520)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Schnellbild") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Go") {
                Button("Start Slideshow (S)") { model.startSlideshow() }
                    .disabled(model.folderURL == nil || model.anySheetOpen)
                Divider()
                Button("Back") { model.navigateBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack || model.anySheetOpen)
                Button("Forward") { model.navigateForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward || model.anySheetOpen)
                Button("Enclosing Folder") { model.goToParentFolder() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp || model.anySheetOpen)
                Divider()
                Button("Search") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.anySheetOpen)
            }
            CommandMenu("Actions") {
                // Not during a slideshow: the selection is in the hidden grid,
                // not what's on screen.
                Button("New Folder") { model.beginNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.canCreateFolder)
                Button("Rename… (F2)") { model.beginRename() }
                    .disabled(model.slideshow != nil || model.anySheetOpen || !(model.selectedEntry.map(model.canRename) ?? false))
                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.slideshow != nil || model.anySheetOpen)
                Button("Open with Default App") { model.openInDefaultApp() }
                    .keyboardShortcut(.return)
                    .disabled(model.slideshow != nil || model.anySheetOpen || !model.selectionIsChangeable)
                Divider()
                // The dual pane (D): the marked items into the other pane's folder
                Button("Copy to Other Pane (F5)") { _ = window.sendToOtherPane(how: .copy) }
                    .disabled(!window.dual || model.slideshow != nil || model.anySheetOpen)
                Button("Move to Other Pane (F6)") { _ = window.sendToOtherPane(how: .move) }
                    .disabled(!window.dual || model.slideshow != nil || model.anySheetOpen)
                Divider()
                Button("Move to Trash…") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete)
                    .disabled(!model.canTrash || model.anySheetOpen)
            }
            CommandGroup(after: .toolbar) {
                Toggle("as Grid", isOn: Binding(get: { model.viewMode == .grid }, set: { if $0 { model.viewMode = .grid } }))
                Toggle("as List", isOn: Binding(get: { model.viewMode == .list }, set: { if $0 { model.viewMode = .list } }))
                Divider()
                Toggle("Dual Pane (D)", isOn: Binding(get: { window.dual }, set: { window.setDual($0) }))
                    // As the key: not during a slideshow, not over a sheet (of either pane)
                    .disabled(window.panes.contains { $0.slideshow != nil || $0.anySheetOpen })
                Toggle("Mini Keyboard (K)", isOn: Binding(get: { model.showMiniKeyboard }, set: { model.showMiniKeyboard = $0 }))
                Divider()
                Button("Larger Thumbnails (⌘+)") { model.growThumbnails() }
                Button("Smaller Thumbnails (⌘−)") { model.shrinkThumbnails() }
                Divider()
                SortChoices(model: model, shortcuts: true)
            }
            CommandGroup(replacing: .help) {
                Button("Schnellbild Help") { model.openHelp() }
                    .keyboardShortcut("?", modifiers: .command)
                    .disabled(model.otherSheetOpen)
            }
        }
    }
}

/// Without a `.app` bundle, a SwiftPM executable otherwise launches as a
/// background process with no window focus. This turns it into a normal
/// foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
