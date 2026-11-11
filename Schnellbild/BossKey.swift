import AppKit

/// The boss key: X hides every window of the app and mutes it at once;
/// only X typed three times brings it back (or quitting and starting again).
/// The windows stay open, invisible and letting clicks through, so the Dock
/// icon or ⌘-Tab bring the app forward with nothing to see, and its keys
/// still arrive here.
@MainActor
enum BossKey {
    private(set) static var engaged = false
    private static var counter = Counter()
    private static var reopenGuard: NSObjectProtocol?

    /// Posted when the app goes quiet or comes back: players set their volume.
    static let changed = Notification.Name("BossKeyChanged")

    static func engage() {
        guard !engaged else { return }
        engaged = true
        counter = Counter()
        NotificationCenter.default.post(name: changed, object: nil)
        hideWindows()
        NSApp.hide(nil)
        // Brought forward (Dock, ⌘-Tab): a window macOS shows again stays invisible
        reopenGuard = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                             object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if engaged { hideWindows() } }
        }
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
        NotificationCenter.default.post(name: changed, object: nil)
        NSApp.activate(ignoringOtherApps: true)
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
