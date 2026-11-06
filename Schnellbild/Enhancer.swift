import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Automatic enhancement as a view filter: the files are never changed.
/// A recipe is worked out once from a picture (for a video: from one frame)
/// and then applied as is, so a video doesn't flicker as each frame would
/// otherwise get its own correction.
///
/// 1. Dark material (mean luminance below 0.4) is brightened with a gamma
///    curve towards a mean of about 0.45.
/// 2. Core Image's automatic adjustments (tone curve, highlights/shadows,
///    vibrance, face balance) are worked out on the brightened picture.
/// 3. An unsharp mask makes edges crisper, like Photoshop's.
struct EnhanceRecipe: @unchecked Sendable {   // CIFilters are only copied, never shared while in use
    let gamma: Double?
    let adjustments: [CIFilter]
    let sharpenRadius: Double

    static let context = CIContext(options: [.cacheIntermediates: false])

    static func analyse(_ image: CIImage) -> EnhanceRecipe {
        var gamma: Double?
        if let luminance = meanLuminance(of: image), luminance < 0.4 {
            // power < 1 brightens; aims the mean at 0.45, never more than ×~3
            gamma = min(max(log(0.45) / log(max(luminance, 0.02)), 0.35), 1)
        }
        let base = gamma.map { applyGamma($0, to: image) } ?? image
        let adjustments = base.autoAdjustmentFilters(options: [.redEye: false])
        // Scaled to the picture, so a 4K frame and a screen-sized photo look alike
        let side = max(image.extent.width, image.extent.height)
        return EnhanceRecipe(gamma: gamma, adjustments: adjustments, sharpenRadius: max(1, side / 900))
    }

    func apply(to image: CIImage) -> CIImage {
        var out = image
        if let gamma { out = Self.applyGamma(gamma, to: out) }
        for filter in adjustments {
            guard let copy = filter.copy() as? CIFilter else { continue }
            copy.setValue(out, forKey: kCIInputImageKey)
            if let result = copy.outputImage { out = result }
        }
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = out
        sharpen.radius = Float(sharpenRadius)
        sharpen.intensity = 0.6
        return (sharpen.outputImage ?? out).cropped(to: image.extent)
    }

    /// A still picture, enhanced.
    static func enhanced(_ picture: CGImage) -> CGImage? {
        let image = CIImage(cgImage: picture)
        return context.createCGImage(analyse(image).apply(to: image), from: image.extent)
    }

    /// A video composition applying one recipe, worked out from the frame at
    /// a tenth of the video (the very first frame is often black).
    static func videoComposition(for asset: AVAsset) async -> AVVideoComposition? {
        guard let duration = try? await asset.load(.duration) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let at = CMTimeMultiplyByFloat64(duration, multiplier: 0.1)
        guard let frame = try? await generator.image(at: at).image else { return nil }
        let recipe = analyse(CIImage(cgImage: frame))
        return try? await AVVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            request.finish(with: recipe.apply(to: source.clampedToExtent()).cropped(to: source.extent), context: nil)
        }
    }

    private static func applyGamma(_ power: Double, to image: CIImage) -> CIImage {
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
