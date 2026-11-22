// Writes the reference picture's video frames (Tests/SchnellbildTests/
// ReferencePicture.swift: frame n with its marker and number) as PNGs,
// frame-00.png … into the folder given, for make_video_fixtures.sh visual.
// Built together with ReferencePicture.swift:
//   swiftc -parse-as-library Tests/SchnellbildTests/ReferencePicture.swift Scripts/reference_frames.swift -o <tool>
//   <tool> <folder> <frames>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
enum ReferenceFrames {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let count = Int(arguments[2]), count > 0, count < 100 else {
            FileHandle.standardError.write(Data("usage: reference_frames <folder> <frames>\n".utf8))
            exit(2)
        }
        let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
        for n in 0..<count {
            let url = folder.appendingPathComponent(String(format: "frame-%02d.png", n))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
            CGImageDestinationAddImage(destination, ReferencePicture.image(frame: n), nil)
            guard CGImageDestinationFinalize(destination) else { exit(1) }
        }
    }
}
