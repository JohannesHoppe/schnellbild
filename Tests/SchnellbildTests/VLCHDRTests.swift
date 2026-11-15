import XCTest
import CoreVideo
import VLCKit
import VLCFrames
@testable import Schnellbild

/// HDR through VLC: the pictures `VLCFrameOutput` hands to its layer are
/// P010 tagged PQ or HLG with BT.2020's primaries and matrix (and HDR10's
/// mastering display and light level when VLC knows them), the layer asks
/// for EDR; SDR stays as it is (8-bit NV12, BT.709). The clips are drawn by
/// `Scripts/make_video_fixtures.sh hdr`. What the screen shows is
/// `VisualUITests`' part.
@MainActor
final class VLCHDRTests: XCTestCase {
    /// The player box handed to another thread to stop (VLC waits there
    /// for its own threads).
    private final class Held: @unchecked Sendable {
        let player = VLCMediaPlayer()
    }

    /// Plays a clip through a `VLCFrameOutput` until a picture satisfies
    /// `done` (or 15 s pass); returns the last picture and what the output
    /// says of its layer.
    private func play(_ name: String, extension ext: String = "mkv", options: [String] = [],
                      until done: @escaping (CVPixelBuffer) -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> (picture: CVPixelBuffer, edr: Bool) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Videos"),
                                "missing \(name).\(ext)", file: file, line: line)
        let media = VLCMedia(url: url)
        VLCSafety.restrict(media, for: url, head: VLCSafety.head(of: url))
        for option in [":no-audio", ":no-osd", ":no-play-and-pause", ":input-repeat=10"] + options { media.addOption(option) }
        let held = Held()
        held.player.media = media
        let output = VLCFrameOutput()
        output.attach(to: held.player)
        held.player.play()
        var last: CVPixelBuffer?
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(50))
            last = output.latestPicture
            if let last, done(last) { break }
        }
        // EDR is switched on the main thread after the colours are known
        try await Task.sleep(for: .milliseconds(200))
        let edr = output.showsEDR
        await Task.detached { held.player.stop() }.value
        let picture = try XCTUnwrap(last, "no picture from \(name).\(ext)", file: file, line: line)
        print("\(name).\(ext) \(options): \(VLCFrameOutput.describe(picture)), EDR \(edr)")
        return (picture, edr)
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    private func assertHDR(_ name: String, transfer: CFString, options: [String] = [],
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let (picture, edr) = try await play(name, options: options, until: { VLCFrameOutput.isHDR($0) }, file: file, line: line)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                       "10-bit pictures: \(VLCFrameOutput.describe(picture))", file: file, line: line)
        XCTAssertEqual(attachment(picture, kCVImageBufferTransferFunctionKey), transfer as String, file: file, line: line)
        XCTAssertEqual(attachment(picture, kCVImageBufferColorPrimariesKey), kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                       file: file, line: line)
        XCTAssertEqual(attachment(picture, kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
                       file: file, line: line)
        XCTAssertTrue(edr, "the layer shows EDR", file: file, line: line)
    }

    /// The Matroska Colour element states PQ: VLC knows it when its output opens.
    func testHDR10FromTheContainer() async throws {
        try await assertHDR("hdr10", transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
    }

    /// Only the HEVC stream states PQ: VLC learns it from the decoder a few
    /// pictures in.
    func testHDR10FromTheStreamOnly() async throws {
        try await assertHDR("hdr10-vui", transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
    }

    /// Decoded by FFmpeg, as while subtitles are shown (`decodeInSoftware`).
    func testHDR10DecodedInSoftware() async throws {
        try await assertHDR("hdr10", transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, options: [":codec=avcodec,all"])
        try await assertHDR("hdr10-vui", transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, options: [":codec=avcodec,all"])
    }

    func testHLG() async throws {
        try await assertHDR("hlg", transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
    }

    /// A 10-bit BT.709 video: 10-bit pictures, tagged SDR, no EDR.
    func testTenBitSDRStaysSDR() async throws {
        var seen = 0
        let (picture, edr) = try await play("sdr10", until: { _ in seen += 1; return seen > 30 })
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertFalse(VLCFrameOutput.isHDR(picture), VLCFrameOutput.describe(picture))
        XCTAssertEqual(attachment(picture, kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertFalse(edr)
    }

    /// An ordinary 8-bit video stays NV12, BT.709's transfer (the clip is
    /// 128 × 96: BT.601), no EDR.
    func testEightBitSDRStaysNV12() async throws {
        var seen = 0
        let (picture, edr) = try await play("clip", until: { _ in seen += 1; return seen > 30 })
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(attachment(picture, kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(attachment(picture, kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        XCTAssertNil(CVBufferCopyAttachment(picture, kCVImageBufferMasteringDisplayColorVolumeKey, nil))
        XCTAssertFalse(edr)
    }

    /// The colours are read from the media's input item at its place inside
    /// `libvlc_media_t` (`LibVLCVideo.colour(of:)`). A VLCKit with another
    /// layout fails here: the item isn't found (the instance check refuses
    /// it), or it is another one than the media's. Without it every video
    /// plays as SDR.
    func testTheInputItemIsTheMedias() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hdr10", withExtension: "mkv", subdirectory: "Videos"))
        let media = VLCMedia(url: url)
        let uri = try XCTUnwrap(LibVLCVideo.inputItemURI(of: media),
                                "libvlc_media_t's input item not found: check the offsets in VideoColour.swift against this VLCKit")
        XCTAssertEqual(uri, media.url?.absoluteString)
        XCTAssertTrue(uri.hasSuffix("/hdr10.mkv"), uri)
    }

    /// The chromas VLC hands over for sources of more than 8 bits.
    func testDeepChromas() {
        for chroma in ["CVPP", "P010", "I0AL", "I0AB", "I0CL", "I2AL", "I4AL", "I0FL", "GBAL"] {
            XCTAssertTrue(VLCFrameOutput.isDeep(chroma: chroma), chroma)
        }
        for chroma in ["CVPN", "CVPB", "NV12", "I420", "J420", "I422", "I444", "RV32", "UYVY", "I40A"] {
            XCTAssertFalse(VLCFrameOutput.isDeep(chroma: chroma), chroma)
        }
    }

    /// VLC's stream information, as `EsOutUpdateInfo` writes it, read into
    /// the pixel buffer's attachments (the mastering display in the SEI's
    /// order and units).
    func testColoursFromVLCsStreamInformation() throws {
        let colour = try XCTUnwrap(VideoColour(information: [
            "Color transfer function": "SMPTE ST2084 (PQ)",
            "Color primaries": "ITU-R BT.2020",
            "Color space": "ITU-R BT.2020 Limited Range",
            "Max. luminance": "1000.0000 cd/m²",
            "Min. luminance": "0.0050 cd/m²",
            "Primary R": "x=0.6800 y=0.3200",
            "Primary G": "x=0.2650 y=0.6900",
            "Primary B": "x=0.1500 y=0.0600",
            "White point": "x=0.3127 y=0.3290",
            "MaxCLL": "1000 cd/m²",
            "MaxFALL": "400 cd/m²",
        ]))
        XCTAssertEqual(colour.transfer, .pq)
        XCTAssertEqual(colour.primaries, .bt2020)
        XCTAssertTrue(colour.matrix2020)
        XCTAssertFalse(colour.fullRange)
        let mastering: [UInt8] = [0x33, 0xC2, 0x86, 0xC4,  0x1D, 0x4C, 0x0B, 0xB8,  0x84, 0xD0, 0x3E, 0x80,
                                  0x3D, 0x13, 0x40, 0x42,  0x00, 0x98, 0x96, 0x80,  0x00, 0x00, 0x00, 0x32]
        XCTAssertEqual(colour.masteringDisplay.map([UInt8].init), mastering)
        XCTAssertEqual(colour.contentLightLevel.map([UInt8].init), [0x03, 0xE8, 0x01, 0x90])

        XCTAssertEqual(VideoColour(information: ["Color transfer function": "Hybrid Log-Gamma"])?.transfer, .hlg)
        let unstated = try XCTUnwrap(VideoColour(information: ["Color transfer function": "Hybrid Log-Gamma"]))
        XCTAssertEqual(unstated.primaries, .bt2020, "HDR without primaries: BT.2020")
        XCTAssertTrue(unstated.matrix2020)
        let sdr = try XCTUnwrap(VideoColour(information: ["Color transfer function": "ITU-R BT.709",
                                                          "Color space": "ITU-R BT.709 Full Range"]))
        XCTAssertFalse(sdr.isHDR)
        XCTAssertTrue(sdr.fullRange)
        XCTAssertNil(VideoColour(information: ["Color primaries": "ITU-R BT.2020"]), "no transfer function stated: not known")
    }
}
