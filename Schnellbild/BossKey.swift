import AppKit

/// The boss key: X (or the key set in Settings) hides every window of the
/// app and mutes it at once; only that key typed three times, each within a
/// second, with the app in front brings it back, and ⌘Q still quits. The
/// windows stay open, invisible and letting clicks through: a click on the
/// Dock icon or ⌘-Tab brings the app forward with nothing to see (its menu
/// bar only), and its keys still arrive here. A window in full screen has a
/// space of its own, black behind an invisible window: it leaves full screen
/// first (the app hides once it has) and goes back into it on return.
@MainActor
enum BossKey {
    private(set) static var engaged = false
    private static var counter = Counter()
    private static var activationGuard: NSObjectProtocol?
    private static var fullScreenWindows: [NSWindow] = []
    private static var hidden = HiddenWindows()
    private static var exitWatch: NSObjectProtocol?

    /// Posted when the app goes quiet or comes back: players set their volume.
    static let changed = Notification.Name("BossKeyChanged")

    /// Set once the first use's explanation has been shown.
    static let explainedKey = "bossKeyExplained"

    /// The boss key pressed: the very first time an alert says what it does
    /// and how to come back, then the app goes quiet.
    static func press() {
        guard !engaged else { return }
        let defaults = BrowserModel.makeDefaults()
        if needsExplaining(defaults: defaults) {
            explain()
            defaults.set(true, forKey: explainedKey)
        }
        engage()
    }

    /// Whether the explanation is still to come: never shown before, and
    /// not under a UI test unless it asks for it (`--explain-boss-key`).
    static func needsExplaining(defaults: UserDefaults, testing: Bool = TestSwitches.on,
                                asked: Bool = TestSwitches.has("--explain-boss-key")) -> Bool {
        !defaults.bool(forKey: explainedKey) && (!testing || asked)
    }

    /// The first use's alert, with the boss key as set.
    static func explanation(_ shortcuts: Shortcuts) -> String {
        let key = shortcuts.keys(.bossKey).first?.text ?? String(localized: "no key")
        return String(localized: "Schnellbild disappears at once and every video goes silent. A click on the Dock icon doesn't bring it back. To bring it back, switch to Schnellbild (⌘ + Tab) and press \(key) three times within a second.")
    }

    private static func explain() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Boss key")
        alert.informativeText = explanation(.shared)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    static func engage() {
        guard !engaged else { return }
        engaged = true
        counter = Counter()
        NotificationCenter.default.post(name: changed, object: nil)
        hideWindows()
        fullScreenWindows = NSApp.windows.filter { $0.styleMask.contains(.fullScreen) }
        if fullScreenWindows.isEmpty {
            NSApp.hide(nil)
        } else {
            // Hidden in full screen, the app would leave its black space on screen
            exitWatch = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                               object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hideAfterFullScreen() }
            }
            for window in fullScreenWindows { _ = FullScreenSwitch.shared.set(false, window: window) }
            // Should the end of the animation never be reported
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { hideAfterFullScreen() } }
        }
        // Brought forward (Dock, ⌘-Tab): a window macOS shows again stays
        // invisible, and one of them takes the keys
        activationGuard = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                 object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { broughtForward() }
        }
        BrowserModel.testLog("boss key engaged")
    }

    private static func hideAfterFullScreen() {
        if let exitWatch { NotificationCenter.default.removeObserver(exitWatch) }
        exitWatch = nil
        if engaged, !NSApp.isHidden { NSApp.hide(nil) }
    }

    /// The app in front again while engaged: every window stays invisible.
    static func broughtForward() {
        guard engaged else { return }
        hideWindows()
        // The keys go to the key window: one of the invisible ones takes them
        if NSApp.keyWindow == nil, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKey()
        }
        BrowserModel.testLog("boss key: brought forward, key window \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")")
    }

    /// Every key while engaged goes here and nowhere else; ⌘Q quits.
    static func typed(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        // By the letter on the key, as the menus read it, on any layout
        if modifiers == .command, LatinKeys.letter(of: event) == "q" {
            NSApp.terminate(nil)
            return
        }
        BrowserModel.testLog("boss key: typed \(KeyChord.from(event)?.stored ?? "nil")\(event.isARepeat ? " (repeat)" : "")")
        if counter.typed(key: KeyChord.from(event), repeating: event.isARepeat, at: Date(), shortcuts: .shared) { release() }
    }

    /// Shows every window again (the boss key three times).
    static func release() {
        guard engaged else { return }
        engaged = false
        if let activationGuard { NotificationCenter.default.removeObserver(activationGuard) }
        activationGuard = nil
        hidden.restore()
        if let exitWatch { NotificationCenter.default.removeObserver(exitWatch) }
        exitWatch = nil
        NotificationCenter.default.post(name: changed, object: nil)
        // Typed while hidden (the keys still arrive): shown again
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for window in fullScreenWindows { _ = FullScreenSwitch.shared.set(true, window: window) }
        fullScreenWindows = []
        BrowserModel.testLog("boss key released")
    }

    private static func hideWindows() {
        hidden.hide(NSApp.windows)
    }

    /// The windows hiding made invisible and click-through, each with the
    /// alpha and mouse handling it had: the release gives exactly those
    /// back, so a window with an alpha or mouse handling of its own, or one
    /// that appeared while engaged and was never hidden, keeps its own.
    @MainActor
    struct HiddenWindows {
        private var windows: [(window: Weak, alpha: CGFloat, ignoresMouse: Bool)] = []

        final class Weak {
            weak var window: NSWindow?
            init(_ window: NSWindow) { self.window = window }
        }

        /// Hides these windows; one hidden already keeps what it had before.
        mutating func hide(_ list: [NSWindow]) {
            for window in list {
                if !windows.contains(where: { $0.window.window === window }) {
                    windows.append((Weak(window), window.alphaValue, window.ignoresMouseEvents))
                }
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
        }

        /// Gives every window hidden what it had (those still open), once.
        mutating func restore() {
            for entry in windows {
                guard let window = entry.window.window else { continue }
                window.alphaValue = entry.alpha
                window.ignoresMouseEvents = entry.ignoresMouse
            }
            windows = []
        }
    }

    /// The boss key three times in a row, each within a second of the one
    /// before; any other key starts over, a key held down (its repeats)
    /// neither counts nor starts over.
    struct Counter {
        private var count = 0
        private var last: Date?

        /// True on the third boss key: `key` as typed, one of the boss
        /// key's keys as set.
        @MainActor
        mutating func typed(key: KeyChord?, repeating: Bool, at time: Date, shortcuts: Shortcuts) -> Bool {
            if repeating { return false }
            return typed(x: key.map { Self.isBossKey($0, shortcuts) } == true, at: time)
        }

        /// One of the boss key's keys; a letter with ⇧ counts as the
        /// letter, as when the boss key is pressed (`Shortcuts.resolve`).
        @MainActor
        static func isBossKey(_ key: KeyChord, _ shortcuts: Shortcuts) -> Bool {
            let keys = shortcuts.keys(.bossKey)
            if keys.contains(key) { return true }
            guard key.shift, case .char(let c) = key.key, c.isLetter else { return false }
            return keys.contains(KeyChord(key.key, command: key.command, option: key.option, control: key.control))
        }

        /// True on the third X.
        mutating func typed(x: Bool, at time: Date) -> Bool {
            guard x else { count = 0; last = nil; return false }
            if let last, time.timeIntervalSince(last) > 1 { count = 0 }
            count += 1
            last = time
            if count == 3 { count = 0; self.last = nil; return true }
            return false
        }
    }
}
