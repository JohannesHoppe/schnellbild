import XCTest

/// Downloads not finished ("x.mp4.part" counts as an MP4, marked with a small
/// arrow) and files whose names say nothing (they count by their content).
/// Fixtures: UITests/Fixtures/partial (`Scripts/make_video_fixtures.sh partial`).
final class PartialFilesUITests: SchnellbildUITestCase {
    private func percent(_ bar: XCUIElement) -> Int { Int(text(of: bar).filter(\.isNumber)) ?? -1 }

    /// An MP4 still downloading (its index first), opened as a drop opens
    /// it: it plays in AVKit as far as its data reaches.
    func testAnOpenedMP4DownloadPlays() throws {
        let file = try put("front.mp4.part", at: "film.mp4.part")
        launch(open: file.path)
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 20), "an MP4 by its final name")
        waitForBadge(containing: "film.mp4.part")
        let bar = element("videoProgress")
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        eventually("plays", timeout: 15) { self.percent(bar) > 5 }
    }

    /// A Matroska download cut off plays in VLC.
    func testAnOpenedMKVDownloadPlaysInVLC() throws {
        let file = try put("film.mkv.part", at: "clip.mkv.part")
        launch(open: file.path)
        XCTAssertTrue(element("video.vlc").waitForExistence(timeout: 20))
        let bar = element("videoProgress")
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        eventually("plays", timeout: 15) { self.percent(bar) > 5 }
    }

    /// An MP4 cut off before its index (written last) can't play yet: the
    /// view says why.
    func testAnMP4CutBeforeItsIndexSaysWhy() throws {
        let file = try put("end.mp4.part", at: "film.mp4.part")
        launch(open: file.path)
        let note = element("video.unplayable")
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        XCTAssertTrue(text(of: note).contains("download") || note.staticTexts.firstMatch.label.contains("download"),
                      "\(text(of: note)) / \(note.staticTexts.firstMatch.label)")
    }

    /// A folder of downloads in progress isn't greyed out; inside, each
    /// shows with its preview and the small arrow, in the grid and the list.
    func testAFolderOfDownloadsShowsThemMarked() throws {
        try put("front.mp4.part", at: "downloads/film.mp4.part")
        try put("film.mkv.part", at: "downloads/clip.mkv.part")
        try put("large.jpg", at: "downloads/photo.jpg.crdownload")
        try put("photos-cut.rar.part", at: "downloads/photos.rar.part")
        launchOnTempDir()
        let folder = tile("downloads")
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        eventually("the folder shows previews of the downloads", timeout: 30) {
            let state = self.text(of: folder)
            return !state.contains("empty") && !state.contains(" 0 previews")
        }
        openTile("downloads", showing: tile("film.mp4.part"))
        for name in ["film.mp4.part", "clip.mkv.part", "photo.jpg.crdownload"] {
            XCTAssertTrue(tile(name).waitForExistence(timeout: 15), name)
            eventually("\(name): marked, with its preview", timeout: 30) {
                let state = self.text(of: self.tile(name))
                return state.contains("unfinished") && state.hasSuffix(", preview")
            }
        }
        let archive = tile("photos.rar.part")
        eventually("the archive is marked, not greyed out", timeout: 20) {
            let state = self.text(of: archive)
            return state.contains("unfinished") && !state.contains("empty")
        }
        // For the report: the grid with its marks (the CI shell keeps the screen)
        _ = try? screenStats(of: app.windows.firstMatch.frame)
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(element("row.film.mp4.part").waitForExistence(timeout: 10), "the list view")
        _ = try? screenStats(of: app.windows.firstMatch.frame)
        // Inside the archive cut off: the picture it cuts is marked as incomplete
        app.typeKey("l", modifierFlags: [])
        openTile("photos.rar.part", showing: tile("Day 1"))
        openTile("Day 1", showing: tile("big.jpg"))
        eventually("the picture cut off is marked", timeout: 15) { self.text(of: self.tile("big.jpg")).contains("unfinished") }
    }

    /// The Inspector says the download isn't finished.
    func testTheInspectorSaysTheDownloadIsntFinished() throws {
        let file = try put("front.mp4.part", at: "film.mp4.part")
        launch(open: file.path)
        XCTAssertTrue(element("video.avkit").waitForExistence(timeout: 20))
        app.typeKey("i", modifierFlags: [])
        let inspector = element("inspector")
        XCTAssertTrue(inspector.waitForExistence(timeout: 10))
        eventually("a Download row", timeout: 10) { inspector.staticTexts["Not finished"].exists }
    }

    /// A JPEG without an extension and an MP4 named ".xyz" show by their
    /// content: in the grid, and the picture in the full view.
    func testFilesOfUnknownNamesShowByTheirContent() throws {
        try put("large.jpg", at: "IMG_0001")
        try put("clip.mp4", at: "clip.xyz")
        launchOnTempDir()
        let photo = tile("IMG_0001")
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "read by its content")
        eventually("with its preview", timeout: 20) { self.text(of: photo).hasSuffix(", preview") }
        XCTAssertTrue(tile("clip.xyz").waitForExistence(timeout: 20))
        XCTAssertTrue(text(of: tile("clip.xyz")).contains("video"), text(of: tile("clip.xyz")))
        openInFullView("IMG_0001")
        eventually("the picture opens", timeout: 15) { self.text(of: self.element("fullImage")).hasSuffix("loaded") }
    }

    /// A picture without an extension, opened alone (as a drop): shown at once.
    func testAnOpenedFileOfUnknownNameShows() throws {
        let file = try put("large.jpg", at: "IMG_0002")
        launch(open: file.path)
        eventually("the picture opens", timeout: 20) { self.text(of: self.element("fullImage")).hasSuffix("loaded") }
        waitForBadge(containing: "IMG_0002")
    }
}
