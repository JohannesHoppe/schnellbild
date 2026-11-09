import SwiftUI

/// The keyboard-shortcut cheat sheet, shown via F1 or the "Schnellbild Help"
/// menu item.
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let id = UUID()
        /// Key glyphs and key names, shown as they are.
        let keys: String
        let action: LocalizedStringKey
    }
    private struct Group: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let shortcuts: [Shortcut]
    }

    private let groups: [Group] = [
        Group(title: "Grid", shortcuts: [
            Shortcut(keys: "← →", action: "Previous / next item"),
            Shortcut(keys: "↑ ↓", action: "One row up / down"),
            Shortcut(keys: "Return / Space / F3", action: "Open picture or video · open folder or archive"),
            Shortcut(keys: "Backspace", action: "Back (where you were, also a search); without history the enclosing folder"),
            Shortcut(keys: "Home / End", action: "First / last item"),
            Shortcut(keys: "L", action: "Grid or list (a click on a column sorts by it)"),
            Shortcut(keys: "⌘+ / ⌘−", action: "Larger / smaller thumbnails"),
            Shortcut(keys: "F2 / ⇧F6", action: "Rename the selected folder or file (also in the full view)"),
            Shortcut(keys: "Esc", action: "Clear search"),
        ]),
        Group(title: "Full view", shortcuts: [
            Shortcut(keys: "← →", action: "Pictures: previous / next · Videos: 10 % of the length back / ahead; at the start / end: previous / next item"),
            Shortcut(keys: "⌘← ⌘→", action: "Previous / next item, also from a video"),
            Shortcut(keys: "↑ ↓", action: "Pictures zoomed in: look further up / down · Videos: volume up / down (remembered)"),
            Shortcut(keys: "⇧← ⇧→", action: "Video: 1 % of the length back / ahead"),
            Shortcut(keys: "Space", action: "Next picture · play/pause video"),
            Shortcut(keys: "+ / −", action: "Zoom in / out"),
            Shortcut(keys: "0 / 1", action: "Fit to window / 100 %"),
            Shortcut(keys: "[ / ]", action: "Rotate left / right"),
            Shortcut(keys: "i", action: "File info"),
            Shortcut(keys: "e", action: "Auto enhance on / off (exposure, contrast, saturation, sharpness; files are not changed)"),
            Shortcut(keys: "a", action: "Sliders: adjust by hand (switches auto enhance off)"),
            Shortcut(keys: "Esc / Backspace / Return", action: "Back to grid"),
        ]),
        Group(title: "Slideshow", shortcuts: [
            Shortcut(keys: "s", action: "Start: all pictures and videos in this folder and its subfolders (while searching: the results)"),
            Shortcut(keys: "Space", action: "Pause / resume"),
            Shortcut(keys: "← →", action: "Previous / next · Videos: 10 % of the length back / ahead"),
            Shortcut(keys: "⇧← ⇧→", action: "Video: 1 % of the length back / ahead"),
            Shortcut(keys: "⌘← ⌘→", action: "Previous / next item"),
            Shortcut(keys: "↑ ↓", action: "Pictures zoomed in: look further up / down · Videos: volume up / down (remembered)"),
            Shortcut(keys: "f", action: "Toggle full screen"),
            Shortcut(keys: "i", action: "File info"),
            Shortcut(keys: "e", action: "Auto enhance on / off (exposure, contrast, saturation, sharpness; files are not changed)"),
            Shortcut(keys: "a", action: "Sliders: adjust by hand (switches auto enhance off)"),
            Shortcut(keys: "Esc / s", action: "End the slideshow"),
        ]),
        Group(title: "Dual pane and marking", shortcuts: [
            Shortcut(keys: "D / ⌃O", action: "Dual pane on / off: two folders side by side"),
            Shortcut(keys: "Tab", action: "Switch to the other pane"),
            Shortcut(keys: "F5 / F6", action: "Copy / move the marked items into the other pane's folder"),

            Shortcut(keys: "⌘-click / Insert", action: "Mark / unmark an item"),
            Shortcut(keys: "⇧-click / ⇧ arrows", action: "Mark a range"),
            Shortcut(keys: "⌘A / Esc", action: "Mark all / unmark all"),
            Shortcut(keys: "drag", action: "Marked items onto a folder or into the other pane: moved (copied to another volume)"),
        ]),
        Group(title: "Search field", shortcuts: [
            Shortcut(keys: "⌘F", action: "Search names of folders, archives, pictures and videos (incl. subfolders)"),
            Shortcut(keys: "↓", action: "Move into the results"),
            Shortcut(keys: "Return", action: "Open the selected result"),
            Shortcut(keys: "Esc", action: "Clear the search; again: leave the field"),
        ]),
        Group(title: "Grid and full view", shortcuts: [
            Shortcut(keys: "⌘[ / ⌘]", action: "Back / forward (history)"),
            Shortcut(keys: "⌘↑", action: "Enclosing folder"),
            Shortcut(keys: "⌘1 … ⌘5", action: "Sort by name, kind, date modified, date taken, size (again: reverse)"),
            Shortcut(keys: "f / ⌃⌘F", action: "Toggle full screen"),
            Shortcut(keys: "⌘O", action: "Open folder"),
            Shortcut(keys: "⇧⌘N / F7", action: "New folder: type its name, ↩ creates it, Esc creates none"),
            Shortcut(keys: "⇧⌘R", action: "Reveal in Finder"),
            Shortcut(keys: "⌘↩ / F4", action: "Open with default app"),
            Shortcut(keys: "⌘⌫ / F8", action: "Move to Trash"),
            Shortcut(keys: "⌘Q / F10", action: "Quit (F10 asks first)"),
            Shortcut(keys: "F9", action: "The app's menus in the window"),
            Shortcut(keys: "K", action: "Show / hide the mini keyboard"),
            Shortcut(keys: "F1 / ⌘?", action: "Show this list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { HStack(spacing: 6) { Text("Done"); KeyCap("↩") } }
                    .keyboardShortcut(.defaultAction)
                // Esc closes it too
                Button { dismiss() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
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
                                    Text(verbatim: shortcut.keys)
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
