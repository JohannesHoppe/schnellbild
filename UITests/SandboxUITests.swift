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
        launch(open: tempDir.path, grants: .none)
        XCTAssertTrue(app.buttons["allowAccess"].firstMatch.waitForExistence(timeout: 15), "a folder outside every grant asks")
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
        launch(open: pictures.path, grants: .none)
        XCTAssertTrue(tile("holiday.jpg").waitForExistence(timeout: 15), "read without a grant")
        XCTAssertFalse(app.buttons["allowAccess"].exists)
    }

    /// A folder chosen in the open panel shows, and comes back after a
    /// relaunch from its security-scoped bookmark alone (no panel, no
    /// `--open`); Settings → Forget Folder Access gives it up, and it asks.
    func testAFolderChosenInTheOpenPanelIsKeptAcrossLaunches() throws {
        try put("sample.jpg", at: "Trip/x.jpg")
        let trip = tempDir.appendingPathComponent("Trip")
        launch(grants: .none)
        XCTAssertTrue(app.staticTexts["No folder open"].waitForExistence(timeout: 15))
        grantThroughOpenPanel(trip)
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15), "the folder chosen")
        app.terminate()

        launch(resetState: false)
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15), "opened again from its bookmark")
        XCTAssertFalse(app.buttons["allowAccess"].exists)

        app.typeKey(",", modifierFlags: .command)
        let forget = app.buttons["Forget Folder Access…"].firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 10))
        eventually("one folder granted") { forget.isEnabled }
        forget.click()
        let confirm = app.buttons["Forget Folder Access"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        eventually("nothing granted") { !forget.isEnabled }
        app.terminate()

        launch(resetState: false)
        XCTAssertTrue(app.buttons["allowAccess"].firstMatch.waitForExistence(timeout: 15), "the last folder asks again")
        XCTAssertFalse(tile("x.jpg").exists)
    }

    /// Above the folder opened to the app: the folder above asks; its
    /// Allow Access… opens the panel there, and once allowed it shows with
    /// the folder came from in it, also after a relaunch.
    func testGoingAboveAGrantedFolderAsksForIt() throws {
        try put("sample.jpg", at: "Trip/x.jpg")
        launch(grants: .none)
        grantThroughOpenPanel(tempDir.appendingPathComponent("Trip"))
        XCTAssertTrue(tile("x.jpg").waitForExistence(timeout: 15))

        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Schnellbild needs your permission for this folder"].waitForExistence(timeout: 15))
        XCTAssertFalse(tile("a.jpg").exists)
        app.buttons["allowAccess"].firstMatch.click()
        // The panel opens at the folder above; its button allows that one
        confirmOpenPanel()
        XCTAssertTrue(tile("Trip").waitForExistence(timeout: 15), "the folder above, with the one came from")
        XCTAssertTrue(tile("a.jpg").exists)
        app.terminate()

        launch(resetState: false)
        XCTAssertTrue(tile("Trip").waitForExistence(timeout: 15), "kept")
    }

    /// The folder the user opened to the app can't be renamed by itself
    /// (the sandbox would refuse: that changes the folder above): its name
    /// in the title bar asks for the folder above first, then renames.
    func testRenamingTheGrantedFolderAsksForTheFolderAbove() throws {
        try put("sample.jpg", at: "Trip/x.jpg")
        launch(grants: .none)
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
