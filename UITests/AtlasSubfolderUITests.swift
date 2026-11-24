import XCTest

/// The Atlas of a folder with the trip in subfolders by day (and an MKV
/// placed by its XMP sidecar): the subfolders on and off, the full view
/// going on into the next folder, the selection going back to the grid as
/// the folder holding it, and the MKV playing in the tour.
final class AtlasSubfolderUITests: SchnellbildUITestCase {
    private let days: [(String, String)] = [
        ("norway-01-bryggen.jpg", ""), ("norway-02-bryggen.jpg", ""), ("norway-03-harbour.jpg", ""), ("norway-04-floyen.jpg", ""),
        ("norway-05-flam.jpg", "Day 2/"), ("norway-06-flam.jpg", "Day 2/"), ("norway-07-stegastein.jpg", "Day 2/"),
        ("norway-08-geiranger.jpg", "Day 3/"), ("norway-09-geiranger.jpg", "Day 3/"), ("norway-10-geiranger.mov", "Day 3/"),
        ("norway-11-dalsnibba.jpg", "Day 3/"), ("norway-12-alesund.jpg", "Day 4/Evening/"),
        ("norway-13-evening.jpg", "Day 4/Evening/"), ("norway-14-trollstigen.jpg", "Day 5/"),
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try FileManager.default.removeItem(at: tempDir.appendingPathComponent(name)) }
        for (name, folder) in days { try put(name, at: folder + name) }
        // An MKV on the ferry, placed and timed by its sidecar (as Lightroom
        // writes one): `ramp.mkv`, grey growing brighter with time (luma 32 + 9 per second)
        try put("ramp.mkv", at: "Day 3/norway-ferry.mkv")
        let sidecar = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:DateTimeOriginal="2026-06-16T11:40:00+02:00"
         exif:GPSLatitude="62,6.066N" exif:GPSLongitude="7,12.372E"/></rdf:RDF></x:xmpmeta>
        """
        try sidecar.write(to: tempDir.appendingPathComponent("Day 3/norway-ferry.mkv.xmp"), atomically: true, encoding: .utf8)
    }

    private func count() -> String { text(of: element("atlasCount")) }

    private func openAtlas() {
        launchOnTempDir(waitFor: "Day 3")
        showAtlasFromTheGrid()
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
        eventually("every day's places", timeout: 30) { self.count().contains("14 on the map") }
    }

    func testTheSubfoldersAreOnTheMapUnlessTurnedOff() throws {
        openAtlas()
        let toggle = element("atlasSubfolders").firstMatch
        XCTAssertTrue(toggle.exists)
        toggle.click()
        eventually("only the folder's own", timeout: 15) { self.count().contains("4 on the map") }
        toggle.click()
        eventually("the subfolders again", timeout: 30) { self.count().contains("14 on the map") }
    }

    func testAnItemOfASubfolderSelectsItsFolderInTheGrid() throws {
        openAtlas()
        let evening = element("atlas.norway-13-evening.jpg").firstMatch
        XCTAssertTrue(evening.waitForExistence(timeout: 10), "in the strip: no place")
        evening.click()
        eventually("selected in the strip") { self.text(of: evening).hasPrefix("selected") }
        app.typeKey(.space, modifierFlags: [])
        waitForBadge(containing: "norway-13-evening.jpg")
        app.typeKey(.rightArrow, modifierFlags: .command)
        waitForBadge(containing: "norway-14-trollstigen.jpg")   // on into the next folder
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("l", modifierFlags: [])
        eventually("the grid again") { self.tile("Day 5").exists }
        waitForSelected("Day 5")
    }

    /// The MKV plays through VLC: its pictures reach VLC's output (the
    /// test log's probes of the first pictures, dark: the start of the
    /// ramp) and the screen (measured a second in, held by the pause: much
    /// darker than the frame at 30 % the thumbnail under it shows).
    func testAnMKVPlaysAtItsPlaceInTheTour() throws {
        let log = testLog("app.log")
        launch(open: tempDir.path, extra: ["--test-log=\(log.lastPathComponent)"])
        XCTAssertTrue(app.staticTexts["Day 3"].waitForExistence(timeout: 15))
        showAtlasFromTheGrid()
        XCTAssertTrue(element("atlas").waitForExistence(timeout: 10))
        eventually("every day's places", timeout: 30) { self.count().contains("14 on the map") }
        app.typeKey("t", modifierFlags: [])
        let status = element("tourStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        for _ in 0..<4 { app.typeKey(.rightArrow, modifierFlags: []) }
        eventually("Geiranger") { self.text(of: status).hasPrefix("station 5 of 8") }
        let item = element("tourItem")
        eventually("the ferry's MKV after the photos and the video", timeout: 40) { item.exists && item.label.hasPrefix("norway-ferry.mkv") }
        XCTAssertEqual(item.label, "norway-ferry.mkv, video vlc", "played through VLC, as in the full view")
        // Its pictures reach VLC's output
        eventually("VLC's first pictures", timeout: 10) {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("vlc picture 1 of media")
        }
        let probes = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("vlc picture") }
        print("VLC's pictures:\n" + probes.joined(separator: "\n"))
        let lumas = probes.compactMap { line in line.range(of: "luma ").flatMap { Int(line[$0.upperBound...].prefix { $0.isNumber }) } }
        XCTAssertFalse(lumas.isEmpty)
        XCTAssertTrue(lumas.allSatisfy { $0 < 60 }, "the ramp's start, not a later frame: \(lumas)")
        // And the screen: a second in, held
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.space, modifierFlags: [])
        eventually("paused") { self.text(of: status).hasSuffix("paused") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let f = item.frame
        if let shown = try? screenStats(of: CGRect(x: f.midX - f.width / 4, y: f.midY - f.height / 4, width: f.width / 2, height: f.height / 2)) {
            XCTAssertGreaterThan(shown.mean, 0.03, "a picture, not black")
            XCTAssertLessThan(shown.mean, 0.22, "VLC's picture of the first seconds, not the thumbnail at 30 % (about 0.32)")
        }
        app.typeKey(.escape, modifierFlags: [])
        eventually("the tour ended", timeout: 10) { !status.exists }
    }
}
