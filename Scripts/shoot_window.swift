// Photographs Schnellbild's window like ⌘⇧4 + Space does: with its shadow
// and rounded corners on a transparent background. Open sheets and menus are
// separate windows; they are drawn into the picture at their place.
// Usage: shoot_window <out.png>   (compiled by .github/workflows/screenshots.yml)
// Needs screen recording permission, which the GitHub macOS runners have.
import AppKit

struct Window { let id: Int; let bounds: CGRect; let layer: Int }

func appWindows() -> [Window] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard (info[kCGWindowOwnerName as String] as? String) == "Schnellbild",
              let id = info[kCGWindowNumber as String] as? Int,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        let bounds = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
        guard bounds.width > 40, bounds.height > 40 else { return nil }
        return Window(id: id, bounds: bounds, layer: info[kCGWindowLayer as String] as? Int ?? 0)
    }
}

/// `screencapture -l` of one window; with or without its shadow.
func capture(_ window: Window, shadow: Bool) -> CGImage? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("win-\(window.id)-\(UUID()).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x"] + (shadow ? [] : ["-o"]) + ["-l", String(window.id), file.path]
    try? task.run()
    task.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: file) }
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Where the window itself sits inside its shadowed picture: the first fully
/// opaque pixel along the middle row and column (the shadow is translucent).
func contentOrigin(of image: CGImage) -> CGPoint {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * w + x) * 4 + 3] }   // y from the top
    let left = (0..<w).first { alpha($0, h / 2) == 255 } ?? 0
    let top = (0..<h).first { alpha(w / 2, $0) == 255 } ?? 0
    return CGPoint(x: left, y: top)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let windows = appWindows()
guard let main = windows.filter({ $0.layer == 0 }).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
      let base = capture(main, shadow: true) else {
    FileHandle.standardError.write("No Schnellbild window\n".data(using: .utf8)!)
    exit(1)
}
// Pixels per point (1 on the runners' displays, 2 on Retina)
let pxPerPt = capture(main, shadow: false).map { CGFloat($0.width) / main.bounds.width } ?? 1
let origin = contentOrigin(of: base)

let W = base.width, H = base.height
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
// Sheets and menus on top, without their own shadow, at their place relative
// to the main window (CG coordinates: y up, so flip from the top-based bounds)
for other in windows where other.id != main.id {
    guard let image = capture(other, shadow: false) else { continue }
    let x = origin.x + (other.bounds.minX - main.bounds.minX) * pxPerPt
    let yTop = origin.y + (other.bounds.minY - main.bounds.minY) * pxPerPt
    let rect = CGRect(x: x, y: CGFloat(H) - yTop - CGFloat(image.height),
                      width: CGFloat(image.width), height: CGFloat(image.height))
    ctx.draw(image, in: rect)
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path) (\(windows.count) window(s))")
