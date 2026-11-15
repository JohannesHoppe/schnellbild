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
final class PDFPages: @unchecked Sendable {
    let url: URL
    /// At least one.
    let count: Int
    private let document: PDFDocument
    /// PDFKit's document isn't made for being drawn from two threads at once.
    private let lock = NSLock()

    private init(url: URL, document: PDFDocument) {
        self.url = url
        self.document = document
        count = document.pageCount
    }

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    /// nil for a file that isn't a readable PDF, has no pages, or is locked
    /// with a password.
    static func open(_ url: URL) async -> PDFPages? {
        guard let data = try? await MediaData.read(url), !Task.isCancelled,
              let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { return nil }
        return PDFPages(url: url, document: document)
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
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let scale = CGFloat(max(longestSide, 1)) / max(size.width, size.height)
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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
