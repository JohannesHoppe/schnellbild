import XCTest
@testable import Schnellbild

/// Settings → General → Show photos on folders (`BrowserModel.folderPreviews`).
@MainActor
final class FolderPreviewsTests: XCTestCase {
    func testPhotosOnFoldersAreOnUnlessTurnedOffEverywhere() {
        let defaults = makeTestDefaults()
        let pane = BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions)
        XCTAssertTrue(pane.folderPreviews, "on unless turned off")
        // Every pane of the same preferences follows, and it is kept
        let other = BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions)
        pane.folderPreviews = false
        XCTAssertFalse(other.folderPreviews)
        XCTAssertFalse(BrowserModel(defaults: defaults, fileActions: FileActionsSpy().actions).folderPreviews, "remembered")
        other.folderPreviews = true
        XCTAssertTrue(pane.folderPreviews)
    }

    /// The Finder's icons: macOS's folder, an archive's type's (one macOS
    /// doesn't know, the generic archive's), each at a size that stays sharp
    /// on a tile.
    func testFoldersAndArchivesLookAsInTheFinder() throws {
        let folder = try XCTUnwrap(FolderIcon.folder.image)
        XCTAssertEqual(folder.size, NSSize(width: 512, height: 512))
        XCTAssertNotNil(FolderIcon.archive(URL(fileURLWithPath: "/tmp/Trip.zip")).image)
        XCTAssertNotNil(FolderIcon.archive(URL(fileURLWithPath: "/tmp/Trip.rar.part")).image)
        XCTAssertNil(FolderIcon.symbol("externaldrive.fill").image)
    }
}
