import XCTest
import PDFKit
@testable import Schnellbild

/// The printed cheat sheet: every shortcut on one page, A4 and US Letter.
/// With CHEATSHEET_PDF set, the A4 page is written there (CI keeps it to
/// look at).
@MainActor
final class CheatSheetTests: XCTestCase {
    func testTheCheatSheetIsOnePage() throws {
        for paper in [CGSize(width: 595, height: 842), CGSize(width: 612, height: 792)] {
            let data = ShortcutsHelpView.cheatSheetPDF(paper: paper)
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, 1)
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, paper)
        }
        if let path = ProcessInfo.processInfo.environment["CHEATSHEET_PDF"] {
            try ShortcutsHelpView.cheatSheetPDF().write(to: URL(fileURLWithPath: path))
        }
    }
}
