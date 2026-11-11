import AppKit

/// The boss key: X hides every window of the app and mutes it at once;
/// only X typed three times brings it back (or quitting and starting again).
/// The windows stay open, invisible and letting clicks through, so the Dock
/// icon or ⌘-Tab bring the app forward with nothing to see, and its keys
/// still arrive here. A window in full screen has a space of its own, black
/// behind an invisible window: it leaves full screen first (the app hides
/// once it has) and goes back into it on return.
@MainActor
enum BossKey {
    private(set) static var engaged = false
    private static var counter = Counter()
    private static var reopenGuard: NSObjectProtocol?
    private static var fullScreenWindows: [NSWindow] = []
    private static var exitWatch: NSObjectProtocol?

    /// Posted when the app goes quiet or comes back: players set their volume.
    static let changed = Notification.Name("BossKeyChanged")

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
        // Brought forward (Dock, ⌘-Tab): a window macOS shows again stays invisible
        reopenGuard = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                             object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if engaged { hideWindows() } }
        }
    }

    private static func hideAfterFullScreen() {
        if let exitWatch { NotificationCenter.default.removeObserver(exitWatch) }
        exitWatch = nil
        if engaged, !NSApp.isHidden { NSApp.hide(nil) }
    }

    /// Every key while engaged goes here and nowhere else.
    static func typed(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let x = plain && !event.isARepeat && event.charactersIgnoringModifiers?.lowercased() == "x"
        if counter.typed(x: x, at: Date()) { release() }
    }

    private static func release() {
        engaged = false
        if let reopenGuard { NotificationCenter.default.removeObserver(reopenGuard) }
        reopenGuard = nil
        for window in NSApp.windows {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        if let exitWatch { NotificationCenter.default.removeObserver(exitWatch) }
        exitWatch = nil
        NotificationCenter.default.post(name: changed, object: nil)
        // X X X typed while hidden (the keys still arrive): shown again
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for window in fullScreenWindows { _ = FullScreenSwitch.shared.set(true, window: window) }
        fullScreenWindows = []
    }

    private static func hideWindows() {
        for window in NSApp.windows {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }

    /// Three X in a row, each within a second of the one before; any other
    /// key starts over.
    struct Counter {
        private var count = 0
        private var last: Date?

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
