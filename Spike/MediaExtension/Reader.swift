import Foundation
import MediaExtension
import OSLog

// A format reader that only reports that the system asked it. It answers
// whether macOS starts a Media Extension built this way at all, and which
// processes (Quick Look, Finder thumbnails, an opted-in app) ask it.

let log = Logger(subsystem: "art.haushoppe.schnellbild.spike", category: "reader")

final class SpikeFactory: NSObject, MEFormatReaderExtension {
    required override init() {
        super.init()
        log.notice("spike: factory started in pid \(getpid(), privacy: .public)")
    }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws -> any MEFormatReader {
        let type = primaryByteSource.contentType?.identifier ?? "unknown"
        log.notice("spike: asked for \(primaryByteSource.fileName, privacy: .public) (\(type, privacy: .public))")
        throw MEError(.unsupportedFeature)
    }
}
