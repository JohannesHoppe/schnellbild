import AppKit
import PDFKit

/// A PDF's pages as vector pictures: each drawn with PDFKit at the size
/// asked for, so a page stays sharp at every zoom. A passive view: the
/// document is read from memory (`MediaData`, so the 256 MB cap and
/// archives apply) and its pages are only drawn into a bitmap
/// (`PDFPage.draw(with:to:)`). No `PDFView`, so nothing is clicked: PDFKit
/// carries out a link's or form field's `PDFAction` (go-to, named, remote
/// go-to, reset form, URL; its headers name no other, no JavaScript) only
/// through a `PDFView` (`performAction`, a click on a link). Annotations
/// are drawn as they look; none acts.
///
/// Illustrator files (".ai") are PDFs when saved with PDF content (the
/// default; Illustrator's own data rides along as private streams, which
/// PDFKit passes over). Saved without it, the PDF holds only Illustrator's
/// placeholder page ("saved without PDF Content"), and an Illustrator
/// file of version 8 or older is PostScript: then the picture it carries
/// (`EmbeddedPreview`: the XMP thumbnail, an EPSI preview) is shown as
/// its one page (`isPreview`); without one, the placeholder page.
final class PDFPages: @unchecked Sendable {
    let url: URL
    /// At least one.
    let count: Int
    /// The page shown is the picture the file carries, not its content.
    let isPreview: Bool
    private let document: PDFDocument
    /// PDFKit's document isn't made for being drawn from two threads at once.
    private let lock = NSLock()

    private init(url: URL, document: PDFDocument, isPreview: Bool = false) {
        self.url = url
        self.document = document
        self.isPreview = isPreview
        count = document.pageCount
    }

    /// A PDF, or an Illustrator file (`BrowserModel.mediaKind` lists only
    /// those that start as a PDF or carry a preview).
    static func isPDF(_ url: URL) -> Bool {
        let ext = BrowserModel.shownExtension(of: url)
        return ext == "pdf" || ext == "ai"
    }

    /// nil for a file that isn't a readable PDF, has no pages, or is locked
    /// with a password (an Illustrator file: that has no preview either).
    static func open(_ url: URL) async -> PDFPages? {
        guard let data = try? await MediaData.read(url), !Task.isCancelled else { return nil }
        let document = PDFDocument(data: data).flatMap { !$0.isLocked && $0.pageCount > 0 ? $0 : nil }
        guard BrowserModel.shownExtension(of: url) == "ai" else { return document.map { PDFPages(url: url, document: $0) } }
        if let document, !isPlaceholder(document) { return PDFPages(url: url, document: document) }
        if let preview = EmbeddedPreview.previewData(in: data), let image = NSImage(data: preview),
           let page = PDFPage(image: image) {
            let shown = PDFDocument()
            shown.insert(page, at: 0)
            return PDFPages(url: url, document: shown, isPreview: true)
        }
        return document.map { PDFPages(url: url, document: $0) }
    }

    /// Illustrator's page in a file saved without PDF content.
    static func isPlaceholder(_ document: PDFDocument) -> Bool {
        guard document.pageCount == 1, let text = document.page(at: 0)?.string else { return false }
        return text.range(of: "without PDF Content", options: .caseInsensitive) != nil
    }

    /// Page `index`'s size in points as it is shown: its crop box, turned
    /// by the page's rotation.
    func size(of index: Int) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return document.page(at: index).map(Self.shownSize)
    }

    private static func shownSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return abs(page.rotation) % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// Page `index` (from 0) drawn with its longest side `longestSide`
    /// pixels on white paper, as viewers show a page; with its size in points.
    func render(page index: Int, longestSide: Int) -> (CGImage, CGSize)? {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < count, let page = document.page(at: index) else { return nil }
        let size = Self.shownSize(page)
        guard let context = MediaInfo.bitmap(for: size, longestSide: longestSide) else { return nil }
        let width = context.width, height = context.height
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        // Turns the page by its rotation and draws its crop box from the origin
        page.draw(with: .cropBox, to: context)
        guard let cg = context.makeImage() else { return nil }
        return (cg, size)
    }
}
