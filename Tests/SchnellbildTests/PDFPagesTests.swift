import XCTest
import PDFKit
@testable import Schnellbild

/// PDFs in the full view: their pages drawn as vector pictures (`PDFPages`),
/// ← → turning them as a video's seek does, the ends handing over to the
/// previous / next item, the keys going through the shortcut mapping
/// (also as in Phiewer), and a PDF as one item in the slideshow.
@MainActor
final class PDFPagesTests: XCTestCase {
    private func chord(_ stored: String) -> KeyChord { KeyChord(stored: stored)! }

    /// Three pages, one flat colour each: 1 red 300 × 400, 2 green
    /// 500 × 200 turned a quarter, 3 blue 300 × 400.
    private func makePDF(at url: URL) throws {
        var media = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        let pages: [(CGSize, CGColor)] = [
            (CGSize(width: 300, height: 400), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            (CGSize(width: 500, height: 200), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (CGSize(width: 300, height: 400), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
        ]
        for (size, colour) in pages {
            var box = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(colour)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        // Page 2 turned a quarter, as a landscape page in a scanned document
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.page(at: 1)?.rotation = 90
        XCTAssertTrue(document.write(to: url))
    }

    private func centre(_ image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = CGFloat(image.width / 2), y = CGFloat(image.height / 2)
        context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (bytes[0], bytes[1], bytes[2])
    }

    func testEachPageIsDrawnAtItsSizeAndTurnedAsTheFileSays() async throws {
        let tree = try TempTree(self)
        let url = tree.root.appendingPathComponent("doc.pdf")
        try makePDF(at: url)
        let opened = await PDFPages.open(url)
        let pages = try XCTUnwrap(opened)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.size(of: 0), CGSize(width: 300, height: 400))
        XCTAssertEqual(pages.size(of: 1), CGSize(width: 200, height: 500), "turned a quarter: standing")
        XCTAssertNil(pages.size(of: 3))

        let first = try XCTUnwrap(pages.render(page: 0, longestSide: 2000))
        XCTAssertEqual(first.0.height, 2000, "drawn at the size asked for, not at 72 dpi")
        XCTAssertEqual(first.0.width, 1500)
        XCTAssertEqual(first.1, CGSize(width: 300, height: 400))
        let red = centre(first.0)
        XCTAssertTrue(red.red > 200 && red.green < 60 && red.blue < 60, "page 1 is red: \(red)")

        let second = try XCTUnwrap(pages.render(page: 1, longestSide: 1000))
        XCTAssertEqual([second.0.width, second.0.height], [400, 1000], "page 2 stands")
        let green = centre(second.0)
        XCTAssertTrue(green.green > 200 && green.red < 60, "page 2 is green: \(green)")
        let blue = centre(try XCTUnwrap(pages.render(page: 2, longestSide: 400)).0)
        XCTAssertTrue(blue.blue > 200 && blue.red < 60, "page 3 is blue: \(blue)")
        XCTAssertNil(pages.render(page: 3, longestSide: 400), "no page 4")
        XCTAssertNil(pages.render(page: -1, longestSide: 400))

        // Tiles and the Inspector: the first page
        let size = await VectorPicture.size(of: url)
        XCTAssertEqual(size, CGSize(width: 300, height: 400))
        let tile = await VectorPicture.render(url, longestSide: 200)
        XCTAssertEqual(tile?.0.height, 200)
    }

    /// The tile, the full view and the Inspector opening one PDF share the
    /// document while one of them holds it: read once. A file rewritten
    /// is read again; one no longer held by anyone too.
    func testAPDFOpenAlreadyIsSharedWhileItIsHeld() async throws {
        let tree = try TempTree(self)
        let url = tree.root.appendingPathComponent("doc.pdf")
        try makePDF(at: url)
        let reads = Counter()
        let saved = MediaData.fileReader
        MediaData.fileReader = { url in reads.add(); return try MediaData.readFile(url) }
        defer { MediaData.fileReader = saved }
        var first = await PDFPages.open(url)
        let second = await PDFPages.open(url)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "the document open already")
        XCTAssertEqual(reads.value, 1)

        // Rewritten: another size and date
        try FileManager.default.removeItem(at: url)
        var media = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        weak var gone: PDFPages?
        do {
            let rewritten = await PDFPages.open(url)
            XCTAssertFalse(rewritten === first, "read again")
            XCTAssertEqual(rewritten?.count, 1)
            XCTAssertEqual(reads.value, 2)
            gone = rewritten
        }
        first = nil
        _ = first
        if gone == nil {
            _ = await PDFPages.open(url)
            XCTAssertEqual(reads.value, 3, "held by no one: read again")
        }
    }

    func testAFileThatIsNoPDFOpensAsNothing() async throws {
        let tree = try TempTree(self)
        let fake = tree.root.appendingPathComponent("fake.pdf")
        try Data("%PDF-1.7\nnot really\n".utf8).write(to: fake)
        let opened = await PDFPages.open(fake)
        XCTAssertNil(opened)
        let empty = try tree.file("empty.pdf")
        let none = await PDFPages.open(empty)
        XCTAssertNil(none)
        XCTAssertTrue(PDFPages.isPDF(URL(fileURLWithPath: "/x/Report.PDF")))
        XCTAssertFalse(PDFPages.isPDF(URL(fileURLWithPath: "/x/vector.svg")))
    }

    /// a.jpg, doc.pdf, z.jpg; the full view on doc.pdf, which the view
    /// reports open with three pages.
    private func openOnPDF(_ m: BrowserModel) async throws -> URL {
        let tree = try TempTree(self)
        for n in ["a.jpg", "doc.pdf", "z.jpg"] { try tree.file(n) }
        await openAndWait(m, tree.root)
        m.selectEntry(named: "doc.pdf")
        m.activateSelection()
        XCTAssertEqual(m.mode, .detail)
        let url = try XCTUnwrap(m.selectedEntry?.url)
        m.pdfOpened(url, pages: 3)
        return url
    }

    func testArrowsTurnThePagesThenMoveOnAsAtAVideosEnds() async throws {
        let m = makeModel()
        let url = try await openOnPDF(m)
        XCTAssertEqual(m.pdfPage(of: url), 0, "starts at its first page")
        m.zoomIn()
        m.rotateRight()
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.pdfPage(of: url), 1)
        XCTAssertEqual(m.zoom, 1, "each page starts at fit")
        XCTAssertEqual(m.rotation, 0, "and upright")
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.pdfPage(of: url), 2)
        m.handleKey(.right, command: false, repeating: true)
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf", "held down: stays on the last page")
        XCTAssertEqual(m.pdfPage(of: url), 2)
        m.handleKey(.left, command: false)
        XCTAssertEqual(m.pdfPage(of: url), 1, "back a page")
        m.handleKey(.right, command: false)
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg", "past the last page: the next item")
        XCTAssertNil(m.pdfPosition)

        m.handleKey(.left, command: true)
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf")
        XCTAssertEqual(m.pdfPage(of: url), 0, "back on the PDF: its first page")
        m.pdfOpened(url, pages: 3)
        m.handleKey(.left, command: false, repeating: true)
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf", "held down: stays on the first page")
        m.handleKey(.left, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "a.jpg", "before the first page: the previous item")
    }

    func testCommandArrowsLeaveAPDFStraightAway() async throws {
        let m = makeModel()
        let url = try await openOnPDF(m)
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.pdfPage(of: url), 1)
        m.handleKey(.right, command: true)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg")
        m.handleKey(.left, command: true)
        m.pdfOpened(url, pages: 3)
        m.handleKey(.left, command: true)
        XCTAssertEqual(m.selectedEntry?.name, "a.jpg")
    }

    /// The page shown stays when the view reports the same PDF again (a
    /// sharper drawing); ⇧← ⇧→ are a video's fine steps and leave a PDF as it is.
    func testThePageStaysWhileTheSamePDFIsShown() async throws {
        let m = makeModel()
        let url = try await openOnPDF(m)
        m.handleKey(.right, command: false)
        m.pdfOpened(url, pages: 3)
        XCTAssertEqual(m.pdfPage(of: url), 1)
        m.handleKey(.right, command: false, shift: true)
        m.handleKey(.left, command: false, shift: true)
        XCTAssertEqual(m.pdfPage(of: url), 1)
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf")
        XCTAssertEqual(m.pdfPage(of: URL(fileURLWithPath: "/elsewhere/other.pdf")), 0, "another PDF: its first page")
    }

    /// The last item: → on its last page stays there (no item to go to),
    /// as ← on the first page of the first item does.
    func testAtTheEndsOfTheFolderAPDFKeepsItsPage() async throws {
        let m = makeModel()
        let tree = try TempTree(self)
        for n in ["a.pdf", "b.jpg", "z.pdf"] { try tree.file(n) }
        await openAndWait(m, tree.root)
        m.selectEntry(named: "z.pdf")
        m.activateSelection()
        let last = try XCTUnwrap(m.selectedEntry?.url)
        m.pdfOpened(last, pages: 2)
        m.handleKey(.right, command: false)
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.pdf")
        XCTAssertEqual(m.pdfPage(of: last), 1, "stays on its last page")
        m.handleKey(.right, command: true)
        XCTAssertEqual(m.pdfPage(of: last), 1)

        m.selectEntry(named: "a.pdf")
        let first = try XCTUnwrap(m.selectedEntry?.url)
        m.pdfOpened(first, pages: 2)
        m.handleKey(.left, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "a.pdf")
        XCTAssertEqual(m.pdfPage(of: first), 0)
    }

    /// Not open yet (still read, or not readable): ← → go on as from a
    /// picture, but a key held down doesn't race past it.
    func testAPDFNotOpenYetIsLeftLikeAPicture() async throws {
        let m = makeModel()
        let tree = try TempTree(self)
        for n in ["a.jpg", "doc.pdf", "z.jpg"] { try tree.file(n) }
        await openAndWait(m, tree.root)
        m.selectEntry(named: "doc.pdf")
        m.activateSelection()
        m.handleKey(.right, command: false, repeating: true)
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf")
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg")
    }

    /// The keys go through the shortcut mapping like a video's seek: with
    /// Schnellbild's keys ← → turn pages and ⌘← ⌘→ change the item; as in
    /// Phiewer the other way round; a key the user gave the action turns
    /// pages too.
    func testTypedKeysTurnPagesThroughTheShortcutMapping() async throws {
        let defaults = makeTestDefaults()
        let spy = FileActionsSpy()
        let left = BrowserModel(defaults: defaults, fileActions: spy.actions)
        left.searchDebounce = .zero
        let w = WindowModel(left: left, defaults: defaults) {
            BrowserModel(defaults: defaults, fileActions: spy.actions, settingsPrefix: "rightPane.")
        }
        let s = Shortcuts(defaults: makeTestDefaults())
        w.shortcuts = s
        let m = w.left
        let url = try await openOnPDF(m)

        XCTAssertTrue(w.typeKey(.right))
        XCTAssertEqual(m.pdfPage(of: url), 1, "→ turns the page")
        XCTAssertTrue(w.typeKey(.left))
        XCTAssertEqual(m.pdfPage(of: url), 0)

        s.choose(.phiewer)
        XCTAssertTrue(w.typeKey(.right, command: true))
        XCTAssertEqual(m.pdfPage(of: url), 1, "as in Phiewer: ⌘→ turns the page")
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf")
        XCTAssertTrue(w.typeKey(.right))
        XCTAssertEqual(m.selectedEntry?.name, "z.jpg", "as in Phiewer: → is the next item")
        XCTAssertTrue(w.typeKey(.left))
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf")
        m.pdfOpened(url, pages: 3)

        s.choose(.schnellbild)
        s.assign(chord("j"), to: .fullNext)
        XCTAssertTrue(w.typeKey(.char("j")))
        XCTAssertEqual(m.pdfPage(of: url), 1, "a key of one's own turns the page")
        s.assign(chord("h"), to: .fullPrevious, replacing: chord("left"))
        XCTAssertTrue(w.typeKey(.char("h")))
        XCTAssertEqual(m.pdfPage(of: url), 0)
        XCTAssertFalse(w.typeKey(.left), "← no longer turns pages")
        XCTAssertEqual(m.pdfPage(of: url), 0)
        XCTAssertEqual(m.selectedEntry?.name, "doc.pdf")
    }

    /// In the slideshow a PDF is one item, shown at its first page: ← →
    /// change the item.
    func testInTheSlideshowAPDFIsOneItem() async throws {
        let tree = try TempTree(self)
        for n in ["a.jpg", "doc.pdf", "z.jpg"] { try tree.file(n) }
        let m = makeModel()
        m.slideshowInterval = .seconds(60)
        await openAndWait(m, tree.root)
        m.selectEntry(named: "doc.pdf")
        m.startSlideshow()
        await waitUntil { m.slideshow?.loading == false && m.shownMediaEntry != nil }
        XCTAssertEqual(m.shownMediaEntry?.name, "doc.pdf")
        let url = try XCTUnwrap(m.shownMediaEntry?.url)
        m.pdfOpened(url, pages: 3)
        m.handleKey(.right, command: false)
        XCTAssertEqual(m.shownMediaEntry?.name, "z.jpg", "→ is the next item")
        m.handleKey(.left, command: false)
        XCTAssertEqual(m.shownMediaEntry?.name, "doc.pdf")
        XCTAssertEqual(m.pdfPage(of: url), 0, "its first page")
        m.stopSlideshow()
    }

    /// The mini keyboard's row for a PDF names pages and items.
    func testTheMiniKeyboardHasARowForPDFs() {
        let keys = MiniKeyboard.keys(for: .pdf)
        XCTAssertEqual(keys.first?.action, .fullPrevious)
        XCTAssertTrue(keys.contains { $0.action == .fullNextItem })
        XCTAssertLessThanOrEqual(keys.count, 14, "fits the narrowest window")
    }
}
