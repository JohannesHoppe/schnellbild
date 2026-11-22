import XCTest
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VLCKit
import VLCFrames
@testable import Schnellbild

/// The visual check of every format the app shows: the reference picture
/// (`ReferencePicture`) in each format (`FormatFixtures.samples`, the
/// videos and AVIF sequence from `Scripts/make_video_fixtures.sh visual`),
/// decoded through the app's own paths, the tile's (`ThumbnailCache`:
/// QuickLook, the app's own picture or VLC's frame) and the full view's
/// (`FullImageView.decode`; a video's picture from AVFoundation or VLC's
/// `VLCFrameOutput`, as the full view chooses), each compared with what it
/// must show: the mean difference per channel over the picture and the
/// largest at the probes (`FormatFixtures.probePoints`), within the
/// format's tolerance; a turned or cut picture fails by its sides first.
/// A video's picture carries its frame number, read back to compare it with
/// that very frame. With FORMAT_SNAPSHOT_DIR set, every picture goes there
/// as a PNG, with a contact sheet per group (reference | tile | full view)
/// and the numbers in `results-<group>.txt`.
@MainActor
final class FormatVisualTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("visual-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let snapshots = ProcessInfo.processInfo.environment["FORMAT_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    // MARK: Comparing

    /// How far a decoded picture lies from what it must show.
    struct Metrics {
        let width: Int, height: Int
        /// Mean and largest difference per channel (red, green, blue).
        let mean: [Double]
        let max: [Int]
        /// The largest difference of a channel at a probe, and where.
        let probe: Int
        let worstProbe: String
        /// Its sides' ratio differs from the reference's by more than 3 %.
        let shapeDiffers: Bool

        func within(_ tolerance: FormatFixtures.Tolerance) -> Bool {
            !shapeDiffers && mean.allSatisfy { $0 <= tolerance.mean } && probe <= tolerance.probe
        }

        var text: String {
            let means = mean.map { String(format: "%.1f", $0) }.joined(separator: "/")
            let maxes = max.map(String.init).joined(separator: "/")
            return "\(width)×\(height) mean \(means) max \(maxes) probe \(probe) (\(worstProbe))" + (shapeDiffers ? " SIDES DIFFER" : "")
        }
    }

    static func compare(_ image: CGImage, with reference: CGImage) -> Metrics {
        let w = image.width, h = image.height
        let shown = RGBAPixels(image)
        let expected = RGBAPixels(reference, width: w, height: h)
        var sums = [0.0, 0, 0], maxes = [0, 0, 0]
        for i in stride(from: 0, to: shown.bytes.count, by: 4) {
            for c in 0..<3 {
                let d = abs(Int(shown.bytes[i + c]) - Int(expected.bytes[i + c]))
                sums[c] += Double(d)
                maxes[c] = Swift.max(maxes[c], d)
            }
        }
        let count = Double(w * h)
        var worst = 0, worstName = "-"
        for (name, px, py) in FormatFixtures.probePoints {
            let x = Int((Double(px) + 0.5) / Double(ReferencePicture.width) * Double(w))
            let y = Int((Double(py) + 0.5) / Double(ReferencePicture.height) * Double(h))
            for c in 0..<3 {
                var a = 0, b = 0
                for dy in -1...1 { for dx in -1...1 {
                    a += Int(shown.at(x + dx, y + dy).channel(c))
                    b += Int(expected.at(x + dx, y + dy).channel(c))
                } }
                let d = abs(a - b) / 9
                if d > worst { worst = d; worstName = name }
            }
        }
        let ratio = Double(w) / Double(h), wanted = Double(reference.width) / Double(reference.height)
        return Metrics(width: w, height: h, mean: sums.map { $0 / count }, max: maxes, probe: worst, worstProbe: worstName,
                       shapeDiffers: abs(ratio / wanted - 1) > 0.03)
    }

    // MARK: Results and pictures

    /// One row of a contact sheet: a format, what it must show, its tile and its full view.
    struct Row {
        let name: String
        let reference: CGImage
        let thumbnail: CGImage?
        let full: CGImage?
        let note: String
        let passed: Bool
    }

    private var rows: [Row] = []
    private var lines: [String] = []

    private func record(_ name: String, reference: CGImage, thumbnail: CGImage?, full: CGImage?,
                        thumbnailReference: CGImage? = nil, tolerance: FormatFixtures.Tolerance, extra: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        var note = extra, passed = true
        let parts: [(String, CGImage?, CGImage, FormatFixtures.Tolerance)] = [
            ("tile", thumbnail, thumbnailReference ?? reference, tolerance.scaled), ("full", full, reference, tolerance),
        ]
        for (part, image, expected, allowed) in parts {
            guard let image else {
                passed = false
                note += " \(part): NONE"
                XCTFail("\(name): no \(part) picture", file: file, line: line)
                continue
            }
            let metrics = Self.compare(image, with: expected)
            let ok = metrics.within(allowed)
            passed = passed && ok
            note += " | \(part) \(metrics.text) \(ok ? "ok" : "FAILS (mean ≤ \(allowed.mean), probe ≤ \(allowed.probe))")"
            XCTAssertTrue(ok, "\(name) \(part): \(metrics.text)", file: file, line: line)
        }
        lines.append("\(name):\(note)")
        print("visual: \(name):\(note)")
        rows.append(Row(name: name, reference: reference, thumbnail: thumbnail, full: full, note: note, passed: passed))
    }

    /// The PNGs of every row, the contact sheet and the numbers, into FORMAT_SNAPSHOT_DIR.
    private func writeSnapshots(group: String) throws {
        guard let out = Self.snapshots else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for row in rows {
            let base = group + "-" + row.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            for (part, image) in [("reference", row.reference), ("thumbnail", row.thumbnail), ("full", row.full)] {
                if let image { try Self.writePNG(image, to: out.appendingPathComponent("\(base)-\(part).png")) }
            }
        }
        try Self.writePNG(Self.contactSheet(rows, title: group), to: out.appendingPathComponent("contact-\(group).png"))
        try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("results-\(group).txt"), atomically: true, encoding: .utf8)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Reference | tile | full view per row, the format's name and verdict on the left.
    static func contactSheet(_ rows: [Row], title: String) -> CGImage {
        let cellW = 384, cellH = 240, labelW = 260, gap = 8, header = 40
        let width = labelW + 3 * (cellW + gap) + gap
        let height = header + rows.count * (cellH + gap) + gap
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.18, green: 0.18, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ string: String, x: Int, top: Int, size: CGFloat, colour: CGColor, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: colour] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes)!)
            context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - top) - size)
            CTLineDraw(line, context)
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        text("\(title): reference | tile | full view", x: gap, top: 10, size: 20, colour: white, bold: true)
        for (i, row) in rows.enumerated() {
            let top = header + i * (cellH + gap)
            text(row.name, x: gap, top: top + 4, size: 18, colour: white, bold: true)
            text(row.passed ? "within tolerance" : "OUT OF TOLERANCE", x: gap, top: top + 30, size: 14,
                 colour: row.passed ? CGColor(srgbRed: 0.5, green: 0.9, blue: 0.5, alpha: 1) : CGColor(srgbRed: 1, green: 0.4, blue: 0.4, alpha: 1))
            // The numbers, one part a line
            for (n, part) in row.note.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }).enumerated() where !part.isEmpty {
                for (m, chunk) in stride(from: 0, to: part.count, by: 34).map({ String(part.dropFirst($0).prefix(34)) }).enumerated() {
                    text(chunk, x: gap, top: top + 56 + n * 54 + m * 14, size: 11, colour: CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
                }
            }
            for (column, image) in [row.reference, row.thumbnail, row.full].enumerated() {
                let x = labelW + gap + column * (cellW + gap)
                let cell = CGRect(x: x, y: height - top - cellH, width: cellW, height: cellH)
                context.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1))
                context.fill(cell)
                guard let image else { continue }
                // Fitted, never enlarged beyond twice its size
                let scale = min(Double(cellW) / Double(image.width), Double(cellH) / Double(image.height), 2)
                let w = Double(image.width) * scale, h = Double(image.height) * scale
                context.interpolationQuality = scale >= 1 ? .none : .high
                context.draw(image, in: CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h))
            }
        }
        return context.makeImage()!
    }

    // MARK: The app's paths

    /// The tile as the grid gets it (QuickLook, else the app's own picture).
    private func thumbnail(_ url: URL) async -> CGImage? {
        guard let image = await ThumbnailCache.shared.thumbnail(for: url, side: 128),
              image.accessibilityDescription != ThumbnailCache.fileIcon else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The full view's picture at up to 1024 pixels (larger than every sample).
    private func fullView(_ url: URL) async -> CGImage? {
        let pages = PDFPages.isPDF(url) ? await PDFPages.open(url) : nil
        guard case .success(let result) = await FullImageView.decode(url, pages: pages, page: 0, maxPixel: 1024, kept: nil) else { return nil }
        return result.2
    }

    private func checkPicture(_ sample: FormatFixtures.Sample, extra: String = "") async {
        ContentSniffer.shared.content(of: sample.url)   // as a listing reads such files
        let kind = BrowserModel.mediaKind(of: sample.url)
        XCTAssertEqual(kind, .image, "\(sample.name) is a picture to the app")
        let thumbnail = await thumbnail(sample.url)
        let full = await fullView(sample.url)
        record(sample.name, reference: sample.reference, thumbnail: thumbnail, full: full, tolerance: sample.tolerance, extra: extra)
    }

    // MARK: Pictures

    /// ImageIO's formats and those read by hand (Netpbm's P4), each written
    /// from the reference picture.
    func testPictureFormatsLookRight() async throws {
        var missing: [String] = []
        for sample in try FormatFixtures.samples(in: dir, missing: &missing) {
            let ext = sample.url.pathExtension
            if BrowserModel.systemImageExtensions.contains(ext), !BrowserModel.imageExtensions.contains(ext) {
                lines.append("\(sample.name): not read by this macOS (another file)")
                print("visual: \(sample.name): not read by this macOS")
                continue
            }
            await checkPicture(sample)
        }
        // The AVIF sequence (no writer in ImageIO): its first frame
        if let url = Bundle.module.url(forResource: "visual", withExtension: "avifs", subdirectory: "Videos") {
            let thumbnail = await thumbnail(url), full = await fullView(url)
            let frame = full.flatMap(ReferencePicture.frameNumber(in:))
            XCTAssertEqual(frame, 0, "the full view shows the sequence's first frame")
            record("avifs (AV1 sequence)", reference: ReferencePicture.image(frame: frame ?? 0), thumbnail: thumbnail, full: full,
                   thumbnailReference: ReferencePicture.image(frame: thumbnail.flatMap(ReferencePicture.frameNumber(in:)) ?? 0),
                   tolerance: .video, extra: " frame \(frame.map(String.init) ?? "?")")
        } else {
            missing.append("avifs")
        }
        if let url = Bundle.module.url(forResource: "visual", withExtension: "avci", subdirectory: "Videos") {
            await checkPicture(FormatFixtures.Sample(name: "avci (AVC in HEIF)", url: url, reference: ReferencePicture.image(),
                                                     tolerance: .video))
        } else {
            missing.append("avci")
        }
        for name in missing { lines.append("\(name): no sample on this macOS") }
        let probe = EmbeddedPreview.ASTCRows.probe
        lines.append("ASTC rows probe: \(probe.said), read from the bottom: \(probe.fromTheBottom)")
        print("visual: \(lines.last!)")
        // Why ASTC and KTX are written by hand: ImageIO's own writers, read
        // back by ImageIO (said, not asserted: a fixed writer changes nothing here)
        for (name, type) in [("ImageIO's ASTC writer", "org.khronos.astc"), ("ImageIO's KTX writer", "org.khronos.ktx")] {
            let reference = ReferencePicture.image()
            guard let data = FormatFixtures.written(type, picture: reference),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { lines.append("\(name): nothing written or read"); continue }
            let metrics = Self.compare(image, with: reference)
            let flipped = Self.compare(image, with: ReferencePicture.scaled(reference, width: reference.width, height: reference.height, flipped: true))
            lines.append("\(name), read back: \(metrics.text); against the reference upside down: \(flipped.text)")
            print("visual: \(lines.last!)")
        }
        try writeSnapshots(group: "pictures")
        XCTAssertEqual(missing, [], "samples this macOS can't write")
    }

    /// Vector pictures and the files shown by a picture they carry:
    /// compressed SVG, Illustrator, PostScript, ZIP documents.
    func testDocumentFormatsLookRight() async throws {
        var missing: [String] = []
        for sample in try FormatFixtures.documentSamples(in: dir, missing: &missing) {
            let pages = PDFPages.isPDF(sample.url) ? await PDFPages.open(sample.url) : nil
            let shown = pages.map { $0.isPreview ? " (embedded preview)" : " (PDF page)" } ?? ""
            await checkPicture(sample, extra: shown)
        }
        for name in missing { lines.append("\(name): no sample on this macOS") }
        try writeSnapshots(group: "documents")
        XCTAssertEqual(missing, [])
    }

    /// Which way ImageIO reads an ASTC texture's rows, by its size (said, not
    /// asserted): white above, black below, each read back.
    func testASTCRowOrderBySize() throws {
        var said: [String] = []
        for (w, h) in [(16, 16), (64, 64), (128, 64), (64, 128), (256, 256), (384, 240), (240, 384), (384, 256), (512, 512), (1024, 1024)] {
            let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))   // the upper half
            let texture = FormatFixtures.astc(picture: context.makeImage()!).data
            guard let source = CGImageSourceCreateWithData(texture as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { said.append("\(w)×\(h): not read"); continue }
            let pixels = RGBAPixels(image)
            let top = pixels.at(w / 2, 2).r, bottom = pixels.at(w / 2, h - 3).r
            said.append("\(w)×\(h): top \(top), bottom \(bottom): " + (top > 128 && bottom < 128 ? "from the top" : top < 128 && bottom > 128 ? "FROM THE BOTTOM" : "?"))
        }
        print(said.map { "astc rows: " + $0 }.joined(separator: "\n"))
        if let out = Self.snapshots {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try (said.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("results-astc-rows.txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Videos

    /// A frame of the video as the full view shows it: AVKit's (when
    /// AVFoundation plays it and it isn't one of VLC's formats), else
    /// VLC's picture as `VLCFrameOutput` hands it to the layer, converted
    /// by Core Image as the compositor converts it (its attachments).
    /// With the picture: the colour attachments it was shown with.
    private func fullVideoFrame(_ url: URL) async throws -> (CGImage?, String, [String: Any]) {
        let asset = AVURLAsset(url: url, options: VideoDetailView.assetOptions(for: url))
        var playable = false
        if !VideoDetailView.playsInVLC(url) { playable = (try? await asset.load(.isPlayable)) ?? false }
        if playable {
            // The pictures AVPlayer hands its layer: an AVPlayerItemVideoOutput
            // in the decoder's own format, with the colour attachments the layer shows them by
            let item = AVPlayerItem(asset: asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.play()
            var picture: CVPixelBuffer?
            let end = Date().addingTimeInterval(15)
            while Date() < end, picture == nil {
                try await Task.sleep(for: .milliseconds(40))
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                guard output.hasNewPixelBuffer(forItemTime: time),
                      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                      let image = Self.render(buffer), let n = ReferencePicture.frameNumber(in: image), n >= 5 else { continue }
                picture = buffer
            }
            player.pause()
            let attachments = picture.flatMap { CVBufferCopyAttachments($0, .shouldPropagate) as? [String: Any] } ?? [:]
            return (picture.flatMap(Self.render), "AVKit " + (picture.map(VLCFrameOutput.describe) ?? "no picture"), attachments)
        }
        let media = VLCMedia(url: url)
        VLCSafety.restrict(media, for: url, head: VLCSafety.head(of: url))
        for option in [":no-audio", ":no-osd", ":no-play-and-pause"] { media.addOption(option) }
        let player = VLCMediaPlayer()
        player.media = media
        let output = VLCFrameOutput()
        output.attach(to: player)
        player.play()
        var picture: CVPixelBuffer?
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(40))
            // A picture well into the video (frame 5 or later)
            if let latest = output.latestPicture, let image = Self.render(latest),
               let n = ReferencePicture.frameNumber(in: image), n >= 5 {
                picture = latest
                break
            }
        }
        let held = UncheckedPlayer(player: player)
        await Task.detached { held.player.stop() }.value
        let attachments = picture.flatMap { CVBufferCopyAttachments($0, .shouldPropagate) as? [String: Any] } ?? [:]
        return (picture.flatMap(Self.render), "VLC " + (picture.map(VLCFrameOutput.describe) ?? "no picture"), attachments)
    }

    private struct UncheckedPlayer: @unchecked Sendable { let player: VLCMediaPlayer }

    /// A picture as the screen shows a video of it: made YCbCr (BT.601,
    /// limited range, its colour halved as 4:2:0 halves it) with
    /// `attachments`, then shown as `render` shows a decoded picture.
    static func asShown(_ picture: CGImage, attachments: [String: Any]) -> CGImage {
        let p = RGBAPixels(picture)
        let w = p.width & ~1, h = p.height & ~1
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { return picture }
        CVPixelBufferLockBaseAddress(buffer, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let c = p.at(x, y)
            return (Double(c.r), Double(c.g), Double(c.b))
        }
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = rgb(x, y)
                let value: Double = 16 + 0.256788 * r + 0.504129 * g + 0.097906 * b
                luma[y * lumaRow + x] = clamp(value)
            }
        }
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                var r = 0.0, g = 0.0, b = 0.0
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let c = rgb(x + dx, y + dy)
                    r += c.0 / 4; g += c.1 / 4; b += c.2 / 4
                }
                let cb: Double = 128 - 0.148223 * r - 0.290993 * g + 0.439216 * b
                let cr: Double = 128 + 0.439216 * r - 0.367788 * g - 0.071427 * b
                chroma[y / 2 * chromaRow + x] = clamp(cb)
                chroma[y / 2 * chromaRow + x + 1] = clamp(cr)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachments(buffer, attachments as CFDictionary, .shouldPropagate)
        // The matrix the clips were made with (ffmpeg's for SD, BT.601), whatever the
        // player tagged: a player reading them with another shows wrong colours
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        return render(buffer) ?? picture
    }

    /// A picture buffer as the screen shows it: Core Image reads its
    /// matrix, range and colours from its attachments.
    static func render(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
            .createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// The video formats added lately, each a clip of the reference
    /// picture's frames: the tile and the full view each show a frame
    /// whose number they carry, compared with that frame.
    func testVideoFormatsLookRight() async throws {
        for ext in ["asf", "divx", "m2t", "m1v", "ogm", "insv", "360", "f4v", "rm", "rmvb", "mxf"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "visual", withExtension: ext, subdirectory: "Videos"), "visual.\(ext)")
            XCTAssertEqual(BrowserModel.mediaKind(of: url), .video, ext)
            let thumbnail = await thumbnail(url)
            let (full, player, attachments) = try await fullVideoFrame(url)
            let thumbFrame = thumbnail.flatMap(ReferencePicture.frameNumber(in:))
            let fullFrame = full.flatMap(ReferencePicture.frameNumber(in:))
            XCTAssertNotNil(thumbFrame, "\(ext): the tile's frame number can't be read")
            XCTAssertNotNil(fullFrame, "\(ext): the full view's frame number can't be read")
            // The full view: the frame as the screen shows a video of it decoded
            // exactly, with the colours it is tagged with (an untagged SD video's
            // primaries are SMPTE C's, which an sRGB screen shows a little
            // shifted, as QuickTime Player does); the tile: VLC's or QuickLook's
            // RGB, the frame as it is
            record(ext, reference: Self.asShown(ReferencePicture.image(frame: fullFrame ?? 0), attachments: attachments),
                   thumbnail: thumbnail, full: full,
                   thumbnailReference: ReferencePicture.image(frame: thumbFrame ?? 0), tolerance: .video,
                   extra: " \(player), tile frame \(thumbFrame.map(String.init) ?? "?"), full frame \(fullFrame.map(String.init) ?? "?")")
        }
        try writeSnapshots(group: "videos")
    }
}

private extension ReferencePicture.RGB {
    func channel(_ c: Int) -> UInt8 { c == 0 ? r : c == 1 ? g : b }
}
