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
            Shortcut(keys: "F2", action: "Rename the selected folder or file (also in the full view)"),
            Shortcut(keys: "Esc", action: "Clear search"),
        ]),
        Group(title: "Full view", shortcuts: [
            Shortcut(keys: "← →", action: "Previous / next image · video: skip a tenth back / ahead, then on to the previous / next item"),
            Shortcut(keys: "⌘← ⌘→ ↑ ↓", action: "Previous / next item, also from a video"),
            Shortcut(keys: "Space", action: "Next image · play/pause video"),
            Shortcut(keys: "+ / −", action: "Zoom in / out"),
            Shortcut(keys: "0 / 1", action: "Fit to window / 100 %"),
            Shortcut(keys: "[ / ]", action: "Rotate left / right"),
            Shortcut(keys: "i", action: "File info"),
            Shortcut(keys: "e", action: "Auto enhance on / off (exposure, contrast, saturation, sharpness; files stay untouched)"),
            Shortcut(keys: "a", action: "Sliders: adjust by hand (switches auto enhance off)"),
            Shortcut(keys: "Esc / Backspace / Return", action: "Back to grid"),
        ]),
        Group(title: "Slideshow", shortcuts: [
            Shortcut(keys: "s", action: "Start: everything in this folder and its subfolders (while searching: the results)"),
            Shortcut(keys: "Space", action: "Pause / resume"),
            Shortcut(keys: "← →", action: "Previous / next · video: skip a tenth"),
            Shortcut(keys: "⌘← ⌘→ ↑ ↓", action: "Previous / next item"),
            Shortcut(keys: "Esc / s", action: "End the slideshow"),
        ]),
        Group(title: "Search field", shortcuts: [
            Shortcut(keys: "⌘F", action: "Search folder and file names (incl. subfolders)"),
            Shortcut(keys: "↓", action: "Move into the results"),
            Shortcut(keys: "Return", action: "Open the selected result"),
            Shortcut(keys: "Esc", action: "Clear · leave the field"),
        ]),
        Group(title: "Anywhere", shortcuts: [
            Shortcut(keys: "⌘[ / ⌘]", action: "Back / forward (history)"),
            Shortcut(keys: "⌘↑", action: "Enclosing folder"),
            Shortcut(keys: "⌘1 … ⌘5", action: "Sort by name, kind, date modified, date taken, size (again: reverse)"),
            Shortcut(keys: "f", action: "Toggle full screen"),
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
        .frame(width: 520, height: 580)
    }
}
