import XCTest
@testable import Schnellbild

/// Every format the app shows is listed (Johannes' rule "Every format shows"):
/// site/formats.json is the list the website's formats pages are made from,
/// and build_site.py fails when the README's tables leave one of its
/// extensions out. Here the list is held to the app's own extensions, both
/// ways, on every macOS: the ones this macOS's ImageIO reads (DICOM, ".ori")
/// count whether or not it reads them.
final class FormatListTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Entry: Decodable {
        let id: String
        let kind: String
        let ext: [String]
        let parts: Bool?
    }

    private func entries() throws -> [Entry] {
        struct List: Decodable { let formats: [Entry] }
        let data = try Data(contentsOf: repository.appendingPathComponent("site/formats.json"))
        return try JSONDecoder().decode(List.self, from: data).formats
    }

    /// The extensions a file is shown by, whichever macOS runs the app.
    private var accepted: [String: String] {
        var kinds: [String: String] = [:]
        let pictures = BrowserModel.imageExtensions
            .union(BrowserModel.systemImageExtensions)
            .union(RawDecoder.librawOnly)
            .union(PictureDecoders.ownExtensions)
            .union(EmbeddedPreview.extensions)
        for ext in pictures { kinds[ext] = "picture" }
        for ext in BrowserModel.videoExtensions.union(["ts"]) { kinds[ext] = "video" }
        for ext in ArchiveName.formats.keys { kinds[ext] = "archive" }
        kinds["001"] = "archive"
        return kinds
    }

    func testEveryExtensionTheAppShowsIsListed() throws {
        let listed = Set(try entries().flatMap { $0.ext.map { ($0 as NSString).pathExtension.isEmpty ? $0 : ($0 as NSString).pathExtension } })
        let missing = Set(accepted.keys).subtracting(listed).sorted()
        XCTAssertEqual(missing, [], "shown by the app but not in site/formats.json (and so not on the website or in the README)")
    }

    func testNothingIsListedThatTheAppDoesNotShow() throws {
        let accepted = accepted
        for entry in try entries() where entry.parts != true {
            for ext in entry.ext {
                let last = (ext as NSString).pathExtension.isEmpty ? ext : (ext as NSString).pathExtension
                let kind = try XCTUnwrap(accepted[last], "\(entry.id): .\(ext) is listed, the app doesn't show it")
                // Documents are pictures to the app
                XCTAssertEqual(entry.kind == "document" ? "picture" : entry.kind, kind, "\(entry.id): .\(ext)")
            }
        }
    }

    func testListedArchivesAndTheirPartsOpenAsArchives() throws {
        for entry in try entries() where entry.kind == "archive" {
            for ext in entry.ext {
                let name = "Holiday." + ext
                if entry.parts == true, ArchiveName.format(of: name) == nil {
                    // A later volume: hidden, read through its first one
                    XCTAssertFalse(ArchiveName.firstVolumeNames(of: name).isEmpty, "\(entry.id): \(name)")
                } else {
                    XCTAssertNotNil(ArchiveName.format(of: name), "\(entry.id): \(name)")
                }
            }
        }
    }

    func testArchiveNamesKeepTheirFormats() {
        XCTAssertEqual(ArchiveName.format(of: "a.zip"), .zip)
        XCTAssertEqual(ArchiveName.format(of: "a.CBZ"), .zip)
        XCTAssertEqual(ArchiveName.format(of: "a.7z"), .sevenZip)
        XCTAssertEqual(ArchiveName.format(of: "a.cb7"), .sevenZip)
        XCTAssertEqual(ArchiveName.format(of: "a.rar"), .rar)
        XCTAssertEqual(ArchiveName.format(of: "a.cbr"), .rar)
        XCTAssertEqual(ArchiveName.format(of: "a.part1.rar"), .rar)
        XCTAssertNil(ArchiveName.format(of: "a.part2.rar"))
        XCTAssertNil(ArchiveName.format(of: "a.part2.cbr"))
        XCTAssertEqual(ArchiveName.format(of: "a.7z.001"), .sevenZip)
        XCTAssertEqual(ArchiveName.format(of: "a.zip.001"), .zip)
        XCTAssertNil(ArchiveName.format(of: "a.rar.001"))
        XCTAssertNil(ArchiveName.format(of: "a.001"))
        XCTAssertNil(ArchiveName.format(of: "a.zip.002"))
        XCTAssertEqual(ArchiveName.format(of: "a.rar.part"), .rar)
        XCTAssertNil(ArchiveName.format(of: "._a.zip"))
        XCTAssertNil(ArchiveName.format(of: "a.tar"))
    }
}
