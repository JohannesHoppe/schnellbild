import AppKit

/// Which folders the app may read in the App Sandbox (the DMG and the Mac
/// App Store build alike). The sandbox opens a folder to the app when the
/// user chooses it in an open panel or drops it on the window, with
/// everything inside it; such a grant is kept as a security-scoped bookmark
/// and opened again at launch, so the last folder, the bookmarks and the
/// other pane come back after a restart. A folder outside every grant (the
/// folder above, a bookmark to elsewhere) asks: the open panel at that
/// folder (`ask`).
///
/// A grant on a volume that isn't there (a NAS asleep, a USB disk
/// unplugged) is kept as it is and tried again when a volume mounts or a
/// place inside it is opened (`retry(covering:)`), never dropped.
///
/// Without the sandbox (unit tests, a build run from the terminal) every
/// folder can be read: nothing is granted or kept, and `covers` is always
/// true.
@MainActor
final class FolderAccess {
    static var shared = FolderAccess()
    /// Launched in the App Sandbox.
    nonisolated static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    static let key = "folderAccess"

    /// Where the grants are kept (the app's preferences; set at launch).
    var defaults = UserDefaults.standard
    private let sandboxed: Bool

    private struct Grant {
        let url: URL
        let path: String
        let bookmark: Data
    }
    private var grants: [Grant] = []
    /// Grants that didn't open (their volume not mounted), with the path
    /// the bookmark names, when it says.
    private var pending: [(bookmark: Data, path: String?)] = []
    private var mountObserver: NSObjectProtocol?

    init(sandboxed: Bool = FolderAccess.isSandboxed) {
        self.sandboxed = sandboxed
    }

    /// The folders granted before, opened again (once, at launch, before
    /// any folder is read). Resolved without mounting anything, so a share
    /// that is gone doesn't hold the launch; those are kept for later.
    func restore() {
        guard sandboxed else { return }
        for data in defaults.array(forKey: Self.key) as? [Data] ?? [] {
            if let grant = Self.opened(data) { grants.append(grant) } else { pending.append((data, Self.path(ofBookmark: data))) }
        }
        save()
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.retryPending { _ in true } }
        }
    }

    /// A grant kept for a volume that wasn't there and covers `url`: tried
    /// again. Returns whether `url` is covered now (read it again then).
    @discardableResult
    func retry(covering url: URL) -> Bool {
        guard sandboxed, !pending.isEmpty, !covers(url) else { return false }
        let path = BrowserModel.canonicalPath(url)
        // (one whose path isn't known is tried too)
        return retryPending { $0.map { Self.path(path, isIn: $0) } ?? true } && covers(url)
    }

    /// Opens the pending grants `which` picks; returns whether one opened.
    private func retryPending(_ which: (String?) -> Bool) -> Bool {
        var opened = false
        pending.removeAll { entry in
            guard which(entry.path), let grant = Self.opened(entry.bookmark) else { return false }
            grants.append(grant)
            opened = true
            return true
        }
        if opened { save() }
        return opened
    }

    /// A folder or file the user chose or dropped: readable from now on and
    /// after a restart. Called while the sandbox has opened it to the app
    /// (right after the panel or the drop).
    func grant(_ url: URL) {
        guard sandboxed, !covers(url) else { return }
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path),
              let bookmark = Self.bookmark(of: url) else { return }
        let path = BrowserModel.canonicalPath(url)
        // Grants inside the new one aren't needed beside it
        for inner in grants where Self.path(inner.path, isIn: path) { inner.url.stopAccessingSecurityScopedResource() }
        grants.removeAll { Self.path($0.path, isIn: path) }
        pending.removeAll { $0.path.map { Self.path($0, isIn: path) } ?? false }
        grants.append(Grant(url: url, path: path, bookmark: bookmark))
        save()
    }

    /// Whether the app may read `url` (a folder, a file, a place inside an archive).
    func covers(_ url: URL) -> Bool {
        guard sandboxed else { return true }
        let path = BrowserModel.canonicalPath(url)
        return grants.contains { Self.path(path, isIn: $0.path) }
    }

    /// How many folders are granted (Settings), those on volumes not there included.
    var count: Int { grants.count + pending.count }

    /// Every grant given up (Settings): folders ask again.
    func forgetAll() {
        for grant in grants { grant.url.stopAccessingSecurityScopedResource() }
        grants = []
        pending = []
        save()
    }

    /// Asks the user to open `folder` to the app: the open panel, at that
    /// folder. Returns the folder chosen (it may be one that holds `folder`,
    /// or another one), granted.
    func ask(for folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Allow Access")
        panel.message = String(localized: "Choose this folder, or one that holds it, so Schnellbild may show it. Schnellbild remembers your choice.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        grant(url)
        return url
    }

    private func save() {
        defaults.set(grants.map(\.bookmark) + pending.map(\.bookmark), forKey: Self.key)
    }

    /// A kept bookmark opened: resolved without asking and without mounting
    /// a volume, its access started. Nil while its volume isn't there.
    private static func opened(_ data: Data) -> Grant? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        // Moved or renamed meanwhile: the bookmark is made anew
        let bookmark = stale ? (bookmark(of: url) ?? data) : data
        return Grant(url: url, path: BrowserModel.canonicalPath(url), bookmark: bookmark)
    }

    /// The path a bookmark names, read from its data without resolving it.
    private static func path(ofBookmark data: Data) -> String? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path.map { BrowserModel.canonicalPath(URL(fileURLWithPath: $0)) }
    }

    private static func bookmark(of url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// `path` is `folder` or lies inside it.
    nonisolated static func path(_ path: String, isIn folder: String) -> Bool {
        if path == folder || folder == "/" { return true }
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
