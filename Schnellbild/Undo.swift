import SwiftUI

/// One action on disk the app did, as it can be undone and redone: a
/// rename, a move to the Trash, a move or copy into a folder.
struct UndoStep {
    enum Kind { case rename, trash, move, copy }
    /// Each part carries the identity of the item where it lies now (after
    /// the action for Undo, before it for Redo): Undo and Redo act only on
    /// that very item, never on another one that took its name.
    enum Part: Sendable {
        case moved(URL, to: URL, identity: ItemIdentity?)
        /// `to` is the copy.
        case copied(URL, to: URL, identity: ItemIdentity?)
        /// Where it lay, and where it lies in the Trash.
        case trashed(URL, inTrash: URL, identity: ItemIdentity?)
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
        var paths: [String] = []
        let base = folder.standardizedFileURL.path.count + 1
        if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            while let item = walk.nextObject() as? URL {
                paths.append(String(item.standardizedFileURL.path.dropFirst(base)))
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
    /// The App Sandbox lets the app put items into the Trash, not take them out.
    case outOfTrashDenied(String)

    var errorDescription: String? {
        switch self {
        case .notTheSame(let name):
            return String(localized: "“\(name)” is no longer the item Schnellbild put there, so it stays as it is.")
        case .changed(let name):
            return String(localized: "“\(name)” has changed since it was copied, so it isn't moved to the Trash.")
        case .outOfTrashDenied(let name):
            return String(localized: "Schnellbild may not take “\(name)” out of the Trash. Use “Put Back” in the Finder's Trash.")
        }
    }
}

/// The window's undo and redo, as often as wanted. Only in the context
/// menus (no keys): an undo moves files again, which shouldn't happen by
/// a stray ⌘Z.
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
                    case (.trashed(let original, let inTrash, let identity), true):
                        try check(inTrash, identity)
                        do {
                            try move(inTrash, original)
                        } catch let error as RenameError {
                            throw error
                        } catch where Self.isPermissionDenied(error) {
                            throw UndoError.outOfTrashDenied(original.lastPathComponent)
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

    /// A move refused for want of permission (the sandbox, the Trash's rights).
    nonisolated private static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain, [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(error.code) { return true }
            if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

extension UndoStep.Part {
    /// The item's place before the action (to tell parts apart).
    var source: String {
        switch self {
        case .moved(let a, _, _), .copied(let a, _, _), .trashed(let a, _, _): return BrowserModel.canonicalPath(a)
        }
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
        }
    }

    static func redoTitle(_ kind: UndoStep.Kind) -> LocalizedStringKey {
        switch kind {
        case .rename: return "Redo Rename"
        case .trash: return "Redo Move to Trash"
        case .move: return "Redo Move"
        case .copy: return "Redo Copy"
        }
    }
}
