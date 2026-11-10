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
    /// `.help("…")`, `String(localized: "…")`, `.accessibilityLabel("…")`,
    /// both sides of `Text(a ? "…" : "…")` …), the help's `action: "…"`, and
    /// its keys where they hold words (`wordsInKeys: true`), with each
    /// interpolation `\(…)` kept as a marker. A small scanner, not a regular
    /// expression: interpolations can hold quotes of their own.
    static func uiTexts(in source: String) -> [String] {
        let calls = ["Text(", "Button(", "Label(", "Toggle(", "TextField(", "SecureField(", "ShortcutLabel(", "CommandMenu(",
                     "headerButton(", "slider(", "infoRow(", ".help(", ".accessibilityLabel(", ".accessibilityValue(",
                     "String(localized: ", "action: ", "word: ", "Group(title: ", "title: "]
        let chars = Array(source)
        var texts: [String] = []
        var i = 0
        while i < chars.count {
            guard let start = calls.first(where: { matches($0, chars, at: i) }) else { i += 1; continue }
            // Right after a letter or digit it's another call ("myText(")
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_", !start.hasPrefix(".") { i += 1; continue }
            let (literals, end) = argument(chars, from: i + start.count)
            texts += literals.filter { $0.contains(where: \.isLetter) }
            i = max(end, i + 1)
        }
        // The help's keys column, where it holds words ("drag")
        i = 0
        let shortcut = "Shortcut(keys: "
        while i < chars.count {
            guard matches(shortcut, chars, at: i) else { i += 1; continue }
            let (literals, end) = argument(chars, from: i + shortcut.count)
            var close = end, depth = 1
            while close < chars.count, depth > 0 {
                if chars[close] == "(" { depth += 1 } else if chars[close] == ")" { depth -= 1 }
                close += 1
            }
            if String(chars[i..<min(close, chars.count)]).contains("wordsInKeys: true") {
                texts += literals.filter { $0.contains(where: \.isLetter) }
            }
            i = max(end, i + 1)
        }
        return texts
    }

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
    ]

    /// Every text the app shows has an English entry, so every language
    /// can translate it (a missing one would stay English everywhere).
    func testEveryTextInTheCodeHasAnEntry() throws {
        let english = Set(try table("en", "Localizable.strings").keys)
            .union(try table("en", "Localizable.stringsdict").keys)
            .union(Self.readByUITests)
        let sources = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Schnellbild")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        var found = 0
        for file in files {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
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

    func testTheScannerReadsEveryFormOfText() {
        let source = #"""
        Text(stopped ? "Search stopped" : "No \(n) matches").font(.x)
        Text(verbatim: "Name.jpg") Text(entry.name) Image(systemName: "folder")
        headerButton("Date Modified", key: .modified)
        .accessibilityValue(up ? "ascending" : "descending") .accessibilityLabel("Stop search")
        Text(format("No"))
        Shortcut(keys: "⌘F", action: "Search") Shortcut(keys: "drag", action: "Move", wordsInKeys: true)
        """#
        XCTAssertEqual(Self.uiTexts(in: source), ["Search stopped", "No \u{1} matches", "Date Modified", "ascending", "descending",
                                                  "Stop search", "Search", "Move", "drag"])
    }

    func testPlaceholdersKeepTheirPositions() {
        XCTAssertEqual(Self.placeholders("%@ of %lld"), Self.placeholders("%2$lld von %1$@"))
        XCTAssertNotEqual(Self.placeholders("%@ and %@"), Self.placeholders("%1$@ und %1$@"))
        XCTAssertNotEqual(Self.placeholders("%@ of %lld"), Self.placeholders("%lld von %@"))
    }

    /// Info.plist names exactly the languages there are.
    func testInfoPlistListsTheLanguages() throws {
        let plist = root.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let listed = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(listed), Set(languages))
    }
}
