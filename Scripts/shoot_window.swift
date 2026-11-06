// Photographs Schnellbild's window like ⌘⇧4 + Space does: with its shadow and
// rounded corners on a transparent background, including an open sheet or
// menu. The pictures come from `screencapture`, run by the shell (the
// permission to record the screen belongs to the runner's shell, not to
// programs it starts). Compiled by .github/workflows/screenshots.yml:
//   shoot_window window              prints "<id> <x>,<y>,<w>,<h>" of the main window
//   shoot_window compose <out> <dir> from <dir>/shadow.png (screencapture -l),
//                                    <dir>/flat.png (-o -l: the window's shape)
//                                    and <dir>/screen.png (-R: what the screen
//                                    shows there, sheets and menus included)
import AppKit

func mainWindow() -> (id: Int, bounds: CGRect)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info -> (Int, CGRect)? in
        guard (info[kCGWindowOwnerName as String] as? String) == "Schnellbild",
              (info[kCGWindowLayer as String] as? Int) == 0,
              let id = info[kCGWindowNumber as String] as? Int,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return (id, CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!))
    }.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
}

func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Where the window itself sits inside its shadowed picture: the first fully
/// opaque pixel along the middle row and column (the shadow is translucent).
func contentOrigin(of image: CGImage) -> (x: Int, top: Int) {
    let w = image.width, h = image.height
    let ctx = context(w, h)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let row = ctx.bytesPerRow
    let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func alpha(_ x: Int, _ yFromTop: Int) -> UInt8 { pixels[yFromTop * row + x * 4 + 3] }
    let left = (0..<w).first { alpha($0, h / 2) == 255 } ?? 0
    let top = (0..<h).first { alpha(w / 2, $0) == 255 } ?? 0
    return (left, top)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "window":
    // All of the app's windows, for the log
    for info in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    where (info[kCGWindowOwnerName as String] as? String) == "Schnellbild" {
        FileHandle.standardError.write("  window \(info[kCGWindowNumber as String] ?? "?") layer \(info[kCGWindowLayer as String] ?? "?") \(info[kCGWindowBounds as String] ?? "?")\n".data(using: .utf8)!)
    }
    guard let main = mainWindow() else { fail("No Schnellbild window") }
    let b = main.bounds
    print("\(main.id) \(Int(b.minX)),\(Int(b.minY)),\(Int(b.width)),\(Int(b.height))")

case "compose" where args.count > 3:
    let dir = URL(fileURLWithPath: args[3], isDirectory: true)
    guard let shadow = load(dir.appendingPathComponent("shadow.png")),
          let flat = load(dir.appendingPathComponent("flat.png")),
          let screen = load(dir.appendingPathComponent("screen.png")) else { fail("Pictures missing in \(dir.path)") }
    // The screen area cut to the window's shape (rounded corners)
    let fw = flat.width, fh = flat.height
    let cut = context(fw, fh)
    cut.draw(screen, in: CGRect(x: 0, y: 0, width: fw, height: fh))
    cut.setBlendMode(.destinationIn)
    cut.draw(flat, in: CGRect(x: 0, y: 0, width: fw, height: fh))
    // … laid over the window in the shadowed picture
    let origin = contentOrigin(of: shadow)
    let W = shadow.width, H = shadow.height
    let out = context(W, H)
    out.draw(shadow, in: CGRect(x: 0, y: 0, width: W, height: H))
    out.draw(cut.makeImage()!, in: CGRect(x: origin.x, y: H - origin.top - fh, width: fw, height: fh))
    let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    print("Wrote \(args[2])")

default:
    fail("Usage: shoot_window window | compose <out> <dir>")
}
