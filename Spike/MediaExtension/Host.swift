import AVFoundation
import MediaToolbox

// Opens the given videos through AVFoundation, opted in to Media Extension
// format readers (as Quick Look and QuickTime Player are).

@main
struct SpikeHost {
    static func main() async {
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        for path in CommandLine.arguments.dropFirst() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            do {
                let tracks = try await asset.load(.tracks)
                print("\(path): \(tracks.count) tracks")
            } catch {
                print("\(path): \(error)")
            }
        }
    }
}
