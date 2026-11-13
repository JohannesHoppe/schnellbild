import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import Schnellbild

/// The inspector's facts: the format a file's content shows, an extension
/// that names another one, and the codecs.
final class FileFactsTests: XCTestCase {
    private func clip(_ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "clip", withExtension: ext, subdirectory: "Videos"), "missing clip.\(ext)")
    }

    private func head(_ ext: String) throws -> Data {
        try XCTUnwrap(try FileHandle(forReadingFrom: try clip(ext)).read(upToCount: 512))
    }

    private func named(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testAVideoUnderItsOwnExtensionIsFine() throws {
        for ext in ["mkv", "webm", "mp4", "mov", "m4v", "avi", "ts", "m2ts", "mts", "mpg", "vob", "wmv", "flv", "ogv"] {
            let facts = FileFacts.video(head: try head(ext), named: named("a.\(ext)"))
            XCTAssertNotNil(facts.format, ext)
            XCTAssertNil(facts.recommendedExtension, "\(ext): \(facts)")
        }
    }

    func testAVideoUnderAnotherFormatsExtensionGetsItsOwn() throws {
        XCTAssertEqual(FileFacts.video(head: try head("ts"), named: named("a.mkv")).recommendedExtension, "ts")
        XCTAssertEqual(FileFacts.video(head: try head("m2ts"), named: named("a.mkv")).recommendedExtension, "m2ts")
        XCTAssertEqual(FileFacts.video(head: try head("avi"), named: named("a.mp4")).recommendedExtension, "avi")
        XCTAssertEqual(FileFacts.video(head: try head("mkv"), named: named("a.avi")).recommendedExtension, "mkv")
        XCTAssertEqual(FileFacts.video(head: try head("mov"), named: named("a.wmv")).recommendedExtension, "mov")
        XCTAssertEqual(FileFacts.video(head: try head("mp4"), named: named("a.flv")).recommendedExtension, "mp4")
        XCTAssertEqual(FileFacts.video(head: try head("ts"), named: named("a.mkv")).format, "MPEG-TS")
    }

    /// What the first bytes don't show (an MPEG video stream, DV, text)
    /// gets no verdict.
    func testUnknownContentGetsNoVerdict() throws {
        XCTAssertEqual(FileFacts.video(head: try head("m2v"), named: named("a.mkv")), FileFacts())
        XCTAssertEqual(FileFacts.video(head: Data("#EXTM3U\n".utf8), named: named("a.mkv")), FileFacts())
        XCTAssertEqual(FileFacts.video(head: nil, named: named("a.mkv")), FileFacts())
    }

    private func picture(_ type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func facts(_ data: Data, named name: String) throws -> FileFacts {
        FileFacts.picture(try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), named: named(name))
    }

    func testAPictureUnderAnotherFormatsExtensionGetsItsOwn() throws {
        let jpeg = try picture(.jpeg), png = try picture(.png)
        for name in ["a.jpg", "a.jpeg", "a.JPG", "a.jpe"] {
            XCTAssertNil(try facts(jpeg, named: name).recommendedExtension, name)
        }
        XCTAssertNil(try facts(png, named: "a.png").recommendedExtension)
        XCTAssertEqual(try facts(jpeg, named: "a.png").recommendedExtension, UTType.jpeg.preferredFilenameExtension)
        XCTAssertEqual(try facts(png, named: "a.jpg").recommendedExtension, "png")
        XCTAssertEqual(try facts(png, named: "a.png").depth, 8)
        XCTAssertNotNil(try facts(png, named: "a.png").format)
    }

    /// Extensions that stand for the same format as the content's type.
    func testRelatedExtensionsFit() {
        XCTAssertNil(FileFacts.recommendedExtension(for: "tif", content: .tiff))
        XCTAssertNil(FileFacts.recommendedExtension(for: "mpo", content: .jpeg))
        XCTAssertNil(FileFacts.recommendedExtension(for: "hif", content: .heic))
        XCTAssertNil(FileFacts.recommendedExtension(for: "heif", content: .heic))
    }

    func testTheCodecsOfAVideo() async throws {
        let facts = await StreamFacts.of(AVURLAsset(url: try clip("mp4")))
        XCTAssertEqual(facts.video?.hasPrefix("H.264"), true, "\(facts)")
        XCTAssertGreaterThan(facts.seconds ?? 0, 0)
        XCTAssertEqual(StreamFacts.codecName(0x6176_6331), "H.264")   // avc1
        XCTAssertEqual(StreamFacts.codecName(0x6161_6320), "AAC")     // "aac "
        XCTAssertEqual(StreamFacts.describeBitrate(4_240_000), "4.2 Mbit/s".replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? "."))
        XCTAssertEqual(StreamFacts.describeBitrate(320_000), "320 kbit/s")
        // Units through the tables and the locale's measurement format
        XCTAssertEqual(StreamFacts.describeVideo(codec: "H.264", frameRate: 25), "H.264, 25 fps")
        let audio = StreamFacts.describeAudio(codec: "AAC", channels: 2, sampleRate: 48_000)
        XCTAssertTrue(audio.hasPrefix("AAC, 2 channels, 48"), audio)
        XCTAssertTrue(audio.contains("Hz"), audio)
        XCTAssertEqual(StreamFacts.describeDepth(16), "16 bits")
        XCTAssertEqual(StreamFacts.bitrate(bytes: 1_000_000, seconds: 8), 1_000_000)
        XCTAssertNil(StreamFacts.bitrate(bytes: 1_000_000, seconds: nil))
        XCTAssertEqual(InspectorView.duration(185), "3:05")
        XCTAssertEqual(InspectorView.duration(3727), "1:02:07")
    }
}
