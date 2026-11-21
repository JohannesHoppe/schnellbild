import XCTest
import AppKit
import AVFoundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
@testable import Schnellbild

/// What this macOS draws and plays, printed into the log of each CI runner
/// (macOS 15 and 26), the evidence for the app's format lists: ImageIO's
/// readable and writable types, AppKit's, AVFoundation's, whether anything
/// draws PostScript, and which picture extensions the app lists that no
/// system type behind ImageIO names. Lines start with "formats:".
final class SystemFormatsTests: XCTestCase {
    private func say(_ line: String) { print("formats: " + line) }

    func testPrintWhatThisMacOSReads() {
        say("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let readable = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).sorted()
        for identifier in readable {
            let type = UTType(identifier)
            say("ImageIO reads \(identifier) [\((type?.tags[.filenameExtension] ?? []).joined(separator: " "))] \(type?.localizedDescription ?? "")")
        }
        say("ImageIO writes " + (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).sorted().joined(separator: " "))
        say("NSImage reads " + NSImage.imageTypes.sorted().joined(separator: " "))
        say("AVFoundation plays " + AVURLAsset.audiovisualTypes().map(\.rawValue).sorted().joined(separator: " "))

        // The app's picture extensions and the ImageIO type each one names
        let types = readable.compactMap(UTType.init)
        for ext in BrowserModel.imageExtensions.sorted() {
            let named = UTType(filenameExtension: ext)
            let reader = types.first { named?.conforms(to: $0) == true }
            say("extension .\(ext): \(named?.identifier ?? "no type") → \(reader?.identifier ?? "not ImageIO's")")
        }
    }

    /// Pictures made in the test (`FormatFixtures`) under the extension of
    /// their format, each decoded by ImageIO from the file.
    func testPrintWhatImageIODecodes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (ext, data) in FormatFixtures.all() {
            guard let data else { say("decode .\(ext): no fixture (ImageIO doesn't write it here)"); continue }
            let url = dir.appendingPathComponent("picture.\(ext)")
            try data.write(to: url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { say("decode .\(ext): no source"); continue }
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            say("decode .\(ext): type \(CGImageSourceGetType(source) as String? ?? "nil"), status \(CGImageSourceGetStatus(source).rawValue), "
                + "frames \(CGImageSourceGetCount(source)), " + (image.map { "\($0.width) × \($0.height)" } ?? "no image"))
        }
    }

    /// PostScript: macOS 14 and later convert none (`NSEPSImageRep`'s
    /// header: no instances from macOS 14 on); AppKit, ImageIO and PDFKit are
    /// asked with a PostScript program here, and whether QuickLook makes a
    /// picture of it and of an Illustrator file.
    func testPrintWhetherAnythingDrawsPostScript() async throws {
        let eps = FormatFixtures.postScript
        say("NSImage(data: EPS) \(NSImage(data: eps).map { "\($0.size) \($0.representations)" } ?? "nil")")
        say("PDFDocument(data: EPS) \(PDFDocument(data: eps) == nil ? "nil" : "a document")")
        let source = CGImageSourceCreateWithData(eps as CFData, nil)
        say("ImageIO EPS \(source.flatMap { CGImageSourceGetType($0) as String? } ?? "nil"), images \(source.map(CGImageSourceGetCount) ?? 0)")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [(String, Data)] = [("plain.eps", eps), ("plain.ps", eps), ("pdf.ai", FormatFixtures.illustratorWithPDF()),
                                       ("epsi.eps", FormatFixtures.epsi())]
        if let dos = FormatFixtures.dosEPS() { files.append(("dos.eps", dos)) }
        if let ai = FormatFixtures.illustratorWithoutPDF() { files.append(("placeholder.ai", ai)) }
        for (name, data) in files {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: 1, representationTypes: .all)
            let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let kind = rep.map { $0.type == .thumbnail ? "thumbnail" : $0.type == .icon ? "icon" : "low quality" } ?? "nothing"
            say("QuickLook \(name) (\(UTType(filenameExtension: url.pathExtension)?.identifier ?? "-")): \(kind)")
        }
    }
}
