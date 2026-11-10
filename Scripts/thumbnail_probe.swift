// Asks QuickLook for a file's thumbnail, as Finder and Schnellbild's grid do,
// and prints its kind, size and how long it took. Exits 1 without a thumbnail.
// Usage: swift Scripts/thumbnail_probe.swift <file> [<png to write>]
import AppKit
import QuickLookThumbnailing

let file = URL(fileURLWithPath: CommandLine.arguments[1])
let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 256, height: 256),
                                           scale: 2, representationTypes: .thumbnail)
let start = Date()
let done = DispatchSemaphore(value: 0)
var ok = false
QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
    let seconds = String(format: "%.3f", Date().timeIntervalSince(start))
    if let rep, rep.type == .thumbnail {
        ok = true
        print("\(file.lastPathComponent): thumbnail \(rep.cgImage.width)×\(rep.cgImage.height) in \(seconds) s")
        if CommandLine.arguments.count > 2 {
            let png = NSBitmapImageRep(cgImage: rep.cgImage).representation(using: .png, properties: [:])
            try? png?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    } else {
        print("\(file.lastPathComponent): no thumbnail after \(seconds) s (\(error?.localizedDescription ?? "only an icon"))")
    }
    done.signal()
}
done.wait()
exit(ok ? 0 : 1)
