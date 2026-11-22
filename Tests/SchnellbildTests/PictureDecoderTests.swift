import XCTest
import AppKit
import ImageIO
@testable import Schnellbild

/// The formats the app decodes itself (QOI, PCX, DCX) and the RAW formats
/// LibRaw reads: files made in the test from one reference picture
/// (`DecoderFixtures`), decoded through the app's paths (the tile's,
/// `ThumbnailCache`, and the full view's, `MediaData.picture` scaled down
/// by ImageIO) and compared with the reference pixel by pixel. With
/// `DECODER_SNAPSHOT_DIR` set every decoded picture is written there as a
/// PNG beside the reference, with a contact sheet (`contact-sheet.png`) to
/// look at (CI's artifact `decoder-snapshots`).
final class PictureDecoderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private typealias RGBA = DecoderFixtures.RGBA

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The full view's picture: `MediaData.picture` scaled down by ImageIO
    /// to `maxPixel`, as `FullImageView` decodes it.
    private func fullView(_ url: URL, maxPixel: Int = 4096) async throws -> CGImage {
        let picture = await MediaData.picture(url)
        let source = try XCTUnwrap(picture?.source, "no picture for \(url.lastPathComponent)")
        return try XCTUnwrap(MediaInfo.scaledDown(source, at: 0, maxPixel: maxPixel, now: true), "\(url.lastPathComponent) not decoded")
    }

    /// The tile's picture, through the thumbnail cache as the grid asks it.
    @MainActor
    private func tile(_ url: URL, side: CGFloat = 128) async throws -> CGImage {
        let image = await ThumbnailCache.shared.thumbnail(for: url, side: side)
        let tile = try XCTUnwrap(image, "no tile for \(url.lastPathComponent)")
        var rect = CGRect(origin: .zero, size: tile.size)
        return try XCTUnwrap(tile.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    // MARK: Snapshots to look at

    private static var sheet: [(label: String, pictures: [(caption: String, image: CGImage)])] = []

    private static var snapshotDir: URL? {
        ProcessInfo.processInfo.environment["DECODER_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// Writes the pictures as PNGs and adds a row to the contact sheet,
    /// which is written again with every row.
    private func snapshot(_ label: String, _ pictures: [(String, CGImage)]) {
        Self.sheet.removeAll { $0.label == label }
        Self.sheet.append((label, pictures.map { (caption: $0.0, image: $0.1) }))
        Self.sheet.sort { $0.label < $1.label }
        guard let folder = Self.snapshotDir else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (caption, image) in pictures {
            let name = "\(label)-\(caption)".replacingOccurrences(of: " ", with: "-")
            try? RGBA.of(image, width: image.width, height: image.height).png.write(to: folder.appendingPathComponent(name + ".png"))
        }
        let contact = DecoderFixtures.contactSheet(Self.sheet)
        try? RGBA.of(contact, width: contact.width, height: contact.height).png.write(to: folder.appendingPathComponent("contact-sheet.png"))
    }

    /// Checks a decoded picture against what was encoded: drawn at the
    /// expected size (over white, as transparency shows nothing to
    /// compare), mean and largest difference per sample within the limits.
    private func assertMatches(_ image: CGImage, _ expected: RGBA, mean: Double, max: Int, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let white = CGColor(gray: 1, alpha: 1)
        let got = RGBA.of(image, width: expected.width, height: expected.height, background: white)
        let want = RGBA.of(expected.image, width: expected.width, height: expected.height, background: white)
        let difference = got.difference(to: want)
        print("decoders: \(what): \(image.width) × \(image.height), mean difference \(String(format: "%.2f", difference.mean)), largest \(difference.max)")
        XCTAssertLessThanOrEqual(difference.mean, mean, "\(what): mean difference", file: file, line: line)
        XCTAssertLessThanOrEqual(difference.max, max, "\(what): largest difference", file: file, line: line)
    }

    // MARK: QOI

    /// QOI with 3 and 4 channels decodes to every pixel encoded, also
    /// through the app's tile and full view; its header says sRGB or linear.
    func testQOIDecodesEveryPixel() async throws {
        let reference = DecoderFixtures.reference(text: "QOI"), withAlpha = DecoderFixtures.reference(text: "QOI", alpha: true)
        for (name, picture, channels) in [("qoi-rgb", reference, 3), ("qoi-rgba", withAlpha, 4)] {
            let data = DecoderFixtures.qoi(picture, channels: channels)
            let decoded = try XCTUnwrap(QOIDecoder.decode(data), name)
            var expected = picture
            if channels == 3 { for i in stride(from: 3, to: expected.pixels.count, by: 4) { expected.pixels[i] = 255 } }
            XCTAssertEqual(decoded.pixels, expected.pixels, "\(name): every pixel as encoded")
            XCTAssertEqual(decoded.hasAlpha, channels == 4)

            let url = try file("\(name).qoi", data)
            XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
            let full = try await fullView(url)
            XCTAssertEqual(full.width, picture.width)
            assertMatches(full, expected, mean: 0.5, max: 2, "\(name) full view")
            let tile = try await tile(url)
            assertMatches(tile, expected, mean: 6, max: 160, "\(name) tile")
            snapshot(name, [("reference", expected.image), ("tile", tile), ("full view", full)])
        }
        let linear = try XCTUnwrap(QOIDecoder.header(DecoderFixtures.qoi(reference, channels: 3, linear: true)))
        XCTAssertTrue(linear.linear)
    }

    /// A QOI file without an extension shows by its header.
    func testAQOIFileWithoutAnExtensionIsAPicture() async throws {
        let url = try file("picture", DecoderFixtures.qoi(DecoderFixtures.reference(), channels: 4))
        ContentSniffer.shared.content(of: url)
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        XCTAssertEqual(BrowserModel.shownExtension(of: url), "qoi")
        _ = try await fullView(url)
    }

    // MARK: PCX

    /// Every kind of PCX (1, 2 and 4 bits through the header's palette, 4
    /// planes of 1 bit, 8 bits through the palette at the end, 24 and 32
    /// bits in planes), run-length encoded or not, with padding after each
    /// plane's line: the picture in its colours, exactly.
    func testEveryKindOfPCXDecodesExactly() async throws {
        let reference = DecoderFixtures.reference(text: "PCX"), withAlpha = DecoderFixtures.reference(text: "PCX", alpha: true)
        for kind in DecoderFixtures.PCXKind.allCases {
            let picture = kind == .rgba ? withAlpha : reference
            for encoded in [true, false] {
                let (data, expected) = DecoderFixtures.pcx(picture, kind: kind, encoded: encoded, extraBytes: encoded ? 0 : 3)
                let decoded = try XCTUnwrap(PCXDecoder.decode(data), kind.rawValue)
                XCTAssertEqual(decoded.pixels, expected.pixels, "\(kind.rawValue) \(encoded ? "encoded" : "plain"): every pixel")
            }
            let (data, expected) = DecoderFixtures.pcx(picture, kind: kind)
            let url = try file("pcx-\(kind.rawValue).pcx", data)
            XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
            let full = try await fullView(url)
            assertMatches(full, expected, mean: 0.5, max: 2, "pcx \(kind.rawValue) full view")
            let tile = try await tile(url)
            assertMatches(tile, expected, mean: 6, max: 160, "pcx \(kind.rawValue) tile")
            // How far the format's colours are from the reference
            let against = RGBA.of(full, width: picture.width, height: picture.height, background: CGColor(gray: 1, alpha: 1))
            print("decoders: pcx \(kind.rawValue) against the reference: \(against.difference(to: RGBA.of(picture.image, width: picture.width, height: picture.height, background: CGColor(gray: 1, alpha: 1))))")
            snapshot("pcx-\(kind.rawValue)", [("reference", picture.image), ("expected", expected.image), ("tile", tile), ("full view", full)])
        }
    }

    /// A DCX shows its first page.
    func testADCXShowsItsFirstPage() async throws {
        let reference = DecoderFixtures.reference(text: "DCX")
        let first = DecoderFixtures.pcx(reference, kind: .rgb), second = DecoderFixtures.pcx(reference, kind: .mono)
        let url = try file("pages.dcx", DecoderFixtures.dcx([first.data, second.data]))
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        let full = try await fullView(url)
        assertMatches(full, first.expected, mean: 0.5, max: 2, "dcx full view")
        let tile = try await tile(url)
        snapshot("dcx", [("reference", reference.image), ("tile", tile), ("full view", full)])
    }

    // MARK: Everywhere a picture goes

    /// The formats are pictures in a listing, in a folder tile's previews,
    /// in the slideshow's walk and inside archives (by their names), and
    /// the Inspector names the file's format and depth.
    func testTheyArePicturesEverywhere() async throws {
        let folder = dir.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DecoderFixtures.qoi(DecoderFixtures.reference(), channels: 3).write(to: folder.appendingPathComponent("a.qoi"))
        try DecoderFixtures.pcx(DecoderFixtures.reference(), kind: .ega).data.write(to: folder.appendingPathComponent("b.pcx"))
        try DecoderFixtures.casioBay(DecoderFixtures.reference()).write(to: folder.appendingPathComponent("c.bay"))
        let previews = await BrowserModel.folderPreviewFiles(in: folder)
        XCTAssertEqual(Set(previews.map(\.lastPathComponent)), ["a.qoi", "b.pcx", "c.bay"])
        let holds = await BrowserModel.containsMedia(dir)
        XCTAssertEqual(holds, true)
        let walked = await BrowserModel.scan(folder)
        XCTAssertEqual(Set(walked.map(\.name)), ["a.qoi", "b.pcx", "c.bay"])
        let zip = dir.appendingPathComponent("a.zip")
        for name in ["x.qoi", "x.pcx", "x.dcx", "x.bay", "x.mef"] {
            XCTAssertEqual(BrowserModel.mediaKind(of: zip.appendingPathComponent(name)), .image, name)
        }

        // The Inspector: the file's format and bits, not the TIFF's handed to ImageIO
        for (name, format, depth) in [("b.pcx", "PCX (ZSoft)", 4), ("a.qoi", "QOI (Quite OK Image)", 8)] {
            let url = folder.appendingPathComponent(name)
            let opened = await MediaData.imageSource(url)
            let source = try XCTUnwrap(opened)
            let facts = FileFacts.picture(source, named: url)
            XCTAssertEqual(facts.format, format)
            XCTAssertEqual(facts.depth, depth)
            XCTAssertNil(facts.recommendedExtension)
            let report = PictureMetadata.report(source, named: url)
            XCTAssertTrue(report.media.contains(InfoRow(label: String(localized: "Bit Depth"), value: StreamFacts.describeDepth(depth))), name)
            XCTAssertTrue(report.media.contains(InfoRow(label: String(localized: "Resolution"), value: "160 × 100 px")), name)
        }
    }

    // MARK: Damaged and crafted files

    /// A fixed-seed generator, so a failure can be run again.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func damaged(_ data: Data, _ random: inout SplitMix) -> Data {
        var bytes = [UInt8](data)
        switch Int.random(in: 0..<4, using: &random) {
        case 0:
            // Cut anywhere
            bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &random)))
        case 1:
            // Bytes flipped
            for _ in 0..<Int.random(in: 1...16, using: &random) {
                bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
        case 2:
            // The header's bytes flipped
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                bytes[Int.random(in: 0..<min(bytes.count, 128), using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
        default:
            // A part repeated or left out
            let from = Int.random(in: 0..<bytes.count, using: &random), to = Int.random(in: from...bytes.count, using: &random)
            if Bool.random(using: &random) { bytes.insert(contentsOf: bytes[from..<to], at: from) } else { bytes.removeSubrange(from..<to) }
        }
        return Data(bytes)
    }

    /// Thousands of damaged QOI and PCX files from a fixed seed, files cut
    /// at every length, and crafted headers: none traps, none decodes to
    /// more than the limits, a cut file keeps what it had.
    func testDamagedAndCraftedFilesNeverTrap() {
        var random = SplitMix(state: 0x5C11_E11B_11D0_0001)
        let reference = DecoderFixtures.reference(width: 40, height: 24)
        let samples = [DecoderFixtures.qoi(reference, channels: 3), DecoderFixtures.qoi(reference, channels: 4)]
            + DecoderFixtures.PCXKind.allCases.map { DecoderFixtures.pcx(reference, kind: $0).data }
        for round in 0..<4000 {
            let sample = samples[round % samples.count]
            let data = damaged(sample, &random)
            for picture in [QOIDecoder.decode(data), PCXDecoder.decode(data), PCXDecoder.firstDCXPage(data).flatMap(PCXDecoder.decode)] {
                guard let picture else { continue }
                XCTAssertTrue(DecodedPicture.fits(width: picture.width, height: picture.height))
                XCTAssertEqual(picture.pixels.count, picture.width * picture.height * 4)
            }
        }
        for sample in samples {
            for cut in 0..<sample.count {
                _ = QOIDecoder.decode(sample.prefix(cut))
                _ = PCXDecoder.decode(sample.prefix(cut))
            }
        }
        // A file cut in half keeps its size and the rows it had
        let rgb = DecoderFixtures.pcx(reference, kind: .rgb)
        let half = try? XCTUnwrap(PCXDecoder.decode(rgb.data.prefix(rgb.data.count / 2)))
        XCTAssertEqual(half?.width, 40)
        XCTAssertEqual(Array(half?.pixels.prefix(40 * 4) ?? []), Array(rgb.expected.pixels.prefix(40 * 4)), "the first row as encoded")

        // QOI: sizes beyond the limits, none, endless; channels and colour space out of range
        func qoiHeader(width: UInt32, height: UInt32, channels: UInt8 = 4, colorspace: UInt8 = 0) -> Data {
            var d = Data("qoif".utf8)
            for v in [width, height] { d.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
            d.append(contentsOf: [channels, colorspace])
            return d + Data([0xFE, 1, 2, 3, 0xFD, 0, 0, 0, 0, 0, 0, 0, 1])   // RGB, a run of 62, the end
        }
        XCTAssertNil(QOIDecoder.decode(qoiHeader(width: 0xFFFF_FFFF, height: 0xFFFF_FFFF)))
        XCTAssertNil(QOIDecoder.decode(qoiHeader(width: 9000, height: 9000)), "81 Mpx: beyond the limit")
        XCTAssertNil(QOIDecoder.decode(qoiHeader(width: 0, height: 10)))
        XCTAssertNil(QOIDecoder.decode(qoiHeader(width: 4, height: 4, channels: 5)))
        XCTAssertNil(QOIDecoder.decode(qoiHeader(width: 4, height: 4, colorspace: 2)))
        let small = QOIDecoder.decode(qoiHeader(width: 8000, height: 8000))
        XCTAssertEqual(small?.width, 8000, "64 Mpx: within the limit, decoded as far as the chunks reach")

        // PCX: a window past 65 535, lines shorter than the row, unknown bits, planes, versions
        func pcxHeader(_ change: (inout [UInt8]) -> Void) -> Data {
            var h = [UInt8](repeating: 0, count: 128)
            h[0] = 10; h[1] = 5; h[2] = 1; h[3] = 8; h[8] = 9; h[10] = 9; h[65] = 1; h[66] = 10
            change(&h)
            return Data(h) + Data(repeating: 0xFF, count: 300)
        }
        XCTAssertNotNil(PCXDecoder.decode(pcxHeader { _ in }))
        XCTAssertNil(PCXDecoder.decode(pcxHeader { $0[66] = 4 }), "a line shorter than the row")
        XCTAssertNil(PCXDecoder.decode(pcxHeader { $0[3] = 3 }))
        XCTAssertNil(PCXDecoder.decode(pcxHeader { $0[65] = 5 }))
        XCTAssertNil(PCXDecoder.decode(pcxHeader { $0[65] = 2 }), "8 bits in 2 planes")
        XCTAssertNil(PCXDecoder.decode(pcxHeader { $0[1] = 1 }))
        XCTAssertNil(PCXDecoder.decode(pcxHeader { $0[4] = 10 }), "the window's end before its start")
        XCTAssertNil(PCXDecoder.decode(pcxHeader { $0[8] = 0xFF; $0[9] = 0xFF; $0[10] = 0xFF; $0[11] = 0xFF; $0[66] = 0xFF; $0[67] = 0xFF }),
                     "65 536 × 65 536: beyond the limits")
        // A run longer than what is left: the picture ends there
        XCTAssertNotNil(PCXDecoder.decode(pcxHeader { _ in } + Data([0xFF, 7])))
        // DCX offsets outside the file or into its table
        var dcx = DecoderFixtures.dcx([rgb.data])
        dcx.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertNil(PCXDecoder.firstDCXPage(dcx))
        dcx.replaceSubrange(4..<8, with: [2, 0, 0, 0])
        XCTAssertNil(PCXDecoder.firstDCXPage(dcx))
    }

    // MARK: LibRaw

    /// The RAW formats LibRaw adds are those ImageIO doesn't read on this
    /// macOS; ImageIO's own stay ImageIO's.
    func testLibRawTakesOnlyWhatImageIODoesntRead() {
        for ext in RawDecoder.librawOnly {
            XCTAssertEqual(RawDecoder.extensions.contains(ext), !BrowserModel.imageIOReads(ext), ext)
            print("decoders: .\(ext): \(RawDecoder.extensions.contains(ext) ? "LibRaw" : "ImageIO")")
        }
        for ext in RawDecoder.imageIOExtensions {
            XCTAssertFalse(RawDecoder.extensions.contains(ext), ext)
            XCTAssertNil(PictureDecoders.format(of: URL(fileURLWithPath: "/x/a.\(ext)")), ext)
        }
        XCTAssertTrue(BrowserModel.imageExtensions.isSuperset(of: RawDecoder.extensions))
    }

    /// A Casio QV-2000UX raw file (headerless, known by its size) shows in
    /// the tile and the full view as the reference: developed by LibRaw
    /// (no preview inside: the tile is developed at half size).
    func testACasioRawFileShows() async throws {
        let reference = DecoderFixtures.reference(text: "RAW")
        let url = try file("casio.bay", DecoderFixtures.casioBay(reference))
        XCTAssertEqual(BrowserModel.mediaKind(of: url), .image)
        let full = try await fullView(url)
        XCTAssertEqual(full.width, 1632)
        XCTAssertEqual(full.height, 1208)
        // Demosaicing softens the edges between bars and letters
        assertMatches(full, reference, mean: 8, max: 255, "casio full view")
        let tile = try await tile(url)
        assertMatches(tile, reference, mean: 10, max: 255, "casio tile")
        snapshot("raw-casio-bay", [("reference", reference.image), ("tile", tile), ("full view", full)])
        let opened = await MediaData.imageSource(url)
        let source = try XCTUnwrap(opened)
        let facts = FileFacts.picture(source, named: url)
        XCTAssertEqual(facts.camera, "Casio QV-2000UX")
        XCTAssertEqual(facts.depth, 8)
        XCTAssertTrue(facts.format?.hasSuffix("(LibRaw)") == true, facts.format ?? "-")
    }

    /// A DNG (camera colours sRGB's, Bayer RGGB) developed by LibRaw and its
    /// preview: as the full view takes a RAW of ImageIO's formats that
    /// ImageIO doesn't decode (`RawDecoder.fallback`), and as a tile from
    /// the preview the file carries.
    func testLibRawDevelopsADNGAndReadsItsPreview() async throws {
        let reference = DecoderFixtures.reference(text: "DNG")
        let data = DecoderFixtures.dng(reference, preview: true)
        let url = try file("camera.dng", data)
        let fallback = await RawDecoder.fallback(url)
        let developed = try XCTUnwrap(fallback)
        let full = try XCTUnwrap(MediaInfo.scaledDown(developed.source, at: 0, maxPixel: 4096, now: true))
        XCTAssertEqual(full.width, reference.width * 2)
        assertMatches(full, reference, mean: 8, max: 255, "dng developed")
        let previewed = await RawDecoder.preview(data, maxPixel: 256, allowBitmap: true)
        let preview = try XCTUnwrap(previewed)
        assertMatches(preview, reference, mean: 0.5, max: 2, "dng preview")
        let halved = await RawDecoder.developed(data, named: url, half: true)
        let half = try XCTUnwrap(halved)
        let halfImage = try XCTUnwrap(MediaInfo.scaledDown(half.source, at: 0, maxPixel: 4096, now: true))
        XCTAssertEqual(halfImage.width, reference.width)
        snapshot("raw-dng", [("reference", reference.image), ("preview", preview), ("half size", halfImage), ("developed", full)])
        // The camera and its facts reach the picture's properties
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(developed.source, 0, nil) as? [CFString: Any])
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Schnellbild")
    }

    /// LibRaw on damaged and crafted RAW files: DNGs cut at many lengths and
    /// with bytes flipped (a fixed seed), a Casio-sized file of noise and
    /// one of zeros, a DNG claiming a size beyond the limits, a cancelled
    /// development. Nothing traps; what comes back is within the limits.
    func testLibRawOnDamagedFilesNeverTraps() async throws {
        var random = SplitMix(state: 0x11B2_A77F_0022_0003)
        let reference = DecoderFixtures.reference(width: 48, height: 32)
        let samples = [DecoderFixtures.dng(reference, preview: true), DecoderFixtures.dng(reference, preview: false)]
        var developed = 0
        for round in 0..<600 {
            let data = damaged(samples[round % samples.count], &random)
            if let picture = await RawDecoder.developed(data, named: URL(fileURLWithPath: "/x/a.dng"), half: round % 2 == 0) {
                let image = try XCTUnwrap(MediaInfo.scaledDown(picture.source, at: 0, maxPixel: 64, now: true))
                XCTAssertGreaterThan(image.width, 0)
                developed += 1
            }
            _ = await RawDecoder.preview(data, maxPixel: 64, allowBitmap: true)
        }
        print("decoders: LibRaw developed \(developed) of 600 damaged DNGs")
        for cut in stride(from: 0, to: samples[0].count, by: 97) {
            _ = await RawDecoder.developed(samples[0].prefix(cut), named: URL(fileURLWithPath: "/x/a.dng"), half: true)
        }
        var noise = Data(count: 1_976_352)
        for i in 0..<noise.count { noise[i] = UInt8.random(in: 0...255, using: &random) }
        let fromNoise = await RawDecoder.developed(noise, named: URL(fileURLWithPath: "/x/a.bay"), half: true)
        XCTAssertNotNil(fromNoise, "noise in a Casio's size is a (noisy) picture")
        let fromZeros = await RawDecoder.developed(Data(count: 1_976_352), named: URL(fileURLWithPath: "/x/a.bay"), half: true)
        XCTAssertNotNil(fromZeros)
        let tooShort = await RawDecoder.developed(Data(count: 1000), named: URL(fileURLWithPath: "/x/a.bay"), half: true)
        XCTAssertNil(tooShort)

        // A DNG whose raw IFD claims 60 000 × 60 000 pixels: refused before anything is allocated
        var huge = DecoderFixtures.TIFFWriter()
        huge.add(ifd: [.long(254, [0]), .long(256, [60000]), .long(257, [60000]), .short(258, [16]), .short(259, [1]), .short(262, [32803]),
                       .short(277, [1]), .long(278, [60000]), .short(33421, [2, 2]), .bytes(33422, [0, 1, 1, 2]),
                       .bytes(50706, [1, 4, 0, 0]), .ascii(271, "X"), .ascii(50708, "X")],
                 strip: Data(count: 4096), subIFDs: [])
        let fromHuge = await RawDecoder.developed(huge.data, named: URL(fileURLWithPath: "/x/a.dng"), half: false)
        XCTAssertNil(fromHuge)

        // Cancelled: the task's development stops and gives nothing
        let big = DecoderFixtures.casioBay(DecoderFixtures.reference())
        let task = Task { await RawDecoder.developed(big, named: URL(fileURLWithPath: "/x/a.bay"), half: false) }
        task.cancel()
        _ = await task.value
    }

    // MARK: Real RAW files

    /// The camera RAW samples (`Scripts/fetch_raw_samples.sh`: raw.pixls.us
    /// files under CC0 1.0, `Scripts/raw_samples.env`), in `RAW_SAMPLES_DIR`
    /// or `Vendor/RawSamples`. On CI they must be there.
    private var rawSamples: URL? {
        let folder = ProcessInfo.processInfo.environment["RAW_SAMPLES_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Vendor/RawSamples")
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("LICENSES.txt").path) ? folder : nil
    }

    /// Real RAW files of the formats LibRaw adds (Kodak `.kdc`, Minolta's
    /// RD175 `.mdc`, Sinar `.sti`, Olympus `.ori` where ImageIO doesn't read
    /// it) and of ImageIO's own (`.dng`, `.nef`, `.ori` on macOS 26) as the
    /// control: each through the tile's and the full view's path, and
    /// LibRaw's development beside ImageIO's where both read the file, else
    /// beside the tile (the preview the camera wrote, where there is one).
    /// The pictures go to the contact sheet.
    func testRealRawSamplesShow() async throws {
        guard let folder = rawSamples else {
            if ProcessInfo.processInfo.environment["CI"] != nil { XCTFail("no RAW samples: Scripts/fetch_raw_samples.sh") }
            throw XCTSkip("no RAW samples (Scripts/fetch_raw_samples.sh)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "LICENSES.txt" }.sorted()
        XCTAssertEqual(names.count, 7)
        let white = CGColor(gray: 1, alpha: 1)
        /// Both drawn at 192 px wide in the full view's proportions
        func small(_ image: CGImage, like full: CGImage) -> RGBA {
            RGBA.of(image, width: 192, height: max(1, 192 * full.height / max(1, full.width)), background: white)
        }
        /// The mean of the samples: a black picture is near 0
        func brightness(_ image: RGBA) -> Double {
            Double(image.pixels.enumerated().reduce(0) { $1.offset % 4 == 3 ? $0 : $0 + Int($1.element) }) / Double(image.width * image.height * 3)
        }
        for name in names {
            let url = folder.appendingPathComponent(name)
            let ext = url.pathExtension
            XCTAssertEqual(BrowserModel.mediaKind(of: url), .image, name)
            let byLibRaw = RawDecoder.extensions.contains(ext)
            let full = try await fullView(url, maxPixel: 1024)
            let tile = try await tile(url, side: 256)
            let data = try Data(contentsOf: url)
            let developed = await RawDecoder.developed(data, named: url, half: true)
            let libraw = try XCTUnwrap(developed.flatMap { MediaInfo.scaledDown($0.source, at: 0, maxPixel: 1024, now: true) }, "\(name): LibRaw")
            var pictures: [(String, CGImage)] = [("tile", tile), ("full view (\(byLibRaw ? "LibRaw" : "ImageIO"))", full)]
            // The tile and the full view show one picture
            let tileAgainstFull = small(tile, like: full).difference(to: small(full, like: full))
            print("decoders: \(name): \(byLibRaw ? "LibRaw" : "ImageIO"), full view \(full.width) × \(full.height), "
                  + "tile \(tile.width) × \(tile.height), tile against full view: mean \(String(format: "%.1f", tileAgainstFull.mean))")
            XCTAssertGreaterThan(brightness(small(libraw, like: libraw)), 20, "\(name): LibRaw's picture is black")
            if byLibRaw {
                // The tile is the camera's own preview where it carries a
                // good one: its rendering, not LibRaw's
                XCTAssertLessThan(tileAgainstFull.mean, 30, "\(name): tile and full view differ")
                pictures.append(("LibRaw half size", libraw))
            } else {
                // ImageIO and LibRaw develop the same raw data (their tone
                // curves differ a little)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let imageIO = try XCTUnwrap(MediaInfo.scaledDown(source, at: 0, maxPixel: 1024, now: true))
                let against = small(libraw, like: imageIO).difference(to: small(imageIO, like: imageIO))
                let imageIOBrightness = brightness(small(imageIO, like: imageIO))
                print("decoders: \(name): LibRaw against ImageIO: mean \(String(format: "%.1f", against.mean)), largest \(against.max); "
                      + "ImageIO's brightness \(String(format: "%.1f", imageIOBrightness))")
                // ImageIO's own picture is ImageIO's matter (a black or blown out
                // one is reported in the log), LibRaw's must match a picture it shows
                if (20...200).contains(imageIOBrightness) {
                    XCTAssertLessThan(against.mean, 40, "\(name): LibRaw and ImageIO differ")
                } else {
                    print("decoders: \(name): ImageIO shows it \(imageIOBrightness < 20 ? "black" : "blown out") on this macOS (\(ProcessInfo.processInfo.operatingSystemVersionString))")
                }
                pictures.append(("LibRaw half size", libraw))
            }
            snapshot("sample-\((name as NSString).deletingPathExtension)-\(ext)", pictures)
        }
    }
}
