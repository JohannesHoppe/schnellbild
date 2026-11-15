import Foundation
import CoreGraphics
import CoreText
import CoreImage

/// Draws subtitle lines as VLC would, for the line that runs when a track
/// is switched on in the middle of a video (VLC reads such a track only
/// from its next line on; `VLCPlaybackControl.handover`), at the picture's
/// own size, laid over it by `VLCFrameOutput`.
///
/// Text subtitles (SubRip, 3GPP timed text) in the look of VLC 3's
/// freetype renderer with its defaults (modules/text_renderer/freetype,
/// codec/substext.h): Helvetica Neue at 6.25 % of the picture's height,
/// white, a black outline of 4 % of the size, a black shadow at half
/// opacity 6 % of the size down to the right, centred, its bottom 4 % of
/// the height above the picture's. ASS in the line's style as libass draws
/// it: font, size and outline scaled from the script's PlayResY, the font
/// sized by its Windows ascent and descent (as VSFilter), colours, bold,
/// italic, bottom alignment with MarginV. Not reproduced: inline styling
/// (SubRip's `<i>` `<b>` `<font>`, ASS override tags such as positions,
/// moves, rotations, karaoke, per-character colours, fades), ASS
/// alignments other than the bottom row (drawn at the bottom), timed text's
/// own style records; such lines show as plain text in the track's style.
enum SubtitleOverlay {
    /// The lines drawn into a transparent picture of `width` × `height`
    /// pixels (nil: nothing to draw).
    static func image(_ texts: [String], kind: SubtitleTrackLines.Kind, style: String?, width: Int, height: Int) -> CIImage? {
        let lines = texts.filter { !$0.isEmpty }
        guard !lines.isEmpty, width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        let look: Look
        switch kind {
        case .text:         look = vlcLook(width: width, height: height)
        case .ass(let ass): look = assLook(ass.style(style), playResY: ass.playResY, height: height)
        }
        draw(lines, look, in: context, width: width)
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    /// How a line is drawn, in pixels of the picture.
    struct Look {
        var font: CTFont
        var fill: CGColor
        var outline: CGColor
        /// The outline's width on each side of the glyph's edge.
        var outlineRadius: CGFloat
        var shadow: CGColor
        /// Right and down.
        var shadowOffset: CGSize
        /// The lowest ink (the shadow's or the outline's) this far above the
        /// picture's bottom (`inkPlaced`), or the line's box (baseline less
        /// the font's descent) for libass.
        var bottom: CGFloat
        var inkPlaced: Bool
        /// The baseline-to-baseline distance.
        var lineHeight: CGFloat
        /// Below the baseline, for a box placed by its bottom.
        var descent: CGFloat
    }

    /// VLC's freetype renderer with its defaults.
    static func vlcLook(width: Int, height: Int) -> Look {
        // ConvertToLiveSize with VLCKit's forced relative size (freetype.c's
        // UpdateDefaultLiveStyles: 10 % with freetype-rel-fontsize 0) of the
        // height (the width if portrait)
        let area = height > width ? width : height
        let size = CGFloat(Int(Double(area) * 10 / 100))
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
        // freetype-shadow-distance 0.06 at freetype-shadow-angle -45°
        let shadow = 0.06 * cos(CGFloat.pi / 4) * size
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return Look(font: font, fill: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), outline: black,
                    outlineRadius: size * 0.04, shadow: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 128.0 / 255),
                    shadowOffset: CGSize(width: shadow, height: shadow),
                    // substext.h: margin_ratio 0.04 of the visible height
                    bottom: CGFloat(Int(0.04 * Double(height))), inkPlaced: true,
                    lineHeight: CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), descent: CTFontGetDescent(font))
    }

    /// libass with the line's style, scaled from the script to the picture.
    static func assLook(_ style: ASSStyles.Style, playResY: Double, height: Int) -> Look {
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
        let em = size * units / cell
        font = CTFontCreateCopyWithAttributes(font, em, nil, nil)
        func colour(_ c: ASSStyles.RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        let shadow = CGFloat(style.shadow) * scale
        return Look(font: font, fill: colour(style.primary), outline: colour(style.outlineColour),
                    outlineRadius: CGFloat(style.outline) * scale, shadow: colour(style.back),
                    shadowOffset: CGSize(width: shadow, height: shadow),
                    bottom: CGFloat(style.marginV) * scale, inkPlaced: false,
                    lineHeight: size, descent: size * (ascent + descent > 0 ? descent / cell : 0.2))
    }

    /// The OS/2 table's usWinAscent and usWinDescent, in font units.
    static func windowsMetrics(_ font: CTFont) -> (CGFloat, CGFloat) {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 78 else { return (0, 0) }
        let b = [UInt8](table)
        return (CGFloat(UInt16(b[74]) << 8 | UInt16(b[75])), CGFloat(UInt16(b[76]) << 8 | UInt16(b[77])))
    }

    private static func draw(_ texts: [String], _ look: Look, in context: CGContext, width: Int) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): look.font,
                                                         NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        let lines = texts.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        // Bottom up: the last line lowest
        let bottomInk = lines.last.map { CTLineGetBoundsWithOptions($0, .useGlyphPathBounds).minY } ?? 0
        var baseline: CGFloat
        if look.inkPlaced {
            baseline = look.bottom + look.outlineRadius + max(look.shadowOffset.height, 0) - bottomInk
        } else {
            baseline = look.bottom + look.descent
        }
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for line in lines.reversed() {
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let x = (CGFloat(width) - ink.width) / 2 - ink.minX
            // Shadow: the outlined glyphs, moved
            if look.shadow.alpha > 0, look.shadowOffset != .zero {
                stroke(line, at: CGPoint(x: x + look.shadowOffset.width, y: baseline - look.shadowOffset.height),
                       look.shadow, radius: look.outlineRadius, in: context)
            }
            if look.outlineRadius > 0 { stroke(line, at: CGPoint(x: x, y: baseline), look.outline, radius: look.outlineRadius, in: context) }
            context.setTextDrawingMode(.fill)
            context.setFillColor(look.fill)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            baseline += look.lineHeight
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
