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
                .frame(minWidth: 720, minHeight: 520)
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
                    .disabled(model.folderURL == nil)
                Divider()
                Button("Back") { model.navigateBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("Forward") { model.navigateForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                Button("Enclosing Folder") { model.goToParentFolder() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Divider()
                Button("Search") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Actions") {
                // Not during a slideshow: the selection is in the hidden grid,
                // not what's on screen.
                Button("New Folder") { model.beginNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.canCreateFolder)
                Button("Rename… (F2)") { model.beginRename() }
                    .disabled(model.slideshow != nil || model.showHelp || !model.selectionIsChangeable)
                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.slideshow != nil)
                Button("Open with Default App") { model.openInDefaultApp() }
                    .keyboardShortcut(.return)
                    .disabled(model.slideshow != nil || !model.selectionIsChangeable)
                Divider()
                // The dual pane (D): the marked items into the other pane's folder
                Button("Copy to Other Pane (F5)") { _ = window.sendToOtherPane(how: .copy) }
                    .disabled(!window.dual || model.slideshow != nil)
                Button("Move to Other Pane (F6)") { _ = window.sendToOtherPane(how: .move) }
                    .disabled(!window.dual || model.slideshow != nil)
                Divider()
                Button("Move to Trash…") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete)
                    .disabled(model.slideshow != nil || !model.selectionIsChangeable)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Dual Pane (D)", isOn: Binding(get: { window.dual }, set: { window.setDual($0) }))
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
                    .disabled(model.renameTarget != nil)
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
}
