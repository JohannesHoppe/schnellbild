import SwiftUI

/// One action on disk the app did, as it can be undone and redone: a
/// rename, a move to the Trash, a move or copy into a folder, a new folder.
struct UndoStep {
    enum Kind { case rename, trash, move, copy, newFolder }
    /// Each part carries the identity of the item where it lies now (after
    /// the action for Undo, before it for Redo): Undo and Redo act only on
    /// that very item, never on another one that took its name.
    enum Part: Sendable {
        case moved(URL, to: URL, identity: ItemIdentity?)
        /// `to` is the copy.
        case copied(URL, to: URL, identity: ItemIdentity?)
        /// Where it lay, and where it lies in the Trash.
        case trashed(URL, inTrash: URL, identity: ItemIdentity?)
        /// A folder the app made (its identity with its contents: empty).
        case created(URL, identity: ItemIdentity?)
    }
    let kind: Kind
    var parts: [Part]
}

/// Which item lies at a place: its volume and file number (the same item
/// keeps them through renames and moves on its volume). For a copied
/// folder also what it holds, so undoing the copy never trashes what was
/// put into it later.
struct ItemIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    var contents: Int?

    /// The item at `url` (a link as the link); with `withContents` a
    /// folder's whole contents too (by their relative paths).
    static func of(_ url: URL, withContents: Bool = false) -> ItemIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        var identity = ItemIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
        if withContents, (info.st_mode & S_IFMT) == S_IFDIR {
            identity.contents = contentsHash(url)
        }
        return identity
    }

    private static func contentsHash(_ folder: URL) -> Int {
        // Every item by its path inside the folder, AppleDouble files ("._x")
        // too, one `readdir` per folder (links not followed)
        var paths: [String] = []
        let base = folder.standardizedFileURL.path
        var folders = [""]
        while let inner = folders.popLast() {
            for item in FolderWalk.names(in: inner.isEmpty ? base : base + "/" + inner) ?? [] {
                // The Finder's view settings, written when it shows the folder
                if item.name == ".DS_Store" { continue }
                let path = inner.isEmpty ? item.name : inner + "/" + item.name
                paths.append(path)
                if item.isFolder { folders.append(path) }
            }
        }
        var hasher = Hasher()
        for path in paths.sorted() { hasher.combine(path) }
        hasher.combine(paths.count)
        return hasher.finalize()
    }

    /// Whether the item now at the place is the one recorded (`self`).
    func matches(_ current: ItemIdentity?) -> Bool {
        guard let current else { return false }
        return device == current.device && inode == current.inode && (contents == nil || contents == current.contents)
    }
}

/// Why an Undo or Redo left an item as it is.
enum UndoError: LocalizedError {
    /// Another item lies where the action put it.
    case notTheSame(String)
    /// A copied folder holds other things now.
    case changed(String)
    /// A folder the app made isn't empty any more.
    case filled(String)
    /// Nothing lies where the item went in the Trash (emptied, put back).
    case goneFromTrash(String)
    /// An item couldn't be taken out of the Trash (the name taken, no
    /// permission, the volume gone): it is still in the Trash.
    case stillInTrash(String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notTheSame(let name):
            return String(localized: "“\(name)” is no longer the item Schnellbild put there, so it stays as it is.")
        case .changed(let name):
            return String(localized: "“\(name)” has changed since it was copied, so it isn't moved to the Trash.")
        case .filled(let name):
            return String(localized: "“\(name)” isn't empty any more, so it isn't moved to the Trash.")
        case .goneFromTrash(let name):
            return String(localized: "“\(name)” is no longer in the Trash.")
        case .stillInTrash(let name, let reason):
            return String(localized: "“\(name)” couldn't be taken out of the Trash and is still there. \(reason)")
        }
    }
}

/// The window's undo and redo, as often as wanted: Edit → Undo / Redo
/// (⌘Z, ⇧⌘Z) and the top of the context menus.
@MainActor
final class FileHistory: ObservableObject {
    @Published private(set) var undoSteps: [UndoStep] = []
    @Published private(set) var redoSteps: [UndoStep] = []
    /// An undo or redo is being carried out: no second one meanwhile (both
    /// would act on the same items).
    @Published fileprivate(set) var running = false

    func record(_ step: UndoStep) {
        guard !step.parts.isEmpty else { return }
        undoSteps.append(step)
        redoSteps.removeAll()
    }

    fileprivate func popUndo() -> UndoStep? { undoSteps.popLast() }
    fileprivate func popRedo() -> UndoStep? { redoSteps.popLast() }
    fileprivate func pushUndo(_ step: UndoStep) { undoSteps.append(step) }
    fileprivate func pushRedo(_ step: UndoStep) { redoSteps.append(step) }
}

extension BrowserModel {
    /// Undoes the newest action: a rename or move back, a copy to the
    /// Trash, a trashed item back out of the Trash to where it was.
    func undo() {
        Self.testLog("\(Date().timeIntervalSince1970) undo: \(undoHistory.undoSteps.last.map { "\($0.kind) \($0.parts.map { URL(fileURLWithPath: $0.source).lastPathComponent })" } ?? "nothing"), running \(undoHistory.running)")
        guard !undoHistory.running, let step = undoHistory.popUndo() else { return }
        run(step, undoing: true)
    }

    /// Does again what was undone last.
    func redo() {
        guard !undoHistory.running, let step = undoHistory.popRedo() else { return }
        run(step, undoing: false)
    }

    private func run(_ step: UndoStep, undoing: Bool) {
        undoHistory.running = true
        let spy = fileActions.runsOffMain ? nil : fileActions
        let parts = undoing ? Array(step.parts.reversed()) : step.parts
        let work: @Sendable () -> (done: [UndoStep.Part], changes: [FileChange], folders: [URL], error: Error?) = {
            var done: [UndoStep.Part] = []
            var changes: [FileChange] = []
            var folders: [URL] = []
            /// The item at `url` must be the one the step recorded.
            func check(_ url: URL, _ identity: ItemIdentity?) throws {
                guard let identity else { return }
                let current = ItemIdentity.of(url, withContents: identity.contents != nil)
                if identity.matches(current) { return }
                if let current, current.device == identity.device, current.inode == identity.inode {
                    throw UndoError.changed(url.lastPathComponent)
                }
                throw UndoError.notTheSame(url.lastPathComponent)
            }
            func move(_ a: URL, _ b: URL) throws {
                // Never over something that took the name meanwhile
                let taken = if let spy { MainActor.assumeIsolated { spy.conflicts(b, a) } } else { LiveFiles.conflicts(b, a) }
                if taken {
                    throw RenameError.alreadyExists(b.lastPathComponent)
                }
                if let spy { try MainActor.assumeIsolated { try spy.move(a, b) } } else { try LiveFiles.move(a, b) }
            }
            func trash(_ url: URL) throws -> URL? {
                if let spy { return try MainActor.assumeIsolated { try spy.trash(url) } }
                return try LiveFiles.trash(url)
            }
            for part in parts {
                do {
                    switch (part, undoing) {
                    case (.moved(let a, let b, let identity), true):
                        try check(b, identity)
                        try move(b, a); changes.append(.moved(b, to: a))
                        done.append(.moved(a, to: b, identity: ItemIdentity.of(a)))
                    case (.moved(let a, let b, let identity), false):
                        try check(a, identity)
                        try move(a, b); changes.append(.moved(a, to: b))
                        done.append(.moved(a, to: b, identity: ItemIdentity.of(b)))
                    case (.copied(let source, let copy, let identity), true):
                        try check(copy, identity)
                        _ = try trash(copy)
                        changes.append(.removed(copy)); done.append(.copied(source, to: copy, identity: nil))
                    case (.copied(let source, let copy, _), false):
                        if let spy { try MainActor.assumeIsolated { try spy.copy(source, copy) } } else { try LiveFiles.copy(source, copy) }
                        folders.append(copy.deletingLastPathComponent())
                        done.append(.copied(source, to: copy, identity: ItemIdentity.of(copy, withContents: true)))
                    case (.created(let folder, let identity), true):
                        do { try check(folder, identity) } catch UndoError.changed { throw UndoError.filled(folder.lastPathComponent) }
                        _ = try trash(folder)
                        changes.append(.removed(folder)); done.append(.created(folder, identity: nil))
                    case (.created(let folder, _), false):
                        if let spy {
                            try MainActor.assumeIsolated {
                                if spy.conflicts(folder, folder.deletingLastPathComponent()) { throw RenameError.alreadyExists(folder.lastPathComponent) }
                                try spy.createFolder(folder)
                            }
                        } else {
                            if LiveFiles.conflicts(folder, folder.deletingLastPathComponent()) { throw RenameError.alreadyExists(folder.lastPathComponent) }
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                        }
                        folders.append(folder.deletingLastPathComponent())
                        done.append(.created(folder, identity: ItemIdentity.of(folder, withContents: true)))
                    case (.trashed(let original, let inTrash, let identity), true):
                        var info = stat()
                        guard lstat(inTrash.path, &info) == 0 else { throw UndoError.goneFromTrash(original.lastPathComponent) }
                        try check(inTrash, identity)
                        do {
                            try move(inTrash, original)
                        } catch {
                            throw UndoError.stillInTrash(original.lastPathComponent, reason: error.localizedDescription)
                        }
                        folders.append(original.deletingLastPathComponent())
                        done.append(.trashed(original, inTrash: inTrash, identity: ItemIdentity.of(original)))
                    case (.trashed(let original, _, let identity), false):
                        try check(original, identity)
                        guard let inTrash = try trash(original) else { throw CocoaError(.fileWriteUnknown) }
                        changes.append(.removed(original))
                        done.append(.trashed(original, inTrash: inTrash, identity: ItemIdentity.of(inTrash)))
                    }
                } catch {
                    return (done, changes, folders, error)
                }
            }
            return (done, changes, folders, nil)
        }
        onFiles(work) { [self] result in
            undoHistory.running = false
            // What was carried out can go the other way again
            let done = undoing ? Array(result.done.reversed()) : result.done
            if !done.isEmpty {
                let carried = UndoStep(kind: step.kind, parts: done)
                if undoing { undoHistory.pushRedo(carried) } else { undoHistory.pushUndo(carried) }
            }
            // A step that failed (half way) keeps its other part to try
            // again, or is forgotten so the steps before it can be reached
            if let error = result.error {
                let rest = step.parts.filter { part in !done.contains { $0.source == part.source } }
                if fileActions.keepFailedUndo(error, !rest.isEmpty), !rest.isEmpty {
                    let left = UndoStep(kind: step.kind, parts: rest)
                    if undoing { undoHistory.pushUndo(left) } else { undoHistory.pushRedo(left) }
                }
            }
            let keep = selectedEntry?.url
            apply(result.changes)
            // The folder shown went along (its rename undone): follow it;
            // else what went to another folder leaves this one's listing
            if !followFolder(through: result.changes) { dropWhatLeft(keeping: keep) }
            // What came back (out of the Trash, a copy made again) is read anew
            let folders = result.folders + result.changes.compactMap { change in
                change.destination.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent, isDirectory: true) }
            }
            if !folders.isEmpty {
                notifyFolderChanges(folders)
                // Read again only when the folder shown (or a search over it) got something
                if let shown = folderURL, isFiltering || folders.contains(where: { BrowserModel.samePath($0, shown) }) {
                    refresh(changed: folders)
                }
            }
        }
    }
}

extension UndoStep.Part {
    /// The item's place before the action (to tell parts apart).
    var source: String {
        switch self {
        case .moved(let a, _, _), .copied(let a, _, _), .trashed(let a, _, _), .created(let a, _): return BrowserModel.canonicalPath(a)
        }
    }
}

/// Edit → Undo … / Redo … with ⌘Z and ⇧⌘Z, for the window's file actions.
/// While text is typed, ⌘Z and ⇧⌘Z are the text field's (the key monitor
/// hands them to it before the menu sees them).
struct UndoCommands: View {
    @ObservedObject var history: FileHistory
    @ObservedObject var window: WindowModel
    let model: BrowserModel

    var body: some View {
        let blocked = history.running || window.anySheetOpen
        Button(history.undoSteps.last.map { UndoMenuItems.undoTitle($0.kind) } ?? "Undo") { model.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(history.undoSteps.isEmpty || blocked)
        Button(history.redoSteps.last.map { UndoMenuItems.redoTitle($0.kind) } ?? "Redo") { model.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(history.redoSteps.isEmpty || blocked)
    }
}

/// "Undo …" / "Redo …" at the top of a context menu, when there is something.
struct UndoMenuItems: View {
    @ObservedObject var history: FileHistory
    let model: BrowserModel

    var body: some View {
        if let step = history.undoSteps.last {
            Button(Self.undoTitle(step.kind)) { model.undo() }.disabled(history.running)
        }
        if let step = history.redoSteps.last {
            Button(Self.redoTitle(step.kind)) { model.redo() }.disabled(history.running)
        }
        if !history.undoSteps.isEmpty || !history.redoSteps.isEmpty { Divider() }
    }

    static func undoTitle(_ kind: UndoStep.Kind) -> LocalizedStringKey {
        switch kind {
        case .rename: return "Undo Rename"
        case .trash: return "Undo Move to Trash"
        case .move: return "Undo Move"
        case .copy: return "Undo Copy"
        case .newFolder: return "Undo New Folder"
        }
    }

    static func redoTitle(_ kind: UndoStep.Kind) -> LocalizedStringKey {
        switch kind {
        case .rename: return "Redo Rename"
        case .trash: return "Redo Move to Trash"
        case .move: return "Redo Move"
        case .copy: return "Redo Copy"
        case .newFolder: return "Redo New Folder"
        }
    }
}
