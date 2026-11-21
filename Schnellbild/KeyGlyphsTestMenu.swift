import SwiftUI
import AppKit

/// Menu items with every key the app shows, as key equivalents, for
/// `KeyGlyphsUITests` (only with `--ui-testing --key-glyphs-menu`): the test
/// photographs the menu, so the glyphs macOS draws for each key on the
/// runner's macOS can be compared with `KeyGlyphs`. Never shown otherwise.
struct KeyGlyphsTestMenu: View {
    static var shown: Bool { TestSwitches.has("--key-glyphs-menu") }

    private static func function(_ number: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(NSF1FunctionKey + number - 1))!))
    }

    private static let items: [(String, KeyEquivalent, EventModifiers)] = [
        ("glyph left", .leftArrow, .command), ("glyph right", .rightArrow, .command),
        ("glyph up", .upArrow, .command), ("glyph down", .downArrow, .command),
        ("glyph home", .home, .command), ("glyph end", .end, .command),
        ("glyph page up", .pageUp, .command), ("glyph page down", .pageDown, .command),
        ("glyph return", .return, .command), ("glyph delete", .delete, .command),
        ("glyph forward delete", .deleteForward, .command), ("glyph escape", .escape, .command),
        ("glyph tab", .tab, .command), ("glyph space", .space, .command),
        ("glyph f1", function(1), .command), ("glyph f5", function(5), .command),
        ("glyph f10", function(10), .command), ("glyph letter n", "n", .command),
        ("glyph minus", "-", .command), ("glyph plus", "+", .command),
        ("glyph all modifiers up", .upArrow, [.control, .option, .shift, .command]),
        ("glyph up alone", .upArrow, []), ("glyph home alone", .home, []),
    ]

    var body: some View {
        ForEach(Self.items, id: \.0) { item in
            Button(action: {}) { Text(verbatim: item.0) }
                .keyboardShortcut(item.1, modifiers: item.2)
        }
    }
}
