import Foundation
import Compression
import VLCFrames

/// One line of a subtitle track: when it shows, its text (tags taken out,
/// one string per line of text), and for ASS the style it names and the
/// event as the file holds it.
struct SubtitleLine: Equatable {
    var start: Double       // seconds
    var end: Double
    var text: [String]
    var style: String?
    var ass: ASSEvent? = nil
}

/// An ASS event's own fields: its text with the override tags, its order
/// in the script and its margins (0: the style's).
struct ASSEvent: Equatable {
    var text: String
    var readOrder = 0
    var marginL = 0.0
    var marginR = 0.0
    var marginV = 0.0
}

/// A subtitle track's lines around a time, read from the file by the app
/// itself: VLC reads a track chosen in the middle of a video only from its
/// next line on, so the app draws the line running then
/// (`SubtitleOverlay`). Text subtitles only: Matroska's SubRip
/// (`S_TEXT/UTF8`) and ASS / SSA (`S_TEXT/ASS`, `S_TEXT/SSA`, `S_ASS`,
/// `S_SSA`, compressed with zlib or header stripping or not), MP4's 3GPP
/// timed text (`tx3g`). Every size and offset is checked against the file;
/// a damaged file gives no lines.
struct SubtitleTrackLines: Equatable {
    enum Kind: Equatable {
        /// Drawn by VLC's text renderer (freetype) in its own style.
        case text
        /// Drawn by libass in the track's styles (`ASSStyles`).
        case ass(ASSStyles)
    }
    var kind: Kind
    /// Sorted by start.
    var lines: [SubtitleLine]
}

enum SubtitleReader {
    /// How far back a line may have begun and still run (and how far ahead
    /// lines are read).
    static let reach: Double = 20
    /// How long a read may take (a file on a share that answers slowly):
    /// past it there are no lines, and VLC takes the track at once.
    static let budget: Double = 2

    /// The lines of the `index`-th subtitle track (in the file's order, as
    /// VLC lists them) that run in `from ... to`; nil when the file or the
    /// track can't be read this way, the read takes longer than `budget`
    /// seconds or its task is cancelled.
    static func lines(of url: URL, subtitleIndex index: Int, from: Double, to: Double, budget: Double = budget) -> SubtitleTrackLines? {
        guard let bytes = FileBytes(url) else { return nil }
        return lines(in: bytes, subtitleIndex: index, from: from, to: to, budget: budget)
    }

    static func lines(in bytes: ByteSource, subtitleIndex index: Int, from: Double, to: Double,
                      budget: Double = budget) -> SubtitleTrackLines? {
        guard let head = bytes.read(at: 0, count: Int(min(400, bytes.size))) else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        let over = { Task.isCancelled || Date() > deadline }
        switch VLCSafety.container(in: Data(head))?.demux {
        case "mkv": return MatroskaSubtitles.lines(bytes, subtitleIndex: index, from: from, to: to, over: over)
        case "mp4": return MP4Subtitles.lines(bytes, subtitleIndex: index, from: from, to: to, over: over)
        default:    return nil
        }
    }

    /// A time in a file's units, held in UInt64's range (none before 0).
    static func units(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value < 18_000_000_000_000_000_000 ? UInt64(value) : .max
    }

    /// SubRip's text without its tags (`<i>`, `<font …>`), split into lines.
    static func plainText(_ text: String) -> [String] {
        var out = ""
        var inTag = false
        for character in text {
            if character == "<" { inTag = true; continue }
            if inTag { if character == ">" { inTag = false }; continue }
            out.append(character)
        }
        return out.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// An ASS event's text without its override blocks (`{\i1}`), `\N` and
    /// `\n` as new lines, `\h` as a space.
    static func assText(_ text: String) -> [String] {
        var out = ""
        var inBlock = false
        for character in text {
            if character == "{" { inBlock = true; continue }
            if inBlock { if character == "}" { inBlock = false }; continue }
            out.append(character)
        }
        out = out.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        return out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - ASS styles

/// What libass draws a line with: the script's resolution and its styles
/// (`[Script Info]` PlayResY, `[V4+ Styles]` / `[V4 Styles]`).
struct ASSStyles: Equatable {
    struct Style: Equatable {
        var font = "Arial"
        var size = 18.0
        var primary = RGBA(r: 1, g: 1, b: 1, a: 1)
        var outlineColour = RGBA(r: 0, g: 0, b: 0, a: 1)
        var back = RGBA(r: 0, g: 0, b: 0, a: 1)
        var bold = false
        var italic = false
        var underline = false
        var strikeOut = false
        var outline = 2.0
        var shadow = 2.0
        /// Numpad alignment (1 … 9), 2 bottom centre.
        var alignment = 2
        var marginL = 20.0
        var marginR = 20.0
        var marginV = 20.0
    }
    struct RGBA: Equatable { var r, g, b, a: Double }

    var playResX = 384.0
    var playResY = 288.0
    /// 0 and 3: long lines broken into lines of about the same width, 1: at
    /// the end of each line, 2: not at all (and `\n` breaks a line).
    var wrapStyle = 0
    var styles: [String: Style] = [:]

    func style(_ name: String?) -> Style {
        if let name, let style = styles[name] ?? styles[name.trimmingCharacters(in: .whitespaces).lowercased()] { return style }
        return styles["default"] ?? styles.values.first ?? Style()
    }

    /// From a script's header (Matroska's CodecPrivate).
    static func parse(_ header: String) -> ASSStyles {
        var result = ASSStyles()
        var section = ""
        var format: [String] = []
        var playResX: Double?
        var playResY: Double?
        for raw in header.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if section == "[script info]" {
                if key == "playresy" { playResY = number(value) }
                if key == "playresx" { playResX = number(value) }
                if key == "wrapstyle" { result.wrapStyle = Int(value) ?? 0 }
            } else if section.contains("styles") {
                let fields = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if key == "format" { format = fields.map { $0.lowercased() } }
                if key == "style", !format.isEmpty {
                    var style = Style()
                    var name = ""
                    for (i, field) in format.enumerated() {
                        // The last field may hold commas no more (names come first)
                        guard i < fields.count else { break }
                        let v = fields[i]
                        switch field {
                        case "name": name = v
                        case "fontname": style.font = v
                        case "fontsize": style.size = number(v) ?? style.size
                        case "primarycolour": style.primary = colour(v) ?? style.primary
                        case "outlinecolour": style.outlineColour = colour(v) ?? style.outlineColour
                        case "backcolour": style.back = colour(v) ?? style.back
                        case "bold": style.bold = (Int(v) ?? 0) != 0
                        case "italic": style.italic = (Int(v) ?? 0) != 0
                        case "underline": style.underline = (Int(v) ?? 0) != 0
                        case "strikeout": style.strikeOut = (Int(v) ?? 0) != 0
                        case "outline": style.outline = number(v) ?? style.outline
                        case "shadow": style.shadow = number(v) ?? style.shadow
                        case "alignment":
                            let a = Int(v) ?? 2
                            // SSA (V4) numbers its alignments otherwise: 1-3 bottom, +4 top, +8 middle
                            style.alignment = section.contains("v4+") ? a : ASSStyles.numpad(ssa: a)
                        case "marginl": style.marginL = number(v) ?? style.marginL
                        case "marginr": style.marginR = number(v) ?? style.marginR
                        case "marginv": style.marginV = number(v) ?? style.marginV
                        default: break
                        }
                    }
                    result.styles[name.lowercased()] = style
                }
            }
        }
        // libass's rule: a missing PlayResY follows PlayResX (4:3), else 288,
        // and a missing PlayResX follows PlayResY (4:3; 1280 for 1024, as libass)
        result.playResY = playResY ?? playResX.map { $0 == 1280 ? 1024 : $0 * 3 / 4 } ?? 288
        if result.playResY <= 0 { result.playResY = 288 }
        result.playResX = playResX ?? (result.playResY == 1024 ? 1280 : result.playResY * 4 / 3)
        if result.playResX <= 0 { result.playResX = result.playResY * 4 / 3 }
        return result
    }

    /// A number of a script (a size, a margin, a position): nil for none,
    /// and for NaN, infinity and anything beyond a million, which no script
    /// means and drawing can't take.
    static func number<S: StringProtocol>(_ text: S) -> Double? {
        guard let value = Double(text), value.isFinite, abs(value) <= 1_000_000 else { return nil }
        return value
    }

    /// SSA's alignment (1 … 3 at the bottom, 4 added for the top, 8 for the
    /// middle) as the numpad's (1 … 9).
    static func numpad(ssa a: Int) -> Int {
        a > 8 ? a - 5 : a > 4 ? a + 2 : a
    }

    /// `&HAABBGGRR` (alpha 00 opaque) or a decimal number.
    static func colour(_ text: String) -> RGBA? {
        var t = text.uppercased().replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: "")
        let value: UInt32?
        if text.uppercased().hasPrefix("&H") {
            if t.count > 8 { t = String(t.suffix(8)) }
            value = UInt32(t, radix: 16)
        } else {
            value = UInt32(t)
        }
        guard let value else { return nil }
        return RGBA(r: Double(value & 0xFF) / 255, g: Double(value >> 8 & 0xFF) / 255,
                    b: Double(value >> 16 & 0xFF) / 255, a: 1 - Double(value >> 24 & 0xFF) / 255)
    }
}

// MARK: - ASS override tags

/// An ASS event's text as libass lays it out: runs of text, each in its own
/// style after the override tags before it (`{\b1}`, `{\c&H0000FF&}` …),
/// in lines (`\N`), with the event's alignment and position.
///
/// Read: `\an` and `\a` (alignment), `\pos`, `\b`, `\i`, `\u`, `\s`, `\c`
/// and `\1c` … `\4c`, `\alpha` and `\1a` … `\4a`, `\fs` (also `\fs+` /
/// `\fs-`), `\fn`, `\bord`, `\shad`, `\r` (back to the event's or a named
/// style), `\q` (wrapping), `\p` (a drawing, left out), `\N`, `\n` (a line
/// break with WrapStyle 2, else a space), `\h`. As libass, the first `\an` / `\a` and
/// the first `\pos` of an event count, and a tag without its value goes
/// back to the style's. Every other tag is passed over (see `SubtitleOverlay`).
struct ASSText: Equatable {
    /// What a run is drawn with: the style, changed by the tags before it.
    struct RunStyle: Equatable {
        var font: String
        var size: Double
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strikeOut: Bool
        var primary: ASSStyles.RGBA
        var outlineColour: ASSStyles.RGBA
        var back: ASSStyles.RGBA
        var outline: Double
        var shadow: Double

        init(_ style: ASSStyles.Style) {
            font = style.font; size = style.size; bold = style.bold; italic = style.italic
            underline = style.underline; strikeOut = style.strikeOut
            primary = style.primary; outlineColour = style.outlineColour; back = style.back
            outline = style.outline; shadow = style.shadow
        }
    }
    struct Run: Equatable {
        var text: String
        var style: RunStyle
    }
    struct Point: Equatable { var x, y: Double }

    /// One array of runs per line (`\N`).
    var lines: [[Run]]
    /// Numpad alignment, 1 … 9.
    var alignment: Int
    /// `\pos`: where the alignment's point of the text lies, in the
    /// script's coordinates (PlayResX × PlayResY).
    var position: Point?
    /// The track's WrapStyle, or the event's `\q`.
    var wrapStyle: Int

    static func parse(_ text: String, style name: String?, in styles: ASSStyles) -> ASSText {
        let base = styles.style(name)
        var style = RunStyle(base)
        var alignment: Int?
        var position: Point?
        var lines: [[Run]] = [[]]
        var drawing = false
        var wrapStyle = styles.wrapStyle
        func append(_ string: String) {
            guard !drawing, !string.isEmpty else { return }
            if let last = lines[lines.count - 1].last, last.style == style {
                lines[lines.count - 1][lines[lines.count - 1].count - 1].text += string
            } else {
                lines[lines.count - 1].append(Run(text: string, style: style))
            }
        }
        let characters = Array(text)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == "{", let close = characters[i...].firstIndex(of: "}") {
                for (tag, value) in tags(String(characters[(i + 1)..<close])) {
                    apply(tag, value, to: &style, base: base, styles: styles, alignment: &alignment, position: &position,
                          drawing: &drawing, wrapStyle: &wrapStyle)
                }
                i = close + 1
                continue
            }
            if c == "\\", i + 1 < characters.count {
                switch characters[i + 1] {
                case "N": if !drawing { lines.append([]) }; i += 2; continue
                case "n":
                    if wrapStyle == 2 { if !drawing { lines.append([]) } } else { append(" ") }
                    i += 2; continue
                case "h": append("\u{00A0}"); i += 2; continue
                default: break
                }
            }
            append(String(c))
            i += 1
        }
        return ASSText(lines: lines, alignment: alignment ?? base.alignment, position: position, wrapStyle: wrapStyle)
    }

    /// The tags of one override block, each with its value: `\fs20` is
    /// ("fs", "20"), `\pos(1,2)` ("pos", "1,2"), `\fnArial Bold` ("fn",
    /// "Arial Bold"); a `\t(…)` keeps its own tags inside its value.
    static func tags(_ block: String) -> [(String, String)] {
        let characters = Array(block)
        var result: [(String, String)] = []
        var i = 0
        while i < characters.count {
            guard characters[i] == "\\" else { i += 1; continue }
            i += 1
            var name = ""
            // \1c … \4c, \1a … \4a
            if i + 1 < characters.count, ("1"..."4").contains(characters[i]), "ca".contains(characters[i + 1]) {
                name = String(characters[i...(i + 1)])
                i += 2
            } else {
                while i < characters.count, characters[i].isLetter { name.append(characters[i]); i += 1 }
            }
            // Names that run on into their value: \fn<font>, \r<style>
            var value = ""
            if name.hasPrefix("fn"), name != "fn" { value = String(name.dropFirst(2)); name = "fn" }
            else if name.hasPrefix("r"), name != "r" { value = String(name.dropFirst()); name = "r" }
            if i < characters.count, characters[i] == "(" {
                var depth = 0
                var j = i
                while j < characters.count {
                    if characters[j] == "(" { depth += 1 }
                    if characters[j] == ")" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                value = String(characters[(i + 1)..<min(j, characters.count)])
                i = min(j + 1, characters.count)
            } else {
                while i < characters.count, characters[i] != "\\" { value.append(characters[i]); i += 1 }
            }
            if !name.isEmpty { result.append((name, value.trimmingCharacters(in: .whitespaces))) }
        }
        return result
    }

    private static func apply(_ tag: String, _ value: String, to style: inout RunStyle, base: ASSStyles.Style,
                              styles: ASSStyles, alignment: inout Int?, position: inout Point?, drawing: inout Bool,
                              wrapStyle: inout Int) {
        let number = ASSStyles.number(value)
        // 0 or 1; else the style's
        func flag(_ fallback: Bool) -> Bool { Int(value).flatMap { $0 == 0 || $0 == 1 ? $0 == 1 : nil } ?? fallback }
        // &HBBGGRR&: the colour only, its alpha stays; none: the style's
        func colour(_ current: ASSStyles.RGBA, _ fallback: ASSStyles.RGBA) -> ASSStyles.RGBA {
            let from: UInt32? = value.isEmpty ? nil : UInt32(hex(value).prefix(8), radix: 16)
            guard value.isEmpty || from != nil else { return current }
            guard let v = from else { return ASSStyles.RGBA(r: fallback.r, g: fallback.g, b: fallback.b, a: current.a) }
            return ASSStyles.RGBA(r: Double(v & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v >> 16 & 0xFF) / 255,
                                  a: current.a)
        }
        // &HAA&: the alpha only (00 opaque)
        func alpha(_ current: ASSStyles.RGBA, _ fallback: ASSStyles.RGBA) -> ASSStyles.RGBA {
            let from: UInt32? = value.isEmpty ? nil : UInt32(hex(value).prefix(8), radix: 16)
            guard value.isEmpty || from != nil else { return current }
            let a = from.map { 1 - Double($0 & 0xFF) / 255 } ?? fallback.a
            return ASSStyles.RGBA(r: current.r, g: current.g, b: current.b, a: a)
        }
        switch tag {
        case "an":
            if alignment == nil { alignment = Int(value).flatMap { (1...9).contains($0) ? $0 : nil } ?? base.alignment }
        case "a":
            // SSA's numbers; libass takes \a4 and \a8 as \a5 (as VSFilter)
            if alignment == nil {
                if let a = Int(value), (1...11).contains(a) { alignment = ASSStyles.numpad(ssa: a & 3 == 0 ? 5 : a) }
                else { alignment = base.alignment }
            }
        case "pos":
            let parts = value.split(separator: ",").compactMap { ASSStyles.number($0.trimmingCharacters(in: .whitespaces)) }
            if position == nil, parts.count == 2 { position = Point(x: parts[0], y: parts[1]) }
        case "b":
            // 0, 1 or a weight (from 100; bold from 600); else the style's
            if let n = Int(value), n == 0 || n == 1 || n >= 100 { style.bold = n == 1 || n >= 600 } else { style.bold = base.bold }
        case "i": style.italic = flag(base.italic)
        case "u": style.underline = flag(base.underline)
        case "s": style.strikeOut = flag(base.strikeOut)
        case "c", "1c": style.primary = colour(style.primary, base.primary)
        case "3c": style.outlineColour = colour(style.outlineColour, base.outlineColour)
        case "4c": style.back = colour(style.back, base.back)
        case "alpha":
            style.primary = alpha(style.primary, base.primary)
            style.outlineColour = alpha(style.outlineColour, base.outlineColour)
            style.back = alpha(style.back, base.back)
        case "1a": style.primary = alpha(style.primary, base.primary)
        case "3a": style.outlineColour = alpha(style.outlineColour, base.outlineColour)
        case "4a": style.back = alpha(style.back, base.back)
        case "fs":
            // \fs+n / \fs-n: n tenths more or less (libass)
            var size = 0.0
            if let n = number { size = value.hasPrefix("+") || value.hasPrefix("-") ? style.size * (1 + n / 10) : n }
            style.size = size > 0 && size <= 1_000_000 ? size : base.size
        case "fn": style.font = value.isEmpty || value == "0" ? base.font : value
        case "bord": style.outline = number.map { max($0, 0) } ?? base.outline
        case "shad": style.shadow = number.map { max($0, 0) } ?? base.shadow
        case "r": style = RunStyle(value.isEmpty ? base : styles.style(value))
        case "p": drawing = (number ?? 0) > 0
        case "q": wrapStyle = Int(value).flatMap { (0...3).contains($0) ? $0 : nil } ?? styles.wrapStyle
        default: break   // \2c \2a (karaoke), \k, \t, \move, \fad, \fscx, \fsp, \fr, \clip, \blur, \be …
        }
    }

    /// The hex digits of `&H00FF00&` and its kin.
    private static func hex(_ value: String) -> String {
        value.uppercased().replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "H", with: "")
    }
}

// MARK: - Matroska

/// Matroska's subtitle blocks, read in parts: the head (Info, Tracks, Cues),
/// then the clusters from the cue before `from - reach` on, block by block,
/// only the subtitle track's blocks read whole.
enum MatroskaSubtitles {
    static let largestElement = 16 << 20
    static let largestBlocks = 200_000

    private struct Track {
        var number: UInt64 = 0
        var type: UInt64 = 0
        var codec = ""
        var privateData = Data()
        /// ContentCompAlgo: 0 zlib, 3 header stripping; nil none.
        var compression: UInt64?
        var stripped = Data()
    }

    static func lines(_ source: ByteSource, subtitleIndex index: Int, from: Double, to: Double,
                      over: () -> Bool = { false }) -> SubtitleTrackLines? {
        var reader = EBMLFile(source: WindowedBytes(source))
        guard let ebml = reader.header(at: 0), ebml.id == 0x1A45DFA3, let ebmlSize = ebml.size,
              let segment = reader.header(at: ebml.dataStart + ebmlSize), segment.id == 0x18538067 else { return nil }
        let segmentStart = segment.dataStart
        let segmentEnd = segment.size.map { min(segmentStart + $0, source.size) } ?? source.size
        /// A place the file gives relative to the segment's data; nil when
        /// it lies outside the segment.
        func inSegment(_ position: UInt64) -> UInt64? {
            let (at, overflow) = segmentStart.addingReportingOverflow(position)
            return overflow || at >= segmentEnd ? nil : at
        }
        var scale: UInt64 = 1_000_000
        var tracks: [Track] = []
        var cues: [(time: UInt64, position: UInt64)] = []
        var cuesAt: UInt64?
        var firstCluster: UInt64?
        // The segment's top level up to the first cluster (Cues may also come later)
        var at = segmentStart
        var seen = 0
        while at < segmentEnd, seen < 10_000, let element = reader.header(at: at) {
            seen += 1
            switch element.id {
            case 0x1549A966:
                if let data = reader.body(element) { scale = parseInfo(data) ?? scale }
            case 0x1654AE6B:
                if let data = reader.body(element) { tracks = parseTracks(data) }
            case 0x114D9B74:   // SeekHead: where the Cues are
                if let data = reader.body(element), let position = cuesPosition(data) { cuesAt = inSegment(position) }
            case 0x1C53BB6B:
                if let data = reader.body(element) { cues = parseCues(data) }
            case 0x1F43B675:
                if firstCluster == nil { firstCluster = at }
            default: break
            }
            guard let size = element.size else { break }
            // Clusters are walked later: the Cues are read where the SeekHead says
            if element.id == 0x1F43B675 { break }
            at = element.dataStart + size
        }
        if cues.isEmpty, let cuesAt, let element = reader.header(at: cuesAt), element.id == 0x1C53BB6B,
           let data = reader.body(element) {
            cues = parseCues(data)
        }
        let subtitleTracks = tracks.filter { $0.type == 0x11 }
        guard index >= 0, index < subtitleTracks.count, let firstCluster, !over() else { return nil }
        let track = subtitleTracks[index]
        let ass = ["S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA"].contains(track.codec)
        guard ass || track.codec == "S_TEXT/UTF8" else { return nil }
        let unitsPerSecond = 1e9 / Double(max(scale, 1))
        // Where to begin: the last cue at or before `from - reach`, then the
        // last cluster from there that begins by then
        let startTime = SubtitleReader.units((from - SubtitleReader.reach) * unitsPerSecond)
        var clusterAt = firstCluster
        if let cue = cues.last(where: { $0.time <= startTime }), let place = inSegment(cue.position) { clusterAt = place }
        guard let begin = lastCluster(&reader, from: clusterAt, startingBy: startTime, end: segmentEnd, over: over) else { return nil }
        clusterAt = begin
        let stopTime = to * unitsPerSecond
        var lines: [SubtitleLine] = []
        var blocks = 0
        // Cluster by cluster, block by block
        clusters: while clusterAt < segmentEnd, let cluster = reader.header(at: clusterAt), cluster.id == 0x1F43B675 {
            let end = cluster.size.map { min(cluster.dataStart + $0, segmentEnd) } ?? segmentEnd
            var clusterTime: UInt64 = 0
            var child = cluster.dataStart
            while child < end, let element = reader.header(at: child) {
                blocks += 1
                if blocks > largestBlocks { break clusters }
                if blocks % 256 == 0, over() { return nil }
                guard let size = element.size, element.dataStart + size <= end else { break clusters }
                switch element.id {
                case 0xE7:
                    if let data = reader.body(element) { clusterTime = data.reduce(0) { $0 << 8 | UInt64($1) } }
                    if Double(clusterTime) > stopTime { break clusters }
                case 0xA0:   // BlockGroup: Block + BlockDuration
                    if let line = blockGroup(&reader, element, track: track, clusterTime: clusterTime, unitsPerSecond: unitsPerSecond, ass: ass) {
                        lines.append(line)
                    }
                case 0xA3:   // SimpleBlock: no duration, it runs to the next line
                    if let line = block(&reader, at: element.dataStart, size: size, track: track, clusterTime: clusterTime,
                                        duration: nil, unitsPerSecond: unitsPerSecond, ass: ass) {
                        lines.append(line)
                    }
                default: break
                }
                child = element.dataStart + size
            }
            if cluster.size == nil { break }
            clusterAt = end
        }
        if over() { return nil }
        lines.sort { $0.start < $1.start }
        // A line without a duration ends where the next begins (at most 5 s)
        for i in lines.indices where lines[i].end <= lines[i].start {
            lines[i].end = i + 1 < lines.count ? lines[i + 1].start : lines[i].start + 5
            lines[i].end = min(lines[i].end, lines[i].start + 5)
        }
        let kind: SubtitleTrackLines.Kind = ass ? .ass(ASSStyles.parse(String(decoding: track.privateData, as: UTF8.self))) : .text
        return SubtitleTrackLines(kind: kind, lines: lines.filter { $0.end > from && $0.start <= to })
    }

    /// The last cluster from `start` on that begins at `time` or before,
    /// found by the clusters' heads alone (one read each: the cluster's
    /// header and its time, its first element), so a file without Cues
    /// isn't read block by block from its start. A cluster of unknown size
    /// (a live recording) or without its time first ends the search there.
    /// Nil when the read is over (`over`).
    private static func lastCluster(_ reader: inout EBMLFile, from start: UInt64, startingBy time: UInt64, end: UInt64,
                                    over: () -> Bool) -> UInt64? {
        var found = start
        var at = start
        var steps = 0
        while at < end {
            steps += 1
            if steps % 64 == 0, over() { return nil }
            guard let head = reader.source.read(at: at, count: Int(min(32, end - at)), direct: true) else { break }
            var data = EBMLData(data: Data(head))
            guard let cluster = data.element(checkingSize: false), cluster.id == 0x1F43B675, let size = cluster.size else { break }
            let dataStart = at + UInt64(data.position)
            guard let first = data.element(checkingSize: false), first.id == 0xE7, let length = first.size, length <= 8,
                  let bytes = data.bytes(first) else { break }
            if bytes.reduce(UInt64(0), { $0 << 8 | UInt64($1) }) > time { break }
            found = at
            at = dataStart + size
        }
        return found
    }

    private static func blockGroup(_ reader: inout EBMLFile, _ group: EBMLFile.Header, track: Track, clusterTime: UInt64,
                                   unitsPerSecond: Double, ass: Bool) -> SubtitleLine? {
        // Its Block's track number first (a video frame isn't read whole)
        guard let size = group.size, let head = reader.source.read(at: group.dataStart, count: Int(min(size, 24))) else { return nil }
        var peek = EBMLData(data: Data(head))
        if let first = peek.element(checkingSize: false), first.id == 0xA1,
           let (number, _) = EBMLData.vint(peek.data, peek.position), number != track.number { return nil }
        guard size <= UInt64(largestElement), let data = reader.body(group) else { return nil }
        var memory = EBMLData(data: data)
        var block: Data?
        var duration: UInt64?
        while let element = memory.element() {
            switch element.id {
            case 0xA1: block = memory.bytes(element)
            case 0x9B: duration = memory.bytes(element).map { $0.reduce(0) { $0 << 8 | UInt64($1) } }
            default: _ = memory.bytes(element)
            }
        }
        guard let block else { return nil }
        return line(fromBlock: block, track: track, clusterTime: clusterTime, duration: duration, unitsPerSecond: unitsPerSecond, ass: ass)
    }

    private static func block(_ reader: inout EBMLFile, at start: UInt64, size: UInt64, track: Track, clusterTime: UInt64,
                              duration: UInt64?, unitsPerSecond: Double, ass: Bool) -> SubtitleLine? {
        // The track number first: only the subtitle track's blocks are read whole
        guard let head = reader.source.read(at: start, count: Int(min(size, 8))), let (number, _) = EBMLData.vint(head, 0),
              number == track.number, size <= UInt64(largestElement),
              let data = reader.source.read(at: start, count: Int(size)) else { return nil }
        return line(fromBlock: Data(data), track: track, clusterTime: clusterTime, duration: duration, unitsPerSecond: unitsPerSecond, ass: ass)
    }

    private static func line(fromBlock block: Data, track: Track, clusterTime: UInt64, duration: UInt64?,
                             unitsPerSecond: Double, ass: Bool) -> SubtitleLine? {
        let bytes = [UInt8](block)
        guard let (number, length) = EBMLData.vint(bytes, 0), number == track.number, bytes.count >= length + 3 else { return nil }
        let relative = Int16(bitPattern: UInt16(bytes[length]) << 8 | UInt16(bytes[length + 1]))
        let flags = bytes[length + 2]
        guard flags & 0x06 == 0 else { return nil }   // laced: not for subtitles
        var payload = Data(bytes[(length + 3)...])
        switch track.compression {
        case 0?: guard let inflated = inflate(payload) else { return nil }; payload = inflated
        case 3?: payload = track.stripped + payload
        case nil: break
        default: return nil
        }
        let time = (Double(clusterTime) + Double(relative)) / unitsPerSecond
        let end = duration.map { time + Double($0) / unitsPerSecond } ?? time
        let text = String(decoding: payload, as: UTF8.self)
        if ass {
            // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return nil }
            func number(_ i: Int) -> Double { ASSStyles.number(fields[i].trimmingCharacters(in: .whitespaces)) ?? 0 }
            // ReadOrder is a whole number; anything else (NaN, 1e999) is none
            let readOrder = Int(fields[0].trimmingCharacters(in: .whitespaces)) ?? 0
            let event = ASSEvent(text: String(fields[8]), readOrder: readOrder, marginL: number(4), marginR: number(5),
                                 marginV: number(6))
            return SubtitleLine(start: time, end: end, text: SubtitleReader.assText(String(fields[8])),
                                style: String(fields[2]).trimmingCharacters(in: .whitespaces), ass: event)
        }
        return SubtitleLine(start: time, end: end, text: SubtitleReader.plainText(text), style: nil)
    }

    /// zlib (RFC 1950): its two-byte header, then deflate.
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let deflated = data.dropFirst(2)
        let capacity = min(max(deflated.count * 8, 4096), 4 << 20)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { outBytes in
            deflated.withUnsafeBytes { inBytes in
                compression_decode_buffer(outBytes.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          inBytes.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    private static func parseInfo(_ data: Data) -> UInt64? {
        var reader = EBMLData(data: data)
        while let element = reader.element() {
            let body = reader.bytes(element)
            if element.id == 0x2AD7B1, let body { return max(1, body.reduce(0) { $0 << 8 | UInt64($1) }) }
        }
        return nil
    }

    private static func parseTracks(_ data: Data) -> [Track] {
        var tracks: [Track] = []
        var reader = EBMLData(data: data)
        while let entry = reader.element() {
            guard let body = reader.bytes(entry) else { break }
            guard entry.id == 0xAE else { continue }
            var track = Track()
            var fields = EBMLData(data: body)
            while let element = fields.element() {
                guard let value = fields.bytes(element) else { break }
                let number = value.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                switch element.id {
                case 0xD7: track.number = number
                case 0x83: track.type = number
                case 0x86: track.codec = String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
                case 0x63A2: track.privateData = value
                case 0x6D80: parseEncodings(value, into: &track)
                default: break
                }
            }
            tracks.append(track)
        }
        return tracks
    }

    /// ContentEncodings → ContentEncoding → ContentCompression (algorithm,
    /// settings: the bytes header stripping took off).
    private static func parseEncodings(_ data: Data, into track: inout Track) {
        var encodings = EBMLData(data: data)
        while let encoding = encodings.element() {
            guard let body = encodings.bytes(encoding), encoding.id == 0x6240 else { continue }
            var fields = EBMLData(data: body)
            while let element = fields.element() {
                guard let value = fields.bytes(element) else { break }
                if element.id == 0x5035 { track.compression = 255; return }   // encrypted
                guard element.id == 0x5034 else { continue }
                track.compression = 0
                var compression = EBMLData(data: value)
                while let item = compression.element() {
                    guard let v = compression.bytes(item) else { break }
                    if item.id == 0x4254 { track.compression = v.reduce(0) { $0 << 8 | UInt64($1) } }
                    if item.id == 0x4255 { track.stripped = v }
                }
            }
        }
    }

    /// SeekHead → Seek: the Cues' place (relative to the segment's data).
    private static func cuesPosition(_ data: Data) -> UInt64? {
        var reader = EBMLData(data: data)
        while let seek = reader.element() {
            guard let body = reader.bytes(seek) else { break }
            guard seek.id == 0x4DBB else { continue }
            var fields = EBMLData(data: body)
            var id: [UInt8] = []
            var position: UInt64?
            while let element = fields.element() {
                guard let value = fields.bytes(element) else { break }
                if element.id == 0x53AB { id = [UInt8](value) }
                if element.id == 0x53AC { position = value.reduce(0) { $0 << 8 | UInt64($1) } }
            }
            if id == [0x1C, 0x53, 0xBB, 0x6B], let position { return position }
        }
        return nil
    }

    private static func parseCues(_ data: Data) -> [(time: UInt64, position: UInt64)] {
        var cues: [(time: UInt64, position: UInt64)] = []
        var reader = EBMLData(data: data)
        while let point = reader.element(), cues.count < 1_000_000 {
            guard let body = reader.bytes(point) else { break }
            guard point.id == 0xBB else { continue }
            var fields = EBMLData(data: body)
            var time: UInt64?
            var position: UInt64?
            while let element = fields.element() {
                guard let value = fields.bytes(element) else { break }
                if element.id == 0xB3 { time = value.reduce(0) { $0 << 8 | UInt64($1) } }
                if element.id == 0xB7 {
                    var positions = EBMLData(data: value)
                    while let item = positions.element() {
                        guard let v = positions.bytes(item) else { break }
                        if item.id == 0xF1, position == nil { position = v.reduce(0) { $0 << 8 | UInt64($1) } }
                    }
                }
            }
            if let time, let position { cues.append((time, position)) }
        }
        return cues.sorted { $0.time < $1.time }
    }
}

/// EBML element headers read from a file.
struct EBMLFile {
    struct Header {
        let id: UInt32
        let size: UInt64?       // nil: unknown
        let dataStart: UInt64
    }
    let source: WindowedBytes

    func header(at offset: UInt64) -> Header? {
        guard offset < source.size, let bytes = source.read(at: offset, count: Int(min(12, source.size - offset))) else { return nil }
        var reader = EBMLData(data: Data(bytes))
        guard let element = reader.element(checkingSize: false) else { return nil }
        return Header(id: element.id, size: element.size, dataStart: offset + UInt64(reader.position))
    }

    func body(_ header: Header) -> Data? {
        guard let size = header.size, size <= UInt64(MatroskaSubtitles.largestElement),
              let bytes = source.read(at: header.dataStart, count: Int(size)) else { return nil }
        return Data(bytes)
    }
}

/// A file's bytes read through a window kept in memory: the heads of a
/// cluster's blocks lie close together, so one read (one round trip on a
/// network share) serves many of them.
final class WindowedBytes: ByteSource {
    static let window = 64 << 10
    let source: ByteSource
    private var start: UInt64 = 0
    private var bytes: [UInt8] = []

    init(_ source: ByteSource) { self.source = source }

    var size: UInt64 { source.size }

    func read(at offset: UInt64, count: Int) -> [UInt8]? { read(at: offset, count: count, direct: false) }

    /// `direct`: past the window, which stays as it is.
    func read(at offset: UInt64, count: Int, direct: Bool) -> [UInt8]? {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
        if offset >= start, offset - start <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - (offset - start) {
            let from = Int(offset - start)
            return Array(bytes[from..<from + count])
        }
        guard !direct, count <= Self.window else { return source.read(at: offset, count: count) }
        guard let fresh = source.read(at: offset, count: Int(min(UInt64(Self.window), size - offset))) else { return nil }
        start = offset
        bytes = fresh
        return Array(fresh[0..<count])
    }
}

/// EBML in memory.
struct EBMLData {
    struct Element { let id: UInt32; let size: UInt64? }
    let data: [UInt8]
    var position = 0

    init(data: Data) { self.data = [UInt8](data) }

    static func vint(_ bytes: [UInt8], _ offset: Int) -> (UInt64, Int)? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let first = bytes[offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard offset + length <= bytes.count else { return nil }
        var value = UInt64(first) & ((1 << (8 - length)) - 1)
        for i in 1..<length { value = value << 8 | UInt64(bytes[offset + i]) }
        return (value, length)
    }

    mutating func element(checkingSize: Bool = true) -> Element? {
        guard position < data.count else { return nil }
        let first = data[position]
        guard first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, position + idLength <= data.count else { return nil }
        var id: UInt32 = 0
        for i in 0..<idLength { id = id << 8 | UInt32(data[position + i]) }
        guard let (size, sizeLength) = Self.vint(data, position + idLength) else { return nil }
        let unknown = size == (UInt64(1) << (7 * sizeLength)) - 1
        let start = position + idLength + sizeLength
        if checkingSize, !unknown, size > UInt64(data.count - min(start, data.count)) { return nil }
        position = start
        return Element(id: id, size: unknown ? nil : size)
    }

    /// The element's contents (nil: unknown size or past the end); moves past it.
    mutating func bytes(_ element: Element) -> Data? {
        guard let size = element.size, size <= UInt64(data.count - position) else { position = data.count; return nil }
        defer { position += Int(size) }
        return Data(data[position..<position + Int(size)])
    }
}

// MARK: - MP4 (3GPP timed text)

enum MP4Subtitles {
    static func lines(_ source: ByteSource, subtitleIndex index: Int, from: Double, to: Double,
                      over: () -> Bool = { false }) -> SubtitleTrackLines? {
        guard let movie = MP4Boxes.movieIndex(source) else { return nil }
        let bytes = movie
        let tracks = MP4Boxes.boxes(in: bytes, 0..<bytes.count).filter { $0.type == "trak" }.filter { track in
            guard let media = MP4Boxes.child("mdia", of: track, in: bytes),
                  let handler = MP4Boxes.child("hdlr", of: media, in: bytes),
                  let type = bytes.fourCC(handler.payload.lowerBound + 8) else { return false }
            return ["sbtl", "text", "subt"].contains(type)
        }
        guard index >= 0, index < tracks.count,
              let samples = MP4Boxes.sampleRanges(bytes, track: tracks[index], format: "tx3g", fileSize: source.size) else { return nil }
        let starts = MP4Boxes.sampleStarts(bytes, track: tracks[index])
        guard starts.count >= samples.count else { return nil }
        let length = MP4Boxes.mediaLength(bytes, track: tracks[index])
        var lines: [SubtitleLine] = []
        for (i, range) in samples.enumerated() {
            if i % 256 == 0, over() { return nil }
            let start = starts[i]
            let end = i + 1 < starts.count ? starts[i + 1] : (length ?? start + 5)
            guard end > from - SubtitleReader.reach, start <= to else { continue }
            guard range.count >= 2, range.count <= 64 << 10, let sample = source.read(at: range.lowerBound, count: Int(range.count)),
                  let textLength = sample.u16(0), Int(textLength) + 2 <= sample.count, textLength > 0 else { continue }
            let raw = Array(sample[2..<2 + Int(textLength)])
            let text: String
            if raw.count >= 2, raw[0] == 0xFE, raw[1] == 0xFF {
                text = String(decoding: stride(from: 2, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]) }, as: UTF16.self)
            } else {
                text = String(decoding: raw, as: UTF8.self)
            }
            lines.append(SubtitleLine(start: start, end: end, text: SubtitleReader.plainText(text), style: nil))
        }
        return SubtitleTrackLines(kind: .text, lines: lines.filter { $0.end > from && $0.start <= to })
    }
}
