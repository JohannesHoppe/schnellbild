import Foundation

/// Which files and folders are hidden, and whether the app shows them
/// (Settings → General, View → Show Hidden Files, ⇧⌘. as in the Finder).
/// One definition for every place that lists items: the grid and the list,
/// the other files, the search, slideshows, the Atlas, folder tiles and the
/// folders inside archives. Shown, nothing is left out, not even what macOS
/// keeps for itself (`isSystemItem`). Hiding is about what is shown: files
/// that belong to an item shown (XMP sidecars, a video's logs, GPX tracks,
/// the later volumes of a RAR) are read whether hidden or not.
enum HiddenFiles {
    /// The preference (app-wide, every pane and window; off unless turned on).
    static let shownKey = "showHiddenFiles"
    /// Every pane reads its folder, search and Atlas again.
    static let changed = Notification.Name("SchnellbildHiddenFilesChanged")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shownNow = false

    /// Whether hidden items are shown now. Read by the walks off the main
    /// thread; set from the preference by the panes (`BrowserModel`).
    static var shown: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shownNow }
        set { lock.lock(); shownNow = newValue; lock.unlock() }
    }

    /// What the listings read to tell (prefetched with the other keys).
    static let keys: Set<URLResourceKey> = [.isHiddenKey]

    /// What macOS keeps beside the items for itself: the Finder's view
    /// settings (".DS_Store"), AppleDouble files ("._x": a file's extra data
    /// on SMB shares, exFAT and FAT, part of "x"), a folder's custom icon
    /// ("Icon\r") and the folder that holds AppleDouble files in ZIPs made
    /// by the Finder ("__MACOSX"). Hidden like any other hidden item, also
    /// the two whose names don't start with a dot: with hidden items shown,
    /// every item on disk and in an archive is listed, so a folder that
    /// looks empty is empty.
    static func isSystemItem(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "Icon\r" || name == "__MACOSX"
    }

    /// The AppleDouble items ("._x") in `folder` that `listed` (what
    /// FileManager listed, which leaves them out) misses, read with
    /// `readdir`. Reads the disk; off the main thread.
    static func appleDoubleItems(in folder: URL, besides listed: [URL]) -> [URL] {
        let known = Set(listed.map(\.lastPathComponent))
        return (FolderWalk.names(in: folder.path) ?? []).compactMap { item in
            guard item.name.hasPrefix("._"), !known.contains(item.name) else { return nil }
            return folder.appendingPathComponent(item.name, isDirectory: item.isFolder)
        }
    }

    /// Hidden by its name: it starts with a dot, or it is one of macOS's
    /// own items (`isSystemItem`). No disk access.
    static func isHidden(name: String) -> Bool { name.hasPrefix(".") || isSystemItem(name) }

    /// Hidden: hidden by its name, or the hidden flag
    /// (`chflags hidden`: ~/Library, /usr, /Volumes …), read from `values`
    /// (`isHiddenKey`, which also says so for dot names).
    static func isHidden(name: String, values: URLResourceValues?) -> Bool {
        isHidden(name: name) || values?.isHidden == true
    }

    /// Whether a listing or walk lists an item: while hidden items are
    /// shown, every one; else a hidden item only when it is in `kept`
    /// (canonical paths of items the user opened himself: a file dropped,
    /// a folder chosen).
    static func lists(_ url: URL, values: URLResourceValues?, shown: Bool = HiddenFiles.shown,
                      kept: Set<String> = []) -> Bool {
        if shown || !isHidden(name: url.lastPathComponent, values: values) { return true }
        return !kept.isEmpty && kept.contains(BrowserModel.canonicalPath(url))
    }

    /// The same for a path inside an archive (no hidden flag there): every
    /// part of `path` below the place listed counts.
    static func lists(archivePath path: String, shown: Bool = HiddenFiles.shown) -> Bool {
        shown || !path.split(separator: "/").contains { isHidden(name: String($0)) }
    }

    /// The first folder from `root` (exclusive) down to `folder` that is
    /// hidden, or nil: where a pane shows a place inside hidden folders
    /// it didn't open itself (`BrowserModel.hiddenFilesChanged`). Reads the
    /// disk; off the main thread.
    static func firstHidden(below root: URL, to folder: URL) -> URL? {
        let rootPath = BrowserModel.canonicalPath(root)
        let path = BrowserModel.canonicalPath(folder)
        guard path != rootPath, BrowserModel.isSameOrInside(path, rootPath) else { return nil }
        let rest = path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1)
        var current = URL(fileURLWithPath: rootPath, isDirectory: true)
        for part in rest.split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true)
            // Inside an archive the names alone tell
            let values = ArchivePath.isInside(current) ? nil : try? current.resourceValues(forKeys: keys)
            if isHidden(name: String(part), values: values) { return current }
        }
        return nil
    }
}
