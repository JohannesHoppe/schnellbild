// Mean luminance (0 … 1, sRGB-encoded values) of a PNG and its standard
// deviation (how even the area is), for the visual UI tests: the CI shell
// captures part of the screen with `screencapture` and answers the test with
// these numbers (see .github/workflows/ci.yml).
//
//   measure_brightness picture.png   →   0.4612 0.0031
import AppKit

guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("-1 -1")
    exit(1)
}
let width = cg.width, height = cg.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
var sum = 0.0, squares = 0.0
for i in stride(from: 0, to: pixels.count, by: 4) {
    let y = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
    sum += y
    squares += y * y
}
let count = Double(width * height)
let mean = sum / count
print(String(format: "%.4f %.4f", mean, max(squares / count - mean * mean, 0).squareRoot()))
