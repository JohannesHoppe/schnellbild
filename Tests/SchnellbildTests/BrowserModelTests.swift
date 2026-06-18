import XCTest
@testable import Schnellbild

// MARK: - GridEntry

final class GridEntryTests: XCTestCase {
    func testParentNameIsDotDot() {
        let e = GridEntry(url: URL(fileURLWithPath: "/some/dir"), kind: .parent)
        XCTAssertEqual(e.name, "..")
    }

    func testFileNameIsLastComponent() {
        let e = GridEntry(url: URL(fileURLWithPath: "/a/b/photo.jpg"), kind: .image)
        XCTAssertEqual(e.name, "photo.jpg")
    }

    func testIsMedia() {
        XCTAssertTrue(GridEntry(url: URL(fileURLWithPath: "/x.jpg"), kind: .image).isMedia)
        XCTAssertTrue(GridEntry(url: URL(fileURLWithPath: "/x.mp4"), kind: .video).isMedia)
        XCTAssertFalse(GridEntry(url: URL(fileURLWithPath: "/x"), kind: .folder).isMedia)
        XCTAssertFalse(GridEntry(url: URL(fileURLWithPath: "/x"), kind: .parent).isMedia)
    }

    func testIsGIFIsCaseInsensitive() {
        XCTAssertTrue(GridEntry(url: URL(fileURLWithPath: "/a/anim.GIF"), kind: .image).isGIF)
        XCTAssertFalse(GridEntry(url: URL(fileURLWithPath: "/a/anim.png"), kind: .image).isGIF)
    }
}

// MARK: - Sorting

final class SortEntriesTests: XCTestCase {
    private func entry(_ name: String, _ kind: GridEntry.Kind,
                       date: Date? = nil, size: Int? = nil) -> GridEntry {
        GridEntry(url: URL(fileURLWithPath: "/root/\(name)"), kind: kind, modDate: date, byteSize: size)
    }

    func testParentFirstThenFoldersThenMedia() {
        let input = [
            entry("b.jpg", .image),
            entry("zfolder", .folder),
            entry("a.mp4", .video),
            entry("dotdot", .parent),
            entry("afolder", .folder),
        ]
        let sorted = BrowserModel.sortEntries(input, key: .name, ascending: true)
        // Grouping: parent first, then folders, then media.
        XCTAssertEqual(sorted[0].kind, .parent)
        XCTAssertTrue(sorted[1...2].allSatisfy { $0.kind == .folder })
        XCTAssertTrue(sorted[3...4].allSatisfy { $0.isMedia })
        // Each group is sorted by name (media: "a.mp4" before "b.jpg").
        XCTAssertEqual(sorted[1].url.lastPathComponent, "afolder")
        XCTAssertEqual(sorted[2].url.lastPathComponent, "zfolder")
        XCTAssertEqual(sorted[3].url.lastPathComponent, "a.mp4")
        XCTAssertEqual(sorted[4].url.lastPathComponent, "b.jpg")
    }

    func testNameAscendingAndDescending() {
        let input = [entry("a.jpg", .image), entry("c.jpg", .image), entry("b.jpg", .image)]
        let asc = BrowserModel.sortEntries(input, key: .name, ascending: true).map { $0.url.lastPathComponent }
        let desc = BrowserModel.sortEntries(input, key: .name, ascending: false).map { $0.url.lastPathComponent }
        XCTAssertEqual(asc, ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(desc, ["c.jpg", "b.jpg", "a.jpg"])
    }

    func testNameSortIsNumericAware() {
        let input = [entry("img2.jpg", .image), entry("img10.jpg", .image), entry("img1.jpg", .image)]
        let asc = BrowserModel.sortEntries(input, key: .name, ascending: true).map { $0.url.lastPathComponent }
        XCTAssertEqual(asc, ["img1.jpg", "img2.jpg", "img10.jpg"])
    }

    func testSortByDateAndSize() {
        let d0 = Date(timeIntervalSince1970: 0)
        let d1 = Date(timeIntervalSince1970: 1000)
        let input = [
            entry("new.jpg", .image, date: d1, size: 10),
            entry("old.jpg", .image, date: d0, size: 99),
        ]
        let byDate = BrowserModel.sortEntries(input, key: .date, ascending: true).map { $0.url.lastPathComponent }
        XCTAssertEqual(byDate, ["old.jpg", "new.jpg"])
        let bySize = BrowserModel.sortEntries(input, key: .size, ascending: true).map { $0.url.lastPathComponent }
        XCTAssertEqual(bySize, ["new.jpg", "old.jpg"])
    }
}

// MARK: - Directory scan

final class ScanTests: XCTestCase {
    func testScanClassifiesIncludesHiddenExcludesNonMedia() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sb_scan_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("photo.jpg"))
        try Data().write(to: dir.appendingPathComponent("clip.mp4"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))      // ignored: not media
        try Data().write(to: dir.appendingPathComponent(".secret.png"))    // hidden, but media → included
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let entries = await BrowserModel.scan(dir)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.url.lastPathComponent, $0) })

        XCTAssertEqual(byName["photo.jpg"]?.kind, .image)
        XCTAssertEqual(byName["clip.mp4"]?.kind, .video)
        XCTAssertEqual(byName["sub"]?.kind, .folder)
        XCTAssertNotNil(byName[".secret.png"], "hidden media should be listed")
        XCTAssertNil(byName["notes.txt"], "non-media files should be excluded")
    }
}

// MARK: - Model behaviour (synchronous, MainActor)

@MainActor
final class BrowserModelTests: XCTestCase {
    func testZoomClampsBetweenFitAndMax() {
        let m = BrowserModel()
        XCTAssertEqual(m.zoom, 1.0, accuracy: 0.0001)
        m.zoomIn()
        XCTAssertEqual(m.zoom, 1.25, accuracy: 0.0001)
        for _ in 0..<50 { m.zoomIn() }
        XCTAssertLessThanOrEqual(m.zoom, 8.0)
        for _ in 0..<50 { m.zoomOut() }
        XCTAssertEqual(m.zoom, 1.0, accuracy: 0.0001)
    }

    func testThumbnailSizeClamps() {
        let m = BrowserModel()
        for _ in 0..<50 { m.growThumbnails() }
        XCTAssertLessThanOrEqual(m.thumbnailSide, 320)
        for _ in 0..<50 { m.shrinkThumbnails() }
        XCTAssertGreaterThanOrEqual(m.thumbnailSide, 80)
    }

    func testScaleIsModeAware() {
        let m = BrowserModel()
        m.mode = .detail
        let z = m.zoom
        m.scaleUp()
        XCTAssertGreaterThan(m.zoom, z, "in the full-size view, scaleUp zooms")

        m.mode = .grid
        let side = m.thumbnailSide
        m.scaleUp()
        XCTAssertGreaterThan(m.thumbnailSide, side, "in the grid, scaleUp grows tiles")
    }

    func testGoBackFromDetailReturnsToGrid() {
        let m = BrowserModel()
        m.mode = .detail
        m.goBack()
        XCTAssertEqual(m.mode, .grid)
    }

    func testRotationWraps() {
        let m = BrowserModel()
        XCTAssertEqual(m.rotation, 0, accuracy: 0.0001)
        m.rotateRight()
        XCTAssertEqual(m.rotation, 90, accuracy: 0.0001)
        m.rotateRight(); m.rotateRight(); m.rotateRight()   // full turn → 0
        XCTAssertEqual(m.rotation, 0, accuracy: 0.0001)
        m.rotateLeft()
        XCTAssertEqual(m.rotation, -90, accuracy: 0.0001)
    }

    func testCloseDetailResetsRotation() {
        let m = BrowserModel()
        m.mode = .detail
        m.rotateRight()
        m.closeDetail()
        XCTAssertEqual(m.rotation, 0, accuracy: 0.0001)
        XCTAssertEqual(m.mode, .grid)
    }
}

// MARK: - Model integration via open() (async, MainActor)

@MainActor
final class OpenFolderTests: XCTestCase {
    func testOpenPopulatesCountsSelectionAndNavigation() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sb_open_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for n in ["a.jpg", "b.jpg", "c.jpg"] {
            try Data().write(to: dir.appendingPathComponent(n))
        }

        let m = BrowserModel()
        m.open(folder: dir)
        try await waitUntil { !m.isLoading && !m.entries.isEmpty }

        // entries = ".." + "sub" + 3 images
        XCTAssertEqual(m.entries.first?.kind, .parent)
        XCTAssertEqual(m.folderCount, 1)
        XCTAssertEqual(m.imageCount, 3)
        XCTAssertEqual(m.videoCount, 0)
        XCTAssertEqual(m.mediaCount, 3)

        // default selection lands on the first non-parent entry (the folder)
        XCTAssertEqual(m.selectedEntry?.kind, .folder)

        // stepMedia clamps within the media range (can't run off the end)
        m.selection = m.entries.count - 1
        m.stepMedia(1)
        XCTAssertEqual(m.selection, m.entries.count - 1)
    }

    func testDroppingAFileOpensItInDetail() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sb_drop_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.jpg"))
        let file = dir.appendingPathComponent("b.jpg")
        try Data().write(to: file)

        let m = BrowserModel()
        m.openDropped([file])
        try await waitUntil { !m.isLoading && !m.entries.isEmpty }

        XCTAssertEqual(m.mode, .detail, "dropping a file should open the full-size view")
        XCTAssertEqual(m.selectedMediaEntry?.url.lastPathComponent, "b.jpg")
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
