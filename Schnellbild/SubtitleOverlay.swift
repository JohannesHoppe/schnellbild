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
/// ASS in the line's style as libass draws it: font, size and outline
/// scaled from the script's PlayResY, the font sized by its Windows ascent
/// and descent (as VSFilter), colours, bold, italic, bottom alignment with
/// MarginV.
///
/// Not reproduced: inline styling (SubRip's `<i>` `<b>` `<font>`, ASS
/// override tags such as positions, moves, rotations, karaoke,
/// per-character colours, fades), ASS alignments other than the bottom row
/// (drawn at the bottom), timed text's own style records; such lines show
/// as plain text in the track's style.
enum SubtitleOverlay {
    /// The lines drawn into a transparent picture of `width` × `height`
    /// pixels (nil: nothing to draw). `decoded`: the size VLC proposed for
    /// the pictures (its decoder's, with padding).
    static func image(_ texts: [String], kind: SubtitleTrackLines.Kind, style: String?, width: Int, height: Int,
                      decoded: (width: Int, height: Int)?) -> CIImage? {
        let lines = texts.filter { !$0.isEmpty }
        guard !lines.isEmpty, width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        let look: Look
        switch kind {
        case .text:         look = vlcLook(width: width, height: height, decoded: decoded ?? (width, height))
        case .ass(let ass): look = assLook(ass.style(style), playResY: ass.playResY, width: width, height: height)
        }
        draw(lines, look, in: context)
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

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
        enum Placement {
            /// The lowest line's filled ink (not its outline) bottom at `bottom`,
            /// each line's ink centred on `centre`; lines `inkAdvance` apart
            /// beyond their ink.
            case ink(bottom: CGFloat, centre: CGFloat, gap: CGFloat)
            /// libass: the lowest line's box (baseline less the font's
            /// descent) at `bottom`, lines `lineHeight` apart, centred.
            case box(bottom: CGFloat, centre: CGFloat, descent: CGFloat, lineHeight: CGFloat)
        }
        var placement: Placement
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
                    placement: .ink(bottom: bottom, centre: centre, gap: size * 0.04 * 2 + shadow + 1))
    }

    /// libass with the line's style, scaled from the script to the picture.
    static func assLook(_ style: ASSStyles.Style, playResY: Double, width: Int, height: Int) -> Look {
        let scale = CGFloat(Double(height) / playResY)
        var font = CTFontCreateWithName(style.font as CFString, 100, nil)
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 100, nil, traits, traits) { font = styled }
        // libass's ass_face_set_size: the size is the Windows ascent plus descent
        let (ascent, descent) = windowsMetrics(font)
        let units = CGFloat(CTFontGetUnitsPerEm(font))
        let cell = ascent + descent > 0 ? ascent + descent : units
        let size = CGFloat(style.size) * scale
        font = CTFontCreateCopyWithAttributes(font, size * units / cell, nil, nil)
        func colour(_ c: ASSStyles.RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        let shadow = CGFloat(style.shadow) * scale
        return Look(font: font, fill: colour(style.primary), outline: colour(style.outlineColour),
                    outlineRadius: CGFloat(style.outline) * scale, shadow: colour(style.back),
                    shadowOffset: CGSize(width: shadow, height: shadow),
                    placement: .box(bottom: CGFloat(style.marginV) * scale, centre: CGFloat(width) / 2,
                                    descent: size * (ascent + descent > 0 ? descent / cell : 0.2), lineHeight: size))
    }

    /// The OS/2 table's usWinAscent and usWinDescent, in font units.
    static func windowsMetrics(_ font: CTFont) -> (CGFloat, CGFloat) {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 78 else { return (0, 0) }
        let b = [UInt8](table)
        return (CGFloat(UInt16(b[74]) << 8 | UInt16(b[75])), CGFloat(UInt16(b[76]) << 8 | UInt16(b[77])))
    }

    private static func draw(_ texts: [String], _ look: Look, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): look.font,
                                                         NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        let lines = texts.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        context.setLineJoin(.round)
        context.setLineCap(.round)
        // Bottom up: the last line lowest
        var level: CGFloat = 0   // ink placement: the ink bottom; box placement: the baseline
        for (n, line) in lines.reversed().enumerated() {
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let origin: CGPoint
            switch look.placement {
            case .ink(let bottom, let centre, let gap):
                if n == 0 { level = bottom }
                origin = CGPoint(x: centre - ink.midX, y: level - ink.minY)
                level += ink.height + gap
            case .box(let bottom, let centre, let descent, let lineHeight):
                if n == 0 { level = bottom + descent }
                origin = CGPoint(x: centre - ink.midX, y: level)
                level += lineHeight
            }
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
}
