import XCTest
import Foundation

/// Every language has every string English has, and each translation takes
/// the same values (`%@`, `%lld`) as its English source, in any order.
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

    /// The value placeholders of a format, without their positions ("%2$@" → "@").
    static func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(lld|ld|d|@)")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range)
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .sorted()
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
                let rule = try XCTUnwrap((entry as? [String: Any])?["count"] as? [String: Any], "\(language): \(key)")
                XCTAssertNotNil(rule["other"], "\(language): \(key) needs an “other” form")
                for (category, form) in rule where !category.hasPrefix("NS") {
                    XCTAssertEqual(Self.placeholders(try XCTUnwrap(form as? String)), ["lld"], "\(language): \(key) [\(category)]")
                }
            }
        }
    }

    // MARK: The code against the tables

    /// The UI texts written in the code: string literals after the calls
    /// that show text (`Text("…")`, `Button("…"`, `.help("…")`,
    /// `String(localized: "…")`, the help's `action: "…"` …), with each
    /// interpolation `\(…)` kept as a marker. A small scanner, not a regular
    /// expression: interpolations can hold quotes of their own.
    static func uiTexts(in source: String) -> [String] {
        let starts = ["Text(\"", "Button(\"", "Label(\"", "Toggle(\"", "TextField(\"", "SecureField(\"", "ShortcutLabel(\"", "CommandMenu(\"",
                      ".help(\"", "String(localized: \"", "action: \"", "word: \"", "Group(title: \"", "title: \"", "slider(\"", "infoRow(\""]
        let chars = Array(source)
        var texts: [String] = []
        var i = 0
        while i < chars.count {
            guard let start = starts.first(where: { start in
                let s = Array(start)
                return i + s.count <= chars.count && Array(chars[i..<i + s.count]) == s
            }) else { i += 1; continue }
            // Right after a letter or digit it's another call ("myText(")
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_", !start.hasPrefix(".") { i += 1; continue }
            var j = i + start.count
            var text = ""
            while j < chars.count, chars[j] != "\"" {
                if chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == "(" {
                    var depth = 1
                    j += 2
                    while j < chars.count, depth > 0 {
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
            if text.contains(where: \.isLetter) { texts.append(text) }
            i = j + 1
        }
        return texts
    }

    /// The table keys a text can have: each interpolation becomes `%@` or
    /// `%lld` (SwiftUI picks by the value's type).
    static func keys(for text: String) -> [String] {
        let parts = text.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
        var keys = [parts[0]]
        for part in parts.dropFirst() { keys = keys.flatMap { [$0 + "%@" + part, $0 + "%lld" + part] } }
        return keys
    }

    /// Every text the app shows has an English entry, so every language
    /// can translate it (a missing one would stay English everywhere).
    func testEveryTextInTheCodeHasAnEntry() throws {
        let english = Set(try table("en", "Localizable.strings").keys)
            .union(try table("en", "Localizable.stringsdict").keys)
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

    /// Info.plist names exactly the languages there are.
    func testInfoPlistListsTheLanguages() throws {
        let plist = root.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let listed = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(listed), Set(languages))
    }
}
