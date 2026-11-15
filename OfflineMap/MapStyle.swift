import CoreGraphics
import Foundation

/// A colour in sRGB.
public struct MapColor: Equatable, Hashable, Sendable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From "#rrggbb".
    public init(_ hex: String, alpha: Double = 1) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: alpha)
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: MapColor.sRGB, components: [red, green, blue, alpha])!
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// WCAG 2's relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2's contrast ratio (1 to 21).
    public func contrast(with other: MapColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The map's colours, one set for the light and one for the dark appearance:
/// calm greys like the app, water in a soft blue, the app's accent for what
/// the user's own things are (markers, badges). `MapStyleTests` hold the
/// contrasts (labels at least 4.5:1, highways and country borders about 3:1).
public struct MapPalette: Equatable, Sendable {
    public var land, water, glacier, glacierOutline: MapColor
    public var highway, majorRoad, mediumRoad, minorRoad: MapColor
    public var countryBorder, regionBorder: MapColor
    public var label, mutedLabel, waterLabel, halo: MapColor
    /// Markers and badges, and what is written on them
    public var accent, accentText: MapColor
    /// The frame around thumbnails on the map
    public var frame: MapColor
    public var isDark: Bool

    public static let light = MapPalette(
        land: MapColor("#f5f5f7"), water: MapColor("#bfd3f0"), glacier: MapColor("#ffffff"), glacierOutline: MapColor("#d2d9e3"),
        highway: MapColor("#86868b"), majorRoad: MapColor("#a5a5aa"), mediumRoad: MapColor("#c2c2c7"), minorRoad: MapColor("#d6d6db"),
        countryBorder: MapColor("#8e8e93"), regionBorder: MapColor("#b4b4ba"),
        label: MapColor("#1d1d1f"), mutedLabel: MapColor("#6e6e73"), waterLabel: MapColor("#0947a3"), halo: MapColor("#ffffff", alpha: 0.85),
        accent: MapColor("#0a66e8"), accentText: MapColor("#ffffff"), frame: MapColor("#ffffff"), isDark: false)

    public static let dark = MapPalette(
        land: MapColor("#2e2e31"), water: MapColor("#0c1420"), glacier: MapColor("#424246"), glacierOutline: MapColor("#424246"),
        highway: MapColor("#88888e"), majorRoad: MapColor("#69696e"), mediumRoad: MapColor("#55555a"), minorRoad: MapColor("#46464a"),
        countryBorder: MapColor("#8e8e94"), regionBorder: MapColor("#5a5a60"),
        label: MapColor("#e0e0e0"), mutedLabel: MapColor("#a0a0a0"), waterLabel: MapColor("#8cb7f2"), halo: MapColor("#121212", alpha: 0.85),
        accent: MapColor("#8cb7f2"), accentText: MapColor("#121212"), frame: MapColor("#e0e0e0"), isDark: true)

    public static func appearance(dark: Bool) -> MapPalette { dark ? .dark : .light }
}

/// Line widths and from which zoom each kind of line shows.
enum MapStyle {
    /// Widths grow with the zoom: thin lines for the world, wider ones for a town.
    static func widthFactor(_ zoom: Double) -> Double {
        switch zoom {
        case ..<6: return 0.8
        case ..<8: return 1
        case ..<10: return 1.4
        case ..<12: return 2
        default: return 2.6
        }
    }

    struct Road {
        var kind: String
        var width: Double
        var fromZoom: Double
        var color: KeyPath<MapPalette, MapColor>
    }

    /// Drawn in this order (the most important last, on top). Medium roads
    /// only from zoom 10: below that they crowd a city like Tokyo.
    static let roads: [Road] = [
        Road(kind: "minor_road", width: 0.6, fromZoom: 11, color: \.minorRoad),
        Road(kind: "medium_road", width: 0.7, fromZoom: 10, color: \.mediumRoad),
        Road(kind: "major_road", width: 0.8, fromZoom: 6, color: \.majorRoad),
        Road(kind: "highway", width: 1.0, fromZoom: 3, color: \.highway),
    ]

    static func riverWidth(_ zoom: Double) -> Double { zoom < 8 ? 0.6 : zoom < 10 ? 1.0 : 1.5 }
}
