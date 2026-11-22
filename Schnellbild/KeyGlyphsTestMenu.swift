import SwiftUI
import AppKit

/// Menu items with every key the app shows, as key equivalents, for
/// `KeyGlyphsUITests` (only with `--ui-testing --key-glyphs-menu`): the test
/// photographs the menu, so the glyphs macOS draws for each key on the
/// runner's macOS can be compared with `KeyGlyphs`. Never shown otherwise.
/// With ⌃⌥, which none of the app's own items has: a menu shows a key
/// equivalent once, an item with the same key as another shows none.
struct KeyGlyphsTestMenu: View {
    static var shown: Bool { TestSwitches.has("--key-glyphs-menu") }

    private static func function(_ number: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(NSF1FunctionKey + number - 1))!))
    }

    private static let keys: [(String, KeyEquivalent)] = [
        ("left", .leftArrow), ("right", .rightArrow), ("up", .upArrow), ("down", .downArrow),
        ("home", .home), ("end", .end), ("page up", .pageUp), ("page down", .pageDown),
        ("return", .return), ("delete", .delete), ("forward delete", .deleteForward), ("escape", .escape),
        ("tab", .tab), ("space", .space), ("f1", function(1)), ("f5", function(5)), ("f10", function(10)),
        ("letter n", "n"), ("minus", "-"), ("plus", "+"),
    ]

    private static let items: [(String, KeyEquivalent, EventModifiers)] =
        keys.map { ("glyph \($0.0)", $0.1, [.control, .option]) } + [
            ("glyph all modifiers up", .upArrow, [.control, .option, .shift, .command]),
            ("glyph up alone", .upArrow, []), ("glyph home alone", .home, []),
            ("glyph return alone", .return, []), ("glyph delete alone", .delete, []),
        ]

    var body: some View {
        ForEach(Self.items, id: \.0) { item in
            Button(action: {}) { Text(verbatim: item.0) }
                .keyboardShortcut(item.1, modifiers: item.2)
        }
    }
}
