import SwiftUI
import PDFKit

private struct Shortcut: Identifiable {
    let id = UUID()
    /// Key glyphs and key names, shown as they are.
    let keys: String
    let action: LocalizedStringKey
    /// The keys column holds words besides key names ("drag"): translated.
    var wordsInKeys = false

    var keysText: Text { wordsInKeys ? Text(LocalizedStringKey(keys)) : Text(verbatim: keys) }
}

private struct Group: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let shortcuts: [Shortcut]
}

/// The keyboard-shortcut cheat sheet, shown via F1 or the "Schnellbild Help"
/// menu item, and printed on one page (`printCheatSheet`).
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    fileprivate static let groups: [Group] = [
        Group(title: "Grid", shortcuts: [
            Shortcut(keys: "← →", action: "Previous / next item"),
            Shortcut(keys: "↑ ↓", action: "One row up / down"),
            Shortcut(keys: "Space / F3", action: "Open picture or video · open folder or archive"),
            Shortcut(keys: "Backspace", action: "Back (where you were, also a search); without history the enclosing folder"),
            Shortcut(keys: "Home / End", action: "First / last item"),
            Shortcut(keys: "L", action: "Grid or list (a click on a column sorts by it)"),
            Shortcut(keys: "+ / − · ⌘+ / ⌘−", action: "Larger / smaller thumbnails"),
            Shortcut(keys: "Return", action: "Rename"),
            Shortcut(keys: "⇧⌘N / F7", action: "New folder: type its name, ↩ creates it, Esc creates none"),
            Shortcut(keys: "F8", action: "Move to Trash"),
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
            Shortcut(keys: "⌥← / ⌥→", action: "Rotate left / right"),
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
            Shortcut(keys: "Esc / s / Return / Backspace", action: "End the slideshow"),
        ]),
        Group(title: "Dual pane and marking", shortcuts: [
            Shortcut(keys: "D / ⌃O", action: "Dual pane on / off: two folders side by side"),
            Shortcut(keys: "Tab", action: "Switch to the other pane"),
            Shortcut(keys: "F5 / F6", action: "Copy / move the marked items into the other pane's folder"),

            Shortcut(keys: "⌘-click / Insert", action: "Mark / unmark an item", wordsInKeys: true),
            Shortcut(keys: "⇧-click / ⇧ arrows", action: "Mark a range", wordsInKeys: true),
            Shortcut(keys: "⌘A / Esc", action: "Mark all / unmark all"),
            Shortcut(keys: "drag", action: "Marked items onto a folder or into the other pane: moved (copied to another volume)", wordsInKeys: true),
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
            Shortcut(keys: "⇧⌘R", action: "Reveal in Finder"),
            Shortcut(keys: "⌘↩ / F4", action: "Open with default app"),
            Shortcut(keys: "⌘⌫", action: "Move to Trash"),
            Shortcut(keys: "⌘Q / F10", action: "Quit (F10 asks first)"),
            Shortcut(keys: "F9", action: "The app's menus in the window"),
            Shortcut(keys: "K", action: "Show / hide the mini keyboard"),
            Shortcut(keys: "X", action: "Boss key: hidden and silent at once; X X X brings it back"),
            Shortcut(keys: "F1 / ⌘?", action: "Show this list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button { Self.printCheatSheet() } label: { HStack(spacing: 6) { Text("Print…"); KeyCap("⌘P") } }
                    .keyboardShortcut("p", modifiers: .command)
                    .accessibilityIdentifier("printCheatSheet")
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
                    ForEach(Self.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(group.shortcuts) { shortcut in
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    shortcut.keysText
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

    // MARK: Printing

    /// The print panel for the cheat sheet (printer, or Save as PDF).
    @MainActor
    static func printCheatSheet() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        guard let document = PDFDocument(data: cheatSheetPDF(paper: info.paperSize)),
              let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        operation.jobTitle = String(localized: "Keyboard Shortcuts")
        operation.run()
    }

    /// The cheat sheet as a one-page PDF on the given paper, scaled down if
    /// it would not fit (vector: sharp at any printer's resolution).
    @MainActor
    static func cheatSheetPDF(paper: CGSize = CGSize(width: 595, height: 842)) -> Data {
        let margin: CGFloat = 32
        let usable = CGSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        let renderer = ImageRenderer(content: CheatSheetPage().frame(width: usable.width))
        let data = NSMutableData()
        renderer.render { size, draw in
            var page = CGRect(origin: .zero, size: paper)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { return }
            context.beginPDFPage(nil)
            let scale = min(1, usable.width / size.width, usable.height / size.height)
            // From the top left of the printable area
            context.translateBy(x: margin, y: paper.height - margin - size.height * scale)
            context.scaleBy(x: scale, y: scale)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data as Data
    }
}

/// The printed cheat sheet: black on white, the groups in two columns.
private struct CheatSheetPage: View {
    var body: some View {
        let (left, right) = Self.columns(ShortcutsHelpView.groups)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Schnellbild").font(.system(size: 15, weight: .bold))
                Text("Keyboard Shortcuts").font(.system(size: 15))
            }
            HStack(alignment: .top, spacing: 18) {
                column(left)
                column(right)
            }
        }
        .foregroundStyle(.black)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func column(_ groups: [Group]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(group.title).font(.system(size: 9.5, weight: .bold))
                        .padding(.bottom, 1)
                    ForEach(group.shortcuts) { shortcut in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            shortcut.keysText
                                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                                .frame(width: 78, alignment: .leading)
                            Text(shortcut.action)
                                .font(.system(size: 7.5))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The groups in order, split where both columns hold about as many lines.
    static func columns(_ groups: [Group]) -> ([Group], [Group]) {
        let lines = groups.map { $0.shortcuts.count + 2 }
        let total = lines.reduce(0, +)
        var best = 0, bestDiff = Int.max, sum = 0
        for i in 0...groups.count {
            let diff = abs(total - 2 * sum)
            if diff < bestDiff { best = i; bestDiff = diff }
            if i < groups.count { sum += lines[i] }
        }
        return (Array(groups[..<best]), Array(groups[best...]))
    }
}

