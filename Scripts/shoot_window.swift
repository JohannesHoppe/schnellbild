// Photographs Schnellbild's window like ⌘⇧4 + Space does: with its shadow and
// rounded corners on a transparent background, including an open sheet or
// menu. The pictures come from `screencapture`, run by the shell (the
// permission to record the screen belongs to the runner's shell, not to
// programs it starts). Compiled by .github/workflows/screenshots.yml:
//   shoot_window window              prints "<id> <x>,<y>,<w>,<h>" of the main window
//   shoot_window window front        the same of the frontmost window (Settings)
//   shoot_window compose <out> <dir> from <dir>/shadow.png (screencapture -l),
//                                    <dir>/flat.png (-o -l: the window's shape)
//                                    and <dir>/screen.png (-R: what the screen
//                                    shows there, sheets and menus included)
import AppKit

/// The largest of the app's windows, or with `front` the frontmost (the
/// list runs front to back).
func mainWindow(front: Bool = false) -> (id: Int, bounds: CGRect)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let windows = list.compactMap { info -> (Int, CGRect)? in
        guard (info[kCGWindowOwnerName as String] as? String) == "Schnellbild",
              (info[kCGWindowLayer as String] as? Int) == 0,
              let id = info[kCGWindowNumber as String] as? Int,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return (id, CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!))
    }
    return front ? windows.first : windows.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
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

/// RGBA bytes of an image, rows from the top.
struct Pixels {
    let width: Int, height: Int, row: Int
    let data: [UInt8]
    init(_ image: CGImage) {
        width = image.width; height = image.height
        let ctx = context(width, height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        row = ctx.bytesPerRow
        data = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: row * height))
    }
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        let i = y * row + x * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
}

/// Where the window (`flat`, no shadow) sits inside the shadowed picture:
/// the offset at which the opaque pixels of both match best. The shadow is
/// wider at the bottom and differs between light and dark mode, so it is
/// searched for rather than derived.
func contentOrigin(of flat: CGImage, in shadow: CGImage) -> (x: Int, top: Int) {
    let f = Pixels(flat), s = Pixels(shadow)
    var samples: [(Int, Int)] = []
    for gy in 1..<24 { for gx in 1..<24 {
        let x = f.width * gx / 24, y = f.height * gy / 24
        if f.at(x, y).3 == 255 { samples.append((x, y)) }
    }}
    var best = (x: (s.width - f.width) / 2, top: 0, cost: Int.max)
    for dy in 0...max(s.height - f.height, 0) {
        for dx in 0...max(s.width - f.width, 0) {
            var cost = 0
            for (x, y) in samples {
                let a = f.at(x, y), b = s.at(x + dx, y + dy)
                cost += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                if cost >= best.cost { break }
            }
            if cost < best.cost { best = (dx, dy, cost) }
        }
    }
    return (best.x, best.top)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "window":
    // All of the app's windows, for the log
    for info in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    where (info[kCGWindowOwnerName as String] as? String) == "Schnellbild" {
        FileHandle.standardError.write("  window \(info[kCGWindowNumber as String] ?? "?") layer \(info[kCGWindowLayer as String] ?? "?") \(info[kCGWindowBounds as String] ?? "?")\n".data(using: .utf8)!)
    }
    guard let main = mainWindow(front: args.count > 2 && args[2] == "front") else { fail("No Schnellbild window") }
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
    let origin = contentOrigin(of: flat, in: shadow)
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
