import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VLCFrames

/// A grid entry: ".." (parent level), subfolder, image, or video.
struct GridEntry: Identifiable, Hashable {
    enum Kind { case parent, folder, image, video }
    let url: URL
    let kind: Kind
    var modDate: Date? = nil
    var byteSize: Int? = nil
    /// Worked out once (`GridEntry.isArchive(_:kind:)`): the grid asks on
    /// every redraw, the counts for every entry of every search batch.
    let isArchive: Bool

    init(url: URL, kind: Kind, modDate: Date? = nil, byteSize: Int? = nil) {
        self.url = url
        self.kind = kind
        self.modDate = modDate
        self.byteSize = byteSize
        isArchive = Self.isArchive(url, kind: kind)
    }

    var id: URL { url }
    var name: String { kind == .parent ? ".." : url.lastPathComponent }
    var isMedia: Bool { kind == .image || kind == .video }
}

/// A file in a folder that the grid doesn't show (not a picture, video or
/// archive): listed by name under the grid, so a folder with only such
/// files doesn't look empty.
struct OtherFile: Identifiable, Hashable {
    let url: URL
    var byteSize: Int? = nil
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// A folder's contents: what the grid shows, and the other files.
struct FolderListing {
    var entries: [GridEntry] = []
    var others: [OtherFile] = []
}

/// Transport control of the video currently on screen. Implemented for AVKit
/// and for VLCKit, so the keyboard drives both players the same way.
@MainActor
protocol PlaybackControl: AnyObject {
    /// The player's real state, so the keyboard stays in step with the
    /// player's own on-screen controls and with the end of the video.
    var isPlaying: Bool { get }
    /// Position in the video, 0 (start) … 1 (end); nil while the length
    /// isn't known yet.
    var progress: Double? { get }
    func play()
    func pause()
    /// Jump to a position (0 … 1). From the end, playing resumes.
    func seek(toProgress progress: Double)
    /// The look as a filter on the picture (see `Look`); with `.auto` the
    /// player measures the video and reports its look through
    /// `BrowserModel.autoLookMeasured`.
    func setEnhancement(_ enhancement: Enhancement)
    /// Plays although its length isn't known (a WebM recorded in a
    /// browser): the slideshow waits for its end instead of skipping it.
    var playsWithoutLength: Bool { get }
    /// The picture's size in pixels as shown, once known (the Inspector).
    var videoSize: CGSize? { get }
    /// Sound, 0 … 1 (the app's one volume for all videos).
    func setVolume(_ volume: Double)
    /// The video's length in seconds, once known (the time left).
    var lengthSeconds: Double? { get }
    /// The codecs, once the player has opened the video (the Inspector).
    func streamFacts() async -> StreamFacts?
}

extension PlaybackControl {
    var playsWithoutLength: Bool { false }
    var videoSize: CGSize? { nil }
    var lengthSeconds: Double? { nil }
    func streamFacts() async -> StreamFacts? { nil }
}

/// Side effects on the file system and the workspace. Injectable, so tests
/// can observe them without touching Finder, the Trash, or modal alerts.
struct FileActions {
    var reveal: @MainActor (URL) -> Void
    var openInDefaultApp: @MainActor (URL) -> Void
    /// An other file (not a picture, video or archive): only documents
    /// that hold no program, web locations only to web addresses.
    var openOtherFile: @MainActor (URL) -> Void = { if !LiveFiles.openOtherFile($0) { NSSound.beep() } }
    /// `detail` says what goes with it (a folder's contents, an archive's parts).
    var confirmTrash: @MainActor (_ name: String, _ detail: String) -> Bool
    /// Returns where the item now lies in the Trash (for Undo), if known.
    var trash: @MainActor (URL) throws -> URL?
    var move: @MainActor (_ from: URL, _ to: URL) throws -> Void
    /// Into another folder: moved on the same volume, copied to another
    /// (as the Finder does). Returns whether it was moved.
    var transfer: @MainActor (_ from: URL, _ to: URL) throws -> Bool
    var createFolder: @MainActor (URL) throws -> Void
    var copy: @MainActor (_ from: URL, _ to: URL) throws -> Void
    /// A name already taken in the target folder: true to keep both (the
    /// new one gets a number), false to skip it.
    var askKeepBoth: @MainActor (_ name: String, _ folder: String) -> Bool
    /// Whether `target` exists as an item other than `source`. On a
    /// case-insensitive volume "Photos" is the same item as "photos"; on a
    /// case-sensitive one (many NAS shares) it may be a different folder.
    var conflicts: @MainActor (_ target: URL, _ source: URL) -> Bool
    /// Tells why an action failed (a share without a Trash, no permission),
    /// in the system's words and language.
    var report: @MainActor (Error) -> Void
    /// Where moves and copies into folders run: the live actions off the
    /// main thread (a copy to a share takes long) through `LiveFiles`, which
    /// is what their closures call too; others (a test's spy) through their
    /// own closures.
    var runsOffMain = false

    /// Carries out the steps of a move; per step whether it was moved
    /// (false: copied) or why it failed.
    @MainActor
    func run(_ steps: [BrowserModel.TransferStep], _ how: BrowserModel.Transfer) async -> [Result<Bool, Error>] {
        if runsOffMain {
            return await Blocking.run {
                steps.map { step in Result { try Self.perform(step, how, move: LiveFiles.move, transfer: LiveFiles.transfer, copy: LiveFiles.copy) } }
            }
        }
        return steps.map { step in Result { try Self.perform(step, how, move: move, transfer: transfer, copy: copy) } }
    }

    private static func perform(_ step: BrowserModel.TransferStep, _ how: BrowserModel.Transfer,
                                move: (URL, URL) throws -> Void, transfer: (URL, URL) throws -> Bool,
                                copy: (URL, URL) throws -> Void) throws -> Bool {
        var moved = false
        for (file, to) in step.files {
            switch how {
            case .asFinder: moved = try transfer(file, to)
            case .copy:     try copy(file, to); moved = false
            case .move:     try move(file, to); moved = true
            }
        }
        return moved
    }

    static let live = FileActions(
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        openInDefaultApp: { LiveFiles.openWithDefaultApp($0) },
        confirmTrash: { name, detail in
            let alert = NSAlert()
            alert.messageText = String(localized: "Move “\(name)” to the Trash?")
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Move to Trash"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        },
        trash: { try LiveFiles.trash($0) },
        move: { try LiveFiles.move($0, $1) },
        transfer: { try LiveFiles.transfer($0, $1) },
        createFolder: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
        copy: { try LiveFiles.copy($0, $1) },
        askKeepBoth: { name, folder in
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(name)” already exists in “\(folder)”.")
            alert.informativeText = String(localized: "Keep both: the new one gets a number. Skip: it stays where it is.")
            alert.addButton(withTitle: String(localized: "Keep Both"))
            alert.addButton(withTitle: String(localized: "Skip"))
            return alert.runModal() == .alertFirstButtonReturn
        },
        conflicts: { LiveFiles.conflicts($0, $1) },
        report: { NSAlert(error: $0).runModal() },
        runsOffMain: true
    )
}

/// The file system work of the live actions, on any thread.
enum LiveFiles {
    /// Opens a picture, video, archive or folder with the app the Mac uses
    /// for it. A file someone else made can pretend: a link or alias named
    /// "Holiday.jpg" may point to an app or a script, which LaunchServices
    /// would launch. So what is opened is what the item really is: links
    /// and aliases resolved, and only pictures, videos, PDFs, archives and
    /// folders (not apps or packages), each with the app for its type.
    @MainActor
    static func openWithDefaultApp(_ url: URL) {
        guard let target = openableTarget(url) else { NSSound.beep(); return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: target) else { NSSound.beep(); return }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The item behind links and aliases, if it may be opened at all.
    static func openableTarget(_ url: URL) -> URL? {
        var target = url.resolvingSymlinksInPath()
        if (try? target.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]))?.isAliasFile == true {
            guard let resolved = try? URL(resolvingAliasFileAt: target) else { return nil }
            target = resolved.resolvingSymlinksInPath()
        }
        guard let values = try? target.resourceValues(forKeys: [.contentTypeKey, .isPackageKey, .isDirectoryKey, .isAliasFileKey]),
              values.isPackage != true, values.isAliasFile != true || values.isDirectory == true,
              let type = values.contentType else { return nil }
        if values.isDirectory == true { return type.conforms(to: .folder) ? target : nil }
        let allowed: [UTType] = [.image, .movie, .audiovisualContent, .pdf, .archive]
        return allowed.contains(where: type.conforms(to:)) && !type.conforms(to: .executable) ? target : nil
    }

    /// One of the other files (not a picture, video or archive), with the
    /// app the Mac uses for it. Only kinds that hold no program: text,
    /// documents, PDFs, sound, spreadsheets and the like; never apps,
    /// packages, scripts, installers, disk images or anything executable.
    /// A web location (.webloc, .url) opens its address in the browser,
    /// and only when it is a web address (http, https): a "link" to a
    /// file or another app's scheme is refused.
    @MainActor
    static func openOtherFile(_ url: URL) -> Bool {
        if let web = webAddress(in: url) {
            NSWorkspace.shared.open(web)
            return true
        }
        guard let target = openableDocument(url),
              let app = NSWorkspace.shared.urlForApplication(toOpen: target) else { return false }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Whether `openOtherFile` would open it (the context menu's "Open").
    static func canOpenOtherFile(_ url: URL) -> Bool {
        isWebLocation(url) ? webAddress(in: url) != nil : openableDocument(url) != nil
    }

    private static let refusedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh", "py", "pl", "rb", "php",
        "scpt", "scptd", "applescript", "workflow", "action", "shortcut", "pkg", "mpkg", "dmg", "iso",
        "jar", "class", "fileloc", "inetloc", "afploc", "ftploc", "mailloc", "newsloc", "configprofile",
        "mobileconfig", "prefpane", "kext", "plugin", "osax", "bundle", "framework", "dylib", "so",
        "exe", "msi", "bat", "cmd", "com", "ps1", "vbs", "js", "jse", "wsf", "lnk", "url", "webloc"]

    private static func isWebLocation(_ url: URL) -> Bool {
        ["webloc", "url"].contains(url.pathExtension.lowercased())
    }

    /// The http(s) address a .webloc (a property list) or .url (Windows'
    /// INI form) holds; nil for anything else.
    static func webAddress(in url: URL) -> URL? {
        guard isWebLocation(url),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) < 64 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        var address: String?
        if url.pathExtension.lowercased() == "webloc" {
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            address = plist?["URL"] as? String
        } else if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            address = text.split(whereSeparator: \.isNewline)
                .first { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("url=") }
                .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(4)) }
        }
        guard let address, let web = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = web.scheme?.lowercased(), scheme == "http" || scheme == "https", web.host != nil else { return nil }
        return web
    }

    /// The file behind links and aliases when it is a document that holds
    /// no program; nil otherwise.
    static func openableDocument(_ url: URL) -> URL? {
        var target = url.resolvingSymlinksInPath()
        if (try? target.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true {
            guard let resolved = try? URL(resolvingAliasFileAt: target) else { return nil }
            target = resolved.resolvingSymlinksInPath()
        }
        guard let values = try? target.resourceValues(forKeys: [.contentTypeKey, .isPackageKey, .isDirectoryKey, .isRegularFileKey]),
              values.isRegularFile == true, values.isPackage != true, values.isDirectory != true,
              let type = values.contentType else { return nil }
        let refused: [UTType] = [.executable, .application, .applicationBundle, .script, .shellScript,
                                 .package, .bundle, .diskImage, .systemPreferencesPane,
                                 UTType("com.apple.installer-package-archive"), UTType("com.apple.terminal.shell-script"),
                                 UTType("com.apple.automator-workflow"), UTType("com.apple.applescript.script"),
                                 UTType("com.apple.applescript.text"), UTType("com.apple.configprofile"),
                                 UTType("com.apple.internet-location"), UTType("com.apple.web-internet-location")].compactMap { $0 }
        if refused.contains(where: type.conforms(to:)) { return nil }
        // By name too: kinds that run or open something when opened, also
        // where the Mac files them under a harmless type (Terminal settings
        // are XML and can hold a command)
        if refusedExtensions.contains(target.pathExtension.lowercased())
            || refusedExtensions.contains(url.pathExtension.lowercased()) { return nil }
        let allowed: [UTType] = [.text, .pdf, .image, .audiovisualContent, .audio, .compositeContent,
                                 .spreadsheet, .presentation, .rtf, .rtfd, .font, .vCard]
        return allowed.contains(where: type.conforms(to:)) ? target : nil
    }

    static func move(_ from: URL, _ to: URL) throws {
        let fm = FileManager.default
        // FileManager refuses a case-only rename ("photos" → "Photos") on
        // case-insensitive volumes, because the target "exists"; go via a
        // temporary name.
        if from.path != to.path, from.path.lowercased() == to.path.lowercased() {
            let temp = from.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: from, to: temp)
            do {
                try fm.moveItem(at: temp, to: to)
            } catch {
                try? fm.moveItem(at: temp, to: from)   // never leave the folder under the hidden name
                throw error
            }
        } else {
            try fm.moveItem(at: from, to: to)
        }
    }

    /// Moved on the same volume, copied to another (as the Finder does).
    static func transfer(_ from: URL, _ to: URL) throws -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        let a = try? from.resourceValues(forKeys: key).volumeIdentifier
        let b = try? to.deletingLastPathComponent().resourceValues(forKeys: key).volumeIdentifier
        if let a, let b, a.isEqual(b) {
            try FileManager.default.moveItem(at: from, to: to)
            return true
        }
        try FileManager.default.copyItem(at: from, to: to)
        return false
    }

    static func copy(_ from: URL, _ to: URL) throws {
        try FileManager.default.copyItem(at: from, to: to)
    }

    /// Whether `target` exists as an item other than `source`.
    static func conflicts(_ target: URL, _ source: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let a = try? target.resourceValues(forKeys: key).fileResourceIdentifier,
              let b = try? source.resourceValues(forKeys: key).fileResourceIdentifier else { return true }
        return !a.isEqual(b)
    }

    /// Where the item now lies in the Trash, if the volume says.
    @discardableResult
    static func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

/// Why a folder rename was rejected.
enum RenameError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case alreadyExists(String)
    /// The new name's extension isn't one of the item's kind (picture / video).
    case changesKind(String, video: Bool)
    /// An archive's new name isn't one of its format (".zip" …).
    case changesArchiveFormat(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:            return String(localized: "Please enter a name.")
        case .invalidName:          return String(localized: "Names can't contain “/” or “:”, and can't be “.” or “..”.")
        case .alreadyExists(let n): return String(localized: "A folder or file named “\(n)” already exists in this folder.")
        case .changesKind(let ext, false): return String(localized: "The name must end in a picture extension, such as “.\(ext)”.")
        case .changesKind(let ext, true): return String(localized: "The name must end in a video extension, such as “.\(ext)”.")
        case .changesArchiveFormat(let ext): return String(localized: "The name must end in “.\(ext)”, as the archive does.")
        case .failed(let reason):   return reason
        }
    }
}

/// A block observer of the default `NotificationCenter` on the main queue,
/// removed when this goes.
final class NotificationToken {
    private let token: NSObjectProtocol
    init(_ name: Notification.Name, object: AnyObject? = nil, _ block: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main, using: block)
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// A change the app made on disk (rename, trash). One value is applied to
/// every list the model holds — the folder, the search results, results
/// still streaming in, the history — so they all agree.
struct FileChange {
    private enum Kind { case moved(to: String), removed }
    private let path: String
    private let kind: Kind

    /// The changed item (canonical path).
    var source: String { path }
    /// Where it went (canonical path); nil when it was removed.
    var destination: String? {
        if case .moved(let to) = kind { return to }
        return nil
    }

    static func moved(_ old: URL, to new: URL) -> FileChange {
        FileChange(path: BrowserModel.canonicalPath(old), kind: .moved(to: BrowserModel.canonicalPath(new)))
    }
    static func removed(_ url: URL) -> FileChange {
        FileChange(path: BrowserModel.canonicalPath(url), kind: .removed)
    }

    /// The changed item and every folder above it, as canonical paths: their
    /// contents (and so their previews and emptiness) changed.
    var affectedFolders: [String] {
        var result: [String] = []
        var paths = [path]
        if case .moved(let to) = kind { paths.append(to) }
        for start in paths {
            var current = start
            while !current.isEmpty, current != "/" {
                result.append(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }
        return result
    }

    /// `url` after the change; nil if it was removed (or lay inside what was).
    func apply(to url: URL) -> URL? {
        let current = BrowserModel.canonicalPath(url)
        guard let changed = apply(toPath: current) else { return nil }
        // (built without asking the file system whether it is a folder)
        return changed == current ? url : URL(fileURLWithPath: changed, isDirectory: url.hasDirectoryPath)
    }

    /// A canonical path after the change; nil if it was removed.
    func apply(toPath current: String) -> String? {
        guard BrowserModel.isSameOrInside(current, path) else { return current }
        switch kind {
        case .removed:         return nil
        case .moved(let to):   return to + current.dropFirst(path.count)
        }
    }

    func apply(to entry: GridEntry) -> GridEntry? {
        guard entry.kind != .parent else { return entry }
        guard let url = apply(to: entry.url) else { return nil }
        guard url != entry.url else { return entry }
        return GridEntry(url: url, kind: entry.kind, modDate: entry.modDate, byteSize: entry.byteSize)
    }

    /// A removed folder stays in the history (it then shows as empty).
    func apply(to location: BrowserModel.Location) -> BrowserModel.Location {
        var result = location
        result.folder = apply(to: location.folder) ?? location.folder
        result.selected = location.selected.flatMap { apply(to: $0) }
        return result
    }
}

/// Changes looked up by path: a batch (a marked set trashed or moved) is
/// applied to thousands of entries, each found through its own folders
/// instead of through every change. Changes that build on each other (one
/// moves what another moved or into it) are applied in order instead.
struct FileChanges {
    let all: [FileChange]
    private let bySource: [String: FileChange]?

    init(_ changes: [FileChange]) {
        all = changes
        var sources: [String: FileChange] = [:]
        for change in changes where sources[change.source] == nil { sources[change.source] = change }
        let independent = sources.count == changes.count && changes.allSatisfy { change in
            // No source inside another, nothing moved into or under a source
            Self.ancestors(of: change.source).dropFirst().allSatisfy { sources[$0] == nil }
                && (change.destination.map { Self.ancestors(of: $0).allSatisfy { sources[$0] == nil } } ?? true)
        }
        bySource = independent ? sources : nil
    }

    /// The path and every folder above it, deepest first.
    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = path
        while true {
            result.append(current)
            guard current != "/", !current.isEmpty else { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }

    /// A canonical path after the changes; nil when it is gone.
    func path(_ start: String) -> String? {
        if let bySource {
            var current = start
            while true {
                if let change = bySource[current] { return change.apply(toPath: start) }
                guard current != "/", !current.isEmpty else { return start }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        var path = start
        for change in all {
            guard let next = change.apply(toPath: path) else { return nil }
            path = next
        }
        return path
    }

    /// Where a URL ends up after the changes; nil when it is gone. The path
    /// is made canonical once.
    func url(_ url: URL) -> URL? {
        let start = BrowserModel.canonicalPath(url)
        guard let path = path(start) else { return nil }
        return path == start ? url : URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
    }
}

/// How many changes a search has recorded, readable from its walk: each
/// batch carries the count from when it began, so only later changes are
/// replayed on it.
final class ChangeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var now: Int { lock.lock(); defer { lock.unlock() }; return count }
    func set(_ value: Int) { lock.lock(); count = value; lock.unlock() }
}

/// Matches found by a search's walk, read after `stamp` changes were recorded.
struct SearchBatch: Sendable {
    var stamp: Int
    var entries: [GridEntry]
    /// What the walk learnt about the folders it found, for their tiles
    /// (they needn't walk the same folders again over the network).
    var facts = FolderFacts.Learnt()
}

/// Tells a walk on its own thread to stop (the search went away).
final class WalkStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}

/// What a search's walk learns about the folders it finds: whether they
/// hold media and their first pictures, as a folder tile would look them up
/// (`BrowserModel.folderPreviewFiles`): the first three met at the top,
/// else the first ones further down.
struct FolderFacts {
    struct Learnt: Sendable {
        /// Known to hold media (as soon as one is met).
        var withMedia: [URL] = []
        /// At the end of a whole walk: each found folder's previews…
        var previews: [URL: [URL]] = [:]
        /// …and the found folders with no media at any depth.
        var withoutMedia: [URL] = []
        var isEmpty: Bool { withMedia.isEmpty && previews.isEmpty && withoutMedia.isEmpty }
    }

    private struct Folder {
        let url: URL
        var top: [URL] = []
        var below: [URL] = []
        var hasMedia: Bool { !top.isEmpty || !below.isEmpty }
    }
    private var folders: [String: Folder] = [:]
    private(set) var learnt = Learnt()

    /// A folder found by the search (not an archive).
    mutating func found(folder url: URL) {
        folders[url.standardizedFileURL.path] = Folder(url: url)
    }

    /// A picture or video met anywhere in the walk.
    mutating func met(media url: URL) {
        guard !folders.isEmpty else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        var path = parent
        while true {
            if var folder = folders[path] {
                let had = folder.hasMedia
                if path == parent {
                    if folder.top.count < 3 { folder.top.append(url) }
                } else if folder.below.count < 3 {
                    folder.below.append(url)
                }
                folders[path] = folder
                if !had { learnt.withMedia.append(folder.url) }
            }
            guard path != "/", !path.isEmpty else { break }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// Hands on what was learnt since the last call.
    mutating func take() -> Learnt {
        defer { learnt = Learnt() }
        return learnt
    }

    /// The walk went through everything: the previews and the empty folders are known.
    mutating func finish() -> Learnt {
        var result = take()
        for folder in folders.values {
            if folder.hasMedia {
                result.previews[folder.url] = folder.top.isEmpty ? folder.below : folder.top
            } else {
                result.withoutMedia.append(folder.url)
            }
        }
        return result
    }
}

/// One search: what it has found so far and the tree walk adding to it.
/// The history keeps it, so going back shows the same results, and a walk
/// still running goes on in the background.
@MainActor
/// How a search matches names: a part of the name ignoring case (by the
/// same rules in every language: Turkish rules would keep "img" from
/// "IMG_0001.JPG"), a part with the case as typed, or a regular expression
/// (ICU syntax, found anywhere in the name; `(?i)` ignores case).
struct NameMatcher: Equatable, @unchecked Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case ignoringCase, matchingCase, regex
    }
    let query: String
    let mode: Mode
    /// (NSRegularExpression is immutable and safe to share across threads)
    private let expression: NSRegularExpression?

    nonisolated init(_ query: String, mode: Mode = .ignoringCase) {
        self.query = query
        self.mode = mode
        expression = mode == .regex ? try? NSRegularExpression(pattern: query) : nil
    }

    /// A regular expression that compiles (the other modes always are).
    nonisolated var isValid: Bool { mode != .regex || expression != nil }

    /// How long an expression may try one name: one that backtracks without
    /// end ("(a|a)*b") counts as no match after this, and so does every
    /// name once `stop` says the search is over.
    nonisolated static let regexTimeLimit: TimeInterval = 0.05

    nonisolated func matches(_ name: String, stop: WalkStop? = nil) -> Bool {
        switch mode {
        case .ignoringCase: return name.range(of: query, options: .caseInsensitive, locale: nil) != nil
        case .matchingCase: return name.range(of: query, options: .literal) != nil
        case .regex:
            guard let expression, stop?.isSet != true else { return false }
            // ICU calls back now and then during a long match (`reportProgress`)
            var found = false
            let deadline = Date(timeIntervalSinceNow: Self.regexTimeLimit)
            expression.enumerateMatches(in: name, options: .reportProgress, range: NSRange(name.startIndex..., in: name)) { match, _, halt in
                if match != nil { found = true; halt.pointee = true }
                else if stop?.isSet == true || Date() > deadline { halt.pointee = true }
            }
            return found
        }
    }

    /// Whether matching may take a while (a regular expression): then the
    /// folder's own items are matched off the main thread too.
    nonisolated var isCostly: Bool { mode == .regex }

    nonisolated static func == (a: NameMatcher, b: NameMatcher) -> Bool { a.query == b.query && a.mode == b.mode }
}

final class SearchRun {
    let matcher: NameMatcher
    var query: String { matcher.query }
    /// The searched folder (canonical): what moves out of it is no result.
    let root: String?
    let clock = ChangeClock()
    private(set) var results: [GridEntry]
    /// Canonical paths in `results`, so nothing shows up twice.
    private var seen: Set<String>
    /// Changes made while the walk runs, in order. The walk may still report
    /// paths it read before such a change; they are replayed on arrival.
    private var changes: [FileChange] = []
    var task: Task<Void, Never>?
    /// The walk is done (or was stopped).
    var finished = false
    /// Stopped to save work (too many running in the history) before the
    /// walk was through: coming back searches again. A search the user
    /// stopped keeps what it found.
    private(set) var stoppedEarly = false
    /// The user stopped the walk (the stop button): "no matches" means none so far.
    private(set) var stoppedByUser = false

    init(matcher: NameMatcher, root: URL?, results: [GridEntry]) {
        self.matcher = matcher
        self.root = root.map(BrowserModel.canonicalPath)
        self.results = results
        seen = Set(results.map { BrowserModel.canonicalPath($0.url) })
    }

    /// Adds a batch from the walk; what was new. Only the changes recorded
    /// after the batch began are replayed on it (a path reused since is the
    /// new item's).
    func add(_ batch: SearchBatch) -> [GridEntry] {
        let later = changes.dropFirst(min(batch.stamp, changes.count))
        var fresh: [GridEntry] = []
        for found in batch.entries {
            guard let entry = later.reduce(Optional(found), { entry, change in
                entry.flatMap { change.apply(to: $0) }
            }), stays(entry.url) else { continue }
            if seen.insert(BrowserModel.canonicalPath(entry.url)).inserted { fresh.append(entry) }
        }
        results += fresh
        return fresh
    }

    private func stays(_ url: URL) -> Bool {
        guard let root else { return true }
        return BrowserModel.isSameOrInside(BrowserModel.canonicalPath(url), root)
    }

    func apply(_ change: FileChange) { apply([change]) }

    /// Several changes in one pass over the results.
    func apply(_ batch: [FileChange]) {
        let lookup = FileChanges(batch)
        results = results.compactMap { entry in
            guard let url = lookup.url(entry.url) else { return nil }
            if url == entry.url { return entry }
            // Moved out of the searched folder: no longer a result here
            guard stays(url) else { return nil }
            return GridEntry(url: url, kind: entry.kind, modDate: entry.modDate, byteSize: entry.byteSize)
        }
        seen = Set(results.map { BrowserModel.canonicalPath($0.url) })
        if !finished {
            changes.append(contentsOf: batch)
            clock.set(changes.count)
        }
    }

    func stop(incomplete: Bool) {
        task?.cancel()
        if !finished { if incomplete { stoppedEarly = true } else { stoppedByUser = true } }
        finished = true
    }
}

/// Single source of truth for all browsing.
@MainActor
final class BrowserModel: ObservableObject {
    enum Mode { case grid, detail }
    enum SortKey: String, CaseIterable {
        case name, kind, modified, captured, size

        var title: String {
            switch self {
            case .name:     return String(localized: "Name")
            case .kind:     return String(localized: "Kind")
            case .modified: return String(localized: "Date Modified")
            case .captured: return String(localized: "Date Taken")
            case .size:     return String(localized: "Size")
            }
        }
        /// Like Finder: names A→Z, but dates and sizes newest/largest first.
        var startsAscending: Bool { self == .name || self == .kind }
    }
    enum KeyInput: Equatable {
        case left, right, up, down, space, enter, escape, backspace, home, end, f1, f2
        /// The Norton Commander keys, a second way next to the Mac ones:
        /// F3 view, F4 edit (the default app), F5 copy and F6 move to the
        /// other pane (the window's), F6 alone / ⇧F6 rename, F7 new folder,
        /// F8 trash, F9 the menus, F10 quit; Insert marks, Tab switches panes.
        /// (Norton's F2, its user menu, stays rename here: the Mac-style key
        /// comes first.)
        case insert, tab, f3, f4, f5, f6, f7, f8, f9, f10
        case char(Character)
    }

    /// A place in the navigation history: a folder, the search shown in it,
    /// and the selected item. Going back to a search shows its results
    /// again (with any renames applied) instead of searching anew, so the
    /// list stays stable; a search that was still running when the user
    /// left keeps running and shows what it has found by then.
    struct Location {
        var folder: URL
        var query: String = ""
        var selected: URL? = nil
        var search: SearchRun? = nil
    }

    @Published private(set) var folderURL: URL? {
        didSet { folderPath = folderURL.map(Self.canonicalPath); updateWatch() }
    }
    /// `canonicalPath(folderURL)`, kept so grid cells don't recompute it.
    private var folderPath: String?
    @Published private(set) var entries: [GridEntry] = [] {
        didSet { listRevision += 1; recomputeDerived(); readCaptureDatesIfNeeded() }
    }
    @Published var selection: Int? {
        didSet { if !keepingChoice { selectionChosen = !settingDefaultSelection } }
    }
    /// The selection follows its item (a re-sort, a change on disk): whether
    /// the user chose it stays as it was.
    private var keepingChoice = false
    private func keepSelection(_ index: Int?) {
        keepingChoice = true
        selection = index
        keepingChoice = false
    }
    /// The selection is the user's (or restored from the history), not the
    /// first tile picked on opening a folder: a slideshow starts there.
    private(set) var selectionChosen = false
    private var settingDefaultSelection = false

    private func selectDefault(in list: [GridEntry]) {
        settingDefaultSelection = true
        selection = Self.defaultSelection(in: list)
        settingDefaultSelection = false
    }
    @Published var mode: Mode = .grid {
        didSet { if mode == .grid { refreshIfDeferred() } }
    }
    @Published var showInspector = false
    @Published var showHelp = false
    @Published private(set) var isLoading = false {
        didSet { if !isLoading { refreshIfDeferred() } }
    }
    /// Counts the changes the app made on disk; folder tiles read their
    /// previews again on each.
    @Published private(set) var folderChanges = 0
    /// Why the current folder or archive couldn't be listed (shown instead
    /// of "This folder is empty").
    struct LoadError: Equatable {
        let archive: Bool
        let reason: String
        /// In the App Sandbox: a folder the user hasn't opened to the app
        /// (`FolderAccess`), which `allowAccess` asks for.
        var needsAccess = false
    }
    @Published private(set) var loadError: LoadError?
    /// The current folder's files the grid doesn't show (not while searching).
    @Published private(set) var otherFiles: [OtherFile] = []
    /// The place `load` is reading, for the history while it loads.
    private var loadingLocation: Location?

    /// Set by the grid based on window width — for row-accurate ↑/↓.
    @Published var columnCount: Int = 1
    /// Tile size in the grid (⌘+/⌘-).
    @Published var thumbnailSide: CGFloat = 150

    /// Zoom of the image full-size view (1 = fit to window).
    @Published var zoom: CGFloat = 1
    /// Set by the full-size view: factor that corresponds to 100 % actual pixels.
    @Published var actualSizeFactor: CGFloat = 1
    /// View-only rotation in degrees (multiples of 90) — never written to disk.
    @Published var rotation: Double = 0
    private let maxZoom: CGFloat = 8

    @Published private(set) var sortKey: SortKey = .name { didSet { orderRevision += 1 } }
    @Published private(set) var sortAscending = true { didSet { orderRevision += 1 } }
    /// When each photo or video was taken (EXIF / QuickTime metadata), read
    /// only while sorting by `.captured`. Files without it sort by their
    /// modification date.
    private var captureDates: [URL: Date] = [:] { didSet { orderRevision += 1 } }
    /// Files whose capture date was already read (found or not).
    private var captureDatesRead: Set<URL> = []
    private var captureDateTask: Task<Void, Never>?

    // MARK: Search state

    /// The query. Every change re-runs the search over folder and file names
    /// in the current folder and all its subfolders.
    @Published var searchText: String = "" {
        didSet { if Self.trimmed(searchText) != Self.trimmed(oldValue) { applyFilter() } }
    }
    /// How names are matched (the switch beside the search field),
    /// remembered per pane: a change searches again.
    @Published var searchMode: NameMatcher.Mode = .ignoringCase {
        didSet {
            guard searchMode != oldValue else { return }
            defaults.set(searchMode.rawValue, forKey: settingsPrefix + "searchMode")
            if !query.isEmpty { applyFilter() }
        }
    }

    /// The query as searched: `searchText` without surrounding blanks.
    var query: String { Self.trimmed(searchText) }
    /// Whether a (non-blank) query filters the grid.
    var isFiltering: Bool { !query.isEmpty }
    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
    /// Whether the (always visible) search field has keyboard focus.
    @Published var searchFocused = false {
        didSet { if searchFocused { onActivate?() } }
    }
    /// Told when the user turns to this pane (a click, a menu on one of its
    /// tiles, its search field): the window makes it the active one.
    var onActivate: (() -> Void)?
    @Published private(set) var isSearching = false
    /// Delay before walking subfolders, so fast typing doesn't start a full
    /// tree walk per keystroke.
    var searchDebounce: Duration = .milliseconds(120)
    /// The full, unfiltered set of the current folder. `entries` is the
    /// currently visible (possibly search-filtered) view of it.
    private var allEntries: [GridEntry] = [] { didSet { listRevision += 1 } }
    /// The search shown; the history can hold more (`Location.search`).
    private var search: SearchRun?
    /// Unfinished searches kept running in the history; older ones stop.
    static let backgroundSearchLimit = 3
    /// A result to select as soon as the search produces it.
    private var pendingResultSelection: URL?
    /// Identifies the newest `load`, so an older scan that finishes late is ignored.
    private var loadGeneration = 0

    // MARK: History

    @Published private(set) var backStack: [Location] = []
    @Published private(set) var forwardStack: [Location] = []
    /// Each step can hold a full result list; older steps are dropped.
    static let historyLimit = 50
    /// From the full view, Back first returns to the grid it was opened from.
    var canGoBack: Bool { mode == .detail || !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { folderURL.flatMap(Self.parentFolder(of:)) != nil }

    /// The enclosing folder; nil at the file system root.
    /// Above "/" lies the level of all drives: `/Volumes`, where macOS
    /// lists every mounted disk and network share (the startup disk as a
    /// link to "/"). Nothing lies above that.
    nonisolated static func parentFolder(of url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        if path == "/" { return URL(fileURLWithPath: volumesPath, isDirectory: true) }
        guard path != volumesPath else { return nil }
        return url.standardizedFileURL.deletingLastPathComponent()
    }

    nonisolated static let volumesPath = "/Volumes"

    /// The level of all drives (`/Volumes`): no parent of its own.
    nonisolated static func isDrivesLevel(_ url: URL) -> Bool { url.standardizedFileURL.path == volumesPath }

    // MARK: Rename

    /// The folder or file whose rename sheet is open.
    @Published var renameTarget: GridEntry?
    /// The other file (not a picture, video or archive) whose rename sheet
    /// is open.
    @Published var renameFileTarget: OtherFile?

    // MARK: Archive passwords

    /// A protected archive none of the remembered passwords opens: the
    /// password sheet asks for one.
    struct PasswordRequest: Identifiable {
        let id = UUID()
        let archive: String
        let location: Location
        let thenDetail: Bool
        /// The password typed last time didn't open it.
        let wrong: Bool
    }
    @Published var passwordRequest: PasswordRequest?

    /// The password sheet's "Open": tried on the archive, and remembered
    /// (for every archive) once it opens it.
    func submitPassword(_ password: String) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        guard !password.isEmpty else { passwordRequest = request; return }
        load(request.location, thenDetail: request.thenDetail, password: password)
    }

    /// The password sheet's "Cancel": back to where the user came from.
    func cancelPassword() {
        passwordRequest = nil
        if canGoBack { navigateBack(); return }
        // Up, without the declined archive as a step back (it would ask again)
        // (out of the archive altogether: a folder inside it would ask too)
        guard let current = folderURL else { return }
        let archive = ArchivePath.split(current)?.archive
        guard let parent = Self.parentFolder(of: archive ?? current) else { return }
        load(Location(folder: parent, selected: archive ?? current))
    }

    // MARK: Slideshow / video

    /// A slideshow over every photo and video below a folder, folder by
    /// folder in the sort order (a folder's own media first, then each
    /// subfolder). It starts with the first pictures found while the walk
    /// goes on, and plays in full screen over the grid.
    struct Slideshow {
        var items: [GridEntry] = []
        var index = 0
        /// Still walking subfolders: more items may come.
        var loading = true
        /// Pictures wait (videos pause through their player).
        var paused = false
        /// Stepped past the last item while the walk still runs: the next
        /// batch moves the show on.
        var waitingForMore = false
        /// The item to start at (the one in the full view, or the file
        /// selected in the grid), until it has arrived or the user has moved on.
        var startAt: URL?
        /// The folder to start in (selected in the grid): the first item
        /// from inside it. Canonical path with a trailing "/".
        var startInside: String?
        /// Nothing shown yet: waiting for the item to start at.
        var waitingForStart: Bool { startAt != nil || startInside != nil }
        /// Every item once (search results can hold a folder and files in it).
        var seen: Set<String> = []
        /// The show's parts in order (a folder's own media, each subfolder;
        /// or each search result) and how many items each has brought so
        /// far: the part to start in is walked first, the others' items go
        /// in before or after it.
        var partCounts: [Int] = [1]
        /// Tells this slideshow's walk from an earlier, cancelled one.
        let id = UUID()
        var current: GridEntry? { items.indices.contains(index) ? items[index] : nil }
    }
    @Published private(set) var slideshow: Slideshow? {
        didSet { if slideshow == nil { refreshIfDeferred() } }
    }
    /// How long a picture stays; a video plays to its end. Set in Settings
    /// (`slideshowSecondsKey`, the same for both panes).
    var slideshowInterval: Duration = .seconds(3)
    static let slideshowSecondsKey = "slideshowSeconds"
    static let slideshowSecondsRange = 1...60
    /// How often the slideshow checks that a video plays at all; four checks
    /// without a length skip it (a file nothing can play).
    var slideshowVideoCheck: Duration = .seconds(2)
    private var slideshowTimer: Task<Void, Never>?
    private var slideshowWalk: Task<Void, Never>?
    /// Whether starting the slideshow put the window into full screen.
    private var slideshowEnteredFullScreen = false
    /// Puts the window into (true) or out of (false) full screen; returns
    /// whether that changed anything. Tests replace it.
    lazy var setFullScreen: @MainActor (Bool) -> Bool = { [weak self] on in
        FullScreenSwitch.shared.set(on, window: self?.hostWindow)
    }

    /// The window this pane is in (set by it, `WindowModel.watch`).
    weak var owner: WindowModel?
    /// The AppKit window showing this pane.
    var hostWindow: NSWindow? { owner?.nsWindow ?? Self.appWindow }

    /// The browser window keys and menus act on: the key window's (the key
    /// window can be the Adjustments popover's: then the main one).
    static var appWindow: NSWindow? { WindowModel.current?.nsWindow ?? NSApp.mainWindow ?? NSApp.keyWindow }

    /// The window showing this pane closed: nothing goes on playing in it,
    /// and it stops listening (a model kept for the next window).
    func leaveWindow() {
        if slideshow != nil { stopSlideshow() }
        if mode == .detail { closeDetail() }
        if isSearching { stopSearch() }
        bossKeyObserver = nil
        inWindow = false
        updateWatch()
    }

    /// The file `activePlayer` plays (the Inspector asks only that one).
    var activePlayerURL: URL?
    /// The player of the video on screen — for keyboard control
    /// (play/pause, skimming). Set by the video views.
    weak var activePlayer: PlaybackControl? {
        didSet {
            shownSince = Date()
            videoPaused = false
            if enhancement != .off { activePlayer?.setEnhancement(enhancement) }
            activePlayer?.setVolume(audibleVolume)
        }
    }

    static let volumeKey = "videoVolume"
    /// The volume of every video, 0 … 1 (↑ / ↓ on a video, in tenths);
    /// starts at 100 %, remembered.
    @Published private(set) var volume: Double = 1
    /// What the player plays at: silent while the boss key hides the app.
    var audibleVolume: Double { BossKey.engaged ? 0 : volume }
    private var bossKeyObserver: NotificationToken?

    /// Changes with every volume step: the volume display shows a while.
    @Published private(set) var volumeChange: UUID?

    /// ↑ / ↓ on what's shown: a video's volume; a zoomed-in picture moves
    /// to show more of its top / bottom; otherwise nothing (paging is ← →).
    private func verticalKey(up: Bool) -> Bool {
        if shownMediaEntry?.kind == .video { changeVolume(by: up ? 0.1 : -0.1); return true }
        guard zoom > 1.01 else { return false }
        panRequest = PanRequest(up: up)
        return true
    }

    /// A step of looking further up or down in a zoomed-in picture (the
    /// picture view moves by part of its height).
    struct PanRequest: Equatable {
        let up: Bool
        let id = UUID()
    }
    @Published private(set) var panRequest: PanRequest?

    /// The volume another pane set (one volume for the window).
    func adoptVolume(_ value: Double) {
        guard value != volume else { return }
        volume = value
        activePlayer?.setVolume(audibleVolume)
    }

    func changeVolume(by delta: Double) {
        volume = (min(max(volume + delta, 0), 1) * 10).rounded() / 10
        defaults.set(volume, forKey: Self.volumeKey)
        activePlayer?.setVolume(audibleVolume)
        volumeChange = UUID()
    }
    /// Auto enhance (E, the wand): works out exposure, contrast, saturation
    /// and sharpness for each photo and, now and then, for the video
    /// playing; the sliders (`look`) follow it. Stays on while paging until
    /// switched off, which shows the files as they are again.
    @Published var enhance = false {
        didSet {
            guard enhance != oldValue else { return }
            if !enhance && !adjustingByHand { manualLook = .neutral; look = .neutral }
            activePlayer?.setEnhancement(enhancement)
        }
    }
    /// The settings shown on the sliders: auto's for the item on screen
    /// while auto enhance is on, else the ones set by hand.
    @Published private(set) var look = Look.neutral
    /// Settings by hand; they stay while paging until reset.
    @Published private(set) var manualLook = Look.neutral
    private var adjustingByHand = false
    /// Whether the adjustment panel is open.
    @Published var showAdjustments = false

    /// What photos and videos show.
    var enhancement: Enhancement {
        enhance ? .auto : manualLook.isNeutral ? .off : .manual(manualLook)
    }

    /// A slider moved by hand: auto enhance goes off, and the look carries
    /// on from what was on screen.
    func adjust(_ new: Look) {
        adjustingByHand = true
        enhance = false
        adjustingByHand = false
        manualLook = new
        look = new
        activePlayer?.setEnhancement(enhancement)
    }

    /// Back to the files as they are.
    func resetLook() {
        enhance = false
        adjust(.neutral)
    }

    /// Auto enhance's look for the item on screen (a photo once, a video
    /// now and then), for the sliders. Ignored from a player no longer shown.
    func autoLookMeasured(_ measured: Look, from player: PlaybackControl? = nil) {
        guard enhance else { return }
        if let player, player !== activePlayer { return }
        // Only a change: every write publishes and redraws the grid behind
        guard look != measured else { return }
        look = measured
    }
    /// Whether the current video is paused (or has ended). Videos autoplay;
    /// the players report changes via `playbackStateChanged`.
    @Published private(set) var videoPaused = false

    // MARK: Dependencies

    let defaults: UserDefaults
    var fileActions: FileActions
    /// Renames, trashing and moves, to undo and redo (the window's panes share one).
    var undoHistory = FileHistory()

    static let lastFolderKey = "lastFolderPath"
    static let sortKeyKey = "sortKey"
    static let sortAscendingKey = "sortAscending"
    /// Prefixes this pane's own settings (last folder, sort): the right pane
    /// of the dual pane remembers its own.
    let settingsPrefix: String
    private var lastFolderKey: String { settingsPrefix + Self.lastFolderKey }
    private var sortKeyKey: String { settingsPrefix + Self.sortKeyKey }
    private var sortAscendingKey: String { settingsPrefix + Self.sortAscendingKey }

    nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "heic", "heif", "hif", "heics", "avif", "jxl",
        "tiff", "tif", "bmp", "webp", "psd", "pdf", "jp2", "j2k", "exr", "hdr", "tga",
        "ico", "icns", "mpo", "dds", "svg",
        // camera RAW formats ImageIO reads
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf", "dng", "raf", "orf",
        "rw2", "rwl", "raw", "pef", "srw", "3fr", "fff", "erf", "dcr", "mos", "mrw", "iiq"
    ]
    nonisolated static let videoExtensions: Set<String> = [
        "mp4", "mov", "qt", "m4v", "avi", "mkv", "webm", "m2ts", "mts",
        "mpg", "mpeg", "m2v", "vob", "3gp", "3g2", "dv", "wmv", "flv", "ogv"
        // (".ts" by its content: `TransportStreams`)
    ]

    /// The one rule for which files the app shows: image, video, or nil.
    /// "._" files are never pictures: macOS keeps a file's extra data in them
    /// on volumes that can't hold it (SMB shares, exFAT, FAT).
    nonisolated static func mediaKind(of url: URL) -> GridEntry.Kind? {
        guard !url.lastPathComponent.hasPrefix("._") else { return nil }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if ext == "ts", TransportStreams.shared.isVideo(url) { return .video }
        return nil
    }

    init(defaults: UserDefaults = .standard, fileActions: FileActions = .live, settingsPrefix: String = "") {
        self.settingsPrefix = settingsPrefix
        self.defaults = defaults
        self.fileActions = fileActions
        // UI tests (`--search-delay=<ms>`): a search that stays running long
        // enough to be watched and stopped
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), let arg = args.first(where: { $0.hasPrefix("--search-delay=") }),
           let ms = Int(arg.dropFirst("--search-delay=".count)) {
            searchDebounce = .milliseconds(ms)
        }
        showMiniKeyboard = defaults.bool(forKey: Self.miniKeyboardKey)
        if let seconds = defaults.object(forKey: Self.slideshowSecondsKey) as? Int,
           Self.slideshowSecondsRange.contains(seconds) { slideshowInterval = .seconds(seconds) }
        if let raw = defaults.string(forKey: settingsPrefix + "viewMode"), let mode = ViewMode(rawValue: raw) { viewMode = mode }
        if let raw = defaults.string(forKey: settingsPrefix + "searchMode"), let mode = NameMatcher.Mode(rawValue: raw) { searchMode = mode }
        if let stored = defaults.object(forKey: Self.volumeKey) as? Double { volume = min(max(stored, 0), 1) }
        if let raw = defaults.string(forKey: sortKeyKey), let key = SortKey(rawValue: raw) {
            sortKey = key
            sortAscending = defaults.object(forKey: sortAscendingKey) as? Bool ?? key.startsAscending
        }
        enterWindow()
    }

    /// The pane shows in a window (again): it listens to the app's events.
    func enterWindow() {
        inWindow = true
        updateWatch()
        // The boss key mutes the video playing at once, and gives it its sound back
        bossKeyObserver = NotificationToken(BossKey.changed) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.activePlayer?.setVolume(self.audibleVolume) }
        }
    }

    /// `--ui-testing` keeps UI-test runs out of the user's real preferences;
    /// `--reset-state` starts such a run from empty preferences.
    static func makeDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard arguments.contains("--ui-testing") else { return .standard }
        let suite = "art.haushoppe.schnellbild.uitests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        if arguments.contains("--reset-state") { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Choosing / loading a folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a folder")
        if panel.runModal() == .OK, let url = panel.url {
            FolderAccess.shared.grant(url)
            open(folder: url)
        }
    }

    /// The folder shown can't be read in the App Sandbox: the user opens it
    /// to the app (or one that holds it), and it is read again; another
    /// folder chosen instead opens.
    func allowAccess() {
        guard let folder = folderURL, let granted = FolderAccess.shared.ask(for: folder) else { return }
        if FolderAccess.shared.covers(folder) { refresh() } else { open(folder: granted) }
    }

    /// Navigate to a folder. Records the current location in the history.
    func open(folder url: URL, selecting target: URL? = nil, thenDetail: Bool = false) {
        recordHistory()
        load(Location(folder: url, selected: target), thenDetail: thenDetail)
    }

    private func load(_ location: Location, thenDetail: Bool = false, password: String? = nil,
                      keeping kept: (marks: Set<String>, chosen: Bool)? = nil) {
        isLoading = true            // first: keeps the searchText reset below from searching
        loadingLocation = location
        refreshDeferred = false     // this reading is the one it waited for
        // Previews and emptiness come from FolderPreviewCache, which checks
        // each folder's date (changes outside the app: Finder, a camera import)
        emptyFolders = []
        loadGeneration += 1
        let generation = loadGeneration
        listingStale = false
        // The last folder's capture dates still being read: not waited for;
        // what they didn't reach is read when it is wanted again
        captureDateTask?.cancel()
        captureDateTask = nil
        captureDatesRead = Set(captureDates.keys)
        leaveSearch()
        pendingResultSelection = nil
        folderURL = location.folder
        entries = []
        allEntries = []
        otherFiles = []
        loadError = nil
        clearMarks()
        selection = nil
        mode = .grid
        searchText = location.query
        resetTransforms()
        stopSlideshow()
        defaults.set(location.folder.path, forKey: lastFolderKey)
        let url = location.folder
        let target = location.selected
        Task {
            // The folder's date first: a change during the listing shows as one later (`relist`)
            let stamp = await FolderPreviewCache.stamp(of: url)
            let scanned = await Self.listing(url, password: password)
            guard self.loadGeneration == generation else { return }   // a newer navigation won
            self.listedStamp = stamp
            var full = (try? scanned.get().entries) ?? []
            if let parent = Self.parentFolder(of: url) {
                full.insert(GridEntry(url: parent, kind: .parent), at: 0)
            }
            let ordered = await self.ordered(full)
            guard self.loadGeneration == generation else { return }
            // A folder read again (`refresh`): its marks and whether the user
            // chose the selection stay, once the listing (and a search) is there
            defer {
                if let kept {
                    let here = Set(self.entries.map { Self.canonicalPath($0.url) })
                    self.marked = kept.marks.intersection(here)
                    self.selectionChosen = kept.chosen
                }
            }
            switch scanned {
            case .success(let listing):
                self.otherFiles = listing.others
            case .failure(let error as CocoaError):
                // Not "empty": the folder couldn't be listed (no permission, a share gone)
                self.loadError = LoadError(archive: false, reason: error.localizedDescription,
                                           needsAccess: !FolderAccess.shared.covers(url))
            case .failure(ArchiveError.needsPassword):
                // Asked once; what is typed is remembered for every archive.
                // The help makes way (one sheet at a time).
                self.showHelp = false
                self.passwordRequest = PasswordRequest(archive: ArchivePath.split(url)?.archive.lastPathComponent ?? url.lastPathComponent,
                                                       location: location, thenDetail: thenDetail, wrong: password != nil)
            case .failure(let error):
                self.loadError = LoadError(archive: ArchivePath.split(url) != nil, reason: error.localizedDescription,
                                           needsAccess: !FolderAccess.shared.covers(url))
            }
            self.allEntries = ordered
            self.isLoading = false
            self.loadingLocation = nil
            if self.isFiltering {
                if let run = location.search, run.matcher == self.matcher, !run.stoppedEarly {
                    // History: the remembered results; a search still
                    // running goes on adding to them.
                    self.search = run
                    self.isSearching = !run.finished
                    self.searchStopped = run.stoppedByUser
                    self.entries = self.sorted(run.results)
                    if let idx = self.index(of: target) { self.selection = idx } else { self.selectDefault(in: self.entries) }
                } else {
                    // The user typed while the folder loaded.
                    self.pendingResultSelection = target
                    self.applyFilter()
                }
                return
            }
            self.entries = self.allEntries
            if let idx = self.index(of: target) {
                self.selection = idx
                if thenDetail, self.entries[idx].isMedia {
                    self.resetTransforms()
                    self.mode = .detail
                }
            } else {
                self.selectDefault(in: self.entries)
            }
        }
    }

    /// UI tests (`--test-log=<path>`): what happened, a line each, for
    /// what the screen doesn't show (how often a rename ran).
    nonisolated static func testLog(_ line: String, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--ui-testing"),
              let arg = arguments.first(where: { $0.hasPrefix("--test-log=") }) else { return }
        let path = String(arg.dropFirst("--test-log=".count))
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// Reopen the last folder on launch (if it still exists).
    /// Checked off the main thread: a share that is mounted but unreachable
    /// (Wi-Fi asleep, VPN down) answers only after its timeout.
    /// Shown as one of two panes (the window sets it): F6 moves there.
    var inDualPane = false

    /// The last folder is being checked (`restoreLastFolder`).
    private(set) var restoringLastFolder = false

    /// The last folder wasn't opened again: the app quit unexpectedly last
    /// time soon after opening it (a file there may crash it; reopening it
    /// at every launch would crash every launch).
    @Published private(set) var skippedRestore: String?
    /// The folder being reopened at launch, until the app has run a while.
    private var restoreUnconfirmedKey: String { settingsPrefix + Self.restoreUnconfirmedKey }
    static let restoreUnconfirmedKey = "restoreUnconfirmed"

    /// The app quits normally: the folders reopened at launch did no harm,
    /// in every pane of every window ("", "rightPane.", "window<n>." …).
    static func confirmRestore(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(restoreUnconfirmedKey) {
            defaults.removeObject(forKey: key)
        }
    }

    func restoreLastFolder(orElse fallback: @escaping @MainActor () -> URL? = { nil }) {
        guard folderURL == nil else { return }
        guard let path = defaults.string(forKey: lastFolderKey) else {
            if let other = fallback() { open(folder: other) }
            return
        }
        if defaults.string(forKey: restoreUnconfirmedKey) == path {
            defaults.removeObject(forKey: restoreUnconfirmedKey)
            skippedRestore = path
            return
        }
        defaults.set(path, forKey: restoreUnconfirmedKey)
        let key = restoreUnconfirmedKey, defaults = defaults
        Task {
            // Still running after a while: it didn't take the app down
            try? await Task.sleep(for: .seconds(15))
            defaults.removeObject(forKey: key)
        }
        restoringLastFolder = true
        Task {
            defer { restoringLastFolder = false }
            let exists = await Blocking.run {
                // A folder inside an archive: the archive file must still be there
                if let (archive, _) = ArchivePath.splitChecked(URL(fileURLWithPath: path)) {
                    return FileManager.default.fileExists(atPath: archive.path)
                }
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                    && !BrowserModel.isPackage(URL(fileURLWithPath: path))
            }
            // Unless the user opened something meanwhile
            guard folderURL == nil else { return }
            if exists { open(folder: URL(fileURLWithPath: path)) } else if let other = fallback() { open(folder: other) }
        }
    }

    /// CLI / UI-test seam: `--open=<path>` opens a folder (grid) or a file
    /// (straight into the full-size view) on launch — same rules as drag &
    /// drop. One argument: AppKit reads "-name value" pairs as settings, so a
    /// path as an argument of its own can end up unpaired, and AppKit then
    /// takes it for a file to open and shows no window.
    @discardableResult
    func openFromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let arg = args.first(where: { $0.hasPrefix("--open=") }) else { return false }
        let url = URL(fileURLWithPath: String(arg.dropFirst("--open=".count)))
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        openDropped([url])
        return true
    }

    /// Read a directory — including hidden entries, with date/size.
    /// Runs off the main thread; metadata is prefetched during
    /// enumeration (no extra round-trips).
    nonisolated static func scan(_ url: URL) async -> [GridEntry] {
        (try? await listing(url).get().entries) ?? []
    }

    /// What the grid shows of a folder, plus its other files, or why it
    /// can't be read (an archive that needs a password; `password` is one
    /// just typed for it).
    nonisolated static func listing(_ url: URL, password: String? = nil) async -> Result<FolderListing, Error> {
        if await Blocking.run(.userInitiated, { ArchivePath.splitChecked(url) != nil }) {
            do { return .success(try await ArchiveStore.shared.listing(in: url, trying: password)) }
            catch { return .failure(error) }
        }
        do { return .success(try await scanFolder(url)) }
        catch { return .failure(error) }
    }

    nonisolated private static func scanFolder(_ url: URL) async throws -> FolderListing {
        try await Blocking.run {
            let keys = entryKeys
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            var listing = FolderListing()
            let drives = isDrivesLevel(url)
            for item in contents {
                // The drives' level: the system's own mounts (Time Machine's
                // snapshots) aren't drives one browses
                if drives, item.lastPathComponent.hasPrefix("com.apple.") { continue }
                if let entry = entry(for: item, keys: keys) { listing.entries.append(entry); continue }
                var vals = try? item.resourceValues(forKeys: keys)
                if vals?.isSymbolicLink == true { vals = try? item.resolvingSymlinksInPath().resourceValues(forKeys: keys) }
                // Hidden files (".DS_Store", "._…") aren't listed; folders that
                // aren't shown are packages, which count as files
                guard !item.lastPathComponent.hasPrefix("."),
                      vals?.isDirectory != true || vals?.isPackage == true else { continue }
                listing.others.append(OtherFile(url: item, byteSize: vals?.isPackage == true ? nil : vals?.fileSize))
            }
            // A split archive's later volumes belong to its tile
            // (names compared ignoring case: "MOVIE.PART2.RAR" belongs to "MOVIE.PART1.RAR")
            // (only parts of an archive the grid shows)
            let names = Set(listing.entries.filter(\.isArchive).map { $0.name.lowercased() })
            listing.others.removeAll { ArchiveName.firstVolumeNames(of: $0.name).contains { names.contains($0.lowercased()) } }
            listing.others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return listing
        }
    }

    /// What `entry(for:keys:)` reads, prefetched by the listings.
    nonisolated static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey, .isAliasFileKey
    ]

    /// Classify one file system item; nil for non-media files. Packages
    /// (".photoslibrary", ".app") are single files to the user, as in the
    /// Finder: not a folder to browse, walk in a slideshow or search.
    nonisolated private static func entry(for item: URL, keys: Set<URLResourceKey>) -> GridEntry? {
        var vals = try? item.resourceValues(forKeys: keys)
        // A Finder alias is a file that LaunchServices follows anywhere (an
        // app): listed among the other files, never shown or opened as media
        if vals?.isAliasFile == true, vals?.isSymbolicLink != true { return nil }
        // A symbolic link is what it points to: a link to a folder is that
        // folder, at its real place (what is done in it is done there, so it
        // says where); a link to a file counts by the file it points to (a
        // "photo.jpg" pointing to a script is no photo)
        var target = item
        if vals?.isSymbolicLink == true {
            target = item.resolvingSymlinksInPath()
            vals = try? target.resourceValues(forKeys: keys)
        }
        let date = vals?.contentModificationDate
        if vals?.isPackage == true { return nil }
        if vals?.isDirectory == true {
            if ArchiveName.format(of: target.lastPathComponent) != nil { ArchivePath.noteFolder(target) }
            return GridEntry(url: target, kind: .folder, modDate: date)
        }
        if target != item, mediaKind(of: target) != mediaKind(of: item) { return nil }
        // An archive opens like a folder
        if ArchiveName.format(of: item.lastPathComponent) != nil {
            ArchivePath.noteArchive(item)
            return GridEntry(url: item, kind: .folder, modDate: date, byteSize: vals?.fileSize)
        }
        guard let kind = mediaKind(of: item) else { return nil }
        return GridEntry(url: item, kind: kind, modDate: date, byteSize: vals?.fileSize)
    }

    /// Whether a photo or video lies anywhere below `folder`. Stops at the
    /// first one, so only folders that are really empty are walked to the
    /// end. Hidden files (".DS_Store", "._…") and anything that isn't a
    /// picture or video ("Thumbs.db", "desktop.ini") don't count.
    /// nil when cancelled before it knew (the tile went away): no answer to
    /// remember.
    nonisolated static func containsMedia(_ folder: URL) async -> Bool? {
        if ArchivePath.split(folder) != nil, await Blocking.run(.userInitiated, { ArchivePath.splitChecked(folder) != nil }) {
            // An archive that needs a password: not known (not greyed out)
            guard let media = try? await ArchiveStore.shared.media(below: folder) else { return nil }
            return !media.isEmpty
        }
        return await FolderProbes.run { cancelled in anyMedia(below: folder, cancelled: cancelled) }
    }

    /// How far a folder tile looks into a folder (its previews, whether it
    /// holds media) before it gives up: on a network share each item is a
    /// round trip.
    nonisolated static func probeLimit(for folder: URL) -> Int {
        let local = (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        return local ? 20_000 : 2_000
    }

    /// The walk itself, synchronous (a directory enumerator isn't for async
    /// code); nil when cancelled or when it gave up (not known: the folder
    /// isn't greyed out).
    nonisolated private static func anyMedia(below folder: URL, cancelled: () -> Bool) -> Bool? {
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        let limit = probeLimit(for: folder)
        var looked = 0
        while true {
            if cancelled() { return nil }
            looked += 1
            if looked > limit { return nil }
            // A pool per item: a big tree would pile up autoreleased objects
            let found: Bool? = autoreleasepool {
                guard let url = walk.nextObject() as? URL else { return false }
                // An archive opens like a folder; what's in it isn't looked into
                // here (that means unpacking), so it counts as holding something
                if mediaKind(of: url) != nil || ArchiveName.format(of: url.lastPathComponent) != nil, isFile(url) { return true }
                return nil
            }
            if let found { return found }
        }
    }

    /// A file, not a folder named like one ("Export.mov"). The enumerators
    /// read this along with the listing.
    nonisolated private static func isFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey])
        // A Finder alias is no picture, whatever its name
        if values?.isAliasFile == true, values?.isSymbolicLink != true { return false }
        // A link to a file counts as that file
        if values?.isSymbolicLink == true {
            return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        }
        return values?.isRegularFile ?? false
    }

    /// Folders known to hold no photos or videos at any depth, as canonical
    /// paths. Filled by the folder tiles as they find out; the grid greys
    /// them out.
    @Published private(set) var emptyFolders: Set<String> = []

    func isEmptyFolder(_ entry: GridEntry) -> Bool {
        entry.kind == .folder && emptyFolders.contains(Self.canonicalPath(entry.url))
    }

    func noteFolder(_ url: URL, empty: Bool) {
        let path = Self.canonicalPath(url)
        // Only on a change: every write publishes and redraws the grid
        guard emptyFolders.contains(path) != empty else { return }
        if empty { emptyFolders.insert(path) } else { emptyFolders.remove(path) }
    }

    /// The media files a folder tile previews: the first `limit` the disk
    /// lists at the folder's top (any three: listing a big folder on a
    /// network share to its end to sort it would cost far more), else the
    /// first ones further down.
    nonisolated static func folderPreviewFiles(in folder: URL, limit: Int = 3) async -> [URL] {
        if ArchivePath.split(folder) != nil, await Blocking.run(.userInitiated, { ArchivePath.splitChecked(folder) != nil }) {
            // An archive: its first pictures at any depth (archives often
            // hold one folder at the top). Not videos: they'd be unpacked.
            let media = (try? await ArchiveStore.shared.media(below: folder)) ?? []
            return Array(media.filter { mediaKind(of: $0) == .image }.prefix(limit))
        }
        return await FolderProbes.run { cancelled -> [URL]? in
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .contentModificationDateKey]
            // The first ones the disk lists at the top, not the first by
            // name: a big folder on a network share isn't listed to its end
            // for three pictures
            var first: [URL] = []
            if let top = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) {
                while first.count < limit, !cancelled() {
                    let more: Bool = autoreleasepool {
                        guard let url = top.nextObject() as? URL else { return false }
                        if mediaKind(of: url) != nil, isFile(url) { first.append(url) }
                        return true
                    }
                    if !more { break }
                }
            }
            if !first.isEmpty { return first }
            // None at the top: the first ones further down, so a folder of
            // folders previews what's inside them too
            guard let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var looked = 0
            let most = probeLimit(for: folder)
            while looked <= most, !cancelled(), first.count < limit {   // a huge tree: give up, not hang
                looked += 1
                let more: Bool = autoreleasepool {
                    guard let url = walk.nextObject() as? URL else { return false }
                    if mediaKind(of: url) != nil, isFile(url) { first.append(url) }
                    return true
                }
                if !more { break }
            }
            return first
        } ?? []
    }

    /// Sorted: ".." on top, then folders, then media — each group by key.
    /// Ties (same kind, date or size) fall back to the name, always A→Z, so
    /// the order is stable. `captured` holds the capture dates read so far.
    nonisolated static func sortEntries(_ entries: [GridEntry], key: SortKey, ascending: Bool,
                                        captured: [URL: Date] = [:]) -> [GridEntry] {
        EntryOrder(key: key, ascending: ascending, captured: captured).sorted(entries)
    }

    /// The grid's order as a comparison, so streamed search results can be
    /// merged into a sorted list instead of sorting it all again.
    struct EntryOrder: Sendable {
        let key: SortKey
        let ascending: Bool
        let captured: [URL: Date]

        /// An entry with what the comparison reads, worked out once (a
        /// capture date looked up per comparison would hash its URL each time).
        struct Keyed {
            let entry: GridEntry
            let group: Int
            let name: String
            let ext: String
            /// The kind's rank (`.kind`), the date (`.modified`, `.captured`)
            /// or the size (`.size`) the key compares.
            let rank: Int
            let date: Date
            let size: Int
        }

        func keyed(_ entry: GridEntry) -> Keyed {
            let group = entry.kind == .parent ? 0 : (entry.kind == .folder ? 1 : 2)
            // As the list's Kind column says: folders, archives, pictures, videos
            let rank: Int
            switch entry.kind {
            case .parent, .folder: rank = entry.isArchive ? 1 : 0
            case .image:           rank = 2
            case .video:           rank = 3
            }
            let date: Date
            switch key {
            case .modified: date = entry.modDate ?? .distantPast
            case .captured: date = captured[entry.url] ?? entry.modDate ?? .distantPast
            default:        date = .distantPast
            }
            return Keyed(entry: entry, group: group, name: entry.name,
                         ext: entry.isMedia ? entry.url.pathExtension.lowercased() : "",
                         rank: rank, date: date, size: entry.byteSize ?? 0)
        }

        private func compare(_ a: Keyed, _ b: Keyed) -> ComparisonResult {
            func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
                x < y ? .orderedAscending : (y < x ? .orderedDescending : .orderedSame)
            }
            switch key {
            case .name:
                return a.name.localizedStandardCompare(b.name)   // the key itself, reversed with the direction
            case .kind:
                // Within pictures and videos by extension (a dot in a folder
                // name isn't one)
                let byKind = order(a.rank, b.rank)
                guard byKind == .orderedSame, a.entry.isMedia, b.entry.isMedia else { return byKind }
                return a.ext.localizedStandardCompare(b.ext)
            case .modified, .captured:
                return order(a.date, b.date)
            case .size:
                return order(a.size, b.size)
            }
        }

        /// ".." on top, then folders, then media, each group by the key.
        func before(_ a: Keyed, _ b: Keyed) -> Bool {
            if a.group != b.group { return a.group < b.group }
            let result = compare(a, b)
            // Ties go by name A→Z in either direction, like Finder
            if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        func sorted(_ entries: [GridEntry]) -> [GridEntry] {
            entries.map(keyed).sorted(by: before).map(\.entry)
        }

        /// `fresh` merged into `list`, which is in this order already.
        func merged(_ list: [GridEntry], _ fresh: [GridEntry]) -> [GridEntry] {
            let add = fresh.map(keyed).sorted(by: before)
            var result: [GridEntry] = []
            result.reserveCapacity(list.count + add.count)
            var i = 0
            for item in add {
                // Binary search for where `item` goes among the rest of `list`
                var low = i, high = list.count
                while low < high {
                    let mid = (low + high) / 2
                    if before(keyed(list[mid]), item) { low = mid + 1 } else { high = mid }
                }
                result.append(contentsOf: list[i..<low])
                result.append(item.entry)
                i = low
            }
            result.append(contentsOf: list[i...])
            return result
        }

        /// `list` after `changes`: what is gone leaves it, what stays in place
        /// keeps its position, and what moved or was renamed goes where it now
        /// sorts (`list` is in this order already: nothing is sorted anew).
        func following(_ list: [GridEntry], _ lookup: FileChanges) -> [GridEntry] {
            var kept: [GridEntry] = []
            kept.reserveCapacity(list.count)
            var moved: [GridEntry] = []
            for entry in list {
                guard entry.kind != .parent else { kept.append(entry); continue }
                guard let url = lookup.url(entry.url) else { continue }
                if url == entry.url { kept.append(entry); continue }
                moved.append(GridEntry(url: url, kind: entry.kind, modDate: entry.modDate, byteSize: entry.byteSize))
            }
            return moved.isEmpty ? kept : merged(kept, moved)
        }
    }

    /// The order the lists are in (sort key, direction, the capture dates known).
    private var entryOrder: EntryOrder { EntryOrder(key: sortKey, ascending: sortAscending, captured: captureDates) }
    /// Counts the changes to `entryOrder` (a new key or direction, capture
    /// dates read), so a sort off the main thread knows it is still current.
    private var orderRevision = 0
    /// Counts the changes to the lists, so a re-sort off the main thread
    /// knows they are still the ones it sorted.
    private var listRevision = 0

    /// Lists longer than this are sorted off the main thread: comparing
    /// names as the Finder does (`localizedStandardCompare`) takes its time
    /// over a hundred thousand of them.
    static let mainThreadSortLimit = 5_000

    /// `list` in the current order; a long list is sorted off the main
    /// thread (again, should the order change meanwhile).
    private func ordered(_ list: [GridEntry]) async -> [GridEntry] {
        guard list.count > Self.mainThreadSortLimit else { return sorted(list) }
        while true {
            let order = entryOrder, revision = orderRevision
            let result = await Blocking.run(.userInitiated) { order.sorted(list) }
            if revision == orderRevision { return result }
        }
    }

    private var resortTask: Task<Void, Never>?

    /// Choose the sort order. The same key again reverses the direction; a
    /// new key starts in its natural direction. Remembered across launches.
    func setSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = key.startsAscending }
        defaults.set(key.rawValue, forKey: sortKeyKey)
        defaults.set(sortAscending, forKey: sortAscendingKey)
        resort()
        readCaptureDatesIfNeeded()
    }

    /// Sort the lists again, keeping the selection.
    /// Long lists are sorted off the main thread and shown once sorted
    /// (sorted again when they or the order changed meanwhile).
    private func resort() {
        resortTask?.cancel()
        resortTask = nil
        guard allEntries.count + entries.count > Self.mainThreadSortLimit else {
            let keep = selectedEntry?.url
            allEntries = sorted(allEntries)
            entries = sorted(entries)
            keepSelection(index(of: keep) ?? selection)
            return
        }
        let all = allEntries, shown = entries, filtering = isFiltering
        let order = entryOrder, orderSeen = orderRevision, listSeen = listRevision
        resortTask = Task { [weak self] in
            // (not searching: the grid shows the folder's listing itself)
            let (sortedAll, sortedShown) = await Blocking.run(.userInitiated) {
                (order.sorted(all), filtering ? order.sorted(shown) : [])
            }
            guard let self, !Task.isCancelled else { return }
            guard orderSeen == self.orderRevision, listSeen == self.listRevision else { self.resort(); return }
            let keep = self.selectedEntry?.url
            self.allEntries = sortedAll
            self.entries = filtering ? sortedShown : sortedAll
            self.keepSelection(self.index(of: keep) ?? self.selection)
        }
    }

    /// While sorting by capture date, read the dates of the media listed
    /// that aren't known yet (off the main thread, a few files at a time)
    /// and sort again once they're in.
    func readCaptureDatesIfNeeded() {
        guard sortKey == .captured else { return }
        readCaptureDates(of: Set((allEntries + entries).filter { $0.isMedia }.map(\.url)))
    }

    /// A list row showing a file's Date Taken: read with the other rows
    /// coming into view (not the whole folder's headers).
    func wantCaptureDate(of url: URL) {
        guard !captureDatesRead.contains(url) else { return }
        wantedCaptureDates.insert(url)
        guard !captureDateRequestPending else { return }
        captureDateRequestPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.captureDateRequestPending = false
            let wanted = self.wantedCaptureDates
            self.wantedCaptureDates = []
            self.readCaptureDates(of: wanted)
        }
    }
    private var wantedCaptureDates: Set<URL> = []
    private var captureDateRequestPending = false

    private func readCaptureDates(of urls: Set<URL>) {
        let missing = urls.subtracting(captureDatesRead)
        guard !missing.isEmpty else { return }
        captureDatesRead.formUnion(missing)
        let previous = captureDateTask
        captureDateTask = Task { [weak self] in
            await previous?.value
            let found = await Self.captureDates(of: Array(missing))
            guard let self, !Task.isCancelled else { return }
            // The list view's Date Taken column shows them
            if !found.isEmpty { self.objectWillChange.send() }
            self.captureDates.merge(found) { _, new in new }
            if self.sortKey == .captured { self.resort() }
        }
    }

    /// Capture dates of the given files, read in parallel (8 at a time).
    nonisolated static func captureDates(of urls: [URL]) async -> [URL: Date] {
        await withTaskGroup(of: (URL, Date?).self) { group in
            var result: [URL: Date] = [:]
            var pending = urls[...]
            func addNext() {
                // Left for another folder: the rest isn't read
                guard !Task.isCancelled, let url = pending.popFirst() else { return }
                group.addTask { (url, await captureDate(of: url)) }
            }
            for _ in 0..<8 { addNext() }
            for await (url, date) in group {
                if let date { result[url] = date }
                addNext()
            }
            return result
        }
    }

    /// When a photo or video was taken: EXIF DateTimeOriginal for images
    /// (only the header is read, on a dispatch thread: it waits on the
    /// disk), the QuickTime creation date for videos.
    nonisolated static func captureDate(of url: URL) async -> Date? {
        guard !ArchivePath.isInside(url) else { return nil }   // not unpacked for sorting
        switch mediaKind(of: url) {
        case .image:
            return await Blocking.run(.utility) { pictureDate(of: url) }
        case .video:
            let asset = AVURLAsset(url: url)
            guard let item = try? await asset.load(.creationDate) else { return nil }
            return try? await item.load(.dateValue)
        default:
            return nil
        }
    }

    /// A picture's capture date, from its header.
    nonisolated private static func pictureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(
                  source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        // The first date that is one: a camera whose clock was never set
        // writes "0000:00:00 00:00:00" (or blanks), which the lenient
        // parser would turn into the year 2
        let candidates: [(text: String?, offset: String?)] = [
            (exif?[kCGImagePropertyExifDateTimeOriginal] as? String, exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String),
            (exif?[kCGImagePropertyExifDateTimeDigitized] as? String, exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String),
            (tiff?[kCGImagePropertyTIFFDateTime] as? String, nil)
        ]
        for case let (text?, offset) in candidates {
            // With the camera's offset from UTC when it wrote one (as video
            // dates are), else in the Mac's time zone
            let date = offset.flatMap { exifOffsetDateFormatter.date(from: text + $0) } ?? exifDateFormatter.date(from: text)
            if let date, Calendar(identifier: .gregorian).component(.year, from: date) >= 1900 { return date }
        }
        return nil
    }

    /// EXIF dates: "2024:07:14 18:32:05", in the camera's local time.
    /// Lenient: a time in the Mac's own daylight-saving gap still parses.
    nonisolated private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = true
        return formatter
    }()

    /// An EXIF date followed by its offset time ("+02:00").
    nonisolated private static let exifOffsetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
        return formatter
    }()

    private func sorted(_ list: [GridEntry]) -> [GridEntry] {
        Self.sortEntries(list, key: sortKey, ascending: sortAscending, captured: captureDates)
    }

    /// Where `url` is in the visible list.
    private func index(of url: URL?) -> Int? {
        guard let url else { return nil }
        let path = Self.canonicalPath(url)
        return entries.firstIndex { Self.canonicalPath($0.url) == path }
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    /// A comparable path: standardized, with macOS's /private/var,
    /// /private/tmp and /private/etc folded onto /var, /tmp and /etc. Pure
    /// string work without file system access, because it runs per entry on
    /// the main thread and must stay fast on network volumes. Entries are
    /// listed under the folder's own path, so they compare consistently.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// A symbolic link: walks don't follow one into the tree (it may point
    /// back up, around and around).
    nonisolated static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// A folder the Finder shows as one item (`.photoslibrary`, `.app`).
    nonisolated static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// `path` is `ancestor` or lies inside it ("/a/photos" is not inside "/a/photo").
    nonisolated static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    private static func defaultSelection(in list: [GridEntry]) -> Int? {
        list.firstIndex { $0.kind != .parent } ?? (list.isEmpty ? nil : 0)
    }

    // MARK: - Search

    /// Recompute the visible `entries` from the query: name matches (folders
    /// and files) in the current folder appear at once, matches from all
    /// subfolders stream in while the tree walk runs.
    func applyFilter() {
        guard !isLoading else { return }
        searchStopped = false
        clearMarks()
        leaveSearch()
        let query = self.query
        let matcher = self.matcher
        guard !query.isEmpty else {
            if listingStale, let folderURL {
                // Changed while the search was shown: read it again
                listingStale = false
                load(Location(folder: folderURL, query: "", selected: selectedEntry?.url))
                return
            }
            pendingResultSelection = nil
            let keep = selectedEntry?.url
            entries = allEntries
            if let kept = index(of: keep) { keepSelection(kept) } else { selectDefault(in: allEntries) }
            return
        }
        mode = .grid
        // The folder's own items at once; with a regular expression (which
        // can take long on a name) off the main thread, first thing in the task
        let candidates = allEntries.filter { $0.kind != .parent }
        let costly = matcher.isCostly && matcher.isValid
        let local = costly ? [] : candidates.filter { matcher.matches($0.name) }
        let run = SearchRun(matcher: matcher, root: folderURL, results: local)
        search = run
        showResults()

        // (an expression that doesn't compile matches nothing: no walk)
        guard let root = folderURL, matcher.isValid else { run.finished = true; return }
        isSearching = true
        let debounce = searchDebounce
        let clock = run.clock
        run.task = Task { [weak self, weak run] in
            if costly, !candidates.isEmpty {
                let found = await Self.matching(candidates, matcher)
                guard let self, let run, !Task.isCancelled else { return }
                self.add(SearchBatch(stamp: 0, entries: found), to: run)
            }
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            for await batch in Self.recursiveMatches(under: root, matching: matcher, clock: clock) {
                guard let self, let run, !Task.isCancelled else { return }
                self.add(batch, to: run)
            }
            guard let self, let run, !Task.isCancelled else { return }
            run.finished = true
            if run === self.search { self.isSearching = false }
        }
    }

    /// The entries whose names `matcher` matches, worked out on a dispatch
    /// thread (an expression may take its time on each name); cancelling
    /// the caller stops it.
    nonisolated static func matching(_ entries: [GridEntry], _ matcher: NameMatcher) async -> [GridEntry] {
        let stop = WalkStop()
        return await withTaskCancellationHandler {
            await Blocking.run { entries.filter { matcher.matches($0.name, stop: stop) } }
        } onCancel: { stop.set() }
    }

    /// The search on screen goes: it keeps running if the history holds
    /// it (the user went into a result and may come back), else it stops.
    private func leaveSearch() {
        if let search, !search.finished, !historySearches.contains(where: { $0 === search }) {
            search.stop(incomplete: true)
        }
        search = nil
        isSearching = false
        // Only the newest few unfinished searches in the history go on.
        let running = historySearches.filter { !$0.finished }
        for old in running.dropLast(Self.backgroundSearchLimit) { old.stop(incomplete: true) }
    }

    /// Every search the history holds, oldest first, each once.
    private var historySearches: [SearchRun] { Self.distinct((backStack + forwardStack.reversed()).compactMap(\.search)) }
    /// The search on screen and those in the history.
    /// (Also the one of a history step being loaded: changes made meanwhile
    /// must reach the results it will show.)
    private var allSearches: [SearchRun] { Self.distinct(historySearches + [search, loadingLocation?.search].compactMap { $0 }) }
    private static func distinct(_ runs: [SearchRun]) -> [SearchRun] {
        var seen = Set<ObjectIdentifier>()
        return runs.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Stops the running search (the stop button); what it has found stays.
    func stopSearch() {
        guard let search, !search.finished else { return }
        search.stop(incomplete: false)
        isSearching = false
        searchStopped = true
    }

    /// The user stopped the search on screen: "no matches" means none so far.
    @Published private(set) var searchStopped = false

    /// Add a streamed batch to the search on screen. Internal so tests can
    /// deliver a batch the walk read before a rename or trash.
    func appendSearchBatch(_ batch: [GridEntry]) {
        if let search { add(SearchBatch(stamp: 0, entries: batch), to: search) }
    }

    private func add(_ batch: SearchBatch, to run: SearchRun) {
        if !batch.facts.isEmpty { learn(batch.facts) }
        let fresh = run.add(batch)
        guard !fresh.isEmpty, run === search else { return }
        showResults(adding: fresh)
    }

    /// Publish search results, keeping the selected item selected while
    /// results stream in. Streamed results are merged into the sorted list
    /// (a broad search brings thousands, batch by batch).
    private func showResults(adding fresh: [GridEntry]? = nil) {
        let keep = fresh == nil ? nil : selectedEntry?.url
        if let fresh {
            entries = EntryOrder(key: sortKey, ascending: sortAscending, captured: captureDates).merged(entries, fresh)
        } else {
            entries = sorted(search?.results ?? [])
        }
        if let idx = index(of: pendingResultSelection) {
            selection = idx
            pendingResultSelection = nil
        } else if let keep, let idx = entries.firstIndex(where: { $0.url == keep }) ?? index(of: keep) {
            keepSelection(idx)
        } else {
            // The first result, not the user's choice
            selectDefault(in: entries)
        }
    }

    /// Deep name match (folders and files) under `root`, delivered in batches
    /// so results appear while a large or slow tree is still being walked.
    /// Skips hidden items and package contents; stops when the consumer
    /// cancels.
    nonisolated static func recursiveMatches(under root: URL, query: String,
                                             clock: ChangeClock? = nil) -> AsyncStream<SearchBatch> {
        recursiveMatches(under: root, matching: NameMatcher(query), clock: clock)
    }

    nonisolated static func recursiveMatches(under root: URL, matching matcher: NameMatcher,
                                             clock: ChangeClock? = nil) -> AsyncStream<SearchBatch> {
        if ArchivePath.split(root) != nil {
            // In an archive: its list of names, known already
            return AsyncStream { continuation in
                let task = Task.detached(priority: .userInitiated) {
                    let stamp = clock?.now ?? 0
                    if await Blocking.run(.userInitiated, { ArchivePath.splitChecked(root) != nil }),
                       let found = try? await ArchiveStore.shared.matches(below: root, matching: matcher), !found.isEmpty {
                        continuation.yield(SearchBatch(stamp: stamp, entries: found))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncStream { continuation in
            // On a thread of its own, not one of Swift's (as many as the Mac
            // has cores): the walk waits on the disk the whole search long
            let stop = WalkStop()
            continuation.onTermination = { _ in stop.set() }
            DispatchQueue.global(qos: .userInitiated).async {
                let keys = entryKeys
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continuation.finish(); return }

                var batch = SearchBatch(stamp: clock?.now ?? 0, entries: [])
                var facts = FolderFacts()
                var lastFlush = ContinuousClock.now
                var whole = false
                while !stop.isSet {
                    // A pool per item: a walk over a million files would
                    // otherwise hold every autoreleased object until it ends
                    let more: Bool = autoreleasepool {
                        guard let url = enumerator.nextObject() as? URL else { return false }
                        // A real folder named like an archive: its results are a folder's
                        if ArchiveName.format(of: url.lastPathComponent) != nil,
                           (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            ArchivePath.noteFolder(url)
                        }
                        if matcher.matches(url.lastPathComponent, stop: stop),
                           let match = entry(for: url, keys: keys) {
                            batch.entries.append(match)
                            if match.kind == .folder, !match.isArchive { facts.found(folder: match.url) }
                        }
                        // (read along with the listing: no extra trip) A file,
                        // not a folder named like one, not a Finder alias
                        if mediaKind(of: url) != nil, let values = try? url.resourceValues(forKeys: keys),
                           values.isDirectory != true, values.isAliasFile != true || values.isSymbolicLink == true {
                            facts.met(media: url)
                        }
                        return true
                    }
                    guard more else { whole = true; break }
                    if !batch.entries.isEmpty || !facts.learnt.isEmpty,
                       batch.entries.count >= 64 || ContinuousClock.now - lastFlush > .milliseconds(200) {
                        batch.facts = facts.take()
                        continuation.yield(batch)
                        batch = SearchBatch(stamp: clock?.now ?? 0, entries: [])
                        lastFlush = .now
                    }
                }
                // Only a walk that went through knows which folders hold nothing
                batch.facts = whole ? facts.finish() : facts.take()
                if !batch.entries.isEmpty || !batch.facts.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
        }
    }

    /// What a search's walk learnt about the folders it found: their tiles
    /// take it from the cache instead of walking them again.
    private func learn(_ facts: FolderFacts.Learnt) {
        let cache = FolderPreviewCache.shared
        for folder in facts.withMedia { cache.learn(folder, hasMedia: true) }
        for (folder, files) in facts.previews { cache.learn(folder, files: files) }
        for folder in facts.withoutMedia {
            cache.learn(folder, hasMedia: false)
            cache.learn(folder, files: [])
            noteFolder(folder, empty: true)
        }
    }

    /// The search as typed, in the mode chosen beside the field.
    var matcher: NameMatcher { NameMatcher(query, mode: searchMode) }

    /// Where a search result lives, relative to the searched folder
    /// ("vacation/2024"); nil for items directly in it.
    func relativeLocation(of entry: GridEntry) -> String? {
        guard let rootPath = folderPath, entry.kind != .parent else { return nil }
        let dirPath = Self.canonicalPath(entry.url.deletingLastPathComponent())
        guard dirPath != rootPath, Self.isSameOrInside(dirPath, rootPath) else { return nil }
        return String(dirPath.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
    }

    /// Keys typed while the search field has focus. Escape clears the query
    /// (or leaves the field when it's empty); ↓ moves into the results;
    /// Return opens the selected result.
    @discardableResult
    func handleSearchFieldKey(_ key: KeyInput) -> Bool {
        switch key {
        case .escape:
            if searchText.isEmpty { searchFocused = false } else { searchText = "" }
            return true
        case .down:
            searchFocused = false
            mode = .grid
            if selection == nil, !entries.isEmpty { selection = 0 }
            return true
        case .enter:
            searchFocused = false
            if mode == .grid { activateSelection() }
            return true
        default:
            return false
        }
    }

    /// Drag & drop: open a folder; for a file → open the parent folder and
    /// select it. Dropped on the "Slideshow" zone, a slideshow starts over
    /// the folder (for a file: over its folder, at that file), the grid of
    /// that folder behind it.
    func openDropped(_ urls: [URL], slideshow: Bool = false) {
        guard let first = urls.first else { return }
        // Opened to the app by the drop (App Sandbox), for now and after a restart
        for url in urls { FolderAccess.shared.grant(url) }
        // What it is: looked up off the main thread (dropped from a share
        // that answers slowly)
        let look: @Sendable () -> (exists: Bool, isFolder: Bool, isPackage: Bool) = {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            return (exists, isDir.boolValue, isDir.boolValue && BrowserModel.isPackage(first))
        }
        guard fileActions.runsOffMain else { openDropped(first, look(), slideshow: slideshow); return }
        Task { openDropped(first, await Blocking.run(.userInitiated, look), slideshow: slideshow) }
    }

    private func openDropped(_ first: URL, _ found: (exists: Bool, isFolder: Bool, isPackage: Bool), slideshow: Bool) {
        guard found.exists else { return }
        // An archive opens like a folder; a package (a Photos library, an
        // app) is one item, as in the Finder: its folder opens, with it selected
        let isPackage = found.isPackage
        let opensAsFolder = (found.isFolder && !isPackage) || ArchiveName.format(of: first.lastPathComponent) != nil
        let folder = opensAsFolder ? first : first.deletingLastPathComponent()
        let file = opensAsFolder ? nil : first
        if slideshow {
            open(folder: folder, selecting: file)
            startSlideshow(over: folder, startingAt: isPackage ? nil : file)
        } else if isPackage {
            open(folder: folder, selecting: file)
        } else if let file {
            open(folder: folder, selecting: file, thenDetail: true)
        } else {
            open(folder: folder)
        }
    }

    // MARK: - History (back / forward)

    /// The place on screen, with its search (finished or still running).
    private var currentLocation: Location? {
        guard let folderURL else { return nil }
        // Still loading: the place being loaded, with its selection and
        // search (the grid has neither yet).
        if isLoading, var loading = loadingLocation {
            if loading.query != searchText { loading.query = searchText; loading.search = nil }
            return loading
        }
        let run = isFiltering && !isLoading ? search : nil
        return Location(folder: folderURL, query: searchText, selected: selectedEntry?.url, search: run)
    }

    private func recordHistory() {
        guard let current = currentLocation else { return }
        if let last = backStack.last, Self.sameSpot(last, current) {
            backStack[backStack.count - 1] = current
        } else {
            let pushed = Self.pushing(current, onto: backStack)
            backStack = pushed.stack
            stopSearches(of: pushed.dropped)
        }
        let dropped = forwardStack
        forwardStack.removeAll()
        stopSearches(of: dropped)
    }

    /// Searches of locations that left the history stop, unless the screen
    /// or another history step still shows them.
    private func stopSearches(of dropped: [Location]) {
        let kept = allSearches
        for run in dropped.compactMap(\.search) where !run.finished && !kept.contains(where: { $0 === run }) {
            run.stop(incomplete: true)
        }
    }

    /// Same folder, query and selection; the result lists aren't compared.
    private static func sameSpot(_ a: Location, _ b: Location) -> Bool {
        samePath(a.folder, b.folder) && a.query == b.query
            && a.selected.map(canonicalPath) == b.selected.map(canonicalPath)
    }

    /// `stack` with `location` on top, at most `historyLimit` deep, and the
    /// steps that fell off the far end (their searches stop once the stack
    /// is stored).
    private static func pushing(_ location: Location, onto stack: [Location]) -> (stack: [Location], dropped: [Location]) {
        let all = stack + [location]
        return (Array(all.suffix(historyLimit)), Array(all.dropLast(historyLimit)))
    }

    /// Back. The full view isn't a history step of its own (it opens in
    /// place, over the folder or the search results), so from there Back
    /// returns to that grid, with the search and its results as they were.
    func navigateBack() {
        if mode == .detail { closeDetail(); return }
        guard let target = backStack.popLast() else { return }
        if let current = currentLocation {
            let pushed = Self.pushing(current, onto: forwardStack)
            forwardStack = pushed.stack
            stopSearches(of: pushed.dropped)
        }
        load(target)
    }

    func navigateForward() {
        guard let target = forwardStack.popLast() else { return }
        if let current = currentLocation {
            let pushed = Self.pushing(current, onto: backStack)
            backStack = pushed.stack
            stopSearches(of: pushed.dropped)
        }
        load(target)
    }

    // MARK: - Selection / navigation

    var selectedEntry: GridEntry? {
        guard let i = selection, entries.indices.contains(i) else { return nil }
        return entries[i]
    }

    var selectedMediaEntry: GridEntry? {
        guard let entry = selectedEntry, entry.isMedia else { return nil }
        return entry
    }

    func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selection = index
    }

    // MARK: Marking several items

    /// Items marked besides the selection (⌘-click, ⇧-click, ⇧-arrows, ⌘A,
    /// Insert), as canonical paths. Empty: the selection alone counts.
    @Published private(set) var marked: Set<String> = []
    /// Where a range (⇧) starts, by its path: re-sorts, search batches and
    /// removals move items around. A plain move of the cursor (arrows,
    /// Home, End) lets the next range start where the cursor is.
    private var markAnchor: String?

    func isMarked(_ entry: GridEntry) -> Bool { marked.contains(Self.canonicalPath(entry.url)) }

    /// What file actions work on: the marked items in grid order, else the
    /// selected one. Never "..".
    var actionEntries: [GridEntry] {
        if marked.isEmpty { return selectedEntry.map { $0.kind == .parent ? [] : [$0] } ?? [] }
        return entries.filter { $0.kind != .parent && marked.contains(Self.canonicalPath($0.url)) }
    }

    func clearMarks() {
        if !marked.isEmpty { marked = [] }
        markAnchor = nil
    }

    /// The selection a click just made: that tile is under the pointer, so
    /// the grid doesn't scroll to it (a double click's second click must
    /// meet the same tile).
    var clickedSelection: Int?

    /// A click on a tile: plain selects it (and unmarks), ⌘ marks or unmarks
    /// it, ⇧ marks the range from the last one.
    func click(_ entry: GridEntry, command: Bool, shift: Bool) {
        guard let index = index(of: entry.url) else { return }
        onActivate?()
        clickedSelection = selection == index ? nil : index
        if shift { markRange(to: index); return }
        if command {
            // The one selected joins, if the user chose it (not the tile
            // selected by default on opening the folder)
            if marked.isEmpty, selectionChosen, let current = selectedEntry, current.kind != .parent, current.url != entry.url {
                marked.insert(Self.canonicalPath(current.url))   // the one selected joins
            }
            let path = Self.canonicalPath(entry.url)
            if entry.kind != .parent { if marked.contains(path) { marked.remove(path) } else { marked.insert(path) } }
            selection = index
            markAnchor = Self.canonicalPath(entry.url)
            return
        }
        clearMarks()
        selection = index
        markAnchor = Self.canonicalPath(entry.url)
    }

    /// Marks everything from the anchor to `index` and moves the selection there.
    func markRange(to index: Int) {
        guard entries.indices.contains(index) else { return }
        // An anchor that left the listing: the range starts at the cursor
        let anchor = markAnchor.flatMap { path in entries.firstIndex { Self.canonicalPath($0.url) == path } }
            ?? min(selection ?? index, entries.count - 1)
        let range = min(anchor, index)...max(anchor, index)
        marked = Set(entries[range].filter { $0.kind != .parent }.map { Self.canonicalPath($0.url) })
        markAnchor = Self.canonicalPath(entries[anchor].url)
        selection = index
    }

    /// Insert (as in the commanders): marks or unmarks the selected item and
    /// moves on to the next.
    func toggleMarkAndAdvance() {
        guard let entry = selectedEntry, let index = selection else { return }
        if entry.kind != .parent {
            let path = Self.canonicalPath(entry.url)
            if marked.contains(path) { marked.remove(path) } else { marked.insert(path) }
        }
        // A range (⇧) goes on from where the cursor is now
        if index + 1 < entries.count { selection = index + 1 }
        markAnchor = nil
    }

    func markAll() {
        marked = Set(entries.filter { $0.kind != .parent }.map { Self.canonicalPath($0.url) })
        markAnchor = nil
    }

    /// Selects an item by its file, wherever it is in the list now (search
    /// results may have moved it since a menu was opened); false if it's gone.
    @discardableResult
    func select(_ entry: GridEntry) -> Bool {
        guard let index = index(of: entry.url) else { return false }
        onActivate?()
        selection = index
        return true
    }

    func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        markAnchor = nil
        let current = selection ?? 0
        selection = min(max(current + delta, 0), entries.count - 1)
    }

    func stepRow(_ direction: Int) {
        guard !entries.isEmpty else { return }
        markAnchor = nil
        let current = selection ?? 0
        let target = current + direction * columnCount
        guard target >= 0, target < entries.count else { return }
        selection = target
    }

    // MARK: - Counters / media

    /// Recomputed once whenever `entries` changes — avoids walking the array
    /// (three filters + a firstIndex) on every render of the status bar / badge.
    private(set) var folderCount = 0
    /// Archives, counted apart from folders (they open like folders).
    private(set) var archiveCount = 0
    private(set) var imageCount = 0
    private(set) var videoCount = 0
    private var firstMediaIndex: Int?

    private func recomputeDerived() {
        var folders = 0, archives = 0, images = 0, videos = 0
        var first: Int?
        for (idx, entry) in entries.enumerated() {
            switch entry.kind {
            case .folder:
                if entry.isArchive { archives += 1 } else { folders += 1 }
            case .image:  images += 1; if first == nil { first = idx }
            case .video:  videos += 1; if first == nil { first = idx }
            case .parent: break
            }
        }
        folderCount = folders
        archiveCount = archives
        imageCount = images
        videoCount = videos
        firstMediaIndex = first
    }

    var mediaCount: Int {
        guard let first = firstMediaIndex else { return 0 }
        return entries.count - first
    }
    var currentMediaNumber: Int? {
        guard let first = firstMediaIndex, let sel = selection, sel >= first else { return nil }
        return sel - first + 1
    }

    /// In the full-size view: page through media only (skip folders).
    func stepMedia(_ delta: Int) {
        guard let first = firstMediaIndex else { return }
        let current = selection ?? first
        selection = min(max(current + delta, first), entries.count - 1)
        resetTransforms()
    }

    // MARK: - Zoom (full-size view)

    func zoomIn()        { zoom = min(zoom * 1.25, maxZoom) }
    func zoomOut()       { zoom = clampedZoom(zoom / 1.25) }
    func zoomReset()     { zoom = 1 }
    func zoomActualSize(){ zoom = clampedZoom(actualSizeFactor) }
    /// (Not snapped: a pinch grows in small steps from fit.)
    func applyPinch(_ factor: CGFloat) { zoom = min(max(zoom * factor, 1), maxZoom) }
    /// Within 1 … maxZoom; a hair above fit (100 % of a picture barely
    /// larger than the view) is fit, as the views count it.
    private func clampedZoom(_ z: CGFloat) -> CGFloat {
        let clamped = min(max(z, 1), maxZoom)
        return clamped <= 1.01 ? 1 : clamped
    }

    // MARK: - Rotation (view-only — the file on disk is never modified)

    func rotateLeft()  { rotation = (rotation - 90).truncatingRemainder(dividingBy: 360) }
    func rotateRight() { rotation = (rotation + 90).truncatingRemainder(dividingBy: 360) }

    /// Reset the view transforms (zoom + rotation) when switching media.
    private func resetTransforms() { zoom = 1; rotation = 0 }

    // MARK: - Grid tile size

    func growThumbnails()   { thumbnailSide = min(thumbnailSide + 30, 320) }
    func shrinkThumbnails() { thumbnailSide = max(thumbnailSide - 30, 80) }

    /// Mode-aware "+"/"−": zoom the image in the full-size view, resize tiles in the grid.
    /// Whether the full view or the slideshow is up (zoom keys zoom it).
    private var viewingMedia: Bool { mode == .detail || slideshow != nil }

    func scaleUp()   { viewingMedia ? zoomIn()  : growThumbnails() }
    func scaleDown() { viewingMedia ? zoomOut() : shrinkThumbnails() }

    // MARK: - Activation / navigation

    func activateSelection() {
        guard let entry = selectedEntry else { return }
        switch entry.kind {
        case .parent:
            goToParentFolder()
        case .folder:
            open(folder: entry.url)
        case .image, .video:
            // The full view takes the keys, also when it was opened with the
            // mouse while the search field had focus.
            searchFocused = false
            resetTransforms()
            mode = .detail
        }
    }

    func closeDetail() {
        stopSlideshow()
        resetTransforms()
        mode = .grid
    }

    /// Backspace, like a browser's Back: out of the full view, else where
    /// the user was before (also back to a search and its results); with no
    /// history yet, the enclosing folder.
    func leaveDetailOrGoBack() {
        if mode == .detail { closeDetail(); return }
        if canGoBack { navigateBack() } else { goToParentFolder() }
    }

    func goToParentFolder() {
        guard let current = folderURL, let parent = Self.parentFolder(of: current) else { return }
        open(folder: parent, selecting: current)
    }

    // MARK: - Keyboard dispatch

    /// The pane's key bindings (the window's are `WindowModel.handleWindowKey`,
    /// F9 / F10 / ⌃⌘F the key monitor's). Returns true if the key was
    /// handled (and should be consumed). Pure enough to unit-test exhaustively.
    /// ⌘⌫ and ⌘↩ return false so they reach their menu items. While a text
    /// field is being edited (`textEditing`) or a sheet is open, keys belong
    /// to them — except F1 and F2.
    @discardableResult
    func handleKey(_ key: KeyInput, command: Bool, shift: Bool = false, option: Bool = false,
                   textEditing: Bool = false, repeating: Bool = false) -> Bool {
        keyRepeating = repeating
        defer { keyRepeating = false }
        let handled = option
            ? !textEditing && optionKey(key, command: command, shift: shift)
            : dispatchKey(key, command: command, shift: shift, textEditing: textEditing)
        // The mini keyboard lights up the key that acted, typed or clicked
        if handled { lastKeyPress = KeyPress(key: key, command: command, shift: shift, option: option) }
        return handled
    }

    /// Keys with ⌥: ⌥← / ⌥→ turn the photo or video on screen a quarter
    /// (the arrows page and skim; with ⌥ they turn). Nothing else.
    private func optionKey(_ key: KeyInput, command: Bool, shift: Bool) -> Bool {
        guard !command, !shift, viewingMedia, !anySheetOpen else { return false }
        switch key {
        case .left:  rotateLeft();  return true
        case .right: rotateRight(); return true
        default:     return false
        }
    }

    /// A key that acted, for the mini keyboard to light it up.
    struct KeyPress: Equatable {
        let key: KeyInput
        let command: Bool
        let shift: Bool
        var option = false
        let id = UUID()
        let at = Date()
        /// The same key, whenever pressed (letters in any case).
        func matches(_ key: KeyInput, command: Bool, shift: Bool, option: Bool = false) -> Bool {
            guard self.command == command, self.shift == shift, self.option == option else { return false }
            if case .char(let a) = self.key, case .char(let b) = key { return a.lowercased() == b.lowercased() }
            return self.key == key
        }
    }
    @Published private(set) var lastKeyPress: KeyPress?

    /// A key the window handled (D, Tab, F5, F6), for the mini keyboard.
    func noteKeyPress(_ key: KeyInput, command: Bool) {
        lastKeyPress = KeyPress(key: key, command: command, shift: false)
    }

    /// Tiles or a list (L): per pane, remembered.
    enum ViewMode: String { case grid, list }
    @Published var viewMode: ViewMode = .grid {
        didSet {
            defaults.set(viewMode.rawValue, forKey: settingsPrefix + "viewMode")
            if viewMode == .list { columnCount = 1 }
        }
    }

    /// A capture date read already (the list's Date Taken column).
    func knownCaptureDate(of url: URL) -> Date? { captureDates[url] }

    static let miniKeyboardKey = "showMiniKeyboard"
    /// The mini keyboard under the window (K): the keys of what's on screen,
    /// clickable, lit up when used. Remembered.
    @Published var showMiniKeyboard = false {
        didSet { defaults.set(showMiniKeyboard, forKey: Self.miniKeyboardKey) }
    }

    private func dispatchKey(_ key: KeyInput, command: Bool, shift: Bool, textEditing: Bool) -> Bool {
        let sheetOpen = anySheetOpen
        switch key {
        case .f1:
            guard !otherSheetOpen else { return false }
            if showHelp { showHelp = false } else { openHelp() }
            return true
        case .f2, .f6:
            // Rename: F2, and Norton's F6 (in a single pane; ⇧F6 anywhere —
            // in the dual pane F6 moves, the window's, never renames). Also
            // while typing in the search field; not during a slideshow (the
            // selection is in the hidden grid).
            if key == .f6, inDualPane, !shift { return false }
            guard !sheetOpen, slideshow == nil else { return false }
            return beginRename()
        default:
            guard !textEditing, !sheetOpen else { return false }
        }
        // Esc closes the Adjustments popover first, as it would by itself.
        if key == .escape, showAdjustments { showAdjustments = false; return true }
        if slideshow != nil { return handleSlideshowKey(key, command: command, shift: shift) }
        switch key {
        case .f1, .f2:
            return false   // handled above
        case .f9, .f10:
            return false   // the window's: the menus, quit
        case .tab, .f5, .f6:
            return false   // the window's (two panes), F6 above
        case .f3:
            guard mode == .grid, selectedEntry != nil else { return false }
            activateSelection(); return true
        case .f4:
            guard mode == .grid || selectedMediaEntry != nil, selectionIsChangeable else { return false }
            openInDefaultApp(); return true
        case .insert:
            guard mode == .grid else { return false }
            toggleMarkAndAdvance(); return true
        case .f7:
            return beginNewFolder()
        case .f8:
            guard mode == .grid, canTrash else { return false }
            moveSelectionToTrash(); return true
        case .backspace:
            guard !command else { return false }
            leaveDetailOrGoBack(); return true
        case .escape:
            if mode == .detail { closeDetail(); return true }
            if !marked.isEmpty { clearMarks(); return true }   // first the marks
            if !searchText.isEmpty { searchText = ""; return true }
            return false
        case .enter:
            // As in the Finder: ↩ renames the selected item (Space opens it),
            // on ".." it goes up; in the full view it goes back to the grid
            guard !command else { return false }
            if mode == .detail { closeDetail(); return true }
            // ".." can't be renamed: ↩ goes up
            if selectedEntry?.kind == .parent { goToParentFolder(); return true }
            return beginRename()
        case .space:
            if mode == .detail {
                (selectedMediaEntry?.kind == .video) ? togglePlayPause() : stepMedia(+1)
            } else {
                activateSelection()
            }
            return true
        case .left, .right:
            // ⌘←/⌘→ always page; plain ←/→ skim through a video first.
            let direction = key == .right ? 1 : -1
            if mode == .grid {
                // ⇧: marks the range on the way
                if shift, let current = selection { markRange(to: min(max(current + direction, 0), entries.count - 1)) }
                else { step(direction) }
            }
            else if command { stepMedia(direction) }
            else if shift { fineSkim(direction) }
            else { skim(direction) }
            return true
        case .up:
            if command { goToParentFolder(); return true }
            if mode == .detail { return verticalKey(up: true) }
            if shift, let current = selection, current - columnCount >= 0 { markRange(to: current - columnCount); return true }
            stepRow(-1); return true
        case .down:
            if mode == .detail { return verticalKey(up: false) }
            if shift, let current = selection, current + columnCount < entries.count { markRange(to: current + columnCount); return true }
            stepRow(+1); return true
        case .home:
            guard mode == .grid else { return false }
            markAnchor = nil
            select(0); return true
        case .end:
            guard mode == .grid, !entries.isEmpty else { return false }
            markAnchor = nil
            select(entries.count - 1); return true
        case .char(let character):
            return handleCharacter(character, command: command)
        }
    }

    private func handleCharacter(_ character: Character, command: Bool) -> Bool {
        let c = Character(character.lowercased())
        switch c {
        case "+", "=": scaleUp();   return true
        case "-":      scaleDown(); return true
        case "f":
            // The search field is disabled without a folder; a focus request
            // then would stay pending and grab focus later.
            if command { focusSearch() } else { toggleFullScreen() }
            return true
        case "a" where command:
            guard mode == .grid else { return false }
            markAll(); return true
        case "[" where command: navigateBack();    return true
        case "]" where command: navigateForward(); return true
        case "s" where !command: startSlideshow(); return true
        case "e" where !command: enhance.toggle(); return true
        case "a" where !command: showAdjustments.toggle(); return true
        case "k" where !command: showMiniKeyboard.toggle(); return true
        case "l" where !command: viewMode = viewMode == .grid ? .list : .grid; return true
        default:
            break
        }
        guard viewingMedia, !command else { return false }
        switch c {
        case "0": zoomReset();            return true
        case "1": zoomActualSize();       return true
        case "i": showInspector.toggle(); return true
        default:  return false
        }
    }

    // MARK: - Slideshow

    /// Focus the search field — only when it is enabled (a folder is open);
    /// a request on the disabled field would grab focus later.
    func focusSearch() {
        searchFocused = folderURL != nil
        Self.testLog("focus search: \(searchFocused)")
    }


    // MARK: - File actions

    func revealInFinder() {
        guard slideshow == nil else { return }   // the selection is in the hidden grid
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        // Inside an archive: the archive file
        fileActions.reveal(ArchivePath.isInside(entry.url) ? ArchivePath.split(entry.url)!.archive : entry.url)
    }

    // MARK: Other files (not pictures, videos or archives)

    /// Whether an other file may be renamed, moved or trashed: one on disk,
    /// not inside an archive (archives are only read).
    func canChange(_ file: OtherFile) -> Bool {
        slideshow == nil && !ArchivePath.isInside(file.url)
    }

    /// Opens an other file with its app, when it is a document (see
    /// `LiveFiles.openOtherFile`); otherwise a beep.
    func open(_ file: OtherFile) {
        guard !ArchivePath.isInside(file.url) else { NSSound.beep(); return }   // no file other apps can open
        fileActions.openOtherFile(file.url)
    }

    func reveal(_ file: OtherFile) {
        fileActions.reveal(ArchivePath.split(file.url)?.archive ?? file.url)
    }

    func beginRename(_ file: OtherFile) {
        guard canChange(file), !anySheetOpen else { return }
        searchFocused = false
        renameFileTarget = file
    }

    /// Renames an other file in place; any name, it isn't shown as a picture
    /// or video either way.
    @discardableResult
    func rename(_ file: OtherFile, to rawName: String) async throws -> URL {
        Self.testLog("rename \(file.name) → \(rawName)")
        let name = try Self.validName(rawName)
        let old = file.url
        guard name != old.lastPathComponent else { renameFileTarget = nil; return old }
        let new = old.deletingLastPathComponent().appendingPathComponent(name)
        try await renameOnDisk(old, new, name: name)
        undoHistory.record(UndoStep(kind: .rename, parts: [.moved(old, to: new)]))
        apply(.moved(old, to: new))
        // A new extension can make it a picture, video or archive: the grid
        // shows it then
        if Self.mediaKind(of: new) != nil || ArchiveName.format(of: name) != nil { refresh(changed: [old.deletingLastPathComponent()]) }
        renameFileTarget = nil
        return new
    }

    func moveToTrash(_ file: OtherFile) {
        guard canChange(file) else { return }
        guard fileActions.confirmTrash(file.name, String(localized: "The file will be moved to the Trash.")) else { return }
        trashFiles([(file.url, false)]) { [self] trashed in apply(trashed.map { FileChange.removed($0) }) }
    }

    func openInDefaultApp() {
        guard slideshow == nil else { return }   // the selection is in the hidden grid
        guard let entry = selectedEntry, entry.kind != .parent else { return }
        guard !ArchivePath.isInside(entry.url) else { NSSound.beep(); return }   // not a file other apps can open
        fileActions.openInDefaultApp(entry.url)
    }

    /// Whether the selection is a file on disk the app may change (not
    /// something inside an archive: archives are only read).
    var selectionIsChangeable: Bool {
        guard let entry = selectedEntry, entry.kind != .parent else { return false }
        return !ArchivePath.isInside(entry.url)
    }

    /// What the Trash takes: the marked items (grid), else the selected one.
    private var trashEntries: [GridEntry] {
        guard mode == .grid else { return selectedMediaEntry.map { [$0] }?.filter { !ArchivePath.isInside($0.url) } ?? [] }
        return actionEntries.filter { !ArchivePath.isInside($0.url) }
    }

    /// The Trash has something to take (the menu item and ⌘⌫).
    var canTrash: Bool { slideshow == nil && !trashLookupPending && !trashEntries.isEmpty }

    /// The parts of an archive are being looked up before its Trash prompt:
    /// a second ⌘⌫ meanwhile would ask twice for the same item.
    @Published private(set) var trashLookupPending = false

    func moveSelectionToTrash() {
        guard slideshow == nil, !trashLookupPending else { return }   // the selection is in the hidden grid
        let items = trashEntries
        // Several (marked): all of them, after one confirmation
        if items.count > 1 { trashMarked(items); return }
        guard let entry = items.first ?? selectedEntry, entry.kind != .parent else { return }
        guard !ArchivePath.isInside(entry.url) else { NSSound.beep(); return }   // archives are only read
        // What goes with it, said exactly: a folder's whole contents (also
        // what the grid doesn't show), all parts of a split archive (found
        // by listing its folder: off the main thread)
        let isArchive = entry.isArchive
        let url = entry.url
        trashLookupPending = true
        onFiles({ isArchive ? ArchiveName.allFiles(of: url) : [url] }) { [self] files in
            trashLookupPending = false
            let detail = entry.kind == .folder && !isArchive
                ? String(localized: "The folder and everything in it, including files Schnellbild doesn't show, will be moved to the Trash.")
                : files.count > 1 ? String(localized: "All parts of this archive will be moved to the Trash.")
                : String(localized: "The file will be moved to the Trash.")
            guard fileActions.confirmTrash(entry.name, detail) else { return }
            trashItems([entry]) { [self] trashed in
                guard !trashed.isEmpty else { return }
                // (the other pane follows through `onFileChange`)
                clearMarks()
                apply(.removed(entry.url))
                if mode == .detail {
                    // The next item comes up as paging shows it: at fit, upright.
                    resetTransforms()
                    if selectedMediaEntry == nil { mode = .grid }
                }
            }
        }
    }

    /// Every item confirmed goes, also after one that fails (it is reported;
    /// an item inside a folder trashed before it is gone with it).
    private func trashMarked(_ items: [GridEntry]) {
        let names = items.prefix(4).map(\.name).joined(separator: ", ") + (items.count > 4 ? ", …" : "")
        let detail = String(localized: "The marked items will be moved to the Trash, folders with everything in them.")
        guard fileActions.confirmTrash(names, detail) else { return }
        clearMarks()
        trashItems(items) { [self] trashed in apply(trashed.map { FileChange.removed($0) }) }
    }

    /// File-system work: off the main thread for the live actions (a share
    /// can take long), right here for a test's spy (its closures belong to
    /// the main thread). `then` runs on the main thread.
    func onFiles<T>(_ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void) {
        guard fileActions.runsOffMain else { then(work()); return }
        Self.transfersUnderWay += 1
        Task {
            let result = await Blocking.run { work() }
            // Counted down after `then`: a move's copy, which `then` starts,
            // counts itself first, so the count never touches 0 in between.
            then(result)
            Self.transfersUnderWay -= 1
        }
    }

    /// Moves items to the Trash, an archive with all its parts (a part that
    /// can't go doesn't keep the others: the set is broken either way, and
    /// the tile goes with its first part). Hands on what went, at least in
    /// part; the first failure is reported.
    private func trashItems(_ items: [GridEntry], then: @escaping @MainActor ([URL]) -> Void) {
        trashFiles(items.map { ($0.url, $0.isArchive) }, then: then)
    }

    private func trashFiles(_ urls: [(URL, Bool)], then: @escaping @MainActor ([URL]) -> Void) {
        let spy = fileActions.runsOffMain ? nil : fileActions.trash
        let work: @Sendable () -> (trashed: [URL], parts: [UndoStep.Part], error: Error?) = {
            var trashed: [URL] = []
            var parts: [UndoStep.Part] = []
            var firstError: Error?
            var gonePaths: Set<String> = []
            for (url, isArchive) in urls {
                let path = BrowserModel.canonicalPath(url)
                // Inside something already gone: gone with it (checked up its folders)
                var above = (path as NSString).deletingLastPathComponent
                var inside = false
                while !above.isEmpty, above != "/" {
                    if gonePaths.contains(above) { inside = true; break }
                    above = (above as NSString).deletingLastPathComponent
                }
                if inside { continue }
                let files = isArchive ? ArchiveName.allFiles(of: url) : [url]
                var gone = false
                for file in files {
                    do {
                        let inTrash = if let spy { try MainActor.assumeIsolated { try spy(file) } } else { try LiveFiles.trash(file) }
                        if let inTrash { parts.append(.trashed(file, inTrash: inTrash)) }
                        gone = true
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
                if gone { trashed.append(url); gonePaths.insert(path) }
            }
            return (trashed, parts, firstError)
        }
        onFiles(work) { [self] result in
            if let error = result.error { fileActions.report(error) }
            undoHistory.record(UndoStep(kind: .trash, parts: result.parts))
            then(result.trashed)
        }
    }

    // MARK: Changes the other pane must see

    /// Told about every folder whose contents this pane changed on disk (the
    /// window passes it to the other pane).
    var onFoldersChanged: (([URL]) -> Void)?

    func notifyFolderChanges(_ folders: [URL]) {
        onFoldersChanged?(folders)
    }

    /// The folder shown, read again (another pane changed it): query,
    /// selection and marks stay where they can.
    func refresh(changed folders: [URL] = []) {
        guard folderURL != nil else { return }
        // Not while loading, under the full view or a slideshow: read again
        // once the listing is there, or back in the grid
        guard !isLoading, mode == .grid, slideshow == nil else { refreshDeferred = true; return }
        guard let folderURL else { return }
        // A search on screen keeps its results and its walk; only the
        // folders that changed are searched for what arrived. The folder's
        // own listing is read again once the search is cleared.
        if isFiltering, let run = search, !folders.isEmpty {
            listingStale = true
            searchArrivals(in: folders, below: folderURL, for: run)
            return
        }
        let location = Location(folder: folderURL, query: searchText, selected: selectedEntry?.url)
        load(location, keeping: (marked, selectionChosen))
    }

    private var refreshDeferred = false
    /// The folder changed while a search was shown: read it again when the
    /// search is cleared.
    private var listingStale = false

    /// What arrived in `folders` that matches the search: the searched
    /// folder itself by its listing, a folder below it by a walk of it.
    private func searchArrivals(in folders: [URL], below root: URL, for run: SearchRun) {
        let rootPath = Self.canonicalPath(root)
        let matcher = run.matcher
        let clock = run.clock
        for folder in folders where Self.isSameOrInside(Self.canonicalPath(folder), rootPath) {
            let shallow = Self.canonicalPath(folder) == rootPath
            Task { [weak self, weak run] in
                if shallow {
                    let stamp = clock.now
                    let found = await Self.matching(Self.scan(folder).filter { $0.kind != .parent }, matcher)
                    guard let self, let run else { return }
                    self.add(SearchBatch(stamp: stamp, entries: found), to: run)
                } else {
                    for await batch in Self.recursiveMatches(under: folder, matching: matcher, clock: clock) {
                        guard let self, let run else { return }
                        self.add(batch, to: run)
                    }
                }
            }
        }
    }

    private func refreshIfDeferred() {
        guard refreshDeferred else { return }
        refreshDeferred = false
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Whether a change in `folders` shows here: the folder itself, or one
    /// below it while searching.
    func shows(any folders: [URL]) -> Bool {
        guard let folderPath else { return false }
        return folders.contains { folder in
            let path = Self.canonicalPath(folder)
            return path == folderPath || (isFiltering && Self.isSameOrInside(path, folderPath))
        }
    }

    // MARK: Changes outside the app

    /// Whether panes watch the folder they show (FSEvents, `FolderWatch`):
    /// the app turns it on at launch; a test turns it on for its own model.
    static var watchFoldersByDefault = false
    var watchesFolder = BrowserModel.watchFoldersByDefault {
        didSet { updateWatch() }
    }
    private var watch: FolderWatch?
    /// In a window (not one that closed, `leaveWindow`).
    private var inWindow = true

    /// The watch follows the folder shown (none inside an archive: nothing
    /// changes there).
    private func updateWatch() {
        guard watchesFolder, inWindow, let folderURL, ArchivePath.split(folderURL) == nil else { watch = nil; return }
        guard watch?.path != folderURL.path else { return }
        watch = nil
        watch = FolderWatch(path: folderURL.path) { [weak self] changed, rootChanged in
            self?.changedOutside(changed, rootChanged: rootChanged)
        }
    }

    /// FSEvents: something changed in or below the folder shown (`changed`:
    /// the folders whose contents changed, nil for too many to name).
    func changedOutside(_ changed: [String]?, rootChanged: Bool) {
        guard let folderURL, let folderPath else { return }
        if rootChanged { followFolderGone(); return }
        guard let changed else {
            forgetBelow(nil)
            relist(force: true, searchAgain: isFiltering)
            return
        }
        let below = changed.filter { $0 != folderPath && Self.isSameOrInside($0, folderPath) }
        if !below.isEmpty {
            forgetBelow(below)
            // A search shown finds what arrived there, and drops what went
            if isFiltering, let run = search {
                let folders = below.map { URL(fileURLWithPath: $0, isDirectory: true) }
                searchArrivals(in: folders, below: folderURL, for: run)
                dropVanishedResults(in: Set(below))
            }
        }
        if changed.contains(folderPath) { relist(force: true) }
    }

    /// Folder tiles read their previews and emptiness again: the folders
    /// around `paths` (canonical), or every one (nil).
    private func forgetBelow(_ paths: [String]?) {
        if let paths {
            let affected = paths.flatMap { FileChange.removed(URL(fileURLWithPath: $0, isDirectory: true)).affectedFolders }
            FolderPreviewCache.shared.forget(affected)
            emptyFolders.subtract(affected)
        } else {
            FolderPreviewCache.shared.forgetAll()
            emptyFolders = []
        }
        folderChanges += 1
    }

    /// Search results directly in `folders` that are no longer on disk leave
    /// the results (checked off the main thread).
    private func dropVanishedResults(in folders: Set<String>) {
        let candidates = entries.filter { folders.contains(Self.canonicalPath($0.url.deletingLastPathComponent())) }.map(\.url)
        guard !candidates.isEmpty else { return }
        Task {
            let gone = await Blocking.run(.utility) { candidates.filter { !FileManager.default.fileExists(atPath: $0.path) } }
            if !gone.isEmpty { applyHere(gone.map(FileChange.removed)) }
        }
    }

    /// The folder's own date when it was listed: `relist` reads it again
    /// only when that changed.
    private var listedStamp: Date?
    private var relisting = false
    /// Asked again while reading: read once more when done.
    private var relistQueued: (force: Bool, searchAgain: Bool)?

    /// The folder shown, read again in place (changes outside the app: the
    /// Finder, a camera import, another Mac on a share): what came, went or
    /// changed shows, the selection, marks, search and scroll position stay.
    /// Unless `force`, only when the folder's date changed since it was
    /// listed (one look at the disk, off the main thread). `searchAgain`: a
    /// search shown searches again once the listing is in (Reload).
    func relist(force: Bool = false, searchAgain: Bool = false) {
        guard let folderURL, !isLoading else { return }
        guard ArchivePath.split(folderURL) == nil else {
            if force { load(Location(folder: folderURL, query: searchText, selected: selectedEntry?.url), keeping: (marked, selectionChosen)) }
            return
        }
        guard !relisting else {
            relistQueued = (force || relistQueued?.force == true, searchAgain || relistQueued?.searchAgain == true)
            return
        }
        relisting = true
        let generation = loadGeneration, known = listedStamp
        Task {
            defer {
                relisting = false
                if let again = relistQueued {
                    relistQueued = nil
                    relist(force: again.force, searchAgain: again.searchAgain)
                }
            }
            let stamp = await FolderPreviewCache.stamp(of: folderURL)
            guard loadGeneration == generation else { return }
            // (no date: unreadable for now, a share slow to answer: left as
            // it is; a folder deleted or a volume gone is told otherwise,
            // FSEvents' `rootChanged`, `volumesChanged`)
            guard force || (stamp != nil && stamp != known) else { return }
            guard case .success(let listing) = await Self.listing(folderURL) else { return }
            guard loadGeneration == generation, !isLoading else { return }
            listedStamp = stamp
            merge(listing)
            if searchAgain, isFiltering {
                pendingResultSelection = selectedEntry?.url
                applyFilter()
            }
        }
    }

    /// A listing read again, merged into the one shown: what went leaves
    /// every list (as if trashed here), what came or changed goes where it
    /// sorts; nothing else moves.
    private func merge(_ listing: FolderListing) {
        if listing.others != otherFiles { otherFiles = listing.others }
        var fresh: [String: GridEntry] = [:]
        for entry in listing.entries { fresh[Self.canonicalPath(entry.url)] = entry }
        var gone: [FileChange] = []
        var renewed: [GridEntry] = []
        var listed = Set<String>()
        for entry in allEntries where entry.kind != .parent {
            let path = Self.canonicalPath(entry.url)
            listed.insert(path)
            guard let now = fresh[path] else { gone.append(.removed(entry.url)); continue }
            if now != entry { renewed.append(now) }
        }
        let changedPaths = Set(renewed.map { Self.canonicalPath($0.url) })
        renewed += listing.entries.filter { !listed.contains(Self.canonicalPath($0.url)) }
        if !gone.isEmpty {
            applyHere(gone)
            // The picture shown full size went: back to the grid
            if mode == .detail, selectedMediaEntry == nil { mode = .grid }
        }
        guard !renewed.isEmpty else { return }
        forgetBelow(renewed.filter { $0.kind == .folder }.map { Self.canonicalPath($0.url) })
        let keep = selectedEntry?.url
        let previous = selection
        let unchanged = changedPaths.isEmpty ? allEntries : allEntries.filter { !changedPaths.contains(Self.canonicalPath($0.url)) }
        allEntries = entryOrder.merged(unchanged, renewed)
        if isFiltering {
            // What arrived and matches: the search finds it
            if let run = search, let folderURL { searchArrivals(in: [folderURL], below: folderURL, for: run) }
            return
        }
        entries = allEntries
        keepSelection(index(of: keep) ?? previous.map { min($0, entries.count - 1) })
    }

    /// The folder shown went (deleted, moved away, its volume gone): the
    /// nearest folder around it still there opens, at last the drives' level.
    private func followFolderGone() {
        guard let folderURL else { return }
        let generation = loadGeneration
        Task {
            let place = await Blocking.run(.utility) { () -> URL? in
                var candidate: URL? = folderURL
                while let folder = candidate {
                    var isFolder: ObjCBool = false
                    if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue { return folder }
                    candidate = BrowserModel.parentFolder(of: folder)
                }
                return nil
            }
            guard loadGeneration == generation, let place, !Self.samePath(place, folderURL) else { return }
            // Not into the history: the folder left is gone
            load(Location(folder: place, query: "", selected: nil))
        }
    }

    /// A volume was mounted or unmounted (`unmounted`): a pane showing a
    /// folder on it goes to the drives' level; one showing the drives' level
    /// lists them again.
    func volumesChanged(unmounted volume: URL?) {
        guard let folderURL else { return }
        if let volume, Self.isSameOrInside(Self.canonicalPath(folderURL), Self.canonicalPath(volume)), !Self.isDrivesLevel(volume) {
            load(Location(folder: URL(fileURLWithPath: Self.volumesPath, isDirectory: true), query: "", selected: nil))
            return
        }
        if Self.isDrivesLevel(folderURL) { relist(force: true) }
    }

    /// View → Reload (⌘R): the folder shown read again, its tiles too; a
    /// search searches again.
    func reload() {
        guard folderURL != nil, !isLoading, slideshow == nil else { return }
        forgetBelow(nil)
        relist(force: true, searchAgain: isFiltering)
    }

    /// F1 / "Schnellbild Help". Not over the rename sheet: a second sheet
    /// can't open on top of it.
    func openHelp() {
        guard !otherSheetOpen else { return }
        showHelp = true
    }

    /// A sheet other than the help is open (a second sheet can't open on top).
    var otherSheetOpen: Bool { renameTarget != nil || renameFileTarget != nil || passwordRequest != nil || newFolderRequested }
    /// Any of the sheets is open (they keep their keys).
    var anySheetOpen: Bool { showHelp || otherSheetOpen }

    // MARK: - New folder, moving into folders

    /// The new-folder sheet is open (⇧⌘N): nothing exists until a name is
    /// given and confirmed; Esc leaves no folder behind.
    @Published var newFolderRequested = false

    /// Tiles are being dragged over this pane where a drop goes into the
    /// folder it shows (free space, a picture or video tile, the bars):
    /// the pane is outlined and names that folder.
    @Published var dropIntoFolderTargeted = false

    /// The folder a drop onto the pane goes into: none while results are
    /// shown (their folder is not the one searched) or inside an archive.
    var paneDropFolder: URL? {
        guard let folder = folderURL, !isFiltering, ArchivePath.split(folder) == nil else { return nil }
        return folder
    }

    /// "IMG 2.jpg", "IMG 3.jpg" … for a name taken in `folder`.
    nonisolated static func freeName(for name: String, in folder: URL, isFolder: Bool = false, taken: (URL) -> Bool) -> URL {
        // As the Finder: a folder's number goes after its whole name
        let stem = isFolder ? name : (name as NSString).deletingPathExtension
        let ext = isFolder ? "" : (name as NSString).pathExtension
        for n in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !taken(candidate) { return candidate }
        }
        return folder.appendingPathComponent(name)
    }

    /// A name as typed, checked: not empty, no "/" or ":", not "." / "..".
    static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.emptyName }
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw RenameError.invalidName
        }
        return name
    }

    /// Whether a folder can be made here: a real folder, not inside an
    /// archive, no slideshow or sheet in the way.
    var canCreateFolder: Bool {
        // In the grid: what it makes is selected there
        guard let folderURL, mode == .grid, slideshow == nil, !isLoading else { return false }
        return !anySheetOpen && ArchivePath.split(folderURL) == nil
    }

    @discardableResult
    func beginNewFolder() -> Bool {
        guard canCreateFolder else { return false }
        searchFocused = false
        newFolderRequested = true
        return true
    }

    /// Makes the folder named in the sheet in the folder shown, and selects it.
    @discardableResult
    func createFolder(named raw: String) async throws -> URL {
        guard let folderURL, canCreateFolder || newFolderRequested else { throw RenameError.invalidName }
        let name = try Self.validName(raw)
        let url = folderURL.appendingPathComponent(name, isDirectory: true)
        // Any item of that name there (compared with the folder itself: a
        // different item, so an existing one counts); off the main thread
        // for the live actions, inline for a test's spy
        let make: @Sendable (Bool, () throws -> Void) throws -> Void = { taken, create in
            if taken { throw RenameError.alreadyExists(name) }
            do { try create() } catch { throw RenameError.failed(error.localizedDescription) }
        }
        if fileActions.runsOffMain {
            try await Blocking.run {
                try make(LiveFiles.conflicts(url, folderURL)) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            }
        } else {
            try make(fileActions.conflicts(url, folderURL)) { try fileActions.createFolder(url) }
        }
        newFolderRequested = false
        // A folder named like an archive stays a folder
        if ArchiveName.format(of: name) != nil { ArchivePath.noteFolder(url) }
        notifyFolderChanges([folderURL])
        // (the pane may have moved on meanwhile)
        guard self.folderURL.map(Self.canonicalPath) == Self.canonicalPath(folderURL) else { return url }
        let entry = GridEntry(url: url, kind: .folder, modDate: Date())
        allEntries = entryOrder.merged(allEntries, [entry])
        noteFolder(url, empty: true)
        if !isFiltering {
            entries = allEntries
            selection = index(of: url)
        }
        return url
    }

    /// How items go into another folder: dropped (moved on the same
    /// volume, copied to another, as in the Finder), F5 (copied), F6 (moved).
    enum Transfer { case asFinder, copy, move }

    /// Files or folders dropped onto a folder tile (or ".."), or sent to the
    /// other pane (F5 / F6), go into `folder`. A name taken there asks: keep
    /// both (the new one numbered) or skip. Not into archives, not into
    /// themselves.
    func move(_ sources: [URL], into folder: URL, how: Transfer = .asFinder) {
        guard ArchivePath.split(folder) == nil else { NSSound.beep(); return }
        let target = Self.canonicalPath(folder)
        let shown = folderPath
        // By their paths alone (no file system): what can go at all
        let sourcePaths = sources.map(Self.canonicalPath)
        let candidates = sources.filter { source in
            let path = Self.canonicalPath(source)
            return !ArchivePath.isInside(source) && path != target && !target.hasPrefix(path + "/")
                // Not inside another item that goes along
                && !sourcePaths.contains(where: { path.hasPrefix($0 + "/") })
                // Never the folder shown or one around it
                && (shown.map { $0 != path && !$0.hasPrefix(path + "/") } ?? true)
                && Self.canonicalPath(source.deletingLastPathComponent()) != target
        }
        guard !candidates.isEmpty else { return }
        transfersRunning += 1
        // What each item is and what is taken there: looked up off the main
        // thread (a share answers slowly, item by item)
        let conflicts = fileActions.runsOffMain ? nil : fileActions.conflicts
        let look: @Sendable () -> [TransferProbe] = {
            candidates.map { source in
                let taken: (URL, URL) -> Bool = { target, source in
                    if let conflicts { return MainActor.assumeIsolated { conflicts(target, source) } }
                    return LiveFiles.conflicts(target, source)
                }
                // A split archive goes with all its parts (an archive is a
                // file; a folder named like one is a folder)
                let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let files = !isFolder && ArchiveName.format(of: source.lastPathComponent) != nil ? ArchiveName.allFiles(of: source) : [source]
                let destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: isFolder)
                let destinationTaken = taken(destination, source)
                // Free names for Keep Both, looked up here too
                var free: [URL] = []
                if destinationTaken, files.count == 1 {
                    var skip: Set<String> = []
                    while free.count < 4 {
                        let next = BrowserModel.freeName(for: source.lastPathComponent, in: folder, isFolder: isFolder) {
                            skip.contains($0.lastPathComponent) || taken($0, source)
                        }
                        skip.insert(next.lastPathComponent)
                        free.append(next)
                    }
                }
                return TransferProbe(source: source, isFolder: isFolder, files: files,
                                     destinationTaken: destinationTaken, freeNames: free,
                                     partTaken: files.dropFirst().contains { taken(folder.appendingPathComponent($0.lastPathComponent), $0) })
            }
        }
        onFiles(look) { [self] probes in
            let steps = planMove(probes, into: folder)
            guard !steps.isEmpty else { transfersRunning -= 1; return }
            // What goes is no longer marked here
            clearMarks()
            // Copies (to another volume, F5) can take long: off the main
            // thread, the app stays usable meanwhile
            Self.transfersUnderWay += 1
            Task {
                let outcomes = await fileActions.run(steps, how)
                transfersRunning -= 1
                Self.transfersUnderWay -= 1
                finishMove(steps, outcomes, into: folder)
            }
        }
    }

    /// What a source of a move is, and what is taken in the target folder.
    struct TransferProbe: Sendable {
        let source: URL
        let isFolder: Bool
        let files: [URL]
        let destinationTaken: Bool
        /// Names free there, for Keep Both (when the name is taken).
        let freeNames: [URL]
        let partTaken: Bool
    }

    /// Where each item goes: a name taken there asks (keep both, numbered,
    /// or skip); the destinations of the items before count as taken too.
    private func planMove(_ probes: [TransferProbe], into folder: URL) -> [TransferStep] {
        var steps: [TransferStep] = []
        var planned: Set<String> = []
        for probe in probes {
            let source = probe.source
            let isPlanned: (URL) -> Bool = { planned.contains(Self.canonicalPath($0)) }
            // A later part taken there: the set would be mixed
            if probe.partTaken || probe.files.dropFirst().contains(where: { isPlanned(folder.appendingPathComponent($0.lastPathComponent)) }) {
                NSSound.beep(); continue
            }
            var destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: probe.isFolder)
            if probe.destinationTaken || isPlanned(destination) {
                guard fileActions.askKeepBoth(source.lastPathComponent, folder.lastPathComponent) else { continue }
                // Renamed, the parts of a split archive no longer belong together
                guard probe.files.count == 1 else { NSSound.beep(); continue }
                destination = probe.freeNames.first { !isPlanned($0) }
                    // (all of them planned already: rare, looked up here)
                    ?? Self.freeName(for: source.lastPathComponent, in: folder, isFolder: probe.isFolder,
                                     taken: { isPlanned($0) || self.fileActions.conflicts($0, source) })
            }
            let pairs = probe.files.map { ($0, $0 == source ? destination : folder.appendingPathComponent($0.lastPathComponent)) }
            for (_, to) in pairs { planned.insert(Self.canonicalPath(to)) }
            steps.append(TransferStep(source: source, destination: destination, files: pairs))
        }
        return steps
    }

    /// One item of a move: its files (a split archive's parts) and where they go.
    struct TransferStep: Sendable {
        let source: URL
        let destination: URL
        let files: [(URL, URL)]
    }

    /// Copies and moves under way (the status bar says so).
    @Published private(set) var transfersRunning = 0
    /// The same for the whole app: quitting waits for them
    /// (`AppDelegate.applicationShouldTerminate`), or a file would be left
    /// half copied under its final name.
    static var transfersUnderWay = 0 {
        didSet { if transfersUnderWay == 0 { onTransfersDone?() } }
    }
    static var onTransfersDone: (() -> Void)?

    private func finishMove(_ steps: [TransferStep], _ outcomes: [Result<Bool, Error>], into folder: URL) {
        let target = Self.canonicalPath(folder)
        var moves: [FileChange] = []
        var reported = false
        var undoParts: [UndoStep.Part] = []
        for (step, outcome) in zip(steps, outcomes) {
            if case .success(let moved) = outcome {
                undoParts += step.files.map { moved ? UndoStep.Part.moved($0.0, to: $0.1) : .copied($0.0, to: $0.1) }
            }
            switch outcome {
            case .success(true):
                moves.append(.moved(step.source, to: step.destination))
            case .success(false):
                // A copy: the target and every folder around it hold more now
                let around = FileChange.removed(folder).affectedFolders
                FolderPreviewCache.shared.forget(around)
                emptyFolders.subtract(around)
                folderChanges += 1
            case .failure(let error):
                if !reported { fileActions.report(error); reported = true }
            }
        }
        undoHistory.record(UndoStep(kind: undoParts.contains { if case .copied = $0 { return true }; return false } ? .copy : .move,
                                    parts: undoParts))
        // The selection as it was, before the moves rewrite its path
        let keep = selectedEntry?.url
        // What left a folder: the other pane follows the changes; what
        // arrived: the other pane reads the target folder again
        apply(moves)
        notifyFolderChanges([folder])
        // The folder shown went along (opened while the move ran): follow it
        if followFolder(through: moves) { return }
        guard let shown = folderPath else { return }
        // Into the folder shown (a drop onto the pane): read it again to show what came
        if target == shown { refresh(changed: [folder]); return }
        dropWhatLeft(keeping: keep)
    }

    /// After a move: what went elsewhere leaves this folder's listing and
    /// its results; the selection stays on `keep` where it is still listed.
    func dropWhatLeft(keeping keep: URL?) {
        guard let shown = folderPath else { return }
        let inShown: (GridEntry) -> Bool = { $0.kind == .parent || Self.canonicalPath($0.url.deletingLastPathComponent()) == shown }
        let belowShown: (GridEntry) -> Bool = { Self.isSameOrInside(Self.canonicalPath($0.url), shown) }
        let before = (allEntries.count, entries.count)
        let previous = selection
        allEntries = allEntries.filter(inShown)
        entries = isFiltering ? entries.filter(belowShown) : allEntries
        guard (allEntries.count, entries.count) != before else { return }
        // Marks only on what is still listed
        if !marked.isEmpty { marked.formIntersection(entries.map { Self.canonicalPath($0.url) }) }
        if let index = index(of: keep) {
            keepSelection(index)
        } else if let previous, !entries.isEmpty {
            // What was selected went: its neighbour, as after the Trash
            keepSelection(min(previous, entries.count - 1))
        } else {
            selectDefault(in: entries)
        }
        // The full view shows media only: back to the grid when what it showed left
        if mode == .detail, selectedMediaEntry == nil { mode = .grid }
    }

    /// Whether the folder shown can be renamed in place (its name in the
    /// title bar): a real folder, not inside an archive, not a volume's top.
    var canRenameCurrentFolder: Bool {
        guard let folderURL, slideshow == nil, !isLoading, ArchivePath.split(folderURL) == nil else { return false }
        return Self.parentFolder(of: folderURL) != nil && folderURL.pathComponents.count > 3   // not "/" or "/Volumes/X"
    }

    /// The folder shown, renamed from its name in the title bar: it stays
    /// open under the new name; history and results follow. A name that
    /// can't be used is reported.
    func renameCurrentFolder(to raw: String) async {
        guard canRenameCurrentFolder, let old = folderURL else { return }
        do {
            let name = try Self.validName(raw)
            guard name != old.lastPathComponent else { return }
            let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            Self.testLog("rename the folder shown \(old.lastPathComponent) → \(name)")
            try await renameOnDisk(old, new, name: name)
            // A folder named like an archive stays a folder
            if ArchiveName.format(of: name) != nil { ArchivePath.noteFolder(new) }
            apply(.moved(old, to: new))
            // (the pane may have moved on meanwhile; the change reached it)
            guard folderURL.map(Self.canonicalPath) == Self.canonicalPath(old) else { return }
            folderURL = new
            defaults.set(new.path, forKey: lastFolderKey)
            if let parent = Self.parentFolder(of: new), let i = allEntries.firstIndex(where: { $0.kind == .parent }) {
                allEntries[i] = GridEntry(url: parent, kind: .parent)
                if let j = entries.firstIndex(where: { $0.kind == .parent }) { entries[j] = allEntries[i] }
            }
        } catch {
            fileActions.report(error)
        }
    }

    // MARK: - Rename

    /// Whether an item can be renamed here: not "..", nothing inside an
    /// archive (archives are only read), not an archive split into parts
    /// by its name ("x.part1.rar", "x.7z.001").
    func canRename(_ entry: GridEntry) -> Bool {
        guard entry.kind != .parent, !ArchivePath.isInside(entry.url) else { return false }
        // (by the name the download will have: "x.7z.001.part" is a volume too)
        let name = ArchiveName.finalName(of: entry.name).lowercased()
        return !(entry.isArchive && (ArchiveName.rarPart(of: name) != nil || name.hasSuffix(".001")))
    }

    /// Open the rename sheet for the selected folder or file, in the grid or
    /// the full view.
    @discardableResult
    func beginRename() -> Bool {
        // Not over the help: a second sheet can't open on top of it.
        guard slideshow == nil, !anySheetOpen, let entry = selectedEntry, canRename(entry) else { return false }
        searchFocused = false   // F2 works while typing in the search field
        guard entry.isArchive else { renameTarget = entry; return true }
        // A split archive is renamed by renaming all its volumes, not here
        // (its parts are known only by listing the folder: off the main
        // thread, a share answers slowly)
        let url = entry.url
        Task {
            let parts = await Blocking.run { ArchiveName.allFiles(of: url).count }
            guard selectedEntry?.url == url, !anySheetOpen, slideshow == nil else { return }
            if parts > 1 { NSSound.beep() } else { renameTarget = entry }
        }
        return true
    }

    /// Rename a folder or file in place. Updates the grid, the selection and
    /// every history entry that points to it (or, for a folder, into it).
    @discardableResult
    func rename(_ entry: GridEntry, to rawName: String) async throws -> URL {
        Self.testLog("rename \(entry.name) → \(rawName)")
        let name = try Self.validName(rawName)
        let old = entry.url
        guard name != old.lastPathComponent else { renameTarget = nil; return old }
        // An archive is a file: it keeps a name of its format
        let archive = entry.isArchive
        let isFolder = entry.kind == .folder && !archive
        let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isFolder)
        if archive, ArchiveName.format(of: name) != ArchiveName.format(of: old.lastPathComponent) {
            // The ending of its format (not a download's ".part")
            let final = ArchiveName.finalName(of: old.lastPathComponent)
            throw RenameError.changesArchiveFormat((final as NSString).pathExtension)
        }
        if entry.kind != .folder, Self.mediaKind(of: new) != entry.kind {
            throw RenameError.changesKind(old.pathExtension, video: entry.kind == .video)
        }
        try await renameOnDisk(old, new, name: name)
        undoHistory.record(UndoStep(kind: .rename, parts: [.moved(old, to: new)]))

        // Stay where we are: same folder, same query, same results (and the
        // full view stays open) — only the renamed item and, for a folder,
        // everything listed inside it get the new path.
        // A folder named like an archive stays a folder
        if isFolder, ArchiveName.format(of: name) != nil { ArchivePath.noteFolder(new) }
        // (the other pane follows through `onFileChange`)
        apply(.moved(old, to: new))
        renameTarget = nil
        return new
    }

    /// Renames on disk: off the main thread for the live actions (a share
    /// answers slowly), inline for a test's spy. Refuses a name taken by
    /// another item.
    private func renameOnDisk(_ old: URL, _ new: URL, name: String) async throws {
        let check: @Sendable (Bool) throws -> Void = { taken in if taken { throw RenameError.alreadyExists(name) } }
        guard fileActions.runsOffMain else {
            try check(fileActions.conflicts(new, old))
            do { try fileActions.move(old, new) } catch { throw RenameError.failed(error.localizedDescription) }
            return
        }
        try await Blocking.run {
            try check(LiveFiles.conflicts(new, old))
            do { try LiveFiles.move(old, new) } catch { throw RenameError.failed(error.localizedDescription) }
        }
    }

    /// A change this pane made on disk: its own lists, then the other panes.
    func apply(_ change: FileChange) { apply([change]) }

    /// Changes this pane made on disk: its own lists, then the other panes.
    /// Several at once (a marked set trashed) are applied in one go.
    func apply(_ changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        Bookmarks.shared.follow(changes)
        applyHere(changes)
        onFileChange?(changes)
    }

    /// Told about every change this pane makes on disk (the window hands it
    /// to the other pane, `adopt`).
    var onFileChange: (([FileChange]) -> Void)?

    /// Changes another pane made on disk: lists and history follow them, and
    /// so does the folder shown when it was moved, renamed or trashed (then
    /// the nearest folder around it that is still there opens).
    func adopt(_ changes: [FileChange]) {
        let keep = selectedEntry?.url
        applyHere(changes)
        if followFolder(through: changes) { return }
        dropWhatLeft(keeping: keep)
        // The picture shown full size went: back to the grid
        if mode == .detail, selectedMediaEntry == nil { mode = .grid }
    }

    /// The folder shown, after changes on disk: under its new path when it
    /// was moved or renamed, else the nearest folder around it still there
    /// when it was trashed. Returns whether it changed.
    @discardableResult
    private func followFolder(through changes: [FileChange]) -> Bool {
        guard let folderURL, !changes.isEmpty else { return false }
        if let moved = Self.through(changes, folderURL) {
            guard Self.canonicalPath(moved) != Self.canonicalPath(folderURL) else { return false }
            self.folderURL = moved
            defaults.set(moved.path, forKey: lastFolderKey)
            refresh()
        } else {
            var parent = Self.parentFolder(of: folderURL)
            while let candidate = parent, Self.through(changes, candidate) == nil { parent = Self.parentFolder(of: candidate) }
            // Not into the history: the folder left is gone
            if let parent { load(Location(folder: parent, query: "", selected: nil)) }
        }
        return true
    }

    /// Where a URL ends up after all the changes; nil when it is gone. The
    /// path is made canonical once, whatever the number of changes.
    static func through(_ changes: [FileChange], _ url: URL) -> URL? {
        FileChanges(changes).url(url)
    }

    private func applyHere(_ changes: [FileChange]) {
        // What the folders around the changes contain is no longer known.
        let affected = changes.flatMap(\.affectedFolders)
        let affectedSet = Set(affected)
        if !emptyFolders.isDisjoint(with: affectedSet) { emptyFolders.subtract(affectedSet) }
        FolderPreviewCache.shared.forget(affected)
        folderChanges += 1
        let lookup = FileChanges(changes)
        // What stays keeps its place; only what moved is put where it sorts now
        let order = entryOrder
        let keep = selectedEntry.flatMap { lookup.url($0.url) }
        let previous = selection
        if !marked.isEmpty { marked = Set(marked.compactMap { lookup.path($0) }) }
        allEntries = order.following(allEntries, lookup)
        for run in allSearches { run.apply(changes) }
        pendingResultSelection = pendingResultSelection.flatMap { lookup.url($0) }
        backStack = backStack.map { location in changes.reduce(location) { $1.apply(to: $0) } }
        forwardStack = forwardStack.map { location in changes.reduce(location) { $1.apply(to: $0) } }
        entries = order.following(entries, lookup)
        // The other files too: renamed in place, gone when trashed or moved
        // out of the folder shown
        if !otherFiles.isEmpty, let shown = folderPath {
            otherFiles = otherFiles.compactMap { file -> OtherFile? in
                guard let url = lookup.url(file.url), Self.canonicalPath(url.deletingLastPathComponent()) == shown else { return nil }
                return url == file.url ? file : OtherFile(url: url, byteSize: file.byteSize)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // Marks only on what is still listed (a mark no tile shows would
        // take F5 / F6 / the Trash away from the selection)
        if !marked.isEmpty { marked.formIntersection(entries.map { Self.canonicalPath($0.url) }) }
        keepSelection(index(of: keep)
            ?? (entries.isEmpty ? nil : previous.map { min($0, entries.count - 1) }))
        if slideshow != nil { applyToSlideshow(lookup) }
    }

    /// The slideshow's items follow the changes too: what was moved or
    /// renamed plays from its new place, what is gone leaves the show.
    private func applyToSlideshow(_ lookup: FileChanges) {
        guard var show = slideshow else { return }
        var items: [GridEntry] = []
        var counts: [Int] = []
        var index = show.index
        var start = 0
        for count in show.partCounts {
            var kept = 0
            for (offset, item) in show.items[start..<min(start + count, show.items.count)].enumerated() {
                if let url = lookup.url(item.url) {
                    items.append(url == item.url ? item : GridEntry(url: url, kind: item.kind, modDate: item.modDate, byteSize: item.byteSize))
                    kept += 1
                } else if start + offset < show.index {
                    index -= 1
                }
            }
            counts.append(kept)
            start += count
        }
        guard items.count != show.items.count || zip(items, show.items).contains(where: { $0.url != $1.url }) else { return }
        let shown = show.current.flatMap { lookup.url($0.url) }
        show.items = items
        show.partCounts = counts
        show.seen = Set(items.map { Self.canonicalPath($0.url) })
        show.index = items.isEmpty ? 0 : min(max(index, show.index < 0 ? -1 : 0), items.count - 1)
        slideshow = show
        // Nothing left and nothing more to come (another pane trashed it
        // all): the show ends, no black screen left behind
        if items.isEmpty, !show.loading { stopSlideshow(); return }
        // The item on screen went: the one now in its place gets its time
        if let current = show.current, current.url != shown { showSlideshowItem() }
    }

    // MARK: - Video control

    /// Decides from the player's real state, not from the last key press.
    func togglePlayPause() {
        guard let p = activePlayer else { return }
        let playing = p.isPlaying
        // A pause asked for here is a pause, even in the video's last moments
        pausedByKey = playing
        if playing { p.pause() } else { p.play() }
        videoPaused = playing
    }

    /// The player's next "not playing" is the pause asked for with Space,
    /// not the video's end.
    private var pausedByKey = false

    /// Called by the players when playback starts, pauses or ends — also
    /// through their own on-screen controls.
    func playbackStateChanged(_ player: PlaybackControl, isPlaying: Bool) {
        guard player === activePlayer else { return }
        videoPaused = !isPlaying
        let asked = pausedByKey
        pausedByKey = false
        // In a slideshow a video that played to its end hands over to the next item.
        if slideshow != nil, !isPlaying, !asked, (player.progress ?? 0) >= 0.99 {
            slideshowStep(+1)
        }
    }

    /// The photo or video on screen: the slideshow's, or the full view's.
    var shownMediaEntry: GridEntry? {
        if let slideshow { return slideshow.current }
        return mode == .detail ? selectedMediaEntry : nil
    }

    /// One ←/→ step in a video: a tenth of its length.
    static let videoJump = 0.1

    /// The key being handled repeats (held down).
    private var keyRepeating = false
    /// When the item on screen came up: a video's length is unknown at first.
    private var shownSince = Date()
    /// How long a video may take to report its length before ←/→ count it
    /// as unplayable and page on.
    var lengthGrace: TimeInterval = 1.5

    /// ←/→ in the full view. Images: previous/next item. Videos: jump a tenth
    /// of the length; past the end → next item, at the start → previous one.
    /// So one key pages through images and skims through videos.
    func skim(_ direction: Int) {
        guard shownMediaEntry?.kind == .video else { page(direction); return }
        guard let player = activePlayer, let progress = player.progress else {
            // Length not known yet: wait for it (a key held down would race
            // through video after video); only one that never gets a length
            // is left with ←/→, and not by a repeating key.
            // A video in an archive with no player yet is still being unpacked
            let opening = activePlayer == nil && shownMediaEntry.map { ArchivePath.isInside($0.url) } == true
            if !keyRepeating, !opening, Date().timeIntervalSince(shownSince) > lengthGrace { page(direction) }
            return
        }
        if direction > 0 {
            let target = progress + Self.videoJump
            // At the end: on to the next item, but not with a key held down
            if target >= 0.999 { if !keyRepeating { page(+1) } } else { player.seek(toProgress: target) }
        } else {
            // Close to the start counts as the start, so a playing video
            // doesn't keep catching the key.
            if progress < Self.videoJump / 4 { if !keyRepeating { page(-1) } }
            else { player.seek(toProgress: max(progress - Self.videoJump, 0)) }
        }
    }

    /// ⇧←/⇧→ in a video: a fine step of a hundredth of its length (←/→
    /// jump a tenth), to find a place exactly. Stays in the video at its
    /// start and end (no paging).
    static let fineVideoJump = 0.01

    func fineSkim(_ direction: Int) {
        guard shownMediaEntry?.kind == .video, let player = activePlayer,
              let progress = player.progress else { return }
        let target = min(max(progress + Double(direction) * Self.fineVideoJump, 0), 1)
        player.seek(toProgress: direction > 0 ? min(target, 0.999) : target)
    }

    /// Previous / next item: in the slideshow, or in the full view.
    func page(_ direction: Int) {
        if slideshow != nil { slideshowStep(direction) } else { stepMedia(direction) }
    }

    // MARK: - Slideshow

    /// Start a slideshow. Over `folder` if given (a folder tile's context
    /// menu, the drop zone); otherwise over the search results while
    /// searching, else the current folder — always the whole of it (▶︎ means
    /// "this folder"). It starts at the item the full view shows, or at the
    /// file / in the folder the user selected in the grid (not the tile
    /// selected on opening a folder), and goes on from there, starting over
    /// at the end.
    func startSlideshow(over folder: URL? = nil, startingAt start: URL? = nil) {
        stopSlideshow()
        var roots: [GridEntry] = []
        if let folder {
            roots = [GridEntry(url: folder, kind: .folder)]
        } else if isFiltering {
            roots = entries.filter { $0.kind != .parent }
        } else if let folderURL {
            roots = [GridEntry(url: folderURL, kind: .folder)]
        }
        guard !roots.isEmpty else { NSSound.beep(); return }
        var show = Slideshow()
        show.startAt = start ?? (mode == .detail ? selectedMediaEntry?.url : nil)
        // From the grid (▶︎, S): at the file or in the folder the user selected
        if start == nil, folder == nil, mode == .grid, selectionChosen,
           let chosen = selectedEntry, chosen.kind != .parent {
            if chosen.isMedia { show.startAt = chosen.url }
            else if chosen.kind == .folder { show.startInside = Self.canonicalPath(chosen.url) + "/" }
        }
        if show.waitingForStart { show.index = -1 }   // shown once the start has arrived
        let id = show.id
        searchFocused = false
        slideshow = show
        slideshowEnteredFullScreen = setFullScreen(true)
        let key = sortKey, ascending = sortAscending
        let startAt = show.startAt.map(Self.canonicalPath), startInside = show.startInside
        slideshowWalk = Task { [weak self] in
            // The show's parts: each search result; over one folder its own
            // media, then each subfolder
            enum Part { case media([GridEntry]), folder(URL) }
            var parts: [Part] = []
            if roots.count == 1, roots[0].kind == .folder {
                let contents = await Self.scan(roots[0].url)
                var captured: [URL: Date] = [:]
                if key == .captured { captured = await Self.captureDates(of: contents.filter(\.isMedia).map(\.url)) }
                let sorted = Self.sortEntries(contents, key: key, ascending: ascending, captured: captured)
                parts = [.media(sorted.filter(\.isMedia))]
                    + sorted.filter { $0.kind == .folder && !$0.name.hasPrefix(".") }.map { .folder($0.url) }
            } else {
                parts = roots.map { $0.isMedia ? .media([$0]) : .folder($0.url) }
            }
            guard !Task.isCancelled else { return }
            // The part holding the start first: no waiting for the parts before it
            func holdsStart(_ part: Part) -> Bool {
                switch part {
                case .media(let items): return startAt.map { s in items.contains { Self.canonicalPath($0.url) == s } } ?? false
                case .folder(let url):
                    let inside = Self.canonicalPath(url) + "/"
                    return startAt?.hasPrefix(inside) == true || startInside?.hasPrefix(inside) == true
                }
            }
            let first = parts.firstIndex(where: holdsStart) ?? 0
            self?.setSlideshowParts(parts.count, id: id)
            for number in [first] + parts.indices.filter({ $0 != first }) {
                switch parts[number] {
                case .media(let items):
                    if !items.isEmpty { self?.addToSlideshow(items, id: id, part: number) }
                case .folder(let url):
                    await Self.walkForSlideshow(url, key: key, ascending: ascending) { batch in
                        self?.addToSlideshow(batch, id: id, part: number)
                    }
                }
                if Task.isCancelled { return }
            }
            if !Task.isCancelled { self?.slideshowWalkFinished(id: id) }
        }
    }

    private func setSlideshowParts(_ count: Int, id: UUID) {
        guard var show = slideshow, show.id == id else { return }
        show.partCounts = Array(repeating: 0, count: max(count, 1))
        slideshow = show
    }

    /// Depth first: a folder's own media in the sort order, then each of its
    /// subfolders in the sort order. Hands over one batch per folder.
    nonisolated static func walkForSlideshow(_ folder: URL, key: SortKey, ascending: Bool,
                                             found: @MainActor ([GridEntry]) -> Void) async {
        guard !Task.isCancelled else { return }
        let contents = await scan(folder)
        var captured: [URL: Date] = [:]
        if key == .captured { captured = await captureDates(of: contents.filter(\.isMedia).map(\.url)) }
        guard !Task.isCancelled else { return }
        let sorted = sortEntries(contents, key: key, ascending: ascending, captured: captured)
        let media = sorted.filter(\.isMedia)
        if !media.isEmpty { await found(media) }
        let folders = sorted.filter { $0.kind == .folder && !$0.name.hasPrefix(".") }
        let links = await Blocking.run { Set(folders.filter { isLink($0.url) }.map(\.url)) }
        for sub in folders where !links.contains(sub.url) {
            await walkForSlideshow(sub.url, key: key, ascending: ascending, found: found)
        }
    }

    private func addToSlideshow(_ batch: [GridEntry], id: UUID, part: Int = 0) {
        guard var show = slideshow, show.id == id else { return }   // from a cancelled walk
        let new = batch.filter { show.seen.insert(Self.canonicalPath($0.url)).inserted }
        guard !new.isEmpty else { return }
        let wasEmpty = show.items.isEmpty
        // After the items of the parts before this one
        let part = min(part, show.partCounts.count - 1)
        let offset = show.partCounts[...part].reduce(0, +)
        let atEnd = offset == show.items.count
        show.items.insert(contentsOf: new, at: offset)
        show.partCounts[part] += new.count
        // The item on screen keeps its place in the show
        if show.index >= offset, !wasEmpty { show.index += new.count }
        var moved = wasEmpty && !show.waitingForStart
        if let startAt = show.startAt, let i = new.firstIndex(where: { Self.samePath($0.url, startAt) }) {
            show.index = offset + i   // the item to start at has arrived
            show.startAt = nil
            moved = true
        } else if let inside = show.startInside,
                  let i = new.firstIndex(where: { Self.canonicalPath($0.url).hasPrefix(inside) }) {
            show.index = offset + i   // the first item of the folder to start in
            show.startInside = nil
            moved = true
        } else if show.waitingForMore, atEnd {
            show.index = offset
            moved = true
        }
        if moved { show.waitingForMore = false }
        slideshow = show
        if moved { showSlideshowItem() }
    }

    private func slideshowWalkFinished(id: UUID) {
        guard var show = slideshow, show.id == id else { return }
        show.loading = false
        // The item to start at never came (gone, or an empty folder): from the first
        let neverStarted = show.index < 0
        show.startAt = nil
        show.startInside = nil
        if neverStarted { show.index = 0 }
        let wrap = show.waitingForMore
        show.waitingForMore = false
        slideshow = show
        if show.items.isEmpty { stopSlideshow(); NSSound.beep() } else if wrap { slideshowStep(+1) }
        else if neverStarted { showSlideshowItem() }
    }

    /// Next / previous item; past the end it starts over (once the walk is done).
    func slideshowStep(_ delta: Int) {
        guard var show = slideshow, !show.items.isEmpty else { return }
        show.startAt = nil   // the user (or the show) has moved on
        show.startInside = nil
        var next = show.index + delta
        if next >= show.items.count {
            if show.loading {
                // Past the end while subfolders are still read: the next batch moves on
                show.waitingForMore = true
                slideshow = show
                return
            }
            next = 0
        }
        if next < 0 { next = show.loading ? 0 : show.items.count - 1 }
        // A show of one video: it stays on screen, so it plays again from the start
        let again = next == show.index && show.current?.kind == .video
        show.index = next
        show.waitingForMore = false
        slideshow = show
        showSlideshowItem()
        if again { activePlayer?.play() }
    }

    /// Show the current item: pictures move on after the interval, videos
    /// when they end (`playbackStateChanged`).
    private func showSlideshowItem() {
        slideshowTimer?.cancel()
        resetTransforms()
        guard let show = slideshow, let item = show.current else { return }
        if item.kind == .video {
            // A video moves on when it ends. One that can't be played (it never
            // gets a length) is skipped after a while instead of halting the show.
            let check = slideshowVideoCheck
            slideshowTimer = Task { [weak self] in
                var unknown = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: check)
                    guard !Task.isCancelled, let self, self.slideshow?.current == item else { return }
                    let player = self.activePlayer
                    let stuck = player?.progress == nil && player?.playsWithoutLength != true
                    unknown = stuck ? unknown + 1 : 0
                    // A video in an archive gets its player only once enough
                    // of it is unpacked (its index may sit at the end): longer
                    let patience = player == nil && ArchivePath.isInside(item.url) ? 30 : 4
                    if unknown >= patience { self.slideshowStep(+1); return }
                }
            }
            return
        }
        guard !show.paused else { return }
        let interval = slideshowInterval
        slideshowTimer = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, self.slideshow != nil else { return }
            self.slideshowStep(+1)
        }
    }

    /// Space: pause or resume. Videos pause through their player.
    func toggleSlideshowPause() {
        guard var show = slideshow else { return }
        if show.current?.kind == .video { togglePlayPause(); return }
        show.paused.toggle()
        slideshow = show
        showSlideshowItem()
    }

    func stopSlideshow() {
        slideshowTimer?.cancel()
        slideshowWalk?.cancel()
        slideshowTimer = nil
        slideshowWalk = nil
        guard slideshow != nil else { return }
        slideshow = nil
        if slideshowEnteredFullScreen { _ = setFullScreen(false) }
        slideshowEnteredFullScreen = false
    }

    /// Keys while the slideshow runs.
    private func handleSlideshowKey(_ key: KeyInput, command: Bool, shift: Bool) -> Bool {
        switch key {
        case .escape, .backspace, .enter:
            stopSlideshow(); return true
        case .space:
            toggleSlideshowPause(); return true
        case .left, .right:
            let direction = key == .right ? 1 : -1
            if command { slideshowStep(direction) } else if shift { fineSkim(direction) } else { skim(direction) }
            return true
        case .up, .down:
            return verticalKey(up: key == .up)
        case .char(let raw):
            let c = Character(raw.lowercased())   // also with Shift or Caps Lock
            switch c {
            case "s" where !command: stopSlideshow(); return true
            // No search, history or file actions while the hidden grid's
            // selection isn't what's on screen
            case "f" where command, "[" where command, "]" where command, "a" where command: return true
            default: return handleCharacter(c, command: command)   // F, I, E, A, K, zoom: as in the full view
            }
        default:
            return false
        }
    }

    // MARK: - Window

    func toggleFullScreen() {
        guard let window = hostWindow else { return }
        _ = FullScreenSwitch.shared.set(!FullScreenSwitch.shared.isOrBecomesFullScreen(window), window: window)
    }
}

/// Full screen on request, also while the window is still on its way in or
/// out: AppKit ignores a toggle during that animation (an empty slideshow
/// ends at once), so the last request is carried out once it has ended.
/// Each window has its own animation and requests: one window going into
/// full screen never holds back or carries out another's.
@MainActor
final class FullScreenSwitch {
    static let shared = FullScreenSwitch()

    /// One window's animation and the request waiting for its end.
    private struct State {
        /// Where the window is going while it animates, since when.
        var moving: (to: Bool, since: Date)?
        var wanted: Bool?
        /// Where a retry after an animation is still taking the window; a
        /// new request cancels it.
        var retrying: Bool?
        var isEmpty: Bool { moving == nil && wanted == nil && retrying == nil }
    }
    private var states: [ObjectIdentifier: State] = [:]
    private var observers: [NSObjectProtocol] = []

    private func state(_ window: NSWindow) -> State { states[ObjectIdentifier(window)] ?? State() }
    private func update(_ window: NSWindow, _ change: (inout State) -> Void) {
        var state = state(window)
        change(&state)
        states[ObjectIdentifier(window)] = state.isEmpty ? nil : state
    }

    /// Where the window is going while it animates. An animation that never
    /// reported its end (it failed) stops counting after a while.
    private func movingTo(_ window: NSWindow) -> Bool? {
        guard let moving = state(window).moving, Date().timeIntervalSince(moving.since) < 6 else { return nil }
        return moving.to
    }

    private init() {
        let center = NotificationCenter.default
        let starts: [(Notification.Name, Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)
        ]
        for (name, target) in starts {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    BrowserModel.testLog("full screen: will \(target ? "enter" : "exit")")
                    guard let window else { return }
                    FullScreenSwitch.shared.update(window) { $0.moving = (target, Date()) }
                }
            })
        }
        let ends: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification
        ]
        for name in ends {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { FullScreenSwitch.shared.ended(window) }
            })
        }
        // A closed window's requests go with it (its identifier may be reused)
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window else { return }
                FullScreenSwitch.shared.states[ObjectIdentifier(window)] = nil
            }
        })
    }

    func isOrBecomesFullScreen(_ window: NSWindow) -> Bool {
        state(window).wanted ?? movingTo(window) ?? window.styleMask.contains(.fullScreen)
    }

    /// Returns whether the window ends up changed by this request.
    func set(_ on: Bool, window: NSWindow?) -> Bool {
        BrowserModel.testLog("full screen: set \(on), window \(window != nil), moving \(String(describing: window.flatMap(movingTo))), is \(window?.styleMask.contains(.fullScreen) ?? false)")
        guard let window else { return false }
        if let movingTo = movingTo(window) {
            update(window) { $0.wanted = on }
            return movingTo != on
        }
        // A retry still on its way elsewhere: cancelled, the window stays as asked
        if let retrying = state(window).retrying {
            update(window) { $0.retrying = nil }
            if retrying != on, window.styleMask.contains(.fullScreen) == on { return true }
        }
        guard window.styleMask.contains(.fullScreen) != on else { return false }
        // Moving from now on: AppKit announces the animation only later.
        update(window) { $0.moving = (on, Date()) }
        window.toggleFullScreen(nil)
        return true
    }

    private func ended(_ window: NSWindow?) {
        guard let window else { return }
        let wanted = state(window).wanted
        BrowserModel.testLog("full screen: ended, wanted \(String(describing: wanted)), is \(window.styleMask.contains(.fullScreen))")
        update(window) { $0.moving = nil; $0.wanted = nil }
        guard let wanted else { return }
        apply(wanted, to: window, tries: 4)
    }

    /// Right as the animation ends AppKit still ignores a toggle: asked a
    /// moment later, and again until the window is where it was asked to be.
    private func apply(_ on: Bool, to window: NSWindow, tries: Int) {
        update(window) { $0.retrying = on }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                // A newer request takes over
                let state = self.state(window)
                guard state.retrying == on, self.movingTo(window) == nil, state.wanted == nil else { return }
                guard window.styleMask.contains(.fullScreen) != on else { self.update(window) { $0.retrying = nil }; return }
                BrowserModel.testLog("full screen: toggling to \(on), \(tries) tries left")
                window.toggleFullScreen(nil)
                if tries > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated {
                            let state = self.state(window)
                            guard state.retrying == on, self.movingTo(window) == nil, state.wanted == nil,
                                  window.styleMask.contains(.fullScreen) != on else { self.update(window) { $0.retrying = nil }; return }
                            self.apply(on, to: window, tries: tries - 1)
                        }
                    }
                } else {
                    self.update(window) { $0.retrying = nil }
                }
            }
        }
    }
}

/// AVKit playback, driven by the keyboard. Reports state changes from any
/// source (keys, the player's controls, the end of the video) to the model.
@MainActor
final class AVPlaybackControl: PlaybackControl {
    let player: AVPlayer
    /// Feeds the player a video inside an archive (held here: the asset
    /// holds it weakly).
    var resourceLoader: ArchiveResourceLoader?
    private var observation: NSKeyValueObservation?

    init(player: AVPlayer, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void = { _, _ in }) {
        self.player = player
        observation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self else { return }
                // A look set after the last frame was drawn (just before the
                // end) reaches the picture it stops on
                if !playing, self.enhancer?.isStale == true { self.redrawIfPaused() }
                onStateChange(self, playing)
            }
        }
    }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    func setVolume(_ volume: Double) { player.volume = Float(volume) }

    var videoSize: CGSize? {
        let size = player.currentItem?.presentationSize ?? .zero
        return size.width > 0 && size.height > 0 ? size : nil
    }

    func streamFacts() async -> StreamFacts? {
        guard let asset = player.currentItem?.asset else { return nil }
        return await StreamFacts.of(asset)
    }

    /// At the end, playing starts over.
    func play() {
        if let item = player.currentItem {
            let duration = CMTimeGetSeconds(item.duration)
            if duration.isFinite, duration > 0, CMTimeGetSeconds(player.currentTime()) >= duration - 0.05 {
                player.seek(to: .zero)
            }
        }
        player.play()
    }

    func pause() { player.pause() }

    private var composition: AVVideoComposition?
    private var enhancer: VideoEnhancer?
    private var compositionTask: Task<Void, Never>?
    /// Where auto enhance's look goes (the model, for the sliders).
    var onAutoLook: @MainActor (PlaybackControl, Look) -> Void = { _, _ in }

    /// One video composition per video, made the first time a look is
    /// asked for; it reads the current look for every frame. Off, the
    /// composition is taken away so the video plays unfiltered.
    func setEnhancement(_ enhancement: Enhancement) {
        guard let item = player.currentItem else { return }
        BrowserModel.testLog("avkit enhancement \(enhancement), composition \(composition != nil), attached \(item.videoComposition != nil), playing \(isPlaying)")
        if enhancement == .off {
            compositionTask?.cancel()
            compositionTask = nil
            enhancer?.set(.off)
            item.videoComposition = nil
            redrawIfPaused()
            return
        }
        if let enhancer, let composition {
            enhancer.set(enhancement)
            if item.videoComposition == nil {
                // Put back after "off": a paused item takes it only a moment
                // later, so a redraw at once would still draw without it.
                item.videoComposition = composition
                redrawIfPaused(after: .milliseconds(100))
            } else {
                redrawIfPaused()
            }
            return
        }
        let enhancer = self.enhancer ?? VideoEnhancer(report: { [weak self] look in
            Task { @MainActor in
                guard let self else { return }
                self.onAutoLook(self, look)
            }
        })
        self.enhancer = enhancer
        enhancer.set(enhancement)
        guard compositionTask == nil else { return }
        let asset = item.asset
        compositionTask = Task { [weak self] in
            // How long a frame lasts: a redraw stays within the frame shown
            if self?.frameDuration == nil, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let duration = try? await track.load(.minFrameDuration), duration.seconds > 0, duration.seconds.isFinite {
                self?.frameDuration = duration.seconds
            }
            let made = try? await AVVideoComposition.videoComposition(with: asset) { request in
                enhancer.process(request)
            }
            guard let self, !Task.isCancelled else { return }
            self.compositionTask = nil   // also after a failure: the next change tries again
            guard let made else { return }
            self.composition = made
            item.videoComposition = made
            self.redrawIfPaused()   // a paused item doesn't draw its frame again by itself
        }
    }

    /// Where the last nudge went ahead to (the next goes back from there).
    private var nudgedAhead: CMTime?
    /// The video's shortest frame duration, once known; redraws then seek
    /// to two points inside the frame on screen, never across its edge.
    private var frameDuration: Double?
    private var nudgeLater = false

    /// A paused video shows a new look only once its frame is drawn again.
    /// A seek to the very time it stands at reuses the picture already
    /// composed, so the seek goes 1/600 s ahead, and from there back to where
    /// it stood, and so on: always within the frame shown (a frame starts at
    /// the time it stands at; going back from there would show the one
    /// before). Seeks in quick succession (a slider dragged), or a
    /// composition put back just now, can still leave the frame drawn with
    /// an earlier look: a stale frame is drawn again, a little later each time.
    private func redrawIfPaused(after delay: Duration = .zero, attempts: Int = 6) {
        guard !isPlaying else { return }
        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !self.isPlaying else { return }
            let now = self.player.currentTime()
            if let frame = self.frameDuration, now.seconds.isFinite {
                // A quarter and a half into the frame shown, by turns
                let start = (now.seconds / frame).rounded(.down) * frame
                self.nudgeLater.toggle()
                let target = CMTime(seconds: start + frame * (self.nudgeLater ? 0.5 : 0.25), preferredTimescale: 600_000)
                BrowserModel.testLog("avkit redraw at \(target.seconds)")
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    guard finished else { return }
                    Task { @MainActor in
                        guard let self, attempts > 1, self.enhancer?.isStale == true else { return }
                        self.redrawIfPaused(after: .milliseconds(150), attempts: attempts - 1)
                    }
                }
                return
            }
            let step = CMTime(value: 1, timescale: 600)
            // (compared loosely: the time read back may come in another timescale)
            let back = self.nudgedAhead.map { abs($0.seconds - now.seconds) < 1.0 / 1200 } ?? false
            var target = back ? CMTimeSubtract(now, step) : CMTimeAdd(now, step)
            if let duration = self.duration, target.seconds > duration { target = CMTimeSubtract(now, step) }
            if CMTimeCompare(target, .zero) < 0 { target = CMTimeAdd(now, step) }
            self.nudgedAhead = CMTimeCompare(target, now) > 0 ? target : nil
            BrowserModel.testLog("avkit redraw at \(target.seconds)")
            self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                BrowserModel.testLog("avkit redraw finished \(finished)")
                guard finished else { return }   // a newer seek takes over
                Task { @MainActor in
                    guard let self, attempts > 1, self.enhancer?.isStale == true else { return }
                    self.redrawIfPaused(after: .milliseconds(150), attempts: attempts - 1)
                }
            }
        }
    }

    private var duration: Double? {
        guard let item = player.currentItem else { return nil }
        let seconds = CMTimeGetSeconds(item.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    var progress: Double? {
        guard let duration else { return nil }
        return min(max(CMTimeGetSeconds(player.currentTime()) / duration, 0), 1)
    }

    var lengthSeconds: Double? { duration }

    func seek(toProgress progress: Double) {
        guard let duration else { return }
        let ended = !isPlaying && (self.progress ?? 0) >= 0.999
        player.seek(to: CMTime(seconds: duration * min(max(progress, 0), 1), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if ended { player.play() }
    }
}

/// ".ts" names TypeScript code far more often than an MPEG transport stream
/// (a TV or IPTV recording): such a file is a video only when its first bytes
/// show a transport stream (a sync byte every 188 or 192 bytes, as VLC opens
/// it: `VLCSafety.container`). Each file is read once; the answer is kept by
/// its path, size and date, so a file written anew is read again.
final class TransportStreams: @unchecked Sendable {
    static let shared = TransportStreams()
    private let lock = NSLock()
    private var known: [String: (stamp: String, video: Bool)] = [:]
    /// Kept answers at most (a folder of code has many .ts files).
    private let limit = 20_000

    func isVideo(_ url: URL) -> Bool {
        // A path through an archive has no first bytes to read without unpacking
        guard !ArchivePath.isInside(url) else { return false }
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        let stamp = "\(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        if let answer = lock.withLock({ known[url.path] }), answer.stamp == stamp { return answer.video }
        let video = VLCSafety.head(of: url).flatMap(VLCSafety.container(in:))?.demux == "ts"
        lock.withLock {
            if known.count >= limit { known.removeAll(keepingCapacity: true) }
            known[url.path] = (stamp, video)
        }
        return video
    }
}
