// Renders the cover picture for articles and project pages about Schnellbild
// (1600 × 900, light): the app icon on the left, on the right the window with
// the grid from the website's screenshot, cut off by the picture's edges.
// Usage: swift Scripts/make_cover.swift <lang> (en, de, …: the screenshot
//   docs/screenshots/grid-light[-<lang>].webp)
// Result: docs/press/cover-<lang>.webp (lossy, quality 90, by `cwebp`, Homebrew's `webp`)
import AppKit
import CoreGraphics
import ImageIO

let W = 1600, H = 900
let background = CGColor(red: 234 / 255, green: 238 / 255, blue: 244 / 255, alpha: 1)
// The icon: 380 px, its middle on the picture's middle line
let iconRect = CGRect(x: 110, y: 260, width: 380, height: 380)
// The screenshot (window with its shadow, 1072 × 752) at 1.302 times its size,
// its top left corner here (the window's own edge lies 56 px further in)
let shotScale: CGFloat = 1.302
let shotOrigin = CGPoint(x: 561, y: 61)

func image(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("can't read \(path)") }
    return image
}

let lang = CommandLine.arguments.dropFirst().first ?? "en"
let shotPath = "docs/screenshots/grid-light\(lang == "en" ? "" : "-\(lang)").webp"
let shot = image(shotPath)
let icon = image("Resources/icon_1024.png")

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }
ctx.interpolationQuality = .high
// y from the top, as the positions above
func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height) }

ctx.setFillColor(background)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.draw(icon, in: flipped(iconRect))
ctx.draw(shot, in: flipped(CGRect(x: shotOrigin.x, y: shotOrigin.y,
                                  width: CGFloat(shot.width) * shotScale, height: CGFloat(shot.height) * shotScale)))

let out = "docs/press/cover-\(lang).png"
try? FileManager.default.createDirectory(atPath: "docs/press", withIntermediateDirectories: true)
guard let picture = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("can't write \(out)") }
CGImageDestinationAddImage(dest, picture, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("can't write \(out)") }
let webp = out.replacingOccurrences(of: ".png", with: ".webp")
let cwebp = Process()
cwebp.executableURL = URL(fileURLWithPath: "/usr/bin/env")
cwebp.arguments = ["cwebp", "-quiet", "-q", "90", out, "-o", webp]
try cwebp.run()
cwebp.waitUntilExit()
guard cwebp.terminationStatus == 0 else { fatalError("cwebp failed") }
try FileManager.default.removeItem(atPath: out)
print(webp)
