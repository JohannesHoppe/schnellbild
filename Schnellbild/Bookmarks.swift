import SwiftUI

/// Folder bookmarks, shared by both panes and remembered: ⌘D sets or
/// removes the folder shown, ⌃1 … ⌃9 open the first nine, the Bookmarks
/// menu, the star in the toolbar and a folder tile's context menu.
/// Kept as paths: a folder inside an archive can be one too. A bookmark
/// whose folder is gone opens as a folder that can't be read.
@MainActor
final class Bookmarks: ObservableObject {
    static let shared = Bookmarks(defaults: BrowserModel.makeDefaults())
    static let key = "folderBookmarks"

    @Published private(set) var folders: [URL]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        folders = (defaults.stringArray(forKey: Self.key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func contains(_ folder: URL) -> Bool {
        let path = BrowserModel.canonicalPath(folder)
        return folders.contains { BrowserModel.canonicalPath($0) == path }
    }

    /// Sets a bookmark (at the end), or removes the one there is.
    func toggle(_ folder: URL) {
        if contains(folder) { remove(folder) } else { folders.append(folder.standardizedFileURL); save() }
    }

    func remove(_ folder: URL) {
        let path = BrowserModel.canonicalPath(folder)
        folders.removeAll { BrowserModel.canonicalPath($0) == path }
        save()
    }

    /// A folder renamed or moved by the app: its bookmark follows.
    func follow(_ changes: [FileChange]) {
        let lookup = FileChanges(changes)
        let followed = folders.map { lookup.url($0) ?? $0 }
        guard followed != folders else { return }
        folders = followed
        save()
    }

    private func save() { defaults.set(folders.map(\.path), forKey: Self.key) }

    /// "Holiday" — "Photos/Holiday" when two bookmarks share a name.
    func title(of folder: URL) -> String {
        let name = folder.lastPathComponent
        let twins = folders.filter { $0.lastPathComponent == name }.count > 1
        return twins ? folder.deletingLastPathComponent().lastPathComponent + "/" + name : name
    }
}

/// The bookmarks' menu items: this folder's on / off (⌘D in the menu bar),
/// then every bookmark (the first nine with ⌃1 … ⌃9), and their removal.
struct BookmarkItems: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var bookmarks = Bookmarks.shared
    let shortcuts: Bool

    var body: some View {
        let shown = model.folderURL
        let marked = shown.map(bookmarks.contains) ?? false
        let toggle = Button(marked ? "Remove Bookmark for This Folder" : "Bookmark This Folder") {
            if let shown { bookmarks.toggle(shown) }
        }
        .disabled(shown == nil)
        if shortcuts { toggle.keyboardShortcut("d", modifiers: .command) } else { toggle }
        if !bookmarks.folders.isEmpty {
            Divider()
            ForEach(Array(bookmarks.folders.enumerated()), id: \.element) { index, folder in
                let item = Button(bookmarks.title(of: folder)) { model.open(folder: folder) }
                    .help(folder.path)
                if shortcuts, index < 9 {
                    item.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                } else {
                    item
                }
            }
            Divider()
            Menu("Remove Bookmark") {
                ForEach(bookmarks.folders, id: \.self) { folder in
                    Button(bookmarks.title(of: folder)) { bookmarks.remove(folder) }
                }
            }
        }
    }
}
