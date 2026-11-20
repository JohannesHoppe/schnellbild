import XCTest
import SwiftUI
@testable import Schnellbild

/// What a view draws in its first frame, before any of its tasks ran: a
/// thumbnail in the cache shows at once (the Atlas shown again or after
/// the tour, the full view opened), not a grey square or black first.
/// `ImageRenderer` draws that first frame and runs no task.
@MainActor
final class FirstFrameTests: XCTestCase {
    /// A file (never read) whose cached thumbnail is a red square of `side` points.
    private func cachedRed(side: CGFloat) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("first-frame-\(UUID().uuidString).jpg")
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        ThumbnailCache.shared.keep(image, side: side, modified: nil, for: url)
        return url
    }

    /// The colour in the middle of the view's first frame.
    private func middle(of view: some View, size: CGSize) throws -> NSColor {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        let image = try XCTUnwrap(renderer.cgImage, "drawn")
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func assertRed(_ color: NSColor, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(color.redComponent, 0.8, "\(what): \(color)", file: file, line: line)
        XCTAssertLessThan(color.greenComponent, 0.3, "\(what): \(color)", file: file, line: line)
        XCTAssertLessThan(color.blueComponent, 0.3, "\(what): \(color)", file: file, line: line)
    }

    func testAnAtlasThumbnailShowsTheCachedPictureInItsFirstFrame() throws {
        let url = cachedRed(side: 64)
        for side: CGFloat in [22, 40, 64] {
            assertRed(try middle(of: AtlasThumbnail(url: url, modified: nil, side: side), size: CGSize(width: side, height: side)),
                      "a tile of \(side) points")
        }
    }

    func testTheFullViewShowsTheTilesThumbnailUntilThePictureIsDecoded() throws {
        let url = cachedRed(side: 256)
        let model = BrowserModel(defaults: makeTestDefaults())
        let view = FullImageView(url: url).environmentObject(model)
        assertRed(try middle(of: view, size: CGSize(width: 400, height: 300)), "the full view")
    }
}
