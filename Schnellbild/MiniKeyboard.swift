import SwiftUI

/// The mini keyboard (K): a row of the keys that work on what's on screen,
/// each with what it does. A cheat sheet that can be clicked: a click goes
/// through `WindowModel.handleWindowKey`, then `BrowserModel.handleKey`,
/// exactly like the key itself. A key that acts, typed or clicked, lights
/// up. Each key shows the action's key as set in Settings → Keyboard.
struct MiniKeyboard: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var shortcuts = Shortcuts.shared

    /// One key: its action, its word, and the key it sends.
    struct Key: Identifiable {
        let action: ShortcutAction
        /// The action's key as Schnellbild has it (stored form): what a
        /// click sends, and the key's identifier for the UI tests
        /// ("key.space", "key.esc", "key.⌘F"), whatever key it shows.
        let standard: KeyChord
        let word: LocalizedStringKey

        init(_ action: ShortcutAction, _ standard: String, word: LocalizedStringKey) {
            self.action = action
            self.standard = KeyChord(stored: standard) ?? KeyChord(.space)
            self.word = word
        }

        /// Unique within a row ("F" and "⌘F" are two keys).
        var id: String { standard.idText }

        /// The cap: the key it has always had while the action still has
        /// it, else the action's first key; nil when the action has none.
        @MainActor
        func cap(_ shortcuts: Shortcuts) -> String? {
            let keys = shortcuts.keys(action)
            return keys.contains(standard) ? standard.text : keys.first?.text
        }
    }

    /// What's on screen decides the keys.
    /// `playlist`: the slideshow's playlist open; `playlistKeys`: it has the
    /// keys (after a click in it).
    enum Context { case grid, dualGrid, atlas, tour, picture, pdf, video, slideshow, playlist, playlistKeys }

    static func keys(for context: Context) -> [Key] {
        switch context {
        case .grid:
            return [
                Key(.forward, "@]", word: "Forward"),
                Key(.gridBack, "delete", word: "Back"),
                Key(.gridPrevious, "left", word: "Previous"),
                Key(.gridRowUp, "up", word: "Row up"),
                Key(.gridRowDown, "down", word: "Row down"),
                Key(.gridNext, "right", word: "Next"),
                Key(.gridOpen, "space", word: "Open"),
                Key(.gridRename, "return", word: "Rename"),
                Key(.startSlideshow, "s", word: "Slideshow"),
                Key(.enhance, "e", word: "Auto Enhance"),
                Key(.adjust, "a", word: "Adjust"),
                Key(.fullScreen, "f", word: "Full Screen"),
                Key(.search, "@f", word: "Search"),
                Key(.help, "f1", word: "Help"),
            ]
        case .dualGrid:
            return [
                Key(.switchPane, "tab", word: "Other pane"),
                Key(.copyToOther, "@$c", word: "Copy there"),
                Key(.moveToOther, "@$m", word: "Move there"),
                Key(.newFolder, "f7", word: "New folder"),
                Key(.mark, "m", word: "Mark"),
                Key(.gridBack, "delete", word: "Back"),
                Key(.gridPrevious, "left", word: "Previous"),
                Key(.gridNext, "right", word: "Next"),
                Key(.gridOpen, "space", word: "Open"),
                Key(.gridRename, "return", word: "Rename"),
                Key(.startSlideshow, "s", word: "Slideshow"),
                Key(.search, "@f", word: "Search"),
                Key(.toggleDual, "d", word: "Single pane"),
                Key(.help, "f1", word: "Help"),
            ]
        case .atlas:
            return [
                Key(.gridBack, "delete", word: "Back"),
                Key(.gridPrevious, "left", word: "Left"),
                Key(.gridRowUp, "up", word: "Up"),
                Key(.gridRowDown, "down", word: "Down"),
                Key(.gridNext, "right", word: "Right"),
                Key(.gridOpen, "space", word: "Open"),
                Key(.largerThumbnails, "+", word: "Zoom in"),
                Key(.smallerThumbnails, "-", word: "Zoom out"),
                Key(.startTour, "t", word: "Tour"),
                Key(.toggleAtlas, "w", word: "Grid"),
                Key(.info, "i", word: "Info"),
                Key(.search, "@f", word: "Search"),
                Key(.help, "f1", word: "Help"),
            ]
        case .tour:
            return [
                Key(.tourPause, "space", word: "Pause"),
                Key(.tourPrevious, "left", word: "Previous place"),
                Key(.tourNext, "right", word: "Next place"),
                Key(.fullScreen, "f", word: "Full Screen"),
                Key(.endTour, "escape", word: "End"),
            ]
        case .picture:
            return [
                Key(.fullPrevious, "left", word: "Previous"),
                Key(.fullNext, "right", word: "Next"),
                Key(.zoomIn, "+", word: "Zoom in"),
                Key(.zoomOut, "-", word: "Zoom out"),
                Key(.zoomFit, "0", word: "Fit"),
                Key(.zoomActual, "1", word: "100 %"),
                Key(.rotateLeft, "~left", word: "Rotate left"),
                Key(.rotateRight, "~right", word: "Rotate right"),
                Key(.info, "i", word: "Info"),
                Key(.enhance, "e", word: "Auto Enhance"),
                Key(.adjust, "a", word: "Adjust"),
                Key(.fullScreen, "f", word: "Full Screen"),
                Key(.closeFullView, "escape", word: "Grid"),
                Key(.help, "f1", word: "Help"),
            ]
        case .pdf:
            return [
                Key(.fullPrevious, "left", word: "Previous page"),
                Key(.fullNext, "right", word: "Next page"),
                Key(.fullPreviousItem, "@left", word: "Previous item"),
                Key(.fullNextItem, "@right", word: "Next item"),
                Key(.zoomIn, "+", word: "Zoom in"),
                Key(.zoomOut, "-", word: "Zoom out"),
                Key(.zoomFit, "0", word: "Fit"),
                Key(.zoomActual, "1", word: "100 %"),
                Key(.rotateLeft, "~left", word: "Rotate left"),
                Key(.rotateRight, "~right", word: "Rotate right"),
                Key(.info, "i", word: "Info"),
                Key(.fullScreen, "f", word: "Full Screen"),
                Key(.closeFullView, "escape", word: "Grid"),
                Key(.help, "f1", word: "Help"),
            ]
        case .video:
            return [
                Key(.fullSpace, "space", word: "Play / Pause"),
                Key(.fullPrevious, "left", word: "−10 %"),
                Key(.fullNext, "right", word: "+10 %"),
                Key(.fullUp, "up", word: "Louder"),
                Key(.fullDown, "down", word: "Quieter"),
                Key(.slower, "<", word: "Slower"),
                Key(.faster, ">", word: "Faster"),
                Key(.subtitles, "v", word: "Subtitles"),
                Key(.fullPreviousItem, "@left", word: "Previous item"),
                Key(.fullNextItem, "@right", word: "Next item"),
                Key(.enhance, "e", word: "Auto Enhance"),
                Key(.fullScreen, "f", word: "Full Screen"),
                Key(.closeFullView, "escape", word: "Grid"),
                Key(.help, "f1", word: "Help"),
            ]
        case .slideshow:
            return [
                Key(.showPause, "space", word: "Pause"),
                Key(.fullPrevious, "left", word: "Previous"),
                Key(.fullNext, "right", word: "Next"),
                Key(.playlist, "p", word: "Playlist"),
                Key(.info, "i", word: "Info"),
                Key(.enhance, "e", word: "Auto Enhance"),
                Key(.adjust, "a", word: "Adjust"),
                Key(.fullScreen, "f", word: "Full Screen"),
                Key(.endSlideshow, "escape", word: "End"),
            ]
        case .playlist:
            return [
                Key(.showPause, "space", word: "Pause"),
                Key(.fullPrevious, "left", word: "Previous"),
                Key(.fullNext, "right", word: "Next"),
                Key(.info, "i", word: "Info"),
                Key(.enhance, "e", word: "Auto Enhance"),
                Key(.adjust, "a", word: "Adjust"),
                Key(.fullScreen, "f", word: "Full Screen"),
                Key(.endSlideshow, "escape", word: "Close playlist"),
            ]
        case .playlistKeys:
            return [
                Key(.showPause, "space", word: "Pause"),
                Key(.fullPrevious, "left", word: "Previous"),
                Key(.fullNext, "right", word: "Next"),
                Key(.listUp, "up", word: "Row up"),
                Key(.listDown, "down", word: "Row down"),
                Key(.listShow, "return", word: "Show"),
                Key(.listTakeOut, "delete", word: "Take out"),
                Key(.endSlideshow, "escape", word: "Close playlist"),
            ]
        }
    }

    @EnvironmentObject var window: WindowModel

    private var context: Context {
        if model.slideshow != nil {
            guard model.showPlaylist else { return .slideshow }
            return model.playlistFocused ? .playlistKeys : .playlist
        }
        if model.touring { return .tour }
        guard model.mode == .detail else {
            if model.viewMode == .atlas { return .atlas }
            return window.dual ? .dualGrid : .grid
        }
        guard let shown = model.shownMediaEntry else { return .picture }
        if shown.kind == .video { return .video }
        return PDFPages.isPDF(shown.url) ? .pdf : .picture
    }

    var body: some View {
        // One row; at most 14 keys fit the narrowest window. An action
        // without a key (Settings → Keyboard) leaves its key out.
        HStack(spacing: 6) {
            ForEach(Self.keys(for: context)) { key in
                if let cap = key.cap(shortcuts) {
                    MiniKeyButton(key: key, cap: cap)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniKeyboard")
    }
}

/// One key of the mini keyboard: lights up when it acts.
private struct MiniKeyButton: View {
    let key: MiniKeyboard.Key
    let cap: String
    @EnvironmentObject var model: BrowserModel
    @EnvironmentObject var window: WindowModel
    @State private var lit = false
    /// How often it acted (UI tests read it under `--ui-testing`: lighting
    /// up is too short to catch).
    @State private var presses = 0

    var body: some View {
        Button {
            // As typed: the window's keys first (D, Tab, F5, F6), then the
            // pane's. Schnellbild's key for the action does it, whatever key
            // the action has now.
            let k = key.standard
            if !window.handleWindowKey(k.key, command: k.command, control: k.control, shift: k.shift, textEditing: false) {
                model.handleKey(k.key, command: k.command, shift: k.shift, option: k.option)
            }
        } label: {
            VStack(spacing: 3) {
                Text(verbatim: cap)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 26, minHeight: 22)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(lit ? Color.accentColor : Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(lit ? Color.white : Color.primary)
                    .scaleEffect(lit ? 0.92 : 1)
                Text(key.word)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("key.\(key.id)")
        .accessibilityValue(VideoDetailView.uiTesting && presses > 0 ? "pressed \(presses)" : "")
        .onChange(of: model.lastKeyPress) { _, press in
            // Just now: a press stored in the other pane (now active) is old
            guard let press, Date().timeIntervalSince(press.at) < 0.5, matches(press) else { return }
            presses += 1
            withAnimation(Motion.animation(.easeOut(duration: 0.08))) { lit = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(Motion.animation(.easeIn(duration: 0.2))) { lit = false }
            }
        }
    }

    /// The press was this key's: Schnellbild's key for the action, or the
    /// key a set key is carried out with (`WindowModel.perform`).
    private func matches(_ press: BrowserModel.KeyPress) -> Bool {
        var chords = [key.standard]
        if case .key(let performed) = key.action.performer { chords.append(performed) }
        return chords.contains { press.matches($0.key, command: $0.command, shift: $0.shift, option: $0.option) }
    }
}
