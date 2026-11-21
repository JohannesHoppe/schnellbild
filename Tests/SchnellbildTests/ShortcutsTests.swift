import XCTest
import SwiftUI
@testable import Schnellbild

/// The keys of every action (Settings → Keyboard): the stored form, the
/// presets, taking a key from another action, the preferences, and what a
/// typed key does in the window.
@MainActor
final class ShortcutsTests: XCTestCase {
    private func chord(_ stored: String) -> KeyChord { KeyChord(stored: stored)! }

    private func window(_ spy: FileActionsSpy, _ shortcuts: Shortcuts) -> WindowModel {
        let defaults = makeTestDefaults()
        let left = BrowserModel(defaults: defaults, fileActions: spy.actions)
        left.searchDebounce = .zero
        let window = WindowModel(left: left, defaults: defaults) {
            BrowserModel(defaults: defaults, fileActions: spy.actions, settingsPrefix: "rightPane.")
        }
        window.shortcuts = shortcuts
        return window
    }

    // MARK: Keys

    func testTheStoredFormReadsBack() {
        for action in ShortcutAction.allCases {
            for preset in ShortcutPreset.allCases {
                let keys = action.keys(in: preset)
                XCTAssertEqual(keys.count, (preset == .phiewer ? action.spec.phiewer ?? action.spec.standard : action.spec.standard).count,
                               "\(action) \(preset): every key reads")
                for key in keys { XCTAssertEqual(KeyChord(stored: key.stored), key, "\(action): \(key.stored)") }
            }
            if case .key(let key) = action.performer { XCTAssertNotNil(KeyChord(stored: key.stored)) }
        }
        XCTAssertEqual(chord("@$c"), KeyChord(.char("c"), command: true, shift: true))
        XCTAssertEqual(chord("^~$@left"), KeyChord(.left, command: true, shift: true, option: true, control: true))
        XCTAssertEqual(chord("@"), KeyChord(.char("@")), "a modifier sign alone is its key")
        XCTAssertEqual(chord("@@"), KeyChord(.char("@"), command: true))
        for garbage in ["", "@", "@f11", "left2", "@\u{F70E}", "\u{1}", "@ab"] where garbage != "@" {
            XCTAssertNil(KeyChord(stored: garbage), garbage)
        }
    }

    func testKeysAreShownAsOnApplesKeyboards() {
        let glyphs = KeyGlyphs.current
        XCTAssertEqual(chord("@$c").text, "⇧ + ⌘ + C")
        XCTAssertEqual(chord("^@s").text, "⌃ + ⌘ + S")
        XCTAssertEqual(chord("~left").text, "⌥ + \(glyphs.left)")
        XCTAssertEqual(chord("@$c").compactText, "⇧⌘C")
        XCTAssertEqual(chord("-").text, "−")
        XCTAssertEqual(chord("space").text, String(localized: "Space"))
        XCTAssertEqual(chord("space").idText, "space")
        XCTAssertEqual(chord("escape").text, "⎋")
        XCTAssertEqual(chord("escape").idText, "esc")
        XCTAssertEqual(chord("escape").buttonCaps.text, "esc")
        XCTAssertEqual(chord("@escape").buttonCaps.text, "⌘ + ⎋", "esc as a word only alone")
        XCTAssertEqual(chord("tab").idText, "Tab")
        XCTAssertEqual(chord("delete").text, "⌫")
        XCTAssertEqual(KeyChord(.char("="), command: true), chord("@+"), "= is the + key")
        XCTAssertEqual(KeyChord(.char("<"), shift: true), chord("<"), "⇧ is in the character")
        XCTAssertEqual(KeyChord(.char("C"), command: true, shift: true), chord("@$c"), "letters in lower case, ⇧ apart")
        XCTAssertNotEqual(KeyChord(.char("c"), command: true), chord("@$c"))
        let names = try! NSRegularExpression(pattern: "\\b(Backspace|Delete|Return|Enter|Esc|Escape|Tab|Home|End|space)\\b")
        for action in ShortcutAction.allCases {
            for key in action.keys(in: .schnellbild) + action.keys(in: .phiewer) {
                XCTAssertEqual(names.numberOfMatches(in: key.text, range: NSRange(key.text.startIndex..., in: key.text)), 0,
                               "\(action): “\(key.text)” names a key in English")
            }
        }
        XCTAssertEqual(chord("@delete").menuShortcut, KeyboardShortcut(.delete, modifiers: .command))
        XCTAssertEqual(chord("@$n").menuShortcut, KeyboardShortcut("n", modifiers: [.command, .shift]))
        XCTAssertEqual(chord("^1").menuShortcut, KeyboardShortcut("1", modifiers: .control))
        XCTAssertNil(chord("d").menuShortcut, "letters alone are taught by F1, not the menus")
        XCTAssertNil(chord("f9").menuShortcut)
    }

    // MARK: Presets

    func testThePresetsGiveEveryKeyToOneActionWhereItWorks() {
        for preset in ShortcutPreset.allCases {
            let actions = ShortcutAction.allCases
            for (i, a) in actions.enumerated() {
                for b in actions[(i + 1)...] where a.scope.overlaps(b.scope) {
                    let shared = Set(a.keys(in: preset)).intersection(b.keys(in: preset))
                    XCTAssertTrue(shared.isEmpty, "\(preset): \(a) and \(b) share \(shared.map(\.text))")
                }
                for key in a.keys(in: preset) { XCTAssertFalse(Shortcuts.isReserved(key), "\(preset) \(a): \(key.text)") }
            }
        }
    }

    func testAsInPhiewerTakesPhiewersKeysForWhatSchnellbildHas() {
        let s = Shortcuts(defaults: makeTestDefaults())
        XCTAssertEqual(s.preset, .schnellbild)
        XCTAssertEqual(s.keys(.toggleList), [chord("l")])
        s.choose(.phiewer)
        XCTAssertEqual(s.keys(.fullPreviousItem), [chord("left")], "← is the previous item")
        XCTAssertEqual(s.keys(.fullNextItem), [chord("right")])
        XCTAssertEqual(s.keys(.fullPrevious), [chord("@left")], "⌘← seeks in a video")
        XCTAssertEqual(s.keys(.fullNext), [chord("@right")])
        XCTAssertEqual(s.keys(.trash).first, chord("delete"), "⌫ deletes")
        XCTAssertEqual(s.keys(.gridBack), [], "⌫ is Delete there")
        XCTAssertFalse(s.keys(.closeFullView).contains(chord("delete")))
        XCTAssertEqual(s.keys(.gridRename).first, chord("@r"), "⌘R renames")
        XCTAssertEqual(s.keys(.fullRename).first, chord("@r"))
        XCTAssertEqual(s.keys(.reload), [], "⌘R is Rename there")
        XCTAssertEqual(s.keys(.toggleList), [chord("~@l")], "⌥⌘L: folder / thumbnail view")
        XCTAssertEqual(s.keys(.startSlideshow), [chord("~@s")], "⌥⌘S starts and stops the slideshow")
        XCTAssertTrue(s.keys(.endSlideshow).contains(chord("~@s")))
        XCTAssertEqual(s.keys(.bookmark), [chord("@d")], "no Duplicate here: ⌘D stays the bookmark")
        XCTAssertEqual(s.keys(.zoomIn), ShortcutAction.zoomIn.standardKeys, "⌘+ zooms in both")
        XCTAssertFalse(s.hasChanges, "the preset's keys are no change")
        XCTAssertTrue(s.differsFromStandard(.trash))
        XCTAssertFalse(s.differsFromStandard(.search))
        XCTAssertEqual(Shortcuts.differences(of: .phiewer), ShortcutAction.allCases.filter(s.differsFromStandard).count)
        XCTAssertEqual(Shortcuts.differences(of: .schnellbild), 0)
    }

    // MARK: Changing keys

    func testAKeyGivenToAnActionLeavesTheOneThatHadIt() {
        let s = Shortcuts(defaults: makeTestDefaults())
        XCTAssertEqual(s.conflicts(chord("@r"), for: .toggleList), [.reload])
        XCTAssertEqual(s.conflicts(chord("f"), for: .listUp), [], "the playlist's keys go before the others")
        XCTAssertEqual(s.conflicts(chord("s"), for: .playlist), [.endSlideshow])
        XCTAssertEqual(s.conflicts(chord("s"), for: .gridOpen), [.startSlideshow])
        s.assign(chord("@r"), to: .toggleList)
        XCTAssertEqual(s.keys(.toggleList), [chord("l"), chord("@r")], "one more")
        XCTAssertEqual(s.keys(.reload), [], "Reload lost it")
        XCTAssertTrue(s.isChanged(.toggleList))
        XCTAssertTrue(s.isChanged(.reload))
        s.assign(chord("j"), to: .toggleList, replacing: chord("l"))
        XCTAssertEqual(s.keys(.toggleList), [chord("j"), chord("@r")], "in place of L")
        s.assign(chord("j"), to: .toggleList)
        XCTAssertEqual(s.keys(.toggleList), [chord("j"), chord("@r")], "not twice")
        s.remove(chord("@r"), from: .toggleList)
        XCTAssertEqual(s.keys(.toggleList), [chord("j")])
        s.reset(.reload)
        XCTAssertEqual(s.keys(.reload), [chord("@r")])
        s.assign(chord("@q"), to: .reload)
        XCTAssertEqual(s.keys(.reload), [chord("@r")], "⌘Q stays the system's")
        s.reset(.toggleList)
        XCTAssertFalse(s.hasChanges)
        // Resetting takes the key back from whoever holds it now
        s.assign(chord("l"), to: .gridOpen)
        XCTAssertEqual(s.keys(.toggleList), [])
        s.reset(.toggleList)
        XCTAssertEqual(s.keys(.toggleList), [chord("l")])
        XCTAssertEqual(s.keys(.gridOpen), ShortcutAction.gridOpen.standardKeys)
        s.assign(chord("j"), to: .mark)
        s.resetAll()
        XCTAssertFalse(s.hasChanges)
        XCTAssertEqual(s.preset, .schnellbild)
    }

    func testTheKeysAreKeptAndBadEntriesLeftOut() {
        let defaults = makeTestDefaults()
        let s = Shortcuts(defaults: defaults)
        s.choose(.phiewer)
        s.assign(chord("j"), to: .toggleList, replacing: chord("~@l"))
        s.remove(chord("v"), from: .subtitles)
        let again = Shortcuts(defaults: defaults)
        XCTAssertEqual(again.preset, .phiewer)
        XCTAssertEqual(again.keys(.toggleList), [chord("j")])
        XCTAssertEqual(again.keys(.subtitles), [], "no key is kept as no key")
        XCTAssertEqual(again.keys(.trash), s.keys(.trash))
        XCTAssertEqual(defaults.dictionary(forKey: Shortcuts.customKey)?.count, 2, "only what differs from the preset")

        // Old or broken entries: unknown actions and presets, keys that
        // don't read, reserved keys, a key two actions claim
        defaults.set("someday", forKey: Shortcuts.presetKey)
        defaults.set(["noSuchAction": ["j"], "subtitles": "v", "mark": ["@q", "f11", "y", "y"],
                      "listShow": ["@d"], "toggleList": ["l"]], forKey: Shortcuts.customKey)
        let read = Shortcuts(defaults: defaults)
        XCTAssertEqual(read.preset, .schnellbild)
        XCTAssertEqual(read.keys(.subtitles), [chord("v")], "not a list: left out")
        XCTAssertEqual(read.keys(.mark), [chord("y")], "reserved, unreadable and doubled keys left out")
        XCTAssertEqual(read.keys(.listShow), [chord("@d")], "the playlist's key and the bookmark's never meet: both keep it")
        XCTAssertEqual(read.keys(.bookmark), [chord("@d")])
        defaults.set(["gridOpen": ["l"]], forKey: Shortcuts.customKey)
        let claimed = Shortcuts(defaults: defaults)
        XCTAssertEqual(claimed.keys(.gridOpen), [chord("l")], "the changed action keeps the key")
        XCTAssertEqual(claimed.keys(.toggleList), [], "the other one gives it up")
        defaults.set(42, forKey: Shortcuts.customKey)
        XCTAssertFalse(Shortcuts(defaults: defaults).hasChanges, "something else entirely: the preset")
    }

    // MARK: What a typed key does

    func testAKeyResolvesByWhereItIsTyped() {
        let s = Shortcuts(defaults: makeTestDefaults())
        XCTAssertEqual(s.resolve(chord("l"), in: .grid), .standard)
        XCTAssertEqual(s.resolve(chord("q"), in: .grid), .free)
        s.assign(chord("j"), to: .toggleList, replacing: chord("l"))
        XCTAssertEqual(s.resolve(chord("j"), in: .grid), .custom(.toggleList))
        XCTAssertEqual(s.resolve(chord("l"), in: .grid), .blocked, "L belongs to nothing now")
        XCTAssertEqual(s.resolve(chord("l"), in: .show), .free, "the slideshow never had it")
        // A letter with ⇧ no action has counts as the letter: taken from its action, given to another
        XCTAssertEqual(s.resolve(chord("$l"), in: .grid), .blocked, "⇧L doesn't sneak past")
        XCTAssertEqual(s.resolve(chord("$j"), in: .grid), .custom(.toggleList))
        XCTAssertEqual(s.resolve(chord("$q"), in: .grid), .free)
        s.assign(chord("b"), to: .bossKey, replacing: chord("x"))
        XCTAssertEqual(s.resolve(chord("$x"), in: .grid), .blocked, "the boss key moved: ⇧X doesn't hide the windows")
        XCTAssertEqual(s.resolve(chord("$b"), in: .grid), .custom(.bossKey))
        // The playlist's keys first while it has them, then the slideshow's
        XCTAssertEqual(s.resolve(chord("up"), in: [.show, .list]), .standard)
        XCTAssertEqual(s.resolve(chord("escape"), in: [.show, .list]), .standard)
        s.assign(chord("u"), to: .listUp, replacing: chord("up"))
        XCTAssertEqual(s.resolve(chord("up"), in: [.show, .list]), .custom(.fullUp), "↑ is the slideshow's again (volume), past the playlist")
        s.assign(chord("t"), to: .listTakeOut, replacing: chord("delete"))
        XCTAssertEqual(s.resolve(chord("delete"), in: [.show, .list]), .custom(.endSlideshow),
                       "⌫ ends the slideshow, not through the playlist")
    }

    func testTypedKeysUseTheKeysAsSet() async throws {
        let tree = try TempTree(self)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file(name) }
        let spy = FileActionsSpy()
        let s = Shortcuts(defaults: makeTestDefaults())
        let w = window(spy, s)
        let m = w.left
        await openAndWait(m, tree.root)
        m.selectEntry(named: "a.jpg")

        // Schnellbild's keys as ever
        XCTAssertTrue(w.typeKey(.char("l")))
        XCTAssertEqual(m.viewMode, .list)
        XCTAssertTrue(w.typeKey(.char("l")))
        XCTAssertEqual(m.viewMode, .grid)

        // L moved to J
        s.assign(chord("j"), to: .toggleList, replacing: chord("l"))
        XCTAssertTrue(w.typeKey(.char("j")))
        XCTAssertEqual(m.viewMode, .list, "J shows the list")
        XCTAssertFalse(w.typeKey(.char("l")), "L does nothing now")
        XCTAssertEqual(m.viewMode, .list)
        XCTAssertTrue(m.lastKeyPress?.matches(.char("l"), command: false, shift: false) == true,
                      "the mini keyboard lights the action's key")
        XCTAssertFalse(w.typeKey(.char("j"), textEditing: true), "letters typed into a field stay the field's")
        XCTAssertEqual(m.viewMode, .list)

        // A key with ⌘ and ⌥, an F-key, and an action of the menus
        s.assign(chord("~@k"), to: .gridNext)
        m.viewMode = .grid
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(w.typeKey(.char("k"), command: true, option: true))
        XCTAssertEqual(m.selectedEntry?.name, "b.jpg")
        s.assign(chord("f9"), to: .gridFirst)
        XCTAssertTrue(w.typeKey(.f9))
        XCTAssertEqual(m.selection, 0)

        // As in Phiewer: ⌘R renames, ⌫ moves to the Trash
        s.choose(.phiewer)
        m.selectEntry(named: "b.jpg")
        XCTAssertTrue(w.typeKey(.char("r"), command: true))
        XCTAssertEqual(m.renameTarget?.name, "b.jpg", "⌘R renames")
        m.renameTarget = nil
        XCTAssertTrue(w.typeKey(.backspace))
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["b.jpg"], "⌫ moves to the Trash")
        XCTAssertTrue(w.typeKey(.char("l"), command: true, option: true))
        XCTAssertEqual(m.viewMode, .list, "⌥⌘L: the list")
        m.viewMode = .grid

        // The full view: ← and ⌘← swap, Esc still goes back, ⌫ no longer does
        m.selectEntry(named: "a.jpg")
        XCTAssertTrue(w.typeKey(.space))   // Space opens, as in both
        XCTAssertEqual(m.mode, .detail)
        XCTAssertTrue(w.typeKey(.right))
        XCTAssertEqual(m.selectedEntry?.name, "c.jpg", "→ is the next item")
        XCTAssertTrue(w.typeKey(.left, command: true))
        XCTAssertEqual(m.selectedEntry?.name, "a.jpg", "⌘← on a picture: the previous one")
        XCTAssertTrue(w.typeKey(.escape))
        XCTAssertEqual(m.mode, .grid)
    }

    // MARK: Searching in Settings → Keyboard

    func testTheSearchFindsActionsByNameAndByKey() {
        let s = Shortcuts(defaults: makeTestDefaults())
        func found(_ search: String) -> Set<ShortcutAction> { Set(ShortcutAction.allCases.filter { s.matches($0, search: search) }) }
        XCTAssertEqual(found("").count, ShortcutAction.allCases.count, "nothing typed: every action")
        XCTAssertEqual(found("   ").count, ShortcutAction.allCases.count)
        XCTAssertEqual(found("rename"), [.gridRename, .fullRename], "by name, any case")
        XCTAssertEqual(found("⌘R"), [.reload, .reveal], "⌘R and ⇧⌘R hold ⌘R")
        XCTAssertEqual(found("cmd r"), found("⌘R"), "modifiers by their names")
        XCTAssertEqual(found("shift+cmd+r"), [.reveal])
        XCTAssertEqual(found("cmd shift r"), [.reveal], "in any order")
        XCTAssertEqual(found("⌘+"), [.largerThumbnails, .zoomIn], "+ at the end is the key")
        XCTAssertEqual(found("ctrl cmd s"), [.nextSubtitle])
        XCTAssertTrue(found("F7").contains(.newFolder))
        XCTAssertTrue(found("no such thing").isEmpty)
        s.choose(.phiewer)
        XCTAssertEqual(found("⌘R").intersection([.gridRename, .fullRename, .reload]), [.gridRename, .fullRename],
                       "the keys as set: ⌘R renames as in Phiewer")
        XCTAssertEqual(Shortcuts.keySearch("option command l"), "⌥⌘L")
        XCTAssertEqual(Shortcuts.keySearch("esc"), "⎋")
        XCTAssertEqual(found("⌘ + R"), found("⌘R"), "as a tooltip writes it")
        XCTAssertTrue(found(chord("@up").compactText).contains(.enclosingFolder))
        XCTAssertEqual(Shortcuts.keySearch("cmd up", glyphs: .triangles), "⌘▲")
        XCTAssertEqual(Shortcuts.keySearch("⌘↑", glyphs: .triangles), "⌘▲", "either version's arrows")
        XCTAssertEqual(Shortcuts.keySearch("⌘▲", glyphs: .arrows), "⌘↑")
        XCTAssertEqual(Shortcuts.keySearch("home", glyphs: .arrows), "↖")
    }

    // MARK: Glyphs and caps

    func testTheGlyphsAreTheMenusOfTheRunningMacOS() {
        XCTAssertEqual(KeyGlyphs.forMacOS(15), .arrows)
        XCTAssertEqual(KeyGlyphs.forMacOS(26), .triangles)
        XCTAssertEqual(KeyGlyphs.forMacOS(27), .triangles, "later versions as 26")
        XCTAssertEqual(KeyGlyphs.current, KeyGlyphs.forMacOS(ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
        let keys: [(String, String, String)] = [
            ("left", "←", "◀"), ("right", "→", "▶"), ("up", "↑", "▲"), ("down", "↓", "▼"), ("home", "↖", "↖"), ("end", "↘", "↘"),
            ("return", "↩", "↩"), ("delete", "⌫", "⌫"), ("escape", "⎋", "⎋"), ("tab", "⇥", "⇥"), ("f1", "F1", "F1"), ("x", "X", "X"),
        ]
        for (stored, on15, on26) in keys {
            XCTAssertEqual(chord(stored).keyText(.arrows), on15, stored)
            XCTAssertEqual(chord(stored).keyText(.triangles), on26, stored)
        }
        XCTAssertEqual(KeyCaps.chord(chord("@up"), glyphs: .triangles).text, "⌘ + ▲", "the Go menu's Enclosing Folder")
        XCTAssertEqual(KeyCaps.chord(chord("@up"), glyphs: .arrows).text, "⌘ + ↑")
        XCTAssertEqual(chord("right").idText, "→", "the mini keyboard's identifiers stay")
        XCTAssertEqual(chord("@up").idText, "⌘↑")
    }

    func testHomeAndEndSayHowToTypeThemWithFn() {
        XCTAssertEqual(KeyCaps.chord(chord("home"), glyphs: .triangles).text, "↖ (fn + ◀)")
        XCTAssertEqual(KeyCaps.chord(chord("end"), glyphs: .triangles).text, "↘ (fn + ▶)")
        XCTAssertEqual(KeyCaps.chord(chord("home"), glyphs: .arrows).text, "↖ (fn + ←)")
        XCTAssertEqual(KeyCaps.chord(chord("end"), glyphs: .arrows).text, "↘ (fn + →)")
        XCTAssertEqual(KeyCaps.chord(chord("home"), glyphs: .arrows).parts,
                       [.cap("↖"), .open, .cap("fn"), .plus, .cap("←"), .close])
        XCTAssertEqual(KeyCaps.chord(chord("$end"), glyphs: .arrows).text, "⇧ + ↘ (⇧ + fn + →)", "with the modifiers")
        XCTAssertEqual(KeyCaps.chord(chord("left"), glyphs: .arrows).text, "←", "other keys need no fn")
    }

    func testEachKeyIsItsOwnCap() {
        let all = KeyChord(.char("n"), command: true, shift: true, option: true, control: true)
        XCTAssertEqual(all.caps.parts, [.cap("⌃"), .plus, .cap("⌥"), .plus, .cap("⇧"), .plus, .cap("⌘"), .plus, .cap("N")],
                       "modifiers in Apple's order, then the key")
        XCTAssertEqual(all.text, "⌃ + ⌥ + ⇧ + ⌘ + N")
        XCTAssertEqual(chord("x").caps.parts, [.cap("X")])
        let thrice = KeyCaps.sequence(chord("x"), count: 3)
        XCTAssertEqual(thrice.parts, [.cap("X"), .then, .cap("X"), .then, .cap("X")], "a sequence: no sign between")
        XCTAssertEqual(thrice.text, "X X X")
        XCTAssertEqual(KeyCaps.either([chord("space").caps, chord("f3").caps]).text, String(localized: "Space") + " / F3")
        XCTAssertEqual(KeyCaps.range(chord("@1").caps, chord("@5").caps).text, "⌘ + 1 … ⌘ + 5")
        XCTAssertEqual(KeyCaps.either([]).parts, [], "nothing: no separators")
        let s = Shortcuts(defaults: makeTestDefaults())
        XCTAssertEqual(HelpKeys.sequence(.markAll, count: 2).text(s), "⌘ + A ⌘ + A")
        XCTAssertEqual(s.caps(.info).parts, [.cap("I"), .or, .cap("⌘"), .plus, .cap("I")])
    }

    // MARK: Where keys are shown

    func testTheHelpAndTheMiniKeyboardShowTheKeysAsSet() {
        let s = Shortcuts(defaults: makeTestDefaults())
        func helpKeys(_ action: String) -> String? {
            ShortcutsHelpView.groups(s).flatMap(\.shortcuts).first { $0.action == String(localized: String.LocalizationValue(action)) }?.keys
        }
        XCTAssertEqual(helpKeys("Grid or list (a click on a column sorts by it)"), "L")
        let glyphs = KeyGlyphs.current
        XCTAssertEqual(helpKeys("Larger / smaller thumbnails"), "+ / − · ⌘ + + / ⌘ + −")
        XCTAssertEqual(helpKeys("Previous / next item"), "\(glyphs.left) / \(glyphs.right)")
        XCTAssertEqual(helpKeys("First / last item"), "↖ (fn + \(glyphs.left)) / ↘ (fn + \(glyphs.right))")
        XCTAssertEqual(helpKeys("Sort by name, kind, date modified, date taken, size, distance (again: reverse)"), "⌘ + 1 … ⌘ + 6")
        XCTAssertEqual(helpKeys("Copy / move the marked items into the other pane's folder"), "⇧ + ⌘ + C / ⇧ + ⌘ + M · F5 / F6")
        XCTAssertEqual(helpKeys("Undo / redo renaming, trashing, moving, copying, a new folder"), "⌘ + Z / ⇧ + ⌘ + Z")
        let sort = ShortcutsHelpView.groups(s).flatMap(\.shortcuts).first { $0.keys == "⌘ + 1 … ⌘ + 6" }?.caps
        XCTAssertEqual(sort?.parts, [.cap("⌘"), .plus, .cap("1"), .through, .cap("⌘"), .plus, .cap("6")], "a cap per key")
        s.assign(chord("j"), to: .toggleList, replacing: chord("l"))
        s.remove(chord("right"), from: .gridNext)
        s.assign(chord("^@1"), to: .sortName, replacing: chord("@1"))
        XCTAssertEqual(helpKeys("Grid or list (a click on a column sorts by it)"), "J")
        XCTAssertEqual(helpKeys("Previous / next item"), glyphs.left)
        XCTAssertEqual(helpKeys("Sort by name, kind, date modified, date taken, size, distance (again: reverse)"),
                       "⌃ + ⌘ + 1 / ⌘ + 2 / ⌘ + 3 / ⌘ + 4 / ⌘ + 5 / ⌘ + 6")
        XCTAssertNotNil(ShortcutsHelpView.groups(s).flatMap(\.shortcuts).first { $0.action == String(localized: "Quit (F10 asks first)") })

        let grid = MiniKeyboard.keys(for: .grid)
        let next = grid.first { $0.action == .gridNext }!
        XCTAssertEqual(next.id, "→", "the key's identifier stays")
        XCTAssertNil(next.cap(s), "no key: left out")
        s.assign(chord("n"), to: .gridNext)
        XCTAssertEqual(next.cap(s), chord("n"))
        let search = grid.first { $0.action == .search }!
        XCTAssertEqual(search.cap(s), chord("@f"))
        XCTAssertEqual(search.cap(s)?.caps.parts, [.cap("⌘"), .plus, .cap("F")], "a cap per key")
        XCTAssertEqual(s.menuShortcut(.search), KeyboardShortcut("f", modifiers: .command))
        s.assign(chord("/"), to: .search, replacing: chord("@f"))
        XCTAssertEqual(search.cap(s), chord("/"))
        XCTAssertNil(s.menuShortcut(.search), "a key without ⌘ isn't in the menu")
        s.assign(chord("~@f"), to: .search)
        XCTAssertEqual(s.menuShortcut(.search), KeyboardShortcut("f", modifiers: [.command, .option]))
    }
}
