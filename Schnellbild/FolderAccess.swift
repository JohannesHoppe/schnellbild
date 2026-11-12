import AppKit

/// Which folders the app may read in the App Sandbox (the Mac App Store
/// build). The sandbox opens a folder to the app when the user chooses it in
/// an open panel or drops it on the window, with everything inside it; such a
/// grant is kept as a security-scoped bookmark and opened again at launch, so
/// the last folder, the bookmarks and the other pane come back after a
/// restart. A folder outside every grant (the folder above, a bookmark to
/// elsewhere) asks: the open panel at that folder (`ask`).
///
/// Outside the sandbox (the DMG build) every folder can be read: nothing is
/// granted or kept, and `covers` is always true.
@MainActor
final class FolderAccess {
    static let shared = FolderAccess()
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

    init(sandboxed: Bool = FolderAccess.isSandboxed) {
        self.sandboxed = sandboxed
    }

    /// The folders granted before, opened again (once, at launch).
    func restore() {
        guard sandboxed else { return }
        for data in defaults.array(forKey: Self.key) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            // Moved or renamed meanwhile: the bookmark is made anew
            let bookmark = stale ? (Self.bookmark(of: url) ?? data) : data
            grants.append(Grant(url: url, path: BrowserModel.canonicalPath(url), bookmark: bookmark))
        }
        save()
    }

    /// A folder or file the user chose or dropped: readable from now on and
    /// after a restart. Called while the sandbox has opened it to the app
    /// (right after the panel or the drop).
    func grant(_ url: URL) {
        guard sandboxed, !covers(url) else { return }
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path),
              let bookmark = Self.bookmark(of: url) else { return }
        let path = BrowserModel.canonicalPath(url)
        // Grants inside the new one are no longer needed
        for inner in grants where Self.path(inner.path, isIn: path) { inner.url.stopAccessingSecurityScopedResource() }
        grants.removeAll { Self.path($0.path, isIn: path) }
        grants.append(Grant(url: url, path: path, bookmark: bookmark))
        save()
    }

    /// Whether the app may read `url` (a folder, a file, a place inside an archive).
    func covers(_ url: URL) -> Bool {
        guard sandboxed else { return true }
        let path = BrowserModel.canonicalPath(url)
        return grants.contains { Self.path(path, isIn: $0.path) }
    }

    /// How many folders are granted (Settings).
    var count: Int { grants.count }

    /// Every grant given up (Settings): folders ask again.
    func forgetAll() {
        for grant in grants { grant.url.stopAccessingSecurityScopedResource() }
        grants = []
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
        defaults.set(grants.map(\.bookmark), forKey: Self.key)
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
