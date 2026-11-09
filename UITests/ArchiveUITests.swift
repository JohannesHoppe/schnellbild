import XCTest

/// Archives open like folders: ZIP and RAR, pictures and videos inside,
/// the password asked once and remembered, unfinished downloads.
final class ArchiveUITests: SchnellbildUITestCase {

    /// Zips the temp folder's `src` into `name` (stored, so a cut keeps
    /// whole files before it) and removes `src`.
    @discardableResult
    private func zip(_ name: String, password: String? = nil, files: [String] = ["-r", "."]) throws -> URL {
        let src = tempDir.appendingPathComponent("src")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-0"] + (password.map { ["-P", $0] } ?? []) + ["../\(name)"] + files
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.removeItem(at: src)
        return tempDir.appendingPathComponent(name)
    }

    private func makeHoliday(password: String? = nil) throws -> URL {
        try put("dark.jpg", at: "src/beach.jpg")
        try put("bright.jpg", at: "src/Day 1/sun.jpg")
        return try zip("Holiday.zip", password: password)
    }

    func testAZipBrowsesLikeAFolderWithItsPictures() throws {
        try makeHoliday()
        launchOnTempDir()
        let archive = tile("Holiday.zip")
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: archive).contains("archive"), text(of: archive))
        eventually("the archive tile previews its pictures", timeout: 20) { self.text(of: archive).contains("previews") && !self.text(of: archive).hasSuffix("0 previews") }
        archive.doubleClick()
        let beach = tile("beach.jpg")
        XCTAssertTrue(beach.waitForExistence(timeout: 15))
        eventually("a thumbnail from inside the archive", timeout: 15) { self.text(of: beach).hasSuffix("preview") }
        XCTAssertTrue(tile("Day 1").exists)
        beach.doubleClick()
        let image = element("fullImage")
        eventually("the picture opens", timeout: 15) { self.text(of: image).hasSuffix("loaded") }
        app.typeKey(.escape, modifierFlags: [])
        tile("Day 1").doubleClick()
        XCTAssertTrue(tile("sun.jpg").waitForExistence(timeout: 15))
    }

    /// Typed once, the password is remembered: after a restart the archive
    /// opens without asking.
    func testThePasswordIsAskedOnceAndRemembered() throws {
        let archive = try makeHoliday(password: "secret")
        launch(open: archive.path)
        let field = app.secureTextFields["passwordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "asks for the password")
        field.typeText("wrong\r")
        XCTAssertTrue(element("passwordWrong").waitForExistence(timeout: 10), "says the password doesn't open it")
        app.secureTextFields["passwordField"].typeText("secret\r")
        XCTAssertTrue(tile("beach.jpg").waitForExistence(timeout: 15), "opened")
        app.terminate()

        launch(open: archive.path, resetState: false)
        XCTAssertTrue(tile("beach.jpg").waitForExistence(timeout: 15), "opens with the remembered password")
        XCTAssertFalse(app.secureTextFields["passwordField"].exists)
    }

    /// A video inside a ZIP streams from it, unpacked in memory as it
    /// plays: stored or packed, in AVKit and in VLC (the same file through
    /// both). Space pauses it, → skims through it.
    private func checkStreamedVideo(packed: Bool, vlc: Bool) throws {
        try put("clip.mp4", at: "src/clip.mp4")
        let src = tempDir.appendingPathComponent("src")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", packed ? "-9" : "-0", "../Videos.zip", "clip.mp4"]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        let archive = tempDir.appendingPathComponent("Videos.zip")
        launch(open: archive.path, extra: vlc ? ["--force-vlc"] : [])
        let clip = tile("clip.mp4")
        XCTAssertTrue(clip.waitForExistence(timeout: 15))
        clip.doubleClick()
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").waitForExistence(timeout: 20), "plays")
        waitForBadge(containing: "clip.mp4")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
        app.typeKey(.space, modifierFlags: [])
        eventually("plays on", timeout: 10) { !self.text(of: self.badge).contains("Paused") }
        app.typeKey(.rightArrow, modifierFlags: [])   // a jump ahead inside the stream
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").exists)
        let copies = FileManager.default.temporaryDirectory.appendingPathComponent("Schnellbild archive videos")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies.path), "nothing unpacked to disk")
    }

    func testAStoredVideoStreamsInAVKit() throws { try checkStreamedVideo(packed: false, vlc: false) }
    func testAStoredVideoStreamsInVLC() throws { try checkStreamedVideo(packed: false, vlc: true) }
    func testAPackedVideoStreamsInAVKit() throws { try checkStreamedVideo(packed: true, vlc: false) }
    func testAPackedVideoStreamsInVLC() throws { try checkStreamedVideo(packed: true, vlc: true) }

    /// A RAR made with RAR 7: photos with thumbnails, a picture in a folder,
    /// a packed video streamed, in AVKit and VLC.
    private func checkRarPhotosAndVideo(_ fixture: String, vlc: Bool) throws {
        try put(fixture, at: fixture)
        launch(open: tempDir.appendingPathComponent(fixture).path, extra: vlc ? ["--force-vlc"] : [])
        let beach = tile("beach.jpg")
        XCTAssertTrue(beach.waitForExistence(timeout: 15))
        eventually("a thumbnail from the RAR", timeout: 15) { self.text(of: beach).hasSuffix("preview") }
        tile("Day 1").doubleClick()
        let big = tile("big.jpg")
        XCTAssertTrue(big.waitForExistence(timeout: 15))
        big.doubleClick()
        eventually("the picture opens", timeout: 15) { self.text(of: self.element("fullImage")).hasSuffix("loaded") }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: .command)
        let clip = tile("clip.mp4")
        XCTAssertTrue(clip.waitForExistence(timeout: 15))
        clip.doubleClick()
        XCTAssertTrue(element(vlc ? "video.vlc" : "video.avkit").waitForExistence(timeout: 20), "the video plays")
        waitForBadge(containing: "clip.mp4")
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "Paused")
    }

    func testASolidRarInAVKit() throws { try checkRarPhotosAndVideo("photos-solid.rar", vlc: false) }
    func testAPackedRarInVLC() throws { try checkRarPhotosAndVideo("photos-rar5.rar", vlc: true) }

    func testARarWithEncryptedNamesAsksOnce() throws {
        try put("photos-hpsw.rar", at: "photos-hpsw.rar")
        launch(open: tempDir.appendingPathComponent("photos-hpsw.rar").path)
        let field = app.secureTextFields["passwordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "even the names need the password")
        field.typeText("secret\r")
        XCTAssertTrue(tile("beach.jpg").waitForExistence(timeout: 15))
    }

    /// The volumes of a RAR show as one tile and read as one archive.
    func testRarVolumesShowAsOne() throws {
        for part in 1...4 { try put("photos-vols.part\(part).rar", at: "photos-vols.part\(part).rar") }
        launchOnTempDir()
        let first = tile("photos-vols.part1.rar")
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertFalse(tile("photos-vols.part2.rar").exists, "later volumes aren't shown")
        first.doubleClick()
        tile("Day 1").doubleClick()
        XCTAssertTrue(tile("big.jpg").waitForExistence(timeout: 15), "a picture spread over the volumes")
        tile("big.jpg").doubleClick()
        eventually("opens", timeout: 15) { self.text(of: self.element("fullImage")).hasSuffix("loaded") }
    }

    /// A RAR download in progress shows the pictures that have arrived.
    func testAnUnfinishedRarDownload() throws {
        try put("photos-cut.rar.part", at: "photos-cut.rar.part")
        launch(open: tempDir.appendingPathComponent("photos-cut.rar.part").path)
        let beach = tile("beach.jpg")
        XCTAssertTrue(beach.waitForExistence(timeout: 15))
        beach.doubleClick()
        eventually("opens", timeout: 15) { self.text(of: self.element("fullImage")).hasSuffix("loaded") }
    }

    func testRarFolders() throws {
        try put("subdirs.rar", at: "subdirs.rar")
        launch(open: tempDir.appendingPathComponent("subdirs.rar").path)
        let sub = tile("sub")
        XCTAssertTrue(sub.waitForExistence(timeout: 15))
        sub.doubleClick()
        XCTAssertTrue(tile("dir1").waitForExistence(timeout: 15))
        XCTAssertTrue(tile("with space").exists)
        XCTAssertTrue(tile("üȵĩöḋè").exists, "Unicode names")
    }

    /// A download in progress: the pictures before the cut already show.
    func testAnUnfinishedDownloadShowsWhatIsThere() throws {
        try put("dark.jpg", at: "src/1.jpg")
        try put("bright.jpg", at: "src/2.jpg")
        try put("huge.jpg", at: "src/3.jpg")
        let whole = try Data(contentsOf: try zip("whole.zip", files: ["1.jpg", "2.jpg", "3.jpg"]))
        let cut = tempDir.appendingPathComponent("Photos.zip.crdownload")
        try Data(whole.prefix(whole.count / 2)).write(to: cut)
        launch(open: cut.path)
        XCTAssertTrue(tile("1.jpg").waitForExistence(timeout: 15), "the first picture is there")
        tile("1.jpg").doubleClick()
        eventually("and opens", timeout: 15) { self.text(of: self.element("fullImage")).hasSuffix("loaded") }
    }
}
