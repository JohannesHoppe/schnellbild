import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

// Writes the sample library the README screenshots show: photos and two
// short timelapse videos, drawn with CoreGraphics, the same on every run.
// Usage: swift Scripts/make_sample_media.swift <folder>
// (.github/workflows/screenshots.yml; UITests/ReadmeScreenshots.swift opens it)

/// Landscape pictures drawn with CoreGraphics:
/// sky gradient, sun or moon, layered mountain ridges fading into haze,
/// optional water, stars and aurora. Deterministic (seeded), no external
/// images, so the screenshots look the same on every run.
enum SampleScenes {
    struct Scene {
        var sky: [(CGFloat, CGFloat, CGFloat)]          // top → horizon
        var ridges: [(CGFloat, CGFloat, CGFloat)]       // far → near
        var sun: (x: CGFloat, y: CGFloat, r: CGFloat, color: (CGFloat, CGFloat, CGFloat))?
        var water = false
        var stars = false
        var aurora = false
        var seed: UInt64 = 1
        /// How far the sun sinks over a video (fraction of the height).
        var sunDrift: CGFloat = 0
    }

    static let fjord = Scene(sky: [(34, 24, 74), (196, 82, 122), (255, 176, 96)],
                             ridges: [(150, 86, 130), (98, 52, 104), (52, 28, 70)],
                             sun: (0.62, 0.55, 0.06, (255, 214, 140)), water: true, seed: 3)
    static let alpine = Scene(sky: [(74, 136, 222), (170, 208, 246), (246, 238, 222)],
                              ridges: [(166, 186, 214), (112, 136, 170), (64, 84, 112), (36, 52, 70)],
                              sun: (0.28, 0.78, 0.05, (255, 250, 230)), seed: 7)
    static let desert = Scene(sky: [(58, 40, 92), (228, 112, 82), (255, 204, 128)],
                              ridges: [(214, 126, 92), (172, 86, 64), (112, 52, 46)],
                              sun: (0.5, 0.3, 0.09, (255, 226, 160)), seed: 11)
    static let night = Scene(sky: [(4, 8, 28), (16, 34, 74), (36, 84, 104)],
                             ridges: [(28, 56, 74), (16, 36, 50), (6, 18, 28)],
                             sun: (0.78, 0.8, 0.03, (236, 240, 255)), water: true, stars: true, aurora: true, seed: 5)
    static let mist = Scene(sky: [(140, 168, 164), (196, 212, 202), (226, 232, 220)],
                            ridges: [(170, 190, 178), (122, 152, 132), (74, 108, 84), (38, 66, 48)],
                            seed: 13)
    static let blueHour = Scene(sky: [(18, 36, 96), (66, 96, 168), (222, 150, 168)],
                                ridges: [(84, 82, 140), (50, 50, 100), (24, 26, 58)],
                                water: true, stars: true, seed: 17)
    static let golden = Scene(sky: [(110, 162, 226), (198, 210, 216), (250, 208, 138)],
                              ridges: [(190, 168, 112), (140, 132, 72), (86, 90, 44), (46, 54, 26)],
                              sun: (0.82, 0.36, 0.06, (255, 236, 180)), seed: 19)
    static let lagoon = Scene(sky: [(250, 118, 92), (255, 160, 110), (255, 214, 150)],
                              ridges: [(206, 96, 96), (128, 54, 76)],
                              sun: (0.4, 0.54, 0.07, (255, 240, 190)), water: true, seed: 23)

    /// The folder the screenshots show: a few trips as subfolders, loose
    /// pictures next to them. Each picture carries a capture date (EXIF
    /// DateTimeOriginal), so the list view's "Date Taken" column has values.
    static let library: [(path: String, taken: String, scene: Scene)] = [
        ("Lofoten/Sunset over Reine.jpg", "2026:02:14 16:42:08", fjord),
        ("Lofoten/Northern Lights.jpg", "2026:02:14 22:17:35", night),
        ("Lofoten/Blue Hour Harbour.jpg", "2026:02:15 08:51:12", blueHour),
        ("Dolomites/Alpine Morning.jpg", "2025:07:22 06:34:50", alpine),
        ("Dolomites/Golden Ridge.jpg", "2025:07:22 19:58:03", golden),
        ("Dolomites/Misty Valley.jpg", "2025:07:23 07:12:44", mist),
        ("Sahara/Desert Dusk.jpg", "2025:11:03 18:05:21", desert),
        ("Sahara/Sunset over the Dunes.jpg", "2025:11:04 17:49:37", with(desert, seed: 29)),
        ("Fjord at Sunset.jpg", "2024:06:18 22:31:09", with(fjord, seed: 31)),
        ("Lagoon Sunset.jpg", "2024:09:02 19:44:56", lagoon),
        ("Blue Hour.jpg", "2025:01:11 17:02:18", with(blueHour, seed: 37)),
        ("Morning Mist.jpg", "2024:10:27 07:26:40", with(mist, seed: 41)),
        ("Golden Valley.jpg", "2025:05:09 20:13:27", with(golden, seed: 43)),
        ("Aurora.jpg", "2024:03:08 23:48:15", with(night, seed: 47)),
        ("Alpine Lake.jpg", "2025:08:16 10:05:33", { var s = alpine; s.water = true; s.seed = 53; return s }()),
        ("Red Rocks.jpg", "2024:04:21 18:37:02", with(desert, seed: 59)),
    ]

    static func with(_ scene: Scene, seed: UInt64) -> Scene { var s = scene; s.seed = seed; return s }

    /// Timelapse videos: 6 s, 1280×720, 30 fps.
    static let videos: [(path: String, scene: Scene)] = [
        ("Sunset Timelapse.mp4", { var s = fjord; s.sunDrift = 0.32; s.seed = 61; return s }()),
        ("Lofoten/Aurora Timelapse.mp4", with(night, seed: 67)),
    ]

    static func writeLibrary(to folder: URL) async throws {
        for (path, taken, scene) in library {
            let url = try prepare(path, in: folder)
            try writeJPEG(render(scene), taken: taken, to: url)
        }
        for (path, scene) in videos {
            try await writeVideo(scene, to: try prepare(path, in: folder))
        }
    }

    private static func prepare(_ path: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    static func writeVideo(_ scene: Scene, to url: URL, seconds: Int = 6, fps: Int32 = 30) async throws {
        let width = 1280, height = 720
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = seconds * Int(fps)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let image = render(scene, width: width, height: height, time: CGFloat(frame) / CGFloat(frames - 1))
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    // MARK: Drawing

    private struct RNG {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 11) / CGFloat(1 << 53)
        }
    }

    private static func color(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor {
        CGColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: a)
    }

    /// `time` (0 … 1) animates a video frame: the sun sinks by `sunDrift`,
    /// the aurora waves move.
    static func render(_ scene: Scene, width: Int = 2400, height: Int = 1600, time: CGFloat = 0) -> CGImage {
        var scene = scene
        if let sun = scene.sun { scene.sun = (sun.x, sun.y - scene.sunDrift * time, sun.r, sun.color) }
        let W = CGFloat(width), H = CGFloat(height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = RNG(state: scene.seed &* 2654435761 &+ 1)
        let horizon = scene.water ? H * 0.34 : 0   // y counts up from the bottom

        // Sky
        let sky = CGGradient(colorsSpace: cs, colors: scene.sky.map { color($0) } as CFArray,
                             locations: nil)!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])

        if scene.stars {
            for _ in 0..<420 {
                let p = CGPoint(x: rng.next() * W, y: H * 0.45 + rng.next() * H * 0.55)
                let r = 0.8 + rng.next() * 2.2
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.35 + rng.next() * 0.6))
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }

        if scene.aurora {
            ctx.saveGState()
            ctx.setBlendMode(.screen)
            for band in 0..<5 {
                let path = CGMutablePath()
                let base = H * (0.62 + CGFloat(band) * 0.045)
                let phase = rng.next() * 6 + time * 4
                path.move(to: CGPoint(x: 0, y: base))
                for x in stride(from: CGFloat(0), through: W, by: 12) {
                    path.addLine(to: CGPoint(x: x, y: base + sin(x / W * 5 + phase) * H * 0.07))
                }
                ctx.addPath(path)
                ctx.setLineWidth(H * 0.05)
                ctx.setLineCap(.round)
                ctx.setShadow(offset: .zero, blur: H * 0.06, color: color((60, 255, 170), 0.8))
                ctx.setStrokeColor(color((70, 230, 160), 0.16))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        if let sun = scene.sun {
            let c = CGPoint(x: W * sun.x, y: H * sun.y), r = H * sun.r
            let glow = CGGradient(colorsSpace: cs, colors: [color(sun.color, 0.55), color(sun.color, 0)] as CFArray,
                                  locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: c, startRadius: r, endCenter: c, endRadius: r * 6, options: [])
            ctx.setFillColor(color(sun.color))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }

        // Ridges: far ones higher and hazier, near ones lower and darker
        let count = scene.ridges.count
        for (i, tone) in scene.ridges.enumerated() {
            let t = CGFloat(i) / CGFloat(max(count - 1, 1))
            let base = scene.water ? horizon + H * (0.13 - 0.08 * t) : H * (0.36 - 0.2 * t)
            let amp = H * (scene.water ? 0.05 + 0.03 * (1 - t) : 0.07 + 0.04 * (1 - t))
            var waves: [(a: CGFloat, f: CGFloat, p: CGFloat)] = []
            for k in 1...3 { waves.append((amp / CGFloat(k) * (0.6 + rng.next() * 0.8), CGFloat(k) * (1 + rng.next() * 1.4), rng.next() * 6)) }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: horizon))
            for x in stride(from: CGFloat(0), through: W, by: 6) {
                let u = x / W * .pi * 2
                var y = base
                for w in waves { y += w.a * sin(u * w.f + w.p) }
                path.addLine(to: CGPoint(x: x, y: max(y, horizon)))
            }
            path.addLine(to: CGPoint(x: W, y: horizon))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color(tone))
            ctx.fillPath()
        }

        if scene.water {
            // Mirror the sky band above the horizon, darkened
            // (image rows count from the top, the context's y from the bottom)
            let h = Int(horizon)
            if let image = ctx.makeImage(),
               let band = image.cropping(to: CGRect(x: 0, y: height - 2 * h, width: width, height: h)) {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: horizon)
                ctx.scaleBy(x: 1, y: -1)
                ctx.setAlpha(0.8)
                ctx.draw(band, in: CGRect(x: 0, y: 0, width: W, height: horizon))
                ctx.restoreGState()
            }
            let shade = CGGradient(colorsSpace: cs, colors: [color((0, 0, 20), 0.15), color((0, 0, 20), 0.55)] as CFArray,
                                   locations: [0, 1])!
            ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: horizon), end: .zero, options: [])
            if let sun = scene.sun {
                // Soft glow on the water below the sun, stretched downwards
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: horizon))
                ctx.translateBy(x: W * sun.x, y: horizon)
                ctx.scaleBy(x: 1, y: 3)
                let glow = CGGradient(colorsSpace: cs, colors: [color(sun.color, 0.45), color(sun.color, 0)] as CFArray,
                                      locations: [0, 1])!
                ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                       endRadius: H * sun.r * 1.6, options: [])
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()!
    }

    /// `taken` is the EXIF form "yyyy:MM:dd HH:mm:ss" (local time, no offset).
    static func writeJPEG(_ image: CGImage, taken: String, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.88,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: taken,
                kCGImagePropertyExifDateTimeDigitized: taken,
            ],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

let target = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Photos", isDirectory: true)
try await SampleScenes.writeLibrary(to: target)
print("Wrote \(SampleScenes.library.count) pictures and \(SampleScenes.videos.count) videos to \(target.path)")
