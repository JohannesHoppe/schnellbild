import SwiftUI
import PDFKit

/// What the keys column of a row shows: actions' keys as set (Settings →
/// Keyboard), keys that can't be changed, or words ("drag").
enum HelpKeys {
    /// The action's keys: "Space / F3".
    case action(ShortcutAction)
    /// Two actions side by side: "← →", "⌘[ / ⌘]"; with more keys each,
    /// pair by pair: "+ / − · ⌘+ / ⌘−".
    case pair(ShortcutAction, ShortcutAction, String)
    /// Several actions, one key each: "⌘1 … ⌘5" while they have
    /// Schnellbild's keys, else every key.
    case range([ShortcutAction])
    /// Keys that stay as they are (⌘Q, ⌃⌘F: the system's; the search
    /// field's keys).
    case fixed(String)
    /// Words, translated ("drag", "⌘-click").
    case words(String)

    /// The keys as shown; nil for actions that have none.
    @MainActor
    func text(_ shortcuts: Shortcuts) -> String? {
        switch self {
        case .action(let action):
            let text = shortcuts.text(action)
            return text.isEmpty ? nil : text
        case .pair(let a, let b, let joiner):
            let first = shortcuts.keys(a), second = shortcuts.keys(b)
            if !first.isEmpty, first.count == second.count {
                return zip(first, second).map { $0.text + joiner + $1.text }.joined(separator: " · ")
            }
            let both = [shortcuts.text(a), shortcuts.text(b)].filter { !$0.isEmpty }
            return both.isEmpty ? nil : both.joined(separator: " · ")
        case .range(let actions):
            let standard = actions.allSatisfy { shortcuts.keys($0) == $0.standardKeys && $0.standardKeys.count == 1 }
            if standard, let first = actions.first, let last = actions.last {
                return shortcuts.text(first) + " … " + shortcuts.text(last)
            }
            let all = actions.flatMap { shortcuts.keys($0) }.map(\.text)
            return all.isEmpty ? nil : all.joined(separator: " ")
        case .fixed(let keys):
            return keys.replacingOccurrences(of: "Space", with: String(localized: "Space"))
        case .words(let words):
            return String(localized: String.LocalizationValue(words))
        }
    }
}

/// One line of the cheat sheet: the keys and what they do.
struct HelpShortcut: Identifiable {
    let id: Int
    let keys: String
    let action: String
}

struct HelpGroup: Identifiable {
    let id: Int
    let title: LocalizedStringKey
    let shortcuts: [HelpShortcut]
}

/// A row as written in `ShortcutsHelpView.groups`, before its keys are
/// looked up.
private struct Row {
    let keys: [HelpKeys]
    let action: String

    /// `action`: the English text, translated here.
    init(_ keys: HelpKeys..., action: String) {
        self.keys = keys
        self.action = String(localized: String.LocalizationValue(action))
    }

    /// `text`: translated already (it holds keys of its own).
    init(_ keys: HelpKeys..., text: String) {
        self.keys = keys
        action = text
    }
}

/// The keyboard-shortcut cheat sheet, shown via F1 or the "Schnellbild Help"
/// menu item, and printed on one page (`printCheatSheet`). Its keys are the
/// ones set in Settings → Keyboard.
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var shortcuts = Shortcuts.shared

    /// The groups, with the keys as set.
    @MainActor
    static func groups(_ s: Shortcuts) -> [HelpGroup] {
        let thrice = s.keys(.bossKey).first.map { key in Array(repeating: key.text, count: 3).joined(separator: " ") }
            ?? String(localized: "no key")
        // The keys that end the slideshow; all but S close the playlist first
        let closers = s.keys(.endSlideshow).filter { $0 != KeyChord(.char("s")) }.map(\.text).joined(separator: " ")
        let rows: [(LocalizedStringKey, [Row])] = [
            ("Grid", [
                Row(.pair(.gridPrevious, .gridNext, " "), action: "Previous / next item"),
                Row(.pair(.gridRowUp, .gridRowDown, " "), action: "One row up / down"),
                Row(.action(.gridOpen), action: "Open picture or video · open folder or archive"),
                Row(.action(.gridBack), action: "Back (where you were, also a search); without history the enclosing folder"),
                Row(.pair(.gridFirst, .gridLast, " / "), action: "First / last item"),
                Row(.action(.toggleList), action: "Next view: grid, list, Atlas (a click on a column sorts by it)"),
                Row(.pair(.largerThumbnails, .smallerThumbnails, " / "), action: "Larger / smaller thumbnails"),
                Row(.action(.gridRename), action: s.keys(.moveToOther).contains(KeyChord(.f6)) ? "Rename (F6 too in a single pane)" : "Rename"),
                Row(.action(.newFolder), action: "New folder: type its name, ↩ creates it, Esc creates none"),
                Row(.action(.trash), action: "Move to Trash"),
                Row(.action(.gridClear), action: "Clear search"),
            ]),
            ("Full view", [
                Row(.pair(.fullPrevious, .fullNext, " "), action: "Pictures: previous / next · Videos: 10 % of the length back / ahead · PDFs: previous / next page; at the start / end: previous / next item"),
                Row(.pair(.fullPreviousItem, .fullNextItem, " "), action: "Previous / next item, also from a video or PDF"),
                Row(.pair(.fullUp, .fullDown, " "), action: "Pictures zoomed in: look further up / down · Videos: volume up / down (remembered)"),
                Row(.pair(.fullFineBack, .fullFineAhead, " "), action: "Video: 1 % of the length back / ahead"),
                Row(.action(.fullSpace), action: "Next picture · play/pause video"),
                Row(.pair(.zoomIn, .zoomOut, " / "), action: "Zoom in / out"),
                Row(.pair(.zoomFit, .zoomActual, " / "), action: "Fit to window / 100 %"),
                Row(.pair(.rotateLeft, .rotateRight, " / "), action: "Rotate left / right"),
                Row(.action(.fullRename), action: "Rename"),
                Row(.action(.closeFullView), action: "Back to grid"),
            ]),
            ("Videos", [
                Row(.action(.subtitles), action: "Subtitles on / off (remembered, with the language chosen)"),
                Row(.action(.nextSubtitle), action: "Next subtitle track, then none"),
                Row(.action(.nextAudio), action: "Next audio track (the language is remembered)"),
                Row(.pair(.slower, .faster, " / "), action: "Slower / faster (0.5× … 2×, until the app quits)"),
                Row(.action(.normalSpeed), action: "Normal speed"),
                Row(.words("drag"), action: "The control bar by its grip: it stays there for every video; double-click the grip: back to the bottom"),
                Row(.words("right-click"), action: "Subtitles, audio track, speed"),
            ]),
            ("Slideshow", [
                Row(.action(.startSlideshow), action: "Start: all pictures and videos in this folder and its subfolders (while searching: the results)"),
                Row(.action(.showPause), action: "Pause / resume"),
                Row(.pair(.fullPrevious, .fullNext, " "), action: "Previous / next · Videos: 10 % of the length back / ahead"),
                Row(.pair(.fullFineBack, .fullFineAhead, " "), action: "Video: 1 % of the length back / ahead"),
                Row(.pair(.fullPreviousItem, .fullNextItem, " "), action: "Previous / next item"),
                Row(.pair(.fullUp, .fullDown, " "), action: "Pictures zoomed in: look further up / down · Videos: volume up / down (remembered)"),
                Row(.action(.fullScreen), action: "Toggle full screen"),
                Row(.action(.info), action: "File info"),
                Row(.action(.enhance), action: "Auto enhance on / off (exposure, contrast, saturation, sharpness; files are not changed)"),
                Row(.action(.adjust), action: "Sliders: adjust by hand (switches auto enhance off)"),
                Row(.action(.playlist), action: "Playlist: the show's order; drag to reorder, click to show an item"),
                Row(.pair(.listUp, .listDown, " "), .action(.listShow), .action(.listTakeOut),
                    action: "In the playlist, after a click in it: choose / show / take out of the playlist (the file stays)"),
                Row(.action(.endSlideshow), text: closers.isEmpty ? String(localized: "End the slideshow")
                    : String(localized: "End the slideshow (\(closers) close the playlist first)")),
            ]),
            ("Atlas", [
                Row(.action(.toggleList), action: "From the list: the Atlas, the photos and videos on the map; from the Atlas: back to the grid"),
                Row(.words("arrows"), action: "Atlas: to the nearest item on the map that way; down into the strip of items without a location"),
                Row(.pair(.largerThumbnails, .smallerThumbnails, " / "), action: "Atlas: zoom the map in / out"),
                Row(.words("double-click"), action: "Atlas: on several items, zoom in until they part; on one, open it"),
                Row(.words("click"), action: "Atlas: on items taken at one place, the next one (→ ← too)"),
                Row(.words("timeline"), action: "Drag across or move a handle: only that time on the map; click: the item taken nearest then"),
                Row(.action(.startTour), action: "Tour: the places in the order of time, full screen, the route drawn on the map"),
                Row(.action(.tourPause), action: "Tour: pause / resume"),
                Row(.pair(.tourPrevious, .tourNext, " "), action: "Tour: previous / next place"),
                Row(.action(.endTour), action: "End the tour"),
            ]),
            ("Dual pane and marking", [
                Row(.action(.toggleDual), action: "Dual pane on / off: two folders side by side"),
                Row(.action(.switchPane), action: "Switch to the other pane"),
                Row(.pair(.copyToOther, .moveToOther, " / "), action: "Copy / move the marked items into the other pane's folder"),
                Row(.words("⌘-click"), .action(.mark), action: s.keys(.mark) == ShortcutAction.mark.standardKeys
                    ? "Mark / unmark an item (M, Insert: then on to the next)" : "Mark / unmark an item, then on to the next"),
                Row(.words("⇧-click / ⇧ arrows"), action: "Mark a range"),
                Row(.pair(.markAll, .gridClear, " / "), action: "Mark all / unmark all"),
                Row(.words("drag"), action: "Marked items onto a folder or into the other pane: moved (copied to another volume)"),
            ]),
            ("Search field", [
                Row(.action(.search), action: "Search names of folders, archives, pictures and videos (incl. subfolders)"),
                Row(.fixed("↓"), action: "Move into the results"),
                Row(.fixed("↩"), action: "Open the selected result"),
                Row(.fixed("⎋"), action: "Clear the search; again: leave the field"),
            ]),
            ("Grid and full view", [
                Row(.pair(.back, .forward, " / "), action: "Back / forward (history)"),
                Row(.action(.enclosingFolder), action: "Enclosing folder"),
                Row(.action(.reload), action: "Read the folder again"),
                Row(.range(ShortcutAction.sorts), action: "Sort by name, kind, date modified, date taken, size, distance (again: reverse)"),
                Row(.action(.info), action: "File info"),
                Row(.action(.fullScreen), .fixed("⌃⌘F"), action: "Toggle full screen"),
                Row(.action(.enhance), action: "Auto enhance on / off (exposure, contrast, saturation, sharpness; files are not changed)"),
                Row(.action(.adjust), action: "Sliders: adjust by hand (switches auto enhance off)"),
                Row(.action(.openFolder), action: "Open folder"),
                Row(.action(.newWindow), action: "New window (e.g. for another display)"),
                Row(.action(.reveal), action: "Reveal in Finder"),
                Row(.action(.openDefault), action: "Open with default app"),
                Row(.action(.trash), action: "Move to Trash"),
                Row(.fixed("⌘Z / ⇧⌘Z"), action: "Undo / redo renaming, trashing, moving, copying, a new folder"),
                Row(.fixed("⌘Q"), .action(.quit), text: s.keys(.quit).isEmpty ? String(localized: "Quit")
                    : String(localized: "Quit (\(s.text(.quit)) asks first)")),
                Row(.action(.menus), action: "The app's menus in the window"),
                Row(.action(.miniKeyboard), action: "Show / hide the mini keyboard"),
                Row(.action(.hiddenFiles), action: "Show / hide hidden files and folders"),
                Row(.action(.bookmark), action: "Bookmark the folder shown, or remove its bookmark"),
                Row(.range(ShortcutAction.bookmarks), action: "Open bookmark 1 … 9"),
                Row(.action(.bossKey), text: String(localized: "Boss key: hidden and silent at once; \(thrice) or the Dock icon brings it back")),
                Row(.action(.help), action: "Show this list"),
            ]),
        ]
        var number = 0
        return rows.enumerated().map { index, group in
            HelpGroup(id: index, title: group.0, shortcuts: group.1.map { row in
                number += 1
                let parts = row.keys.compactMap { $0.text(s) }
                return HelpShortcut(id: number, keys: parts.isEmpty ? String(localized: "no key") : parts.joined(separator: " / "),
                                    action: row.action)
            })
        }
    }

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
                    ForEach(Self.groups(shortcuts)) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(group.shortcuts) { shortcut in
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(verbatim: shortcut.keys)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(width: 180, alignment: .leading)
                                    Text(verbatim: shortcut.action)
                                        .font(.callout)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    Text("Keys can be changed in Settings → Keyboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
    static func cheatSheetPDF(paper: CGSize = CGSize(width: 595, height: 842), shortcuts: Shortcuts? = nil) -> Data {
        let margin: CGFloat = 32
        let usable = CGSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        let renderer = ImageRenderer(content: CheatSheetPage(groups: groups(shortcuts ?? .shared)).frame(width: usable.width))
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
    let groups: [HelpGroup]

    var body: some View {
        let (left, right) = Self.columns(groups)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Schnellbild").font(.system(size: 17, weight: .bold))
                Text("Keyboard Shortcuts").font(.system(size: 17))
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

    private func column(_ groups: [HelpGroup]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(group.title).font(.system(size: 11, weight: .bold))
                        .padding(.bottom, 1)
                    ForEach(group.shortcuts) { shortcut in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: shortcut.keys)
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 84, alignment: .leading)
                            Text(verbatim: shortcut.action)
                                .font(.system(size: 8.5))
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

    /// The groups in order, split where both columns are about as tall
    /// (a long action or key list takes more than one line).
    static func columns(_ groups: [HelpGroup]) -> ([HelpGroup], [HelpGroup]) {
        func lines(_ shortcut: HelpShortcut) -> Int {
            max(1, (shortcut.action.count + 43) / 44, (shortcut.keys.count + 12) / 13)
        }
        let lines = groups.map { $0.shortcuts.map(lines).reduce(0, +) + 2 }
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
