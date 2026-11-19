import Foundation

/// How the app reads what lies in a folder on disk: a folder's own listing
/// (`items(in:)`) and the walks over it (`run`: the search, a folder tile's
/// previews and whether it holds media). Both list hidden items as
/// `HiddenFiles` says and, while hidden items are shown, the AppleDouble
/// files ("._x") FileManager leaves out. A walk doesn't walk into a hidden
/// folder (unless shown), into a package (one file to the user) or through
/// a link (it may point back up, around and around). Synchronous: it waits
/// on the disk, so it runs on a thread of its own.
struct FolderWalk {
    let root: URL
    /// What `visit` reads of each item, read along with the listing.
    var keys: Set<URLResourceKey> = []
    /// Into the subfolders; else the folder's own items only.
    var deep = true
    /// Items looked at before the walk gives up (a huge tree on a network
    /// share: each item is a round trip).
    var limit = Int.max
    var shown = HiddenFiles.shown
    /// The AppleDouble files too, while hidden items are shown (a `readdir`
    /// of each folder walked into). Off for a walk after media only: an
    /// AppleDouble file is none.
    var appleDoubles = true

    enum Ending: Equatable {
        /// Every item was visited.
        case whole
        /// `visit` asked to stop.
        case stopped
        case cancelled
        /// Past `limit`: not known what the rest holds.
        case gaveUp
    }

    /// What the walk itself reads of each item (with `keys`).
    private static let ownKeys: Set<URLResourceKey> = [.isHiddenKey, .isDirectoryKey, .isSymbolicLinkKey]

    /// Visits every item the walk lists until `visit` returns false.
    @discardableResult
    func run(cancelled: () -> Bool = { false }, _ visit: (URL) -> Bool) -> Ending {
        // (a package's flag only while AppleDouble files are read in each folder walked into)
        let doubles = shown && appleDoubles
        let mine = doubles && deep ? Self.ownKeys.union([.isPackageKey]) : Self.ownKeys
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !deep { options.insert(.skipsSubdirectoryDescendants) }
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys.union(mine)),
                                                        options: options) else { return .whole }
        // AppleDouble files of the folders walked into, visited before the
        // folder's other items; FileManager may list some of them after all
        var pending = doubles ? HiddenFiles.appleDoubleItems(in: root, besides: []) : []
        var added = Set(pending.map(\.path))
        var looked = 0
        while true {
            if cancelled() { return .cancelled }
            looked += 1
            if looked > limit { return .gaveUp }
            // A pool per item: a walk over a million files would otherwise
            // hold every autoreleased object until it ends
            let ending: Ending? = autoreleasepool {
                if !pending.isEmpty { return visit(pending.removeFirst()) ? nil : .stopped }
                guard let url = walk.nextObject() as? URL else { return .whole }
                if !added.isEmpty, added.contains(url.path) { return nil }
                let values = try? url.resourceValues(forKeys: mine)
                let folder = values?.isDirectory == true && values?.isSymbolicLink != true
                guard HiddenFiles.lists(url, values: values, shown: shown) else {
                    // Only for a folder: after a file it would skip the rest of the folder holding it
                    if folder { walk.skipDescendants() }
                    return nil
                }
                if doubles, deep, folder, values?.isPackage != true {
                    let found = HiddenFiles.appleDoubleItems(in: url, besides: [])
                    pending = found
                    added.formUnion(found.map(\.path))
                }
                return visit(url) ? nil : .stopped
            }
            if let ending { return ending }
        }
    }

    /// A folder's own items (hidden ones as `HiddenFiles` says, or those in
    /// `kept`), with `keys` read along. Throws when the folder can't be
    /// listed.
    static func items(in folder: URL, keys: Set<URLResourceKey>, shown: Bool = HiddenFiles.shown) throws -> [URL] {
        let listed = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [])
        return shown ? listed + HiddenFiles.appleDoubleItems(in: folder, besides: listed) : listed
    }

    /// The names in a folder as `readdir` gives them (every item, AppleDouble
    /// files too) and whether each is a folder (not a link to one); nil
    /// when it can't be read.
    static func names(in path: String) -> [(name: String, isFolder: Bool)]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var found: [(name: String, isFolder: Bool)] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            var isFolder = entry.pointee.d_type == DT_DIR
            if entry.pointee.d_type == DT_UNKNOWN {
                // (a file system that doesn't say: asked, without following a link)
                var info = stat()
                isFolder = lstat(path + "/" + name, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
            found.append((name, isFolder))
        }
        return found
    }
}
