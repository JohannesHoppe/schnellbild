import Foundation

/// One sound or subtitle track of the video playing, as its player names it.
struct MediaTrack: Equatable, Identifiable, Sendable {
    /// The player's own number for it (AVKit: its place among the options,
    /// VLC: its elementary stream id).
    let id: Int
    /// What the menus show: the track's title and language.
    let name: String
    /// Its language as a two-letter code where there is one ("en", "de"),
    /// so a choice made in one player is found in the other.
    let language: String?

    init(id: Int, name: String, language: String?) {
        self.id = id
        self.name = name
        self.language = language.flatMap(Self.languageCode)
    }

    /// "eng", "en-US", "ger" … as "en", "de": the language without region.
    static func languageCode(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, text != "und", text != "unknown" else { return nil }
        // ISO 639-2's bibliographic codes, which Foundation doesn't take
        let bibliographic = ["ger": "de", "fre": "fr", "dut": "nl", "chi": "zh", "cze": "cs", "gre": "el",
                             "per": "fa", "rum": "ro", "slo": "sk", "wel": "cy", "ice": "is", "arm": "hy",
                             "baq": "eu", "bur": "my", "geo": "ka", "mac": "mk", "mao": "mi", "may": "ms", "tib": "bo", "alb": "sq"]
        if let code = bibliographic[text] { return code }
        let language = Locale.Language(identifier: text)
        return language.languageCode?.identifier(.alpha2) ?? language.languageCode?.identifier ?? text
    }

    /// The name shown: the title the file gives the track and its language
    /// in the user's language ("Commentary (English)"); the language alone
    /// when the title only names it; "Track 2" when the file says neither.
    static func name(title: String?, language: String?, number: Int) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let code = language.flatMap(languageCode)
        let languageName = code.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        guard let title else { return languageName ?? String(localized: "Track \(number)") }
        guard let code, let languageName else { return title }
        // A title that is the language's name, in any of the names it goes by
        let names = [languageName, Locale(identifier: "en").localizedString(forLanguageCode: code),
                     Locale(identifier: code).localizedString(forLanguageCode: code), code]
        if names.contains(where: { $0?.caseInsensitiveCompare(title) == .orderedSame }) { return languageName }
        return "\(title) (\(languageName))"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The tracks of the video playing and which of them are on.
struct VideoTracks: Equatable, Sendable {
    var audio: [MediaTrack] = []
    var subtitles: [MediaTrack] = []
    /// The sound track playing (nil: none known).
    var audioID: Int?
    /// The subtitles shown (nil: none).
    var subtitleID: Int?

    var currentAudio: MediaTrack? { audio.first { $0.id == audioID } }
    var currentSubtitle: MediaTrack? { subtitles.first { $0.id == subtitleID } }

    /// The subtitles to show for the user's choice: none when they are off;
    /// else the track in the language chosen last, else the one shown
    /// already (the file's default), else the first.
    static func subtitleChoice(in tracks: VideoTracks, show: Bool, language: String?) -> Int? {
        guard show, !tracks.subtitles.isEmpty else { return nil }
        if let language, let track = tracks.subtitles.first(where: { $0.language == language }) { return track.id }
        if let current = tracks.currentSubtitle { return current.id }
        return tracks.subtitles.first?.id
    }

    /// The sound track for the user's choice: the one in the language
    /// chosen last, else the one playing (the file's default).
    static func audioChoice(in tracks: VideoTracks, language: String?) -> Int? {
        if let language, let track = tracks.audio.first(where: { $0.language == language }) { return track.id }
        return tracks.audioID ?? tracks.audio.first?.id
    }

    /// The next one round: each subtitle track, then none, then the first again.
    static func nextSubtitle(after current: Int?, in subtitles: [MediaTrack]) -> Int? {
        guard !subtitles.isEmpty else { return nil }
        guard let current, let index = subtitles.firstIndex(where: { $0.id == current }) else { return subtitles[0].id }
        return index + 1 < subtitles.count ? subtitles[index + 1].id : nil
    }
}

/// The speeds a video plays at: the same steps for both players (AVKit
/// keeps the pitch with `AVAudioTimePitchAlgorithm.spectral`, VLC by itself).
enum PlaybackSpeed {
    static let steps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// One step faster (`by` 1) or slower (-1), held at the ends.
    static func step(from speed: Double, by direction: Int) -> Double {
        if direction > 0 { return steps.first { $0 > speed + 0.001 } ?? steps[steps.count - 1] }
        return steps.last { $0 < speed - 0.001 } ?? steps[0]
    }

    /// "1.5×", in the user's way of writing numbers ("1,5×").
    static func text(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
