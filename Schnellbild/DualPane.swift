import SwiftUI
import AppKit
import Combine

/// A window: one pane, or two side by side (the dual pane, D or ⌃O, as in
/// the file commanders). Each pane is a `BrowserModel` of its own — folder,
/// search, history, sort, full view; keys and the toolbar act on the active
/// one (Tab switches). F5 copies, F6 moves the active pane's marked items
/// into the other pane's folder; what one pane changes on disk, every other
/// pane (of this window and the others) follows.
/// The app has one or more windows (⌘N, e.g. one per display), each its own
/// `WindowModel` with its own remembered folders, sort, dual pane and divider
/// (`settingsPrefix`: none for the first window, "window2." … for the
/// others); keys, menus, full screen and slideshows act on the window they
/// happen in (`current`: the key window's).
@MainActor
final class WindowModel: ObservableObject {
    let left: BrowserModel
    @Published private(set) var right: BrowserModel?
    @Published private(set) var dual = false
    @Published private(set) var rightIsActive = false
    /// A folder or file from the Finder dragged over the window: the zone
    /// under the pointer (left half browses, right half plays).
    @Published var dropZone: DropZone?

    static let dualKey = "dualPane"
    static let splitKey = "dualPaneSplit"
    /// 1 for the first window; its settings carry no prefix.
    let number: Int
    let settingsPrefix: String
    /// The AppKit window showing it (set by its view).
    weak var nsWindow: NSWindow?
    /// The left pane's share of the window's width (the divider between the
    /// panes), remembered.
    @Published private(set) var split = 0.5
    static let splitRange = 0.15...0.85
    private let defaults: UserDefaults
    private let makeRight: () -> BrowserModel
    private var forwarding: [AnyCancellable] = []

    init(left: BrowserModel, defaults: UserDefaults, number: Int = 1, makeRight: @escaping () -> BrowserModel) {
        self.left = left
        self.defaults = defaults
        self.number = number
        settingsPrefix = Self.prefix(number)
        self.makeRight = makeRight
        Self.windows.append(Weak(self))
        watch(left)
        // A right pane with no folder of its own (and none being checked)
        // shows the left one's, also when that opens only after launch
        forwarding.append(left.$folderURL.compactMap { $0 }.sink { [weak self] folder in
            guard let right = self?.right, right.folderURL == nil, !right.restoringLastFolder, !right.isLoading else { return }
            right.open(folder: folder)
        })
        if defaults.object(forKey: settingsPrefix + Self.splitKey) != nil {
            split = min(max(defaults.double(forKey: settingsPrefix + Self.splitKey), Self.splitRange.lowerBound), Self.splitRange.upperBound)
        }
        if defaults.bool(forKey: settingsPrefix + Self.dualKey) { setDual(true) }
    }

    // MARK: The app's windows

    private struct Weak { weak var model: WindowModel?; init(_ model: WindowModel) { self.model = model } }
    private static var windows: [Weak] = []
    /// The first window's model, made at launch; a window that opens while
    /// it shows in none takes it.
    private(set) var claimed = false

    /// Every window's model still alive, in the order they were made.
    static var all: [WindowModel] {
        windows.removeAll { $0.model == nil }
        return windows.compactMap(\.model)
    }

    static func prefix(_ number: Int) -> String { number == 1 ? "" : "window\(number)." }

    /// The model of an AppKit window of the app.
    static func of(_ window: NSWindow?) -> WindowModel? {
        guard let window else { return nil }
        return all.first { $0.nsWindow === window }
    }

    /// The window keys, menus and Settings act on: the key window's, else
    /// the main window's, else the first one showing.
    static var current: WindowModel? {
        of(NSApp.keyWindow) ?? of(NSApp.mainWindow) ?? all.first { $0.nsWindow?.isVisible == true }
    }

    /// The model for a window opening: the first one while no window shows
    /// it, else a new one with the lowest number no open window has.
    static func claim(_ first: WindowModel, defaults: UserDefaults) -> WindowModel {
        if !first.claimed { first.claimed = true; return first }
        let opener = current?.active.folderURL
        let taken = Set(all.filter(\.claimed).map(\.number))
        let number = (2...).first { !taken.contains($0) }!
        let prefix = Self.prefix(number)
        let left = BrowserModel(defaults: defaults, settingsPrefix: prefix)
        let model = WindowModel(left: left, defaults: defaults, number: number) {
            BrowserModel(defaults: defaults, settingsPrefix: prefix + "rightPane.")
        }
        model.claimed = true
        model.startFolder = opener
        return model
    }

    /// Where a new window opens when it has no last folder of its own: the
    /// folder of the window it was opened from.
    private(set) var startFolder: URL?

    /// Its window closed: free for the next one (the first window's model)
    /// and quiet (a video or slideshow in it ends).
    func windowClosed() {
        claimed = false
        nsWindow = nil
        for pane in allPanes { pane.leaveWindow() }
    }

    /// Moves the divider; `remember` when the drag ends.
    func setSplit(_ value: Double, remember: Bool = false) {
        split = min(max(value, Self.splitRange.lowerBound), Self.splitRange.upperBound)
        if remember { defaults.set(split, forKey: settingsPrefix + Self.splitKey) }
    }

    var active: BrowserModel { rightIsActive ? (right ?? left) : left }
    var other: BrowserModel? { dual ? (rightIsActive ? left : right) : nil }
    var panes: [BrowserModel] { dual ? allPanes : [left] }
    /// How long a picture stays in the slideshow, in seconds (Settings):
    /// remembered, and the same in both panes.
    var slideshowSeconds: Int {
        get { Int(left.slideshowInterval.components.seconds) }
        set {
            let seconds = min(max(newValue, BrowserModel.slideshowSecondsRange.lowerBound), BrowserModel.slideshowSecondsRange.upperBound)
            objectWillChange.send()
            defaults.set(seconds, forKey: BrowserModel.slideshowSecondsKey)
            for window in Self.all { for pane in window.allPanes { pane.slideshowInterval = .seconds(seconds) } }
        }
    }

    /// A sheet is open in either pane: it keeps the keys and the menus.
    var anySheetOpen: Bool { panes.contains { $0.anySheetOpen } }
    /// Both panes, the right one also while hidden.
    private var allPanes: [BrowserModel] { [left, right].compactMap { $0 } }
    /// Every pane of every window.
    private static var everyPane: [BrowserModel] { all.flatMap(\.allPanes) }

    /// Menus and the toolbar read the active pane: its changes are the
    /// window's (each pane's own view watches that pane itself).
    private func watch(_ pane: BrowserModel) {
        forwarding.append(pane.objectWillChange.sink { [weak self, weak pane] _ in
            guard let self, pane === self.active else { return }
            self.objectWillChange.send()
        })
        // The other pane's sheets too: they disable the menus
        forwarding.append(Publishers.Merge4(pane.$passwordRequest.map { _ in () }, pane.$renameTarget.map { _ in () }.merge(with: pane.$renameFileTarget.map { _ in () }),
                                            pane.$newFolderRequested.map { _ in () }, pane.$showHelp.map { _ in () })
            .sink { [weak self, weak pane] in
                guard let self, pane !== self.active else { return }
                self.objectWillChange.send()
            })
        pane.onActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane)
        }
        pane.owner = self
        // The other panes (also a hidden one, also in the other windows)
        // follow what this one changes
        pane.onFileChange = { [weak pane] changes in
            guard let pane else { return }
            for other in Self.everyPane where other !== pane { other.adopt(changes) }
        }
        pane.onFoldersChanged = { [weak pane] folders in
            guard let pane else { return }
            for other in Self.everyPane where other !== pane && other.shows(any: folders) { other.refresh(changed: folders) }
        }
        // One volume and one mini keyboard for the window. @Published sends
        // before the value is stored, so the other pane's own sink would see
        // this one's old value and send it back: `syncing` stops that echo.
        forwarding.append(pane.$volume.dropFirst().sink { [weak self, weak pane] volume in
            self?.sync { for other in $0 where other !== pane { other.adoptVolume(volume) } }
        })
        forwarding.append(pane.$showMiniKeyboard.dropFirst().sink { [weak self, weak pane] shown in
            self?.sync { for other in $0 where other !== pane && other.showMiniKeyboard != shown { other.showMiniKeyboard = shown } }
        })
    }

    private var syncing = false

    /// Hands a change to the other panes (both of them, also the hidden right one).
    private func sync(_ apply: ([BrowserModel]) -> Void) {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        apply(allPanes)
    }

    func toggleDual() { setDual(!dual) }

    func setDual(_ on: Bool) {
        if on, right == nil {
            let pane = makeRight()
            pane.undoHistory = left.undoHistory   // one history for the window
            right = pane
            watch(pane)
            // Its own last folder, else the same as the left one
            // (checked off the main thread: an unreachable share answers only after its timeout)
            pane.restoreLastFolder { [weak self] in self?.left.folderURL }
        }
        dual = on
        for pane in allPanes { pane.inDualPane = on }
        if !on { rightIsActive = false }
        defaults.set(on, forKey: settingsPrefix + Self.dualKey)
    }

    func activate(_ pane: BrowserModel) {
        guard dual else { return }
        let isRight = pane === right
        guard rightIsActive != isRight else { return }
        // The pane left behind stops typing in its search field: keys go to
        // the active one
        active.searchFocused = false
        rightIsActive = isRight
    }

    func switchPane() {
        guard dual else { return }
        rightIsActive.toggle()
    }

    /// F5 / F6: the active pane's marked (or selected) items into the other
    /// pane's folder.
    func sendToOtherPane(how: BrowserModel.Transfer) -> Bool {
        guard let other, let folder = other.folderURL else { return false }
        // In the full view: what it shows (the marks belong to the grid)
        let sources = active.mode == .detail ? (active.selectedMediaEntry.map { [$0.url] } ?? []) : active.actionEntries.map(\.url)
        guard !sources.isEmpty else { NSSound.beep(); return true }
        active.move(sources, into: folder, how: how)
        return true
    }

    /// Keys the window takes before the active pane: D / ⌃O (dual pane),
    /// Tab (switch), F5 / F6 (to the other pane). Not while typing.
    func handleWindowKey(_ key: BrowserModel.KeyInput, command: Bool, control: Bool, shift: Bool = false,
                         textEditing: Bool) -> Bool {
        // Not while typing, not during a slideshow, not over a sheet of either pane
        guard !textEditing, !panes.contains(where: { $0.slideshow != nil || $0.anySheetOpen }) else { return false }
        // ⇧F6 renames (the pane's), as in Total Commander
        if key == .f6, shift { return false }
        let handled = dispatchWindowKey(key, command: command, control: control, shift: shift)
        if handled { active.noteKeyPress(key, command: command, shift: shift) }   // the mini keyboard lights it up
        return handled
    }

    private func dispatchWindowKey(_ key: BrowserModel.KeyInput, command: Bool, control: Bool, shift: Bool) -> Bool {
        switch key {
        // ⇧⌘C / ⇧⌘M: F5 / F6 without fn on a Mac keyboard
        case .char(let c) where command && shift && !control && c.lowercased() == "c" && dual:
            return sendToOtherPane(how: .copy)
        case .char(let c) where command && shift && !control && c.lowercased() == "m" && dual:
            return sendToOtherPane(how: .move)
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

/// F9 and F10, as in Norton Commander: the app's menus in the window
/// (Norton's pull-down menu bar), and quitting after a question.
@MainActor
enum NortonMenus {
    private static func popUp(_ menu: NSMenu) {
        guard let window = WindowModel.current?.nsWindow ?? BrowserModel.appWindow, let view = window.contentView else { return }
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

/// The window keys, menus and Settings act on (`WindowModel.current`), for
/// the app's menus to follow: they redraw when it or its active pane changes.
@MainActor
final class WindowFocus: ObservableObject {
    static let shared = WindowFocus()
    @Published private(set) var current: WindowModel?
    private var forwarding: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowFocus.shared.update() }
            })
        }
    }

    func update() {
        let now = WindowModel.current
        guard now !== current else { return }
        current = now
        forwarding = now?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// Ties a window's model to the AppKit window showing it, and tells it when
/// that window closes.
struct WindowAttach: NSViewRepresentable {
    let window: WindowModel

    func makeNSView(context: Context) -> AttachView { AttachView(model: window) }
    func updateNSView(_ view: AttachView, context: Context) {}

    final class AttachView: NSView {
        let model: WindowModel
        private var closing: NSObjectProtocol?
        init(model: WindowModel) {
            self.model = model
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, model.nsWindow !== window else { return }
            model.nsWindow = window
            if let closing { NotificationCenter.default.removeObserver(closing) }
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [model] _ in
                MainActor.assumeIsolated { model.windowClosed() }
            }
            WindowFocus.shared.update()
        }

        deinit { if let closing { NotificationCenter.default.removeObserver(closing) } }
    }
}

