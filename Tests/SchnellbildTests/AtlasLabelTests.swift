import XCTest
import SwiftUI
@testable import Schnellbild

/// The Atlas's words in all 20 languages: each control laid out with its
/// language's text is at least as wide as that text (a label given a width
/// of its own, or a control that doesn't size to its label, would cut it:
/// "Viag…" for Portuguese's "Viagem"), and the header and the timeline's
/// labels fit a pane at its narrowest (on two rows where one doesn't).
@MainActor
final class AtlasLabelTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization")
    }

    private var languages: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }.sorted()
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
    }

    /// A format of the language with the numbers put in (positions too).
    private func format(_ table: [String: String], _ key: String, _ numbers: CVarArg...) -> String {
        String(format: table[key] ?? key, arguments: numbers)
    }

    /// How wide the system font writes a text.
    private func width(_ text: String, size: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
    }

    /// The width a view takes laid out on its own (as wide as it wants).
    private func laidOut<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The size a view takes in a pane of `width` points.
    private func laidOut<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 2000))
    }

    /// The narrowest a pane gets: the dual pane's smaller half (`PaneDivider.leftWidth`).
    private let narrowestPane: CGFloat = 220
    /// The map's padding around the header (10) on each side (its own is inside it).
    private let headerMargins: CGFloat = 20

    private func header(_ table: [String: String], progress: BrowserModel.Progress? = nil) -> AtlasHeader {
        AtlasHeader(texts: AtlasHeaderTexts(
            tour: table["Tour"] ?? "Tour", tourHelp: "", tourLabel: table["Play the tour"] ?? "",
            tourKey: KeyChord(.char("t")),
            count: progress.map { format(table, "Reading locations: %lld of %lld", $0.done, $0.total) }
                ?? format(table, "%lld on the map", 99_999),
            subfolders: table["Include subfolders"] ?? "", subfoldersHelp: "", walking: table["Reading subfolders…"] ?? ""),
            progress: progress, tourEnabled: true, showsSubfolders: true, subfolders: .constant(true), walking: true, onTour: {})
    }

    func testEveryHeaderControlIsAsWideAsItsWordsInEveryLanguage() throws {
        XCTAssertEqual(languages.count, 20)
        for language in languages {
            let table = try strings(language)
            for progress in [nil, BrowserModel.Progress(done: 88_888, total: 99_999)] {
                let header = header(table, progress: progress)
                let tour = laidOut(header.tourButton).width
                XCTAssertGreaterThanOrEqual(tour, width(header.texts.tour, size: NSFont.systemFontSize),
                                            "\(language): Tour “\(header.texts.tour)” gets \(tour) pt")
                let count = laidOut(header.countLabel).width
                XCTAssertGreaterThanOrEqual(count, width(header.texts.count, size: 10),
                                            "\(language): “\(header.texts.count)” gets \(count) pt")
                let toggle = laidOut(header.subfolderToggle).width
                XCTAssertGreaterThanOrEqual(toggle, width(header.texts.subfolders, size: 10) + 14,
                                            "\(language): “\(header.texts.subfolders)” and its box get \(toggle) pt")
                // The whole header: its parts side by side at least, and in the narrowest pane
                let whole = laidOut(header).width
                XCTAssertGreaterThanOrEqual(whole, tour + count + toggle, "\(language): the header \(whole) pt")
                let narrow = laidOut(header, width: narrowestPane - headerMargins)
                XCTAssertLessThanOrEqual(narrow.width, narrowestPane - headerMargins,
                                         "\(language): the header in the narrowest pane is \(narrow.width) pt wide")
            }
        }
    }

    func testTheTimelinesLabelsAreWholeInEveryLanguage() throws {
        let from = AtlasTimeline.text(Date(timeIntervalSince1970: 1_781_000_000), in: .current, time: true)
        for language in languages {
            let table = try strings(language)
            let labels = TimelineLabels(texts: TimelineTexts(
                from: from, to: from, count: format(table, "%lld of %lld", 99_998, 99_999),
                showAll: table["Show All"] ?? "", showAllHelp: "")) {}
            let showAll = laidOut(HStack { labels.narrowed }).width
            XCTAssertGreaterThanOrEqual(showAll, width(labels.texts.count ?? "", size: 10) + width(labels.texts.showAll, size: 10),
                                        "\(language): “\(labels.texts.count ?? "")” and “\(labels.texts.showAll)” get \(showAll) pt")
            XCTAssertGreaterThanOrEqual(laidOut(labels.from).width, width(from, size: 10))
            // The timeline's own padding (12) on each side
            let narrow = laidOut(labels, width: narrowestPane - 24)
            XCTAssertLessThanOrEqual(narrow.width, narrowestPane - 24, "\(language): the timeline's labels are \(narrow.width) pt wide")
        }
    }

    /// The tour's place count and the strip's title, the app's own views
    /// with each language's words, are whole too: on their own and given
    /// less room than they need (a pane at its narrowest).
    func testTheTourAndTheStripSayTheirWordsWhole() throws {
        for language in languages {
            let table = try strings(language)
            let place = format(table, "Place %lld of %lld", 999, 999)
            let status = TourStatusLabel(text: place)
            XCTAssertGreaterThanOrEqual(laidOut(status).width, width(place, size: 12) - 1, "\(language): “\(place)”")
            XCTAssertGreaterThanOrEqual(laidOut(status, width: 40).width, width(place, size: 12) - 1, "\(language): “\(place)” squeezed")
            let strip = format(table, "No location, %lld", 99_999)
            let title = AtlasStripTitle(text: strip)
            XCTAssertGreaterThanOrEqual(laidOut(title).width, width(strip, size: 10), "\(language): “\(strip)”")
            XCTAssertGreaterThanOrEqual(laidOut(title, width: 40).width, width(strip, size: 10), "\(language): “\(strip)” squeezed")
        }
        // What the app shows is these views with its own words
        XCTAssertEqual(TourStatusLabel.localized(station: 3, of: 8).text, String(localized: "Place \(3) of \(8)"))
        XCTAssertEqual(AtlasStripTitle.localized(count: 12).text, String(localized: "No location, \(12)"))
    }

    /// A status or title cut to a width is caught by the measure above.
    func testACutStatusIsCaught() {
        let place = "Place 999 of 999"
        let cut = laidOut(Text(verbatim: place).font(.callout.monospacedDigit()).frame(width: 40), width: 40).width
        XCTAssertLessThan(cut, width(place, size: 12) - 1)
    }

    /// A control that doesn't size to its label is caught: an AppKit
    /// borderless button around the longest Tour word (what showed
    /// "Viag…"), and a label given a width.
    func testACutLabelIsCaught() {
        let word = "Viagem"
        let given = laidOut(Text(verbatim: word).frame(width: 20)).width
        XCTAssertLessThan(given, width(word, size: NSFont.systemFontSize), "a width given to a label is narrower than its word")
        let borderless = laidOut(Button {} label: { HStack(spacing: 5) { Image(systemName: "play.fill"); Text(verbatim: word); KeyCap("T") } }
            .buttonStyle(.borderless)).width
        let drawn = laidOut(Button {} label: { HStack(spacing: 5) { Image(systemName: "play.fill"); Text(verbatim: word).fixedSize(); KeyCap("T") } }
            .buttonStyle(HeaderButtonStyle())).width
        print("“\(word)”: \(width(word, size: NSFont.systemFontSize)) pt as text, a borderless button \(borderless) pt, the header's \(drawn) pt")
        XCTAssertGreaterThan(drawn, width(word, size: NSFont.systemFontSize) + 20, "with its icon and key")
    }
}
