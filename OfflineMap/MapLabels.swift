import CoreGraphics
import CoreText
import Foundation

/// Places label boxes without overlap: each box is accepted only if it
/// touches none accepted before (nor a box to keep free), so the caller
/// offers the most important labels first. Boxes are kept in buckets of a
/// grid, so a check looks only at its neighbours.
public struct LabelPlacer {
    public let bounds: CGRect
    private let cell: CGFloat = 64
    private var buckets: [Int: [CGRect]] = [:]
    public private(set) var placed: [CGRect] = []

    public init(bounds: CGRect, keepFree: [CGRect] = []) {
        self.bounds = bounds
        for rect in keepFree { insert(rect) }
        placed = []
    }

    private func keys(_ rect: CGRect) -> [Int] {
        let x0 = Int(floor(rect.minX / cell)), x1 = Int(floor(rect.maxX / cell))
        let y0 = Int(floor(rect.minY / cell)), y1 = Int(floor(rect.maxY / cell))
        var out: [Int] = []
        for x in x0...x1 { for y in y0...y1 { out.append(x &* 73_856_093 ^ y &* 19_349_663) } }
        return out
    }

    /// Whether the box lies inside the bounds and touches no box placed.
    public func fits(_ rect: CGRect) -> Bool {
        guard bounds.contains(rect) else { return false }
        for key in keys(rect) {
            if let list = buckets[key], list.contains(where: { $0.intersects(rect) }) { return false }
        }
        return true
    }

    private mutating func insert(_ rect: CGRect) {
        for key in keys(rect) { buckets[key, default: []].append(rect) }
    }

    /// Takes the box as placed without checking it (after `fits` said yes to
    /// a box around it).
    public mutating func reserve(_ rect: CGRect) {
        insert(rect)
        placed.append(rect)
    }

    /// Places the box if it fits; returns whether it did.
    @discardableResult
    public mutating func place(_ rect: CGRect) -> Bool {
        guard fits(rect) else { return false }
        insert(rect)
        placed.append(rect)
        return true
    }
}

/// How a label looks.
enum LabelStyle: Int {
    case country, region, city, town, village, water, sea

    var size: CGFloat {
        switch self {
        case .country: return 12
        case .region: return 10.5
        case .city: return 13
        case .town: return 11.5
        case .village: return 10.5
        case .water: return 10.5
        case .sea: return 12
        }
    }

    var bold: Bool { self == .country || self == .city }
    var italic: Bool { self == .region || self == .water || self == .sea }
    var hasDot: Bool { self == .city || self == .town || self == .village }

    func color(_ palette: MapPalette) -> MapColor {
        switch self {
        case .country, .region: return palette.mutedLabel
        case .water, .sea: return palette.waterLabel
        case .village: return palette.mutedLabel
        default: return palette.label
        }
    }
}

/// Laid-out label lines, kept by text and style: the same labels come back
/// with every redraw while the map moves. The colour comes from the context.
final class LabelLines: @unchecked Sendable {
    final class Entry {
        let line: CTLine
        let width, ascent, descent: CGFloat
        init(_ line: CTLine) {
            self.line = line
            var a: CGFloat = 0, d: CGFloat = 0
            width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil))
            ascent = a
            descent = d
        }
    }

    /// A label drawn once with its halo, at one scale, for one palette
    final class Sprite {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// The halo's reach beyond the text, in points
    static let margin: CGFloat = 2

    private let cache = NSCache<NSString, Entry>()
    private let sprites = NSCache<NSString, Sprite>()
    private var fonts: [Int: CTFont] = [:]
    private let lock = NSLock()

    init() {
        cache.countLimit = 4000
        sprites.totalCostLimit = 48 << 20
    }

    /// The label with its halo as an image (stroking the halo is the costly
    /// part of a label; the same labels come back while the map moves).
    func sprite(_ text: String, _ style: LabelStyle, _ entry: Entry, palette: MapPalette, scale: CGFloat) -> Sprite? {
        let key = "\(style.rawValue)|\(palette.isDark)|\(scale)|\(text)" as NSString
        if let sprite = sprites.object(forKey: key) { return sprite }
        let m = Self.margin
        let width = entry.width + 2 * m, height = entry.ascent + entry.descent + 2 * m
        let px = Int(ceil(width * scale)), py = Int(ceil(height * scale))
        guard px > 0, py > 0, let ctx = MapRenderer.context(width: px, height: py) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let baseline = CGPoint(x: m, y: m + entry.descent)
        ctx.setLineJoin(.round)
        ctx.setTextDrawingMode(.stroke)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(palette.halo.cgColor)
        ctx.textPosition = baseline
        CTLineDraw(entry.line, ctx)
        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(style.color(palette).cgColor)
        ctx.textPosition = baseline
        CTLineDraw(entry.line, ctx)
        guard let image = ctx.makeImage() else { return nil }
        let sprite = Sprite(image)
        sprites.setObject(sprite, forKey: key, cost: px * py * 4)
        return sprite
    }

    private func font(_ style: LabelStyle) -> CTFont {
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[style.rawValue] { return font }
        var font = CTFontCreateUIFontForLanguage(style.bold ? .emphasizedSystem : .system, style.size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, style.size, nil)
        if style.italic, let italic = CTFontCreateCopyWithSymbolicTraits(font, style.size, nil, .traitItalic, .traitItalic) {
            font = italic
        }
        fonts[style.rawValue] = font
        return font
    }

    func line(_ text: String, _ style: LabelStyle) -> Entry {
        let key = "\(style.rawValue)|\(text)" as NSString
        if let entry = cache.object(forKey: key) { return entry }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(style),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let entry = Entry(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)))
        cache.setObject(entry, forKey: key)
        return entry
    }
}

extension MapRenderer {
    struct LabelCandidate {
        var text: String
        var anchor: CGPoint
        var style: LabelStyle
        /// Room kept free around it: a place shown before its zoom (min_zoom)
        /// only where the map is empty, as in a remote valley
        var spacing: CGFloat = 0
    }

    /// The labels a view shows, the most important first: places from the
    /// index (countries up to zoom 6.5, regions from 4.5 to 9, localities
    /// from their min_zoom), then named seas and lakes from the tiles, then
    /// localities up to two zooms early where there is room around them.
    func labelCandidates(_ viewport: MapViewport, languages: MapLanguages) -> [LabelCandidate] {
        let zoom = viewport.camera.zoom
        let view = CGRect(origin: .zero, size: viewport.size).insetBy(dx: -60, dy: -30)
        var out: [LabelCandidate] = [], early: [LabelCandidate] = []
        if let places {
            let unit = viewport.unitBounds
            let north = WebMercator.coordinate(unit: CGPoint(x: 0.5, y: max(0, unit.minY))).latitude
            let south = WebMercator.coordinate(unit: CGPoint(x: 0.5, y: min(1, unit.maxY))).latitude
            // A degree to spare on each side: the west edge as it is (not wrapped)
            // and the span from it, so a view nearly the world's width asks for all of it
            let west = Double(unit.minX) * 360 - 180 - 1
            let east = west + min(360, Double(unit.width) * 360 + 2)
            let found = places.places(south: south - 0.5, north: north + 0.5, west: west, east: east, maxMinZoom: zoom + 2)
            for place in found.prefix(3000) {
                let style: LabelStyle
                switch place.kind {
                case .country:
                    guard zoom < 6.5 else { continue }
                    style = .country
                case .region:
                    guard zoom >= 4.5, zoom < 9 else { continue }
                    style = .region
                case .city: style = zoom < 6 || place.populationRank >= 10 ? .city : .town
                case .town: style = place.populationRank >= 9 && zoom < 9 ? .city : .town
                case .village, .hamlet, .locality: style = .village
                }
                let p = viewport.point(for: place.coordinate)
                guard view.contains(p) else { continue }
                if place.minZoom <= zoom + 0.5 {
                    out.append(LabelCandidate(text: place.label(in: languages), anchor: p, style: style))
                } else if place.isLocality {
                    early.append(LabelCandidate(text: place.label(in: languages), anchor: p, style: .village, spacing: 28))
                }
            }
        }
        // Seas, bays, lakes: the label points of the water layer
        let z = min(sourceMaxZoom, max(0, Int(floor(zoom))))
        for (key, origin, side) in Self.tiles(for: viewport, zoom: z) {
            let n = 1 << z
            guard let tile = sourceTile(TileKey(z: z, x: ((key.x % n) + n) % n, y: key.y)), let layer = tile.layers["water"] else { continue }
            let f = side / layer.extent
            for feature in layer.features where feature.type == .point {
                guard (feature["min_zoom"]?.number ?? 0) <= zoom + 0.5, let point = feature.points.first,
                      point.x >= 0, point.y >= 0, Double(point.x) < layer.extent, Double(point.y) < layer.extent,
                      let text = Self.name(of: feature, languages: languages) else { continue }
                let kind = feature["kind"]?.string ?? ""
                let anchor = CGPoint(x: Double(origin.x) + Double(point.x) * f, y: Double(origin.y) + Double(point.y) * f)
                out.append(LabelCandidate(text: text, anchor: anchor, style: kind == "ocean" || kind == "sea" ? .sea : .water))
            }
        }
        return out + early
    }

    /// A feature's name in the first of the languages its tile has (the
    /// tiles carry OpenStreetMap's keys: Bokmål as name:no, Portuguese as name:pt).
    static func name(of feature: VectorTile.Feature, languages: MapLanguages) -> String? {
        for language in languages.order {
            let key = language == "nb" ? "name:no" : language == "pt-BR" ? "name:pt" : "name:" + language
            if let name = feature[key]?.string { return name }
        }
        let local = feature["name"]?.string
        if languages.englishBeforeOtherScripts, let local, MapLanguages.lacksLatin(local), let english = feature["name:en"]?.string {
            return english
        }
        return local
    }

    /// Lays out and draws the labels of a view into a context whose space is
    /// the view (origin top left, y down). Returns the boxes it placed.
    @discardableResult
    func drawLabels(_ viewport: MapViewport, in ctx: CGContext, palette: MapPalette, languages: MapLanguages,
                    avoiding: [CGRect] = []) -> [CGRect] {
        var placer = LabelPlacer(bounds: CGRect(origin: .zero, size: viewport.size).insetBy(dx: 2, dy: 2), keepFree: avoiding)
        let halo = palette.halo.cgColor
        let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.a))
        ctx.saveGState()
        var seen = Set<String>()
        for candidate in labelCandidates(viewport, languages: languages) {
            // The same name twice close together (a place and its seat) once
            let near = "\(candidate.text)|\(Int(candidate.anchor.x / 40))|\(Int(candidate.anchor.y / 40))"
            guard seen.insert(near).inserted else { continue }
            let line = labelLines.line(candidate.text, candidate.style)
            let height = line.ascent + line.descent
            let dot: CGFloat = candidate.style.hasDot ? (candidate.style == .village ? 3 : 4) : 0
            var origins: [CGPoint] = []
            if dot > 0 {   // right of the dot, else left of it, else above
                origins = [CGPoint(x: candidate.anchor.x + dot / 2 + 3, y: candidate.anchor.y - height / 2),
                           CGPoint(x: candidate.anchor.x - dot / 2 - 3 - line.width, y: candidate.anchor.y - height / 2),
                           CGPoint(x: candidate.anchor.x - line.width / 2, y: candidate.anchor.y - dot / 2 - 2 - height)]
            } else {
                origins = [CGPoint(x: candidate.anchor.x - line.width / 2, y: candidate.anchor.y - height / 2)]
            }
            let dotBox = CGRect(x: candidate.anchor.x - dot / 2 - 1, y: candidate.anchor.y - dot / 2 - 1, width: dot + 2, height: dot + 2)
            for origin in origins {
                let box = CGRect(x: origin.x - 2, y: origin.y - 1, width: line.width + 4, height: height + 2)
                let union = dot > 0 ? box.union(dotBox) : box
                // A little air between labels, more around early ones
                let spacing = max(4, candidate.spacing)
                guard placer.fits(union.insetBy(dx: -spacing, dy: -spacing / 4)) else { continue }
                // Two boxes: a label right of its dot must not keep the space left of the dot free
                if dot > 0 { placer.reserve(dotBox) }
                placer.reserve(box)
                let color = candidate.style.color(palette).cgColor
                if dot > 0 {
                    ctx.setFillColor(halo)
                    ctx.fillEllipse(in: dotBox)
                    ctx.setFillColor(color)
                    ctx.fillEllipse(in: dotBox.insetBy(dx: 1, dy: 1))
                }
                if let sprite = labelLines.sprite(candidate.text, candidate.style, line, palette: palette, scale: scale) {
                    // The sprite is upright in its own space (y up); the view's runs down
                    let m = LabelLines.margin
                    let size = CGSize(width: CGFloat(sprite.image.width) / scale, height: CGFloat(sprite.image.height) / scale)
                    ctx.saveGState()
                    ctx.translateBy(x: origin.x - m, y: origin.y - m + size.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(sprite.image, in: CGRect(origin: .zero, size: size))
                    ctx.restoreGState()
                }
                break
            }
        }
        ctx.restoreGState()
        return placer.placed
    }
}
