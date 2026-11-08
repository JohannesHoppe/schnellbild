import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// How a photo or video is shown: four settings, all 0 = the file as it is.
/// A view filter; the files are never changed. Auto enhance works out these
/// same values from the picture (`Look.auto`), so the sliders show what it
/// does and carry on from there when moved by hand.
struct Look: Equatable, Sendable {
    /// −1 … 1: darker … brighter, through the mid-tones (a gamma curve).
    var exposure = 0.0
    /// −1 … 1: flatter … punchier.
    var contrast = 0.0
    /// −1 … 1: black and white … vivid.
    var saturation = 0.0
    /// 0 … 1: an unsharp mask, from off to strong.
    var sharpness = 0.0

    static let neutral = Look()
    var isNeutral: Bool { self == .neutral }

    /// Core Image's gamma power for the exposure (< 1 brightens, > 1
    /// darkens): at most 0.35 one way and 4 the other.
    var gammaPower: Double { exposure >= 0 ? pow(0.35, exposure) : pow(4, -exposure) }
    static func exposure(forGammaPower power: Double) -> Double {
        power <= 1 ? log(power) / log(0.35) : -log(power) / log(4)
    }
    var contrastFactor: Double { 1 + 0.6 * contrast }
    var saturationFactor: Double { 1 + saturation }

    /// The filters work on sRGB-encoded values, the scale `PictureStats`
    /// measures on (Core Image works in linear light otherwise, where a
    /// contrast pivot of 0.5 is a light grey and darkens the mid-tones).
    func apply(to image: CIImage) -> CIImage {
        guard !isNeutral else { return image }
        var out = image.applyingFilter("CILinearToSRGBToneCurve")
        if abs(gammaPower - 1) > 0.001 {
            let gamma = CIFilter.gammaAdjust()
            gamma.inputImage = out
            gamma.power = Float(gammaPower)
            out = gamma.outputImage ?? out
        }
        if contrast != 0 || saturation != 0 {
            let colour = CIFilter.colorControls()
            colour.inputImage = out
            colour.contrast = Float(contrastFactor)
            colour.saturation = Float(saturationFactor)
            out = colour.outputImage ?? out
        }
        if sharpness > 0 {
            // Scaled to the picture, so a 4K frame and a screen-sized photo look alike
            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = out
            sharpen.radius = Float(max(1, max(image.extent.width, image.extent.height) / 900))
            sharpen.intensity = Float(1.2 * sharpness)
            out = sharpen.outputImage ?? out
        }
        return out.applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }

    /// Part of the way to `target` (0 … 1).
    func glided(towards target: Look, rate: Double) -> Look {
        func step(_ a: Double, _ b: Double) -> Double { a + (b - a) * rate }
        return Look(exposure: step(exposure, target.exposure), contrast: step(contrast, target.contrast),
                    saturation: step(saturation, target.saturation), sharpness: step(sharpness, target.sharpness))
    }

    /// What auto enhance sets for a picture:
    /// - Exposure, both ways: dark material (mean luminance below 0.4) is
    ///   brightened towards about 0.45, overexposed material (above 0.62)
    ///   darkened towards about 0.55; in between it stays as is.
    /// - Contrast: a flat picture (its darkest and brightest 2 % close
    ///   together) is stretched, a harsh one softened a little.
    /// - Saturation: washed-out colours are lifted, garish ones calmed;
    ///   black and white stays black and white.
    /// - A moderate unsharp mask.
    static func auto(for stats: PictureStats) -> Look {
        var look = Look(sharpness: 0.5)
        let power = gammaFor(luminance: stats.mean) ?? 1
        look.exposure = exposure(forGammaPower: power)
        let spread = pow(stats.high, power) - pow(stats.low, power)
        if spread > 0.01 {
            look.contrast = min(max((0.8 / spread - 1) / 0.6, -0.15), 1)
        }
        // Contrast spreads the colours as well
        let chroma = stats.chroma * look.contrastFactor
        if stats.chroma > 0.03 {
            look.saturation = min(max((0.2 / chroma - 1) * 0.5, -0.3), 0.35)
        }
        return look
    }

    /// The gamma correction for a mean luminance (Core Image's power: < 1
    /// brightens, > 1 darkens). Dark: aims the mean at 0.45, never stronger
    /// than 0.35. Overexposed: aims it at 0.55, never stronger than 4.
    /// nil in between (0.4 … 0.62): well exposed, left alone.
    static func gammaFor(luminance: Double) -> Double? {
        if luminance < 0.4 { return min(max(log(0.45) / log(max(luminance, 0.02)), 0.35), 1) }
        if luminance > 0.62 { return max(min(log(0.55) / log(min(luminance, 0.98)), 4), 1) }
        return nil
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// A still picture with a look.
    static func render(_ picture: CGImage, with look: Look) -> CGImage? {
        let image = CIImage(cgImage: picture)
        return context.createCGImage(look.apply(to: image), from: image.extent)
    }
}

/// What auto enhance measures in a picture (all 0 … 1): mean luminance, the
/// luminance below which the darkest 2 % lie and above which the brightest
/// 2 %, and the mean colourfulness (largest minus smallest channel).
struct PictureStats: Equatable, Sendable {
    var mean: Double
    var low: Double
    var high: Double
    var chroma: Double

    /// Measured on a copy at most 128 pixels wide.
    static func of(_ image: CIImage) -> PictureStats? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        let scale = min(1, 128 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                                        .scaledBy(x: scale, y: scale))
        let width = max(Int(extent.width * scale), 1), height = max(Int(extent.height * scale), 1)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        Look.context.render(small, toBitmap: &rgba, rowBytes: width * 4,
                            bounds: CGRect(x: 0, y: 0, width: width, height: height),
                            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var histogram = [Int](repeating: 0, count: 256)
        var sum = 0.0, chroma = 0.0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let r = Double(rgba[i]), g = Double(rgba[i + 1]), b = Double(rgba[i + 2])
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sum += y
            histogram[min(Int(y.rounded()), 255)] += 1
            chroma += max(r, g, b) - min(r, g, b)
        }
        let count = width * height
        func percentile(_ p: Double) -> Double {
            let goal = Int(Double(count) * p)
            var seen = 0
            for (level, n) in histogram.enumerated() {
                seen += n
                if seen > goal { return Double(level) / 255 }
            }
            return 1
        }
        return PictureStats(mean: sum / Double(count) / 255, low: percentile(0.02), high: percentile(0.98),
                            chroma: chroma / Double(count) / 255)
    }
}

/// What the player shows: the file as it is, auto enhance, or settings by hand.
enum Enhancement: Equatable, Sendable {
    case off
    case auto
    case manual(Look)
}

/// Auto enhance for a video: measured now and then, not for every frame
/// (the players decide when), gliding towards the measured look in between,
/// so it follows the scenes without pumping. A jump in time (seeking) or the
/// first real picture takes the new look at once. Black or white frames (a
/// dark intro, a fade, a flash) are held.
struct AdaptiveLook {
    private(set) var look = Look.neutral
    private var target = Look.neutral
    private var luminance: Double?

    /// Whether a real picture has been measured yet.
    var hasPicture: Bool { luminance != nil }

    mutating func measure(_ stats: PictureStats, instant: Bool) {
        guard stats.mean >= 0.03, stats.mean <= 0.97 else { return }
        target = Look.auto(for: stats)
        if instant || luminance == nil { look = target }
        luminance = stats.mean
    }

    /// Between measurements: glide towards the last one (about 0.7 s).
    mutating func advance(by elapsed: Double) {
        look = look.glided(towards: target, rate: 1 - exp(-max(elapsed, 0) / 0.7))
    }
}

/// Filters an AVKit video frame by frame through a video composition: either
/// a fixed look (by hand) or auto enhance, measured once a second (every
/// frame until the first real picture, and at once after seeking). Auto
/// reports its current look about four times a second, for the sliders.
final class VideoEnhancer: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var mode = Enhancement.off
    private var adaptive = AdaptiveLook()
    private var lastMeasure = -Double.infinity
    private var lastFrame: Double?
    private var lastReport = Date.distantPast
    private var drawnMode = Enhancement.off
    private let report: @Sendable (Look) -> Void

    init(report: @escaping @Sendable (Look) -> Void) { self.report = report }

    func set(_ mode: Enhancement) {
        lock.lock()
        self.mode = mode
        // Off takes the composition away: frames are drawn as they are
        if mode == .off { drawnMode = .off }
        lastMeasure = -.infinity   // auto again: measure at once
        lock.unlock()
    }

    /// Whether the last frame was drawn in another mode than the current
    /// one (a look set after the last frame, e.g. just before the end).
    var isStale: Bool {
        lock.lock()
        defer { lock.unlock() }
        return drawnMode != mode
    }

    func process(_ request: AVAsynchronousCIImageFilteringRequest) {
        let source = request.sourceImage
        let time = request.compositionTime.seconds

        // Decide under the lock, measure outside it (a GPU render and read
        // back), so `set` from the main thread never waits for a measurement.
        lock.lock()
        let auto = mode == .auto
        let changed = drawnMode != mode
        drawnMode = mode
        let jumped = lastFrame.map { time < $0 || time - $0 > 1 } ?? true
        let elapsed = jumped ? 0 : time - (lastFrame ?? time)
        let measure = auto && (jumped || !adaptive.hasPicture || time - lastMeasure >= 1)
        if measure { lastMeasure = time }
        lastFrame = time
        lock.unlock()

        let stats = measure ? PictureStats.of(source) : nil

        lock.lock()
        let look: Look
        var toReport: Look?
        switch mode {
        case .off:
            look = .neutral
        case .manual(let manual):
            look = manual
        case .auto:
            if let stats { adaptive.measure(stats, instant: jumped) } else if !measure { adaptive.advance(by: elapsed) }
            look = adaptive.look
            if Date().timeIntervalSince(lastReport) >= 0.25 {
                lastReport = Date()
                toReport = look
            }
        }
        lock.unlock()

        if let toReport { report(toReport) }
        if changed { BrowserModel.testLog("avkit frame at \(time) drawn with \(look)") }
        request.finish(with: look.apply(to: source), context: nil)
    }
}
