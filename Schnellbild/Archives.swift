import Foundation
import AppKit
import ImageIO
import Security
import CArchives

// MARK: - Names and paths

enum ArchiveFormat: Equatable {
    case zip, rar, sevenZip
}

/// Which files are archives the grid opens like folders. A split archive is
/// shown once, by its first volume; a download still in progress
/// ("x.rar.part", "x.zip.crdownload") counts by the name it will have.
enum ArchiveName {
    /// Endings of downloads still in progress: Firefox, Chrome, qBittorrent, others.
    static let partialSuffixes = ["part", "crdownload", "!qb", "partial", "download"]

    /// The name without a download's in-progress ending.
    static func finalName(of name: String) -> String {
        let lower = name.lowercased()
        for suffix in partialSuffixes where lower.hasSuffix("." + suffix) {
            return String(name.dropLast(suffix.count + 1))
        }
        return name
    }

    static func isPartial(_ name: String) -> Bool { finalName(of: name) != name }

    /// The format of a file shown as an archive, nil for anything else
    /// (also for the later volumes of a split archive).
    static func format(of name: String) -> ArchiveFormat? {
        guard !name.hasPrefix("._") else { return nil }
        let base = finalName(of: name).lowercased() as NSString
        switch base.pathExtension {
        case "zip", "cbz": return .zip
        case "7z", "cb7":  return .sevenZip
        case "rar", "cbr":
            // "x.part2.rar" and later are read through "x.part1.rar"
            if let part = rarPart(of: base as String), part != 1 { return nil }
            return .rar
        case "001":   // a split by bytes: "x.7z.001", "x.zip.001"
            switch (base.deletingPathExtension as NSString).pathExtension {
            case "7z":  return .sevenZip
            case "zip": return .zip
            default:    return nil
            }
        default:
            return nil
        }
    }

    /// The N of "x.partN.rar".
    static func rarPart(of name: String) -> Int? {
        let stem = (name.lowercased() as NSString).deletingPathExtension as NSString
        guard stem.pathExtension.hasPrefix("part") else { return nil }
        return Int(stem.pathExtension.dropFirst(4))
    }

    /// Whether a name alone says the archive has further volumes.
    static func isSplitByName(_ name: String) -> Bool {
        let base = finalName(of: name).lowercased()
        return rarPart(of: base) != nil || base.hasSuffix(".001")
    }

    /// The files libarchive reads one after the other: "x.7z.001", ".002" …;
    /// "x.z01", "x.z02" … and "x.zip" last; else the file itself. Reads the
    /// folder, so off the main thread.
    static func volumes(of url: URL) -> [URL] {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".001") {
            let stem = String(name.dropLast(4))
            var parts: [URL] = []
            for i in 1... {
                let part = folder.appendingPathComponent(stem + String(format: ".%03d", i))
                guard fm.fileExists(atPath: part.path) else { break }
                parts.append(part)
            }
            return parts.isEmpty ? [url] : parts
        }
        if (name as NSString).pathExtension.lowercased() == "zip" {
            let stem = (name as NSString).deletingPathExtension
            var parts: [URL] = []
            for i in 1... {
                let part = folder.appendingPathComponent(stem + String(format: ".z%02d", i))
                guard fm.fileExists(atPath: part.path) else { break }
                parts.append(part)
            }
            return parts + [url]
        }
        return [url]
    }

    /// Every file of the archive on disk (for the Trash): its volumes, for a
    /// RAR also "x.partN.rar" or "x.r00" ….
    static func allFiles(of url: URL) -> [URL] {
        guard format(of: url.lastPathComponent) == .rar else { return volumes(of: url) }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let lower = url.lastPathComponent.lowercased()
        var files = [url]
        if rarPart(of: lower) != nil {
            let stem = ((url.lastPathComponent as NSString).deletingPathExtension as NSString).deletingPathExtension
            for i in 2... {
                let candidates = [String(format: "%@.part%d.rar", stem, i), String(format: "%@.part%02d.rar", stem, i),
                                  String(format: "%@.part%03d.rar", stem, i)]
                guard let found = candidates.map({ folder.appendingPathComponent($0) })
                    .first(where: { fm.fileExists(atPath: $0.path) }) else { break }
                files.append(found)
            }
        } else {
            let stem = (url.lastPathComponent as NSString).deletingPathExtension
            for i in 0... {
                let part = folder.appendingPathComponent(String(format: "%@.r%02d", stem, i))
                guard fm.fileExists(atPath: part.path) else { break }
                files.append(part)
            }
        }
        return files
    }
}

/// A place inside an archive is a file URL running through the archive
/// file: ".../Holiday.zip/Day 1/a.jpg". The model, the history and the grid
/// treat it like any folder or file; reading goes through `ArchiveStore`.
enum ArchivePath {
    /// The archive and the path inside it ("" for its top), for a URL
    /// through an archive; nil otherwise. By the name only (no file system
    /// access): a folder named like an archive is told apart when listing.
    static func split(_ url: URL) -> (archive: URL, inner: String)? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 1 else { return nil }
        for i in 1..<components.count where ArchiveName.format(of: components[i]) != nil {
            let archive = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...i])))
            return (archive, components[(i + 1)...].joined(separator: "/"))
        }
        return nil
    }

    /// A file or folder inside an archive (not the archive itself).
    static func isInside(_ url: URL) -> Bool {
        guard let (_, inner) = split(url) else { return false }
        return !inner.isEmpty
    }

    /// Splits only where the archive is a real file, not a folder named
    /// like one. Touches the file system.
    static func splitChecked(_ url: URL) -> (archive: URL, inner: String)? {
        guard let found = split(url) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: found.archive.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return found
    }
}

// MARK: - Errors

enum ArchiveError: LocalizedError, Equatable {
    /// Protected, and none of the remembered passwords opens it.
    case needsPassword
    /// Encrypted 7z (libarchive can't decrypt it).
    case encryptionUnsupported
    /// Ends before this entry: still downloading, or a volume is missing.
    case incomplete
    case notFound
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .needsPassword:          return String(localized: "That password doesn't open it. Try another one.")
        case .encryptionUnsupported:  return String(localized: "Encrypted 7z archives can't be opened.")
        case .incomplete:             return String(localized: "The archive ends early: it is still downloading, or a part is missing.")
        case .notFound:               return String(localized: "The archive can't be read: \("missing entry")")
        case .unreadable(let reason): return String(localized: "The archive can't be read: \(reason)")
        }
    }
}

// MARK: - Entries and readers

/// One entry of an archive. `path` is "/"-separated, without a leading or
/// trailing "/".
struct ArchiveItem: Equatable {
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let encrypted: Bool
}

/// What a walk does with an entry.
enum ArchiveVisit {
    case skip
    case stop
    /// The data in chunks; the sink returns false to stop reading. `done`
    /// follows, with the reason when it didn't end well.
    case read(sink: (UnsafeRawBufferPointer) -> Bool, done: (ArchiveError?) -> Void)
}

/// Reads an archive front to back (the formats are streams; ZIP's central
/// directory makes skipping cheap). Runs on a background thread.
protocol ArchiveReader {
    /// Returns whether the archive was read to its end (false: a partial
    /// download, or a later volume is missing). `listOnly` reads the names
    /// without unpacking (no `.read` then).
    func walk(password: String?, listOnly: Bool, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool
}

/// RAR (all versions, solid, volumes, passwords) through UnRAR.
struct RarReader: ArchiveReader {
    let url: URL

    func walk(password: String?, listOnly: Bool, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool {
        var result: Int32 = 0
        var asked: Int32 = 0
        guard let rar = sb_rar_open(url.path, password, listOnly ? 1 : 0, &result, &asked) else {
            throw Self.error(result, passwordGiven: password != nil, passwordAsked: asked != 0)
        }
        defer { sb_rar_close(rar) }
        var entry = SBRarEntry()
        var seen = 0
        while true {
            let r = sb_rar_next(rar, &entry)
            if r == 10 { return sb_rar_volume_missing(rar) == 0 }   // ERAR_END_ARCHIVE
            if r != 0 {
                // Encrypted names: a wrong password shows as damaged data
                if seen == 0, sb_rar_headers_encrypted(rar) != 0 { throw ArchiveError.needsPassword }
                if seen > 0 || sb_rar_volume_missing(rar) != 0 { return false }   // ends early
                throw Self.error(r, passwordGiven: password != nil, passwordAsked: sb_rar_password_asked(rar) != 0)
            }
            seen += 1
            if entry.split_before != 0 { _ = sb_rar_skip(rar); continue }   // the rest of a file from the last volume
            let name = withUnsafeBytes(of: &entry.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let item = ArchiveItem(path: Self.clean(name), isDirectory: entry.is_directory != 0, size: Int64(entry.size),
                                   modified: entry.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(entry.modified)) : nil,
                                   encrypted: entry.is_encrypted != 0)
            switch visit(item) {
            case .stop:
                return true
            case .skip:
                if sb_rar_skip(rar) != 0 { return false }
            case .read(let sink, let done):
                let box = SinkBox(sink)
                let r = sb_rar_read(rar, { context, bytes, count in
                    let box = Unmanaged<SinkBox>.fromOpaque(context!).takeUnretainedValue()
                    return box.sink(UnsafeRawBufferPointer(start: bytes, count: count)) ? 1 : 0
                }, Unmanaged.passUnretained(box).toOpaque())
                withExtendedLifetime(box) {}
                if r == 0 { done(nil); continue }
                if sb_rar_volume_missing(rar) != 0 { done(.incomplete); return false }
                // A wrong password: RAR5 says so, RAR4 fails its checksum
                if r == 22 || r == 24 || (item.encrypted && r == 12) { done(.needsPassword) }
                else { done(Self.error(r, passwordGiven: false, passwordAsked: false)) }
            }
        }
    }

    private final class SinkBox {
        let sink: (UnsafeRawBufferPointer) -> Bool
        init(_ sink: @escaping (UnsafeRawBufferPointer) -> Bool) { self.sink = sink }
    }

    static func clean(_ path: String) -> String {
        path.split(separator: "/").filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
    }

    static func error(_ code: Int32, passwordGiven: Bool, passwordAsked: Bool) -> ArchiveError {
        switch code {
        case 22, 24: return .needsPassword
        case 12 where passwordAsked: return .needsPassword
        case 11: return .unreadable("out of memory")
        case 12: return .unreadable("damaged data")
        case 13: return .unreadable("damaged archive")
        case 14: return .unreadable("unknown format")
        case 15: return .unreadable("can't open the file")
        case 18: return .unreadable("read error")
        default: return .unreadable("UnRAR error \(code)")
        }
    }
}

/// ZIP and 7z through the system's libarchive. ZIP is read by its central
/// directory; without one (a download still in progress, a split archive)
/// front to back.
struct LibArchiveReader: ArchiveReader {
    let volumes: [URL]
    let format: ArchiveFormat

    func walk(password: String?, listOnly: Bool, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool {
        let seekable = format == .zip && volumes.count == 1
        do {
            return try walk(seekable: seekable, password: password, visit)
        } catch ArchiveError.unreadable(let reason) where seekable {
            // No central directory (still downloading): front to back
            do { return try walk(seekable: false, password: password, visit) }
            catch ArchiveError.unreadable { throw ArchiveError.unreadable(reason) }
        }
    }

    private func walk(seekable: Bool, password: String?, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool {
        guard let archive = archive_read_new() else { throw ArchiveError.unreadable("out of memory") }
        defer { archive_read_free(archive) }
        switch format {
        case .zip where seekable: archive_read_support_format_zip_seekable(archive)
        case .zip:                archive_read_support_format_zip_streamable(archive)
        default:                  archive_read_support_format_7zip(archive)
        }
        if let password { archive_read_add_passphrase(archive, password) }
        let paths = volumes.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        var names: [UnsafePointer<CChar>?] = paths.map { UnsafePointer($0) } + [nil]
        let opened = names.withUnsafeMutableBufferPointer { archive_read_open_filenames(archive, $0.baseAddress, 1 << 20) }
        guard opened == SB_ARCHIVE_OK else { throw Self.error(archive) }
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        var seen = 0
        while true {
            var entry: OpaquePointer?
            let r = archive_read_next_header(archive, &entry)
            if r == SB_ARCHIVE_EOF { return true }
            guard r == SB_ARCHIVE_OK || r == SB_ARCHIVE_WARN, let entry else {
                if seen > 0 { return false }   // ends early: a partial download
                throw Self.error(archive)
            }
            seen += 1
            let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
            let name = raw.map { String(cString: $0) } ?? ""
            let isDirectory = (archive_entry_filetype(entry) & mode_t(SB_AE_IFMT)) == mode_t(SB_AE_IFDIR) || name.hasSuffix("/")
            let item = ArchiveItem(path: RarReader.clean(name), isDirectory: isDirectory,
                                   size: archive_entry_size(entry),
                                   modified: { let t = archive_entry_mtime(entry); return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil }(),
                                   encrypted: archive_entry_is_encrypted(entry) != 0)
            switch visit(item) {
            case .stop:
                return true
            case .skip:
                if archive_read_data_skip(archive) < SB_ARCHIVE_WARN { return false }
            case .read(let sink, let done):
                var failure: ArchiveError?
                var stopped = false
                while !stopped {
                    let n = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
                    if n == 0 { break }
                    if n < 0 { failure = Self.error(archive); break }
                    stopped = !buffer.withUnsafeBytes { sink(UnsafeRawBufferPointer(rebasing: $0[..<n])) }
                }
                done(failure)
                if failure == .incomplete { return false }
            }
        }
    }

    static func error(_ archive: OpaquePointer) -> ArchiveError {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "unknown error"
        let lower = message.lowercased()
        if lower.contains("passphrase") { return .needsPassword }
        if lower.contains("encrypt") { return .encryptionUnsupported }
        if lower.contains("truncated") { return .incomplete }
        return .unreadable(message)
    }
}

// MARK: - Passwords

/// The passwords that opened protected archives, all of them, tried on every
/// protected archive (most recently used first). Kept in the login keychain;
/// UI tests keep them in their own preferences, unit tests in memory.
final class PasswordStore: @unchecked Sendable {
    private let lock = NSLock()
    private let load: () -> [String]
    private let save: ([String]) -> Void
    private var cached: [String]?

    init(load: @escaping () -> [String], save: @escaping ([String]) -> Void) {
        self.load = load
        self.save = save
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        if cached == nil { cached = load() }
        return cached ?? []
    }

    /// A password that opened an archive: first in line from now on.
    func remember(_ password: String) {
        lock.lock(); defer { lock.unlock() }
        var list = cached ?? load()
        if list.first == password { cached = list; return }
        list.removeAll { $0 == password }
        list.insert(password, at: 0)
        cached = list
        save(list)
    }

    static func memory() -> PasswordStore {
        let box = Box()
        return PasswordStore(load: { box.list }, save: { box.list = $0 })
    }
    private final class Box { var list: [String] = [] }

    static func defaults(_ defaults: UserDefaults, key: String = "archivePasswords") -> PasswordStore {
        PasswordStore(load: { defaults.stringArray(forKey: key) ?? [] }, save: { defaults.set($0, forKey: key) })
    }

    static let keychainService = "art.haushoppe.schnellbild.archive-passwords"

    static func keychain() -> PasswordStore {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: keychainService, kSecAttrAccount: "all"]
        return PasswordStore(load: {
            var found: CFTypeRef?
            var search = query
            search[kSecReturnData] = true
            guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess,
                  let data = found as? Data,
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return list
        }, save: { list in
            guard let data = try? JSONEncoder().encode(list) else { return }
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData] = data
                item[kSecAttrLabel] = "Schnellbild archive passwords"
                SecItemAdd(item as CFDictionary, nil)
            }
        })
    }
}

// MARK: - The store

/// What the app knows about each archive: its entries (read once per
/// version of the file, kept while the app runs), the password that opens
/// it, and the reads waiting for it. Reads of one archive are served in one
/// pass front to back, in the archive's order: a solid RAR is unpacked once
/// for all the thumbnails asked for, not once per thumbnail.
final class ArchiveStore: @unchecked Sendable {
    static let shared = ArchiveStore()

    private let lock = NSLock()
    private var _passwords = PasswordStore.memory()
    var passwords: PasswordStore {
        get { lock.lock(); defer { lock.unlock() }; return _passwords }
        set { lock.lock(); _passwords = newValue; lock.unlock() }
    }

    /// One archive's entries.
    final class Index {
        let items: [ArchiveItem]
        /// Read to the end (false: a partial download, or a missing volume).
        let complete: Bool
        let password: String?
        /// Entries by their folder ("" for the top), folders implied by
        /// the paths included.
        let children: [String: [ArchiveItem]]
        let byPath: [String: ArchiveItem]

        init(items: [ArchiveItem], complete: Bool, password: String?) {
            self.complete = complete
            self.password = password
            var byPath: [String: ArchiveItem] = [:]
            for item in items where !item.path.isEmpty {
                if byPath[item.path] == nil || item.isDirectory { byPath[item.path] = item }
                // The folders above it, which archives often don't list
                var parent = (item.path as NSString).deletingLastPathComponent
                while !parent.isEmpty, byPath[parent] == nil {
                    byPath[parent] = ArchiveItem(path: parent, isDirectory: true, size: 0, modified: item.modified, encrypted: false)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            self.byPath = byPath
            self.items = items
            var children: [String: [ArchiveItem]] = [:]
            for item in byPath.values {
                children[(item.path as NSString).deletingLastPathComponent, default: []].append(item)
            }
            self.children = children
        }
    }

    private final class Archive {
        let queue: DispatchQueue
        var version: FileVersion?
        var index: Index?
        var pending: [String: [CheckedContinuation<Data, Error>]] = [:]
        var passRunning = false
        init(path: String) { queue = DispatchQueue(label: "archive \(path)", qos: .userInitiated) }
    }

    /// Size and date of the archive file: a new version (a download that
    /// grew) is read again.
    private struct FileVersion: Equatable {
        let size: Int64
        let modified: Date?
        init?(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            size = Int64(values.fileSize ?? 0)
            modified = values.contentModificationDate
        }
    }

    private var archives: [String: Archive] = [:]

    private func archive(_ url: URL) -> Archive {
        let key = BrowserModel.canonicalPath(url)
        lock.lock(); defer { lock.unlock() }
        if let found = archives[key] { return found }
        let made = Archive(path: key)
        archives[key] = made
        return made
    }

    static func reader(for url: URL) -> ArchiveReader? {
        switch ArchiveName.format(of: url.lastPathComponent) {
        case .rar:      return RarReader(url: url)
        case .zip:      return LibArchiveReader(volumes: ArchiveName.volumes(of: url), format: .zip)
        case .sevenZip: return LibArchiveReader(volumes: ArchiveName.volumes(of: url), format: .sevenZip)
        case nil:       return nil
        }
    }

    // MARK: Index

    /// The archive's entries, read once per version of the file. `password`
    /// is one the user just typed: tried first, and remembered when it opens
    /// the archive. Throws `.needsPassword` when no password opens it.
    func index(of url: URL, trying password: String? = nil) async throws -> Index {
        let archive = archive(url)
        return try await withCheckedThrowingContinuation { continuation in
            archive.queue.async {
                continuation.resume(with: Result { try self.indexOnQueue(archive, url: url, trying: password) })
            }
        }
    }

    private func indexOnQueue(_ archive: Archive, url: URL, trying typed: String?) throws -> Index {
        let version = FileVersion(url)
        if let index = archive.index, archive.version == version, typed == nil { return index }
        guard let reader = Self.reader(for: url) else { throw ArchiveError.unreadable("unknown format") }
        let remembered = passwords.all
        // A password just typed is the only one tried; else none first, then
        // every remembered one.
        let candidates: [String?] = typed.map { [$0] } ?? ([nil] + remembered.map(Optional.some))
        for candidate in candidates {
            var items: [ArchiveItem] = []
            let complete: Bool
            do {
                complete = try reader.walk(password: candidate, listOnly: true) { items.append($0); return .skip }
            } catch ArchiveError.needsPassword {
                continue   // the names are encrypted: the next password
            }
            var password = candidate
            let protected = items.filter { $0.encrypted && !$0.isDirectory }
            // libarchive can't decrypt 7z: no password would help
            if !protected.isEmpty, ArchiveName.format(of: url.lastPathComponent) == .sevenZip {
                throw ArchiveError.encryptionUnsupported
            }
            // Encrypted data: the password that unpacks the smallest protected file
            if let probe = protected.min(by: { $0.size < $1.size }) {
                let tries: [String] = candidate.map { [$0] } ?? remembered
                guard let working = tries.first(where: { Self.opens(reader, probe, with: $0) }) else {
                    if candidate == nil { throw ArchiveError.needsPassword }   // all were tried
                    continue
                }
                password = working
            }
            if let password { passwords.remember(password) }
            let index = Index(items: items, complete: complete, password: password)
            archive.index = index
            archive.version = version
            return index
        }
        throw ArchiveError.needsPassword
    }

    private static func opens(_ reader: ArchiveReader, _ probe: ArchiveItem, with password: String?) -> Bool {
        guard let password else { return false }
        var ok = false
        _ = try? reader.walk(password: password, listOnly: false) { item in
            guard item.path == probe.path else { return .skip }
            return .read(sink: { _ in true }, done: { ok = $0 == nil })
        }
        return ok
    }

    // MARK: Reading

    /// An entry's data. Requests for one archive are served together, in
    /// one pass in the archive's order.
    func data(of url: URL) async throws -> Data {
        guard let (archiveURL, inner) = ArchivePath.split(url), !inner.isEmpty else { throw ArchiveError.notFound }
        let index = try await index(of: archiveURL)
        guard let item = index.byPath[inner], !item.isDirectory else { throw ArchiveError.notFound }
        let archive = archive(archiveURL)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            archive.pending[item.path, default: []].append(continuation)
            let start = !archive.passRunning
            archive.passRunning = true
            lock.unlock()
            if start { archive.queue.async { self.servePending(archive, url: archiveURL, index: index) } }
        }
    }

    /// Passes front to back until nothing is waiting.
    private func servePending(_ archive: Archive, url: URL, index: Index) {
        guard let reader = Self.reader(for: url) else { return }
        while true {
            lock.lock()
            let wanted = Set(archive.pending.keys)
            if wanted.isEmpty { archive.passRunning = false; lock.unlock(); return }
            lock.unlock()
            var served = Set<String>()
            let walked = Result {
                try reader.walk(password: index.password, listOnly: false) { item in
                    lock.lock()
                    let waiting = archive.pending[item.path] != nil
                    let anyLeft = archive.pending.keys.contains { !served.contains($0) }
                    lock.unlock()
                    guard anyLeft else { return .stop }
                    guard waiting, !item.isDirectory else { return .skip }
                    var data = Data()
                    if item.size > 0 { data.reserveCapacity(Int(min(item.size, 512 << 20))) }
                    return .read(sink: { data.append(contentsOf: $0); return true }, done: { failure in
                        served.insert(item.path)
                        self.finish(archive, item.path, failure.map { .failure($0) } ?? .success(data))
                    })
                }
            }
            // Whatever the pass didn't reach: not there (the archive ended early)
            lock.lock()
            let unreached = wanted.subtracting(served)
            lock.unlock()
            for path in unreached {
                let failure: ArchiveError
                switch walked {
                case .failure(let error as ArchiveError): failure = error
                case .failure(let error): failure = .unreadable(error.localizedDescription)
                case .success(let complete): failure = complete ? .notFound : .incomplete
                }
                finish(archive, path, .failure(failure))
            }
        }
    }

    private func finish(_ archive: Archive, _ path: String, _ result: Result<Data, Error>) {
        lock.lock()
        let waiting = archive.pending.removeValue(forKey: path) ?? []
        lock.unlock()
        waiting.forEach { $0.resume(with: result) }
    }

    /// An entry written to `file`, in chunks (videos: the players read
    /// files).
    func extract(_ url: URL, to file: URL) async throws {
        guard let (archiveURL, inner) = ArchivePath.split(url), !inner.isEmpty else { throw ArchiveError.notFound }
        let index = try await index(of: archiveURL)
        guard index.byPath[inner] != nil, let reader = Self.reader(for: archiveURL) else { throw ArchiveError.notFound }
        let archive = archive(archiveURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            archive.queue.async {
                FileManager.default.createFile(atPath: file.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: file) else {
                    continuation.resume(throwing: ArchiveError.unreadable("can't write \(file.lastPathComponent)"))
                    return
                }
                var outcome: ArchiveError? = .notFound
                do {
                    _ = try reader.walk(password: index.password, listOnly: false) { item in
                        guard item.path == inner else { return .skip }
                        return .read(sink: { chunk in handle.write(Data(chunk)); return true },
                                     done: { outcome = $0 })
                    }
                } catch let error as ArchiveError {
                    outcome = error
                } catch {
                    outcome = .unreadable(error.localizedDescription)
                }
                try? handle.close()
                if let outcome { continuation.resume(throwing: outcome) } else { continuation.resume() }
            }
        }
    }

    /// Forget an archive (a changed password list tries it afresh).
    func forget(_ url: URL) {
        let archive = archive(url)
        archive.queue.async { archive.index = nil; archive.version = nil }
    }

    // MARK: For the grid

    /// The folders and media files in a folder of an archive, as grid entries.
    func entries(in url: URL, trying password: String? = nil) async throws -> [GridEntry] {
        guard let (archiveURL, inner) = ArchivePath.split(url) else { return [] }
        let index = try await index(of: archiveURL, trying: password)
        return (index.children[inner] ?? []).compactMap { item in
            let itemURL = archiveURL.appendingPathComponent(item.path, isDirectory: item.isDirectory)
            if item.isDirectory { return GridEntry(url: itemURL, kind: .folder, modDate: item.modified) }
            guard let kind = BrowserModel.mediaKind(of: itemURL),
                  ArchiveName.format(of: item.path) == nil else { return nil }   // no archives in archives
            return GridEntry(url: itemURL, kind: kind, modDate: item.modified, byteSize: Int(item.size))
        }
    }

    /// The media files at any depth below a folder of an archive, in path order.
    func media(below url: URL) async throws -> [URL] {
        guard let (archiveURL, inner) = ArchivePath.split(url) else { return [] }
        let index = try await index(of: archiveURL)
        let prefix = inner.isEmpty ? "" : inner + "/"
        return index.byPath.values
            .filter { !$0.isDirectory && $0.path.hasPrefix(prefix) && BrowserModel.mediaKind(of: URL(fileURLWithPath: $0.path)) != nil }
            .map(\.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { archiveURL.appendingPathComponent($0) }
    }

    /// Names matching `query` at any depth below a folder of an archive.
    func matches(below url: URL, query: String) async throws -> [GridEntry] {
        guard let (archiveURL, inner) = ArchivePath.split(url) else { return [] }
        let index = try await index(of: archiveURL)
        let prefix = inner.isEmpty ? "" : inner + "/"
        return index.byPath.values.compactMap { item in
            guard item.path.hasPrefix(prefix),
                  (item.path as NSString).lastPathComponent.localizedCaseInsensitiveContains(query) else { return nil }
            let itemURL = archiveURL.appendingPathComponent(item.path, isDirectory: item.isDirectory)
            if item.isDirectory { return GridEntry(url: itemURL, kind: .folder, modDate: item.modified) }
            guard let kind = BrowserModel.mediaKind(of: itemURL) else { return nil }
            return GridEntry(url: itemURL, kind: kind, modDate: item.modified, byteSize: Int(item.size))
        }
    }
}

// MARK: - Media from disk or from an archive

enum MediaData {
    /// A file's bytes, from disk or from inside an archive.
    static func read(_ url: URL) async throws -> Data {
        if ArchivePath.isInside(url), ArchivePath.splitChecked(url) != nil {
            return try await ArchiveStore.shared.data(of: url)
        }
        return try Data(contentsOf: url)
    }

    /// An image source for a picture, from disk or from inside an archive.
    static func imageSource(_ url: URL) async -> CGImageSource? {
        if ArchivePath.isInside(url), ArchivePath.splitChecked(url) != nil {
            guard let data = try? await ArchiveStore.shared.data(of: url) else { return nil }
            return CGImageSourceCreateWithData(data as CFData, nil)
        }
        return CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    /// A file the players can open: the file itself, or for a video inside
    /// an archive a copy in the temporary folder (the last few are kept).
    static func playableFile(_ url: URL) async throws -> URL {
        guard ArchivePath.isInside(url), ArchivePath.splitChecked(url) != nil else { return url }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Schnellbild archive videos", isDirectory: true)
        let key = BrowserModel.canonicalPath(url)
        if let cached = await PlayableCopies.shared.file(for: key) { return cached }
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(url.lastPathComponent)
        try await ArchiveStore.shared.extract(url, to: file)
        await PlayableCopies.shared.add(file, for: key)
        return file
    }

    /// Copies left from an earlier run.
    static func removeOldCopies() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Schnellbild archive videos", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The videos copied out of archives: the newest few stay, older ones go.
actor PlayableCopies {
    static let shared = PlayableCopies()
    private var copies: [(key: String, file: URL)] = []
    private let keep = 3

    func file(for key: String) -> URL? {
        guard let found = copies.first(where: { $0.key == key }),
              FileManager.default.fileExists(atPath: found.file.path) else { return nil }
        return found.file
    }

    func add(_ file: URL, for key: String) {
        copies.append((key, file))
        while copies.count > keep {
            let old = copies.removeFirst()
            try? FileManager.default.removeItem(at: old.file.deletingLastPathComponent())
        }
    }
}
