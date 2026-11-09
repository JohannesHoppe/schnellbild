import SwiftUI
import AppKit
import Combine

/// The window: one pane, or two side by side (the dual pane, D or ⌃O, as in
/// the file commanders). Each pane is a `BrowserModel` of its own — folder,
/// search, history, sort, full view; keys and the toolbar act on the active
/// one (Tab switches). F5 copies, F6 moves the active pane's marked items
/// into the other pane's folder; what one pane changes on disk, the other
/// reads again.
@MainActor
final class WindowModel: ObservableObject {
    let left: BrowserModel
    @Published private(set) var right: BrowserModel?
    @Published private(set) var dual = false
    @Published private(set) var rightIsActive = false

    static let dualKey = "dualPane"
    private let defaults: UserDefaults
    private let makeRight: () -> BrowserModel
    private var forwarding: [AnyCancellable] = []

    init(left: BrowserModel, defaults: UserDefaults, makeRight: @escaping () -> BrowserModel) {
        self.left = left
        self.defaults = defaults
        self.makeRight = makeRight
        watch(left)
        if defaults.bool(forKey: Self.dualKey) { setDual(true) }
    }

    var active: BrowserModel { rightIsActive ? (right ?? left) : left }
    var other: BrowserModel? { dual ? (rightIsActive ? left : right) : nil }
    var panes: [BrowserModel] { dual ? [left, right].compactMap { $0 } : [left] }

    /// Menus and the toolbar read the active pane: its changes are the window's.
    private func watch(_ pane: BrowserModel) {
        forwarding.append(pane.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        pane.onFoldersChanged = { [weak self, weak pane] folders in
            guard let self, let pane else { return }
            for other in self.panes where other !== pane && other.shows(any: folders) { other.refresh() }
        }
        // One volume and one mini keyboard for the window
        forwarding.append(pane.$volume.dropFirst().sink { [weak self, weak pane] volume in
            guard let self else { return }
            for other in self.panes where other !== pane { other.adoptVolume(volume) }
        })
        forwarding.append(pane.$showMiniKeyboard.dropFirst().sink { [weak self, weak pane] shown in
            guard let self else { return }
            for other in self.panes where other !== pane && other.showMiniKeyboard != shown { other.showMiniKeyboard = shown }
        })
    }

    func toggleDual() { setDual(!dual) }

    func setDual(_ on: Bool) {
        if on, right == nil {
            let pane = makeRight()
            right = pane
            watch(pane)
            // Its own last folder, else the same as the left one
            if !pane.restoreLastFolderNow(), let folder = left.folderURL { pane.open(folder: folder) }
        }
        dual = on
        if !on { rightIsActive = false }
        defaults.set(on, forKey: Self.dualKey)
    }

    func activate(_ pane: BrowserModel) {
        guard dual else { return }
        let isRight = pane === right
        if rightIsActive != isRight { rightIsActive = isRight }
    }

    func switchPane() {
        guard dual else { return }
        rightIsActive.toggle()
    }

    /// F5 / F6: the active pane's marked (or selected) items into the other
    /// pane's folder.
    func sendToOtherPane(how: BrowserModel.Transfer) -> Bool {
        guard let other, let folder = other.folderURL else { return false }
        let sources = active.actionEntries.map(\.url)
        guard !sources.isEmpty else { NSSound.beep(); return true }
        active.move(sources, into: folder, how: how)
        active.clearMarks()
        return true
    }

    /// Keys the window takes before the active pane: D / ⌃O (dual pane),
    /// Tab (switch), F5 / F6 (to the other pane). Not while typing.
    func handleWindowKey(_ key: BrowserModel.KeyInput, command: Bool, control: Bool, shift: Bool = false,
                         textEditing: Bool) -> Bool {
        guard !textEditing, active.slideshow == nil, !active.anySheetOpen else { return false }
        // ⇧F6 renames (the pane's), as in Total Commander
        if key == .f6, shift { return false }
        let handled = dispatchWindowKey(key, command: command, control: control)
        if handled { active.noteKeyPress(key, command: command) }   // the mini keyboard lights it up
        return handled
    }

    private func dispatchWindowKey(_ key: BrowserModel.KeyInput, command: Bool, control: Bool) -> Bool {
        switch key {
        case .char(let c) where !command && !control && c.lowercased() == "d":
            toggleDual(); return true
        case .char(let c) where control && !command && c.lowercased() == "o":
            toggleDual(); return true
        case .tab where dual:
            switchPane(); return true
        case .f5 where dual:
            return sendToOtherPane(how: .copy)
        case .f6 where dual:
            return sendToOtherPane(how: .move)
        default:
            return false
        }
    }
}

extension BrowserModel {
    /// Any of the sheets is open (they keep their keys).
    var anySheetOpen: Bool { showHelp || renameTarget != nil || passwordRequest != nil || newFolderRequested }
}

/// F9 and F10, as in Norton Commander: the app's menus in the window
/// (Norton's pull-down menu bar), and quitting after a question.
@MainActor
enum NortonMenus {
    private static func popUp(_ menu: NSMenu) {
        guard let window = BrowserModel.appWindow, let view = window.contentView else { return }
        menu.autoenablesItems = false
        let point = NSPoint(x: view.bounds.midX - 120, y: view.bounds.midY + 100)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// The menu bar's menus (Go, Actions, View …) in one menu in the window.
    static func showMainMenus() {
        guard let main = NSApp.mainMenu else { return }
        let menu = NSMenu()
        for top in main.items.dropFirst() where top.submenu != nil && top.isEnabled {   // without the app menu
            let copy = top.copy() as! NSMenuItem
            menu.addItem(copy)
        }
        popUp(menu)
    }

    static func askToQuit() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to quit Schnellbild?")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }
}
