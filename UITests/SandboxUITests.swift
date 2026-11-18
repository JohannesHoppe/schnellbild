import XCTest
import AppKit

/// The app in the App Sandbox as it ships: it reads only what the user
/// opened to it (the open panel, a drop), keeps that across launches as
/// security-scoped bookmarks, and asks for anything else.
final class SandboxUITests: SchnellbildUITestCase {
    /// The app under test runs in the App Sandbox: Settings has its
    /// "Folder access" section (only there), and a folder nobody opened to
    /// it asks instead of showing.
    func testTheAppUnderTestIsSandboxed() {
        launchOnTempDir()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Folders opened to Schnellbild"].waitForExistence(timeout: 10),
                      "Settings → Folder access: the app runs in the App Sandbox")
        app.terminate()
        launch(open: tempDir.path, grants: .nothing)
        XCTAssertTrue(element("allowAccess").firstMatch.waitForExistence(timeout: 15), "a folder outside every grant asks")
        XCTAssertFalse(tile("a.jpg").exists, "and shows nothing of it")
    }

    /// The Pictures folder is open to the app without asking (its
    /// entitlement): where the first launch starts.
    func testThePicturesFolderNeedsNoGrant() throws {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        let pictures = URL(fileURLWithPath: home).appendingPathComponent("Pictures/SchnellbildUITests/\(tempDir.lastPathComponent)")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: pictures) }
        let source = try XCTUnwrap(Bundle(for: SchnellbildUITestCase.self).url(forResource: "sample", withExtension: "jpg"))
        try FileManager.default.copyItem(at: source, to: pictures.appendingPathComponent("holiday.jpg"))
        launch(open: pictures.path, grants: .nothing)
        XCTAssertTrue(tile("holiday.jpg").waitForExistence(timeout: 15), "read without a grant")
        XCTAssertFalse(element("allowAccess").exists)
    }

    /// A folder chosen in the open panel shows, and comes back after a
    /// relaunch from its security-scoped bookmark alone (no panel, no
    /// `--open`); Settings → Forget Folder Access gives it up, and it asks.
    func testAFolderChosenInTheOpenPanelIsKeptAcrossLaunches() throws {
        try put("sample.jpg", at: "Trip/x.jpg")
        let trip = tempDir.appendingPathComponent("Trip")
        launch(grants: .nothing)
        XCTAssertTrue(app.staticTexts["No folder open"].waitForExistence(timeout: 15))
        grantThroughOpenPanel(trip)
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15), "the folder chosen")
        quitApp()

        launch(resetState: false)
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15), "opened again from its bookmark")
        XCTAssertFalse(element("allowAccess").exists)

        app.typeKey(",", modifierFlags: .command)
        let forget = app.buttons["Forget Folder Access…"].firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 10))
        eventually("one folder granted") { forget.isEnabled }
        forget.click()
        // The dialog's button (the Touch Bar has one of the same name)
        var confirm: XCUIElement?
        eventually("the dialog asks") {
            confirm = [self.app.sheets, self.app.dialogs].lazy
                .map { $0.buttons["Forget Folder Access"].firstMatch }.first { $0.exists }
            return confirm != nil
        }
        confirm?.click()
        eventually("nothing granted") { !forget.isEnabled }
        quitApp()

        launch(resetState: false)
        XCTAssertTrue(element("allowAccess").firstMatch.waitForExistence(timeout: 15), "the last folder asks again")
        XCTAssertFalse(tile("x.jpg").exists)
    }

    /// Above the folder opened to the app: the folder above asks; its
    /// Allow Access… opens the panel there, and once allowed it shows with
    /// the folder came from in it, also after a relaunch.
    func testGoingAboveAGrantedFolderAsksForIt() throws {
        try put("sample.jpg", at: "Trip/x.jpg")
        launch(grants: .nothing)
        grantThroughOpenPanel(tempDir.appendingPathComponent("Trip"))
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15))

        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Schnellbild needs your permission for this folder"].waitForExistence(timeout: 15))
        XCTAssertFalse(tile("a.jpg").exists)
        element("allowAccess").firstMatch.click()
        // The panel opens at the folder above; its button allows that one
        confirmOpenPanel()
        XCTAssertTrue(tile("Trip").waitForExistence(timeout: 15), "the folder above, with the one came from")
        XCTAssertTrue(tile("a.jpg").exists)
        quitApp()

        launch(resetState: false)
        XCTAssertTrue(tile("Trip").waitForExistence(timeout: 15), "kept")
    }

    /// A photo dropped from the Finder out of a folder nobody opened to the
    /// app: the sandbox opens only that file, so it alone is shown, at once
    /// in the full view, with "Allow Access…" there; its XMP sidecar (its
    /// name, another extension) is read all the same, as a related item.
    /// Allowed, the folder is read around it: the full view stays on it and
    /// → goes on to its neighbour.
    func testAPhotoDroppedAloneFromTheFinder() throws {
        try put("nogeo.jpg", at: "Outside/photo.jpg")
        try put("sample.jpg", at: "Outside/second.jpg")
        let sidecar = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/"
         exif:GPSLatitude="48,8.232N" exif:GPSLongitude="11,34.566E"/></rdf:RDF></x:xmpmeta>
        """
        try sidecar.write(to: tempDir.appendingPathComponent("Outside/photo.xmp"), atomically: true, encoding: .utf8)
        launch(grants: .nothing)
        XCTAssertTrue(app.staticTexts["No folder open"].waitForExistence(timeout: 15))
        dropFromFinder(tempDir.appendingPathComponent("Outside/photo.jpg"))
        waitForBadge(containing: "photo.jpg")
        XCTAssertTrue(text(of: badge).contains("1 / 1"), "only the file dropped: \(text(of: badge))")
        let allow = element("allowAccess").firstMatch
        let shown = allow.waitForExistence(timeout: 5)
        if !shown { print("no Allow Access… in the full view:\n\(app.debugDescription)") }
        XCTAssertTrue(shown, "the full view says how to see the folder")

        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(element("inspector").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["48.1372° N, 11.5761° E"].waitForExistence(timeout: 15), "the place from its sidecar")
        app.typeKey("i", modifierFlags: [])

        allow.click()
        confirmOpenPanel()
        eventually("the folder around it", timeout: 15) { self.text(of: self.badge).contains("1 / 2") }
        XCTAssertTrue(text(of: badge).contains("photo.jpg"), "still on the photo")
        XCTAssertFalse(element("allowAccess").exists)
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForBadge(containing: "second.jpg")
    }

    /// An archive split by bytes (`Trip.zip.001`, `.002`), its first part
    /// dropped alone: the second part has its name with another extension,
    /// so the sandbox opens it too (a related item), and the archive shows whole.
    func testAnArchiveDroppedAloneReadsItsOtherPart() throws {
        try put("dark.jpg", at: "src/beach.jpg")
        try put("bright.jpg", at: "src/sun.jpg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-0", "../Trip.zip", "beach.jpg", "sun.jpg"]
        process.currentDirectoryURL = tempDir.appendingPathComponent("src")
        try process.run()
        process.waitUntilExit()
        let whole = try Data(contentsOf: tempDir.appendingPathComponent("Trip.zip"))
        let outside = try folder("Parts")
        let half = whole.count / 2
        try whole.prefix(half).write(to: outside.appendingPathComponent("Trip.zip.001"))
        try whole.dropFirst(half).write(to: outside.appendingPathComponent("Trip.zip.002"))
        launch(grants: .nothing)
        XCTAssertTrue(app.staticTexts["No folder open"].waitForExistence(timeout: 15))
        dropFromFinder(outside.appendingPathComponent("Trip.zip.001"))
        XCTAssertTrue(tile("beach.jpg").waitForExistence(timeout: 15), "the archive opened")
        XCTAssertTrue(tile("sun.jpg").waitForExistence(timeout: 10), "the part after the first read too")
        XCTAssertFalse(element("allowAccess").exists, "nothing missing")
    }

    /// The folder the user opened to the app can't be renamed by itself
    /// (the sandbox would refuse: that changes the folder above): its name
    /// in the title bar asks for the folder above first, then renames.
    func testRenamingTheGrantedFolderAsksForTheFolderAbove() throws {
        try put("sample.jpg", at: "Trip/x.jpg")
        launch(grants: .nothing)
        grantThroughOpenPanel(tempDir.appendingPathComponent("Trip"))
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15))
        let title = element("folderTitle").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        confirmOpenPanel()
        let field = app.textFields["folderTitleField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "editable once the folder above is allowed")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Iceland\r")
        eventually("renamed on disk", timeout: 10) {
            FileManager.default.fileExists(atPath: self.tempDir.appendingPathComponent("Iceland/x.jpg").path)
        }
        XCTAssertTrue(tile("x.jpg").exists, "still in the folder, under its new name")
    }
}
