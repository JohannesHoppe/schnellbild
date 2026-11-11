import SwiftUI

/// One action on disk the app did, as it can be undone and redone: a
/// rename, a move to the Trash, a move or copy into a folder.
struct UndoStep {
    enum Kind { case rename, trash, move, copy }
    enum Part: Sendable {
        case moved(URL, to: URL)
        /// `to` is the copy.
        case copied(URL, to: URL)
        /// Where it lay, and where it lies in the Trash.
        case trashed(URL, inTrash: URL)
    }
    let kind: Kind
    var parts: [Part]
}

/// The window's undo and redo, as often as wanted. Only in the context
/// menus (no keys): an undo moves files again, which shouldn't happen by
/// a stray ⌘Z.
@MainActor
final class FileHistory: ObservableObject {
    @Published private(set) var undoSteps: [UndoStep] = []
    @Published private(set) var redoSteps: [UndoStep] = []

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
        guard let step = undoHistory.popUndo() else { return }
        run(step, undoing: true)
    }

    /// Does again what was undone last.
    func redo() {
        guard let step = undoHistory.popRedo() else { return }
        run(step, undoing: false)
    }

    private func run(_ step: UndoStep, undoing: Bool) {
        let spy = fileActions.runsOffMain ? nil : fileActions
        let parts = undoing ? Array(step.parts.reversed()) : step.parts
        let work: @Sendable () -> (done: [UndoStep.Part], changes: [FileChange], folders: [URL], error: Error?) = {
            var done: [UndoStep.Part] = []
            var changes: [FileChange] = []
            var folders: [URL] = []
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
                    case (.moved(let a, let b), true):
                        try move(b, a); changes.append(.moved(b, to: a)); done.append(part)
                    case (.moved(let a, let b), false):
                        try move(a, b); changes.append(.moved(a, to: b)); done.append(part)
                    case (.copied(let source, let copy), true):
                        _ = try trash(copy)
                        changes.append(.removed(copy)); done.append(.copied(source, to: copy))
                    case (.copied(let source, let copy), false):
                        if let spy { try MainActor.assumeIsolated { try spy.copy(source, copy) } } else { try LiveFiles.copy(source, copy) }
                        folders.append(copy.deletingLastPathComponent()); done.append(part)
                    case (.trashed(let original, let inTrash), true):
                        try move(inTrash, original)
                        folders.append(original.deletingLastPathComponent()); done.append(part)
                    case (.trashed(let original, _), false):
                        guard let inTrash = try trash(original) else { throw CocoaError(.fileWriteUnknown) }
                        changes.append(.removed(original)); done.append(.trashed(original, inTrash: inTrash))
                    }
                } catch {
                    return (done, changes, folders, error)
                }
            }
            return (done, changes, folders, nil)
        }
        onFiles(work) { [self] result in
            if let error = result.error { fileActions.report(error) }
            // What was carried out can go the other way again; a step that
            // failed half way keeps its other half where it was
            let done = undoing ? Array(result.done.reversed()) : result.done
            if !done.isEmpty {
                let carried = UndoStep(kind: step.kind, parts: done)
                if undoing { undoHistory.pushRedo(carried) } else { undoHistory.pushUndo(carried) }
            }
            if done.count < step.parts.count {
                let rest = step.parts.filter { part in !done.contains { $0.source == part.source } }
                if !rest.isEmpty {
                    let left = UndoStep(kind: step.kind, parts: rest)
                    if undoing { undoHistory.pushUndo(left) } else { undoHistory.pushRedo(left) }
                }
            }
            apply(result.changes)
            // What came back (out of the Trash, a copy made again) is read anew
            let folders = result.folders + result.changes.compactMap { change in
                change.destination.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent, isDirectory: true) }
            }
            if !folders.isEmpty {
                notifyFolderChanges(folders)
                refresh(changed: folders)
            }
        }
    }
}

extension UndoStep.Part {
    /// The item's place before the action (to tell parts apart).
    var source: String {
        switch self {
        case .moved(let a, _), .copied(let a, _), .trashed(let a, _): return BrowserModel.canonicalPath(a)
        }
    }
}

/// "Undo …" / "Redo …" at the top of a context menu, when there is something.
struct UndoMenuItems: View {
    @ObservedObject var history: FileHistory
    let model: BrowserModel

    var body: some View {
        if let step = history.undoSteps.last {
            Button(Self.undoTitle(step.kind)) { model.undo() }
        }
        if let step = history.redoSteps.last {
            Button(Self.redoTitle(step.kind)) { model.redo() }
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
