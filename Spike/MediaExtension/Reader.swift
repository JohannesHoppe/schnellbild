import Foundation
import MediaExtension
import OSLog

// A format reader that only reports that the system asked it. It answers
// whether macOS starts a Media Extension built this way at all, and which
// processes (Quick Look, Finder thumbnails, an opted-in app) ask it.

let log = Logger(subsystem: "art.haushoppe.schnellbild.spike", category: "reader")

/// Also a line in the extension's container (the probe reads it): the log
/// can miss a short-lived process.
func note(_ line: String) {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("spike-notes.txt")
    let text = line + "\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
    } else {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class SpikeFactory: NSObject, MEFormatReaderExtension {
    required override init() {
        super.init()
        log.notice("spike: factory started in pid \(getpid(), privacy: .public)")
        note("factory started in pid \(getpid())")
    }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws -> any MEFormatReader {
        let type = primaryByteSource.contentType?.identifier ?? "unknown"
        log.notice("spike: asked for \(primaryByteSource.fileName, privacy: .public) (\(type, privacy: .public))")
        note("asked for \(primaryByteSource.fileName) (\(type)) by \(ProcessInfo.processInfo.processName)")
        throw MEError(.unsupportedFeature)
    }
}
