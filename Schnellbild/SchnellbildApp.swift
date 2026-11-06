import SwiftUI
import AppKit

@main
struct SchnellbildApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BrowserModel(defaults: BrowserModel.makeDefaults())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
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
                Button("Rename… (F2)") { model.beginRename() }
                    .disabled(model.selectedEntry == nil || model.selectedEntry?.kind == .parent)
                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open with Default App") { model.openInDefaultApp() }
                    .keyboardShortcut(.return)
                Divider()
                Button("Move to Trash…") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete)
            }
            CommandGroup(after: .toolbar) {
                Button("Larger Thumbnails (⌘+)") { model.growThumbnails() }
                Button("Smaller Thumbnails (⌘−)") { model.shrinkThumbnails() }
                Divider()
                SortChoices(model: model, shortcuts: true)
            }
            CommandGroup(replacing: .help) {
                Button("Schnellbild Help") { model.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
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
