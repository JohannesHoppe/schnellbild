import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

/// Small pictures of every format the app shows, made in the test: by
/// ImageIO where it writes the format, else by hand from the format's
/// published layout. No sample files from elsewhere.
enum FormatFixtures {
    /// A 4 × 2 picture: left half red, right half blue.
    static let width = 4, height = 2

    static func cgImage(width: Int = width, height: Int = height) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    /// Written by ImageIO as `type` (`frames` pictures; more than one: an
    /// animation); nil where ImageIO doesn't write it on this system.
    /// `square`: a 16 × 16 picture, for formats of square sides (icons,
    /// textures).
    static func written(_ type: String, frames: Int = 1, square: Bool = false, properties: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type),
              let destination = CGImageDestinationCreateWithData(data, type as CFString, frames, nil) else { return nil }
        let image = square ? cgImage(width: 16, height: 16) : cgImage()
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A picture for each extension of a format ImageIO reads (nil where
    /// it can't be made on this system).
    static func all() -> [(String, Data?)] {
        let apng = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]]
        let jp2 = written(UTType("public.jpeg-2000")!.identifier)
        return [
            ("pbm", netpbm("P1")), ("pgm", netpbm("P5")), ("ppm", netpbm("P6")), ("pnm", netpbm("P6")), ("pfm", netpbm("PF")),
            ("sgi", sgi()), ("psd", photoshop(large: false)), ("psb", photoshop(large: true)),
            ("pict", pict()), ("pct", pict()), ("dcm", dicom()), ("dicom", dicom()),
            ("cur", cursor()), ("dib", written(UTType.bmp.identifier)), ("bmp", written(UTType.bmp.identifier)),
            ("tga", written("com.truevision.tga-image")), ("ico", written(UTType.ico.identifier, square: true)),
            ("icns", written(UTType.icns.identifier, square: true)), ("exr", written("com.ilm.openexr-image")),
            ("dds", written("com.microsoft.dds", square: true)), ("astc", written("org.khronos.astc")), ("ktx", written("org.khronos.ktx")),
            ("ktx2", written("org.khronos.ktx2")), ("pvr", written("public.pvr", square: true)), ("atx", written("com.apple.atx")),
            ("jp2", jp2), ("jpf", jp2), ("jpx", jp2), ("j2k", jp2),
            ("avif", written("public.avif")), ("avifs", written("public.avif", frames: 2)),
            ("heic", written(UTType.heic.identifier)), ("heics", written("public.heics", frames: 2)),
            ("apng", written(UTType.png.identifier, frames: 2, properties: apng)),
            ("gif", written(UTType.gif.identifier, frames: 2)), ("webp", written(UTType.webP.identifier)),
            ("jxl", written("public.jpeg-xl")), ("tif", written(UTType.tiff.identifier)),
        ]
    }

    // MARK: By hand

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func be32(_ v: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) } }
    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] { [0, 8, 16, 24].map { UInt8((v >> $0) & 0xFF) } }

    /// The picture's pixels as RGB rows from the top.
    private static func rgbRows() -> [[UInt8]] {
        (0..<height).map { _ in (0..<width).flatMap { x in x < width / 2 ? [255, 0, 0] : [0, 0, 255] } }
    }

    /// Netpbm (netpbm.sourceforge.net/doc): P1 bitmap as text, P4 bitmap,
    /// P5 grey, P6 colour, PF float colour.
    static func netpbm(_ kind: String) -> Data {
        var head = "\(kind)\n\(width) \(height)\n"
        var body: [UInt8] = []
        switch kind {
        case "P1":   // 1 is black
            head += (0..<height).map { _ in (0..<width).map { $0 < width / 2 ? "1" : "0" }.joined(separator: " ") }
                .joined(separator: "\n") + "\n"
        case "P4":   // one bit a pixel, 1 is black, rows padded to bytes
            body = (0..<height).map { _ in UInt8(0b1100_0000) }
        case "P5":
            head += "255\n"
            body = (0..<height).flatMap { _ in (0..<width).map { x in UInt8(x < width / 2 ? 76 : 29) } }
        case "P6":
            head += "255\n"
            body = rgbRows().flatMap { $0 }
        default:     // "PF": little-endian floats (a negative scale), rows from the bottom
            head += "-1.0\n"
            for _ in 0..<height {
                for x in 0..<width {
                    for c in (x < width / 2 ? [Float(1), 0, 0] : [Float(0), 0, 1]) {
                        body += withUnsafeBytes(of: c.bitPattern.littleEndian) { Array($0) }
                    }
                }
            }
        }
        return Data(head.utf8) + Data(body)
    }

    /// SGI image (Paul Haeberli's "The SGI Image File Format" 1.00):
    /// uncompressed, 8 bits, three channels one after the other, rows from the bottom.
    static func sgi() -> Data {
        var bytes = be16(474) + [0, 1] + be16(3) + be16(width) + be16(height) + be16(3)
        bytes += be32(0) + be32(255) + [0, 0, 0, 0] + [UInt8](repeating: 0, count: 80) + be32(0)
        bytes += [UInt8](repeating: 0, count: 512 - bytes.count)
        let rows = rgbRows()
        for channel in 0..<3 {
            for row in rows.reversed() {
                bytes += (0..<width).map { row[$0 * 3 + channel] }
            }
        }
        return Data(bytes)
    }

    /// Photoshop (Adobe's "Photoshop File Formats Specification"): version
    /// 1 (PSD) or 2 (PSB, the large document format: 8-byte layer and mask
    /// length), RGB, 8 bits, the composite image uncompressed.
    static func photoshop(large: Bool) -> Data {
        var bytes = Array("8BPS".utf8) + be16(large ? 2 : 1) + [UInt8](repeating: 0, count: 6)
        bytes += be16(3) + be32(height) + be32(width) + be16(8) + be16(3)
        bytes += be32(0)                                  // colour mode data
        bytes += be32(0)                                  // image resources
        bytes += large ? be32(0) + be32(0) : be32(0)      // layer and mask information
        bytes += be16(0)                                  // raw image data
        let rows = rgbRows()
        for channel in 0..<3 {
            for row in rows { bytes += (0..<width).map { row[$0 * 3 + channel] } }
        }
        return Data(bytes)
    }

    /// A Windows cursor: an icon written by ImageIO with the type field 2
    /// and its hot spot (in place of planes and bit count) at 0, 0.
    static func cursor() -> Data? {
        guard var bytes = written(UTType.ico.identifier, square: true).map(Array.init) else { return nil }
        bytes[2] = 2; bytes[3] = 0
        let count = Int(bytes[4]) | Int(bytes[5]) << 8
        for entry in 0..<count {
            let at = 6 + entry * 16
            for i in 4..<8 { bytes[at + i] = 0 }
        }
        return Data(bytes)
    }

    /// QuickDraw PICT version 2 (Inside Macintosh: Imaging With QuickDraw,
    /// appendix A): the 512-byte file header, a 10 × 10 frame, a red
    /// rectangle painted over it.
    static func pict() -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        let frame = be16(0) + be16(0) + be16(10) + be16(10)
        bytes += be16(0) + frame
        bytes += be16(0x0011) + be16(0x02FF)                                // version 2
        bytes += be16(0x0C00) + be16(0xFFFE) + be16(0) + be32(0x0048_0000) + be32(0x0048_0000) + frame + be32(0)
        bytes += be16(0x001A) + be16(0xFFFF) + be16(0) + be16(0)            // foreground colour red
        bytes += be16(0x0031) + frame                                       // paint rect
        bytes += be16(0x00FF)                                               // end of picture
        return Data(bytes)
    }

    /// DICOM (PS3.10 file format: preamble, "DICM", the file meta group in
    /// explicit VR little endian; the data set in the same transfer syntax):
    /// an 8-bit grey picture.
    static func dicom() -> Data {
        func element(_ group: Int, _ item: Int, _ vr: String, _ value: [UInt8]) -> [UInt8] {
            var value = value
            if value.count % 2 == 1 { value.append(vr == "UI" ? 0 : 0x20) }
            let long = ["OB", "OW", "UN", "SQ", "UT"].contains(vr)
            return le16(group) + le16(item) + Array(vr.utf8)
                + (long ? [0, 0] + le32(value.count) : le16(value.count)) + value
        }
        let syntax = Array("1.2.840.10008.1.2.1".utf8)
        let mediaClass = Array("1.2.840.10008.5.1.4.1.1.7".utf8)   // secondary capture
        let instance = Array("1.2.3.4".utf8)
        var meta = element(0x0002, 0x0001, "OB", [0, 1])
        meta += element(0x0002, 0x0002, "UI", mediaClass) + element(0x0002, 0x0003, "UI", instance)
        meta += element(0x0002, 0x0010, "UI", syntax)
        var bytes = [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)
        bytes += element(0x0002, 0x0000, "UL", le32(meta.count)) + meta
        bytes += element(0x0008, 0x0016, "UI", mediaClass) + element(0x0008, 0x0018, "UI", instance)
        bytes += element(0x0028, 0x0002, "US", le16(1)) + element(0x0028, 0x0004, "CS", Array("MONOCHROME2".utf8))
        bytes += element(0x0028, 0x0010, "US", le16(height)) + element(0x0028, 0x0011, "US", le16(width))
        bytes += element(0x0028, 0x0100, "US", le16(8)) + element(0x0028, 0x0101, "US", le16(8))
        bytes += element(0x0028, 0x0102, "US", le16(7)) + element(0x0028, 0x0103, "US", le16(0))
        bytes += element(0x7FE0, 0x0010, "OB", (0..<height).flatMap { _ in (0..<width).map { UInt8($0 < width / 2 ? 76 : 29) } })
        return Data(bytes)
    }

    // MARK: Vector documents

    /// A one-page PDF of `size` points, filled red, through Core Graphics.
    static func pdf(size: CGSize = CGSize(width: 200, height: 100), text: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(box)
        if let text {
            // Text as a page carries it (PDFKit reads it back with `string`)
            let attributes = [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 10, nil)] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
            context.textPosition = CGPoint(x: 4, y: size.height / 2)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// An XMP packet with Illustrator's thumbnail (`xmpGImg:image`, base64
    /// with "&#xA;" for its line breaks, as Illustrator writes it; XMP
    /// Specification Part 2, "Thumbnail" in the xmpGImg namespace).
    static func xmpThumbnail(_ jpeg: Data) -> Data {
        let base64 = jpeg.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            .replacingOccurrences(of: "\n", with: "&#xA;")
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:xmpGImg="http://ns.adobe.com/xap/1.0/g/img/">
           <xmp:Thumbnails>
            <rdf:Alt>
             <rdf:li rdf:parseType="Resource">
              <xmpGImg:width>\(width)</xmpGImg:width>
              <xmpGImg:height>\(height)</xmpGImg:height>
              <xmpGImg:format>JPEG</xmpGImg:format>
              <xmpGImg:image>\(base64)</xmpGImg:image>
             </rdf:li>
            </rdf:Alt>
           </xmp:Thumbnails>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(packet.utf8)
    }

    /// Illustrator's placeholder page of a file saved without PDF content.
    static let placeholderText = "This is an Adobe Illustrator File that was saved without PDF Content."

    /// An Illustrator file saved with PDF content: a PDF (Illustrator's own
    /// data rides in it as private streams, which viewers pass over).
    static func illustratorWithPDF() -> Data { pdf() }

    /// An Illustrator file saved without PDF content: a PDF whose page is
    /// Illustrator's placeholder text, its XMP thumbnail beside it.
    static func illustratorWithoutPDF() -> Data? {
        guard let jpeg = written(UTType.jpeg.identifier) else { return nil }
        return pdf(text: placeholderText) + Data("\n%".utf8) + xmpThumbnail(jpeg)
    }

    /// A PostScript program with a red square.
    static let postScript = Data("""
    %!PS-Adobe-3.0 EPSF-3.0
    %%BoundingBox: 0 0 4 2
    %%EndComments
    1 0 0 setrgbcolor 0 0 4 2 rectfill
    showpage
    %%EOF

    """.utf8)

    /// DOS EPS (Adobe TN 5002, "Encapsulated PostScript File Format
    /// Specification" 3.0, "DOS EPS Binary File Header"): the 30-byte header
    /// (C5D0D3C6, then little-endian offsets and lengths of the PostScript,
    /// a WMF and a TIFF preview; checksum FFFF), the PostScript, the TIFF.
    static func dosEPS() -> Data? {
        guard let tiff = written(UTType.tiff.identifier) else { return nil }
        let ps = [UInt8](postScript)
        let header = 30
        var bytes: [UInt8] = [0xC5, 0xD0, 0xD3, 0xC6]
        bytes += le32(header) + le32(ps.count) + le32(0) + le32(0) + le32(header + ps.count) + le32(tiff.count) + [0xFF, 0xFF]
        return Data(bytes + ps) + tiff
    }

    /// EPSI (TN 5002, "Device-Independent Screen Preview"): the preview in
    /// comments between %%BeginPreview: width height depth lines and
    /// %%EndPreview, hexadecimal, rows from the top, 1 bits are black.
    /// Left half black, right half white.
    static func epsi() -> Data {
        let row = String(format: "%02X", 0b1100_0000)
        let text = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 4 2
        %%EndComments
        %%BeginPreview: \(width) \(height) 1 \(height)
        %\(row)
        %\(row)
        %%EndPreview
        0 setgray 0 0 2 2 rectfill
        showpage
        %%EOF

        """
        return Data(text.utf8)
    }

    /// EPS with only an XMP thumbnail (as Illustrator writes into its EPS).
    static func epsWithXMP() -> Data? {
        guard let jpeg = written(UTType.jpeg.identifier) else { return nil }
        return Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 4 2\n%%EndComments\n%%BeginMetadata\n".utf8)
            + xmpThumbnail(jpeg) + Data("\n%%EndMetadata\nshowpage\n%%EOF\n".utf8)
    }
}
