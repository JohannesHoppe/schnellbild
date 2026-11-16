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

    private func width(_ text: String, size: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
    }

    func testTheHeadersWordsAreWholeInEveryLanguage() throws {
        continueAfterFailure = true
        XCTAssertEqual(languages.count, 20, "\(languages)")
        for language in languages {
            let table = strings(language)
            launch(open: tempDir.path, language: language)
            XCTAssertTrue(app.staticTexts["norway-01-bryggen.jpg"].waitForExistence(timeout: 15), language)
            app.typeKey("w", modifierFlags: [])
            let count = element("atlasCount")
            let onMap = String(format: table["%lld on the map"] ?? "%lld on the map", 13)
            eventually("\(language): the places are read", timeout: 20) { self.text(of: count) == onMap }
            let tour = table["Tour"] ?? "Tour", subfolders = table["Include subfolders"] ?? "Include subfolders"
            // (with its icon and the spacing beside the word: 20 pt at least)
            let tourFrame = element("tourButton").firstMatch.frame
            XCTAssertGreaterThanOrEqual(tourFrame.width, width(tour, size: NSFont.systemFontSize) + 20,
                                        "\(language): Tour “\(tour)” in \(tourFrame.width) pt")
            XCTAssertGreaterThanOrEqual(count.frame.width, width(onMap, size: 10), "\(language): “\(onMap)” in \(count.frame.width) pt")
            let toggle = element("atlasSubfolders").firstMatch.frame
            XCTAssertGreaterThanOrEqual(toggle.width, width(subfolders, size: 10) + 14,
                                        "\(language): “\(subfolders)” and its box in \(toggle.width) pt")
            print("\(language): Tour “\(tour)” \(tourFrame.width) pt, count \(count.frame.width) pt, subfolders \(toggle.width) pt")
            app.terminate()
        }
    }
}
