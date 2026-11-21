import SwiftUI

/// The glyphs for the arrow keys, Home and End, as macOS draws them in its
/// menus, so the app's own texts show a key as the menu beside them does:
/// ◀ ▶ ▲ ▼ ⤒ ⤓, the same on macOS 15 and 26 (`KeyGlyphsUITests`
/// photographs a menu of every key on both; ⌃ ⌥ ⇧ ⌘, ⎋ ⇥ and the F-keys
/// look there as the app writes them too).
struct KeyGlyphs: Equatable {
    let left: String
    let right: String
    let up: String
    let down: String
    let home: String
    let end: String

    /// What macOS's menus draw.
    static let menus = KeyGlyphs(left: "◀", right: "▶", up: "▲", down: "▼", home: "⤒", end: "⤓")
    /// The plain arrows: what people type when they search for a key, and
    /// the mini keyboard's identifiers (`KeyChord.idText`).
    static let arrows = KeyGlyphs(left: "←", right: "→", up: "↑", down: "↓", home: "↖", end: "↘")

    /// The glyphs the app shows.
    static let current = menus

    /// The key's glyph; nil for keys these don't cover.
    func glyph(_ key: BrowserModel.KeyInput) -> String? {
        switch key {
        case .left: return left
        case .right: return right
        case .up: return up
        case .down: return down
        case .home: return home
        case .end: return end
        default: return nil
        }
    }

    /// Home and End on a Mac keyboard without those keys: fn with ← / →.
    func fnEquivalent(_ key: BrowserModel.KeyInput) -> String? {
        switch key {
        case .home: return left
        case .end: return right
        default: return nil
        }
    }
}

/// Keys as the app shows them: each key its own cap. Keys pressed together
/// are joined by "+" ([⇧] + [⌘] + [N]), keys that do the same are
/// separated by " / " ([Space] / [F3]), keys pressed one after another
/// stand side by side ([X] [X] [X]), a range runs "…" ([⌘] + [1] … [⌘] + [5]).
/// Home and End add how to type them without those keys: [⤒] ([fn] + [◀]).
struct KeyCaps: Equatable {
    enum Part: Equatable {
        /// One key.
        case cap(String)
        /// Pressed together.
        case plus
        /// Either.
        case or
        /// Then (a sequence).
        case then
        /// Through (a range).
        case through
        /// Between the keys of different pairs: "+ / − · ⌘+ / ⌘−".
        case group
        /// The other way to type the key, in parentheses.
        case open, close
        /// Words, translated already ("drag").
        case words(String)
    }

    var parts: [Part]

    init(_ parts: [Part] = []) { self.parts = parts }

    var isEmpty: Bool { parts.isEmpty }

    /// As plain text, for tooltips and sentences: "⇧ + ⌘ + N", "⤒ (fn + ◀)".
    var text: String {
        parts.map { part in
            switch part {
            case .cap(let key): return key
            case .plus: return " + "
            case .or: return " / "
            case .then: return " "
            case .through: return " … "
            case .group: return " · "
            case .open: return " ("
            case .close: return ")"
            case .words(let words): return words
            }
        }.joined()
    }

    /// The keys of a chord: modifiers in Apple's order (⌃ ⌥ ⇧ ⌘), then the
    /// key; Home / End with fn and the arrow after them. `escWord`: Esc as
    /// "esc", as on the keyboard and the sheets' buttons.
    static func chord(_ chord: KeyChord, glyphs: KeyGlyphs = .current, escWord: Bool = false) -> KeyCaps {
        var keys = chord.modifierGlyphs
        keys.append(escWord && keys.isEmpty && chord.key == .escape ? "esc" : chord.keyText(glyphs))
        var parts = joined(keys, by: .plus)
        if let arrow = glyphs.fnEquivalent(chord.key) {
            parts.append(.open)
            parts += joined(chord.modifierGlyphs + ["fn", arrow], by: .plus)
            parts.append(.close)
        }
        return KeyCaps(parts)
    }

    /// Several ways to the same: " / " between them.
    static func either(_ choices: [KeyCaps]) -> KeyCaps { join(choices, by: .or) }

    /// The same key pressed `count` times: [X] [X] [X].
    static func sequence(_ chord: KeyChord, count: Int, glyphs: KeyGlyphs = .current) -> KeyCaps {
        join(Array(repeating: Self.chord(chord, glyphs: glyphs), count: max(count, 0)), by: .then)
    }

    /// From the first to the last: [⌘] + [1] … [⌘] + [5].
    static func range(_ first: KeyCaps, _ last: KeyCaps) -> KeyCaps { join([first, last], by: .through) }

    static func join(_ list: [KeyCaps], by separator: Part) -> KeyCaps {
        KeyCaps(list.filter { !$0.isEmpty }.enumerated().flatMap { index, caps in (index > 0 ? [separator] : []) + caps.parts })
    }

    private static func joined(_ keys: [String], by separator: Part) -> [Part] {
        keys.enumerated().flatMap { index, key in (index > 0 ? [separator] : []) + [Part.cap(key)] }
    }
}

/// How a row of caps looks where it is drawn.
struct KeyCapStyle {
    var size: CGFloat = 12
    var minWidth: CGFloat = 20
    var minHeight: CGFloat = 18
    var padding: CGFloat = 4
    var fill: Color = Color.primary.opacity(0.06)
    var stroke: Color = Color.secondary.opacity(0.6)
    var foreground: Color = .primary
    /// What stands between the caps ("+", "/", "…").
    var signs: Color = .secondary

    /// On a button beside its title.
    static let button = KeyCapStyle(size: 10, minWidth: 0, minHeight: 0, padding: 4, fill: .clear,
                                    stroke: Color.secondary.opacity(0.7), foreground: .secondary)
    /// F1's list.
    static let help = KeyCapStyle(size: 11, minWidth: 18, minHeight: 17)
    /// The printed sheet: black on white.
    static let print = KeyCapStyle(size: 7.5, minWidth: 10, minHeight: 10, padding: 2.5, fill: .clear,
                                   stroke: Color.black.opacity(0.55), foreground: .black, signs: .black)
}

/// Keys drawn as caps, side by side, wrapping onto more lines where the
/// width ends (F1's column).
struct KeyCapsView: View {
    let caps: KeyCaps
    var style = KeyCapStyle()

    init(_ caps: KeyCaps, style: KeyCapStyle = KeyCapStyle()) {
        self.caps = caps
        self.style = style
    }

    var body: some View {
        KeyCapsFlow(spacing: max(2, style.size * 0.25), lineSpacing: max(2, style.size * 0.3)) {
            ForEach(Array(caps.parts.enumerated()), id: \.offset) { _, part in
                piece(part)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: caps.text))
        .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private func piece(_ part: KeyCaps.Part) -> some View {
        switch part {
        case .cap(let key):
            Text(verbatim: key)
                .font(.system(size: style.size, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: style.minWidth, minHeight: style.minHeight)
                .padding(.horizontal, style.padding)
                .padding(.vertical, style.padding * 0.25)
                .background(RoundedRectangle(cornerRadius: style.size * 0.4).fill(style.fill))
                .overlay(RoundedRectangle(cornerRadius: style.size * 0.4).strokeBorder(style.stroke, lineWidth: 1))
                .foregroundStyle(style.foreground)
        case .then:
            // A sequence: a gap, no sign
            Color.clear.frame(width: style.size * 0.15, height: 1)
        default:
            Text(verbatim: KeyCaps([part]).text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: style.size * 0.9))
                .foregroundStyle(style.signs)
                .fixedSize()
        }
    }
}

/// Lays its pieces out in lines, each line as wide as it can be.
struct KeyCapsFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Line] {
        var lines = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = (lines[lines.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if let width, !lines[lines.count - 1].indices.isEmpty, lines[lines.count - 1].width + added > width {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            lines[lines.count - 1] = line
        }
        return lines.filter { !$0.indices.isEmpty }
    }
}
