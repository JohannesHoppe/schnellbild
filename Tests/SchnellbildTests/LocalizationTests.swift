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
}
