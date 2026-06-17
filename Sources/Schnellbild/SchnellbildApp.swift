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
                Button("Ordner öffnen…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Aktionen") {
                Button("Im Finder zeigen") { model.revealInFinder() }
                    .keyboardShortcut("r")
                Button("Mit Standard-App öffnen") { model.openInDefaultApp() }
                    .keyboardShortcut(.return)
                Divider()
                Button("In den Papierkorb…") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete)
            }
            CommandMenu("Ansicht") {
                Button("Thumbnails größer") { model.growThumbnails() }
                    .keyboardShortcut("+")
                Button("Thumbnails kleiner") { model.shrinkThumbnails() }
                    .keyboardShortcut("-")
                Divider()
                Button("Nach Name sortieren")  { model.setSort(.name) }
                Button("Nach Datum sortieren") { model.setSort(.date) }
                Button("Nach Größe sortieren") { model.setSort(.size) }
            }
        }
    }
}

/// Ohne `.app`-Bundle startet ein SwiftPM-Executable sonst als Hintergrund-
/// prozess ohne Fenster-Fokus. Das macht daraus eine normale Vordergrund-App.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
