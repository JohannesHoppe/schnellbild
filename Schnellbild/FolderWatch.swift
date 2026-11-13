import AppKit
import CoreServices

/// Watches a folder and everything below it for changes on disk (FSEvents):
/// on local disks every change; on a network share only those this Mac
/// makes (the server doesn't report the others: the panes read their
/// folders again when the app becomes active, `DiskEvents`). Changes the
/// app makes itself aren't reported (they reach the panes as `FileChange`s).
/// Changes within `latency` come as one call on the main thread: the
/// folders whose contents changed (canonical paths, each once), or nil when
/// too many to name (a big copy: read it all again), and whether the
/// watched folder itself was moved or deleted.
final class FolderWatch {
    let path: String
    typealias Handler = @MainActor (_ changed: [String]?, _ rootChanged: Bool) -> Void

    /// What the stream calls: kept alive by the stream itself (its context's
    /// retain / release), so a call already queued finds it after the watch went.
    private final class Relay: @unchecked Sendable {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private static let queue = DispatchQueue(label: "Schnellbild folder watch", qos: .utility)
    /// More folders than this in one call: too many to name.
    static let namedLimit = 500

    init?(path: String, latency: TimeInterval = 0.5, _ handler: @escaping Handler) {
        self.path = path
        let relay = Relay(handler)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Relay>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
            let all = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var rootChanged = false
            var changed = Set<String>()
            var overflow = false
            for i in 0..<min(count, all.count) {
                let flag = Int(flags[i])
                if flag & kFSEventStreamEventFlagRootChanged != 0 { rootChanged = true; continue }
                // Events dropped or merged by the system: what changed below isn't known
                if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    overflow = true
                }
                if !overflow { changed.insert(BrowserModel.canonicalPath(URL(fileURLWithPath: all[i], isDirectory: true))) }
                if changed.count > FolderWatch.namedLimit { overflow = true }
            }
            let named: [String]? = overflow ? nil : Array(changed)
            guard rootChanged || overflow || !changed.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.handler(named, rootChanged) } }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
                                             | kFSEventStreamCreateFlagIgnoreSelf)
        guard let made = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = made
        FSEventStreamSetDispatchQueue(made, Self.queue)
        guard FSEventStreamStart(made) else {
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
            stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// The app's own events about the disks: a volume unmounted (a pane on it
/// goes to the drives' level), one mounted (the drives' level lists it), the
/// app or a window becoming active (each pane shown reads its folder again
/// if the folder's date changed: changes FSEvents doesn't report, as on a
/// network share).
@MainActor
enum DiskEvents {
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { for pane in WindowModel.openPanes { pane.volumesChanged(unmounted: volume) } }
        })
        // The folder grants waiting for their volume first, then the panes
        // (one reading the new volume needs its grant)
        observers.append(workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                FolderAccess.shared.volumeMounted()
                for pane in WindowModel.openPanes { pane.volumesChanged(unmounted: nil) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { for pane in WindowModel.openPanes { pane.relist() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                // (on app activation the line above reads them already)
                guard NSApp.isActive, let model = WindowModel.of(window) else { return }
                for pane in model.panes { pane.relist() }
            }
        })
    }
}
