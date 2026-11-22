import XCTest
import Foundation

/// Every language has every string English has, and each translation takes
/// the same values (`%@`, `%lld`) as its English source: reordered only
/// with positions (`%2$@`).
final class LocalizationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization")
    }

    private var languages: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }.sorted()
    }

    private func table(_ language: String, _ file: String) throws -> [String: Any] {
        let url = root.appendingPathComponent("\(language).lproj/\(file)")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "\(language)/\(file) is no dictionary")
    }

    /// The values a format takes, each as "<argument number>:<type>": "%@"
    /// takes the next argument, "%2$@" the second ("%@ of %@" and "%2$@ von
    /// %1$@" take the same, "%1$@ und %1$@" doesn't).
    static func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:([0-9]+)\\$)?(lld|ld|d|@)")
        let range = NSRange(text.startIndex..., in: text)
        var next = 0
        var taken: Set<String> = []
        for match in pattern.matches(in: text, range: range) {
            guard let type = Range(match.range(at: 2), in: text).map({ String(text[$0]) }) else { continue }
            let number: Int
            if let position = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }) {
                number = position
            } else {
                next += 1
                number = next
            }
            taken.insert("\(number):\(type)")
        }
        return taken.sorted()
    }

    func testTheLanguagesAreThere() {
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.count >= 20, "\(languages)")
    }

    func testEveryLanguageHasEveryStringWithTheSamePlaceholders() throws {
        let english = try table("en", "Localizable.strings")
        XCTAssertFalse(english.isEmpty)
        for (key, value) in english {
            XCTAssertEqual(key, value as? String, "English values are their keys: \(key)")
        }
        for language in languages where language != "en" {
            let strings = try table(language, "Localizable.strings")
            XCTAssertEqual(Set(strings.keys), Set(english.keys), "\(language): missing \(Set(english.keys).subtracting(strings.keys)), extra \(Set(strings.keys).subtracting(english.keys))")
            for (key, value) in strings {
                let text = try XCTUnwrap(value as? String)
                XCTAssertFalse(text.isEmpty, "\(language): \(key)")
                XCTAssertEqual(Self.placeholders(text), Self.placeholders(key), "\(language): \(key) → \(text)")
            }
        }
    }

    func testEveryLanguageHasEveryPluralWithItsNumber() throws {
        let english = try table("en", "Localizable.stringsdict")
        XCTAssertFalse(english.isEmpty)
        for language in languages {
            let plurals = try table(language, "Localizable.stringsdict")
            XCTAssertEqual(Set(plurals.keys), Set(english.keys), language)
            for (key, entry) in plurals {
                let plural = try XCTUnwrap(entry as? [String: Any], "\(language): \(key)")
                XCTAssertEqual(plural["NSStringLocalizedFormatKey"] as? String, "%#@count@", "\(language): \(key)")
                let rule = try XCTUnwrap(plural["count"] as? [String: Any], "\(language): \(key)")
                XCTAssertEqual(rule["NSStringFormatSpecTypeKey"] as? String, "NSStringPluralRuleType", "\(language): \(key)")
                XCTAssertEqual(rule["NSStringFormatValueTypeKey"] as? String, "lld", "\(language): \(key)")
                XCTAssertNotNil(rule["other"], "\(language): \(key) needs an “other” form")
                for (category, form) in rule where !category.hasPrefix("NS") {
                    XCTAssertEqual(Self.placeholders(try XCTUnwrap(form as? String)), ["1:lld"], "\(language): \(key) [\(category)]")
                }
            }
        }
    }

    // MARK: The code against the tables

    /// The UI texts written in the code: the string literals a call that
    /// shows text gets as its first argument (`Text("…")`, `Button("…"`,
    /// `Menu("…")`, `Section("…")`, `Picker("…"`, `LabeledContent("…"`,
    /// `.confirmationDialog("…"`, `.navigationTitle("…")`, `.help("…")`,
    /// `String(localized: "…")`, `.accessibilityLabel("…")`, both sides of
    /// `Text(a ? "…" : "…")` …), what a helper returning a
    /// `LocalizedStringKey` returns, the help's `action: "…"`, and its keys
    /// where they hold words (`.words("drag")`), with each interpolation
    /// `\(…)` kept as a marker. A small scanner, not a regular expression:
    /// interpolations can hold quotes of their own. It goes on inside each
    /// argument, so a text handed through another call
    /// (`.help(shortcuts.tip(String(localized: "…"), .back))`) is found too.
    static func uiTexts(in source: String) -> [String] {
        let calls = ["Text(", "Button(", "Label(", "Toggle(", "TextField(", "SecureField(", "ShortcutLabel(", "CommandMenu(",
                     "Menu(", "Section(", "Picker(", "LabeledContent(", "Stepper(", ".confirmationDialog(", ".alert(",
                     ".navigationTitle(", "headerButton(", "slider(", "infoRow(", ".help(", ".accessibilityLabel(",
                     ".accessibilityValue(", "String(localized: ", "action: ", "word: ", "Group(title: ", "title: ", ".words("]
        let chars = Array(source)
        var texts: [String] = []
        var i = 0
        while i < chars.count {
            guard let start = calls.first(where: { matches($0, chars, at: i) }) else { i += 1; continue }
            // Right after a letter or digit it's another call ("myText(")
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_", !start.hasPrefix(".") { i += 1; continue }
            let (literals, _) = argument(chars, from: i + start.count)
            texts += literals.filter { $0.contains(where: \.isLetter) && !names.contains($0) }
            i += start.count
        }
        // What helpers returning a `LocalizedStringKey` return ("Undo Rename")
        i = 0
        let helper = "-> LocalizedStringKey {"
        while i < chars.count {
            guard matches(helper, chars, at: i) else { i += 1; continue }
            var j = i + helper.count, depth = 1
            while j < chars.count, depth > 0 {
                if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1 }
                if matches("return ", chars, at: j) {
                    // To the end of its line: the next case's literal is another return's
                    var end = j
                    while end < chars.count, chars[end] != "\n" { end += 1 }
                    let (literals, _) = argument(Array(chars[j..<end]), from: "return ".count)
                    texts += literals.filter { $0.contains(where: \.isLetter) }
                }
                j += 1
            }
            i = j
        }
        return texts
    }

    /// Names shown as they are, in every language.
    static let names: Set<String> = ["Schnellbild"]

    private static func matches(_ text: String, _ chars: [Character], at i: Int) -> Bool {
        let s = Array(text)
        return i + s.count <= chars.count && Array(chars[i..<i + s.count]) == s
    }

    /// The string literals at the top level of the argument starting at
    /// `from` (one, or the sides of a `?:`), up to its `,` or `)`; none for a
    /// labelled argument (`Text(verbatim: …)`). Returns where it ends.
    private static func argument(_ chars: [Character], from start: Int) -> ([String], Int) {
        var j = start
        while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
        // A label of its own ("verbatim:", "systemName:"): not a text
        var k = j
        while k < chars.count, chars[k].isLetter || chars[k].isNumber || chars[k] == "_" { k += 1 }
        if k > j, k < chars.count, chars[k] == ":" { return ([], k + 1) }
        var literals: [String] = []
        // Brackets open: a call's parentheses, an array, a closure hide what
        // is inside; parentheses only grouping (`a ? (b ? "x" : "y") : ""`)
        // don't
        var open: [Bool] = []   // per bracket: does it hide its literals?
        var previous: Character = "("
        while j < chars.count {
            let c = chars[j]
            if c == "\"" {
                let (text, end) = literal(chars, from: j + 1)
                if !open.contains(true) { literals.append(text) }
                j = end
                previous = "\""
                continue
            }
            if c == "(" {
                open.append(!"?:(,=!&|".contains(previous))
            } else if c == "[" || c == "{" {
                open.append(true)
            } else if c == ")" || c == "]" || c == "}" {
                if open.isEmpty { break }
                open.removeLast()
            } else if c == ",", open.isEmpty {
                break
            }
            if c != " " && c != "\n" { previous = c }
            j += 1
        }
        return (literals, j)
    }

    /// A string literal from after its opening quote; returns its text
    /// (interpolations as markers) and the index after its closing quote.
    private static func literal(_ chars: [Character], from start: Int) -> (String, Int) {
        var j = start
        var text = ""
        while j < chars.count, chars[j] != "\"" {
            if chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == "(" {
                var depth = 1
                j += 2
                while j < chars.count, depth > 0 {
                    if chars[j] == "\"" {   // a literal inside the interpolation
                        j = literal(chars, from: j + 1).1
                        continue
                    }
                    if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                text += "\u{1}"   // an interpolation
            } else if chars[j] == "\\", j + 1 < chars.count {
                text += chars[j + 1] == "n" ? "\n" : String(chars[j + 1])
                j += 2
            } else {
                text.append(chars[j])
                j += 1
            }
        }
        return (text, j + 1)
    }

    /// The table keys a text can have: each interpolation becomes `%@` or
    /// `%lld` (SwiftUI picks by the value's type).
    static func keys(for text: String) -> [String] {
        let parts = text.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
        var keys = [parts[0]]
        for part in parts.dropFirst() { keys = keys.flatMap { [$0 + "%@" + part, $0 + "%lld" + part] } }
        return keys
    }

    /// Accessibility texts the UI tests read; they stay English.
    static let readByUITests: Set<String> = [
        "%@, %@, %lld previews", "%lld columns, %lld laid out, selection %@", "zoom %lld %, rotation %lld°",
        "volume %lld %", "pressed %lld",
        "selected", "not selected", "%@, %@ items", "station %@ of %@, %@%@", "picture", "video vlc", "video avkit",
    ]

    /// Every text the app shows has an English entry, so every language
    /// can translate it (a missing one would stay English everywhere).
    func testEveryTextInTheCodeHasAnEntry() throws {
        let english = Set(try table("en", "Localizable.strings").keys)
            .union(try table("en", "Localizable.stringsdict").keys)
            .union(Self.readByUITests)
        // The app and the offline map's module (its texts are looked up in the app's tables)
        let repository = root.deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for folder in ["Schnellbild", "OfflineMap"] {
            let sources = repository.appendingPathComponent(folder)
            files += try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
                .map { sources.appendingPathComponent($0) }
        }
        XCTAssertFalse(files.isEmpty)
        var found = 0
        for url in files {
            let file = url.lastPathComponent
            let source = try String(contentsOf: url, encoding: .utf8)
            for text in Self.uiTexts(in: source) {
                found += 1
                let candidates = Self.keys(for: text)
                XCTAssertTrue(candidates.contains(where: english.contains),
                              "\(file): no entry for \(candidates.first ?? text)")
            }
        }
        XCTAssertGreaterThan(found, 80, "the scanner finds the texts")
    }

    func testTheScannerReadsInterpolationsWithQuotes() {
        let source = #"Label("Sort: \(key.title) \(up ? "↑" : "↓")", systemImage: "x") .help("Back (⌘[)") myText("no")"#
        XCTAssertEqual(Self.uiTexts(in: source), ["Sort: \u{1} \u{1}", "Back (⌘[)"])
        XCTAssertTrue(Self.keys(for: "Sort: \u{1} \u{1}").contains("Sort: %@ %@"))
    }

    func testTheScannerReadsTextsInsideOtherCalls() {
        let source = #".help(shortcuts.tip(String(localized: "Back"), .back)) .help(Shortcuts.tip(model.on ? String(localized: "Pause") : String(localized: "Play"), keys: k))"#
        XCTAssertEqual(Self.uiTexts(in: source).sorted(), ["Back", "Pause", "Play"])
    }

    func testTheScannerReadsEveryFormOfText() {
        let source = #"""
        Text(stopped ? "Search stopped" : "No \(n) matches").font(.x)
        Text(verbatim: "Name.jpg") Text(entry.name) Image(systemName: "folder")
        headerButton("Date Modified", key: .modified)
        .accessibilityValue(up ? "ascending" : "descending") .accessibilityLabel("Stop search")
        Text(format("No"))
        Row(.action(.search), action: "Search") Row(.words("drag"), action: "Move")
        Menu("Remove Bookmark") { } Section("Appearance") { Picker("Mode", selection: $x) { } }
        LabeledContent("Saved passwords", value: "\(n)") Stepper(value: $v, in: 1...9) { }
        .confirmationDialog("Forget all?", isPresented: $y) .navigationTitle(name ?? "Schnellbild")
        static func title(_ k: Kind) -> LocalizedStringKey { switch k {
            case .a: return "Undo Rename"
            default: return big ? "Undo All" : "Undo" } }
        """#
        XCTAssertEqual(Self.uiTexts(in: source).sorted(), ["Search stopped", "No \u{1} matches", "Date Modified", "ascending", "descending",
                                                  "Stop search", "Search", "Move", "Remove Bookmark", "Appearance", "Mode",
                                                  "Saved passwords", "Forget all?", "Undo Rename", "Undo All", "Undo", "drag"].sorted())
    }

    /// The map's and the globe's buttons name their help through `mapButton`'s
    /// `title:`, which the scanner reads (both sides of each `?:`).
    func testTheGlobesButtonsAreSeen() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OfflineMap")
        let texts = Set(try ["GlobeView.swift", "MapChrome.swift"].flatMap {
            Self.uiTexts(in: try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8))
        })
        for text in ["Zoom in", "Zoom out", "Show day and night", "Hide day and night", "Exaggerate the relief", "Show the relief at true scale"] {
            XCTAssertTrue(texts.contains(text), text)
        }
    }

    /// Each language's plurals have the categories its numbers need, as
    /// CLDR counts whole numbers (Russian "1 / 2–4 / 5 и более", Japanese
    /// one form), and none it never uses (a "one" in Japanese would never
    /// show; Czech "many" is for fractions).
    func testEveryLanguageHasThePluralCategoriesItNeeds() throws {
        let needed: [String: Set<String>] = [
            "cs": ["one", "few", "other"], "pl": ["one", "few", "many", "other"],
            "ru": ["one", "few", "many", "other"], "uk": ["one", "few", "many", "other"],
            "es": ["one", "many", "other"], "fr": ["one", "many", "other"], "it": ["one", "many", "other"],
            "pt-BR": ["one", "many", "other"],
            "ja": ["other"], "ko": ["other"], "zh-Hans": ["other"], "zh-Hant": ["other"],
        ]
        let allowed: [String: Set<String>] = ["cs": ["one", "few", "many", "other"]]
        for language in languages {
            let want = needed[language] ?? ["one", "other"]
            let may = allowed[language] ?? want
            for (key, entry) in try table(language, "Localizable.stringsdict") {
                let rule = try XCTUnwrap((entry as? [String: Any])?["count"] as? [String: Any], "\(language): \(key)")
                let categories = Set(rule.keys.filter { !$0.hasPrefix("NS") })
                XCTAssertTrue(want.isSubset(of: categories), "\(language): \(key) lacks \(want.subtracting(categories).sorted())")
                XCTAssertTrue(categories.isSubset(of: may), "\(language): \(key) has \(categories.subtracting(may).sorted()), never used")
            }
        }
    }

    func testPlaceholdersKeepTheirPositions() {
        XCTAssertEqual(Self.placeholders("%@ of %lld"), Self.placeholders("%2$lld von %1$@"))
        XCTAssertNotEqual(Self.placeholders("%@ and %@"), Self.placeholders("%1$@ und %1$@"))
        XCTAssertNotEqual(Self.placeholders("%@ of %lld"), Self.placeholders("%lld von %@"))
    }

    /// The mini keyboard's rows as `MiniKeyboard.keys(for:)` defines them:
    /// each context's words, read from the source.
    static func miniKeyboardRows(in source: String) -> [String: [String]] {
        guard let start = source.range(of: "static func keys(for context: Context)"),
              let end = source.range(of: "@EnvironmentObject var window", range: start.upperBound..<source.endIndex)
        else { return [:] }
        let body = String(source[start.upperBound..<end.lowerBound])
        let caseName = try! NSRegularExpression(pattern: "case \\.([A-Za-z]+):")
        let word = try! NSRegularExpression(pattern: "word: \"([^\"]+)\"")
        var rows: [String: [String]] = [:]
        let cases = caseName.matches(in: body, range: NSRange(body.startIndex..., in: body))
        for (i, match) in cases.enumerated() {
            let name = String(body[Range(match.range(at: 1), in: body)!])
            let from = match.range.upperBound
            let to = i + 1 < cases.count ? cases[i + 1].range.location : (body as NSString).length
            let part = (body as NSString).substring(with: NSRange(location: from, length: to - from))
            rows[name] = word.matches(in: part, range: NSRange(part.startIndex..., in: part))
                .map { (part as NSString).substring(with: $0.range(at: 1)) }
        }
        return rows
    }

    /// A row of the mini keyboard never shows one word for two keys ("Fit"
    /// and "Adjust" both "Anpassen" would leave the user guessing).
    func testNoDuplicateWordsWithinAMiniKeyboardRow() throws {
        let file = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schnellbild/MiniKeyboard.swift")
        let rows = Self.miniKeyboardRows(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertGreaterThanOrEqual(rows.count, 5, "the scanner finds the rows")
        for language in languages {
            let strings = try table(language, "Localizable.strings")
            for (row, words) in rows {
                var seen: [String: String] = [:]
                for word in words {
                    let shown = ((strings[word] as? String) ?? word).lowercased()
                    if let other = seen[shown] {
                        XCTFail("\(language), \(row): “\(shown)” for both \(other) and \(word)")
                    }
                    seen[shown] = word
                }
            }
        }
    }

    /// Keys are shown as on Apple's keyboards and menus: glyphs (⌫ ↩ ⎋ ⇥,
    /// the arrows, Home and End as macOS's menus draw them, `KeyGlyphs`) where
    /// Apple has them, and the space bar by its name in each language. The
    /// actions' keys and the F1 help's own keys (`HelpKeys.fixed`, chords)
    /// are drawn by `KeyChord.caps`
    /// (`ShortcutsTests.testKeysAreShownAsOnApplesKeyboards`); the mini
    /// keyboard names its keys in the stored form only.
    func testKeyNamesAreGlyphsOrTranslated() throws {
        let sources = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Schnellbild")
        let help = try String(contentsOf: sources.appendingPathComponent("ShortcutsHelpView.swift"), encoding: .utf8)
        XCTAssertFalse(help.contains(".fixed(\""), "F1 help: its own keys are chords, drawn as every key is")
        XCTAssertGreaterThan(help.components(separatedBy: ".fixed([KeyChord(").count - 1, 3, "the help's own keys are found")
        // The mini keyboard's keys: an action and its key in the stored form ("space", "@f")
        let keyboard = try String(contentsOf: sources.appendingPathComponent("MiniKeyboard.swift"), encoding: .utf8)
        let keys = try NSRegularExpression(pattern: "Key\\(\\.[A-Za-z0-9]+, \"([^\"]+)\", word:")
        XCTAssertGreaterThan(keys.numberOfMatches(in: keyboard, range: NSRange(keyboard.startIndex..., in: keyboard)), 50,
                             "the scanner finds the mini keyboard's keys")
        for language in languages {
            XCTAssertNotNil(try table(language, "Localizable.strings")["Space"], "\(language): the space bar's name")
        }
    }

    /// Every action's name in Settings → Keyboard is looked up in the
    /// language ("100 %" is "%100" in Turkish): none is a bare literal.
    func testEveryActionNameIsLocalized() throws {
        let sources = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Schnellbild")
        let code = try String(contentsOf: sources.appendingPathComponent("Shortcuts.swift"), encoding: .utf8)
        guard let start = code.range(of: "/// The action's name in the settings.\n    var name: String {"), let end = code[start.upperBound...].range(of: "\n    }\n") else {
            return XCTFail("the action names' switch not found")
        }
        let names = code[start.upperBound..<end.lowerBound]
        let bare = try NSRegularExpression(pattern: "return \"")
        let text = String(names)
        XCTAssertGreaterThan(text.components(separatedBy: "String(localized:").count, 50, "the scanner reads the names")
        for match in bare.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let line = (text as NSString).substring(with: (text as NSString).lineRange(for: match.range))
            XCTFail("not localized: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// The kind macOS shows for a download not finished (the description
    /// of the type the app declares for them) is translated in every
    /// language, in InfoPlist.strings, where macOS looks it up by its text.
    func testTheDownloadTypesDescriptionIsTranslated() throws {
        let plist = root.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let types = try XCTUnwrap(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let download = try XCTUnwrap(types.first { $0["UTTypeIdentifier"] as? String == "art.haushoppe.schnellbild.download-in-progress" })
        let description = try XCTUnwrap(download["UTTypeDescription"] as? String)
        for language in languages {
            let translated = try table(language, "InfoPlist.strings")[description] as? String
            XCTAssertNotNil(translated, "\(language): \(description)")
            if language != "en" { XCTAssertNotEqual(translated, description, "\(language): translated") }
        }
    }

    /// Info.plist names exactly the languages there are.
    func testInfoPlistListsTheLanguages() throws {
        let plist = root.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let listed = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(listed), Set(languages))
    }
}
