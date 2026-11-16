import XCTest
import AppKit

/// The Atlas's header in the app, in each of the 20 languages: Tour,
/// the count and Include subfolders each as wide as their words at least
/// (a control cut to "Viag…" for Portuguese's "Viagem" would be narrower).
/// `AtlasLabelTests` lays the same views out on their own; this is them in
/// the window, as the screenshots show them.
final class AtlasLabelUITests: SchnellbildUITestCase {
    private let trip = [
        "norway-01-bryggen.jpg", "norway-02-bryggen.jpg", "norway-03-harbour.jpg", "norway-04-floyen.jpg",
        "norway-05-flam.jpg", "norway-06-flam.jpg", "norway-07-stegastein.jpg", "norway-08-geiranger.jpg",
        "norway-09-geiranger.jpg", "norway-10-geiranger.mov", "norway-11-dalsnibba.jpg", "norway-12-alesund.jpg",
        "norway-13-evening.jpg", "norway-14-trollstigen.jpg",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try FileManager.default.removeItem(at: tempDir.appendingPathComponent(name)) }
        for name in trip { try put(name, at: name) }
    }

    private var languages: [String] {
        Bundle(for: AtlasLabelUITests.self).localizations.filter { $0 != "Base" }.sorted()
    }

    private func strings(_ language: String) -> [String: String] {
        let path = Bundle(for: AtlasLabelUITests.self).path(forResource: "Localizable", ofType: "strings",
                                                            inDirectory: nil, forLocalization: language)
        return path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
    }

    /// How wide the system font writes a text in a language: with that
    /// language's fallback fonts (Japanese's differ from those the test
    /// runner, in English, would take: 7 pt on "サブフォルダも含める").
    private func width(_ text: String, size: CGFloat, language: String) -> CGFloat {
        let base = NSFont.systemFont(ofSize: size) as CTFont
        let cascade = CTFontCopyDefaultCascadeListForLanguages(base, [language] as CFArray) ?? ([] as CFArray)
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: cascade] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
        return ceil((text as NSString).size(withAttributes: [.font: font as NSFont]).width)
    }

    /// Each control's width less its words' is what it adds (an icon, a
    /// key, a box): the same in every language. A word cut short ("Viag…")
    /// leaves a control narrower by a letter or more, so its share falls
    /// below the others' (2 pt allowed for how fonts measure; Finnish's "Mat…" was 3 pt short).
    func testTheHeadersWordsAreWholeInEveryLanguage() throws {
        continueAfterFailure = true
        XCTAssertEqual(languages.count, 20, "\(languages)")
        var tourChrome: [String: CGFloat] = [:], countChrome: [String: CGFloat] = [:], toggleChrome: [String: CGFloat] = [:]
        for language in languages {
            let table = strings(language)
            launch(open: tempDir.path, language: language)
            XCTAssertTrue(app.staticTexts["norway-01-bryggen.jpg"].waitForExistence(timeout: 15), language)
            app.typeKey("w", modifierFlags: [])
            let count = element("atlasCount")
            let onMap = String(format: table["%lld on the map"] ?? "%lld on the map", 13)
            eventually("\(language): the places are read", timeout: 20) { self.text(of: count) == onMap }
            let tour = table["Tour"] ?? "Tour", subfolders = table["Include subfolders"] ?? "Include subfolders"
            let tourFrame = element("tourButton").firstMatch.frame, toggleFrame = element("atlasSubfolders").firstMatch.frame
            tourChrome[language] = tourFrame.width - width(tour, size: NSFont.systemFontSize, language: language)
            countChrome[language] = count.frame.width - width(onMap, size: 10, language: language)
            toggleChrome[language] = toggleFrame.width - width(subfolders, size: 10, language: language)
            print("\(language): Tour “\(tour)” \(tourFrame.width) pt (adds \(tourChrome[language]!)), “\(onMap)” \(count.frame.width) pt (adds \(countChrome[language]!)), “\(subfolders)” \(toggleFrame.width) pt (adds \(toggleChrome[language]!))")
            app.terminate()
        }
        for (name, shares) in [("Tour", tourChrome), ("the count", countChrome), ("Include subfolders", toggleChrome)] {
            let usual = shares.values.max() ?? 0
            for (language, share) in shares.sorted(by: { $0.key < $1.key }) {
                XCTAssertGreaterThanOrEqual(share, usual - 2, "\(language): \(name) adds \(share) pt to its words, the others \(usual) pt: cut short")
            }
        }
    }
}
