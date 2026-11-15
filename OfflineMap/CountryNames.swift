import Foundation

/// The name the app gives a country: the system's (Unicode CLDR through
/// `Locale`), except where the map's political positions name it otherwise
/// (CLAUDE.md, "Political positions"): PS is "Palestine" in each language,
/// CLDR's short form of the region name (cldr-json, cldr-localenames-full,
/// territories "PS-alt-short"), not the system's "Palestinian Territories".
public enum CountryNames {
    /// By ISO 3166 code, then by the app's language codes (`MapLanguages.supported`)
    static let overrides: [String: [String: String]] = [
        "PS": [
            "en": "Palestine", "de": "Palästina", "fr": "Palestine", "es": "Palestina", "it": "Palestina",
            "pt-BR": "Palestina", "nl": "Palestina", "pl": "Palestyna", "sv": "Palestina", "da": "Palæstina",
            "nb": "Palestina", "fi": "Palestiina", "cs": "Palestina", "tr": "Filistin", "ru": "Палестина",
            "uk": "Палестина", "ja": "パレスチナ", "ko": "팔레스타인", "zh-Hans": "巴勒斯坦", "zh-Hant": "巴勒斯坦",
        ],
    ]

    /// The country's name in the locale's language, nil for an unknown code.
    public static func name(_ code: String, locale: Locale = .current) -> String? {
        if let names = overrides[code] {
            let language = MapLanguages.code(for: locale.identifier) ?? "en"
            return names[language] ?? names["en"]
        }
        return locale.localizedString(forRegionCode: code)
    }
}
