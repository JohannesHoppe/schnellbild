// Draws the media fixtures the visual UI tests measure (UITests/Fixtures):
// an underexposed and an overexposed video and photo, an even grey video,
// a photo taken upright, red, green and blue bands, plus broken files.
// Always the same output, no external images.
//
//   swift Scripts/make_test_fixtures.swift UITests/Fixtures
import AVFoundation
import AppKit
import CoreImage
import ImageIO

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "UITests/Fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// A horizontal gradient from `low` to `high` grey with a warm patch in the
/// middle, so exposure, contrast and colour all have something to work on.
func frame(width: Int, height: Int, low: Double, high: Double) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<width {
        let v = low + (high - low) * Double(x) / Double(width - 1)
        ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v * 0.95, alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    let mid = (low + high) / 2
    ctx.setFillColor(CGColor(srgbRed: min(mid * 1.3, 1), green: mid, blue: mid * 0.7, alpha: 1))
    ctx.fill(CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3))
    return ctx.makeImage()!
}

func writeJPEG(_ image: CGImage, to name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
        .write(to: out.appendingPathComponent(name))
}

/// Three seconds of the same frame, H.264.
func writeVideo(_ image: CGImage, to name: String) throws {
    try writeVideo(width: image.width, height: image.height, frames: 30, fps: 10, to: name) { _ in image }
}

/// `frames` pictures at `fps`, H.264.
func writeVideo(width: Int, height: Int, frames: Int, fps: Int32, to name: String, frame picture: (Int) -> CGImage) throws {
    let url = out.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let context = CIContext()
    for i in 0..<frames {
        let image = picture(i)
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        context.render(CIImage(cgImage: image), to: buffer!, bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

let dark = frame(width: 640, height: 360, low: 0.03, high: 0.2)
let bright = frame(width: 640, height: 360, low: 0.82, high: 0.97)
try writeJPEG(dark, to: "dark.jpg")
try writeJPEG(bright, to: "bright.jpg")
// Larger than any screen: zooming in decodes it at full size
try writeJPEG(frame(width: 4000, height: 3000, low: 0.2, high: 0.8), to: "huge.jpg")
try writeVideo(dark, to: "dark.mp4")
try writeVideo(bright, to: "bright.mp4")
try writeVideo(frame(width: 640, height: 360, low: 0.5, high: 0.5), to: "grey.mp4")

// Dark left to bright right: zoom and pan move which part is where
let gradient = frame(width: 640, height: 360, low: 0.05, high: 0.95)
try writeJPEG(gradient, to: "gradient.jpg")
try writeVideo(gradient, to: "gradient.mp4")

// Taken with the camera upright: stored lying, dark on the left, with EXIF
// orientation 6 (turn a quarter clockwise), so it stands dark at the top
let lying = frame(width: 2400, height: 1350, low: 0.05, high: 0.95)
let uprightURL = out.appendingPathComponent("upright.jpg")
let upright = CGImageDestinationCreateWithURL(uprightURL as CFURL, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(upright, lying, [
    kCGImagePropertyOrientation: NSNumber(value: 6),
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: NSNumber(value: 6)],
    kCGImageDestinationLossyCompressionQuality: 0.9,
] as CFDictionary)
guard CGImageDestinationFinalize(upright) else { fatalError("upright.jpg") }

// Red, green and blue bands, left to right: do both players show the same colours?
let bands: CGImage = {
    let ctx = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colours = [(0.75, 0.2, 0.2), (0.2, 0.65, 0.25), (0.2, 0.3, 0.75)]
    for (i, c) in colours.enumerated() {
        ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fill(CGRect(x: i * 640 / 3, y: 0, width: 640 / 3 + 1, height: 360))
    }
    return ctx.makeImage()!
}()
try writeVideo(bands, to: "colours.mp4")

// 4K at 60 frames per second, a bar crossing the picture: does playback keep up?
let uhdBackground = frame(width: 3840, height: 2160, low: 0.2, high: 0.7)
try writeVideo(width: 3840, height: 2160, frames: 300, fps: 60, to: "uhd60.mp4") { i in
    let ctx = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(uhdBackground, in: CGRect(x: 0, y: 0, width: 3840, height: 2160))
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.9, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: (i * 12) % 3840, y: 0, width: 160, height: 2160))
    return ctx.makeImage()!
}

// Broken files: a media extension, but garbage inside (a fixed pattern).
let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
for name in ["broken.jpg", "broken.mp4", "broken.mkv"] {
    try garbage.write(to: out.appendingPathComponent(name))
}
print("fixtures written to \(out.path)")
