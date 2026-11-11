import AVFoundation
import AppKit
import MediaToolbox
import VideoToolbox

// Opens the given videos through AVFoundation, opted in to Media Extension
// format readers (as Quick Look and QuickTime Player are), and with
// SPIKE_FRAMES set writes a frame of each there as PNG.

@main
struct SpikeHost {
    static func main() async {
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        let frames = ProcessInfo.processInfo.environment["SPIKE_FRAMES"]
        for path in CommandLine.arguments.dropFirst() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            do {
                let tracks = try await asset.load(.tracks)
                let duration = try await asset.load(.duration)
                print("\(path): \(tracks.count) tracks, \(String(format: "%.2f", duration.seconds)) s")
                guard let frames else { continue }
                let generator = AVAssetImageGenerator(asset: asset)
                let (image, time) = try await generator.image(at: CMTime(seconds: duration.seconds / 2, preferredTimescale: 600))
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                let out = URL(fileURLWithPath: frames).appendingPathComponent("frame-" + URL(fileURLWithPath: path).lastPathComponent + ".png")
                try png?.write(to: out)
                print("  frame \(image.width)×\(image.height) at \(String(format: "%.2f", time.seconds)) s → \(out.lastPathComponent)")
            } catch {
                print("\(path): \(error)")
            }
        }
    }
}
