import AppKit
import Security

/// Which folders the app may read in the App Sandbox (the DMG and the Mac
/// App Store build alike). The sandbox opens a folder to the app when the
/// user chooses it in an open panel or drops it on the window, with
/// everything inside it; such a grant is kept as a security-scoped bookmark
/// and opened again at launch, so the last folder, the bookmarks and the
/// other pane come back after a restart. A folder outside every grant (the
/// folder above, a bookmark to elsewhere) asks: the open panel at that
/// folder (`ask`).
///
/// Only what the app opens is kept: a folder or archive chosen or dropped
/// (`grant`). A file dropped alone from a folder outside every grant is
/// held for the session only (`hold`, the newest `heldFileLimit`): a
/// launch reopens folders, never a lone file. Access is started once per
/// grant and stopped when a grant goes (one holding it replaces it, the
/// user forgets them all, its item is gone): Apple's documentation of
/// `startAccessingSecurityScopedResource()` asks for every start to be
/// balanced by a stop, since leaked starts eventually keep the app from
/// adding locations to its sandbox until it is relaunched.
///
/// A grant on a volume that isn't there (a NAS asleep, a USB disk
/// unplugged) is kept as it is and tried again when a volume mounts or a
/// place inside it is opened (`retry(covering:)`). One whose volume is
/// mounted but that no longer resolves, or resolves into the Trash, names
/// an item that is gone: it is dropped.
///
/// Bookmarks are resolved off the main thread (a share that is mounted but
/// doesn't answer holds the resolution until its timeout); reading a
/// folder waits for the grants kept to be open (`restored()`).
///
/// The standard folders the app's entitlements open to it (Pictures) are
/// covered without a grant (`standardFolders`).
///
/// Renaming or moving an item, or adding one, needs the folder that holds
/// it covered: the sandbox refuses to rename a granted folder itself, since
/// its parent isn't open to the app (`mayChange(in:)`).
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
    /// How many files dropped alone keep their access for the session:
    /// enough for Back to reach them again.
    static let heldFileLimit = 32

    /// What the app asks of the system, so tests can stand in for it.
    struct System: Sendable {
        /// A security-scoped bookmark of a URL the sandbox opened to the app.
        var bookmark: @Sendable (URL) -> Data?
        /// A bookmark resolved without asking and without mounting a volume.
        var resolve: @Sendable (Data) -> (url: URL, stale: Bool)?
        /// The path a bookmark names, read from its data without resolving it.
        var path: @Sendable (Data) -> String?
        var start: @Sendable (URL) -> Bool
        var stop: @Sendable (URL) -> Void
        /// The mount points of the volumes there now (canonical paths).
        var mountedVolumes: @Sendable () -> Set<String>

        static let live = System(
            bookmark: { try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
            resolve: { data in
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                         relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
                return (url, stale)
            },
            path: { data in
                URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path.map { BrowserModel.canonicalPath(URL(fileURLWithPath: $0)) }
            },
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() },
            mountedVolumes: {
                Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).map(BrowserModel.canonicalPath))
            }
        )
    }

    /// Where the grants are kept (the app's preferences; set at launch).
    var defaults = UserDefaults.standard
    private let sandboxed: Bool
    private let system: System

    private struct Grant: Sendable {
        let url: URL
        let path: String
        /// Nil for a file held for the session only.
        let bookmark: Data?
        /// This app started the access (and stops it).
        let started: Bool
    }
    private var grants: [Grant] = []
    private var held: [Grant] = []
    /// Grants that didn't open (their volume not mounted), with the path
    /// the bookmark names, when it says.
    private var pending: [(bookmark: Data, path: String?)] = []
    /// Bookmarks being resolved (at launch, a volume mounting): kept in the
    /// preferences meanwhile.
    private var resolving: [Data] = []
    private var restoring: Task<Void, Never>?

    /// Folders open without a grant: the standard folders the entitlements name.
    private let standard: [String]

    init(sandboxed: Bool = FolderAccess.isSandboxed, system: System = .live, standardFolders: [URL]? = nil) {
        self.sandboxed = sandboxed
        self.system = system
        standard = (standardFolders ?? (sandboxed ? Self.standardFolders : [])).map(BrowserModel.canonicalPath)
    }

    /// The user's standard folders the app's own entitlements open to it
    /// (`com.apple.security.assets.<folder>.read-write`), in the real home
    /// folder, not the container's.
    nonisolated static var standardFolders: [URL] {
        guard let task = SecTaskCreateFromSelf(nil), let home = getpwuid(getuid())?.pointee.pw_dir else { return [] }
        let homeURL = URL(fileURLWithPath: String(cString: home), isDirectory: true)
        let folders = ["pictures": "Pictures", "movies": "Movies", "music": "Music"]
        return folders.compactMap { key, name in
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.assets.\(key).read-write" as CFString, nil)
            return (value as? Bool) == true ? homeURL.appendingPathComponent(name, isDirectory: true) : nil
        }
    }

    /// The folders granted before, opened again (once, at launch, before
    /// any folder is read), off the main thread. Resolved without mounting
    /// anything, so a share that is gone doesn't hold the launch; those are
    /// kept for later.
    func restore() {
        guard sandboxed, restoring == nil else { return }
        let saved = defaults.array(forKey: Self.key) as? [Data] ?? []
        resolving = saved
        restoring = Task { await open(saved.map { (bookmark: $0, path: nil) }) }
    }

    /// Returns once the grants kept are open: a folder is read after it.
    func restored() async {
        await restoring?.value
    }

    /// A volume was mounted (`DiskEvents`, before the panes hear of it): the
    /// grants waiting for their volume are tried again.
    func volumeMounted() async {
        await restored()
        _ = await retryPending { _ in true }
    }

    /// A grant kept for a volume that wasn't there and covers `url`: tried
    /// again. Returns whether `url` is covered now (read it again then).
    func retry(covering url: URL) async -> Bool {
        await restored()
        guard sandboxed, !pending.isEmpty, !covers(url) else { return false }
        let path = BrowserModel.canonicalPath(url)
        // (one whose path isn't known is tried too)
        return await retryPending { $0.map { Self.path(path, isIn: $0) } ?? true } && covers(url)
    }

    /// Opens the pending grants `which` picks; returns whether one opened.
    private func retryPending(_ which: (String?) -> Bool) async -> Bool {
        let chosen = pending.filter { which($0.path) }
        guard !chosen.isEmpty else { return false }
        let bookmarks = Set(chosen.map(\.bookmark))
        // Out of `pending` while they are tried: never opened twice at once
        pending.removeAll { bookmarks.contains($0.bookmark) }
        resolving += chosen.map(\.bookmark)
        return await open(chosen)
    }

    /// Resolves and starts bookmarks off the main thread, then takes what
    /// opened; what waits for its volume goes back to `pending`, what is
    /// gone is dropped. Returns whether one opened. The caller has put
    /// them into `resolving`, so the preferences keep them meanwhile.
    @discardableResult
    private func open(_ kept: [(bookmark: Data, path: String?)]) async -> Bool {
        let system = system
        let bookmarks = kept.map(\.bookmark)
        let outcomes = await Blocking.run(.userInitiated) { Self.resolveAll(bookmarks, system) }
        var opened = false
        for (entry, outcome) in zip(kept, outcomes) {
            if let index = resolving.firstIndex(of: entry.bookmark) { resolving.remove(at: index) }
            switch outcome {
            case .opened(let grant):
                // Granted meanwhile (dropped while this resolved): not twice
                if isGranted(grant.path) {
                    if grant.started { system.stop(grant.url) }
                } else {
                    add(grant)
                    opened = true
                }
            case .waiting(let path): pending.append((entry.bookmark, path ?? entry.path))
            case .gone: break
            }
        }
        save()
        BrowserModel.testLog("folder access opened: \(grants.map(\.path)), waiting \(pending.compactMap(\.path))")
        return opened
    }

    private enum Outcome: Sendable {
        case opened(Grant)
        case waiting(path: String?)
        case gone
    }

    /// Kept bookmarks resolved and their access started (off the main thread).
    nonisolated private static func resolveAll(_ bookmarks: [Data], _ system: System) -> [Outcome] {
        var mounted: Set<String>?
        return bookmarks.map { data in
            guard let (url, stale) = system.resolve(data) else {
                // Not resolved: gone when its volume is there, else waiting
                // No path at all: no bookmark (damaged data), nothing it could ever open
                guard let path = system.path(data) else { return .gone }
                if mounted == nil { mounted = system.mountedVolumes() }
                return mounted!.contains(volume(of: path)) ? .gone : .waiting(path: path)
            }
            let path = BrowserModel.canonicalPath(url)
            guard !isInTrash(path) else { return .gone }
            let started = system.start(url)
            guard started else { return .waiting(path: path) }
            // Moved or renamed meanwhile: the bookmark is made anew
            let bookmark = stale ? (system.bookmark(url) ?? data) : data
            return .opened(Grant(url: url, path: path, bookmark: bookmark, started: true))
        }
    }

    /// The mount point of the volume a path lies on: "/Volumes/<name>", or
    /// "/" for the startup disk.
    nonisolated static func volume(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return "/" }
        return "/Volumes/" + parts[1]
    }

    /// In a Trash: the user's (~/.Trash) or a volume's (/.Trashes).
    nonisolated static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    /// A folder or archive the user chose or dropped: readable from now on
    /// and after a restart. Called while the sandbox has opened it to the
    /// app (right after the panel or the drop).
    func grant(_ url: URL) {
        guard sandboxed else { return }
        let path = BrowserModel.canonicalPath(url)
        guard !isGranted(path) else { return }
        let started = system.start(url)
        guard started || FileManager.default.isReadableFile(atPath: url.path), let bookmark = system.bookmark(url) else {
            if started { system.stop(url) }
            return
        }
        add(Grant(url: url, path: path, bookmark: bookmark, started: started))
        save()
        BrowserModel.testLog("folder access granted: \(path)")
    }

    /// A file the sandbox opened alone (dropped from a folder outside every
    /// grant): its access is held while the app runs, not kept for a
    /// restart. The oldest held file beyond `heldFileLimit` is let go.
    func hold(_ file: URL) {
        guard sandboxed, !covers(file) else { return }
        held.append(Grant(url: file, path: BrowserModel.canonicalPath(file), bookmark: nil, started: system.start(file)))
        while held.count > Self.heldFileLimit { release(held.removeFirst()) }
    }

    /// A grant taken: grants and held files inside it aren't needed beside it.
    private func add(_ grant: Grant) {
        for inner in grants + held where Self.path(inner.path, isIn: grant.path) { release(inner) }
        grants.removeAll { Self.path($0.path, isIn: grant.path) }
        held.removeAll { Self.path($0.path, isIn: grant.path) }
        pending.removeAll { $0.path.map { Self.path($0, isIn: grant.path) } ?? false }
        grants.append(grant)
    }

    private func release(_ grant: Grant) {
        if grant.started { system.stop(grant.url) }
    }

    private func isGranted(_ path: String) -> Bool {
        grants.contains { Self.path(path, isIn: $0.path) }
    }

    /// Whether the app may read `url` (a folder, a file, a place inside an archive).
    func covers(_ url: URL) -> Bool {
        guard sandboxed else { return true }
        let path = BrowserModel.canonicalPath(url)
        return isGranted(path) || held.contains { $0.path == path } || standard.contains { Self.path(path, isIn: $0) }
    }

    /// Whether the app may rename or move what lies in `folder`, or add to
    /// it: the sandbox needs the folder itself open to the app, so a granted
    /// folder can't be renamed or moved, only what is inside it.
    func mayChange(in folder: URL) -> Bool {
        guard sandboxed else { return true }
        let path = BrowserModel.canonicalPath(folder)
        return isGranted(path) || standard.contains { Self.path(path, isIn: $0) }
    }

    /// How many folders are granted (Settings), those on volumes not there included.
    var count: Int { grants.count + pending.count + resolving.count }

    /// Every grant given up (Settings): folders ask again.
    func forgetAll() {
        for grant in grants + held { release(grant) }
        grants = []
        held = []
        pending = []
        resolving = []
        save()
    }

    /// Why a folder is asked for: the panel's message says it.
    enum Purpose {
        /// To show it (it lies outside every grant)
        case show
        /// To rename the folder named, which lies in it
        case rename(String)
        /// To put items into it (a move or copy)
        case moveInto
    }

    /// Asks the user to open `folder` to the app: the open panel, at that
    /// folder. Returns the folder chosen (it may be one that holds `folder`,
    /// or another one), granted.
    func ask(for folder: URL, to purpose: Purpose = .show) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Allow Access")
        switch purpose {
        case .show:
            panel.message = String(localized: "Choose this folder, or one that holds it, so Schnellbild may show it. Schnellbild remembers your choice.")
        case .rename(let name):
            panel.message = String(localized: "Choose the folder that holds “\(name)”, so Schnellbild may rename it. Schnellbild remembers your choice.")
        case .moveInto:
            panel.message = String(localized: "Choose this folder, so Schnellbild may put items into it. Schnellbild remembers your choice.")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        grant(url)
        return url
    }

    private func save() {
        defaults.set(grants.compactMap(\.bookmark) + pending.map(\.bookmark) + resolving, forKey: Self.key)
    }

    /// `path` is `folder` or lies inside it.
    nonisolated static func path(_ path: String, isIn folder: String) -> Bool {
        if path == folder || folder == "/" { return true }
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
