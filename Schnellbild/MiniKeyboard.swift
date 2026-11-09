import SwiftUI

/// The mini keyboard (K): a row of the keys that work on what's on screen,
/// each with what it does. A cheat sheet that can be clicked: a click goes
/// through `BrowserModel.handleKey`, exactly like the key itself. A key that
/// acts, typed or clicked, lights up.
struct MiniKeyboard: View {
    @EnvironmentObject var model: BrowserModel

    /// One key: its cap, its word, and the input it sends.
    struct Key: Identifiable {
        let cap: String
        let word: LocalizedStringKey
        let input: BrowserModel.KeyInput
        var command = false
        var shift = false
        /// The cap is unique within a row ("F" and "⌘F" are two keys).
        var id: String { cap }
    }

    /// What's on screen decides the keys.
    enum Context { case grid, picture, video, slideshow }

    static func keys(for context: Context) -> [Key] {
        switch context {
        case .grid:
            return [
                Key(cap: "⌘[", word: "Back", input: .char("["), command: true),
                Key(cap: "⌘]", word: "Forward", input: .char("]"), command: true),
                Key(cap: "⌫", word: "Up", input: .backspace),
                Key(cap: "←", word: "Previous", input: .left),
                Key(cap: "↑", word: "Row up", input: .up),
                Key(cap: "↓", word: "Row down", input: .down),
                Key(cap: "→", word: "Next", input: .right),
                Key(cap: "↩", word: "Open", input: .enter),
                Key(cap: "S", word: "Slideshow", input: .char("s")),
                Key(cap: "E", word: "Auto Enhance", input: .char("e")),
                Key(cap: "A", word: "Adjust", input: .char("a")),
                Key(cap: "F", word: "Full Screen", input: .char("f")),
                Key(cap: "⌘F", word: "Search", input: .char("f"), command: true),
                Key(cap: "F1", word: "Help", input: .f1),
            ]
        case .picture:
            return [
                Key(cap: "←", word: "Previous", input: .left),
                Key(cap: "→", word: "Next", input: .right),
                Key(cap: "+", word: "Zoom in", input: .char("+")),
                Key(cap: "−", word: "Zoom out", input: .char("-")),
                Key(cap: "0", word: "Fit", input: .char("0")),
                Key(cap: "1", word: "100 %", input: .char("1")),
                Key(cap: "[", word: "Rotate left", input: .char("[")),
                Key(cap: "]", word: "Rotate right", input: .char("]")),
                Key(cap: "I", word: "Info", input: .char("i")),
                Key(cap: "E", word: "Auto Enhance", input: .char("e")),
                Key(cap: "A", word: "Adjust", input: .char("a")),
                Key(cap: "F", word: "Full Screen", input: .char("f")),
                Key(cap: "esc", word: "Grid", input: .escape),
                Key(cap: "F1", word: "Help", input: .f1),
            ]
        case .video:
            return [
                Key(cap: "space", word: "Play / Pause", input: .space),
                Key(cap: "←", word: "−10 %", input: .left),
                Key(cap: "→", word: "+10 %", input: .right),
                Key(cap: "⇧←", word: "−2 s", input: .left, shift: true),
                Key(cap: "⇧→", word: "+2 s", input: .right, shift: true),
                Key(cap: "⌘←", word: "Previous item", input: .left, command: true),
                Key(cap: "⌘→", word: "Next item", input: .right, command: true),
                Key(cap: "E", word: "Auto Enhance", input: .char("e")),
                Key(cap: "A", word: "Adjust", input: .char("a")),
                Key(cap: "F", word: "Full Screen", input: .char("f")),
                Key(cap: "esc", word: "Grid", input: .escape),
                Key(cap: "F1", word: "Help", input: .f1),
            ]
        case .slideshow:
            return [
                Key(cap: "space", word: "Pause", input: .space),
                Key(cap: "←", word: "Previous", input: .left),
                Key(cap: "→", word: "Next", input: .right),
                Key(cap: "I", word: "Info", input: .char("i")),
                Key(cap: "E", word: "Auto Enhance", input: .char("e")),
                Key(cap: "A", word: "Adjust", input: .char("a")),
                Key(cap: "F", word: "Full Screen", input: .char("f")),
                Key(cap: "esc", word: "End", input: .escape),
            ]
        }
    }

    private var context: Context {
        if model.slideshow != nil { return .slideshow }
        guard model.mode == .detail else { return .grid }
        return model.shownMediaEntry?.kind == .video ? .video : .picture
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.keys(for: context)) { key in
                    MiniKeyButton(key: key)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("miniKeyboard")
    }
}

/// One key of the mini keyboard: lights up when it acts.
private struct MiniKeyButton: View {
    let key: MiniKeyboard.Key
    @EnvironmentObject var model: BrowserModel
    @State private var lit = false

    var body: some View {
        Button {
            model.handleKey(key.input, command: key.command, shift: key.shift)
        } label: {
            VStack(spacing: 3) {
                Text(verbatim: key.cap)
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
        .accessibilityValue(lit ? "pressed" : "")
        .onChange(of: model.lastKeyPress) { _, press in
            guard let press, press.matches(key.input, command: key.command, shift: key.shift) else { return }
            withAnimation(.easeOut(duration: 0.08)) { lit = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeIn(duration: 0.2)) { lit = false }
            }
        }
    }
}
