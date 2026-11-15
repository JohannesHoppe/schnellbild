import SwiftUI
import AppKit

/// A key with its modifiers, as the user types it. Letters are kept in
/// lower case with ⇧ as a modifier of its own; other characters already
/// carry what ⇧ made of them ("<", "?"), so ⇧ isn't part of them. "=" is
/// "+" (the same key on US keyboards, where "+" needs ⇧).
struct KeyChord: Hashable {
    let key: BrowserModel.KeyInput
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    init(_ key: BrowserModel.KeyInput, command: Bool = false, shift: Bool = false,
         option: Bool = false, control: Bool = false) {
        var key = key
        var shift = shift
        if case .char(let typed) = key {
            let lower = typed.lowercased()
            let character = lower.count == 1 ? Character(lower) : typed
            key = .char(character == "=" ? "+" : character)
            if !typed.isLetter { shift = false }
        }
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    // MARK: Stored form

    /// Named keys in the stored form; every other key is its character.
    private static let names: [(String, BrowserModel.KeyInput)] = [
        ("left", .left), ("right", .right), ("up", .up), ("down", .down), ("space", .space),
        ("return", .enter), ("escape", .escape), ("delete", .backspace), ("home", .home), ("end", .end),
        ("insert", .insert), ("tab", .tab), ("f1", .f1), ("f2", .f2), ("f3", .f3), ("f4", .f4),
        ("f5", .f5), ("f6", .f6), ("f7", .f7), ("f8", .f8), ("f9", .f9), ("f10", .f10),
    ]

    /// The form kept in the preferences: the modifiers as in Cocoa's key
    /// bindings (^ ⌃, ~ ⌥, $ ⇧, @ ⌘), then the key's name or character:
    /// "@$c" is ⇧⌘C, "~left" ⌥←, "+" the plus key.
    var stored: String {
        var text = ""
        if control { text += "^" }
        if option { text += "~" }
        if shift { text += "$" }
        if command { text += "@" }
        if case .char(let c) = key { return text + String(c) }
        return text + (Self.names.first { $0.1 == key }?.0 ?? "")
    }

    /// Reads the stored form; nil for anything else.
    init?(stored: String) {
        var rest = Substring(stored)
        var command = false, shift = false, option = false, control = false
        // A modifier sign alone is the key itself ("@" on its own is the @ key)
        while rest.count > 1, let first = rest.first, "^~$@".contains(first) {
            switch first {
            case "^": control = true
            case "~": option = true
            case "$": shift = true
            default:  command = true
            }
            rest = rest.dropFirst()
        }
        let name = String(rest)
        let key: BrowserModel.KeyInput
        if let named = Self.names.first(where: { $0.0 == name })?.1 {
            key = named
        } else if name.count == 1, let c = name.first, Self.isTypable(c) {
            key = .char(c)
        } else {
            return nil
        }
        self.init(key, command: command, shift: shift, option: option, control: control)
    }

    /// A character a key types that a shortcut can use: not a control
    /// character, nor one of AppKit's function key codes (F11, Page Up …).
    static func isTypable(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return scalar.value >= 0x21 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }

    // MARK: Shown

    /// As Apple's keyboards and menus show it: ⌃⌥⇧⌘ in that order, then the
    /// key (⌫ ↩ ⎋ ⇥ ↖ ↘, letters in capitals, the space bar by its name in
    /// the user's language).
    var text: String { modifierText + keyText }

    /// The same, with words in English where `text` has words: stable in
    /// every language, for the mini keyboard's accessibility identifiers.
    var idText: String {
        switch key {
        case .space:  return modifierText + "space"
        case .escape: return modifierText + "esc"
        case .tab:    return modifierText + "Tab"
        default:      return text
        }
    }

    /// On a button's key cap: Esc as "esc", as on the keyboard and the
    /// sheets' buttons; every other key as `text`.
    var capText: String { key == .escape && modifierText.isEmpty ? "esc" : text }

    private var modifierText: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
    }

    private var keyText: String {
        switch key {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .space: return String(localized: "Space")
        case .enter: return "↩"
        case .escape: return "⎋"
        case .backspace: return "⌫"
        case .home: return "↖"
        case .end: return "↘"
        case .insert: return "Insert"
        case .tab: return "⇥"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .char(let c):
            if c == "-" { return "−" }
            let upper = String(c).uppercased()
            return upper.count == 1 ? upper : String(c)
        }
    }

    /// The key equivalent a menu item shows and answers to: only keys with
    /// ⌘ or ⌃ (letters and F-keys alone are taught by F1 and the mini
    /// keyboard; a menu would also take them while typing).
    var menuShortcut: KeyboardShortcut? {
        guard command || control else { return nil }
        let equivalent: KeyEquivalent
        switch key {
        case .left: equivalent = .leftArrow
        case .right: equivalent = .rightArrow
        case .up: equivalent = .upArrow
        case .down: equivalent = .downArrow
        case .space: equivalent = .space
        case .enter: equivalent = .return
        case .escape: equivalent = .escape
        case .backspace: equivalent = .delete
        case .home: equivalent = .home
        case .end: equivalent = .end
        case .tab: equivalent = .tab
        case .insert: return nil
        case .char(let c): equivalent = KeyEquivalent(c)
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10:
            let number = Self.functionKeys.firstIndex(of: key) ?? 0
            guard let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + number)) else { return nil }
            equivalent = KeyEquivalent(Character(scalar))
        }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    private static let functionKeys: [BrowserModel.KeyInput] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10]

    var isFunctionKey: Bool { Self.functionKeys.contains(key) }

    /// The key an event typed, by the key on the keyboard (on a layout
    /// without Latin letters, as on the user's Latin layout, as the menus
    /// read it); nil for a key no shortcut can use.
    static func from(_ event: NSEvent) -> KeyChord? {
        let flags = event.modifierFlags
        let characters = event.charactersIgnoringModifiers ?? ""
        guard let key = ContentView.keyInput(code: event.keyCode, characters: characters, latin: {
            LatinKeys.character(for: event.keyCode, shift: flags.contains(.shift))
        }) else { return nil }
        if case .char(let c) = key, !isTypable(c) { return nil }
        return KeyChord(key, command: flags.contains(.command), shift: flags.contains(.shift),
                        option: flags.contains(.option), control: flags.contains(.control))
    }
}

/// Where an action's keys work. The playlist's keys (`list`) work while it
/// has the keys (after a click in it), ahead of the slideshow's.
struct ShortcutScope: OptionSet, Hashable {
    let rawValue: Int
    static let grid = ShortcutScope(rawValue: 1)
    static let full = ShortcutScope(rawValue: 2)
    static let show = ShortcutScope(rawValue: 4)
    static let list = ShortcutScope(rawValue: 8)

    func overlaps(_ other: ShortcutScope) -> Bool { !intersection(other).isEmpty }
}

/// The groups of actions, as F1 shows them.
enum ShortcutGroup: CaseIterable {
    case grid, fullView, videos, slideshow, dual, search, general

    var name: String {
        switch self {
        case .grid:      return String(localized: "Grid")
        case .fullView:  return String(localized: "Full view")
        case .videos:    return String(localized: "Videos")
        case .slideshow: return String(localized: "Slideshow")
        case .dual:      return String(localized: "Dual pane and marking")
        case .search:    return String(localized: "Search field")
        case .general:   return String(localized: "Grid and full view")
        }
    }
}

/// Every action that has keys. Each one's keys can be changed; the presets
/// give them their keys first (`standardKeys`, Schnellbild's own, and those
/// as in Phiewer).
enum ShortcutAction: String, CaseIterable {
    // Grid
    case gridPrevious, gridNext, gridRowUp, gridRowDown, gridOpen, gridBack, gridFirst, gridLast
    case toggleList, largerThumbnails, smallerThumbnails, gridRename, newFolder, trash, gridClear
    // Full view (and the slideshow, where it acts alike)
    case fullPrevious, fullNext, fullPreviousItem, fullNextItem, fullFineBack, fullFineAhead, fullUp, fullDown
    case fullSpace, zoomIn, zoomOut, zoomFit, zoomActual, rotateLeft, rotateRight, info, fullRename, closeFullView
    // Videos
    case subtitles, nextSubtitle, nextAudio, slower, faster, normalSpeed
    // Slideshow
    case startSlideshow, showPause, playlist, listUp, listDown, listShow, listTakeOut, endSlideshow
    // Dual pane and marking
    case toggleDual, switchPane, copyToOther, moveToOther, mark, markAll
    // Search field
    case search
    // Grid and full view
    case back, forward, enclosingFolder, reload, sortName, sortKind, sortModified, sortTaken, sortSize, sortDistance
    case fullScreen, enhance, adjust, openFolder, newWindow, reveal, openDefault, menus, quit
    case miniKeyboard, bookmark, bookmark1, bookmark2, bookmark3, bookmark4, bookmark5
    case bookmark6, bookmark7, bookmark8, bookmark9, bossKey, help

    /// How the action is carried out: through the window's and the pane's
    /// key bindings with the key it has as Schnellbild's (`key`), or by
    /// `WindowModel.perform` (what a menu item does, F9, F10, the boss key).
    enum Performer: Equatable {
        case key(KeyChord)
        case command
    }

    struct Spec {
        let group: ShortcutGroup
        let scope: ShortcutScope
        let standard: [String]
        /// As in Phiewer, where Phiewer's keys differ; nil: Schnellbild's.
        var phiewer: [String]? = nil
        let performer: String?
    }

    private static let gridAndFull: ShortcutScope = [.grid, .full]
    private static let viewing: ShortcutScope = [.full, .show]
    private static let everywhere: ShortcutScope = [.grid, .full, .show]

    var spec: Spec {
        switch self {
        case .gridPrevious:      return Spec(group: .grid, scope: .grid, standard: ["left"], performer: "left")
        case .gridNext:          return Spec(group: .grid, scope: .grid, standard: ["right"], performer: "right")
        case .gridRowUp:         return Spec(group: .grid, scope: .grid, standard: ["up"], performer: "up")
        case .gridRowDown:       return Spec(group: .grid, scope: .grid, standard: ["down"], performer: "down")
        case .gridOpen:          return Spec(group: .grid, scope: .grid, standard: ["space", "f3"], performer: "space")
        case .gridBack:          return Spec(group: .grid, scope: .grid, standard: ["delete"], phiewer: [], performer: "delete")
        case .gridFirst:         return Spec(group: .grid, scope: .grid, standard: ["home"], performer: "home")
        case .gridLast:          return Spec(group: .grid, scope: .grid, standard: ["end"], performer: "end")
        case .toggleList:        return Spec(group: .grid, scope: Self.gridAndFull, standard: ["l"], phiewer: ["~@l"], performer: "l")
        case .largerThumbnails:  return Spec(group: .grid, scope: .grid, standard: ["+", "@+"], performer: "+")
        case .smallerThumbnails: return Spec(group: .grid, scope: .grid, standard: ["-", "@-"], performer: "-")
        case .gridRename:        return Spec(group: .grid, scope: .grid, standard: ["return", "f2", "$f6"],
                                             phiewer: ["@r", "return", "f2", "$f6"], performer: "f2")
        case .newFolder:         return Spec(group: .grid, scope: Self.gridAndFull, standard: ["@$n", "f7"], performer: "f7")
        case .trash:             return Spec(group: .grid, scope: Self.gridAndFull, standard: ["@delete", "f8"],
                                             phiewer: ["delete", "@delete", "f8"], performer: nil)
        case .gridClear:         return Spec(group: .grid, scope: .grid, standard: ["escape"], performer: "escape")

        case .fullPrevious:      return Spec(group: .fullView, scope: Self.viewing, standard: ["left"], phiewer: ["@left"], performer: "left")
        case .fullNext:          return Spec(group: .fullView, scope: Self.viewing, standard: ["right"], phiewer: ["@right"], performer: "right")
        case .fullPreviousItem:  return Spec(group: .fullView, scope: Self.viewing, standard: ["@left"], phiewer: ["left"], performer: "@left")
        case .fullNextItem:      return Spec(group: .fullView, scope: Self.viewing, standard: ["@right"], phiewer: ["right"], performer: "@right")
        case .fullFineBack:      return Spec(group: .fullView, scope: Self.viewing, standard: ["$left"], performer: "$left")
        case .fullFineAhead:     return Spec(group: .fullView, scope: Self.viewing, standard: ["$right"], performer: "$right")
        case .fullUp:            return Spec(group: .fullView, scope: Self.viewing, standard: ["up"], performer: "up")
        case .fullDown:          return Spec(group: .fullView, scope: Self.viewing, standard: ["down"], performer: "down")
        case .fullSpace:         return Spec(group: .fullView, scope: .full, standard: ["space"], performer: "space")
        case .zoomIn:            return Spec(group: .fullView, scope: Self.viewing, standard: ["+", "@+"], performer: "+")
        case .zoomOut:           return Spec(group: .fullView, scope: Self.viewing, standard: ["-", "@-"], performer: "-")
        case .zoomFit:           return Spec(group: .fullView, scope: Self.viewing, standard: ["0"], performer: "0")
        case .zoomActual:        return Spec(group: .fullView, scope: Self.viewing, standard: ["1"], performer: "1")
        case .rotateLeft:        return Spec(group: .fullView, scope: Self.viewing, standard: ["~left"], performer: "~left")
        case .rotateRight:       return Spec(group: .fullView, scope: Self.viewing, standard: ["~right"], performer: "~right")
        // The Inspector: I everywhere, ⌘I as the Finder's Get Info (the Actions menu)
        case .info:              return Spec(group: .general, scope: Self.everywhere, standard: ["i", "@i"], performer: "i")
        case .fullRename:        return Spec(group: .fullView, scope: .full, standard: ["f2"], phiewer: ["@r", "f2"], performer: "f2")
        case .closeFullView:     return Spec(group: .fullView, scope: .full, standard: ["escape", "delete", "return"],
                                             phiewer: ["escape", "return"], performer: "escape")

        case .subtitles:         return Spec(group: .videos, scope: Self.viewing, standard: ["v"], performer: "v")
        case .nextSubtitle:      return Spec(group: .videos, scope: Self.viewing, standard: ["^@s"], performer: nil)
        case .nextAudio:         return Spec(group: .videos, scope: Self.viewing, standard: ["^@a"], performer: nil)
        case .slower:            return Spec(group: .videos, scope: Self.viewing, standard: ["<"], performer: "<")
        case .faster:            return Spec(group: .videos, scope: Self.viewing, standard: [">"], performer: ">")
        case .normalSpeed:       return Spec(group: .videos, scope: Self.viewing, standard: ["@\\"], performer: nil)

        case .startSlideshow:    return Spec(group: .slideshow, scope: Self.gridAndFull, standard: ["s"], phiewer: ["~@s"], performer: "s")
        case .showPause:         return Spec(group: .slideshow, scope: .show, standard: ["space"], performer: "space")
        case .playlist:          return Spec(group: .slideshow, scope: .show, standard: ["p"], performer: "p")
        case .listUp:            return Spec(group: .slideshow, scope: .list, standard: ["up"], performer: "up")
        case .listDown:          return Spec(group: .slideshow, scope: .list, standard: ["down"], performer: "down")
        case .listShow:          return Spec(group: .slideshow, scope: .list, standard: ["return"], performer: "return")
        case .listTakeOut:       return Spec(group: .slideshow, scope: .list, standard: ["delete"], performer: "delete")
        case .endSlideshow:      return Spec(group: .slideshow, scope: .show, standard: ["escape", "s", "return", "delete"],
                                             phiewer: ["escape", "~@s", "return", "delete"], performer: "escape")

        case .toggleDual:        return Spec(group: .dual, scope: Self.gridAndFull, standard: ["d", "^o"], performer: "d")
        case .switchPane:        return Spec(group: .dual, scope: Self.gridAndFull, standard: ["tab"], performer: "tab")
        case .copyToOther:       return Spec(group: .dual, scope: Self.gridAndFull, standard: ["@$c", "f5"], performer: "@$c")
        case .moveToOther:       return Spec(group: .dual, scope: Self.gridAndFull, standard: ["@$m", "f6"], performer: "@$m")
        case .mark:              return Spec(group: .dual, scope: .grid, standard: ["m", "insert"], performer: "m")
        case .markAll:           return Spec(group: .dual, scope: .grid, standard: ["@a"], performer: "@a")

        case .search:            return Spec(group: .search, scope: Self.gridAndFull, standard: ["@f"], performer: "@f")

        case .back:              return Spec(group: .general, scope: Self.gridAndFull, standard: ["@["], performer: "@[")
        case .forward:           return Spec(group: .general, scope: Self.gridAndFull, standard: ["@]"], performer: "@]")
        case .enclosingFolder:   return Spec(group: .general, scope: Self.gridAndFull, standard: ["@up"], performer: "@up")
        case .reload:            return Spec(group: .general, scope: Self.gridAndFull, standard: ["@r"], phiewer: [], performer: nil)
        case .sortName:          return Spec(group: .general, scope: Self.gridAndFull, standard: ["@1"], performer: nil)
        case .sortKind:          return Spec(group: .general, scope: Self.gridAndFull, standard: ["@2"], performer: nil)
        case .sortModified:      return Spec(group: .general, scope: Self.gridAndFull, standard: ["@3"], performer: nil)
        case .sortTaken:         return Spec(group: .general, scope: Self.gridAndFull, standard: ["@4"], performer: nil)
        case .sortSize:          return Spec(group: .general, scope: Self.gridAndFull, standard: ["@5"], performer: nil)
        case .sortDistance:      return Spec(group: .general, scope: Self.gridAndFull, standard: ["@6"], performer: nil)
        case .fullScreen:        return Spec(group: .general, scope: Self.everywhere, standard: ["f"], performer: "f")
        case .enhance:           return Spec(group: .general, scope: Self.everywhere, standard: ["e"], performer: "e")
        case .adjust:            return Spec(group: .general, scope: Self.everywhere, standard: ["a"], performer: "a")
        case .openFolder:        return Spec(group: .general, scope: Self.gridAndFull, standard: ["@o"], performer: nil)
        case .newWindow:         return Spec(group: .general, scope: Self.everywhere, standard: ["@n"], performer: nil)
        case .reveal:            return Spec(group: .general, scope: Self.gridAndFull, standard: ["@$r"], performer: nil)
        case .openDefault:       return Spec(group: .general, scope: Self.gridAndFull, standard: ["@return", "f4"], performer: nil)
        case .menus:             return Spec(group: .general, scope: Self.gridAndFull, standard: ["f9"], performer: nil)
        case .quit:              return Spec(group: .general, scope: Self.gridAndFull, standard: ["f10"], performer: nil)
        case .miniKeyboard:      return Spec(group: .general, scope: Self.everywhere, standard: ["k"], performer: "k")
        case .bookmark:          return Spec(group: .general, scope: Self.gridAndFull, standard: ["@d"], performer: nil)
        case .bookmark1, .bookmark2, .bookmark3, .bookmark4, .bookmark5, .bookmark6, .bookmark7, .bookmark8, .bookmark9:
            return Spec(group: .general, scope: Self.gridAndFull, standard: ["^\(bookmarkIndex! + 1)"], performer: nil)
        case .bossKey:           return Spec(group: .general, scope: Self.everywhere, standard: ["x"], performer: nil)
        case .help:              return Spec(group: .general, scope: Self.everywhere, standard: ["f1", "@?"], performer: "f1")
        }
    }

    var group: ShortcutGroup { spec.group }
    var scope: ShortcutScope { spec.scope }
    var performer: Performer { spec.performer.flatMap(KeyChord.init(stored:)).map(Performer.key) ?? .command }

    /// Schnellbild's own keys.
    var standardKeys: [KeyChord] { spec.standard.compactMap(KeyChord.init(stored:)) }

    func keys(in preset: ShortcutPreset) -> [KeyChord] {
        switch preset {
        case .schnellbild: return standardKeys
        case .phiewer:     return (spec.phiewer ?? spec.standard).compactMap(KeyChord.init(stored:))
        }
    }

    /// The bookmark (0 … 8) the action opens.
    var bookmarkIndex: Int? { Self.bookmarks.firstIndex(of: self) }

    /// Opening the first nine bookmarks, in order.
    static let bookmarks: [ShortcutAction] = [.bookmark1, .bookmark2, .bookmark3, .bookmark4, .bookmark5,
                                              .bookmark6, .bookmark7, .bookmark8, .bookmark9]
    /// Sorting, in the order of `BrowserModel.SortKey.allCases`.
    static let sorts: [ShortcutAction] = [.sortName, .sortKind, .sortModified, .sortTaken, .sortSize, .sortDistance]

    /// The sort the action chooses.
    var sortKey: BrowserModel.SortKey? {
        switch self {
        case .sortName:     return .name
        case .sortKind:     return .kind
        case .sortModified: return .modified
        case .sortTaken:    return .captured
        case .sortSize:     return .size
        case .sortDistance: return .distance
        default:            return nil
        }
    }

    /// The action's name in the settings.
    var name: String {
        if let sortKey { return String(localized: "Sort by \(sortKey.title)") }
        if let bookmarkIndex { return String(localized: "Open bookmark \(bookmarkIndex + 1)") }
        switch self {
        case .gridPrevious:      return String(localized: "Previous")
        case .listUp:            return String(localized: "Playlist: row up")
        case .gridNext:          return String(localized: "Next")
        case .gridRowUp:         return String(localized: "Row up")
        case .gridRowDown:       return String(localized: "Row down")
        case .gridOpen:          return String(localized: "Open")
        case .gridBack:          return String(localized: "Back, or the enclosing folder")
        case .gridFirst:         return String(localized: "First item")
        case .gridLast:          return String(localized: "Last item")
        case .toggleList:        return String(localized: "Grid or list")
        case .largerThumbnails:  return String(localized: "Larger Thumbnails")
        case .smallerThumbnails: return String(localized: "Smaller Thumbnails")
        case .gridRename, .fullRename: return String(localized: "Rename")
        case .newFolder:         return String(localized: "New Folder")
        case .trash:             return String(localized: "Move to Trash")
        case .gridClear:         return String(localized: "Unmark all, then clear the search")
        case .fullPrevious:      return String(localized: "Previous (videos: 10 % back)")
        case .fullNext:          return String(localized: "Next (videos: 10 % ahead)")
        case .fullPreviousItem:  return String(localized: "Previous item")
        case .fullNextItem:      return String(localized: "Next item")
        case .fullFineBack:      return String(localized: "Video: 1 % back")
        case .fullFineAhead:     return String(localized: "Video: 1 % ahead")
        case .fullUp:            return String(localized: "Look further up (videos: louder)")
        case .fullDown:          return String(localized: "Look further down (videos: quieter)")
        case .fullSpace:         return String(localized: "Next picture · play/pause video")
        case .zoomIn:            return String(localized: "Zoom in")
        case .zoomOut:           return String(localized: "Zoom out")
        case .zoomFit:           return String(localized: "Fit")
        case .zoomActual:        return "100 %"
        case .rotateLeft:        return String(localized: "Rotate left")
        case .rotateRight:       return String(localized: "Rotate right")
        case .info:              return String(localized: "File info")
        case .closeFullView:     return String(localized: "Back to grid")
        case .subtitles:         return String(localized: "Subtitles")
        case .nextSubtitle:      return String(localized: "Next Subtitle Track")
        case .nextAudio:         return String(localized: "Next Audio Track")
        case .slower:            return String(localized: "Slower")
        case .faster:            return String(localized: "Faster")
        case .normalSpeed:       return String(localized: "Normal Speed")
        case .startSlideshow:    return String(localized: "Start Slideshow")
        case .showPause:         return String(localized: "Pause / resume")
        case .playlist:          return String(localized: "Playlist")
        case .listDown:          return String(localized: "Playlist: row down")
        case .listShow:          return String(localized: "Playlist: show the item")
        case .listTakeOut:       return String(localized: "Playlist: take out")
        case .endSlideshow:      return String(localized: "End the slideshow")
        case .toggleDual:        return String(localized: "Dual Pane")
        case .switchPane:        return String(localized: "Other pane")
        case .copyToOther:       return String(localized: "Copy to Other Pane")
        case .moveToOther:       return String(localized: "Move to Other Pane")
        case .mark:              return String(localized: "Mark")
        case .markAll:           return String(localized: "Mark all")
        case .search:            return String(localized: "Search")
        case .back:              return String(localized: "Back")
        case .forward:           return String(localized: "Forward")
        case .enclosingFolder:   return String(localized: "Enclosing Folder")
        case .reload:            return String(localized: "Reload")
        case .fullScreen:        return String(localized: "Full Screen")
        case .enhance:           return String(localized: "Auto Enhance")
        case .adjust:            return String(localized: "Adjust")
        case .openFolder:        return String(localized: "Open Folder…")
        case .newWindow:         return String(localized: "New Window")
        case .reveal:            return String(localized: "Reveal in Finder")
        case .openDefault:       return String(localized: "Open with Default App")
        case .menus:             return String(localized: "Menus in the window")
        case .quit:              return String(localized: "Quit (asks first)")
        case .miniKeyboard:      return String(localized: "Mini Keyboard")
        case .bookmark:          return String(localized: "Bookmark This Folder")
        case .bossKey:           return String(localized: "Boss key")
        case .help:              return String(localized: "Schnellbild Help")
        default:                 return rawValue
        }
    }
}

/// The key sets to start from: Schnellbild's own, or Phiewer's where they
/// differ (for people coming from it; only for what Schnellbild has).
enum ShortcutPreset: String, CaseIterable {
    case schnellbild, phiewer
}

/// The keys of every action, app-wide: a preset and what the user changed
/// on top of it, kept in the preferences. The key monitor asks it what a
/// key does (`resolve`); F1, the mini keyboard, menus and tooltips show
/// the keys it holds.
@MainActor
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts(defaults: BrowserModel.makeDefaults())

    static let presetKey = "keyboardShortcutsPreset"
    static let customKey = "keyboardShortcuts"

    private let defaults: UserDefaults
    @Published private(set) var preset: ShortcutPreset = .schnellbild
    @Published private(set) var bindings: [ShortcutAction: [KeyChord]] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    // MARK: Reading

    func keys(_ action: ShortcutAction) -> [KeyChord] { bindings[action] ?? action.keys(in: preset) }

    /// The keys as F1 lists them: "Space / F3"; "" without any.
    func text(_ action: ShortcutAction) -> String { keys(action).map(\.text).joined(separator: " / ") }

    /// The keys for a tooltip or a sentence; the localized "no key" without any.
    func hint(_ action: ShortcutAction) -> String {
        let text = text(action)
        return text.isEmpty ? String(localized: "no key") : text
    }

    /// Whether the action fits a search in Settings → Keyboard: its name
    /// holds the words typed ("rename"), or one of its keys holds the keys
    /// typed, as glyphs ("⌘R") or with their names ("cmd r", "shift+cmd+n").
    func matches(_ action: ShortcutAction, search: String) -> Bool {
        let words = search.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        if action.name.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        let wanted = Self.keySearch(words)
        guard !wanted.isEmpty else { return false }
        return keys(action).contains { $0.text.uppercased().replacingOccurrences(of: " ", with: "").contains(wanted) }
    }

    /// Typed keys as `KeyChord.text` writes them: names of modifiers and
    /// keys become glyphs, spaces and the "+" between keys go, capitals.
    static func keySearch(_ typed: String) -> String {
        let names: [(String, String)] = [
            ("command", "⌘"), ("cmd", "⌘"), ("option", "⌥"), ("opt", "⌥"), ("alt", "⌥"), ("control", "⌃"), ("ctrl", "⌃"),
            ("shift", "⇧"), ("escape", "⎋"), ("esc", "⎋"), ("return", "↩"), ("enter", "↩"), ("backspace", "⌫"),
            ("delete", "⌫"), ("tab", "⇥"), ("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓"),
        ]
        var parts = typed.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
        // A "+" typed last is the plus key itself ("⌘+")
        if typed.hasSuffix("+"), typed.count > 1 { parts.append("+") }
        if typed == "+" { parts = ["+"] }
        let glyphs = parts.map { part in names.first { $0.0 == part }?.1 ?? part }
        // Modifiers in Apple's order, as `text` writes them
        let order = ["⌃", "⌥", "⇧", "⌘"]
        let modifiers = order.filter { glyph in glyphs.contains { $0.contains(glyph) && $0.count == 1 } }
        let rest = glyphs.filter { !(order.contains($0)) }.joined()
        return (modifiers.joined() + rest).replacingOccurrences(of: "-", with: "−").uppercased()
    }

    /// The first key with ⌘ or ⌃, for the action's menu item.
    func menuShortcut(_ action: ShortcutAction) -> KeyboardShortcut? {
        keys(action).lazy.compactMap(\.menuShortcut).first
    }

    /// The keys differ from the preset's: the user changed them.
    func isChanged(_ action: ShortcutAction) -> Bool { keys(action) != action.keys(in: preset) }

    var hasChanges: Bool { ShortcutAction.allCases.contains(where: isChanged) }

    /// The keys differ from Schnellbild's own (a preset or the user).
    func differsFromStandard(_ action: ShortcutAction) -> Bool { keys(action) != action.standardKeys }

    /// The other actions the key already belongs to where this action's
    /// keys work too.
    func conflicts(_ chord: KeyChord, for action: ShortcutAction) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0 != action && $0.scope.overlaps(action.scope) && keys($0).contains(chord) }
    }

    /// Why a key can't be given to an action: macOS keeps it (⌘Q, ⌘W,
    /// ⌃⌘F …), or text fields need it (⌘C, ⌘V …). nil: it can be used.
    static func isReserved(_ chord: KeyChord) -> Bool { reserved.contains(chord) }

    static let reserved: Set<KeyChord> = Set([
        "@q", "@w", "@h", "~@h", "@m", "~@m", "@,", "@`", "^@f", "^@q", "@space", "^space", "@tab",
        "@c", "@v", "@x", "@z", "$@z",
    ].compactMap(KeyChord.init(stored:)))

    // MARK: What a typed key does

    enum Resolution: Equatable {
        /// One of the action's own keys as Schnellbild has it: the key
        /// bindings take it as they always do.
        case standard
        /// A key the user (or a preset) gave the action: `WindowModel.perform`.
        case custom(ShortcutAction)
        /// A key Schnellbild has for an action here that now has other
        /// keys: it does nothing.
        case blocked
        /// No action's key: the key bindings see it as typed.
        case free
    }

    func resolve(_ chord: KeyChord, in context: ShortcutScope) -> Resolution {
        let here = ShortcutAction.allCases.filter { $0.scope.overlaps(context) }
        // The playlist's keys first, while it has them
        let listKeys = here.filter { $0.scope.contains(.list) }
        let ordered = listKeys + here.filter { !$0.scope.contains(.list) }
        if let action = ordered.first(where: { keys($0).contains(chord) }) {
            // The key bindings would hand the playlist's own keys to the
            // playlist: another action's key goes through `perform`
            let takenByList = !action.scope.contains(.list) && listKeys.contains { $0.standardKeys.contains(chord) }
            return action.standardKeys.contains(chord) && !takenByList ? .standard : .custom(action)
        }
        return here.contains(where: { $0.standardKeys.contains(chord) }) ? .blocked : .free
    }

    // MARK: Changing

    /// Gives the action the key: in place of `replacing` (one of its keys),
    /// else as one more. The other actions it belonged to where this one's
    /// keys work lose it.
    func assign(_ chord: KeyChord, to action: ShortcutAction, replacing old: KeyChord? = nil) {
        guard !Self.isReserved(chord) else { return }
        var all = bindingsCompleted()
        for other in conflicts(chord, for: action) { all[other]?.removeAll { $0 == chord } }
        var mine = all[action] ?? []
        if let old, let index = mine.firstIndex(of: old) {
            mine[index] = chord
        } else if !mine.contains(chord) {
            mine.append(chord)
        }
        // The same key twice (it replaced one while it was there already)
        var seen = Set<KeyChord>()
        all[action] = mine.filter { seen.insert($0).inserted }
        bindings = all
        save()
    }

    func remove(_ chord: KeyChord, from action: ShortcutAction) {
        var all = bindingsCompleted()
        all[action]?.removeAll { $0 == chord }
        bindings = all
        save()
    }

    /// The action's keys as the preset has them; another action holding
    /// one of them gives it up.
    func reset(_ action: ShortcutAction) {
        var all = bindingsCompleted()
        let wanted = action.keys(in: preset)
        for chord in wanted {
            for other in conflicts(chord, for: action) { all[other]?.removeAll { $0 == chord } }
        }
        all[action] = wanted
        bindings = all
        save()
    }

    /// Every key as the preset has it.
    func resetAll() { choose(preset) }

    /// A preset's keys for every action (what the user changed goes).
    func choose(_ preset: ShortcutPreset) {
        self.preset = preset
        bindings = Self.presetBindings(preset)
        save()
    }

    /// How many actions a preset gives other keys than Schnellbild's.
    static func differences(of preset: ShortcutPreset) -> Int {
        ShortcutAction.allCases.filter { $0.keys(in: preset) != $0.standardKeys }.count
    }

    static func presetBindings(_ preset: ShortcutPreset) -> [ShortcutAction: [KeyChord]] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.keys(in: preset)) })
    }

    private func bindingsCompleted() -> [ShortcutAction: [KeyChord]] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, keys($0)) })
    }

    // MARK: Preferences

    /// Kept: the preset and, per action whose keys differ from it, its keys
    /// in the stored form. Unknown actions, keys that can't be read and
    /// reserved keys are left out; a key two actions hold where both work
    /// stays with the one the user changed (else the one listed first).
    private func load() {
        preset = defaults.string(forKey: Self.presetKey).flatMap(ShortcutPreset.init(rawValue:)) ?? .schnellbild
        var all = Self.presetBindings(preset)
        var changed: [ShortcutAction] = []
        if let stored = defaults.dictionary(forKey: Self.customKey) {
            for (name, value) in stored {
                guard let action = ShortcutAction(rawValue: name), let list = value as? [String] else { continue }
                var seen = Set<KeyChord>()
                all[action] = list.compactMap(KeyChord.init(stored:))
                    .filter { !Self.isReserved($0) && seen.insert($0).inserted }
                changed.append(action)
            }
        }
        // One key, one action where they work together: the changed ones first
        let order = ShortcutAction.allCases.filter(changed.contains) + ShortcutAction.allCases.filter { !changed.contains($0) }
        var kept: [ShortcutAction: [KeyChord]] = [:]
        for action in order {
            kept[action] = (all[action] ?? []).filter { chord in
                !kept.contains { other, chords in other.scope.overlaps(action.scope) && chords.contains(chord) }
            }
        }
        bindings = kept
    }

    private func save() {
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        var custom: [String: [String]] = [:]
        for action in ShortcutAction.allCases where isChanged(action) {
            custom[action.rawValue] = keys(action).map(\.stored)
        }
        defaults.set(custom, forKey: Self.customKey)
    }
}

// MARK: - Carrying out

/// Opens a new window (File → New Window), set by the menu item's view,
/// which has SwiftUI's `openWindow`.
@MainActor
enum WindowOpener {
    static var open: (() -> Void)?
}

extension WindowModel {
    /// Where the keys work now: the grid, the full view, the slideshow (and
    /// its playlist while it has the keys).
    var shortcutContext: ShortcutScope {
        let model = active
        if model.slideshow != nil { return model.showPlaylist && model.playlistFocused ? [.show, .list] : .show }
        return model.mode == .detail ? .full : .grid
    }

    /// Keys a text field being edited needs for itself.
    private static let textEditingKeys: Set<KeyChord> = Set(["@a", "@c", "@v", "@x", "@z", "$@z"].compactMap(KeyChord.init(stored:)))

    /// A key as typed, before the key bindings see it: a key the user gave
    /// an action carries it out; a key of Schnellbild's that now belongs to
    /// no action here does nothing. nil: the key bindings take it as typed
    /// (Schnellbild's own key of an action, or no action's key).
    func handleTyped(_ chord: KeyChord, textEditing: Bool, repeating: Bool = false) -> Bool? {
        // While typing, letters, arrows, Return … are the text field's
        if textEditing, (!chord.command && !chord.control && !chord.isFunctionKey) || Self.textEditingKeys.contains(chord) {
            return nil
        }
        switch shortcuts.resolve(chord, in: shortcutContext) {
        case .standard, .free:
            return nil
        case .blocked:
            return false
        case .custom(let action):
            // The other pane's sheet (a password asked for) keeps the keys
            if panes.contains(where: { $0 !== active && $0.anySheetOpen }) { return false }
            return perform(action, textEditing: textEditing, repeating: repeating)
        }
    }

    /// A key as typed, all the way: `handleTyped`, then the window's and
    /// the pane's key bindings (what the key monitor does, without its own
    /// keys: X, F9, F10, ⌃⌘F).
    @discardableResult
    func typeKey(_ key: BrowserModel.KeyInput, command: Bool = false, shift: Bool = false, option: Bool = false,
                 control: Bool = false, textEditing: Bool = false) -> Bool {
        let chord = KeyChord(key, command: command, shift: shift, option: option, control: control)
        if let handled = handleTyped(chord, textEditing: textEditing) { return handled }
        if handleWindowKey(key, command: command, control: control, shift: shift, textEditing: textEditing) { return true }
        guard !control else { return false }
        return active.handleKey(key, command: command, shift: shift, option: option, textEditing: textEditing)
    }

    /// Carries out an action as its key would.
    @discardableResult
    func perform(_ action: ShortcutAction, textEditing: Bool = false, repeating: Bool = false) -> Bool {
        let model = active
        guard case .key(let key) = action.performer else { return performCommand(action, textEditing: textEditing) }
        if handleWindowKey(key.key, command: key.command, control: key.control, shift: key.shift, textEditing: textEditing) { return true }
        model.playlistKeysOff = !action.scope.contains(.list)
        defer { model.playlistKeysOff = false }
        return model.handleKey(key.key, command: key.command, shift: key.shift, option: key.option,
                               textEditing: textEditing, repeating: repeating)
    }

    /// What the menu items (and F9, F10, the boss key) do, under the same
    /// conditions as their menu items.
    private func performCommand(_ action: ShortcutAction, textEditing: Bool) -> Bool {
        let model = active
        let sheet = anySheetOpen
        let video = model.shownMediaEntry?.kind == .video
        if let key = action.sortKey {
            guard !sheet else { return false }
            model.setSort(key)
            return true
        }
        if let index = action.bookmarkIndex {
            let folders = Bookmarks.shared.folders
            guard !sheet, model.slideshow == nil, index < folders.count else { return false }
            model.open(folder: folders[index])
            return true
        }
        switch action {
        case .openFolder:
            guard !sheet else { return false }
            model.chooseFolder()
        case .newWindow:
            guard let open = WindowOpener.open else { return false }
            open()
        case .reveal:
            guard model.slideshow == nil, !sheet else { return false }
            model.revealInFinder()
        case .openDefault:
            guard model.slideshow == nil, !sheet, model.selectionIsChangeable else { return false }
            model.openInDefaultApp()
        case .trash:
            guard model.canTrash, !sheet else { return false }
            model.moveSelectionToTrash()
        case .reload:
            guard model.folderURL != nil, !model.isLoading, model.slideshow == nil, !sheet else { return false }
            model.reload()
        case .nextSubtitle:
            guard video, !sheet else { return false }
            model.nextSubtitleTrack()
        case .nextAudio:
            guard video, !sheet else { return false }
            model.nextAudioTrack()
        case .normalSpeed:
            guard video, !sheet else { return false }
            model.setSpeed(1)
        case .bookmark:
            guard !sheet, model.slideshow == nil, let folder = model.folderURL else { return false }
            Bookmarks.shared.toggle(folder)
        case .menus:
            guard !textEditing, model.slideshow == nil, !sheet else { return false }
            NortonMenus.showMainMenus()
            model.noteKeyPress(.f9, command: false)
        case .quit:
            guard !textEditing, model.slideshow == nil, !sheet else { return false }
            NortonMenus.askToQuit()
        case .bossKey:
            guard !textEditing else { return false }
            BossKey.engage()
        default:
            return false
        }
        return true
    }
}
