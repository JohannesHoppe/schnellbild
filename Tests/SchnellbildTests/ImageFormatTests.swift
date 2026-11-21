import XCTest
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Schnellbild

/// Every picture format the app lists is a picture to it and is drawn:
/// ImageIO's formats from a file made in the test (`FormatFixtures`),
/// Illustrator files as PDFs or by their preview, PostScript by the
/// preview it carries, ZIP documents by the picture inside, Netpbm bitmaps.
final class ImageFormatTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ data: Data?) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(data, "no fixture for \(name)").write(to: url)
        return url
    }

    /// The picture the app decodes for the file (as the full view and the
    /// tiles do), its size, and the colour of its top left pixel.
    private func decoded(_ url: URL) async throws -> CGImage {
        let picture = await MediaData.picture(url)
        let source = try XCTUnwrap(picture?.source, "no image source for \(url.lastPathComponent)")
        return try XCTUnwrap(MediaInfo.scaledDown(source, at: 0, maxPixel: 64, now: true), "\(url.lastPathComponent) not decoded")
    }

    private func opened(_ url: URL) async throws -> PDFPages {
        let pages = await PDFPages.open(url)
        return try XCTUnwrap(pages, "\(url.lastPathComponent) not opened")
    }

    /// The red, green and blue of a pixel (0 … 255).
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        // Rows of the context's memory run from the top
        let at = (y * image.width + x) * 4
        return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2])]
    }

    // MARK: ImageIO's formats

    /// The formats ImageIO reads that a test can make, under each of their
    /// extensions: a picture to the app, decoded at its size, left red
    /// (where the format keeps colour).
    func testEveryFormatImageIOReadsIsShown() async throws {
        for (ext, data) in FormatFixtures.all() {
            guard let data else { print("formats: no fixture for .\(ext) on this macOS"); continue }
            let url = try file("picture.\(ext)", data)
            if BrowserModel.systemImageExtensions.contains(ext), !BrowserModel.imageExtensions.contains(ext) {
                // This macOS doesn't read it (DICOM on macOS 15): another file
                print("formats: .\(ext) not read by this macOS")
                XCTAssertNil(BrowserModel.mediaKind(of: url), ext)
                continue
            }
            XCTAssertTrue(BrowserModel.imageExtensions.contains(ext), ".\(ext) isn't listed")
            XCTAssertEqual(BrowserModel.mediaKind(of: url), .image, ext)
            let image = try await decoded(url)
            XCTAssertGreaterThan(image.width, 0, ext)
        }
    }

    /// Formats no test can make (camera RAW, AVC in HEIF, AVIF sequences,
    /// a JPEG 2000 code stream) are listed only where ImageIO names a type
    /// it reads for their extension.
    func testTheFormatsWithoutAFixtureAreImageIOs() {
        let readable = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap(UTType.init)
        for ext in ["avci", "j2c", "nefx", "axr", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "srw"] {
            guard BrowserModel.imageExtensions.contains(ext) else { XCTFail(".\(ext) isn't listed"); continue }
            let type = UTType(filenameExtension: ext)
            XCTAssertTrue(readable.contains { type?.conforms(to: $0) == true }, ".\(ext): no ImageIO type reads \(type?.identifier ?? "-")")
        }
    }

    /// A PSB (Photoshop's large document format) is no other format to the
    /// Inspector, nor are APNG, PNM or a JPEG 2000 under its other names.
    func testOtherNamesOfAFormatGetNoOtherExtension() throws {
        for (ext, data) in [("psb", FormatFixtures.photoshop(large: true)), ("pnm", FormatFixtures.netpbm("P6")),
                            ("apng", FormatFixtures.written(UTType.png.identifier)),
                            ("jpf", FormatFixtures.written("public.jpeg-2000"))] {
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
            let facts = FileFacts.picture(source, named: dir.appendingPathComponent("a.\(ext)"))
            XCTAssertNil(facts.recommendedExtension, ext)
        }
    }

    // MARK: SVG compressed

    /// An SVG compressed with gzip (".svgz") is drawn like an SVG.
    func testACompressedSVGIsDrawn() async throws {
        let svg = dir.appendingPathComponent("drawing.svg")
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="#ff0000"/></svg>
        """.utf8).write(to: svg)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-S", "z", svg.path]   // drawing.svg → drawing.svgz
        try gzip.run(); gzip.waitUntilExit()
        XCTAssertEqual(gzip.terminationStatus, 0)
        let url = dir.appendingPathComponent("drawing.svgz")
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        XCTAssertTrue(VectorPicture.isVector(url))
        let size = await VectorPicture.size(of: url)
        XCTAssertEqual(size, CGSize(width: 40, height: 20))
        let drawn = await VectorPicture.render(url, longestSide: 40)
        XCTAssertEqual(pixel(try XCTUnwrap(drawn).0, x: 2, y: 2), [255, 0, 0])
    }

    // MARK: Netpbm bitmaps

    /// ImageIO reads Netpbm's text bitmap (P1) but not its binary one (P4):
    /// that is shown through a grey picture (P5) of its bits, 1 black.
    func testABinaryNetpbmBitmapIsShown() async throws {
        let url = try file("bits.pbm", FormatFixtures.netpbm("P4"))
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        let image = try await decoded(url)
        XCTAssertEqual([image.width, image.height], [FormatFixtures.width, FormatFixtures.height])
        XCTAssertEqual(pixel(image, x: 0, y: 0), [0, 0, 0], "1 is black")
        XCTAssertEqual(pixel(image, x: 3, y: 1), [255, 255, 255], "0 is white")
        XCTAssertNil(EmbeddedPreview.netpbmBitmap(Data("P4\n4 2\n".utf8)), "its bits missing")
        XCTAssertNil(EmbeddedPreview.netpbmBitmap(Data("P4\n99999999 99999999\n\0".utf8)), "too large")
        XCTAssertNil(EmbeddedPreview.netpbmBitmap(FormatFixtures.netpbm("P6")), "not a bitmap")
    }

    // MARK: Illustrator

    /// Saved with PDF content (the default), an Illustrator file is a PDF:
    /// shown page by page, not as a preview, and the Inspector doesn't call
    /// it "really a PDF".
    func testAnIllustratorFileWithPDFContentIsAPDF() async throws {
        let url = try file("logo.ai", FormatFixtures.illustratorWithPDF())
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        XCTAssertTrue(PDFPages.isPDF(url))
        XCTAssertTrue(VectorPicture.isVector(url))
        XCTAssertEqual(BrowserModel.shownExtension(of: url), "ai", "sorted by kind as Illustrator files")
        let pages = try await opened(url)
        XCTAssertFalse(pages.isPreview)
        XCTAssertEqual(pages.size(of: 0), CGSize(width: 200, height: 100))
        let drawn = await VectorPicture.render(url, longestSide: 64)
        let rendered = try XCTUnwrap(drawn)
        XCTAssertEqual(pixel(rendered.0, x: 2, y: 2), [255, 0, 0])
    }

    /// Saved without PDF content, the PDF inside holds only Illustrator's
    /// placeholder page: the XMP thumbnail is shown instead, as a preview.
    func testAnIllustratorFileWithoutPDFContentShowsItsThumbnail() async throws {
        let url = try file("old.ai", FormatFixtures.illustratorWithoutPDF())
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        let pages = try await opened(url)
        XCTAssertTrue(pages.isPreview)
        XCTAssertEqual(pages.count, 1)
        let rendered = try XCTUnwrap(pages.render(page: 0, longestSide: 64))
        XCTAssertGreaterThan(pixel(rendered.0, x: 2, y: 2)[0], 200, "the thumbnail's red half")
        XCTAssertLessThan(pixel(rendered.0, x: 2, y: 2)[2], 60)
        // Without a thumbnail the placeholder page is what there is
        let bare = try file("bare.ai", FormatFixtures.pdf(text: FormatFixtures.placeholderText))
        let placeholder = try await opened(bare)
        XCTAssertFalse(placeholder.isPreview)
    }

    /// An Illustrator file that is neither a PDF nor carries a preview (a
    /// PostScript one of version 8 or older without one, anything else
    /// named ".ai") is another file, never run as PostScript.
    func testAnIllustratorFileWithNothingToShowIsAnOtherFile() throws {
        XCTAssertNil(BrowserModel.mediaKind(of: try file("ps.ai", FormatFixtures.postScript)))
        XCTAssertNil(BrowserModel.mediaKind(of: try file("text.ai", Data("hello".utf8))))
    }

    // MARK: PostScript

    /// A DOS EPS's TIFF preview is shown; the Inspector names the file's
    /// format with "embedded preview", and recommends no other extension.
    func testADOSEPSShowsItsTIFF() async throws {
        let url = try file("figure.eps", FormatFixtures.dosEPS())
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        let image = try await decoded(url)
        XCTAssertEqual([image.width, image.height], [FormatFixtures.width, FormatFixtures.height])
        XCTAssertEqual(pixel(image, x: 0, y: 0), [255, 0, 0])
        let found = await MediaData.imageSource(url)
        let facts = FileFacts.picture(try XCTUnwrap(found), named: url)
        XCTAssertNil(facts.recommendedExtension)
        XCTAssertEqual(facts.format, FileFacts.previewFormat(of: url))
        XCTAssertTrue(FileFacts.previewFormat(of: url).hasSuffix("embedded preview"), FileFacts.previewFormat(of: url))
    }

    /// An EPSI preview (hexadecimal in comments, 0 white): left black, right white.
    func testAnEPSIPreviewIsShown() async throws {
        let url = try file("figure.epsi", FormatFixtures.epsi())
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        let image = try await decoded(url)
        XCTAssertEqual([image.width, image.height], [FormatFixtures.width, FormatFixtures.height])
        XCTAssertEqual(pixel(image, x: 0, y: 0), [0, 0, 0])
        XCTAssertEqual(pixel(image, x: 3, y: 1), [255, 255, 255])
    }

    /// Illustrator's EPS carries an XMP thumbnail (in colour), shown before an EPSI preview.
    func testAnEPSWithAnXMPThumbnailShowsIt() async throws {
        let url = try file("logo.eps", FormatFixtures.epsWithXMP())
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        let image = try await decoded(url)
        XCTAssertGreaterThan(pixel(image, x: 0, y: 0)[0], 200)
    }

    /// PostScript without a preview is another file: nothing in macOS 14
    /// and later draws PostScript, and the app runs no PostScript.
    func testPostScriptWithoutAPreviewIsAnOtherFile() throws {
        XCTAssertNil(BrowserModel.mediaKind(of: try file("plain.eps", FormatFixtures.postScript)))
        XCTAssertNil(BrowserModel.mediaKind(of: try file("print.ps", FormatFixtures.postScript)))
        // A DOS EPS with a WMF preview only (nothing in macOS draws WMF)
        var wmfOnly = [UInt8](try XCTUnwrap(FormatFixtures.dosEPS()))
        for i in 12..<20 { wmfOnly[i] = wmfOnly[i + 8] }   // the TIFF's place given to the WMF
        for i in 20..<28 { wmfOnly[i] = 0 }
        XCTAssertNil(BrowserModel.mediaKind(of: try file("wmf.eps", Data(wmfOnly))))
    }

    /// Damaged headers and previews read as nothing, never past the data.
    func testDamagedPreviewsReadAsNothing() {
        var header = [UInt8](repeating: 0, count: 30)
        header[0...3] = [0xC5, 0xD0, 0xD3, 0xC6]
        header[20...23] = [30, 0, 0, 0]
        header[24...27] = [0xFF, 0xFF, 0xFF, 0x7F]   // longer than the file
        XCTAssertNil(EmbeddedPreview.dosTIFF(in: Data(header)))
        XCTAssertNil(EmbeddedPreview.epsiPreview(in: Data("%%BeginPreview: 4 2 1 2\n%C0\n%%EndPreview\n".utf8)), "a row short")
        XCTAssertNil(EmbeddedPreview.epsiPreview(in: Data("%%BeginPreview: 100000 100000 8 1\n%00\n".utf8)), "too large")
        XCTAssertNil(EmbeddedPreview.epsiPreview(in: Data("%%BeginPreview: 4 2 3 2\n%C0\n%C0\n".utf8)), "no such depth")
        XCTAssertNil(EmbeddedPreview.xmpThumbnail(in: Data("<xmpGImg:image>bm90IGEgcGljdHVyZQ==</xmpGImg:image>".utf8)),
                     "base64 of no picture")
        XCTAssertNil(EmbeddedPreview.xmpThumbnail(in: Data("<xmpGImg:image>".utf8)), "never closed")
    }

    /// Inside an archive the name decides (no first bytes without
    /// unpacking): EPS and Illustrator files are pictures, PostScript
    /// print jobs and the ZIP documents are not.
    func testInsideArchivesTheNameDecides() throws {
        let zip = dir.appendingPathComponent("a.zip")
        func kind(_ name: String) -> GridEntry.Kind? { BrowserModel.mediaKind(of: zip.appendingPathComponent(name)) }
        XCTAssertEqual(kind("logo.ai"), .image)
        XCTAssertEqual(kind("figure.eps"), .image)
        XCTAssertNil(kind("print.ps"))
        XCTAssertNil(kind("drawing.kra"))
    }

    // MARK: ZIP documents

    /// Krita, OpenRaster, Procreate and Sketch files: the picture inside is shown.
    func testZIPDocumentsShowThePictureInside() async throws {
        let png = try XCTUnwrap(FormatFixtures.written(UTType.png.identifier))
        for (ext, entries) in EmbeddedPreview.zipEntries.sorted(by: { $0.key < $1.key }) {
            let source = dir.appendingPathComponent("src-\(ext)")
            // The last entry only (Krita's preview without its merged image …)
            let entry = try XCTUnwrap(entries.last)
            let inside = source.appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: inside)
            try Data("<doc/>".utf8).write(to: source.appendingPathComponent("maindoc.xml"))
            let url = dir.appendingPathComponent("drawing.\(ext)")
            let zipping = Process()
            zipping.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zipping.arguments = ["-q", "-r", url.path, "."]
            zipping.currentDirectoryURL = source
            try zipping.run(); zipping.waitUntilExit()
            XCTAssertEqual(zipping.terminationStatus, 0)
            XCTAssertEqual(BrowserModel.mediaKind(of: url), .image, ext)
            XCTAssertFalse(ContentSniffer.isUnknown(url.lastPathComponent), "not read as an archive: \(ext)")
            let image = try await decoded(url)
            XCTAssertEqual(pixel(image, x: 0, y: 0), [255, 0, 0], ext)
            let found = await MediaData.imageSource(url)
            let facts = FileFacts.picture(try XCTUnwrap(found), named: url)
            XCTAssertNil(facts.recommendedExtension, ext)
        }
        // Not a ZIP under such a name: another file
        XCTAssertNil(BrowserModel.mediaKind(of: try file("fake.kra", Data("not a zip".utf8))))
    }
}
