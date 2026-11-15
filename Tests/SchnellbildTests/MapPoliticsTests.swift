import CoreGraphics
import Foundation
import XCTest
@testable import OfflineMap

/// The map's political positions on the bundled data (CLAUDE.md, "Political
/// positions"): the world as the EU and Germany read it, in every language.
/// These hold for every new map; a source that disagrees is overridden in
/// Scripts/build_map_data.py, the test is not changed.
final class MapPoliticsTests: XCTestCase {
    func renderer() throws -> MapRenderer {
        let folder = OfflineMapTests.mapFolder
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let map = try XCTUnwrap(files.first { $0.pathExtension == "pmtiles" })
        let places = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("schnellbild-places-") })
        return MapRenderer(archive: try PMTilesArchive(url: map), places: try PlaceIndex(url: places))
    }

    // MARK: Countries

    /// Where a photo was taken, and the country "near …" names.
    static let countries: [(String, Double, Double, String)] = [
        ("Simferopol", 44.952, 34.102, "UA"), ("Sevastopol", 44.616, 33.525, "UA"), ("Kerch", 45.357, 36.468, "UA"),
        ("Yalta", 44.495, 34.166, "UA"), ("Donetsk", 48.016, 37.803, "UA"), ("Luhansk", 48.574, 39.308, "UA"),
        ("Mariupol", 47.097, 37.543, "UA"), ("Melitopol", 46.849, 35.367, "UA"), ("Nova Kakhovka", 46.755, 33.348, "UA"),
        ("Henichesk", 46.171, 34.818, "UA"),
        ("Pristina", 42.663, 21.164, "XK"), ("Prizren", 42.213, 20.739, "XK"),
        ("Taipei", 25.033, 121.565, "TW"),
        ("Laayoune", 27.154, -13.199, "EH"), ("Dakhla", 23.684, -15.958, "EH"), ("Smara", 26.739, -11.672, "EH"),
        ("Katzrin (Golan Heights)", 32.992, 35.688, "SY"), ("Majdal Shams (Golan Heights)", 33.270, 35.770, "SY"),
        ("Ramallah", 31.903, 35.204, "PS"), ("Nablus", 32.222, 35.262, "PS"), ("Hebron", 31.532, 35.098, "PS"),
        ("Gaza", 31.502, 34.467, "PS"), ("Khan Yunis", 31.346, 34.306, "PS"),
        ("Ma'ale Adumim (settlement)", 31.771, 35.298, "PS"), ("Ariel (settlement)", 32.106, 35.185, "PS"),
        ("Modi'in Illit (settlement)", 31.932, 35.044, "PS"),
        ("East Jerusalem, Old City", 31.7767, 35.2345, "PS"), ("East Jerusalem, Sheikh Jarrah", 31.795, 35.230, "PS"),
        ("West Jerusalem", 31.780, 35.200, "IL"), ("Tel Aviv", 32.080, 34.780, "IL"),
        ("Kyrenia", 35.340, 33.319, "CY"), ("Famagusta", 35.125, 33.942, "CY"), ("North Nicosia", 35.185, 33.363, "CY"),
        ("Sukhumi", 43.003, 41.023, "GE"), ("Gagra", 43.335, 40.271, "GE"), ("Tskhinvali", 42.227, 43.970, "GE"),
        ("Tiraspol", 46.840, 29.629, "MD"), ("Bender", 46.832, 29.477, "MD"),
        ("Khankendi", 39.815, 46.752, "AZ"),
        ("Stanley", -51.693, -57.857, "FK"),
    ]

    func testEveryPlaceGetsTheCountryOfTheEuropeanReading() throws {
        let places = try XCTUnwrap(renderer().places)
        for (name, lat, lon, expected) in Self.countries {
            let near = try XCTUnwrap(places.nearby(Coordinate(latitude: lat, longitude: lon)), name)
            XCTAssertEqual(near.countryCode, expected, "\(name): near \(near.place.localName)")
        }
    }

    func testRamallahIsNearRamallahAndEastJerusalemNearJerusalem() throws {
        let places = try XCTUnwrap(renderer().places)
        let english = MapLanguages.preferring(["en"]), us = Locale(identifier: "en_US")
        XCTAssertEqual(places.nearby(Coordinate(latitude: 31.903, longitude: 35.204))?.place.label(in: english), "Ramallah")
        let oldCity = try XCTUnwrap(places.nearby(Coordinate(latitude: 31.7767, longitude: 35.2345)))
        XCTAssertEqual(oldCity.place.label(in: english), "Jerusalem")
        XCTAssertEqual(oldCity.description(languages: english, locale: us), "near Jerusalem, Palestine")
        let ramallah = try XCTUnwrap(places.nearby(Coordinate(latitude: 31.903, longitude: 35.204)))
        XCTAssertEqual(ramallah.countryName(locale: Locale(identifier: "de_DE")), "Palästina")
        XCTAssertEqual(places.nearby(Coordinate(latitude: 31.780, longitude: 35.200))?.description(languages: english, locale: us),
                       "near Jerusalem, Israel")
        XCTAssertEqual(places.regionCountry(at: Coordinate(latitude: 32.992, longitude: 35.688)), "SY")
        XCTAssertEqual(places.regionCountry(at: Coordinate(latitude: 44.952, longitude: 34.102)), "UA")
    }

    // MARK: Names

    func testWesternSaharaIsCalledWesternSahara() throws {
        let places = try XCTUnwrap(renderer().places)
        let country = try XCTUnwrap(places.places(south: 20, north: 28, west: -18, east: -8, maxMinZoom: 12).first { $0.kind == .country && $0.countryCode == "EH" })
        XCTAssertEqual(country.label(in: .preferring(["en"])), "Western Sahara")
        XCTAssertEqual(country.label(in: .preferring(["de"])), "Westsahara")
        XCTAssertEqual(country.label(in: .preferring(["es"])), "Sáhara Occidental")
        for language in MapLanguages.supported {
            XCTAssertFalse(country.label(in: .preferring([language])).contains("Saharaui"), language)
        }
    }

    /// Palestine as the app names the country: CLDR's short form in each language, never "territories".
    static let palestine = [
        "en": "Palestine", "de": "Palästina", "fr": "Palestine", "es": "Palestina", "it": "Palestina", "pt-BR": "Palestina",
        "nl": "Palestina", "pl": "Palestyna", "sv": "Palestina", "da": "Palæstina", "nb": "Palestina", "fi": "Palestiina",
        "cs": "Palestina", "tr": "Filistin", "ru": "Палестина", "uk": "Палестина", "ja": "パレスチナ", "ko": "팔레스타인",
        "zh-Hans": "巴勒斯坦", "zh-Hant": "巴勒斯坦",
    ]

    static func locale(_ language: String) -> Locale {
        Locale(identifier: language.replacingOccurrences(of: "-", with: "_"))
    }

    func testPalestineIsCalledPalestineInEveryLanguage() throws {
        XCTAssertEqual(Set(Self.palestine.keys), Set(MapLanguages.supported))
        let places = try XCTUnwrap(renderer().places)
        let country = try XCTUnwrap(places.places(south: 31, north: 32.6, west: 34.2, east: 35.6, maxMinZoom: 12).first { $0.kind == .country && $0.countryCode == "PS" })
        for (language, name) in Self.palestine {
            XCTAssertEqual(CountryNames.name("PS", locale: Self.locale(language)), name, language)
            XCTAssertEqual(country.label(in: .preferring([language])), name, language)
        }
        XCTAssertEqual(CountryNames.name("DE", locale: Locale(identifier: "de_DE")), "Deutschland")   // the others: the system's
    }

    func testKyivAndNorthMacedonia() throws {
        let places = try XCTUnwrap(renderer().places)
        let kyiv = try XCTUnwrap(places.nearby(Coordinate(latitude: 50.4505, longitude: 30.5200))?.place)
        for language in ["en", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi", "cs", "tr"] {
            XCTAssertEqual(kyiv.label(in: .preferring([language])), "Kyiv", language)
        }
        XCTAssertEqual(kyiv.label(in: .preferring(["de"])), "Kyjiw")
        XCTAssertEqual(kyiv.label(in: .preferring(["uk"])), "Київ")
        XCTAssertEqual(kyiv.label(in: .preferring(["ru"])), "Киев")
        XCTAssertEqual(kyiv.label(in: .preferring(["ja"])), "キーウ")
        let macedonia = try XCTUnwrap(places.places(south: 40, north: 43, west: 20, east: 23.5, maxMinZoom: 12).first { $0.kind == .country && $0.countryCode == "MK" })
        XCTAssertEqual(macedonia.label(in: .preferring(["en"])), "North Macedonia")
    }

    /// No name from a renaming by the US administration from 2025 on, in any language.
    func testNoNameOfAUSRenamingFrom2025On() throws {
        let renderer = try renderer()
        let banned = ["Gulf of America", "Golf von Amerika", "Golfo de América", "Golfe d'Amérique", "Golfe d’Amérique",
                      "Lake America", "Mount McKinley", "Arabian Gulf"]
        var waterNames = 0
        for z in 0...5 {
            for x in 0..<(1 << z) {
                for y in 0..<(1 << z) {
                    guard let tile = renderer.sourceTile(TileKey(z: z, x: x, y: y)), let water = tile.layers["water"] else { continue }
                    for feature in water.features where feature.type == .point {
                        for (key, value) in feature.properties where key.hasPrefix("name") {
                            waterNames += 1
                            let text = value.string ?? ""
                            XCTAssertFalse(banned.contains { text.localizedCaseInsensitiveContains($0) }, "\(z)/\(x)/\(y) \(key): \(text)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(waterNames, 100)
        // Fort Polk, Louisiana: Fort Johnson until the Army's renaming of 2025
        let places = try XCTUnwrap(renderer.places)
        let near = places.places(near: Coordinate(latitude: 31.05, longitude: -93.21), radius: 5_000).map(\.place.localName)
        XCTAssertTrue(near.contains("Fort Johnson"), "\(near)")
        XCTAssertFalse(near.contains("Fort Polk"), "\(near)")
    }

    /// A water label of the tile holding `coordinate` at zoom `z`, by its English name.
    func waterLabel(_ english: String, z: Int, at coordinate: Coordinate) throws -> VectorTile.Feature {
        let renderer = try renderer()
        let u = WebMercator.unitPoint(coordinate)
        let key = TileKey(z: z, x: Int(Double(u.x) * Double(1 << z)), y: Int(Double(u.y) * Double(1 << z)))
        let water = try XCTUnwrap(renderer.sourceTile(key)?.layers["water"])
        return try XCTUnwrap(water.features.first { $0.type == .point && $0["name:en"]?.string == english }, "\(english) in \(key)")
    }

    func testSeasKeepTheirInternationalNames() throws {
        let gulf = try waterLabel("Gulf of Mexico", z: 3, at: Coordinate(latitude: 25, longitude: -90))
        XCTAssertEqual(gulf["name:de"]?.string, "Golf von Mexiko")
        XCTAssertEqual(gulf["name:es"]?.string, "Golfo de México")
        XCTAssertEqual(gulf["name:fr"]?.string, "Golfe du Mexique")
        XCTAssertEqual(gulf["name:ja"]?.string, "メキシコ湾")
        XCTAssertEqual(MapRenderer.name(of: gulf, languages: .preferring(["en"])), "Gulf of Mexico")
        let persian = try waterLabel("Persian Gulf", z: 5, at: Coordinate(latitude: 27, longitude: 51))
        XCTAssertEqual(MapRenderer.name(of: persian, languages: .preferring(["sv"])), "Persiska viken")
        XCTAssertEqual(MapRenderer.name(of: persian, languages: .preferring(["de"])), "Persischer Golf")
        let japan = try waterLabel("Sea of Japan", z: 5, at: Coordinate(latitude: 40, longitude: 135))
        XCTAssertEqual(MapRenderer.name(of: japan, languages: .preferring(["ko"])), "동해 (일본해)")
        XCTAssertEqual(MapRenderer.name(of: japan, languages: .preferring(["de"])), "Japanisches Meer")
        XCTAssertEqual(MapRenderer.name(of: japan, languages: .preferring(["it"])), "Mar del Giappone")
        let ontario = try waterLabel("Lake Ontario", z: 6, at: Coordinate(latitude: 43.6, longitude: -77.9))
        XCTAssertEqual(MapRenderer.name(of: ontario, languages: .preferring(["de"])), "Ontariosee")
    }

    // MARK: Borders

    /// The nearest border of a kind to a point in the zoom 7 tile, in kilometres (nil: none in the tile).
    func border(_ kind: String, near c: Coordinate, disputed: Bool? = nil) throws -> Double? {
        let renderer = try renderer()
        let u = WebMercator.unitPoint(c), n = 128.0
        let key = TileKey(z: 7, x: Int(Double(u.x) * n), y: Int(Double(u.y) * n))
        guard let layer = renderer.sourceTile(key)?.layers["boundaries"] else { return nil }
        let px = (Double(u.x) * n - Double(key.x)) * layer.extent, py = (Double(u.y) * n - Double(key.y)) * layer.extent
        let kmPerUnit = 40_075 * cos(c.latitude * .pi / 180) / n / layer.extent
        var best: Double?
        for feature in layer.features where feature["kind"]?.string == kind {
            let isDisputed = feature["disputed"] == .bool(true)
            if let disputed, disputed != isDisputed { continue }
            for i in feature.partEnds.indices {
                let part = Array(feature.part(i))
                for (a, b) in zip(part, part.dropFirst()) {
                    let d = Self.distance(CGPoint(x: px, y: py), a, b) * kmPerUnit
                    best = min(best ?? .infinity, d)
                }
            }
        }
        return best
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let t = max(0, min(1, ((Double(p.x - a.x)) * dx + Double(p.y - a.y) * dy) / max(1e-9, dx * dx + dy * dy)))
        return hypot(Double(p.x) - Double(a.x) - t * dx, Double(p.y) - Double(a.y) - t * dy)
    }

    func testNoLineOfAnOccupationIsDrawnAsAStateBorder() throws {
        // Crimea's isthmus: no country border (the build has a disputed one there)
        XCTAssertGreaterThan(try border("country", near: Coordinate(latitude: 46.15, longitude: 33.69)) ?? .infinity, 15)
        XCTAssertGreaterThan(try border("country", near: Coordinate(latitude: 46.05, longitude: 34.55)) ?? .infinity, 15)
        // The Golan Heights' ceasefire line: none; Syria's border with Israel west of the Golan stays
        XCTAssertGreaterThan(try border("country", near: Coordinate(latitude: 33.05, longitude: 35.85)) ?? .infinity, 5)
        XCTAssertLessThan(try border("country", near: Coordinate(latitude: 32.95, longitude: 35.62)) ?? .infinity, 5)
        // Inside Western Sahara (the Moroccan berm runs there): no country border; its border with Morocco
        // at 27°40' N: a disputed country border; with Mauritania (26° N, 12° W): a country border
        for (lat, lon) in [(27.0, -11.0), (26.6, -9.5), (25.0, -13.5), (24.0, -14.8), (23.0, -15.5)] {
            XCTAssertGreaterThan(try border("country", near: Coordinate(latitude: lat, longitude: lon)) ?? .infinity, 15, "\(lat), \(lon)")
        }
        XCTAssertLessThan(try border("country", near: Coordinate(latitude: 27.67, longitude: -11.0), disputed: true) ?? .infinity, 5)
        XCTAssertLessThan(try border("country", near: Coordinate(latitude: 27.67, longitude: -12.5), disputed: true) ?? .infinity, 5)
        XCTAssertLessThan(try border("country", near: Coordinate(latitude: 26.0, longitude: -12.0)) ?? .infinity, 5)
        // Lines that stay: the West Bank's Green Line, Gaza's, Kashmir's line of control (disputed)
        XCTAssertLessThan(try border("country", near: Coordinate(latitude: 32.19, longitude: 34.97)) ?? .infinity, 5)
        XCTAssertLessThan(try border("country", near: Coordinate(latitude: 31.40, longitude: 34.38)) ?? .infinity, 5)
        XCTAssertLessThan(try border("country", near: Coordinate(latitude: 34.40, longitude: 74.00), disputed: true) ?? .infinity, 15)
    }
}
