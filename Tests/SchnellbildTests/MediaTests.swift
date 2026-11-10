import XCTest
import CoreImage
import AppKit
@testable import Schnellbild

/// Pictures and videos: what auto enhance measures, the size VLC's pictures
/// are shown at, PDF pages, and a file's identity through a rename.
final class MediaTests: XCTestCase {
    /// A grey square on a transparent background measures as grey: the
    /// transparent pixels aren't counted as black.
    func testTransparentPixelsAreNotMeasured() throws {
        let side = 200
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        let picture = try XCTUnwrap(context.makeImage())
        let stats = try XCTUnwrap(PictureStats.of(CIImage(cgImage: picture)))
        XCTAssertGreaterThan(stats.mean, 0.4, "\(stats)")
        XCTAssertGreaterThan(stats.low, 0.4, "\(stats)")

        let empty = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)).makeImage()
        XCTAssertNil(PictureStats.of(CIImage(cgImage: try XCTUnwrap(empty))), "nothing drawn, nothing to measure")
    }

    /// VLC's padded decoder size gives way to the track's visible size;
    /// non-square pixels are made square; a turned video stays turned.
    func testVLCPicturesAreShownAtTheVisibleSizeWithSquarePixels() {
        typealias Track = VLCFrameOutput.Track
        func shown(_ track: Track?, _ w: Int, _ h: Int) -> [Int] {
            let s = VLCFrameOutput.shownSize(track: track, decoded: (w, h))
            return [s.width, s.height, s.visibleHeight]
        }
        XCTAssertEqual(shown(Track(width: 1920, height: 1080, sampleAspect: 1), 1920, 1152), [1920, 1080, 1080], "AV1 padding")
        XCTAssertEqual(shown(Track(width: 1920, height: 1080, sampleAspect: 1), 1920, 1088), [1920, 1080, 1080], "H.264 alignment")
        XCTAssertEqual(shown(Track(width: 720, height: 576, sampleAspect: 64.0 / 45), 720, 576), [1024, 576, 576], "PAL 16:9")
        XCTAssertEqual(shown(Track(width: 720, height: 480, sampleAspect: 8.0 / 9), 720, 480), [720, 540, 480], "NTSC 4:3")
        XCTAssertEqual(shown(Track(width: 1920, height: 1080, sampleAspect: 1), 1088, 1920), [1080, 1920, 1920], "turned upright")
        XCTAssertEqual(shown(nil, 640, 288), [640, 288, 288], "no track information: VLC's size")
        XCTAssertEqual(shown(Track(width: 4000, height: 3000, sampleAspect: 1), 640, 480), [640, 480, 480], "a track larger than decoded")
        XCTAssertEqual(shown(Track(width: 641, height: 271, sampleAspect: 1), 656, 272), [642, 272, 271], "even sides")
    }

    /// A PDF is drawn sharp at the size asked for and has its page's size.
    func testAPDFPageIsDrawnAtAnySize() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("page.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()

        XCTAssertTrue(VectorPicture.isVector(pdf))
        let size = await MediaInfo.pixelSize(ofAnywhere: pdf)
        XCTAssertEqual(size, CGSize(width: 612, height: 792))
        let rendered = await VectorPicture.render(pdf, longestSide: 2000)
        XCTAssertEqual(rendered?.0.height, 2000, "drawn at the size asked for, not at 72 dpi")
    }

    /// Renamed, a file keeps its identity (a playing video plays on).
    func testAFileKeepsItsIdentityThroughARename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.mp4"), b = folder.appendingPathComponent("b.mp4")
        try Data([1]).write(to: a)
        let before = try XCTUnwrap(FileIdentity(of: a))
        try FileManager.default.moveItem(at: a, to: b)
        XCTAssertEqual(FileIdentity(of: b), before)
        try Data([1]).write(to: a)
        XCTAssertNotEqual(FileIdentity(of: a), before, "another file under the old name")
        XCTAssertNil(FileIdentity(of: folder.appendingPathComponent("none.mp4")))
    }
}
