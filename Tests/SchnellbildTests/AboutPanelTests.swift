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

    private var licenses: URL { repository.appendingPathComponent("Resources/Licenses") }

    private func document() -> LicenseDocument {
        LicenseDocument.load(licenses: licenses, ownLicense: repository.appendingPathComponent("LICENSE"))
    }

    /// Every license text the app carries is shown, none is named that isn't there.
    func testEveryLicenseFileIsShown() throws {
        let shipped = Set(try FileManager.default.contentsOfDirectory(atPath: licenses.path).filter { !$0.hasPrefix(".") })
        let named = AboutPanel.sections.flatMap(\.allFiles)
        XCTAssertEqual(Set(named.filter { $0 != AboutPanel.ownLicense }), shipped)
        XCTAssertEqual(named.first, AboutPanel.ownLicense, "Schnellbild's own license comes first")
        let text = document().text.string
        XCTAssertFalse(text.contains("is missing)"), "a text couldn't be read")
        for file in shipped where file != AboutPanel.vlckitLibraries {
            let content = try String(contentsOf: licenses.appendingPathComponent(file), encoding: .utf8)
                .trimmingCharacters(in: .newlines)
            XCTAssertTrue(text.contains(content), "\(file) isn't shown in full")
        }
    }

    /// The MIT License is the first text, in full, under Schnellbild's heading.
    func testTheMITLicenseComesFirst() throws {
        let document = document()
        let license = try String(contentsOf: repository.appendingPathComponent("LICENSE"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        XCTAssertTrue(license.hasPrefix("MIT License"))
        let text = document.text.string as NSString
        let mit = text.range(of: license)
        XCTAssertNotEqual(mit.location, NSNotFound)
        XCTAssertEqual(document.starts.first?.id, "schnellbild")
        XCTAssertEqual(document.starts.first?.offset, 0)
        XCTAssertLessThan(mit.location, document.starts[1].offset, "the MIT text before the next section")
        XCTAssertTrue(text.substring(to: document.starts[1].offset).contains("Permission is hereby granted, free of charge"))
    }

    /// Each library inside VLCKit gets its own section with its own text, and
    /// together they hold the whole file.
    func testTheLibrariesInsideVLCKitAreSectionsOfTheirOwn() throws {
        let file = try String(contentsOf: licenses.appendingPathComponent(AboutPanel.vlckitLibraries), encoding: .utf8)
        let split = LicenseDocument.splitLibraries(file)
        XCTAssertTrue(split.intro.hasPrefix("Third-party libraries in VLCKit"))
        XCTAssertGreaterThan(split.libraries.count, 30)
        XCTAssertTrue(split.libraries.contains { $0.name == "ffmpeg" && $0.text.contains("GNU LESSER GENERAL PUBLIC LICENSE") })
        let document = document()
        let vlckit = try XCTUnwrap(document.sections.first { $0.id == "vlckit" })
        let libraries = try XCTUnwrap(vlckit.children?.first { $0.id == "vlckit-libraries" })
        XCTAssertEqual(libraries.children?.map(\.name), split.libraries.map(\.name))
        let text = document.text.string
        XCTAssertTrue(text.contains(split.intro))
        for library in split.libraries {
            XCTAssertTrue(text.contains(library.text), "\(library.name)'s text")
            XCTAssertTrue(document.starts.contains { $0.id == "vlckit-libraries.\(library.name)" })
        }
        // In text order: the sections' starts grow, each once
        XCTAssertEqual(document.starts.map(\.offset), document.starts.map(\.offset).sorted())
        XCTAssertEqual(Set(document.starts.map(\.id)).count, document.starts.count)
    }

    /// The VLCKit section names the build the app carries: the version
    /// Scripts/fetch_vlckit.sh fetches, whose release holds its source.
    func testTheVLCKitSectionNamesTheBuildTheAppCarries() throws {
        let script = try String(contentsOf: repository.appendingPathComponent("Scripts/fetch_vlckit.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("VERSION=\"\(AboutPanel.vlckitBuild)\""), "fetch_vlckit.sh fetches another VLCKit")
        let text = document().text.string
        XCTAssertTrue(text.contains(AboutPanel.vlckitRelease))
        XCTAssertTrue(text.contains("LGPL-only build of VLCKit"))
        XCTAssertFalse(text.contains("AGPL"))
        let patches = try FileManager.default.contentsOfDirectory(atPath: repository.appendingPathComponent("Scripts/vlc-patches").path)
            .filter { $0.hasSuffix(".patch") }
        XCTAssertEqual(patches.count, 6, "the VLCKit section speaks of six changes to VLC")
    }
}
