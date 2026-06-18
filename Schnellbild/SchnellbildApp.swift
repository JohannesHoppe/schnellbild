import SwiftUI
import AppKit

@main
struct SchnellbildApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BrowserModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Actions") {
                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open with Default App") { model.openInDefaultApp() }
                    .keyboardShortcut(.return)
                Divider()
                Button("Move to Trash…") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete)
            }
            CommandMenu("View") {
                Button("Larger Thumbnails (⌘+)") { model.growThumbnails() }
                Button("Smaller Thumbnails (⌘−)") { model.shrinkThumbnails() }
                Divider()
                Button("Sort by Name")  { model.setSort(.name) }
                Button("Sort by Date") { model.setSort(.date) }
                Button("Sort by Size") { model.setSort(.size) }
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
