// Converts the globe's pictures with ImageIO (called by Scripts/build_globe_data.py):
//
//   swift Scripts/convert_globe_images.swift sky <starmap.exr> <out.jpg>
//       NASA SVS's star map (HDR, linear, equirectangular in right ascension and
//       declination) tone-mapped to an 8-bit sRGB JPEG of the same size: scaled
//       so the 99.95th percentile of the brightness is white, then a soft
//       shoulder above it.
//   swift Scripts/convert_globe_images.swift lights <blackmarble.jpg> <out.jpg> <width>
//       NASA's Black Marble (grey) resized to <width> × <width>/2, grey JPEG.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("!! " + message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(path)") }
    return image
}

func save(_ image: CGImage, _ path: String, quality: Double) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { fail("can't write \(path)") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(path)") }
}

let args = CommandLine.arguments
guard args.count >= 4 else { fail("usage: sky <in.exr> <out.jpg> | lights <in.jpg> <out.jpg> <width>") }

switch args[1] {
case "sky":
    let image = load(args[2])
    let w = image.width, h = image.height
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: linear,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { fail("no float context") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let pixels = ctx.data!.bindMemory(to: Float.self, capacity: w * h * 4)
    var luminance = [Float](repeating: 0, count: w * h)
    for k in 0..<(w * h) {
        luminance[k] = 0.2126 * max(0, pixels[k * 4]) + 0.7152 * max(0, pixels[k * 4 + 1]) + 0.0722 * max(0, pixels[k * 4 + 2])
    }
    let sorted = luminance.sorted()
    let white = max(1e-6, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9995))])
    print("sky \(w)×\(h): median \(sorted[sorted.count / 2]), 99.95 % \(white), max \(sorted.last!)")
    var out = [UInt8](repeating: 0, count: w * h * 4)
    func encode(_ v: Float) -> UInt8 {
        // Linear up to 0.8, then a shoulder towards 1; sRGB-encoded
        var x = max(0, v)
        if x > 0.8 { x = 0.8 + 0.2 * (1 - exp(-(x - 0.8) / 0.2)) }
        let s = x <= 0.003_130_8 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }
    for k in 0..<(w * h) {
        out[k * 4] = encode(pixels[k * 4] / white)
        out[k * 4 + 1] = encode(pixels[k * 4 + 1] / white)
        out[k * 4 + 2] = encode(pixels[k * 4 + 2] / white)
        out[k * 4 + 3] = 255
    }
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let outCtx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let result = outCtx.makeImage() else { fail("no output") }
    save(result, args[3], quality: 0.9)
case "lights":
    guard args.count >= 5, let width = Int(args[4]), width > 0 else { fail("lights needs a width") }
    let image = load(args[2])
    let height = width / 2
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { fail("no grey context") }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = ctx.makeImage() else { fail("no output") }
    print("lights \(image.width)×\(image.height) → \(width)×\(height)")
    save(result, args[3], quality: 0.9)
default:
    fail("unknown command \(args[1])")
}
