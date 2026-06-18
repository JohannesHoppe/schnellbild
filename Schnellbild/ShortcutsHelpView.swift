import SwiftUI

/// The keyboard-shortcut cheat sheet, shown via F1 or the "Schnellbild Help"
/// menu item.
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }
    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let shortcuts: [Shortcut]
    }

    private let groups: [Group] = [
        Group(title: "Grid", shortcuts: [
            Shortcut(keys: "← →", action: "Previous / next item"),
            Shortcut(keys: "↑ ↓", action: "One row up / down"),
            Shortcut(keys: "Return / Space", action: "Open image, or enter folder"),
            Shortcut(keys: "Backspace", action: "Up one folder level"),
            Shortcut(keys: "Home / End", action: "First / last item"),
            Shortcut(keys: "⌘+ / ⌘−", action: "Larger / smaller thumbnails"),
        ]),
        Group(title: "Full view", shortcuts: [
            Shortcut(keys: "← → ↑ ↓", action: "Previous / next item"),
            Shortcut(keys: "Space", action: "Next image · play/pause video"),
            Shortcut(keys: "⌘← / ⌘→", action: "Video: seek −10 s / +10 s"),
            Shortcut(keys: "+ / −", action: "Zoom in / out"),
            Shortcut(keys: "0 / 1", action: "Fit to window / 100 %"),
            Shortcut(keys: "[ / ]", action: "Rotate left / right"),
            Shortcut(keys: "i", action: "File info"),
            Shortcut(keys: "s", action: "Slideshow"),
            Shortcut(keys: "Esc / Backspace / Return", action: "Back to grid"),
        ]),
        Group(title: "Anywhere", shortcuts: [
            Shortcut(keys: "f", action: "Toggle full screen"),
            Shortcut(keys: "⌘F", action: "Search (This Folder / Subfolders)"),
            Shortcut(keys: "⌘O", action: "Open folder"),
            Shortcut(keys: "⇧⌘R", action: "Reveal in Finder"),
            Shortcut(keys: "⌘↩", action: "Open with default app"),
            Shortcut(keys: "⌘⌫", action: "Move to Trash"),
            Shortcut(keys: "F1 / ⌘?", action: "Show this list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(group.shortcuts) { shortcut in
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(shortcut.keys)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(width: 180, alignment: .leading)
                                    Text(shortcut.action)
                                        .font(.callout)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 580)
    }
}
