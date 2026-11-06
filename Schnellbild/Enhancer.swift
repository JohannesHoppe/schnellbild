import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Automatic enhancement as a view filter: the files are never changed.
/// For a photo a recipe is worked out once and applied; videos follow their
/// scenes through `VideoEnhancer`.
///
/// 1. Exposure, both ways: dark material (mean luminance below 0.4) is
///    brightened with a gamma curve towards about 0.45, overexposed material
///    (above 0.62) darkened towards about 0.55; in between it stays as is.
/// 2. Core Image's automatic adjustments (tone curve, highlights/shadows,
///    vibrance, face balance) are worked out on the corrected picture.
/// 3. An unsharp mask makes edges crisper, like Photoshop's.
struct EnhanceRecipe: @unchecked Sendable {   // CIFilters are only copied, never shared while in use
    let gamma: Double?
    let adjustments: [CIFilter]
    let sharpenRadius: Double

    static let context = CIContext(options: [.cacheIntermediates: false])

    static func analyse(_ image: CIImage) -> EnhanceRecipe {
        let gamma = meanLuminance(of: image).flatMap(gammaFor(luminance:))
        let base = gamma.map { applyGamma($0, to: image) } ?? image
        let adjustments = base.autoAdjustmentFilters(options: [.redEye: false])
        // Scaled to the picture, so a 4K frame and a screen-sized photo look alike
        let side = max(image.extent.width, image.extent.height)
        return EnhanceRecipe(gamma: gamma, adjustments: adjustments, sharpenRadius: max(1, side / 900))
    }

    /// The gamma correction for a mean luminance (Core Image's power: < 1
    /// brightens, > 1 darkens). Dark: aims the mean at 0.45, never stronger
    /// than 0.35. Overexposed: aims it at 0.55, never stronger than 2.5.
    /// nil in between (0.4 … 0.62): well exposed, left alone.
    static func gammaFor(luminance: Double) -> Double? {
        if luminance < 0.4 { return min(max(log(0.45) / log(max(luminance, 0.02)), 0.35), 1) }
        if luminance > 0.62 { return max(min(log(0.55) / log(min(luminance, 0.98)), 2.5), 1) }
        return nil
    }

    /// Whether a gamma power changes anything.
    static func corrects(_ power: Double) -> Bool { abs(power - 1) > 0.001 }

    func apply(to image: CIImage) -> CIImage {
        var out = image
        if let gamma { out = Self.applyGamma(gamma, to: out) }
        for filter in adjustments {
            guard let copy = filter.copy() as? CIFilter else { continue }
            copy.setValue(out, forKey: kCIInputImageKey)
            if let result = copy.outputImage { out = result }
        }
        return Self.sharpen(out, radius: sharpenRadius).cropped(to: image.extent)
    }

    /// A still picture, enhanced.
    static func enhanced(_ picture: CGImage) -> CGImage? {
        let image = CIImage(cgImage: picture)
        return context.createCGImage(analyse(image).apply(to: image), from: image.extent)
    }

    /// A video composition that follows the video's scenes (`VideoEnhancer`).
    static func videoComposition(for asset: AVAsset) async -> AVVideoComposition? {
        let enhancer = VideoEnhancer()
        return try? await AVVideoComposition.videoComposition(with: asset) { request in
            enhancer.process(request)
        }
    }

    static func sharpen(_ image: CIImage, radius: Double) -> CIImage {
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = image
        sharpen.radius = Float(radius)
        sharpen.intensity = 0.6
        return sharpen.outputImage ?? image
    }

    static func applyGamma(_ power: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.gammaAdjust()
        filter.inputImage = image
        filter.power = Float(power)
        return filter.outputImage ?? image
    }

    /// Mean luminance (0 … 1) of the whole picture.
    static func meanLuminance(of image: CIImage) -> Double? {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        guard let pixel = average.outputImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(pixel, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])) / 255
    }
}

/// How strongly to correct a video's exposure (either way). It is measured now and then, not
/// for every frame (`VideoEnhancer` decides when), and glides towards the
/// measured value in between, so it follows the scenes without pumping. A
/// jump in time (seeking) or the first real picture takes the new value at
/// once. Black or white frames (a dark intro, a fade, a flash) are held.
struct AdaptiveExposure {
    private(set) var gamma = 1.0
    private var target = 1.0
    private var luminance: Double?

    /// Whether a real picture has been measured yet.
    var hasPicture: Bool { luminance != nil }

    /// One measurement of a frame's mean luminance. Returns whether it starts
    /// something new (first picture, a cut to a much brighter or darker
    /// scene), so the tone analysis should run again.
    mutating func measure(luminance measured: Double, instant: Bool) -> Bool {
        // Black or white (a dark intro, a fade, a flash): hold, don't chase it
        guard measured >= 0.03, measured <= 0.97 else { return false }
        let first = luminance == nil
        let cut = luminance.map { abs(measured - $0) > 0.2 } ?? false
        target = EnhanceRecipe.gammaFor(luminance: measured) ?? 1
        if instant || first { gamma = target }
        luminance = measured
        return first || cut
    }

    /// Between measurements: glide towards the last one (about 0.7 s).
    mutating func advance(by elapsed: Double) {
        gamma += (target - gamma) * (1 - exp(-max(elapsed, 0) / 0.7))
    }
}

/// Enhances a video frame by frame (AVKit, through a video composition).
/// The brightness is measured once a second (every frame only until the
/// first real picture), the tone and colour analysis (Core Image's automatic
/// adjustments) runs every 2 s; in between both glide to their new values,
/// so a short misjudgement corrects itself softly. After seeking both are
/// measured again at once.
final class VideoEnhancer: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var exposure = AdaptiveExposure()
    private var current: [CIFilter] = []
    private var target: [CIFilter] = []
    private var lastMeasure = -Double.infinity
    private var lastAnalysis = -Double.infinity
    private var lastFrame: Double?

    func process(_ request: AVAsynchronousCIImageFilteringRequest) {
        let source = request.sourceImage
        let time = request.compositionTime.seconds
        let side = max(source.extent.width, source.extent.height)

        lock.lock()
        defer { lock.unlock() }
        let jumped = lastFrame.map { time < $0 || time - $0 > 1 } ?? true
        let elapsed = jumped ? 0 : time - (lastFrame ?? time)
        lastFrame = time

        var fresh = false
        var small: CIImage?
        func thumbnail() -> CIImage {   // a small copy is enough to measure
            if let small { return small }
            let scale = min(1, 256 / max(side, 1))
            let made = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            small = made
            return made
        }
        if jumped || !exposure.hasPicture || time - lastMeasure >= 1 {
            let measured = EnhanceRecipe.meanLuminance(of: thumbnail()) ?? 0.5
            fresh = exposure.measure(luminance: measured, instant: jumped) || jumped
            lastMeasure = time
        } else {
            exposure.advance(by: elapsed)
        }
        let gamma = exposure.gamma
        if fresh || time - lastAnalysis >= 2 {
            let base = EnhanceRecipe.corrects(gamma) ? EnhanceRecipe.applyGamma(gamma, to: thumbnail()) : thumbnail()
            target = base.autoAdjustmentFilters(options: [.redEye: false])
            lastAnalysis = time
            if fresh { current = target.compactMap { $0.copy() as? CIFilter } }
        }
        current = Self.glide(current, towards: target, rate: fresh ? 1 : 1 - exp(-elapsed / 0.7))

        var out = EnhanceRecipe.corrects(gamma) ? EnhanceRecipe.applyGamma(gamma, to: source) : source
        for filter in current {
            filter.setValue(out, forKey: kCIInputImageKey)
            if let result = filter.outputImage { out = result }
        }
        out = EnhanceRecipe.sharpen(out, radius: max(1, side / 900))
        request.finish(with: out.cropped(to: source.extent), context: nil)
    }

    /// Moves each filter's numbers (and vectors, e.g. tone curve points) a
    /// part of the way to the target's. A filter new in the target starts
    /// at its target values.
    static func glide(_ current: [CIFilter], towards target: [CIFilter], rate: Double) -> [CIFilter] {
        target.compactMap { goal in
            guard let next = goal.copy() as? CIFilter else { return nil }
            guard let now = current.first(where: { $0.name == goal.name }) else { return next }
            for key in goal.inputKeys where key != kCIInputImageKey {
                switch (now.value(forKey: key), goal.value(forKey: key)) {
                case let (a as NSNumber, b as NSNumber):
                    next.setValue(a.doubleValue + (b.doubleValue - a.doubleValue) * rate, forKey: key)
                case let (a as CIVector, b as CIVector) where a.count == b.count:
                    let values = (0..<a.count).map { a.value(at: $0) + (b.value(at: $0) - a.value(at: $0)) * CGFloat(rate) }
                    next.setValue(CIVector(values: values, count: values.count), forKey: key)
                default:
                    break
                }
            }
            return next
        }
    }
}
