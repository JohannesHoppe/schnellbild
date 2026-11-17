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
    /// A folder listed through a symbolic link: the folder it points to.
    /// `url` is the link itself, so trash, rename, move and marks act on the
    /// link (as in the Finder), and opening it goes to this folder.
    var linkTarget: URL?
    /// A download not finished: its name has an in-progress ending
    /// ("x.mp4.part", `DownloadName`). By the name, worked out once.
    let isDownloading: Bool
    /// An entry of an archive read only in part (a download not finished, a
    /// volume missing) whose data runs past what is there.
    var isIncomplete = false

    /// The date a tile's preview is made for: a download still growing
    /// changes its date with every write, so its preview is made again at
    /// most every 30 seconds.
    var previewDate: Date? {
        guard isDownloading, let modDate else { return modDate }
        return Date(timeIntervalSinceReferenceDate: (modDate.timeIntervalSinceReferenceDate / 30).rounded(.down) * 30)
    }

    /// What the tile's and row's small arrow says, nil for a whole file.
    var unfinishedNote: String? {
        if isDownloading { return String(localized: "Download not finished") }
        return isIncomplete ? String(localized: "Incomplete") : nil
    }

    init(url: URL, kind: Kind, modDate: Date? = nil, byteSize: Int? = nil, linkTarget: URL? = nil) {
        self.url = url
        self.kind = kind
        self.modDate = modDate
        self.byteSize = byteSize
        self.linkTarget = linkTarget
        isArchive = linkTarget == nil && Self.isArchive(url, kind: kind)
        isDownloading = kind != .parent && DownloadName.isPartial(url.lastPathComponent)
    }

    var id: URL { url }
    var name: String { kind == .parent ? ".." : url.lastPathComponent }
    var isMedia: Bool { kind == .image || kind == .video }
    /// Where opening a folder goes: the folder a link points to, else the
    /// folder itself.
    var browseURL: URL { linkTarget ?? url }

    /// The same entry at another place (a rename or move); a link keeps
    /// pointing where it points, or follows its folder moved by the app.
    func moved(to new: URL, target: URL? = nil) -> GridEntry {
        GridEntry(url: new, kind: kind, modDate: modDate, byteSize: byteSize, linkTarget: target ?? linkTarget)
    }
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
    /// Where the video stands, in seconds; nil while not known (the pane
    /// remembers it when the user moves on, `PlaybackPositions`).
    var playedSeconds: Double? { get }
    /// The codecs, once the player has opened the video (the Inspector).
    func streamFacts() async -> StreamFacts?
    /// The video's sound and subtitle tracks and which are on, once the
    /// player knows them; it reports changes through
    /// `BrowserModel.tracksChanged`.
    var tracks: VideoTracks { get }
    func selectAudioTrack(_ id: Int)
    /// nil: no subtitles.
    func selectSubtitleTrack(_ id: Int?)
    /// The speed, 1 normal (`PlaybackSpeed.steps`); kept for every playing
    /// after it, also from the start again.
    func setSpeed(_ speed: Double)
    /// The volume (0 … 1) and speed the player itself reports, nil while it
    /// can't say (the UI tests read them).
    var playerVolume: Double? { get }
    var playerSpeed: Double? { get }
}

extension PlaybackControl {
    var playerVolume: Double? { nil }
    var playerSpeed: Double? { nil }
    var playsWithoutLength: Bool { false }
    var videoSize: CGSize? { nil }
    var lengthSeconds: Double? { nil }
    var playedSeconds: Double? { nil }
    func streamFacts() async -> StreamFacts? { nil }
    var tracks: VideoTracks { VideoTracks() }
    func selectAudioTrack(_ id: Int) {}
    func selectSubtitleTrack(_ id: Int?) {}
    func setSpeed(_ speed: Double) {}
}

/// Side effects on the file system and the workspace. Injectable, so tests
/// can observe them without touching Finder, the Trash, or modal alerts.
struct FileActions {
    var reveal: @MainActor (URL) -> Void
    var openInDefaultApp: @MainActor (URL) -> Void
    /// An other file (not a picture, video or archive): only documents
    /// that hold no program, web locations only to web addresses.
    var openOtherFile: @MainActor (URL) -> Void = { if !LiveFiles.openOtherFile($0) { NSSound.beep() } }
    /// The names of what goes; `detail` says what goes with it (a folder's
    /// contents, an archive's parts).
    var confirmTrash: @MainActor (_ names: [String], _ detail: String) -> Bool
    /// Returns where the item now lies in the Trash (for Undo), if known.
    var trash: @MainActor (URL) throws -> URL?
    var move: @MainActor (_ from: URL, _ to: URL) throws -> Void
    /// Into another folder: moved on the same volume, copied to another
    /// (as the Finder does). Returns whether it was moved.
    var transfer: @MainActor (_ from: URL, _ to: URL) throws -> Bool
    var createFolder: @MainActor (URL) throws -> Void
    var copy: @MainActor (_ from: URL, _ to: URL) throws -> Void
    /// A name already taken in the target folder: keep both (the new one
    /// gets a number), skip it, or stop the whole move; `more` says whether
    /// other names may be taken too (the answer can then apply to all).
    var askKeepBoth: @MainActor (_ name: String, _ folder: String, _ more: Bool) -> ConflictAnswer
    /// Whether `target` exists as an item other than `source`. On a
    /// case-insensitive volume "Photos" is the same item as "photos"; on a
    /// case-sensitive one (many NAS shares) it may be a different folder.
    var conflicts: @MainActor (_ target: URL, _ source: URL) -> Bool
    /// Tells why an action failed (a share without a Trash, no permission),
    /// in the system's words and language.
    var report: @MainActor (Error) -> Void
    /// An Undo or Redo failed: tells why and, when part of the step is left
    /// (`canKeep`), whether to keep it to try again (true) or forget it so
    /// the steps before it can be reached.
    var keepFailedUndo: @MainActor (_ error: Error, _ canKeep: Bool) -> Bool = { error, canKeep in
        guard canKeep else { NSAlert(error: error).runModal(); return false }
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.informativeText = String(localized: "Keep: try it again later, before the earlier actions. Forget: go on with the earlier actions.")
        alert.addButton(withTitle: String(localized: "Keep"))
        alert.addButton(withTitle: String(localized: "Forget"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Where moves and copies into folders run: the live actions off the
    /// main thread (a copy to a share takes long) through `LiveFiles`, which
    /// is what their closures call too; others (a test's spy) through their
    /// own closures.
    var runsOffMain = false

    /// Carries out the steps of a move; per step the files it moved or
    /// copied (also when a later part of a split archive failed) and why it
    /// stopped.
    @MainActor
    func run(_ steps: [BrowserModel.TransferStep], _ how: BrowserModel.Transfer) async -> [TransferOutcome] {
        if runsOffMain {
            return await Blocking.run {
                steps.map { Self.perform($0, how, move: LiveFiles.move, transfer: LiveFiles.transfer, copy: LiveFiles.copy) }
            }
        }
        return steps.map { Self.perform($0, how, move: move, transfer: transfer, copy: copy) }
    }

    private static func perform(_ step: BrowserModel.TransferStep, _ how: BrowserModel.Transfer,
                                move: (URL, URL) throws -> Void, transfer: (URL, URL) throws -> Bool,
                                copy: (URL, URL) throws -> Void) -> TransferOutcome {
        var outcome = TransferOutcome()
        files: for (file, to) in step.files {
            do {
                let moved: Bool
                switch how {
                case .asFinder: moved = try transfer(file, to)
                case .copy:     try copy(file, to); moved = false
                case .move:     try move(file, to); moved = true
                }
                outcome.done.append(TransferredFile(from: file, to: to, moved: moved,
                                                    identity: ItemIdentity.of(to, withContents: !moved)))
            } catch TransferError.originalKept(let reason) {
                // Copied to another volume, the original still there: a copy
                outcome.done.append(TransferredFile(from: file, to: to, moved: false, identity: ItemIdentity.of(to, withContents: true)))
                outcome.failed = (file.lastPathComponent, TransferError.originalKept(reason))
                break files
            } catch {
                outcome.failed = (file.lastPathComponent, error)
                break files
            }
        }
        return outcome
    }

    static let live = FileActions(
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        openInDefaultApp: { LiveFiles.openWithDefaultApp($0) },
        confirmTrash: { names, detail in
            let alert = NSAlert()
            if names.count == 1 {
                alert.messageText = String(localized: "Move “\(names[0])” to the Trash?")
                alert.informativeText = detail
            } else {
                // Counted; the names (the first ten) under it
                alert.messageText = String(localized: "Move \(names.count) items to the Trash?")
                let listed = names.prefix(10).joined(separator: ", ") + (names.count > 10 ? ", …" : "")
                alert.informativeText = listed + "\n\n" + detail
            }
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
        askKeepBoth: { name, folder, more in
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(name)” already exists in “\(folder)”.")
            alert.informativeText = String(localized: "Keep both: the new one gets a number. Skip: it stays where it is. Cancel: nothing is moved or copied.")
            alert.addButton(withTitle: String(localized: "Keep Both"))
            alert.addButton(withTitle: String(localized: "Skip"))
            alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
            if more {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = String(localized: "Apply to all")
            }
            let choice: ConflictAnswer.Choice = switch alert.runModal() {
            case .alertFirstButtonReturn: .keepBoth
            case .alertSecondButtonReturn: .skip
            default: .cancel
            }
            return ConflictAnswer(choice: choice, forAll: alert.suppressionButton?.state == .on)
        },
        conflicts: { LiveFiles.conflicts($0, $1) },
        report: { NSAlert(error: $0).runModal() },
        runsOffMain: true
    )
}

/// The answer to a name taken in the target folder.
struct ConflictAnswer {
    enum Choice { case keepBoth, skip, cancel }
    var choice: Choice
    /// For every other name taken in this move too.
    var forAll = false
}

/// A file a move or copy carried out, and the item it made (for Undo).
struct TransferredFile: Sendable {
    let from: URL
    let to: URL
    let moved: Bool
    let identity: ItemIdentity?
}

/// What one item of a move did: its files carried out (a split archive's
/// parts in order, up to one that failed), and the one that failed.
struct TransferOutcome: Sendable {
    var done: [TransferredFile] = []
    var failed: (name: String, error: Error)?
}

enum TransferError: LocalizedError {
    /// Copied to another volume for a move; the original couldn't be removed.
    case originalKept(String)

    var errorDescription: String? {
        switch self {
        case .originalKept(let reason): return String(localized: "Copied, but the original couldn't be removed: \(reason)")
        }
    }
}

/// What a move or copy couldn't do, item by item (what could be done was
/// done and can be undone).
struct TransferFailure: LocalizedError {
    let failures: [(name: String, reason: String)]

    var errorDescription: String? { String(localized: "Not everything was moved or copied.") }
    var recoverySuggestion: String? {
        failures.map { String(localized: "“\($0.name)”: \($0.reason)") }.joined(separator: "\n")
    }
}

/// Copies being written under their temporary names in this process: a
/// listing that meets one leaves it alone.
final class PartialCopies: @unchecked Sendable {
    static let shared = PartialCopies()
    private let lock = NSLock()
    private var paths: Set<String> = []

    func begin(_ url: URL) { lock.withLock { _ = paths.insert(url.standardizedFileURL.path) } }
    func end(_ url: URL) { lock.withLock { _ = paths.remove(url.standardizedFileURL.path) } }
    func isRunning(_ url: URL) -> Bool { lock.withLock { paths.contains(url.standardizedFileURL.path) } }
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

    /// The item behind links and aliases, if it may be opened at all. A
    /// link or alias must lead to a file of its own extension ("Photos.zip"
    /// pointing to "setup.pkg" is refused). Archives are only the formats the
    /// grid opens (zip, rar, 7z and their comic forms): installer packages,
    /// disk images, xip and Apple archives count as archives to the system
    /// too, and opening them installs or mounts something.
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
        if target.lastPathComponent != url.lastPathComponent,
           target.pathExtension.lowercased() != url.pathExtension.lowercased() { return nil }
        if refusedTypes.contains(where: type.conforms(to:)) || refusedExtensions.contains(target.pathExtension.lowercased()) { return nil }
        if type.conforms(to: .archive) || ArchiveName.format(of: target.lastPathComponent) != nil {
            return ArchiveName.format(of: target.lastPathComponent) != nil ? target : nil
        }
        let allowed: [UTType] = [.image, .movie, .audiovisualContent, .pdf]
        return allowed.contains(where: type.conforms(to:)) && !type.conforms(to: .executable) ? target : nil
    }

    /// Kinds that run, install or mount something, or show active web
    /// content (scripts, network), when opened.
    private static let refusedTypes: [UTType] = [
        .executable, .application, .applicationBundle, .script, .shellScript,
        .package, .bundle, .diskImage, .systemPreferencesPane, .html, .xml, .webArchive, .svg,
        UTType("com.apple.installer-package-archive"), UTType("com.apple.installer-meta-package"),
        UTType("com.apple.xip-archive"), UTType("com.apple.archive"), UTType("public.xhtml"),
        UTType("com.apple.terminal.shell-script"),
        UTType("com.apple.automator-workflow"), UTType("com.apple.applescript.script"),
        UTType("com.apple.applescript.text"), UTType("com.apple.configprofile"),
        UTType("com.apple.internet-location"), UTType("com.apple.web-internet-location")].compactMap { $0 }

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
        "exe", "msi", "bat", "cmd", "com", "ps1", "vbs", "js", "jse", "wsf", "lnk", "url", "webloc",
        "xip", "aar", "sparseimage", "sparsebundle", "img", "cdr", "toast",
        "html", "htm", "shtml", "xhtml", "xht", "mht", "mhtml", "webarchive", "svg", "svgz", "hta", "xsl", "xslt"]

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
        // Web pages, web archives and SVG would open in a browser, which
        // runs their scripts and loads from the network
        if refusedTypes.contains(where: type.conforms(to:)) { return nil }
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
        // To another volume: copied (under a temporary name, so a crash never
        // leaves a cut-off file under the real one), then the original removed
        // (a rename in its folder stays on its volume; a volume that doesn't
        // say which it is gets FileManager's own move)
        if from.deletingLastPathComponent().path != to.deletingLastPathComponent().path,
           sameVolume(from, to.deletingLastPathComponent()) == false {
            try copy(from, to)
            do { try fm.removeItem(at: from) } catch { throw TransferError.originalKept(error.localizedDescription) }
            return
        }
        if from.path != to.path, from.path.lowercased() == to.path.lowercased() {
            try renameCase(from, to)
        } else {
            try fm.moveItem(at: from, to: to)
        }
    }

    /// A case-only rename ("photos" → "Photos"), which FileManager refuses
    /// on case-insensitive volumes (the target "exists": it is the item
    /// itself). The system's rename does it in one step: `renamex_np` with
    /// `RENAME_EXCL` refuses any other item under the new name; refused
    /// because that name is the item's own (same device and file number),
    /// `rename` changes the case. Only a volume that does neither gets a
    /// temporary name on the way, one that carries the new name, so a
    /// leftover (the app ended between the two steps) is put back by the
    /// next listing (`restoreIfLeftOver`).
    static func renameCase(_ from: URL, _ to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        let refused = errno
        if refused == EEXIST, ItemIdentity.of(from).map({ $0 == ItemIdentity.of(to) }) == true, rename(from.path, to.path) == 0 { return }
        let fm = FileManager.default
        let temp = from.deletingLastPathComponent().appendingPathComponent(renameTemporaryName(for: to.lastPathComponent))
        PartialCopies.shared.begin(temp)
        defer { PartialCopies.shared.end(temp) }
        try fm.moveItem(at: from, to: temp)
        do {
            try fm.moveItem(at: temp, to: to)
        } catch {
            try? fm.moveItem(at: temp, to: from)   // never leave the item under the hidden name
            throw error
        }
    }

    /// What an item is called between the two steps of a case-only rename:
    /// hidden, with the name it gets ("<prefix><UUID>-Photos"); a name too
    /// long for that goes without it.
    static let renamePrefix = ".schnellbild-rename-"

    static func renameTemporaryName(for name: String) -> String {
        let plain = renamePrefix + UUID().uuidString
        let named = plain + "-" + name
        return named.utf8.count <= 255 ? named : plain
    }

    /// The name a rename's temporary item was to get; nil for any other name.
    static func renameLeftoverTarget(_ name: String) -> String? {
        guard name.hasPrefix(renamePrefix) else { return nil }
        let rest = name.dropFirst(renamePrefix.count)
        guard rest.count > 37, UUID(uuidString: String(rest.prefix(36))) != nil,
              rest.dropFirst(36).first == "-" else { return nil }
        let target = String(rest.dropFirst(37))
        return target.isEmpty || target.contains("/") ? nil : target
    }

    /// A case-only rename's temporary item left behind (the app ended
    /// between its two steps): given the name it was to get, unless this
    /// process is renaming it, it changed in the last `settled` seconds (another Mac
    /// renaming on a share) or the name is taken. Returns where it is now.
    static func restoreIfLeftOver(_ url: URL, settled: TimeInterval = 60) -> URL? {
        guard let target = renameLeftoverTarget(url.lastPathComponent), !PartialCopies.shared.isRunning(url),
              let changed = (try? url.resourceValues(forKeys: [.attributeModificationDateKey]))?.attributeModificationDate,
              Date().timeIntervalSince(changed) >= settled else { return nil }
        let restored = url.deletingLastPathComponent().appendingPathComponent(target)
        return renamex_np(url.path, restored.path, UInt32(RENAME_EXCL)) == 0 ? restored : nil
    }

    /// Moved on the same volume, copied to another (as the Finder does).
    static func transfer(_ from: URL, _ to: URL) throws -> Bool {
        if sameVolume(from, to.deletingLastPathComponent()) == true {
            try FileManager.default.moveItem(at: from, to: to)
            return true
        }
        try copy(from, to)
        return false
    }

    /// Whether both lie on one volume (a move there is a rename); nil when
    /// a volume doesn't say.
    private static func sameVolume(_ a: URL, _ b: URL) -> Bool? {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: key).volumeIdentifier,
              let y = try? b.resourceValues(forKeys: key).volumeIdentifier else { return nil }
        return x.isEqual(y)
    }

    /// What a copy under way is named in its target folder: hidden, and
    /// told apart from anything else by the exact pattern (`isPartialCopy`).
    static let partialCopyPrefix = ".schnellbild-copy-"

    static func isPartialCopy(_ name: String) -> Bool {
        name.hasPrefix(partialCopyPrefix) && name.count == partialCopyPrefix.count + 36
            && UUID(uuidString: String(name.dropFirst(partialCopyPrefix.count))) != nil
    }

    /// Copied under a temporary name in the target folder and renamed once
    /// complete: a crash or a full disk never leaves a cut-off file under
    /// the real name. What failed is removed; a name taken meanwhile is
    /// never overwritten (the rename fails).
    static func copy(_ from: URL, _ to: URL) throws {
        let fm = FileManager.default
        let temp = to.deletingLastPathComponent().appendingPathComponent(partialCopyPrefix + UUID().uuidString)
        PartialCopies.shared.begin(temp)
        defer { PartialCopies.shared.end(temp) }
        do {
            try fm.copyItem(at: from, to: temp)
            try fm.moveItem(at: temp, to: to)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// A copy's temporary item left behind (the app ended during the
    /// copy): removed when its folder is listed, unless this process is
    /// writing it or it changed in the last 12 hours (another Mac may be
    /// copying into a shared folder).
    static func removeIfLeftOver(_ url: URL) {
        guard isPartialCopy(url.lastPathComponent), !PartialCopies.shared.isRunning(url),
              let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(changed) > 12 * 3600 else { return }
        try? FileManager.default.removeItem(at: url)
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
        return entry.moved(to: url)
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

    init(_ query: String, mode: Mode = .ignoringCase) {
        self.query = query
        self.mode = mode
        expression = mode == .regex ? try? NSRegularExpression(pattern: query) : nil
    }

    /// A regular expression that compiles (the other modes always are).
    var isValid: Bool { mode != .regex || expression != nil }

    /// How long an expression may try one name: one that backtracks without
    /// end ("(a|a)*b") counts as no match after this, and so does every
    /// name once `stop` says the search is over.
    static let regexTimeLimit: TimeInterval = 0.05

    func matches(_ name: String, stop: WalkStop? = nil) -> Bool {
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
    var isCostly: Bool { mode == .regex }

    static func == (a: NameMatcher, b: NameMatcher) -> Bool { a.query == b.query && a.mode == b.mode }
}

/// One search: what it has found so far and the tree walk adding to it.
/// The history keeps it, so going back shows the same results, and a walk
/// still running goes on in the background.
@MainActor
final class SearchRun {
    let matcher: NameMatcher
    var query: String { matcher.query }
    /// The searched folder (canonical): what moves out of it is no result.
    /// It follows a rename or move of itself or a folder above it.
    private(set) var root: String?
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
        if let root, let moved = lookup.path(root) { self.root = moved }
        results = results.compactMap { entry in
            guard let url = lookup.url(entry.url) else { return nil }
            if url == entry.url { return entry }
            // Moved out of the searched folder: no longer a result here
            guard stays(url) else { return nil }
            return entry.moved(to: url)
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

/// What a slideshow's walk found and the show hasn't taken yet: handed on
/// at once when nothing was handed on for `interval`, else gathered and
/// handed on together that long after the last time (or on `flush`), so a
/// search of thousands of results or a tree of thousands of folders
/// reaches the show in a few steps.
@MainActor
final class SlideshowArrivals {
    static let interval: Duration = .milliseconds(100)
    private let take: ([(part: Int, items: [GridEntry])]) -> Void
    private var gathered: [(part: Int, items: [GridEntry])] = []
    private var lastHanded: ContinuousClock.Instant?
    private var scheduled: Task<Void, Never>?

    init(_ take: @escaping ([(part: Int, items: [GridEntry])]) -> Void) {
        self.take = take
    }

    func add(_ items: [GridEntry], part: Int) {
        gathered.append((part, items))
        if lastHanded.map({ ContinuousClock.now - $0 >= Self.interval }) ?? true {
            flush()
        } else if scheduled == nil {
            scheduled = Task { [weak self] in
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        scheduled?.cancel()
        scheduled = nil
        guard !gathered.isEmpty else { return }
        let batches = gathered
        gathered = []
        lastHanded = .now
        take(batches)
    }
}

/// Single source of truth for all browsing.
@MainActor
final class BrowserModel: ObservableObject {
    enum Mode { case grid, detail }
    enum SortKey: String, CaseIterable {
        case name, kind, modified, captured, size, distance

        var title: String {
            switch self {
            case .name:     return String(localized: "Name")
            case .kind:     return String(localized: "Kind")
            case .modified: return String(localized: "Date Modified")
            case .captured: return String(localized: "Date Taken")
            case .size:     return String(localized: "Size")
            case .distance: return String(localized: "Distance")
            }
        }
        /// Like Finder: names A→Z, but dates and sizes newest/largest first;
        /// distances nearest first.
        var startsAscending: Bool { self == .name || self == .kind || self == .distance }
    }
    enum KeyInput: Hashable {
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
        didSet { listRevision += 1; recomputeDerived(); readCaptureDatesIfNeeded(); readLocationsIfNeeded(); atlasFollow() }
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
    /// In the App Sandbox: the folder can't be listed, but the file opened
    /// (dropped) can be read, so it alone is shown; "Allow Access…" opens
    /// the folder (`allowAccess`).
    @Published private(set) var accessLimited = false
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

    /// Where `.distance` measures from (an item's place, or coordinates or a
    /// map link pasted: `setDistanceOrigin`); per pane, remembered.
    @Published private(set) var distanceOrigin: GeoPoint?
    /// Where each photo or video was taken, read only while sorting by
    /// `.distance` (through `LocationCache`, by path and modification date).
    /// Files without a place go to the end.
    private var locations: [URL: GeoPoint] = [:] { didSet { orderRevision += 1 } }
    /// Files whose place was read (found or not), and those waiting.
    private var locationsRead: Set<URL> = []
    private var locationsQueued: Set<URL> = []
    private var locationPending: [(url: URL, modified: Date?)] = []
    private var locationTask: Task<Void, Never>?
    private var locationsDone = 0, locationsTotal = 0
    /// While many places are read: how far it has come (the status bar).
    struct Progress: Equatable { let done: Int; let total: Int }
    @Published private(set) var locationProgress: Progress?
    /// The sheet that takes coordinates or a map link to sort by distance from.
    @Published var distanceOriginRequested = false
    /// The Mac's position for the sheet's Use My Location (Core Location,
    /// asked only on that click; nothing at launch).
    static let liveLocation: LocationProvider = CoreLocationProvider()
    /// "Sort by Distance from Here" on an item without a place: its name, for the alert.
    @Published var locationMissing: String?

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
    /// No history or navigation during a slideshow or the tour (`presenting`):
    /// the grid behind them isn't what's on screen, and opening another
    /// folder would end the show.
    var canGoBack: Bool { !presenting && (mode == .detail || !backStack.isEmpty) }
    var canGoForward: Bool { !presenting && !forwardStack.isEmpty }
    var canGoUp: Bool { !presenting && folderURL.flatMap(Self.parentFolder(of:)) != nil }

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
    /// A volume on the drives' level ("/Volumes/USB", "Macintosh HD"): the
    /// system mounts and ejects it, so it is never renamed, moved or trashed.
    nonisolated static func isDrive(_ url: URL) -> Bool { isDrivesLevel(url.deletingLastPathComponent()) }

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
        /// Taken out of the playlist (canonical paths): the walk doesn't bring them back.
        var dismissed: Set<String> = []
        /// Tells this slideshow's walk from an earlier, cancelled one.
        let id = UUID()
        var current: GridEntry? { items.indices.contains(index) ? items[index] : nil }

        /// The part (`partCounts`) each item belongs to, in item order.
        func partOfEachItem() -> [Int] {
            var parts: [Int] = []
            parts.reserveCapacity(items.count)
            for (part, count) in partCounts.enumerated() { parts += Array(repeating: part, count: count) }
            let last = max(partCounts.count - 1, 0)
            if parts.count < items.count { parts += Array(repeating: last, count: items.count - parts.count) }
            return Array(parts.prefix(items.count))
        }

        /// `partCounts` again from each item's part (kept in order, so each
        /// part stays one run of items).
        mutating func recount(_ parts: [Int]) {
            var counts = Array(repeating: 0, count: max(partCounts.count, 1))
            for part in parts { counts[min(part, counts.count - 1)] += 1 }
            partCounts = counts
        }
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
    /// A wait before each part of the walk after the first: tests change the
    /// playlist while the walk still brings items.
    var slideshowPartPause: Duration?
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

    /// Where each video of the folder shown stood when the user left it;
    /// cleared by another folder (`load`).
    private(set) var playbackPositions = PlaybackPositions()

    /// The video at `url` is left (another item, the grid, another folder):
    /// where it stands is remembered for this folder. `list` is
    /// `playbackPositions.list` from when it began to play.
    func videoLeft(_ url: URL, player: PlaybackControl, list: Int) {
        playbackPositions.leave(url, at: player.playedSeconds, length: player.lengthSeconds,
                                playing: player.isPlaying, list: list)
    }
    /// The player of the video on screen — for keyboard control
    /// (play/pause, skimming). Set by the video views.
    weak var activePlayer: PlaybackControl? {
        didSet {
            shownSince = Date()
            videoPaused = false
            if enhancement != .off { activePlayer?.setEnhancement(enhancement) }
            activePlayer?.setVolume(audibleVolume)
            if playbackSpeed != 1 { activePlayer?.setSpeed(playbackSpeed) }
            videoTracks = VideoTracks()
            tracksDecided = nil
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

    /// The volume as set on the control bar's slider (remembered, as the keys').
    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        defaults.set(volume, forKey: Self.volumeKey)
        activePlayer?.setVolume(audibleVolume)
    }

    // MARK: Subtitles, sound tracks, speed

    static let subtitlesKey = "videoSubtitles"
    static let subtitleLanguageKey = "videoSubtitleLanguage"
    static let audioLanguageKey = "videoAudioLanguage"
    /// The tracks of the video on screen and which are on (the control bar,
    /// the Video menu, the context menu).
    @Published private(set) var videoTracks = VideoTracks()
    /// Subtitles shown (V): for every video, remembered; on at first.
    @Published private(set) var showSubtitles = true
    /// The language of the subtitles and of the sound track chosen last
    /// (remembered, read each time: the other panes and windows choose too):
    /// the next video with such a track starts with it.
    var subtitleLanguage: String? { defaults.string(forKey: Self.subtitleLanguageKey) }
    var audioLanguage: String? { defaults.string(forKey: Self.audioLanguageKey) }
    /// The speed of every video in the window until the app quits (< / >,
    /// the menus); not remembered: a video started another day plays at 1×.
    @Published private(set) var playbackSpeed: Double = 1
    /// A short note on the video (the speed, the subtitles or sound track
    /// chosen), shown a moment as the volume is.
    @Published private(set) var playbackNotice: PlaybackNotice?
    /// The track lists the choice from the preferences was made for, per
    /// player: a list that grows (VLC finds a track later) is decided again.
    private var tracksDecided: (player: ObjectIdentifier, audio: [MediaTrack], subtitles: [MediaTrack])?

    struct PlaybackNotice: Equatable {
        let symbol: String
        let text: String
        let id = UUID()
    }

    private func note(_ symbol: String, _ text: String) {
        playbackNotice = PlaybackNotice(symbol: symbol, text: text)
    }

    private var videoOnScreen: Bool { shownMediaEntry?.kind == .video }

    /// The player found or changed its tracks: the subtitles and sound track
    /// the user prefers are chosen once per list of tracks.
    func tracksChanged(from player: PlaybackControl) {
        guard player === activePlayer else { return }
        var tracks = player.tracks
        let id = ObjectIdentifier(player)
        let decided = tracksDecided?.player == id ? tracksDecided : nil
        if decided?.subtitles != tracks.subtitles, !tracks.subtitles.isEmpty {
            let wanted = VideoTracks.subtitleChoice(in: tracks, show: showSubtitles, language: subtitleLanguage)
            if wanted != tracks.subtitleID { player.selectSubtitleTrack(wanted); tracks.subtitleID = wanted }
        }
        if decided?.audio != tracks.audio, tracks.audio.count > 1,
           let wanted = VideoTracks.audioChoice(in: tracks, language: audioLanguage), wanted != tracks.audioID {
            player.selectAudioTrack(wanted)
            tracks.audioID = wanted
        }
        tracksDecided = (id, tracks.audio, tracks.subtitles)
        videoTracks = tracks
    }

    /// V: subtitles on or off, for this video and the next ones.
    func toggleSubtitles() {
        guard videoOnScreen else { return }
        if showSubtitles, videoTracks.subtitleID != nil || videoTracks.subtitles.isEmpty {
            setShowSubtitles(false)
            showSubtitleTrack(nil)
            note("captions.bubble", String(localized: "Subtitles off"))
            return
        }
        setShowSubtitles(true)
        guard let wanted = VideoTracks.subtitleChoice(in: videoTracks, show: true, language: subtitleLanguage) else {
            note("captions.bubble", String(localized: "This video has no subtitles"))
            return
        }
        showSubtitleTrack(wanted)
    }

    /// A subtitle track chosen (nil: none): its language is remembered.
    func selectSubtitle(_ id: Int?) {
        guard videoOnScreen else { return }
        // The language first: the other pane, switched on with it, picks by it
        if let id, let language = videoTracks.subtitles.first(where: { $0.id == id })?.language {
            defaults.set(language, forKey: Self.subtitleLanguageKey)
        }
        setShowSubtitles(id != nil)
        showSubtitleTrack(id)
        if id == nil { note("captions.bubble", String(localized: "Subtitles off")) }
    }

    /// ⌃⌘S: the next subtitle track, then none, then the first again.
    func nextSubtitleTrack() {
        guard videoOnScreen else { return }
        guard !videoTracks.subtitles.isEmpty else {
            note("captions.bubble", String(localized: "This video has no subtitles"))
            return
        }
        selectSubtitle(VideoTracks.nextSubtitle(after: videoTracks.subtitleID, in: videoTracks.subtitles))
    }

    private func setShowSubtitles(_ show: Bool) {
        showSubtitles = show
        defaults.set(show, forKey: Self.subtitlesKey)
    }

    private func showSubtitleTrack(_ id: Int?) {
        activePlayer?.selectSubtitleTrack(id)
        videoTracks.subtitleID = id
        if let track = videoTracks.currentSubtitle {
            note("captions.bubble", String(localized: "Subtitles: \(track.name)"))
        }
    }

    /// A sound track chosen: its language is remembered.
    func selectAudio(_ id: Int) {
        guard videoOnScreen, let track = videoTracks.audio.first(where: { $0.id == id }) else { return }
        if let language = track.language {
            defaults.set(language, forKey: Self.audioLanguageKey)
        }
        activePlayer?.selectAudioTrack(id)
        videoTracks.audioID = id
        note("waveform", String(localized: "Audio: \(track.name)"))
    }

    /// ⌃⌘A: the next sound track, round.
    func nextAudioTrack() {
        guard videoOnScreen else { return }
        let audio = videoTracks.audio
        guard audio.count > 1 else {
            note("waveform", String(localized: "This video has only one audio track"))
            return
        }
        let index = audio.firstIndex { $0.id == videoTracks.audioID } ?? -1
        selectAudio(audio[(index + 1) % audio.count].id)
    }

    /// < / >: a step slower or faster (`PlaybackSpeed.steps`).
    func changeSpeed(by direction: Int) {
        setSpeed(PlaybackSpeed.step(from: playbackSpeed, by: direction))
    }

    func setSpeed(_ speed: Double) {
        guard videoOnScreen else { return }
        playbackSpeed = speed
        activePlayer?.setSpeed(speed)
        note(speed < 1 ? "tortoise.fill" : speed > 1 ? "hare.fill" : "play.fill",
             String(localized: "Speed \(PlaybackSpeed.text(speed))"))
    }

    /// Subtitles switched on or off in another pane: the video on screen
    /// follows (on: the track in the language chosen last), as the next ones do.
    func adoptShowSubtitles(_ shown: Bool) {
        guard shown != showSubtitles else { return }
        showSubtitles = shown
        guard videoOnScreen, !videoTracks.subtitles.isEmpty else { return }
        let wanted = VideoTracks.subtitleChoice(in: videoTracks, show: shown, language: subtitleLanguage)
        guard wanted != videoTracks.subtitleID else { return }
        activePlayer?.selectSubtitleTrack(wanted)
        videoTracks.subtitleID = wanted
    }

    /// The speed another pane set (one speed for the window).
    func adoptSpeed(_ speed: Double) {
        guard speed != playbackSpeed else { return }
        playbackSpeed = speed
        activePlayer?.setSpeed(speed)
    }

    /// Where the control bar sits goes back to the bottom middle.
    func resetVideoBarPosition() { VideoBarPlacement.shared.reset() }
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
        // (".ts" by its content: `isTransportStream`)
    ]

    /// The one rule for which files the app shows: image, video, or nil.
    /// "._" files are never pictures: macOS keeps a file's extra data in them
    /// on volumes that can't hold it (SMB shares, exFAT, FAT). A download
    /// still in progress counts by the name it will have ("x.mp4.part" is a
    /// video, `DownloadName`); a file whose name says nothing known counts
    /// by what its first bytes showed (`ContentSniffer`, no disk access here).
    nonisolated static func mediaKind(of url: URL) -> GridEntry.Kind? {
        guard !url.lastPathComponent.hasPrefix("._") else { return nil }
        let ext = DownloadName.finalExtension(of: url)
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if ext == "ts" { return isTransportStream(url) ? .video : nil }
        return ContentSniffer.shared.known(url)?.mediaKind
    }

    /// ".ts" names TypeScript code far more often than an MPEG transport
    /// stream (a TV or IPTV recording): such a file is a video only when its
    /// first bytes show a transport stream (a sync byte every 188 or 192
    /// bytes, as VLC opens it: `VLCSafety.container`), read once and kept
    /// by `ContentSniffer`. Inside archives never (no first bytes without
    /// unpacking).
    nonisolated static func isTransportStream(_ url: URL) -> Bool {
        ContentSniffer.shared.content(of: url)?.name == "MPEG-TS"
    }

    /// The extension that says what the file is: the one of the name a
    /// download will have, else the one its content showed ("jpeg" for a
    /// JPEG named "IMG"), else its own.
    nonisolated static func shownExtension(of url: URL) -> String {
        let ext = DownloadName.finalExtension(of: url)
        if imageExtensions.contains(ext) || videoExtensions.contains(ext) || ext == "ts" { return ext }
        return ContentSniffer.shared.known(url)?.fileExtension ?? ext
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
        followAtlasSubfolders()
        followHiddenFiles()
        if let seconds = defaults.object(forKey: Self.slideshowSecondsKey) as? Int,
           Self.slideshowSecondsRange.contains(seconds) { slideshowInterval = .seconds(seconds) }
        if let raw = defaults.string(forKey: settingsPrefix + "viewMode"), let mode = ViewMode(rawValue: raw) { viewMode = mode }
        if let raw = defaults.string(forKey: settingsPrefix + "searchMode"), let mode = NameMatcher.Mode(rawValue: raw) { searchMode = mode }
        if let stored = defaults.object(forKey: Self.volumeKey) as? Double { volume = min(max(stored, 0), 1) }
        showSubtitles = defaults.object(forKey: Self.subtitlesKey) as? Bool ?? true
        distanceOrigin = defaults.string(forKey: settingsPrefix + "distanceOrigin").flatMap(GeoPoint.parse)
        if let raw = defaults.string(forKey: sortKeyKey), let key = SortKey(rawValue: raw),
           key != .distance || distanceOrigin != nil {
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
        // Hidden items turned on or off while the window was closed
        if hiddenFilesStale { hiddenFilesChanged() }
    }

    /// `--ui-testing` keeps UI-test runs out of the user's real preferences;
    /// `--reset-state` starts such a run from empty preferences: emptied
    /// once per process, at the first call (at launch), so what the run
    /// writes stays when `Shortcuts`, `Bookmarks` or the quit ask again.
    static func makeDefaults(arguments: [String] = ProcessInfo.processInfo.arguments,
                             suite: String = "art.haushoppe.schnellbild.uitests") -> UserDefaults {
        guard arguments.contains("--ui-testing") else { return .standard }
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        if arguments.contains("--reset-state"), resetSuites.insert(suite).inserted {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }
    private static var resetSuites: Set<String> = []

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
            openExplicitly([url])
            open(folder: url)
        }
    }

    /// The folder shown can't be read in the App Sandbox: the user opens it
    /// to the app (or one that holds it), and it is read again; another
    /// folder chosen instead opens.
    func allowAccess() {
        guard let folder = folderURL, let granted = FolderAccess.shared.ask(for: folder) else { return }
        if FolderAccess.shared.covers(folder) { refresh() } else { openExplicitly([granted]); open(folder: granted) }
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
        stopReadingLocations()
        leaveSearch()
        stopDeep()
        pendingResultSelection = nil
        accessLimited = false
        folderURL = location.folder
        noteRoot(of: location.folder)
        playbackPositions.enter(location.folder)
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
        let target = location.selected, shownHidden = explicitItems
        Task {
            // The folders kept open to the app (App Sandbox) are open first
            await FolderAccess.shared.restored()
            // The folder's date first: a change during the listing shows as one later (`relist`)
            let stamp = await FolderPreviewCache.stamp(of: url)
            let scanned = await Self.listing(url, password: password, kept: shownHidden)
            guard self.loadGeneration == generation else { return }   // a newer navigation won
            self.listedStamp = stamp
            var full = (try? scanned.get().entries) ?? []
            let parent = Self.parentFolder(of: url).map { GridEntry(url: $0, kind: .parent) }
            if let parent { full.insert(parent, at: 0) }
            var ordered = await self.ordered(full)
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
                self.sniffOtherFiles()
            case .failure(let error as CocoaError):
                // A grant kept for a volume that wasn't there opens now: read again
                if await FolderAccess.shared.retry(covering: url) {
                    guard self.loadGeneration == generation else { return }
                    self.load(location, thenDetail: thenDetail, password: password, keeping: kept)
                    return
                }
                let needsAccess = !FolderAccess.shared.covers(url)
                // A file dropped from a folder outside every grant: the
                // sandbox opened only the file, so it alone is shown (at once,
                // in the full view when it was dropped there)
                if needsAccess, let target, ArchivePath.split(url) == nil,
                   let lone = await Blocking.run(.userInitiated, { Self.readableEntry(target) }) {
                    guard self.loadGeneration == generation else { return }
                    ordered = self.sorted([parent, lone].compactMap { $0 })
                    self.accessLimited = true
                    break
                }
                // Not "empty": the folder couldn't be listed (no permission, a share gone)
                self.loadError = LoadError(archive: false, reason: error.localizedDescription,
                                           needsAccess: needsAccess)
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
            if let from = self.confirmRestoreFrom, generation >= from {
                self.confirmRestoreFrom = nil
                self.confirmRestoreLater()
            }
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
            // The Atlas with the subfolders: an item of one (from the history) once it comes
            if self.wantsDeep { self.startDeep(selectAt: self.index(of: target) == nil ? target : nil) }
        }
    }

    /// UI tests (`--test-log=<path>`): what happened, a line each, for
    /// what the screen doesn't show (how often a rename ran).
    /// The clock of timed test log lines: ms since the system started.
    nonisolated static var testClock: String { String(format: "%.1f", ProcessInfo.processInfo.systemUptime * 1000) }

    nonisolated static func testLog(_ line: String, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--ui-testing"),
              let arg = arguments.first(where: { $0.hasPrefix("--test-log=") }) else { return }
        let path = String(arg.dropFirst("--test-log=".count))
        // One writer at a time: lines come from the main thread and VLC's
        // threads, and two writers at the same end would write over each other
        testLogLock.lock()
        defer { testLogLock.unlock() }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
    nonisolated private static let testLogLock = NSLock()

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
    /// The last folder wasn't there at launch (a share or disk not
    /// connected): said instead of a bare "No folder open"; it opens when
    /// a volume mounts and it is there then.
    @Published private(set) var unavailableRestore: String?
    /// The folder being reopened at launch, until the app has run a while.
    private var restoreUnconfirmedKey: String { settingsPrefix + Self.restoreUnconfirmedKey }
    static let restoreUnconfirmedKey = "restoreUnconfirmed"

    /// The load from which on a listing shown starts `confirmRestoreLater`.
    private var confirmRestoreFrom: Int?
    /// How long the app runs with the reopened folder shown before it counts
    /// as harmless.
    var restoreConfirmDelay: Duration = .seconds(15)

    /// Still running a while after the reopened folder's listing is shown:
    /// it didn't take the app down.
    private func confirmRestoreLater() {
        let key = restoreUnconfirmedKey, defaults = defaults, delay = restoreConfirmDelay
        Task {
            try? await Task.sleep(for: delay)
            defaults.removeObject(forKey: key)
        }
    }

    /// The app quits normally: the folders reopened at launch did no harm,
    /// in every pane of every window ("", "rightPane.", "window<n>." …).
    static func confirmRestore(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(restoreUnconfirmedKey) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Where the first launch starts, with no last folder: the user's
    /// Pictures (the real one, not the sandbox container's; the
    /// entitlements grant it), if it is there. UI tests name their own
    /// (`--pictures-folder=<path>`) and have none otherwise.
    static var defaultFolder: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        let folder: URL
        if arguments.contains("--ui-testing") {
            let prefix = "--pictures-folder="
            guard let path = arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) else { return nil }
            folder = URL(fileURLWithPath: String(path), isDirectory: true)
        } else {
            guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
            folder = URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent("Pictures", isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue ? folder : nil
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
        restoringLastFolder = true
        Task {
            defer { restoringLastFolder = false }
            // (a folder outside the grants kept can't be looked at before they are open)
            await FolderAccess.shared.restored()
            let exists = await Blocking.run {
                // A folder inside an archive: the archive file must still be there
                if let (archive, _) = ArchivePath.splitChecked(URL(fileURLWithPath: path)) {
                    return FileManager.default.fileExists(atPath: archive.path)
                }
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                    && !BrowserModel.isPackage(URL(fileURLWithPath: path))
            }
            // Unless the user opened something meanwhile (then it isn't reopened)
            guard folderURL == nil else { defaults.removeObject(forKey: key); return }
            if exists {
                unavailableRestore = nil
                open(folder: URL(fileURLWithPath: path))
                // Confirmed once its listing is shown and the app has run a
                // while after it (its tiles decoding), not while it is read
                confirmRestoreFrom = loadGeneration
                return
            }
            // Nothing was opened: nothing to guard against at the next launch
            defaults.removeObject(forKey: key)
            if let other = fallback() { open(folder: other); return }
            // Tried again when a volume mounts (`volumesChanged`)
            unavailableRestore = path
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

    /// Read a directory, with date/size; hidden items as `HiddenFiles`
    /// says. Runs off the main thread; metadata is prefetched during
    /// enumeration (no extra round-trips).
    nonisolated static func scan(_ url: URL, kept: Set<String> = []) async -> [GridEntry] {
        (try? await listing(url, kept: kept).get().entries) ?? []
    }

    /// What the grid shows of a folder, plus its other files, or why it
    /// can't be read (an archive that needs a password; `password` is one
    /// just typed for it). Hidden items only while they are shown
    /// (`HiddenFiles`), or those in `kept` (canonical paths the user opened
    /// himself).
    nonisolated static func listing(_ url: URL, password: String? = nil, kept: Set<String> = []) async -> Result<FolderListing, Error> {
        let shown = HiddenFiles.shown
        if await Blocking.run(.userInitiated, { ArchivePath.splitChecked(url) != nil }) {
            do { return .success(try await ArchiveStore.shared.listing(in: url, trying: password, showingHidden: shown)) }
            catch { return .failure(error) }
        }
        do { return .success(try await scanFolder(url, showingHidden: shown, kept: kept)) }
        catch { return .failure(error) }
    }

    nonisolated private static func scanFolder(_ url: URL, showingHidden shown: Bool, kept: Set<String>) async throws -> FolderListing {
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
                if LiveFiles.isPartialCopy(item.lastPathComponent) { LiveFiles.removeIfLeftOver(item); continue }
                var item = item
                if LiveFiles.renameLeftoverTarget(item.lastPathComponent) != nil {
                    guard let restored = LiveFiles.restoreIfLeftOver(item) else { continue }
                    item = restored
                }
                // Hidden items (a dot name, the hidden flag) only while shown;
                // ".DS_Store", "._…" never
                guard HiddenFiles.lists(item, values: try? item.resourceValues(forKeys: HiddenFiles.keys),
                                        shown: shown, kept: kept) else { continue }
                if let entry = entry(for: item, keys: keys) { listing.entries.append(entry); continue }
                var vals = try? item.resourceValues(forKeys: keys)
                if vals?.isSymbolicLink == true { vals = try? item.resolvingSymlinksInPath().resourceValues(forKeys: keys) }
                // Folders that aren't shown are packages, which count as files
                guard vals?.isDirectory != true || vals?.isPackage == true else { continue }
                listing.others.append(OtherFile(url: item, byteSize: vals?.isPackage == true ? nil : vals?.fileSize))
            }
            // A split archive's later volumes belong to its tile
            // (names compared ignoring case: "MOVIE.PART2.RAR" belongs to "MOVIE.PART1.RAR")
            // (only parts of an archive the grid shows)
            let names = Set(listing.entries.filter(\.isArchive).map { $0.name.lowercased() })
            listing.others.removeAll { ArchiveName.firstVolumeNames(of: $0.name).contains { names.contains($0.lowercased()) } }
            // Firefox makes an empty file of the final name when a download
            // starts and writes into "x.mp4.part": the empty one isn't shown
            let downloading = Set(listing.entries.filter(\.isDownloading).map { DownloadName.finalName(of: $0.name).lowercased() })
            if !downloading.isEmpty {
                listing.entries.removeAll { $0.byteSize == 0 && !$0.isDownloading && downloading.contains($0.name.lowercased()) }
            }
            listing.others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return listing
        }
    }

    /// A picture, video or archive the app may read although its folder
    /// can't be listed (a file the sandbox opened alone).
    nonisolated private static func readableEntry(_ url: URL) -> GridEntry? {
        guard FileManager.default.isReadableFile(atPath: url.path), let entry = entry(for: url, keys: entryKeys),
              entry.kind != .folder || entry.isArchive else { return nil }
        return entry
    }

    /// What `entry(for:keys:)` reads, prefetched by the listings.
    nonisolated static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey, .isAliasFileKey,
        .isHiddenKey
    ]

    /// Classify one file system item; nil for non-media files. Packages
    /// (".photoslibrary", ".app") are single files to the user, as in the
    /// Finder: not a folder to browse, walk in a slideshow or search.
    nonisolated private static func entry(for item: URL, keys: Set<URLResourceKey>) -> GridEntry? {
        var vals = try? item.resourceValues(forKeys: keys)
        // A Finder alias is a file that LaunchServices follows anywhere (an
        // app): listed among the other files, never shown or opened as media
        if vals?.isAliasFile == true, vals?.isSymbolicLink != true { return nil }
        // A symbolic link counts by what it points to: a link to a folder is
        // listed as the link (trashed, renamed, moved as the link, as in the
        // Finder) and opens the folder it points to; a link to a file counts
        // by the file it points to (a "photo.jpg" pointing to a script is no
        // photo, a "Photos.zip" pointing to an installer no archive)
        var target = item
        let isLink = vals?.isSymbolicLink == true
        if isLink {
            target = item.resolvingSymlinksInPath()
            vals = try? target.resourceValues(forKeys: keys)
        }
        let date = vals?.contentModificationDate
        if vals?.isPackage == true { return nil }
        if vals?.isDirectory == true {
            if ArchiveName.format(of: target.lastPathComponent) != nil { ArchivePath.noteFolder(target) }
            if ArchiveName.format(of: item.lastPathComponent) != nil { ArchivePath.noteFolder(item) }
            return GridEntry(url: item, kind: .folder, modDate: date, linkTarget: isLink ? target : nil)
        }
        if target != item, mediaKind(of: target) != mediaKind(of: item) { return nil }
        if isLink, ArchiveName.format(of: item.lastPathComponent) != nil,
           ArchiveName.format(of: target.lastPathComponent) != ArchiveName.format(of: item.lastPathComponent)
            || target.pathExtension.lowercased() != item.pathExtension.lowercased() { return nil }
        // An archive opens like a folder (one found by its content too)
        if ArchiveName.format(ofFile: item) != nil {
            ArchivePath.noteArchive(item)
            return GridEntry(url: item, kind: .folder, modDate: date, byteSize: vals?.fileSize)
        }
        guard let kind = mediaKind(of: item) else { return nil }
        return GridEntry(url: item, kind: kind, modDate: date, byteSize: vals?.fileSize)
    }

    /// Whether a photo or video lies anywhere below `folder`. Stops at the
    /// first one, so only folders that are really empty are walked to the
    /// end. Hidden items (unless shown, `HiddenFiles`) and anything that isn't a
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
        let shown = HiddenFiles.shown
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return false }
        let limit = probeLimit(for: folder)
        var looked = 0
        while true {
            if cancelled() { return nil }
            looked += 1
            if looked > limit { return nil }
            // A pool per item: a big tree would pile up autoreleased objects
            let found: Bool? = autoreleasepool {
                guard let url = walk.nextObject() as? URL else { return false }
                if skipsHidden(url, in: walk, shown: shown) { return nil }
                // An archive opens like a folder; what's in it isn't looked into
                // here (that means unpacking), so it counts as holding something
                if mediaKind(of: url) != nil || ArchiveName.format(ofFile: url) != nil, isFile(url) { return true }
                return nil
            }
            if let found { return found }
        }
    }

    /// An item of a walk the app doesn't show (`HiddenFiles`): a hidden
    /// folder isn't walked into. The enumerators read the flag along with
    /// the listing.
    nonisolated static func skipsHidden(_ url: URL, in walk: FileManager.DirectoryEnumerator, shown: Bool) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isHiddenKey, .isDirectoryKey])
        guard !HiddenFiles.lists(url, values: values, shown: shown) else { return false }
        // Only for a folder: after a file it would skip the rest of the folder holding it
        if values?.isDirectory == true { walk.skipDescendants() }
        return true
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
        entry.kind == .folder && emptyFolders.contains(Self.canonicalPath(entry.browseURL))
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
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .contentModificationDateKey, .isHiddenKey, .isDirectoryKey]
            let shown = HiddenFiles.shown
            // The first ones the disk lists at the top, not the first by
            // name: a big folder on a network share isn't listed to its end
            // for three pictures
            var first: [URL] = []
            if let top = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]) {
                while first.count < limit, !cancelled() {
                    let more: Bool = autoreleasepool {
                        guard let url = top.nextObject() as? URL else { return false }
                        if !skipsHidden(url, in: top, shown: shown), mediaKind(of: url) != nil, isFile(url) { first.append(url) }
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
                options: [.skipsPackageDescendants]) else { return [] }
            var looked = 0
            let most = probeLimit(for: folder)
            while looked <= most, !cancelled(), first.count < limit {   // a huge tree: give up, not hang
                looked += 1
                let more: Bool = autoreleasepool {
                    guard let url = walk.nextObject() as? URL else { return false }
                    if !skipsHidden(url, in: walk, shown: shown), mediaKind(of: url) != nil, isFile(url) { first.append(url) }
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
                                        captured: [URL: Date] = [:], origin: GeoPoint? = nil,
                                        located: [URL: GeoPoint] = [:]) -> [GridEntry] {
        EntryOrder(key: key, ascending: ascending, captured: captured, origin: origin, located: located).sorted(entries)
    }

    /// The grid's order as a comparison, so streamed search results can be
    /// merged into a sorted list instead of sorting it all again.
    struct EntryOrder: Sendable {
        let key: SortKey
        let ascending: Bool
        let captured: [URL: Date]
        /// `.distance`: from where, and the places read so far.
        var origin: GeoPoint? = nil
        var located: [URL: GeoPoint] = [:]

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
            /// Metres from the origin (`.distance`); nil without a place.
            let distance: Double?
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
            var distance: Double?
            if key == .distance, let origin, let point = located[entry.url] { distance = origin.distance(to: point) }
            // (the extension only where the key reads it: a merge works this out for every probe)
            return Keyed(entry: entry, group: group, name: entry.name,
                         ext: key == .kind && entry.isMedia ? BrowserModel.shownExtension(of: entry.url) : "",
                         rank: rank, date: date, size: entry.byteSize ?? 0, distance: distance)
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
            case .distance:
                return order(a.distance ?? 0, b.distance ?? 0)
            }
        }

        /// ".." on top, then folders, then media, each group by the key.
        func before(_ a: Keyed, _ b: Keyed) -> Bool {
            if a.group != b.group { return a.group < b.group }
            // Without a place: after every item with one, in either direction
            if key == .distance, (a.distance == nil) != (b.distance == nil) { return a.distance != nil }
            let result = compare(a, b)
            // Ties go by name A→Z in either direction, like Finder
            if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        func sorted(_ entries: [GridEntry]) -> [GridEntry] {
            entries.map(keyed).sorted(by: before).map(\.entry)
        }

        /// `fresh` merged into `list`, which is in this order already: one
        /// pass over `list`, a binary search for each new item.
        func merged(_ list: [GridEntry], _ fresh: [GridEntry]) -> [GridEntry] {
            let add = fresh.map(keyed).sorted(by: before)
            let places = Self.insertionPoints(into: list.count, adding: add.count) { before(keyed(list[$0]), add[$1]) }
            var result: [GridEntry] = []
            result.reserveCapacity(list.count + add.count)
            var i = 0
            for (item, place) in zip(add, places) {
                result.append(contentsOf: list[i..<place])
                result.append(item.entry)
                i = place
            }
            result.append(contentsOf: list[i...])
            return result
        }

        /// Where each of `adding` sorted new items goes among `count` sorted
        /// ones (`listBefore(i, j)`: item i of the list comes before new item
        /// j): a binary search in what is left of the list for each, so at
        /// most about `adding · (log2(count) + 1)` comparisons.
        static func insertionPoints(into count: Int, adding: Int, listBefore: (Int, Int) -> Bool) -> [Int] {
            var places: [Int] = []
            places.reserveCapacity(adding)
            var start = 0
            for j in 0..<adding {
                var low = start, high = count
                while low < high {
                    let mid = (low + high) / 2
                    if listBefore(mid, j) { low = mid + 1 } else { high = mid }
                }
                places.append(low)
                start = low
            }
            return places
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
                // A link's folder moved or renamed by the app: the link leads there
                let target = entry.linkTarget.flatMap { lookup.url($0) }
                if url == entry.url {
                    kept.append(target == entry.linkTarget ? entry : entry.moved(to: url, target: target))
                    continue
                }
                moved.append(entry.moved(to: url, target: target))
            }
            return moved.isEmpty ? kept : merged(kept, moved)
        }
    }

    /// The order the lists are in (sort key, direction, the capture dates known).
    private var entryOrder: EntryOrder {
        EntryOrder(key: sortKey, ascending: sortAscending, captured: captureDates, origin: distanceOrigin, located: locations)
    }
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
        // Distance needs a place to measure from: asked for first
        if key == .distance, distanceOrigin == nil { requestDistanceOrigin(); return }
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = key.startsAscending }
        defaults.set(key.rawValue, forKey: sortKeyKey)
        defaults.set(sortAscending, forKey: sortAscendingKey)
        if key != .distance { stopReadingLocations() }
        resort()
        readCaptureDatesIfNeeded()
        readLocationsIfNeeded()
    }

    // MARK: Sorting by distance

    /// Sorts by the distance from `point`, nearest first (remembered with the sort).
    func setDistanceOrigin(_ point: GeoPoint) {
        distanceOrigin = point
        defaults.set(point.decimalPair, forKey: settingsPrefix + "distanceOrigin")
        sortKey = .distance
        sortAscending = true
        defaults.set(SortKey.distance.rawValue, forKey: sortKeyKey)
        defaults.set(true, forKey: sortAscendingKey)
        orderRevision += 1
        resort()
        readLocationsIfNeeded()
    }

    func sortByDistance(from point: GeoPoint) { setDistanceOrigin(point) }

    /// "Sort by Distance from Here" on an item: its place read (cached), else
    /// an alert says it has none.
    func sortByDistance(from entry: GridEntry) {
        guard entry.isMedia else { return }
        let url = entry.url, modified = entry.modDate, name = entry.name
        Task { [weak self] in
            let point: GeoPoint?
            if ArchivePath.isInside(url) {
                point = await detachedCancellable(priority: .userInitiated) { () -> GeoPoint? in
                    guard let source = await MediaData.imageSource(url),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
                    return MediaLocation.picture(props)?.point
                }
            } else {
                point = await LocationCache.shared.point(of: url, modified: modified)
            }
            guard let self else { return }
            if let point { self.setDistanceOrigin(point) } else { self.locationMissing = name }
        }
    }

    /// Opens the sheet that takes coordinates or a map link.
    func requestDistanceOrigin() {
        guard !anySheetOpen, slideshow == nil else { return }
        searchFocused = false
        distanceOriginRequested = true
    }

    /// Metres from the origin to the file's place, once read.
    func knownDistance(of url: URL) -> Double? {
        guard sortKey == .distance, let origin = distanceOrigin, let point = locations[url] else { return nil }
        return origin.distance(to: point)
    }

    /// While sorting by distance, read the places of the media listed (also
    /// search results from subfolders) that aren't known yet, a chunk at a
    /// time off the main thread, sorting again as they come in.
    func readLocationsIfNeeded() {
        guard sortKey == .distance, distanceOrigin != nil else { return }
        let missing = (allEntries + entries).filter {
            $0.isMedia && !locationsRead.contains($0.url) && !locationsQueued.contains($0.url)
        }
        guard !missing.isEmpty else { return }
        for entry in missing where !locationsQueued.contains(entry.url) {
            locationsQueued.insert(entry.url)
            locationPending.append((entry.url, entry.modDate))
            locationsTotal += 1
        }
        if locationTask == nil { startReadingLocations() }
    }

    /// Files read per step; the list is sorted again after a step at most
    /// twice a second, and once at the end.
    private static let locationChunk = 64

    private func startReadingLocations() {
        locationTask = Task { [weak self] in
            var lastSort = Date()
            while true {
                guard let self, !Task.isCancelled else { return }
                let chunk = Array(self.locationPending.prefix(Self.locationChunk))
                if chunk.isEmpty { break }
                self.locationPending.removeFirst(chunk.count)
                // Shown only while there's more than one step to go
                if self.locationsTotal > Self.locationChunk {
                    self.locationProgress = Progress(done: self.locationsDone, total: self.locationsTotal)
                }
                let found = await LocationCache.shared.points(of: chunk)
                guard !Task.isCancelled else { return }
                var read: [URL: GeoPoint] = [:]
                for file in chunk {
                    self.locationsQueued.remove(file.url)
                    if let point = found[file.url] {
                        self.locationsRead.insert(file.url)
                        if let point { read[file.url] = point }
                    }
                }
                if !read.isEmpty { self.locations.merge(read) { _, new in new } }
                self.locationsDone += chunk.count
                if self.locationProgress != nil {
                    self.locationProgress = Progress(done: self.locationsDone, total: self.locationsTotal)
                }
                if self.locationPending.isEmpty || Date().timeIntervalSince(lastSort) > 0.5 {
                    lastSort = Date()
                    self.objectWillChange.send()   // the list's Distance column
                    self.resort()
                }
            }
            guard let self else { return }
            self.locationTask = nil
            self.locationProgress = nil
            self.locationsDone = 0
            self.locationsTotal = 0
        }
    }

    /// Another sort chosen, another folder: what is still to read is left
    /// (read again when it is wanted).
    private func stopReadingLocations() {
        locationTask?.cancel()
        locationTask = nil
        locationPending = []
        locationsQueued = []
        locationProgress = nil
        locationsDone = 0
        locationsTotal = 0
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
        let all = allEntries, shown = entries, filtering = isFiltering || deep != nil
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
            await Self.after(previous)
            let found = await Self.captureDates(of: Array(missing))
            guard let self, !Task.isCancelled else { return }
            // The list view's Date Taken column shows them
            if !found.isEmpty { self.objectWillChange.send() }
            self.captureDates.merge(found) { _, new in new }
            if self.sortKey == .captured { self.resort() }
        }
    }

    /// Waits for the task before, one of a chain: cancelling the newest
    /// (another folder opened) cancels every one it waits for.
    nonisolated static func after(_ previous: Task<Void, Never>?) async {
        guard let previous else { return }
        await withTaskCancellationHandler { await previous.value } onCancel: { previous.cancel() }
    }

    /// The places of the media among `entries` (through `LocationCache`).
    nonisolated static func locations(of entries: [GridEntry]) async -> [URL: GeoPoint] {
        let found = await LocationCache.shared.points(of: entries.filter(\.isMedia).map { ($0.url, $0.modDate) })
        return found.compactMapValues { $0 }
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

    /// When a photo or video was taken, from its header and the files beside
    /// it (`CaptureReader` through `LocationCache`: EXIF with its offset, XMP
    /// sidecars, QuickTime, a camera's clip XML, GoPro's GPS time, a DJI
    /// flight log, the movie header). Not inside archives (not unpacked for sorting).
    nonisolated static func captureDate(of url: URL) async -> Date? {
        guard !ArchivePath.isInside(url) else { return nil }
        let modified = await Blocking.run(.utility) {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return await LocationCache.shared.facts(of: url, modified: modified).time?.date
    }

    private func sorted(_ list: [GridEntry]) -> [GridEntry] {
        entryOrder.sorted(list)
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
            updateDeep()
            return
        }
        stopDeep()
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
            entries = entryOrder.merged(entries, fresh)
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
    /// Skips hidden items unless they are shown (`HiddenFiles`) and package contents; stops when the consumer
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
            let shown = HiddenFiles.shown
            DispatchQueue.global(qos: .userInitiated).async {
                let keys = entryKeys
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsPackageDescendants]
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
                        // Hidden items and what is in hidden folders: only while shown
                        if skipsHidden(url, in: enumerator, shown: shown) { return true }
                        // A real folder named like an archive: its results are a folder's
                        if ArchiveName.format(of: url.lastPathComponent) != nil,
                           (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            ArchivePath.noteFolder(url)
                        }
                        if matcher.matches(url.lastPathComponent, stop: stop),
                           let match = entry(for: url, keys: keys) {
                            batch.entries.append(match)
                            // (the walk doesn't follow links: what it saw says nothing about theirs)
                            if match.kind == .folder, !match.isArchive, match.linkTarget == nil { facts.found(folder: match.url) }
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
        // Opened to the app by the drop (App Sandbox): held while it is
        // looked at; a folder or archive it opens is kept (`openDropped`
        // below), the other items dropped are left alone
        FolderAccess.shared.hold(first)
        openExplicitly(urls)
        // What it is: looked up off the main thread (dropped from a share
        // that answers slowly)
        let look: @Sendable () -> (exists: Bool, isFolder: Bool, isPackage: Bool) = {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            // A file whose name says nothing known ("x.part", "IMG", "x.xyz")
            // counts by its content: read before its folder is listed
            if exists, !isDir.boolValue, BrowserModel.mediaKind(of: first) == nil,
               ArchiveName.format(of: first.lastPathComponent) == nil {
                ContentSniffer.shared.content(of: first)
            }
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
        let opensAsFolder = (found.isFolder && !isPackage) || (!found.isFolder && ArchiveName.format(ofFile: first) != nil)
        let folder = opensAsFolder ? first : first.deletingLastPathComponent()
        let file = opensAsFolder ? nil : first
        // Kept for a restart: what opens as a folder (a launch reopens folders)
        if opensAsFolder { FolderAccess.shared.grant(first) }
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
        guard !presenting else { return }
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
        guard !presenting, let target = forwardStack.popLast() else { return }
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

    /// What the Inspector is about: the item on screen (full view,
    /// slideshow), else the one selected in the grid or list (not "..").
    var inspectedEntry: GridEntry? {
        if mode == .detail || slideshow != nil { return shownMediaEntry }
        guard let entry = selectedEntry, entry.kind != .parent else { return nil }
        return entry
    }

    /// "Get Info" in a tile's or row's menu: that item selected and the
    /// Inspector shown.
    func getInfo(_ entry: GridEntry) {
        guard entry.kind != .parent, select(entry) else { return }
        showInspector = true
    }

    func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selection = index
    }

    // MARK: Marking several items

    /// Items marked besides the selection (⌘-click, ⇧-click, ⇧-arrows, ⌘A,
    /// Insert), as canonical paths. Empty: the selection alone counts.
    @Published private(set) var marked: Set<String> = [] {
        didSet { markRevision += 1 }
    }
    private var markRevision = 0
    /// Where a range (⇧) starts, by its path: re-sorts, search batches and
    /// removals move items around. A plain move of the cursor (arrows,
    /// Home, End) lets the next range start where the cursor is.
    private var markAnchor: String?

    func isMarked(_ entry: GridEntry) -> Bool { marked.contains(Self.canonicalPath(entry.url)) }

    /// What file actions work on: the marked items in grid order, else the
    /// selected one. Never "..". The marked ones are found once per change
    /// of the list or the marks: the menus ask on every change of the model
    /// (a search streaming results), and finding them looks at every entry.
    var actionEntries: [GridEntry] {
        if marked.isEmpty { return selectedEntry.map { $0.kind == .parent ? [] : [$0] } ?? [] }
        if let cached = markedEntries, cached.list == listRevision, cached.marks == markRevision { return cached.entries }
        let found = entries.filter { $0.kind != .parent && marked.contains(Self.canonicalPath($0.url)) }
        markedEntries = (listRevision, markRevision, found)
        return found
    }
    private var markedEntries: (list: Int, marks: Int, entries: [GridEntry])?

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

    /// Insert (as in the commanders) or M: marks or unmarks the selected item
    /// and moves on to the next.
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
        let target = min(max(current + delta, first), entries.count - 1)
        let moved = target != selection
        selection = target
        // At the first / last item a PDF stays on its page
        if moved { resetTransforms() } else { zoom = 1; rotation = 0 }
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
    /// (A PDF shown next starts at its first page.)
    private func resetTransforms() { zoom = 1; rotation = 0; pdfPosition = nil }

    // MARK: - PDF pages (full view)

    /// The PDF the full view shows: the page on screen (from 0) of its
    /// `count`. Set by `FullImageView` once the PDF is open.
    struct PDFPosition: Equatable {
        let url: URL
        var page: Int
        let count: Int
    }
    @Published private(set) var pdfPosition: PDFPosition?

    /// The page of `url` to show: the one turned to while it is the PDF on
    /// screen, else its first.
    func pdfPage(of url: URL) -> Int {
        guard let position = pdfPosition, position.url == url else { return 0 }
        return position.page
    }

    /// The full view opened `url`, a PDF of `count` pages: it starts at its
    /// first page; the PDF already on screen keeps its page.
    func pdfOpened(_ url: URL, pages count: Int) {
        if let position = pdfPosition, position.url == url, position.count == count { return }
        pdfPosition = PDFPosition(url: url, page: 0, count: max(count, 1))
    }

    /// The PDF on screen whose pages ← → turn: in the full view only (the
    /// slideshow shows a PDF as one item, its first page).
    private var pagedPDF: PDFPosition? {
        guard slideshow == nil, mode == .detail, let position = pdfPosition,
              shownMediaEntry?.url == position.url else { return nil }
        return position
    }

    /// Turns to `page` (from 0) of the PDF on screen; each page starts at
    /// fit and upright, as each picture does.
    func showPDFPage(_ page: Int) {
        guard var position = pagedPDF, (0..<position.count).contains(page), page != position.page else { return }
        position.page = page
        pdfPosition = position
        zoom = 1
        rotation = 0
    }

    // MARK: - Grid tile size

    func growThumbnails()   { thumbnailSide = min(thumbnailSide + 30, 320) }
    func shrinkThumbnails() { thumbnailSide = max(thumbnailSide - 30, 80) }

    // MARK: - Trackpad pinch

    /// How far a pinch on the grid goes for one tile step (⌘+ / ⌘−): the
    /// sum of the gesture's magnification since the last step.
    static let tilePinchStep: CGFloat = 0.25
    /// The grid pinch's magnification not yet turned into a step.
    private(set) var tilePinch: CGFloat = 0

    /// A trackpad pinch over this pane (`magnification`: the event's change,
    /// 0 none; `began`: the gesture's first event). A video zooms (AVKit's
    /// view would take the pinch, so the window's event monitor brings it
    /// here); the grid's tiles grow or shrink a step each time the pinch
    /// adds up to `tilePinchStep`, so a pinch goes step by step. A picture
    /// zooms through its own gesture and the list keeps its rows: false,
    /// the event goes on.
    func pinch(_ magnification: CGFloat, began: Bool) -> Bool {
        guard !anySheetOpen else { return false }
        if let shown = shownMediaEntry {
            guard shown.kind == .video else { return false }
            applyPinch(1 + magnification)
            return true
        }
        guard mode == .grid, viewMode == .grid else { return false }
        if began { tilePinch = 0 }
        tilePinch += magnification
        while tilePinch >= Self.tilePinchStep { tilePinch -= Self.tilePinchStep; growThumbnails() }
        while tilePinch <= -Self.tilePinchStep { tilePinch += Self.tilePinchStep; shrinkThumbnails() }
        return true
    }

    /// The pan offset of a zoomed-in picture or video after the zoom
    /// changed from `old` to `new`: scaled with it, so the middle of the
    /// view keeps showing the same place (keys, the menu and a pinch zoom
    /// about the view's middle); at fit, none.
    static func panOffset(_ offset: CGSize, zoomedFrom old: CGFloat, to new: CGFloat) -> CGSize {
        guard new > 1.01, old > 0 else { return .zero }
        let ratio = new / old
        return CGSize(width: offset.width * ratio, height: offset.height * ratio)
    }

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
            open(folder: entry.browseURL)
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
        guard !presenting, let current = folderURL, let parent = Self.parentFolder(of: current) else { return }
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

    /// A key the window handled (D, Tab, F5, F6, ⇧⌘C, ⇧⌘M), for the mini keyboard.
    func noteKeyPress(_ key: KeyInput, command: Bool, shift: Bool = false) {
        lastKeyPress = KeyPress(key: key, command: command, shift: shift)
    }

    /// Tiles, a list (L) or the Atlas (W, the map): per pane, remembered.
    enum ViewMode: String { case grid, list, atlas }
    @Published var viewMode: ViewMode = .grid {
        didSet {
            defaults.set(viewMode.rawValue, forKey: settingsPrefix + "viewMode")
            if viewMode == .list { columnCount = 1 }
            if viewMode != .atlas, oldValue != .atlas { viewModeBeforeAtlas = viewMode }
            if viewMode == .atlas { updateDeep(); atlasFollow() } else if oldValue == .atlas { updateDeep(); atlasIfMade?.pause() }
        }
    }
    /// What W goes back to from the Atlas.
    private var viewModeBeforeAtlas: ViewMode = .grid

    /// W: the Atlas, or back to the grid or list it came from.
    func toggleAtlas() {
        viewMode = viewMode == .atlas ? viewModeBeforeAtlas : .atlas
    }

    /// The Atlas view's state (made when first shown).
    private(set) lazy var atlas: AtlasModel = {
        atlasMade = true
        return AtlasModel(browser: self, readFacts: atlasFacts)
    }()
    private var atlasMade = false
    /// Where the Atlas reads times and places (tests stand in).
    var atlasFacts: AtlasModel.FactsReader = AtlasModel.liveFacts
    var atlasIfMade: AtlasModel? { atlasMade ? atlas : nil }

    /// The tour runs (over the pane, full screen).
    var touring: Bool { atlasIfMade?.tour != nil }
    /// A slideshow or the tour has the window.
    var presenting: Bool { slideshow != nil || touring }

    /// The Atlas reads the facts of what the pane lists, while it is shown.
    private func atlasFollow() {
        guard viewMode == .atlas else { return }
        atlas.walking = deepWalking
        let context = (folderPath ?? "") + "\u{1}" + query + (deep != nil ? "\u{1}deep" : "")
        // The walk's batches: only what came is looked at
        if let added = atlasAdded { atlas.entriesAdded(added, context: context) } else { atlas.entriesChanged(entries, context: context) }
    }
    /// What the walk of the subfolders just added to `entries`.
    private var atlasAdded: [GridEntry]?

    // MARK: The Atlas with the subfolders

    static let atlasSubfoldersKey = "atlasSubfolders"
    /// The Atlas of a folder shows its subfolders' photos and videos too
    /// (app-wide, on unless turned off; a search's results come from every
    /// subfolder anyway).
    @Published var atlasSubfolders = true {
        didSet {
            guard atlasSubfolders != oldValue else { return }
            defaults.set(atlasSubfolders, forKey: Self.atlasSubfoldersKey)
            NotificationCenter.default.post(name: Self.atlasSubfoldersChanged, object: defaults)
            updateDeep()
        }
    }
    /// Every pane follows a change of the preference (those of the same preferences).
    static let atlasSubfoldersChanged = Notification.Name("SchnellbildAtlasSubfoldersChanged")
    private var atlasSubfoldersObserver: NSObjectProtocol?

    func followAtlasSubfolders() {
        atlasSubfolders = defaults.object(forKey: Self.atlasSubfoldersKey) as? Bool ?? true
        guard atlasSubfoldersObserver == nil else { return }
        let defaults = self.defaults
        atlasSubfoldersObserver = NotificationCenter.default.addObserver(forName: Self.atlasSubfoldersChanged, object: defaults,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = self.defaults.object(forKey: Self.atlasSubfoldersKey) as? Bool ?? true
                if self.atlasSubfolders != value { self.atlasSubfolders = value }
            }
        }
    }

    /// The walk of a folder's subfolders for the Atlas: the photos and videos
    /// below the folder, found by the slideshow's walk (`walkForSlideshow`:
    /// hidden folders unless shown and links left out, archives opened), shown in the
    /// pane's list as they arrive, as search results are.
    final class DeepWalk {
        let root: String
        /// The items below the folder (not its own), in `entries`.
        var items: [GridEntry] = []
        /// Found, not shown yet (a batch goes in every quarter of a second).
        var pending: [GridEntry] = []
        var seen: Set<String> = []
        var task: Task<Void, Never>?
        var flushScheduled = false
        /// A walk again after changes outside the app: what it finds replaces
        /// the items once it is through, so nothing on the map goes and comes.
        var quiet = false
        var found: [GridEntry] = []
        /// The first item inside this folder (or archive) is selected when it comes.
        var selectInside: String?
        /// This item is selected when it comes (from the history).
        var selectAt: URL?
        /// Sortings of the whole list asked for, and done (off the main thread).
        var sorting = 0
        var sorted = 0
        /// A batch is merged off the main thread; the walk ended meanwhile.
        var merging = false
        var finishing = false

        init(root: String) { self.root = root }
    }
    private var deep: DeepWalk?
    /// The pane lists its folder's subfolders too (the Atlas with subfolders on).
    var showsDeep: Bool { deep != nil }
    /// Its walk is still going.
    @Published private(set) var deepWalking = false {
        didSet { atlasIfMade?.walking = deepWalking }
    }

    /// Whether the pane should list the subfolders now: the Atlas shown, the
    /// preference on, a folder read and no search.
    private var wantsDeep: Bool {
        viewMode == .atlas && atlasSubfolders && !isFiltering && !isLoading && loadError == nil && folderPath != nil
    }

    /// Starts or ends the walk of the subfolders as the view, the
    /// preference, the folder or the search ask.
    func updateDeep() {
        if wantsDeep {
            if deep?.root != folderPath { startDeep() }
        } else if deep != nil {
            leaveDeep()
        }
    }

    /// The pane's list with the subfolders: the folder's own photos and
    /// videos and those below it, in the pane's order; the selection stays
    /// on its item, a folder selected hands it to its first item once that
    /// comes.
    private func startDeep(quiet: Bool = false, selectAt: URL? = nil) {
        guard let folderURL, let folderPath else { return }
        deep?.task?.cancel()
        let walk = DeepWalk(root: folderPath)
        let selected = selectedEntry
        if quiet, let old = deep {
            walk.items = old.items
            walk.quiet = true
        } else if let selected, selected.kind == .folder || selected.isArchive {
            walk.selectInside = Self.canonicalPath(selected.browseURL)
        }
        walk.selectAt = selectAt
        let own = allEntries.filter(\.isMedia)
        walk.seen = Set(own.map(\.url.path))   // (the walk lists the folder as its listing did: the same paths)
        deep = walk
        if !quiet { showDeep(keeping: selected?.url) }
        deepWalking = true
        let kept = explicitItems
        walk.task = Task { [weak self] in
            await Self.walkForSlideshow(folderURL, key: .name, ascending: true, kept: kept) { batch in
                self?.deepFound(batch, in: walk)
            }
            guard !Task.isCancelled else { return }
            self?.deepFinished(walk)
        }
    }

    /// The folder's own media and the walk's items as the pane's list.
    private func showDeep(keeping url: URL?) {
        guard let deep else { return }
        let list = allEntries.filter(\.isMedia) + deep.items
        // A long list is sorted off the main thread; what the walk brings
        // meanwhile is merged in when it is there
        guard list.count > Self.mainThreadSortLimit else { showDeepList(sorted(list), keeping: url); return }
        let order = entryOrder
        deep.sorting += 1
        let round = deep.sorting
        let count = deep.items.count
        Task { [weak self] in
            let ordered = await Blocking.run(.userInitiated) { order.sorted(list) }
            guard let self, self.deep === deep, deep.sorting == round else { return }
            deep.sorted = round
            let later = Array(deep.items.dropFirst(count))
            self.showDeepList(later.isEmpty ? ordered : self.entryOrder.merged(ordered, later), keeping: self.selectedEntry?.url ?? url)
        }
    }

    private func showDeepList(_ list: [GridEntry], keeping url: URL?) {
        let previous = selection
        entries = list
        if let index = indexByURL(url) {
            keepSelection(index)
        } else if !entries.isEmpty {
            keepSelection(previous.map { min($0, entries.count - 1) } ?? 0)
        } else {
            keepSelection(nil)
        }
    }

    /// Where an item is in the list, found by its URL first (quick in a
    /// list of 100 000), else by its canonical path.
    private func indexByURL(_ url: URL?) -> Int? {
        guard let url else { return nil }
        return entries.firstIndex { $0.url == url } ?? index(of: url)
    }

    private func deepFound(_ batch: [GridEntry], in walk: DeepWalk) {
        guard deep === walk else { return }
        let new = batch.filter { walk.seen.insert($0.url.path).inserted }
        guard !new.isEmpty else { return }
        if walk.quiet { walk.found += new; return }
        walk.pending += new
        guard !walk.flushScheduled else { return }
        walk.flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.flushDeep(walk) }
        }
    }

    private func flushDeep(_ walk: DeepWalk) {
        walk.flushScheduled = false
        // (one merge at a time; what comes meanwhile goes in with the next)
        guard deep === walk, !walk.pending.isEmpty, !walk.merging else { return }
        let fresh = walk.pending
        walk.pending = []
        walk.items += fresh
        // (a long list being sorted takes the batch in when it is done)
        guard walk.sorting == walk.sorted else { return }
        // A long list: merged off the main thread (comparing names as the
        // Finder does takes its time on thousands)
        guard entries.count + fresh.count > Self.deepMergeOnMainLimit else { showMerged(entryOrder.merged(entries, fresh), fresh, walk); return }
        walk.merging = true
        let list = entries, order = entryOrder, revision = listRevision
        Task { [weak self] in
            let merged = await Blocking.run(.userInitiated) { order.merged(list, fresh) }
            guard let self, self.deep === walk else { return }
            walk.merging = false
            // The list changed meanwhile (a change on disk): merged into it as it is now
            self.showMerged(revision == self.listRevision ? merged : self.entryOrder.merged(self.entries, fresh), fresh, walk)
            if !walk.pending.isEmpty { self.flushDeep(walk) } else if walk.finishing { self.deepFinished(walk) }
        }
    }

    /// Lists up to this long take the walk's batches on the main thread.
    static let deepMergeOnMainLimit = 2_000

    /// The walk's batch shown: the list with it, the selection kept or
    /// handed to what came.
    private func showMerged(_ list: [GridEntry], _ fresh: [GridEntry], _ walk: DeepWalk) {
        let keep = selectedEntry?.url
        atlasAdded = fresh
        entries = list
        atlasAdded = nil
        if let at = walk.selectAt, let index = indexByURL(at) {
            walk.selectAt = nil
            walk.selectInside = nil
            selection = index
        } else if let inside = walk.selectInside,
                  let first = fresh.first(where: { Self.canonicalPath($0.url).hasPrefix(inside + "/") }),
                  let index = indexByURL(first.url) {
            walk.selectInside = nil
            selection = index
        } else if let index = indexByURL(keep) {
            keepSelection(index)
        }
    }

    private func deepFinished(_ walk: DeepWalk) {
        guard deep === walk else { return }
        // A batch still being merged: finished once it is in
        if walk.merging { walk.finishing = true; return }
        if walk.quiet {
            walk.items = walk.found
            walk.found = []
            walk.quiet = false
            showDeep(keeping: selectedEntry?.url)
        } else {
            flushDeep(walk)
        }
        walk.selectInside = nil
        walk.selectAt = nil
        deepWalking = false
    }

    /// Back to the folder's own listing (the grid or list, the preference
    /// off, a search): an item of a subfolder hands the selection to the
    /// folder (or archive) of the listing it lies in.
    private func leaveDeep() {
        let selected = selectedEntry?.url
        stopDeep()
        guard !isFiltering, !isLoading else { return }
        entries = allEntries
        if let index = index(of: selected) {
            keepSelection(index)
        } else if let selected {
            let path = Self.canonicalPath(selected)
            let holder = allEntries.firstIndex { entry in
                (entry.kind == .folder || entry.isArchive) && path.hasPrefix(Self.canonicalPath(entry.browseURL) + "/")
            }
            if let holder { keepSelection(holder) } else { selectDefault(in: entries) }
        } else {
            selectDefault(in: entries)
        }
    }

    /// The walk stops; the list is left to the caller.
    private func stopDeep() {
        deep?.task?.cancel()
        deep = nil
        if deepWalking { deepWalking = false }
    }

    /// Changes below the folder made outside the app: the walk again, its
    /// items replaced once it is through.
    private func rewalkDeep() {
        guard deep != nil, wantsDeep else { return }
        startDeep(quiet: true)
    }

    /// T: the tour of what the Atlas shows (the Atlas comes first).
    func startTour() {
        guard mode == .grid, slideshow == nil else { return }
        if viewMode != .atlas { viewMode = .atlas }
        searchFocused = false
        atlas.startTour()
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
        if let atlas = atlasIfMade, atlas.tour != nil { return tourKey(key, command: command, atlas: atlas) }
        if mode == .grid, viewMode == .atlas, let handled = atlasKey(key, command: command, shift: shift) { return handled }
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
        case "l" where !command: viewMode = viewMode == .list ? .grid : .list; return true
        case "w" where !command:
            guard folderURL != nil else { return false }
            toggleAtlas(); return true
        case "t" where !command:
            guard mode == .grid, folderURL != nil else { return false }
            startTour(); return true
        // The Inspector: in the grid and list too, about the item selected
        case "i" where !command:
            guard viewingMedia || folderURL != nil else { return false }
            showInspector.toggle(); return true
        // M: Insert on a Mac keyboard (which has none)
        case "m" where !command:
            guard mode == .grid else { return false }
            toggleMarkAndAdvance(); return true
        default:
            break
        }
        guard viewingMedia, !command else { return false }
        switch c {
        case "0": zoomReset();            return true
        case "1": zoomActualSize();       return true
        // Videos: V subtitles on / off (as in IINA and mpv), < / > slower /
        // faster (as on YouTube; IINA's ⌘[ ⌘] are Back / Forward here)
        case "v" where videoOnScreen: toggleSubtitles(); return true
        case "<" where videoOnScreen: changeSpeed(by: -1); return true
        case ">" where videoOnScreen: changeSpeed(by: +1); return true
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
        let identity = try await renameOnDisk(old, new, name: name)
        undoHistory.record(UndoStep(kind: .rename, parts: [.moved(old, to: new, identity: identity)]))
        renameFileTarget = nil
        apply(.moved(old, to: new))
        // A new extension can make it a picture, video or archive: the grid
        // shows it then
        if Self.mediaKind(of: new) != nil || ArchiveName.format(of: name) != nil { refresh(changed: [old.deletingLastPathComponent()]) }
        return new
    }

    func moveToTrash(_ file: OtherFile) {
        guard canChange(file) else { return }
        guard fileActions.confirmTrash([file.name], String(localized: "The file will be moved to the Trash.")) else { return }
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
        return canChange(entry)
    }

    /// Whether an item may be moved or trashed: one on disk, not inside an
    /// archive (archives are only read), not a drive.
    func canChange(_ entry: GridEntry) -> Bool {
        entry.kind != .parent && !ArchivePath.isInside(entry.url) && !Self.isDrive(entry.url)
    }

    /// What the Trash takes: the marked items (grid), else the selected one.
    private var trashEntries: [GridEntry] {
        guard mode == .grid else { return selectedMediaEntry.map { [$0] }?.filter(canChange) ?? [] }
        return actionEntries.filter(canChange)
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
        guard canChange(entry) else { NSSound.beep(); return }   // archives are only read, drives ejected
        // What goes with it, said exactly: a folder's whole contents (also
        // what the grid doesn't show), all parts of a split archive (found
        // by listing its folder: off the main thread)
        let isArchive = entry.isArchive
        let url = entry.url
        trashLookupPending = true
        onFiles({ isArchive ? ArchiveName.allFiles(of: url) : [url] }) { [self] files in
            trashLookupPending = false
            let detail = entry.linkTarget != nil
                ? String(localized: "The link will be moved to the Trash. The folder it points to stays where it is.")
                : entry.kind == .folder && !isArchive
                ? String(localized: "The folder and everything in it, including files Schnellbild doesn't show, will be moved to the Trash.")
                : files.count > 1 ? String(localized: "All parts of this archive will be moved to the Trash.")
                : String(localized: "The file will be moved to the Trash.")
            guard fileActions.confirmTrash([entry.name], detail) else { return }
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
        let detail = String(localized: "The marked items will be moved to the Trash, folders with everything in them.")
        guard fileActions.confirmTrash(items.map(\.name), detail) else { return }
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
                        if let inTrash { parts.append(.trashed(file, inTrash: inTrash, identity: ItemIdentity.of(inTrash))) }
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

    // MARK: Hidden files and folders

    /// Hidden items are shown (Settings → General, View → Show Hidden
    /// Files, ⇧⌘.): app-wide, every pane of every window follows a change
    /// (those of the same preferences). Off unless turned on.
    @Published var showHiddenFiles = false {
        didSet {
            guard showHiddenFiles != oldValue, !readingHiddenFiles else { return }
            defaults.set(showHiddenFiles, forKey: HiddenFiles.shownKey)
            HiddenFiles.shown = showHiddenFiles
            NotificationCenter.default.post(name: HiddenFiles.changed, object: defaults)
            hiddenFilesChanged()
        }
    }
    private var hiddenFilesObserver: NSObjectProtocol?
    /// The preference being read at the start: nothing to read again yet.
    private var readingHiddenFiles = false

    /// The preference read at the start, then followed: another pane (or
    /// window) changed it.
    func followHiddenFiles() {
        readingHiddenFiles = true
        showHiddenFiles = defaults.bool(forKey: HiddenFiles.shownKey)
        readingHiddenFiles = false
        HiddenFiles.shown = showHiddenFiles
        guard hiddenFilesObserver == nil else { return }
        hiddenFilesObserver = NotificationCenter.default.addObserver(forName: HiddenFiles.changed, object: defaults,
                                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = self.defaults.bool(forKey: HiddenFiles.shownKey)
                if self.showHiddenFiles != value { self.showHiddenFiles = value }
            }
        }
    }

    /// Items the user opened himself (dropped, chosen in the open panel,
    /// `--open=`), as canonical paths: listed even while hidden items aren't.
    private(set) var explicitItems: Set<String> = []
    /// Where the pane's way through the folders began: a folder opened
    /// directly (dropped, chosen, a bookmark, the last one at launch) or the
    /// folder above it the user went up to. Hidden folders below it were
    /// entered while hidden items showed; turned off, the pane leaves them.
    private var shownRoot: URL?
    /// The setting changed while the pane's window was closed: done when it opens again.
    private var hiddenFilesStale = false

    /// The user opens these himself: shown even when hidden.
    private func openExplicitly(_ urls: [URL]) {
        explicitItems.formUnion(urls.map(Self.canonicalPath))
        shownRoot = nil
    }

    /// The pane's way through the folders, for `shownRoot`.
    private func noteRoot(of folder: URL) {
        if let shownRoot, Self.isSameOrInside(Self.canonicalPath(folder), Self.canonicalPath(shownRoot)) { return }
        shownRoot = folder
    }

    /// Hidden items were turned on or off: the folder, a search and the
    /// Atlas's subfolders are read again (selection, marks and scroll
    /// position stay where their items stay); every folder tile reads its
    /// previews and emptiness again. Turned off, a pane inside a hidden
    /// folder it didn't open itself goes to the folder above it, and the
    /// history and the slideshow lose what is hidden.
    func hiddenFilesChanged() {
        guard inWindow else { hiddenFilesStale = true; return }
        hiddenFilesStale = false
        forgetBelow(nil)
        // The history's searches found what was shown then
        let runs = (backStack + forwardStack).compactMap(\.search)
        backStack = backStack.map { var location = $0; location.search = nil; return location }
        forwardStack = forwardStack.map { var location = $0; location.search = nil; return location }
        let current = allSearches
        for run in runs where !run.finished && !current.contains(where: { $0 === run }) { run.stop(incomplete: true) }
        guard let folderURL else { return }
        guard !HiddenFiles.shown else { showHiddenChange(); return }
        let root = shownRoot ?? folderURL
        let historyFolders = (backStack + forwardStack).map(\.folder)
        let showItems = slideshow?.items.map(\.url) ?? []
        let kept = explicitItems
        let generation = loadGeneration
        Task {
            let found = await Blocking.run(.userInitiated) { () -> (here: URL?, history: Set<String>, show: [URL]) in
                let here = HiddenFiles.firstHidden(below: root, to: folderURL)
                let history = Set(historyFolders.filter { HiddenFiles.firstHidden(below: root, to: $0) != nil }.map(Self.canonicalPath))
                // Items of the show in hidden folders, or hidden themselves
                var folders: [String: Bool] = [:]
                let show = showItems.filter { item in
                    guard !kept.contains(Self.canonicalPath(item)) else { return false }
                    if !HiddenFiles.lists(item, values: try? item.resourceValues(forKeys: HiddenFiles.keys), shown: false) { return true }
                    let folder = item.deletingLastPathComponent()
                    let key = Self.canonicalPath(folder)
                    if let known = folders[key] { return known }
                    let hidden = HiddenFiles.firstHidden(below: root, to: folder) != nil
                    folders[key] = hidden
                    return hidden
                }
                return (here, history, show)
            }
            guard loadGeneration == generation, !HiddenFiles.shown else { return }
            if !found.history.isEmpty {
                backStack.removeAll { found.history.contains(Self.canonicalPath($0.folder)) }
                forwardStack.removeAll { found.history.contains(Self.canonicalPath($0.folder)) }
            }
            if !found.show.isEmpty, slideshow != nil { applyHere(found.show.map(FileChange.removed)) }
            if let here = found.here {
                // Not into the history: the folder left can't be shown
                let above = here.deletingLastPathComponent()
                load(Location(folder: above, query: "", selected: nil))
                return
            }
            showHiddenChange()
        }
    }

    /// The folder (or the place in an archive), its search and the Atlas's
    /// walk again, as the setting is now.
    private func showHiddenChange() {
        guard let folderURL else { return }
        if isLoading {
            let location = loadingLocation ?? Location(folder: folderURL, query: searchText)
            load(location, keeping: (marked, selectionChosen))
            return
        }
        relist(force: true, searchAgain: isFiltering)
        rewalkDeep()
    }

    /// The watch follows the folder shown (none inside an archive: nothing
    /// changes there).
    private func updateWatch() {
        watchArchiveDownload()
        guard watchesFolder, inWindow, let folderURL, ArchivePath.split(folderURL) == nil else { watch = nil; return }
        guard watch?.path != folderURL.path else { return }
        watch = nil
        watch = FolderWatch(path: folderURL.path) { [weak self] changed, rootChanged in
            self?.changedOutside(changed, rootChanged: rootChanged)
        }
    }

    private var archiveDownload: (archive: URL, task: Task<Void, Never>)?

    /// Inside an archive whose download isn't finished ("x.rar.part"): its
    /// size is looked at every three seconds, and when it grew its listing
    /// is read again and merged in place (what arrived shows, the selection
    /// stays). Renamed to its final name ("x.rar"), the pane follows it.
    private func watchArchiveDownload() {
        guard watchesFolder, inWindow, let folderURL, let archive = ArchivePath.split(folderURL)?.archive,
              DownloadName.isPartial(archive.lastPathComponent) else {
            archiveDownload?.task.cancel()
            archiveDownload = nil
            return
        }
        guard archiveDownload?.archive != archive else { return }
        archiveDownload?.task.cancel()
        let task = Task { [weak self] in
            func size() async -> Int64? {
                await Blocking.run(.utility) {
                    var info = stat()
                    return stat(archive.path, &info) == 0 ? Int64(info.st_size) : nil
                }
            }
            var known = await size()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let now = await size()
                guard let self, !Task.isCancelled else { return }
                if now == nil {
                    let final = archive.deletingLastPathComponent().appendingPathComponent(DownloadName.finalName(of: archive.lastPathComponent))
                    if await Blocking.run(.utility, { FileManager.default.fileExists(atPath: final.path) }) {
                        let change = FileChange.moved(archive, to: final)
                        self.followFolder(through: [change])
                        self.applyHere([change])
                    }
                    return
                }
                guard now != known, !self.isLoading, let shown = self.folderURL else { continue }
                known = now
                if case .success(let listing) = await Self.listing(shown, kept: self.explicitItems), self.folderURL == shown, !self.isLoading {
                    self.merge(listing)
                }
            }
        }
        archiveDownload = (archive, task)
    }

    /// FSEvents: something changed in or below the folder shown (`changed`:
    /// the folders whose contents changed, nil for too many to name).
    func changedOutside(_ changed: [String]?, rootChanged: Bool) {
        guard let folderURL, let folderPath else { return }
        if rootChanged { followFolderGone(); return }
        guard let changed else {
            forgetBelow(nil)
            relist(force: true, searchAgain: isFiltering)
            rewalkDeep()
            return
        }
        let below = changed.filter { $0 != folderPath && Self.isSameOrInside($0, folderPath) }
        if !below.isEmpty {
            forgetBelow(below)
            rewalkDeep()
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
            guard case .success(let listing) = await Self.listing(folderURL, kept: explicitItems) else { return }
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
        if listing.others != otherFiles {
            otherFiles = listing.others
            sniffOtherFiles()
        }
        var fresh: [String: GridEntry] = [:]
        for entry in listing.entries { fresh[Self.canonicalPath(entry.url)] = entry }
        followFinishedDownloads(fresh)
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
        if deep != nil { showDeep(keeping: keep); return }
        entries = allEntries
        keepSelection(index(of: keep) ?? previous.map { min($0, entries.count - 1) })
    }

    /// A download finished: its tool renamed "x.mp4.part" to "x.mp4". That
    /// is a move for every list (`FileChange.moved`), so the selection, the
    /// marks and the video playing go on with the file under its new name.
    /// An empty file of the final name listed before (Firefox makes one when
    /// the download starts) goes.
    private func followFinishedDownloads(_ fresh: [String: GridEntry]) {
        var placeholders: [FileChange] = []
        var finished: [FileChange] = []
        let listed = Set(allEntries.map { Self.canonicalPath($0.url) })
        for entry in allEntries where entry.isDownloading && fresh[Self.canonicalPath(entry.url)] == nil {
            let final = entry.url.deletingLastPathComponent().appendingPathComponent(DownloadName.finalName(of: entry.name))
            let finalPath = Self.canonicalPath(final)
            guard let now = fresh[finalPath], now.kind == entry.kind else { continue }
            if listed.contains(finalPath) { placeholders.append(.removed(final)) }
            finished.append(.moved(entry.url, to: final))
        }
        if !placeholders.isEmpty { applyHere(placeholders) }
        if !finished.isEmpty { applyHere(finished) }
    }

    /// Other files whose names say nothing known ("IMG", "x.xyz", "x.part")
    /// have their first bytes read off the main thread (`ContentSniffer`,
    /// once per file and size, at most `sniffLimit` of a listing); a
    /// picture, video or archive among them is listed again, in the grid.
    private func sniffOtherFiles() {
        sniffing?.cancel()
        guard let folderURL, ArchivePath.split(folderURL) == nil, !otherFiles.isEmpty else { return }
        let files = otherFiles
        let generation = loadGeneration
        sniffing = Task {
            let found = await Blocking.run(.utility) { () -> Bool in
                let candidates = files.lazy.filter {
                    ContentSniffer.isUnknown($0.name) && ContentSniffer.shared.needsReading($0.url, size: $0.byteSize)
                }.prefix(Self.sniffLimit).map(\.url)
                let urls = Array(candidates)
                guard !urls.isEmpty else { return false }
                let any = ManagedFlag()
                // A few at a time: on a network share each is a round trip
                DispatchQueue.concurrentPerform(iterations: min(4, urls.count)) { lane in
                    for index in stride(from: lane, to: urls.count, by: 4) {
                        let content = ContentSniffer.shared.content(of: urls[index])
                        if content?.mediaKind != nil || content?.archiveFormat != nil { any.set() }
                    }
                }
                return any.isSet
            }
            while isLoading, loadGeneration == generation, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard found, !Task.isCancelled, loadGeneration == generation else { return }
            relist(force: true)
        }
    }

    private var sniffing: Task<Void, Never>?
    /// Files of a listing read for their content at most.
    nonisolated static let sniffLimit = 5_000

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
        // The last folder wasn't there at launch: it may be now
        if volume == nil, folderURL == nil, unavailableRestore != nil, !restoringLastFolder {
            restoreLastFolder()
            return
        }
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
    var otherSheetOpen: Bool { renameTarget != nil || renameFileTarget != nil || passwordRequest != nil || newFolderRequested || distanceOriginRequested }
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
        if !isFiltering, deep == nil {
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
    /// themselves. Returns whether anything goes (nothing inside an
    /// archive, of a drive, the folder itself or what is in it already).
    @discardableResult
    func move(_ sources: [URL], into folder: URL, how: Transfer = .asFinder) -> Bool {
        guard ArchivePath.split(folder) == nil else { NSSound.beep(); return false }
        let target = Self.canonicalPath(folder)
        let shown = folderPath
        // By their paths alone (no file system): what can go at all
        let sourcePaths = sources.map(Self.canonicalPath)
        let candidates = sources.filter { source in
            let path = Self.canonicalPath(source)
            return !ArchivePath.isInside(source) && !Self.isDrive(source) && path != target && !target.hasPrefix(path + "/")
                // Not inside another item that goes along
                && !sourcePaths.contains(where: { path.hasPrefix($0 + "/") })
                // Never the folder shown or one around it
                && (shown.map { $0 != path && !$0.hasPrefix(path + "/") } ?? true)
                && Self.canonicalPath(source.deletingLastPathComponent()) != target
        }
        guard !candidates.isEmpty else { return false }
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
                // Gone (moved or deleted since it was dragged): nothing to move
                let gone = (try? FileManager.default.attributesOfItem(atPath: source.path)) == nil
                return TransferProbe(source: source, gone: gone, isFolder: isFolder, files: files,
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
        return true
    }

    /// What a source of a move is, and what is taken in the target folder.
    struct TransferProbe: Sendable {
        let source: URL
        /// Not there any more (lstat finds nothing).
        let gone: Bool
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
        // "Apply to all": the answer for every other name taken
        var standing: ConflictAnswer.Choice?
        for (number, probe) in probes.enumerated() {
            let source = probe.source
            // Gone since it was dragged (a drag dropped twice: the first
            // drop moved it): nothing to ask about, nothing to move
            if probe.gone { continue }
            let isPlanned: (URL) -> Bool = { planned.contains(Self.canonicalPath($0)) }
            // A later part taken there: the set would be mixed
            if probe.partTaken || probe.files.dropFirst().contains(where: { isPlanned(folder.appendingPathComponent($0.lastPathComponent)) }) {
                NSSound.beep(); continue
            }
            var destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: probe.isFolder)
            if probe.destinationTaken || isPlanned(destination) {
                let choice: ConflictAnswer.Choice
                if let standing {
                    choice = standing
                } else {
                    let more = probes[(number + 1)...].contains { $0.destinationTaken && !$0.gone }
                    let answer = fileActions.askKeepBoth(source.lastPathComponent, folder.lastPathComponent, more)
                    if answer.forAll { standing = answer.choice }
                    choice = answer.choice
                }
                if choice == .cancel { return [] }
                guard choice == .keepBoth else { continue }
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

    /// Applies what was carried out, also the parts of an item that failed
    /// half way (a split archive's first volumes moved): their changes and
    /// their Undo; what failed is reported item by item.
    private func finishMove(_ steps: [TransferStep], _ outcomes: [TransferOutcome], into folder: URL) {
        let target = Self.canonicalPath(folder)
        var moves: [FileChange] = []
        var failures: [(name: String, reason: String)] = []
        var undoParts: [UndoStep.Part] = []
        var copied = false
        for outcome in outcomes {
            for file in outcome.done {
                undoParts.append(file.moved ? .moved(file.from, to: file.to, identity: file.identity)
                                            : .copied(file.from, to: file.to, identity: file.identity))
                if file.moved { moves.append(.moved(file.from, to: file.to)) } else { copied = true }
            }
            if let failed = outcome.failed { failures.append((failed.name, failed.error.localizedDescription)) }
        }
        if copied {
            // A copy: the target and every folder around it hold more now
            let around = FileChange.removed(folder).affectedFolders
            FolderPreviewCache.shared.forget(around)
            emptyFolders.subtract(around)
            folderChanges += 1
        }
        if !failures.isEmpty { fileActions.report(TransferFailure(failures: failures)) }
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
        deep?.items = deep?.items.filter(belowShown) ?? []
        entries = isFiltering || deep != nil ? entries.filter(belowShown) : allEntries
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
            let identity = try await renameOnDisk(old, new, name: name)
            undoHistory.record(UndoStep(kind: .rename, parts: [.moved(old, to: new, identity: identity)]))
            // A folder named like an archive stays a folder
            if ArchiveName.format(of: name) != nil { ArchivePath.noteFolder(new) }
            // The folder shown takes the new path first: the change then
            // keeps what is listed in it (its other files too) in the folder
            // (the pane may have moved on meanwhile; the change reaches it)
            if folderURL.map(Self.canonicalPath) == Self.canonicalPath(old) {
                folderURL = new
                defaults.set(new.path, forKey: lastFolderKey)
                if let parent = Self.parentFolder(of: new), let i = allEntries.firstIndex(where: { $0.kind == .parent }) {
                    allEntries[i] = GridEntry(url: parent, kind: .parent)
                    if let j = entries.firstIndex(where: { $0.kind == .parent }) { entries[j] = allEntries[i] }
                }
            }
            apply(.moved(old, to: new))
        } catch {
            fileActions.report(error)
        }
    }

    // MARK: - Rename

    /// Whether an item can be renamed here: not "..", nothing inside an
    /// archive (archives are only read), not an archive split into parts
    /// by its name ("x.part1.rar", "x.7z.001").
    func canRename(_ entry: GridEntry) -> Bool {
        guard canChange(entry) else { return false }
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
        if entry.kind != .folder, !Self.keepsKind(entry.kind, renaming: old, to: new) {
            throw RenameError.changesKind(Self.shownExtension(of: old), video: entry.kind == .video)
        }
        let identity = try await renameOnDisk(old, new, name: name)
        undoHistory.record(UndoStep(kind: .rename, parts: [.moved(old, to: new, identity: identity)]))

        // Stay where we are: same folder, same query, same results (and the
        // full view stays open) — only the renamed item and, for a folder,
        // everything listed inside it get the new path.
        // A folder named like an archive stays a folder
        if isFolder, ArchiveName.format(of: name) != nil { ArchivePath.noteFolder(new) }
        // (the other pane follows through `onFileChange`)
        renameTarget = nil
        apply(.moved(old, to: new))
        return new
    }

    /// Whether a picture or video keeps its kind under a new name, decided
    /// by the names alone (the new path doesn't exist yet, and nothing is
    /// read on the main thread): an extension of a picture or video says
    /// so; the same ending as before (".ts" told by its content, a file
    /// recognised by its content with no or an unknown extension) keeps
    /// the kind the item has.
    nonisolated static func keepsKind(_ kind: GridEntry.Kind, renaming old: URL, to new: URL) -> Bool {
        let ext = DownloadName.finalExtension(of: new)
        if imageExtensions.contains(ext) { return kind == .image }
        if videoExtensions.contains(ext) { return kind == .video }
        return ext == DownloadName.finalExtension(of: old)
    }

    /// Renames on disk: off the main thread for the live actions (a share
    /// answers slowly), inline for a test's spy. Refuses a name taken by
    /// another item.
    /// Returns the renamed item's identity (for Undo).
    @discardableResult
    private func renameOnDisk(_ old: URL, _ new: URL, name: String) async throws -> ItemIdentity? {
        let check: @Sendable (Bool) throws -> Void = { taken in if taken { throw RenameError.alreadyExists(name) } }
        guard fileActions.runsOffMain else {
            try check(fileActions.conflicts(new, old))
            do { try fileActions.move(old, new) } catch { throw RenameError.failed(error.localizedDescription) }
            return ItemIdentity.of(new)
        }
        // Counted, so quitting waits for it (a case-only rename can take two steps)
        Self.transfersUnderWay += 1
        defer { Self.transfersUnderWay -= 1 }
        return try await Blocking.run {
            try check(LiveFiles.conflicts(new, old))
            do { try LiveFiles.move(old, new) } catch { throw RenameError.failed(error.localizedDescription) }
            return ItemIdentity.of(new)
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
    func followFolder(through changes: [FileChange]) -> Bool {
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
        playbackPositions.follow(lookup)
        allEntries = order.following(allEntries, lookup)
        for run in allSearches { run.apply(changes) }
        pendingResultSelection = pendingResultSelection.flatMap { lookup.url($0) }
        backStack = backStack.map { location in changes.reduce(location) { $1.apply(to: $0) } }
        forwardStack = forwardStack.map { location in changes.reduce(location) { $1.apply(to: $0) } }
        entries = order.following(entries, lookup)
        // The Atlas's subfolders: what moved out of the folder leaves them
        if let deep, let shown = folderPath {
            let below: (GridEntry) -> Bool = { Self.isSameOrInside(Self.canonicalPath($0.url), shown) }
            deep.items = order.following(deep.items, lookup).filter(below)
            entries = entries.filter(below)
        }
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
        // An open rename sheet follows its item (renamed or moved by the
        // other pane, by Undo) and closes when the item is gone
        if let target = renameTarget {
            if let url = lookup.url(target.url) {
                if url != target.url { renameTarget = target.moved(to: url) }
            } else {
                renameTarget = nil
            }
        }
        if let file = renameFileTarget {
            if let url = lookup.url(file.url) {
                if url != file.url { renameFileTarget = OtherFile(url: url, byteSize: file.byteSize) }
            } else {
                renameFileTarget = nil
            }
        }
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
        show.seen = Set(items.map { Self.canonicalPath($0.url) }).union(show.dismissed)
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
    /// So one key pages through images and skims through videos. A PDF in
    /// the full view: its previous / next page; before its first and after
    /// its last page the previous / next item, as at a video's start and end.
    func skim(_ direction: Int) {
        if slideshow == nil, let entry = shownMediaEntry, PDFPages.isPDF(entry.url) {
            // Not open yet (or unreadable): on as from a picture, but not
            // with a key held down
            guard let pdf = pagedPDF else { if !keyRepeating { page(direction) }; return }
            let target = pdf.page + direction
            if (0..<pdf.count).contains(target) { showPDFPage(target) }
            else if !keyRepeating { page(direction) }   // not with a key held down
            return
        }
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
            else if chosen.kind == .folder { show.startInside = Self.canonicalPath(chosen.browseURL) + "/" }
        }
        if show.waitingForStart { show.index = -1 }   // shown once the start has arrived
        let id = show.id
        searchFocused = false
        slideshow = show
        slideshowEnteredFullScreen = setFullScreen(true)
        let key = sortKey, ascending = sortAscending, origin = distanceOrigin, kept = explicitItems
        let startAt = show.startAt.map(Self.canonicalPath), startInside = show.startInside
        let partPause = slideshowPartPause
        slideshowWalk = Task { [weak self] in
            // The show's parts: each search result; over one folder its own
            // media, then each subfolder
            enum Part { case media([GridEntry]), folder(URL) }
            var parts: [Part] = []
            if roots.count == 1, roots[0].kind == .folder {
                let contents = await Self.scan(roots[0].url, kept: kept)
                var captured: [URL: Date] = [:]
                if key == .captured { captured = await Self.captureDates(of: contents.filter(\.isMedia).map(\.url)) }
                let located = key == .distance ? await Self.locations(of: contents) : [:]
                let sorted = Self.sortEntries(contents, key: key, ascending: ascending, captured: captured,
                                              origin: origin, located: located)
                parts = [.media(sorted.filter(\.isMedia))]
                    + sorted.filter { $0.kind == .folder }.map { .folder($0.browseURL) }
            } else {
                parts = roots.map { $0.isMedia ? .media([$0]) : .folder($0.browseURL) }
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
            // What the walk finds goes into the show in a few large steps
            // (each one a pass over the show's items), not one per result
            // or folder
            let arrivals = SlideshowArrivals { [weak self] batches in self?.addToSlideshow(batches, id: id) }
            for (step, number) in ([first] + parts.indices.filter({ $0 != first })).enumerated() {
                if step > 0, let pause = partPause { arrivals.flush(); try? await Task.sleep(for: pause) }
                switch parts[number] {
                case .media(let items):
                    if !items.isEmpty { arrivals.add(items, part: number) }
                case .folder(let url):
                    await Self.walkForSlideshow(url, key: key, ascending: ascending, origin: origin, kept: kept) { batch in
                        arrivals.add(batch, part: number)
                    }
                }
                if Task.isCancelled { return }
            }
            arrivals.flush()
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
    nonisolated static func walkForSlideshow(_ folder: URL, key: SortKey, ascending: Bool, origin: GeoPoint? = nil, kept: Set<String> = [],
                                             found: @MainActor ([GridEntry]) -> Void) async {
        guard !Task.isCancelled else { return }
        let contents = await scan(folder, kept: kept)
        var captured: [URL: Date] = [:]
        if key == .captured { captured = await captureDates(of: contents.filter(\.isMedia).map(\.url)) }
        let located = key == .distance ? await locations(of: contents) : [:]
        guard !Task.isCancelled else { return }
        let sorted = sortEntries(contents, key: key, ascending: ascending, captured: captured, origin: origin, located: located)
        let media = sorted.filter(\.isMedia)
        if !media.isEmpty { await found(media) }
        let folders = sorted.filter { $0.kind == .folder }
        let links = await Blocking.run { Set(folders.filter { isLink($0.url) }.map(\.url)) }
        for sub in folders where !links.contains(sub.url) {
            await walkForSlideshow(sub.url, key: key, ascending: ascending, origin: origin, kept: kept, found: found)
        }
    }

    /// Adds what the walk found, by part, in one pass over the show's
    /// items: each part's new items go after the items it has, so the
    /// parts stay in their order however the walk visits them.
    private func addToSlideshow(_ batches: [(part: Int, items: [GridEntry])], id: UUID) {
        guard var show = slideshow, show.id == id else { return }   // from a cancelled walk
        let lastPart = show.partCounts.count - 1
        var arrived: [Int: [GridEntry]] = [:]
        for (part, batch) in batches {
            let new = batch.filter { show.seen.insert(Self.canonicalPath($0.url)).inserted }
            if !new.isEmpty { arrived[min(part, lastPart), default: []] += new }
        }
        guard !arrived.isEmpty else { return }
        let old = show.items
        let wasEmpty = old.isEmpty
        var items: [GridEntry] = []
        items.reserveCapacity(old.count + arrived.values.reduce(0) { $0 + $1.count })
        var shown: Int?          // the item on screen, where it is now
        var startArrived: Int?   // the item to start at
        var insideArrived: Int?  // the first item of the folder to start in
        var firstAtEnd: Int?     // the first item after all there were
        var cursor = 0
        for part in show.partCounts.indices {
            // (the last part takes any items beyond the counts)
            let end = part == lastPart ? old.count : min(cursor + show.partCounts[part], old.count)
            if (cursor..<end).contains(show.index) { shown = items.count + show.index - cursor }
            items += old[cursor..<end]
            cursor = end
            guard let new = arrived[part] else { continue }
            let offset = items.count
            if startArrived == nil, let startAt = show.startAt,
               let i = new.firstIndex(where: { Self.samePath($0.url, startAt) }) { startArrived = offset + i }
            if insideArrived == nil, let inside = show.startInside,
               let i = new.firstIndex(where: { Self.canonicalPath($0.url).hasPrefix(inside) }) { insideArrived = offset + i }
            if firstAtEnd == nil, cursor == old.count { firstAtEnd = offset }
            items += new
            show.partCounts[part] += new.count
        }
        show.items = items
        // The item on screen keeps its place in the show
        if !wasEmpty, let shown { show.index = shown }
        var moved = wasEmpty && !show.waitingForStart
        if let i = startArrived {
            show.index = i   // the item to start at has arrived
            show.startAt = nil
            moved = true
        } else if let i = insideArrived {
            show.index = i   // the first item of the folder to start in
            show.startInside = nil
            moved = true
        } else if show.waitingForMore, let i = firstAtEnd {
            show.index = i
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
        closePlaylist()
        slideshow = nil
        if slideshowEnteredFullScreen { _ = setFullScreen(false) }
        slideshowEnteredFullScreen = false
    }

    // MARK: - Playlist

    /// The slideshow's playlist (P): its items in the order they play, to
    /// reorder, take out and jump to. It lives as long as the show; nothing
    /// of it is saved.
    @Published private(set) var showPlaylist = false
    /// ↑ ↓ ⌫ ↩ act on the playlist: after a click in it, until a click on
    /// the picture or the playlist closes.
    @Published var playlistFocused = false
    /// The playlist's chosen row (a canonical path, so it stays on its item
    /// while the walk adds more): what ↑ ↓ move and ⌫ takes out.
    @Published private(set) var playlistCursor: String?
    static let playlistPinnedKey = "playlistPinned"
    static let playlistWidthKey = "playlistWidth"
    static let playlistDefaultWidth: Double = 300
    static let playlistWidthRange: ClosedRange<Double> = 200...640
    /// Pinned: the picture makes room beside it; else it lies over the
    /// picture. App-wide, remembered.
    @Published var playlistPinned = false {
        didSet { if playlistPinned != oldValue { defaults.set(playlistPinned, forKey: Self.playlistPinnedKey) } }
    }
    /// Its width in points (the grip on its left edge). App-wide, remembered.
    @Published private(set) var playlistWidth = BrowserModel.playlistDefaultWidth

    /// P: the playlist on or off (only during a slideshow).
    func togglePlaylist() {
        guard slideshow != nil else { return }
        if showPlaylist { closePlaylist(); return }
        // Every pane and window shares pin and width: read them afresh
        playlistPinned = defaults.bool(forKey: Self.playlistPinnedKey)
        if let width = defaults.object(forKey: Self.playlistWidthKey) as? Double { setPlaylistWidth(width) }
        showPlaylist = true
    }

    func closePlaylist() {
        showPlaylist = false
        playlistFocused = false
        playlistCursor = nil
    }

    /// The width dragged to (`remember`: the drag ended); nil is the standard width.
    func setPlaylistWidth(_ width: Double?, remember: Bool = false) {
        let width = width ?? Self.playlistDefaultWidth
        playlistWidth = min(max(width, Self.playlistWidthRange.lowerBound), Self.playlistWidthRange.upperBound)
        if remember { defaults.set(playlistWidth, forKey: Self.playlistWidthKey) }
    }

    /// The row the cursor is on.
    var playlistCursorIndex: Int? {
        guard let cursor = playlistCursor, let items = slideshow?.items else { return nil }
        return items.firstIndex { Self.canonicalPath($0.url) == cursor }
    }

    /// A click on a row: the show goes there, and the list takes the keys.
    func clickPlaylistItem(at index: Int) {
        guard let items = slideshow?.items, items.indices.contains(index) else { return }
        playlistFocused = true
        playlistCursor = Self.canonicalPath(items[index].url)
        playSlideshowItem(at: index)
    }

    /// Jump to an item of the show; a picture gets its full time from now.
    func playSlideshowItem(at index: Int) {
        guard var show = slideshow, show.items.indices.contains(index) else { return }
        show.startAt = nil   // the user has chosen
        show.startInside = nil
        show.waitingForMore = false
        show.index = index
        slideshow = show
        showSlideshowItem()
    }

    /// ↑ ↓ (Home, End) in the playlist: the cursor that many rows on; with
    /// no cursor yet, the first ↑ or ↓ puts it on the item shown.
    func movePlaylistCursor(_ delta: Int) {
        guard let show = slideshow, !show.items.isEmpty else { return }
        let from = playlistCursorIndex ?? min(max(show.index, 0), show.items.count - 1)
        let to = playlistCursorIndex == nil && delta.magnitude == 1
            ? from : min(max(from + max(min(delta, show.items.count), -show.items.count), 0), show.items.count - 1)
        playlistCursor = Self.canonicalPath(show.items[to].url)
    }

    /// Drag & drop in the playlist (`onMove`'s offsets): the items play in
    /// the new order, the one on screen stays on screen. Items the walk
    /// still brings go where their part lies now (moved items join the
    /// part of the item before them).
    func moveSlideshowItems(from source: IndexSet, to destination: Int) {
        guard var show = slideshow else { return }
        let source = IndexSet(source.filter(show.items.indices.contains))
        guard !source.isEmpty, (0...show.items.count).contains(destination) else { return }
        let shown = show.current?.url
        var parts = show.partOfEachItem()
        let moving = source.map { show.items[$0] }
        let ownPart = parts[source.first!]
        for offset in source.reversed() {
            show.items.remove(at: offset)
            parts.remove(at: offset)
        }
        let at = destination - source.count(in: 0..<destination)
        show.items.insert(contentsOf: moving, at: at)
        let joined = at > 0 ? parts[at - 1] : (parts.first ?? ownPart)
        parts.insert(contentsOf: Array(repeating: joined, count: moving.count), at: at)
        show.recount(parts)
        if let shown, let index = show.items.firstIndex(where: { $0.url == shown }) { show.index = index }
        slideshow = show
    }

    /// ⌫ in the playlist: out of the show, the file stays where it is, and
    /// the walk doesn't bring it back. The item on screen taken out: the
    /// next one plays; nothing left and nothing more to come: the show ends.
    func removeFromSlideshow(at offsets: IndexSet) {
        guard var show = slideshow else { return }
        let offsets = IndexSet(offsets.filter(show.items.indices.contains))
        guard let first = offsets.first else { return }
        let shownRemoved = offsets.contains(show.index)
        let before = offsets.count(in: 0..<max(show.index, 0))
        let cursorRemoved = playlistCursorIndex.map(offsets.contains) ?? false
        var parts = show.partOfEachItem()
        for offset in offsets.reversed() {
            show.dismissed.insert(Self.canonicalPath(show.items[offset].url))
            show.items.remove(at: offset)
            parts.remove(at: offset)
        }
        show.recount(parts)
        if show.index >= 0 { show.index -= before }
        if show.items.isEmpty {
            show.index = 0
            show.waitingForMore = false
        } else if show.index >= show.items.count {
            // The last one went: round to the first, or on to what the walk brings
            if show.loading { show.index = show.items.count - 1; show.waitingForMore = true } else { show.index = 0 }
        }
        if cursorRemoved {
            playlistCursor = show.items.isEmpty ? nil : Self.canonicalPath(show.items[min(first, show.items.count - 1)].url)
        }
        slideshow = show
        if show.items.isEmpty, !show.loading { stopSlideshow(); return }
        if shownRemoved { showSlideshowItem() }
    }

    /// Set while another action's key is carried out with one of the
    /// playlist's keys (`WindowModel.perform`): the playlist leaves it alone.
    var playlistKeysOff = false

    /// The keys the playlist takes after a click in it; false: not its key.
    private func playlistKey(_ key: KeyInput) -> Bool {
        guard showPlaylist, playlistFocused else { return false }
        switch key {
        case .up:   movePlaylistCursor(-1)
        case .down: movePlaylistCursor(+1)
        case .home: movePlaylistCursor(-Int.max)
        case .end:  movePlaylistCursor(Int.max)
        case .backspace:
            if let index = playlistCursorIndex { removeFromSlideshow(at: [index]) }
        case .enter:
            if let index = playlistCursorIndex { playSlideshowItem(at: index) }
        default:
            return false
        }
        return true
    }

    /// Keys while the slideshow runs.
    private func handleSlideshowKey(_ key: KeyInput, command: Bool, shift: Bool) -> Bool {
        if !command, !shift, !playlistKeysOff, playlistKey(key) { return true }
        switch key {
        case .escape, .backspace, .enter:
            // The playlist closes first, then the show ends
            if showPlaylist { closePlaylist() } else { stopSlideshow() }
            return true
        case .space:
            toggleSlideshowPause(); return true
        case .left, .right:
            let direction = key == .right ? 1 : -1
            if command { slideshowStep(direction) } else if shift { fineSkim(direction) } else { skim(direction) }
            return true
        case .up, .down:
            // ⌘↑ / ⌘↓ (the enclosing folder, opening) are no navigation here
            return command || verticalKey(up: key == .up)
        case .char(let raw):
            let c = Character(raw.lowercased())   // also with Shift or Caps Lock
            switch c {
            case "s" where !command: stopSlideshow(); return true
            case "p" where !command: togglePlaylist(); return true
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
    /// When the app last changed the item itself (its composition, a seek)
    /// or such a change finished: AVFoundation may report a failure for a
    /// moment around it, which is no fault of the file (`changedLately`).
    private var ownChangeAt = Date.distantPast
    private func noteOwnChange() { ownChangeAt = Date() }
    /// The app changed the item within the last two seconds.
    var changedLately: Bool { Date().timeIntervalSince(ownChangeAt) < 2 }
    /// Feeds the player a video inside an archive (held here: the asset
    /// holds it weakly).
    var resourceLoader: ArchiveResourceLoader?
    private var observation: NSKeyValueObservation?
    private let onStateChange: @MainActor (PlaybackControl, Bool) -> Void

    init(player: AVPlayer, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void = { _, _ in }) {
        self.player = player
        self.onStateChange = onStateChange
        // The subtitles and sound track the app chooses, not the system's
        // accessibility preferences; another speed keeps the pitch
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        observation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.resumeAt == nil else { return }
                // A look set after the last frame was drawn (just before the
                // end) reaches the picture it stops on
                if !playing, self.enhancer?.isStale == true { self.redrawIfPaused() }
                onStateChange(self, playing)
            }
        }
    }

    var isPlaying: Bool { resumeAt?.playing ?? (player.timeControlStatus != .paused) }

    /// Where the video goes on, until the player is there: it stands
    /// (paused, unreported) until the item can seek.
    private var resumeAt: PlaybackPositions.Place?
    private var resumeTask: Task<Void, Never>?
    /// (An item that never gets ready isn't waited for after the player went.)
    deinit { resumeTask?.cancel() }

    /// Starts the video: from the beginning, playing, or where the user left
    /// it (`place`), playing or paused as then. The seek waits until the item
    /// is ready (before, it has nothing it can seek in).
    func begin(at place: PlaybackPositions.Place?) {
        guard let place else { play(); return }
        resumeAt = place
        BrowserModel.testLog("avkit resumes at \(String(format: "%.1f", place.seconds)) s, \(place.playing ? "playing" : "paused")")
        resumeTask = Task { @MainActor [weak self] in
            // (asked every 50 ms, as long as the player is there, at most 10 s)
            var waited = 0
            while let item = self?.player.currentItem, item.status == .unknown, !Task.isCancelled, waited < 200 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            guard let self, !Task.isCancelled, let place = self.resumeAt else { return }
            BrowserModel.testLog("avkit item status \(self.player.currentItem?.status.rawValue ?? -1) after \(waited * 50) ms")
            // A seek of the player's own (a subtitle track chosen, a look
            // redrawn) interrupts this one: it is made again
            for attempt in 1...5 where self.player.currentItem.map({ $0.status != .failed }) == true {
                self.noteOwnChange()
                let done = await self.player.seek(to: CMTime(seconds: place.seconds, preferredTimescale: 600),
                                                  toleranceBefore: .zero, toleranceAfter: .zero)
                self.noteOwnChange()
                BrowserModel.testLog("avkit resume seek \(attempt): \(done ? "there" : "interrupted"), at \(String(format: "%.1f", CMTimeGetSeconds(self.player.currentTime()))) s")
                if done || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // (Space may have changed its mind meanwhile)
            guard !Task.isCancelled, let place = self.resumeAt else { return }
            self.resumeAt = nil
            if place.playing { self.player.play() } else { self.onStateChange(self, false) }
        }
    }

    /// Where it stands (the place it goes on from, while getting there).
    var playedSeconds: Double? {
        if let resumeAt { return resumeAt.seconds }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : nil
    }

    func setVolume(_ volume: Double) { player.volume = Float(volume) }
    var playerVolume: Double? { Double(player.volume) }
    var playerSpeed: Double? { Double(player.defaultRate) }

    // MARK: Tracks and speed

    /// Where the tracks go once they are known (the model).
    var onTracksChanged: @MainActor (PlaybackControl) -> Void = { _ in }
    private var legible: AVMediaSelectionGroup?
    /// The subtitles to choose from: the "forced" ones AVFoundation adds for
    /// each language left out (they show only forced lines).
    private var subtitleOptions: [AVMediaSelectionOption] = []
    private var audible: AVMediaSelectionGroup?
    /// A file whose sound tracks are in no alternate group (AVFoundation
    /// would play them all at once): one is chosen by enabling it alone.
    private var audioItemTracks: [(track: AVPlayerItemTrack, language: String?)] = []
    private var tracksTask: Task<Void, Never>?

    /// Reads the video's subtitle and sound tracks (once).
    func loadTracks() {
        guard tracksTask == nil, let item = player.currentItem else { return }
        let asset = item.asset
        tracksTask = Task { [weak self] in
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            guard let self, !Task.isCancelled else { return }
            self.legible = legible
            self.subtitleOptions = legible?.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? []
            self.audible = (audible?.options.count ?? 0) > 1 ? audible : nil
            if self.audible == nil, let sound = try? await asset.loadTracks(withMediaType: .audio), sound.count > 1 {
                var languages: [CMPersistentTrackID: String] = [:]
                for track in sound {
                    let tag = try? await track.load(.extendedLanguageTag)
                    let code = try? await track.load(.languageCode)
                    languages[track.trackID] = (tag ?? nil) ?? (code ?? nil)
                }
                // The item's tracks come once it is ready to play
                for _ in 0..<50 where !Task.isCancelled {
                    let tracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
                    if tracks.count > 1 {
                        self.audioItemTracks = tracks.map { ($0, $0.assetTrack.flatMap { languages[$0.trackID] }) }
                        let playing = tracks.firstIndex { $0.isEnabled } ?? 0
                        for (index, track) in tracks.enumerated() { track.isEnabled = index == playing }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            guard !Task.isCancelled else { return }
            self.onTracksChanged(self)
        }
    }

    var tracks: VideoTracks {
        var tracks = VideoTracks()
        guard let item = player.currentItem else { return tracks }
        func track(_ option: AVMediaSelectionOption, _ index: Int) -> MediaTrack {
            let name = option.displayName.isEmpty ? String(localized: "Track \(index + 1)") : option.displayName
            return MediaTrack(id: index, name: name, language: option.extendedLanguageTag ?? option.locale?.identifier)
        }
        tracks.subtitles = subtitleOptions.enumerated().map { track($0.element, $0.offset) }
        if let legible, let selected = item.currentMediaSelection.selectedMediaOption(in: legible) {
            tracks.subtitleID = subtitleOptions.firstIndex(of: selected)
        }
        if let audible {
            tracks.audio = audible.options.enumerated().map { track($0.element, $0.offset) }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: audible) {
                tracks.audioID = audible.options.firstIndex(of: selected)
            }
        } else if !audioItemTracks.isEmpty {
            tracks.audio = audioItemTracks.enumerated().map {
                MediaTrack(id: $0.offset, name: MediaTrack.name(title: nil, language: $0.element.language, number: $0.offset + 1),
                           language: $0.element.language)
            }
            tracks.audioID = audioItemTracks.firstIndex { $0.track.isEnabled }
        }
        return tracks
    }

    func selectSubtitleTrack(_ id: Int?) {
        guard let item = player.currentItem, let legible else { return }
        let option = id.flatMap { subtitleOptions.indices.contains($0) ? subtitleOptions[$0] : nil }
        let shown = item.currentMediaSelection.selectedMediaOption(in: legible)
        guard shown != option else { return }
        item.select(option, in: legible)
        refreshSubtitles(clearing: option == nil && shown != nil)
    }

    /// The view that shows the picture (`AVPlayerLayerHost`).
    weak var layerView: AVPlayerLayerHost.PlayerLayerView?

    /// AVKit draws a newly chosen subtitle track only from its next line on,
    /// and keeps a line of the one left on screen until that line ends (seen
    /// on CI, macOS 15 and 26): a seek to where the video stands draws the
    /// choice at once.
    /// Subtitles switched off (`clearing`): on macOS 15 the player layer
    /// sometimes goes on drawing the line it showed, also the next ones,
    /// seek or not (seen on CI); a layer of its own anew, once the seek is
    /// done, shows the picture without it.
    private func refreshSubtitles(clearing: Bool = false) {
        Task { @MainActor [weak self] in
            // (once the item can seek)
            for _ in 0..<50 {
                guard let self, let item = self.player.currentItem else { return }
                // Getting to where it was left: that seek draws the choice
                if self.resumeAt != nil { try? await Task.sleep(for: .milliseconds(100)); continue }
                if item.status == .readyToPlay {
                    self.noteOwnChange()
                    self.player.seek(to: self.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in self?.noteOwnChange() }
                        guard clearing else { return }
                        Task { @MainActor [weak self] in self?.clearSubtitleLine() }
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func clearSubtitleLine() {
        if #available(macOS 26, *) { return }
        BrowserModel.testLog("avkit subtitles off: a new player layer")
        layerView?.renewLayer()
    }

    func selectAudioTrack(_ id: Int) {
        if let audible, let item = player.currentItem, audible.options.indices.contains(id) {
            item.select(audible.options[id], in: audible)
        } else if audioItemTracks.indices.contains(id) {
            for (index, entry) in audioItemTracks.enumerated() { entry.track.isEnabled = index == id }
        }
    }

    /// `play()` starts at `defaultRate`; playing, the rate changes at once.
    func setSpeed(_ speed: Double) {
        player.defaultRate = Float(speed)
        if player.rate != 0 { player.rate = Float(speed) }
    }

    var videoSize: CGSize? {
        let size = player.currentItem?.presentationSize ?? .zero
        return size.width > 0 && size.height > 0 ? size : nil
    }

    func streamFacts() async -> StreamFacts? {
        guard let asset = player.currentItem?.asset else { return nil }
        return await StreamFacts.of(asset)
    }

    /// At the end, playing starts over. While getting to the place it goes
    /// on from, it then plays there.
    func play() {
        if let place = resumeAt {
            resumeAt = PlaybackPositions.Place(seconds: place.seconds, playing: true)
            return
        }
        if let item = player.currentItem {
            let duration = CMTimeGetSeconds(item.duration)
            if duration.isFinite, duration > 0, CMTimeGetSeconds(player.currentTime()) >= duration - 0.05 {
                noteOwnChange()
                player.seek(to: .zero) { [weak self] _ in Task { @MainActor in self?.noteOwnChange() } }
            }
        }
        player.play()
    }

    func pause() {
        if let place = resumeAt {
            resumeAt = PlaybackPositions.Place(seconds: place.seconds, playing: false)
            return
        }
        player.pause()
    }

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
        noteOwnChange()
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
        // (getting to where it was left: that seek draws the look)
        guard !isPlaying, resumeAt == nil else { return }
        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !self.isPlaying, self.resumeAt == nil else { return }
            let now = self.player.currentTime()
            if let frame = self.frameDuration, now.seconds.isFinite {
                // A quarter and a half into the frame shown, by turns
                let start = (now.seconds / frame).rounded(.down) * frame
                self.nudgeLater.toggle()
                let target = CMTime(seconds: start + frame * (self.nudgeLater ? 0.5 : 0.25), preferredTimescale: 600_000)
                BrowserModel.testLog("avkit redraw at \(target.seconds)")
                self.noteOwnChange()
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor in self?.noteOwnChange() }
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
            self.noteOwnChange()
            self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in self?.noteOwnChange() }
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
        noteOwnChange()
        player.seek(to: CMTime(seconds: duration * min(max(progress, 0), 1), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.noteOwnChange() }
        }
        if ended { player.play() }
    }

    /// Whether an error of AVFoundation's says the file's data can't be read
    /// or decoded (itself or what it was caused by), the only failures VLC
    /// takes a whole file over for: a format AVFoundation doesn't read, data
    /// it can't parse or decode, a file it can't read (gone, cut short).
    nonisolated static func isDataFailure(_ error: NSError?) -> Bool {
        var current = error
        while let error = current {
            if error.domain == AVFoundationErrorDomain {
                let codes: Set<AVError.Code> = [.decodeFailed, .fileFormatNotRecognized, .failedToParse, .fileFailedToParse,
                                                .noDataCaptured, .contentIsUnavailable, .noSourceTrack, .undecodableMediaData]
                if let code = AVError.Code(rawValue: error.code), codes.contains(code) { return true }
            }
            if error.domain == NSPOSIXErrorDomain || error.domain == NSCocoaErrorDomain && [CocoaError.fileReadUnknown.rawValue,
                CocoaError.fileReadCorruptFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileReadTooLarge.rawValue].contains(error.code) {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
