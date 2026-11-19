import Foundation
import CoreGraphics
import CoreText
import CoreImage

/// Draws subtitle lines as VLC does, for the line that runs when a track is
/// switched on in the middle of a video (VLC reads such a track only from
/// its next line on; `VLCPlaybackControl`'s handover), at the picture's own
/// size, laid over it by `VLCFrameOutput`.
///
/// Text subtitles (SubRip, 3GPP timed text) in the look of VLC 3's freetype
/// renderer as our VLCKit draws them into the pictures it hands over:
/// Helvetica Neue at 10 % of the height (VLCKit's forced relative size), a
/// black outline of 4 % of the size, a black shadow at half opacity 6 % of
/// the size down to the right. Where the line lies was measured from VLC's
/// own pictures at fourteen sizes from 480 × 270 to 3840 × 2160 (UI tests
/// compare it with VLC's next line, `VisualUITests`): VLC lays the line out
/// in its decoder's padded picture (`decoded`, the size VLC proposes to the
/// video callbacks) and scales it into the picture handed over, so the
/// line's bottom lies 3.13 px + 4.84 % of the height + 0.894 × the padding
/// above the picture's bottom and its middle at the padded width scaled by
/// the height's share, less 1.8 px + 2.4 % of the size; within a pixel at
/// every size measured. Each line of several is centred on its own, the
/// lowest one placed by its ink (descenders too).
///
/// ASS as libass (0.17, in our VLCKit) lays it out: each event in its style
/// changed by its override tags (`ASSText`: `\an`, `\a`, `\pos`, `\b`, `\i`,
/// `\u`, `\s`, `\c` / `\1c` … `\4c`, `\alpha` / `\1a` … `\4a`, `\fs`, `\fn`,
/// `\bord`, `\shad`, `\r`, `\q`, `\N`, `\n`, `\h`); fonts sized by their
/// Windows ascent and descent (as VSFilter); sizes, outlines and shadows
/// scaled from the script's PlayResY, places from PlayResX × PlayResY; each
/// line aligned by its advance between the margins (the event's, else its
/// style's), the text placed by its alignment's point (at the margins, in
/// the middle, or at `\pos`); underline and strike-out where the font's
/// tables put them; shadows, then outlines, then fills. Lines too wide for
/// the margins break at spaces (WrapStyle 1 where they run over, 0 and 3
/// into lines of about the same width, 2 not). Events at the same time
/// without `\pos` stack away from their edge (those at the bottom upwards,
/// at the top downwards) in the script's order.
///
/// Not reproduced (the app's line hands over to VLC's next one within
/// 1.5 s): SubRip's inline styling (`<i>` `<b>` `<font>`: plain text in VLC's
/// style), timed text's own style records; in ASS karaoke (`\k` `\kf` `\ko`,
/// `\2c` `\2a`), animation (`\t`, `\move`, `\fad` `\fade`), rotation and
/// shear (`\fr…`, `\fax` `\fay`, `\org`), scaling and spacing (`\fscx`
/// `\fscy` `\fsp`, the styles' ScaleX, ScaleY, Spacing and Angle), `\xbord`
/// `\ybord` `\xshad` `\yshad`, blur (`\blur` `\be`), clipping (`\clip`
/// `\iclip`), drawings (`\p`: left out), BorderStyle 3 (a box), bold drawn
/// by libass for a font without a bold face, right-to-left reordering,
/// libass's collision rules beyond that stacking, layers, the Effect field
/// (scrolling).
enum SubtitleOverlay {
    /// The running lines drawn into a transparent picture of `width` ×
    /// `height` pixels (nil: nothing to draw). `decoded`: the size VLC
    /// proposed for the pictures (its decoder's, with padding).
    static func image(_ running: [SubtitleLine], kind: SubtitleTrackLines.Kind, width: Int, height: Int,
                      decoded: (width: Int, height: Int)?) -> CIImage? {
        let texts = running.flatMap(\.text).filter { !$0.isEmpty }
        guard !texts.isEmpty, width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        switch kind {
        case .text:
            draw(texts, vlcLook(width: width, height: height, decoded: decoded ?? (width, height)), in: context)
        case .ass(let styles):
            drawASS(running, styles, width: width, height: height, in: context)
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    // MARK: Text subtitles (VLC's freetype renderer)

    /// How lines are drawn, in pixels of the picture (y up from its bottom).
    struct Look {
        var font: CTFont
        var fill: CGColor
        var outline: CGColor
        /// The outline's width on each side of the glyph's edge.
        var outlineRadius: CGFloat
        var shadow: CGColor
        /// Right and down.
        var shadowOffset: CGSize
        /// The lowest line's filled ink (not its outline) bottom at
        /// `bottom`, each line's ink centred on `centre`; lines `gap` apart
        /// beyond their ink.
        var bottom: CGFloat
        var centre: CGFloat
        var gap: CGFloat
    }

    /// VLC's freetype renderer as our VLCKit draws subtitles into the pictures.
    static func vlcLook(width: Int, height: Int, decoded: (width: Int, height: Int)) -> Look {
        // ConvertToLiveSize with VLCKit's forced relative size (freetype.c's
        // UpdateDefaultLiveStyles: 10 % with freetype-rel-fontsize 0) of the
        // height (the width if portrait)
        let area = height > width ? width : height
        let size = CGFloat(Int(Double(area) * 10 / 100))
        // FreeType's hinting keeps small text a little narrower (measured:
        // 2 % at 36 px, 0.3 % at 216 px)
        var narrower = CGAffineTransform(scaleX: 1 - 0.7 / max(size, 1), y: 1)
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, size, &narrower)
        // freetype-shadow-distance 0.06 at freetype-shadow-angle -45°
        let shadow = 0.06 * cos(CGFloat.pi / 4) * size
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        // Measured (see above): the padded picture the line is laid out in
        let h = CGFloat(height), padded = CGFloat(max(decoded.height, height))
        let bottom = 3.132 + 0.0484 * h + 0.894 * (padded - h) - 1
        let centre = CGFloat(max(decoded.width, width)) * h / padded / 2 - 1.812 - 0.0237 * size
        return Look(font: font, fill: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), outline: black,
                    outlineRadius: size * 0.04, shadow: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 128.0 / 255),
                    shadowOffset: CGSize(width: shadow, height: shadow),
                    bottom: bottom, centre: centre, gap: size * 0.04 * 2 + shadow + 1)
    }

    private static func draw(_ texts: [String], _ look: Look, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): look.font,
                                                         NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        let lines = texts.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        context.setLineJoin(.round)
        context.setLineCap(.round)
        // Bottom up: the last line lowest
        var level = look.bottom   // the ink's bottom
        for line in lines.reversed() {
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let origin = CGPoint(x: look.centre - ink.midX, y: level - ink.minY)
            level += ink.height + look.gap
            // Shadow: the outlined glyphs, moved
            if look.shadow.alpha > 0, look.shadowOffset != .zero {
                stroke(line, at: CGPoint(x: origin.x + look.shadowOffset.width, y: origin.y - look.shadowOffset.height),
                       look.shadow, radius: look.outlineRadius, in: context)
            }
            if look.outlineRadius > 0 { stroke(line, at: origin, look.outline, radius: look.outlineRadius, in: context) }
            context.setTextDrawingMode(.fill)
            context.setFillColor(look.fill)
            context.textPosition = origin
            CTLineDraw(line, context)
        }
    }

    /// The glyphs filled and stroked `radius` wide on each side, in `colour`.
    private static func stroke(_ line: CTLine, at point: CGPoint, _ colour: CGColor, radius: CGFloat, in context: CGContext) {
        context.setFillColor(colour)
        context.setStrokeColor(colour)
        context.setLineWidth(radius * 2)
        context.setTextDrawingMode(radius > 0 ? .fillStroke : .fill)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    // MARK: ASS (libass)

    /// A run's font at its size in pixels, with what libass places by it.
    struct ASSFont {
        var font: CTFont
        /// The Windows ascent and descent at the size (together the size).
        var ascent: CGFloat
        var descent: CGFloat
    }

    /// The font of a run: its face (bold, italic) at `size` pixels, sized as
    /// libass's ass_face_set_size: the Windows ascent plus descent is the size.
    static func assFont(_ name: String, bold: Bool, italic: Bool, size: CGFloat) -> ASSFont {
        var font = CTFontCreateWithName(name as CFString, 100, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 100, nil, traits, traits) { font = styled }
        let (ascent, descent) = windowsMetrics(font)
        let units = CGFloat(CTFontGetUnitsPerEm(font))
        let cell = ascent + descent > 0 ? ascent + descent : units
        font = CTFontCreateCopyWithAttributes(font, size * units / cell, nil, nil)
        return ASSFont(font: font, ascent: ascent + descent > 0 ? size * ascent / cell : size * 0.8,
                       descent: ascent + descent > 0 ? size * descent / cell : size * 0.2)
    }

    /// The OS/2 table's usWinAscent and usWinDescent, in font units.
    static func windowsMetrics(_ font: CTFont) -> (CGFloat, CGFloat) {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 78 else { return (0, 0) }
        let b = [UInt8](table)
        return (CGFloat(b.u16(74) ?? 0), CGFloat(b.u16(76) ?? 0))
    }

    /// The OS/2 table's yStrikeoutSize and yStrikeoutPosition, in pixels of
    /// the font's size (nil: the font has none).
    static func strikeOut(_ font: CTFont) -> (size: CGFloat, position: CGFloat)? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 30 else { return nil }
        let b = [UInt8](table)
        let size = CGFloat(Int16(bitPattern: b.u16(26) ?? 0))
        let position = CGFloat(Int16(bitPattern: b.u16(28) ?? 0))
        guard size > 0, position >= 0 else { return nil }
        let scale = CTFontGetSize(font) / CGFloat(CTFontGetUnitsPerEm(font))
        return (size * scale, position * scale)
    }

    /// The key that ties a stretch of the laid-out text to its run's style.
    private static let runKey = NSAttributedString.Key("SchnellbildASSRun")

    /// One line laid out: its text, its width by advance and its height.
    private struct LaidLine {
        var text: NSAttributedString
        var line: CTLine
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
    }

    /// The running events, each in its own layout, into `context`.
    private static func drawASS(_ running: [SubtitleLine], _ styles: ASSStyles, width: Int, height: Int, in context: CGContext) {
        let w = CGFloat(width), h = CGFloat(height)
        let xScale = w / CGFloat(styles.playResX), yScale = h / CGFloat(styles.playResY)
        // Stacked events without \pos: how far the bottom and the top are taken
        var takenBottom: CGFloat = 0, takenTop: CGFloat = 0
        context.setLineJoin(.round)
        context.setLineCap(.round)
        let events = running.sorted { ($0.ass?.readOrder ?? 0, $0.start) < ($1.ass?.readOrder ?? 0, $1.start) }
        for event in events {
            let raw = event.ass?.text ?? event.text.joined(separator: "\\N")
            let parsed = ASSText.parse(raw, style: event.style, in: styles)
            let base = styles.style(event.style)
            var fonts: [String: ASSFont] = [:]
            func font(_ style: ASSText.RunStyle) -> ASSFont {
                let key = "\(style.font)|\(style.bold)|\(style.italic)|\(style.size)"
                if let known = fonts[key] { return known }
                let made = assFont(style.font, bold: style.bold, italic: style.italic, size: CGFloat(style.size) * yScale)
                fonts[key] = made
                return made
            }
            let marginL = CGFloat(event.ass.map { $0.marginL != 0 ? $0.marginL : base.marginL } ?? base.marginL) * xScale
            let marginR = CGFloat(event.ass.map { $0.marginR != 0 ? $0.marginR : base.marginR } ?? base.marginR) * xScale
            let marginV = CGFloat(event.ass.map { $0.marginV != 0 ? $0.marginV : base.marginV } ?? base.marginV) * yScale
            let available = w - marginR - marginL
            // The runs' styles, by index, and each line as attributed text
            var runStyles: [ASSText.RunStyle] = []
            var laid: [LaidLine] = []
            let empty = font(ASSText.RunStyle(base))
            for runs in parsed.lines {
                let text = NSMutableAttributedString()
                for run in runs {
                    runStyles.append(run.style)
                    text.append(NSAttributedString(string: run.text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font(run.style).font,
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                        runKey: runStyles.count - 1]))
                }
                for piece in wrap(text, within: available, style: parsed.wrapStyle) {
                    var ascent: CGFloat = 0, descent: CGFloat = 0
                    piece.enumerateAttribute(runKey, in: NSRange(location: 0, length: piece.length)) { value, _, _ in
                        guard let index = value as? Int else { return }
                        let f = font(runStyles[index])
                        ascent = max(ascent, f.ascent)
                        descent = max(descent, f.descent)
                    }
                    if piece.length == 0 { ascent = empty.ascent; descent = empty.descent }
                    let line = CTLineCreateWithAttributedString(piece)
                    laid.append(LaidLine(text: piece, line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)),
                                         ascent: ascent, descent: descent))
                }
            }
            guard let first = laid.first else { continue }
            let textHeight = laid.reduce(0) { $0 + $1.ascent + $1.descent }
            let column = (parsed.alignment - 1) % 3   // 0 left, 1 centre, 2 right
            let row = (parsed.alignment - 1) / 3      // 0 bottom, 1 middle, 2 top
            // Each line's place in the margins' width
            let shifts = laid.map { column == 0 ? 0 : column == 1 ? (available - $0.width) / 2 : available - $0.width }
            // The first line's baseline (from the top) and the lines' left edge
            var baseline: CGFloat
            var left: CGFloat
            if let position = parsed.position {
                let y = CGFloat(position.y) * yScale
                baseline = row == 2 ? y + first.ascent : row == 1 ? y + first.ascent - textHeight / 2 : y + first.ascent - textHeight
                let minX = shifts.min() ?? 0
                let maxX = zip(shifts, laid).map { $0 + $1.width }.max() ?? 0
                let anchor = column == 0 ? minX : column == 1 ? (minX + maxX) / 2 : maxX
                left = CGFloat(position.x) * xScale - anchor
            } else {
                switch row {
                case 2:
                    baseline = marginV + first.ascent + takenTop
                    takenTop += textHeight
                case 1:
                    baseline = h / 2 - textHeight / 2 + first.ascent
                default:
                    baseline = h - marginV - textHeight + first.ascent - takenBottom
                    takenBottom += textHeight
                }
                left = marginL
            }
            // Every run's outline as a path, with its style
            var pieces: [(path: CGPath, style: ASSText.RunStyle)] = []
            for (n, line) in laid.enumerated() {
                if n > 0 { baseline += laid[n - 1].descent + line.ascent }
                let origin = CGPoint(x: left + shifts[n], y: h - baseline)
                for run in (CTLineGetGlyphRuns(line.line) as? [CTRun]) ?? [] {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let index = attributes[runKey] as? Int, index < runStyles.count,
                          let value = attributes[kCTFontAttributeName as String] else { continue }
                    let runFont = value as! CTFont
                    let count = CTRunGetGlyphCount(run)
                    guard count > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                    let path = CGMutablePath()
                    for (glyph, at) in zip(glyphs, positions) {
                        var move = CGAffineTransform(translationX: origin.x + at.x, y: origin.y + at.y)
                        if let outline = CTFontCreatePathForGlyph(runFont, glyph, &move) { path.addPath(outline) }
                    }
                    let style = runStyles[index]
                    let start = origin.x + positions[0].x
                    let advance = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: count), nil, nil, nil))
                    if style.underline {
                        let thickness = CTFontGetUnderlineThickness(runFont)
                        path.addRect(CGRect(x: start, y: origin.y + CTFontGetUnderlinePosition(runFont) - thickness / 2,
                                            width: advance, height: thickness))
                    }
                    if style.strikeOut, let strike = strikeOut(runFont) {
                        path.addRect(CGRect(x: start, y: origin.y + strike.position - strike.size / 2, width: advance, height: strike.size))
                    }
                    pieces.append((path, style))
                }
            }
            func colour(_ c: ASSStyles.RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
            // Shadows, then outlines, then fills, as libass composes an event
            for piece in pieces where piece.style.shadow > 0 && piece.style.back.a > 0 {
                let offset = CGFloat(piece.style.shadow) * yScale
                var move = CGAffineTransform(translationX: offset, y: -offset)
                guard let moved = piece.path.copy(using: &move) else { continue }
                fill(moved, colour(piece.style.back), border: CGFloat(piece.style.outline) * yScale, in: context)
            }
            for piece in pieces where piece.style.outline > 0 && piece.style.outlineColour.a > 0 {
                fill(piece.path, colour(piece.style.outlineColour), border: CGFloat(piece.style.outline) * yScale, in: context)
            }
            for piece in pieces where piece.style.primary.a > 0 {
                fill(piece.path, colour(piece.style.primary), border: 0, in: context)
            }
        }
    }

    /// A path filled, and stroked `border` wide on each side of its edge.
    private static func fill(_ path: CGPath, _ colour: CGColor, border: CGFloat, in context: CGContext) {
        context.addPath(path)
        context.setFillColor(colour)
        if border > 0 {
            context.setStrokeColor(colour)
            context.setLineWidth(border * 2)
            context.drawPath(using: .fillStroke)
        } else {
            context.fillPath()
        }
    }

    /// A line too wide for `available` broken at its spaces (the spaces at
    /// the breaks left out): WrapStyle 1 where it runs over, 0 and 3 into
    /// lines of about the same width, 2 not at all.
    private static func wrap(_ text: NSAttributedString, within available: CGFloat, style: Int) -> [NSAttributedString] {
        let line = CTLineCreateWithAttributedString(text)
        let total = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard style != 2, total > available, available > 0 else { return [text] }
        let string = text.string as NSString
        let spaces = (0..<string.length).filter { string.character(at: $0) == 0x20 }
        guard !spaces.isEmpty else { return [text] }
        func x(_ index: Int) -> CGFloat { CTLineGetOffsetForStringIndex(line, index, nil) }
        // Where it runs over
        var breaks: [Int] = []
        var start = 0
        var last: Int?
        for space in spaces {
            if x(space) - x(start) > available, let at = last { breaks.append(at); start = at + 1 }
            last = space
        }
        if x(string.length) - x(start) > available, let at = last, at >= start { breaks.append(at) }
        // As many lines, each about as wide
        if style != 1, !breaks.isEmpty {
            let count = breaks.count + 1
            var balanced: [Int] = []
            start = 0
            for k in 1..<count {
                let target = x(start) + (x(string.length) - x(start)) / CGFloat(count - k + 1)
                let candidates = spaces.filter { $0 > start && x($0) - x(start) <= available }
                guard let best = candidates.min(by: { abs(x($0) - target) < abs(x($1) - target) }) else { break }
                balanced.append(best)
                start = best + 1
            }
            if balanced.count == breaks.count { breaks = balanced }
        }
        var pieces: [NSAttributedString] = []
        start = 0
        for at in breaks {
            pieces.append(text.attributedSubstring(from: NSRange(location: start, length: at - start)))
            start = at + 1
        }
        pieces.append(text.attributedSubstring(from: NSRange(location: start, length: string.length - start)))
        return pieces
    }
}
