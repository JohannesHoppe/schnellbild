// Makes the Mac App Store screenshots (2880 × 1800, 16:10) from the README's
// window shots (docs/screenshots): each shot, with its shadow, centred on a
// calm background.
//
//   swift Scripts/make_store_screenshots.swift <out dir> <shot.png> …
import AppKit
import CoreGraphics

let args = CommandLine.arguments.dropFirst()
guard let outDir = args.first, args.count > 1 else {
    FileHandle.standardError.write("usage: make_store_screenshots.swift <out dir> <shot.png> …\n".data(using: .utf8)!)
    exit(2)
}
let width = 2880, height = 1800
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for path in args.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let shot = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("!! can't read \(path)"); exit(1) }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    // A soft vertical gradient, light grey to a little darker
    let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1),
                                                           CGColor(srgbRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
    // The shot as large as fits with a margin, never enlarged past twice its size
    let margin = 0.06
    let scale = min(Double(width) * (1 - 2 * margin) / Double(shot.width),
                    Double(height) * (1 - 2 * margin) / Double(shot.height), 2)
    let w = Double(shot.width) * scale, h = Double(shot.height) * scale
    context.interpolationQuality = .high
    context.draw(shot, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
    let name = (path as NSString).lastPathComponent
    let out = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    // Opaque: App Store Connect takes no transparency
    let opaque = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    opaque.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    CGImageDestinationAddImage(destination, opaque.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { print("!! can't write \(out.path)"); exit(1) }
    print("==> \(out.path) (\(Int(w))×\(Int(h)) on \(width)×\(height))")
}
