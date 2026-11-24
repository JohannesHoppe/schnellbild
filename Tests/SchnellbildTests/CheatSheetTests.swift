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
            // Every shortcut's action is on the page, inside its margins (none cut off)
            let printable = CGRect(origin: .zero, size: paper).insetBy(dx: 31, dy: 31)
            let actions = ShortcutsHelpView.groups(.shared).flatMap(\.shortcuts).map(\.action)
            XCTAssertGreaterThan(actions.count, 40)
            // Each of its words (a long one wraps, and the text runs across
            // both columns line by line)
            func words(_ text: String) -> [Substring] { text.split(whereSeparator: { $0.isWhitespace }) }
            let text = Set(words(page.string ?? ""))
            var missing: [String] = [], outside: [String] = []
            for action in Set(actions) {
                guard words(action).allSatisfy(text.contains) else { missing.append(action); continue }
                // Where its first word is drawn
                let first = String(action.split(whereSeparator: { $0.isWhitespace })[0])
                let found = document.findString(first, withOptions: [])
                if found.isEmpty || !found.allSatisfy({ printable.contains($0.bounds(for: page)) }) { outside.append(action) }
            }
            XCTAssertEqual(missing, [], "\(paper)")
            XCTAssertEqual(outside, [], "\(paper)")
        }
        if let path = ProcessInfo.processInfo.environment["CHEATSHEET_PDF"] {
            try ShortcutsHelpView.cheatSheetPDF().write(to: URL(fileURLWithPath: path))
        }
    }
}
