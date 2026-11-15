// Draws the multi-page PDF the UI tests page through (UITests/Fixtures/pages.pdf):
// three pages, each one flat colour with a white square in its middle, so a
// test can tell them apart on screen: 1 red (portrait), 2 green (landscape),
// 3 blue (portrait). No text, no external images, no personal data.
//
//   swift Scripts/make_pdf_fixture.swift UITests/Fixtures
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "UITests/Fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let url = out.appendingPathComponent("pages.pdf")

let pages: [(size: CGSize, red: CGFloat, green: CGFloat, blue: CGFloat)] = [
    (CGSize(width: 420, height: 560), 0.85, 0.1, 0.1),
    (CGSize(width: 640, height: 420), 0.1, 0.7, 0.2),
    (CGSize(width: 420, height: 560), 0.1, 0.2, 0.85),
]
var media = CGRect(origin: .zero, size: pages[0].size)
let info: [CFString: Any] = [kCGPDFContextTitle: "Schnellbild test pages", kCGPDFContextCreator: "make_pdf_fixture.swift"]
guard let context = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else {
    FileHandle.standardError.write("can't write \(url.path)\n".data(using: .utf8)!)
    exit(1)
}
for page in pages {
    var box = CGRect(origin: .zero, size: page.size)
    let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
    context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
    context.setFillColor(CGColor(srgbRed: page.red, green: page.green, blue: page.blue, alpha: 1))
    context.fill(box)
    let side = min(box.width, box.height) / 4
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side))
    context.endPDFPage()
}
context.closePDF()
print("wrote \(url.path)")
