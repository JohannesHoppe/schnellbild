import SwiftUI
import AppKit

@main
struct SchnellbildApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: BrowserModel

    init() {
        let defaults = BrowserModel.makeDefaults()
        // Archive passwords: the login keychain; UI tests keep theirs in
        // their own preferences (`--reset-state` clears them)
        ArchiveStore.shared.passwords = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            ? .defaults(defaults) : .keychain()
        MediaData.removeOldCopies()
        _model = StateObject(wrappedValue: BrowserModel(defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
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
                Button("Rename… (F2)") { model.beginRename() }
                    .disabled(model.slideshow != nil || model.showHelp || !model.selectionIsChangeable)
                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.slideshow != nil)
                Button("Open with Default App") { model.openInDefaultApp() }
                    .keyboardShortcut(.return)
                    .disabled(model.slideshow != nil || !model.selectionIsChangeable)
                Divider()
                Button("Move to Trash…") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete)
                    .disabled(model.slideshow != nil || !model.selectionIsChangeable)
            }
            CommandGroup(after: .toolbar) {
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
