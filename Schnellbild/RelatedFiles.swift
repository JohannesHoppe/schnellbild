import Foundation

/// The files that belong to a file the App Sandbox opened alone (dropped
/// from a folder outside every grant): its XMP sidecar, a DJI drone's flight
/// log, the further volumes of a split archive. They have the file's name
/// with another extension, the convention Apple's related items follow: the
/// app declares their extensions as document types with
/// `NSIsRelatedItemType` (`Resources/Info.plist`, never offered to open them:
/// `LSHandlerRank` None), and reading one through an `NSFileCoordinator`
/// whose `NSFilePresenter` names the file opened as its
/// `primaryPresentedItemURL` makes the sandbox open it to the app as well
/// ("Accessing files from the macOS App Sandbox", "Use related file access
/// to work with groups of files").
///
/// Names that differ in more than the extension ("x.part2.rar" beside
/// "x.part1.rar", Sony's "nameM01.XML", the folder's GPX tracks) aren't
/// related items: they need the folder ("Allow Access…").
///
/// Outside the sandbox, or for a file that can be read anyway, nothing
/// happens. Thread-safe; it waits for the coordinator, so not on the main
/// thread.
enum RelatedFiles {
    /// Opens `related` (beside `primary`, of its name with another extension)
    /// to the app. Returns whether it can be read now; false also when it
    /// isn't there.
    static func open(_ related: URL, beside primary: URL) -> Bool {
        if canRead(related) { return true }
        guard FolderAccess.isSandboxed, FileManager.default.fileExists(atPath: related.path),
              isRelated(related, to: primary) else { return false }
        let presenter = RelatedPresenter(primary: primary, related: related)
        NSFileCoordinator.addFilePresenter(presenter)
        var readable = false
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: related, options: .withoutChanges, error: &error) { url in
            readable = canRead(url)
        }
        // Kept for as long as the app runs: the access goes with the presenter
        if readable { presenters.withLock { $0.append(presenter) } } else { NSFileCoordinator.removeFilePresenter(presenter) }
        return readable
    }

    /// In the same folder, of the same name with another extension, or of
    /// the whole name with one more ("photo.jpg.xmp"); compared without case.
    static func isRelated(_ related: URL, to primary: URL) -> Bool {
        guard related.deletingLastPathComponent().standardizedFileURL == primary.deletingLastPathComponent().standardizedFileURL else { return false }
        let stem = related.deletingPathExtension().lastPathComponent.lowercased()
        return (stem == primary.deletingPathExtension().lastPathComponent.lowercased()
                && related.pathExtension.lowercased() != primary.pathExtension.lowercased())
            || stem == primary.lastPathComponent.lowercased()
    }

    /// Whether the folder holding `file` can't be listed, though `file` can
    /// be read: a file the sandbox opened alone.
    static func isAlone(_ file: URL) -> Bool {
        guard FolderAccess.isSandboxed else { return false }
        let folder = file.deletingLastPathComponent().path
        guard let dir = opendir(folder) else { return canRead(file) }
        closedir(dir)
        return false
    }

    /// Whether the process may open the file for reading (the sandbox's
    /// answer, not only the permissions').
    static func canRead(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    private static let presenters = Locked<[RelatedPresenter]>([])
}

/// A related file presented to the coordinator, with the file it belongs to.
private final class RelatedPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    init(primary: URL, related: URL) {
        primaryPresentedItemURL = primary
        presentedItemURL = related
    }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
    var value: Value { withLock { $0 } }
    func set(_ value: Value) { withLock { $0 = value } }
}

/// A flag set from several threads at once (a walk told to stop, a lane
/// that found something, a continuation resumed once).
typealias ManagedFlag = Locked<Bool>

extension Locked where Value == Bool {
    convenience init() { self.init(false) }
    var isSet: Bool { value }
    func set() { set(true) }
    func reset() { set(false) }
    /// Sets the flag; true only for the caller that set it first.
    func claim() -> Bool { withLock { flag in defer { flag = true }; return !flag } }
}
