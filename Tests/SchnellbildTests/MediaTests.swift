import XCTest
import CoreImage
import AppKit
import ImageIO
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
    /// A paused AVKit video is drawn again with a new look by seeks into
    /// the frame shown, two points by turns. At its end it stands at its
    /// length, the end of its last frame (here 3.04 s with frames of 0.1 s,
    /// the last one from 3.0 s): both points lie in that frame and before
    /// the end, else the seek lands on the end again and draws nothing.
    /// A picture unpacked into memory beyond `OpenedPicture.largestHeld`
    /// isn't held on screen; a small one or a file on disk is. Its frames
    /// are known either way.
    func testALargePictureInMemoryIsNotHeld() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        let url = URL(fileURLWithPath: "/x/a.zip/a.png")
        let large = OpenedPicture(url: url, source: source, inMemory: OpenedPicture.largestHeld + 1)
        XCTAssertNil(large.source)
        XCTAssertEqual(large.frames, 1)
        XCTAssertNotNil(OpenedPicture(url: url, source: source, inMemory: 1_000).source)
        XCTAssertNotNil(OpenedPicture(url: url, source: source, inMemory: 0).source)
    }

    /// Only an animation's frames play: a GIF, an animated PNG, a HEIC
    /// sequence, each frame for the time it states; a TIFF's pages and an
    /// icon's sizes stay one picture.
    func testOnlyAnimationsPlay() throws {
        func source(_ data: Data?) throws -> CGImageSource {
            try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(data) as CFData, nil))
        }
        let apng = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.3]]
        let heics = [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: 0.5]]
        // (ImageIO writes a 4 × 2 GIF of two like frames as one)
        let gif = try source(FormatFixtures.written("com.compuserve.gif", frames: 2, picture: FormatFixtures.cgImage(width: 32, height: 20)))
        XCTAssertEqual(CGImageSourceGetCount(gif), 2)
        XCTAssertNotNil(AnimationFrames.of(gif, side: 16), "a GIF, also without times")
        let png = try XCTUnwrap(AnimationFrames.of(try source(FormatFixtures.written("public.png", frames: 2, properties: apng)), side: 16))
        XCTAssertEqual(png.delays[0], 0.3, accuracy: 0.001)
        if let data = FormatFixtures.written("public.heics", frames: 2, properties: heics) {
            let sequence = try XCTUnwrap(AnimationFrames.of(try source(data), side: 16), "a HEIC sequence")
            XCTAssertEqual(sequence.delays, [0.5, 0.5], "its own times, not the 0.1 s for none")
        }
        let tiff = try source(FormatFixtures.written("public.tiff", frames: 2))
        XCTAssertEqual(CGImageSourceGetCount(tiff), 2)
        XCTAssertNil(AnimationFrames.of(tiff, side: 16), "a TIFF's pages")
        if let data = FormatFixtures.written("com.microsoft.ico", frames: 2, square: true) {
            XCTAssertNil(AnimationFrames.of(try source(data), side: 16), "an icon's sizes")
        }
        XCTAssertNil(AnimationFrames.of(try source(FormatFixtures.written("public.png")), side: 16), "one picture")
    }

    func testARedrawAtTheEndSeeksIntoTheLastFrame() {
        for duration in [3.04, 3.1, 3.0, 3.0999] {
            var seen: Set<Double> = []
            for later in [false, true] {
                let target = AVPlaybackControl.redrawTime(at: duration, frame: 0.1, duration: duration, later: later)
                XCTAssertLessThan(target, duration, "\(duration), later \(later): before the end")
                XCTAssertGreaterThanOrEqual(target, (duration - 0.0011) - (duration - 0.0011).truncatingRemainder(dividingBy: 0.1) - 1e-9,
                                            "\(duration): in the last frame")
                seen.insert(target)
            }
            XCTAssertEqual(seen.count, 2, "\(duration): two points, by turns")
        }
        // In the middle: a quarter and a half into the frame shown
        XCTAssertEqual(AVPlaybackControl.redrawTime(at: 1.23, frame: 0.1, duration: 3.04, later: false), 1.225, accuracy: 1e-9)
        XCTAssertEqual(AVPlaybackControl.redrawTime(at: 1.23, frame: 0.1, duration: 3.04, later: true), 1.25, accuracy: 1e-9)
    }

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
