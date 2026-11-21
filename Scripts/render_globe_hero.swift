// Renders the website's hero background: the app's globe (GlobeRenderer, off
// screen) seen from a camera outside the app's limits (any tilt, a wider
// lens), with the world trip's photos standing on it as the Atlas view draws
// its tiles. No window around it. Built and run by Scripts/render_globe_hero.sh;
// the same arguments and data give the same picture on the same Mac.
//
//   --camera=<latitude>,<longitude>,<zoom>,<pitch>,<heading>  as MapCamera (pitch may exceed 72°)
//   --distance=<Earth radii> the camera's distance from the target instead of the zoom
//   --lens=<degrees>        vertical angle of view (the app's: 40)
//   --date=<ISO 8601>       the Sun's moment
//   --size=<width>x<height> in points; --scale=<n> pixels per point (2)
//   --shift=<points>        the frame moved up (positive) or down over the
//                           picture, as a shift lens: the horizon lower in
//                           the frame with more space above it
//   --theme=light|dark      the tiles' frame and accent as the map palette's
//   --clouds=<0…1>          the cloud cover shown (the app's: 0.65)
//   --photos=<folder>       the photos (Scripts/fetch_world_photos.sh)
//   --out=<file.jpg|.png>   --quality=<0…1> for JPEG (0.85)
//   --transparent           no stars and no space: transparent around the Earth and its
//                           air (write PNG); the light of the Sun's glow becomes coverage
//   --fade-top=<points>     transparent: the light fades out over this much of the frame's
//   --fade-bottom=<points>  top and bottom (smoothstep), so no edge shows on the page
//   --backdrop=#rrggbb      the transparent picture laid over this colour (a preview)
//   --info                  prints where the Sun and each photo land and how round the limb is, renders nothing
//                           (--limb-points: each point of the limb as well)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

func argument(_ name: String) -> String? {
    CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("!! \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let values = (argument("camera") ?? "").split(separator: ",").compactMap { Double($0) }
guard values.count == 5 else { fail("--camera=<latitude>,<longitude>,<zoom>,<pitch>,<heading>") }
guard let date = argument("date").flatMap({ ISO8601DateFormatter().date(from: $0) }) else { fail("--date=<ISO 8601>") }
let dims = (argument("size") ?? "1200x500").split(separator: "x").compactMap { Double($0) }
guard dims.count == 2 else { fail("--size=<width>x<height>") }
let size = CGSize(width: dims[0], height: dims[1])
// Rendered taller and cut: the frame's top lies `top` points below the render's
let shift = Double(argument("shift") ?? "0") ?? 0
let full = CGSize(width: size.width, height: size.height + 2 * abs(shift))
let top = abs(shift) - shift
let scale = Double(argument("scale") ?? "2") ?? 2
let dark = argument("theme") == "dark"
let palette = dark ? MapPalette.dark : MapPalette.light
let info = CommandLine.arguments.contains("--info")

var scene = GlobeScene(camera: MapCamera(center: Coordinate(latitude: values[0], longitude: values[1]), zoom: values[2], pitch: values[3], heading: values[4]),
                       size: full, dark: dark, lighting: true, date: date, clouds: Double(argument("clouds") ?? "0.65") ?? 0.65)
// The lens is the frame's; the taller render keeps its focal length
let lens = Double(argument("lens") ?? "40") ?? 40
let focal = size.height / 2 / tan(lens / 2 * .pi / 180)
scene.lens = 2 * atan(full.height / 2 / focal) * 180 / .pi
// The camera stands focal / radius Earth radii from its target (GlobeProjection.frame)
if let distance = argument("distance").flatMap(Double.init) {
    scene.camera.zoom = log2(2 * .pi * focal / (WebMercator.tileSize * distance))
}
scene.transparent = CommandLine.arguments.contains("--transparent")
// The tilt as given at any distance (the app eases it out zoomed in)
scene.freeTilt = true
let projection = scene.projection

// The photos and where they were taken (their GPS in the metadata)
struct Photo { let name: String; let coordinate: Coordinate; let image: CGImage }
let photosFolder = URL(fileURLWithPath: argument("photos") ?? root.appendingPathComponent("build/world-photos").path)
let names = ((try? FileManager.default.contentsOfDirectory(atPath: photosFolder.path)) ?? []).filter { $0.lowercased().hasSuffix(".jpg") }.sorted()
let photos: [Photo] = names.compactMap { name in
    guard let source = CGImageSourceCreateWithURL(photosFolder.appendingPathComponent(name) as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 400,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    else { return nil }
    if gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" { lat = -lat }
    if gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" { lon = -lon }
    return Photo(name: name, coordinate: Coordinate(latitude: lat, longitude: lon), image: image)
}
if photos.isEmpty { FileHandle.standardError.write(Data("== no photos in \(photosFolder.path)\n".utf8)) }

// As the Atlas view: tiles 52 pt square in a 2 pt frame, standing 6 pt above
// their place; places closer than a tile's width share one tile (the first by
// name shown, the count on it), only places on the near side and in the view
struct Tile { var point: CGPoint; var photos: [Photo] }
let side = 52.0
var tiles: [Tile] = []
for photo in photos where projection.isVisible(photo.coordinate) {
    var p = projection.point(for: photo.coordinate)
    p.y -= top
    guard p.x > side / 2 + 4, p.x < size.width - side / 2 - 4, p.y > side + 12, p.y < size.height - 6 else { continue }
    if let k = tiles.firstIndex(where: { hypot($0.point.x - p.x, $0.point.y - p.y) < side + 4 }) {
        tiles[k].photos.append(photo)
    } else {
        tiles.append(Tile(point: p, photos: [photo]))
    }
}

func sunPoint() -> CGPoint? {
    let fr = projection.frame
    let dir = GlobeGeometry.unitVector(Astronomy.subsolarPoint(at: date))
    let z = simd_dot(dir, fr.forward)
    guard z > 0 else { return nil }
    return CGPoint(x: full.width / 2 + fr.focal * simd_dot(dir, fr.right) / z, y: full.height / 2 - fr.focal * simd_dot(dir, fr.up) / z - top)
}
if info {
    let fr = projection.frame
    let altitude = (simd_length(fr.position) - 1) * 6371
    let sub = GlobeGeometry.coordinate(simd_normalize(fr.position))
    let sun = GlobeGeometry.unitVector(Astronomy.subsolarPoint(at: date))
    let elevation = asin(simd_dot(GlobeGeometry.unitVector(sub), sun)) * 180 / .pi
    print(String(format: "camera %.0f km above %.2f, %.2f; the Sun %.1f° high there", altitude, sub.latitude, sub.longitude, elevation))
    // How much of the ground in view has the Sun above it
    var lit = 0.0, ground = 0.0, total = 0.0
    for gy in stride(from: 5.0, to: size.height, by: size.height / 40) {
        for gx in stride(from: 5.0, to: size.width, by: size.width / 60) {
            total += 1
            guard let c = projection.coordinate(at: CGPoint(x: gx, y: gy + top)) else { continue }
            ground += 1
            if simd_dot(GlobeGeometry.unitVector(c), sun) > sin(3 * Double.pi / 180) { lit += 1 }
        }
    }
    print(String(format: "ground %.0f %% of the view, %.0f %% of it in daylight", 100 * ground / total, 100 * lit / max(1, ground)))
    // The limb: in each column the first row on the ground, then a circle fitted to them (Kåsa's least squares)
    var limb: [(Double, Double)] = []
    for x in stride(from: 0.0, through: size.width, by: size.width / 120) {
        guard projection.coordinate(at: CGPoint(x: x, y: size.height - 1 + top)) != nil,
              projection.coordinate(at: CGPoint(x: x, y: top)) == nil else { continue }
        var lo = 0.0, hi = size.height - 1
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if projection.coordinate(at: CGPoint(x: x, y: mid + top)) == nil { lo = mid } else { hi = mid }
        }
        limb.append((x, hi))
    }
    if limb.count >= 5 {
        var m = simd_double3x3(0), r = SIMD3<Double>(0, 0, 0)
        for (x, y) in limb {
            let row = SIMD3(x, y, 1), z = -(x * x + y * y)
            m += simd_double3x3(rows: [row * row.x, row * row.y, row * row.z])
            r += row * z
        }
        let s = m.inverse * r
        let cx = -s.x / 2, cy = -s.y / 2, radius = sqrt(cx * cx + cy * cy - s.z)
        let residuals = limb.map { hypot($0.0 - cx, $0.1 - cy) - radius }
        let rms = sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count))
        if CommandLine.arguments.contains("--limb-points") {
            for (x, y) in limb { print(String(format: "limb-point %.1f %.2f", x, y)) }
        }
        print(String(format: "limb: %d points from x %.0f to %.0f, apex y %.0f; circle radius %.0f pt, residual rms %.2f px, max %.2f px",
                     limb.count, limb.first!.0, limb.last!.0, limb.map(\.1).min()!, radius, rms * scale,
                     residuals.map(abs).max()! * scale))
    }
    if let s = sunPoint() {
        let x = min(size.width - 1, max(0, s.x))
        let horizon = stride(from: 0.0, to: size.height, by: 1).first { projection.coordinate(at: CGPoint(x: x, y: $0 + top)) != nil } ?? size.height
        print(String(format: "the Sun at (%.0f, %.0f), the horizon below it at %.0f", s.x, s.y, horizon))
    } else {
        print("the Sun behind the camera")
    }
    for t in tiles { print(String(format: "tile (%.0f, %.0f): ", t.point.x, t.point.y) + t.photos.map(\.name).joined(separator: ", ")) }
    exit(0)
}

// The globe
let maps = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Vendor/Map").path))?.filter { $0.hasSuffix(".pmtiles") } ?? []
guard let mapFile = maps.first, let archive = try? PMTilesArchive(url: root.appendingPathComponent("Vendor/Map/\(mapFile)")) else { fail("no map in Vendor/Map") }
let data = GlobeData.load(folder: root.appendingPathComponent("Vendor/Globe"))
guard data.satellite != nil, data.clouds != nil else { fail("the globe's data is missing in Vendor/Globe (Scripts/fetch_globe.sh)") }
guard let renderer = GlobeRenderer(map: MapRenderer(archive: archive, places: nil), data: data) else { fail("no Metal device") }
renderer.textures.prepareAndWait(for: scene)
guard let (rendered, _) = renderer.snapshot(scene, scale: CGFloat(scale)) else { fail("the render failed") }
var globe = rendered
if scene.transparent {
    // (GlobeRenderer.snapshot gives the glare its coverage already)
    guard let c = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = c.data?.assumingMemoryBound(to: UInt8.self) else { fail("no context") }
    c.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
    for i in stride(from: 0, to: rendered.width * rendered.height * 4, by: 4) {
        let a = max(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2])
        bytes[i + 3] = a
        // The faintest glow ends in 8-bit steps (a visible arc on a dark page): it fades out instead
        if a < 12 {
            let x = min(1, max(0, (Double(a) - 2) / 10)), f = x * x * (3 - 2 * x)
            for k in 0..<4 { bytes[i + k] = UInt8((Double(bytes[i + k]) * f).rounded()) }
        }
    }
    // Faded towards the frame's top and bottom (rows in the render: the frame starts `top` points down)
    let fadeTop = (Double(argument("fade-top") ?? "0") ?? 0) * scale, fadeBottom = (Double(argument("fade-bottom") ?? "0") ?? 0) * scale
    let frameTop = top * scale, frameBottom = (top + size.height) * scale
    for y in 0..<rendered.height {
        let row = Double(y) + 0.5
        func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        let f = (fadeTop > 0 ? smooth((row - frameTop) / fadeTop) : 1) * (fadeBottom > 0 ? smooth((frameBottom - row) / fadeBottom) : 1)
        guard f < 1 else { continue }
        for x in 0..<rendered.width {
            let i = (y * rendered.width + x) * 4
            for k in 0..<4 { bytes[i + k] = UInt8((Double(bytes[i + k]) * f).rounded()) }
        }
    }
    globe = c.makeImage() ?? rendered
}

// The tiles over it
let w = Int(size.width * scale), h = Int(size.height * scale)
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
if let hex = argument("backdrop"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) {
    ctx.setFillColor(CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
}
ctx.draw(globe, in: CGRect(x: 0, y: -(full.height - top - size.height) * scale, width: Double(globe.width), height: Double(globe.height)))
// Points, origin top left
ctx.translateBy(x: 0, y: CGFloat(h))
ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
func colour(_ c: MapColor, _ alpha: CGFloat = 1) -> CGColor { c.cgColor.copy(alpha: alpha) ?? c.cgColor }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
// Nearer tiles (lower in the view) in front
for tile in tiles.sorted(by: { $0.point.y < $1.point.y }) {
    let p = tile.point
    let card = CGRect(x: p.x - side / 2 - 2, y: p.y - side - 6 - 4, width: side + 4, height: side + 4)
    if tile.photos.count > 1 {
        for offset in [6.0, 3.0] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: CGColor(gray: 0, alpha: 0.3))
            ctx.addPath(rounded(card.offsetBy(dx: offset, dy: -offset), 6))
            ctx.setFillColor(colour(palette.frame, 0.9))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(rounded(card, 6))
    ctx.setFillColor(colour(palette.frame))
    ctx.fillPath()
    ctx.restoreGState()
    // The photo, filling its square
    let image = tile.photos[0].image
    let inner = card.insetBy(dx: 2, dy: 2)
    let s = max(inner.width / CGFloat(image.width), inner.height / CGFloat(image.height))
    let drawn = CGRect(x: inner.midX - CGFloat(image.width) * s / 2, y: inner.midY - CGFloat(image.height) * s / 2,
                       width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
    ctx.saveGState()
    ctx.addPath(rounded(inner, 4))
    ctx.clip()
    // CGContext draws images upright in its own (flipped here) space
    ctx.translateBy(x: 0, y: drawn.maxY + drawn.minY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: drawn)
    ctx.restoreGState()
    if tile.photos.count > 1 {
        let text = NSAttributedString(string: "\(tile.photos.count)", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor(cgColor: colour(palette.accentText))!])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetImageBounds(line, ctx)
        let badge = CGRect(x: card.maxX + 8 - max(18, bounds.width + 10) / 2 - 9, y: card.minY - 8, width: max(18, bounds.width + 10), height: 16)
        ctx.addPath(rounded(badge, 8))
        ctx.setFillColor(colour(palette.accent))
        ctx.fillPath()
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: badge.midX - bounds.width / 2 - bounds.minX, y: badge.midY + bounds.height / 2 + bounds.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
    // The dot where they were taken
    let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
    ctx.addEllipse(in: dot)
    ctx.setFillColor(colour(palette.accent))
    ctx.fillPath()
    ctx.addEllipse(in: dot)
    ctx.setStrokeColor(colour(palette.frame))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
}

guard let picture = ctx.makeImage() else { fail("no picture") }
let out = URL(fileURLWithPath: argument("out") ?? "globe-hero.jpg")
let type = out.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { fail("can't write \(out.path)") }
CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: Double(argument("quality") ?? "0.85") ?? 0.85] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fail("can't write \(out.path)") }
print("\(out.path): \(w) × \(h)")
