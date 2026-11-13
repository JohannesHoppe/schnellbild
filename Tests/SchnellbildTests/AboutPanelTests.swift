import XCTest
@testable import Schnellbild

/// The About window links the privacy policy in the UI's language: every
/// language the app is translated into has its page on the website (docs/).
@MainActor
final class AboutPanelTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPrivacyPolicyOfEveryLanguageIsOnTheWebsite() throws {
        XCTAssertEqual(AboutPanel.website(for: "en"), "https://schnellbild.haushoppe-its.de/")
        XCTAssertEqual(AboutPanel.website(for: "zh-Hans"), "https://schnellbild.haushoppe-its.de/zh-hans/")
        XCTAssertEqual(AboutPanel.privacyPolicy(for: "en"), "https://schnellbild.haushoppe-its.de/privacy/")
        XCTAssertEqual(AboutPanel.privacyPolicy(for: "de"), "https://schnellbild.haushoppe-its.de/de/datenschutz/")
        XCTAssertEqual(AboutPanel.privacyPolicy(for: "pt-BR"), "https://schnellbild.haushoppe-its.de/pt-br/privacy/")
        let names = try FileManager.default.contentsOfDirectory(atPath: repository.appendingPathComponent("Resources/Localization").path)
        let languages = names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }
        XCTAssertEqual(languages.count, 20)
        for language in languages {
            let page = AboutPanel.privacyPolicy(for: language)
                .replacingOccurrences(of: "https://schnellbild.haushoppe-its.de/", with: "docs/")
            XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent(page + "index.html").path),
                          "\(language): no \(page)index.html")
        }
    }
}
