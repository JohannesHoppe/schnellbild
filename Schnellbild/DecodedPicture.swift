import Foundation
import CoreGraphics

/// A picture decoded by the app's own decoders: RGBA, 8 bits a sample,
/// not premultiplied, rows from the top. Made only within the limits.
struct DecodedPicture {
    /// The most pixels decoded (as the full view's largest decode).
    static let largestPixels = 64_000_000
    /// The longest side (the formats' own fields allow more).
    static let largestSide = 65_535

    static func fits(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= largestSide && height <= largestSide && width * height <= largestPixels
    }

    let width: Int
    let height: Int
    let hasAlpha: Bool
    /// Linear light (QOI's colour space 1), else sRGB.
    let linear: Bool
    var pixels: [UInt8]

    /// All pixels transparent black; only for sizes that `fits`.
    init(width: Int, height: Int, hasAlpha: Bool, linear: Bool) {
        precondition(Self.fits(width: width, height: height))
        self.width = width
        self.height = height
        self.hasAlpha = hasAlpha
        self.linear = linear
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// `body` with the picture as a CGImage drawn straight from `pixels`
    /// (no copy of them: at 64 Mpx that would be another 256 MB); the image
    /// is valid only inside `body`, which must not keep it.
    func withImage<T>(_ body: (CGImage) -> T?) -> T? {
        guard let space = CGColorSpace(name: linear ? CGColorSpace.linearSRGB : CGColorSpace.sRGB) else { return nil }
        let alpha: CGImageAlphaInfo = hasAlpha ? .last : .noneSkipLast
        return pixels.withUnsafeBytes { bytes -> T? in
            guard let base = bytes.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: base, size: bytes.count, releaseData: { _, _, _ in }),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                                      decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return body(image)
        }
    }
}
