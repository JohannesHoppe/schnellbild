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

    /// For a later volume, the names its first volume can have
    /// ("x.part2.rar" → "x.part1.rar", "x.part01.rar" …); empty for anything else.
    static func firstVolumeNames(of name: String) -> [String] {
        let lower = name.lowercased() as NSString
        let ext = lower.pathExtension
        let stem = (name as NSString).deletingPathExtension
        if ext == "rar", let part = rarPart(of: name), part > 1 {
            let base = (stem as NSString).deletingPathExtension
            return ["\(base).part1.rar", "\(base).part01.rar", "\(base).part001.rar"]
        }
        if ext.count == 3, ext.hasPrefix("r"), Int(ext.dropFirst()) != nil { return ["\(stem).rar"] }
        if ext.count == 3, ext.hasPrefix("z"), Int(ext.dropFirst()) != nil { return ["\(stem).zip"] }
        if ext.count == 3, let n = Int(ext), n > 1 { return ["\(stem).001"] }
        return []
    }

    /// The files libarchive reads one after the other: "x.7z.001", ".002" …;
    /// "x.z01", "x.z02" … and "x.zip" last; else the file itself. Reads the
    /// folder, so off the main thread.
    static func volumes(of url: URL) -> [URL] {
        let name = url.lastPathComponent
        // The folder is listed only for names that can have further parts
        if name.lowercased().hasSuffix(".001") {
            let folder = Siblings(of: url)
            let stem = String(name.dropLast(4))
            var parts: [URL] = []
            for i in 1... {
                guard let part = folder[stem + String(format: ".%03d", i)] else { break }
                parts.append(part)
            }
            return parts.isEmpty ? [url] : parts
        }
        if (name as NSString).pathExtension.lowercased() == "zip" {
            let folder = Siblings(of: url)
            let stem = (name as NSString).deletingPathExtension
            var parts: [URL] = []
            for i in 1... {
                guard let part = folder[stem + String(format: ".z%02d", i)] else { break }
                parts.append(part)
            }
            return parts + [url]
        }
        return [url]
    }

    /// Every file of the archive on disk (for the Trash and for moving): its
    /// volumes, for a RAR also "x.partN.rar" or "x.r00" ….
    static func allFiles(of url: URL) -> [URL] {
        guard format(of: url.lastPathComponent) == .rar else { return volumes(of: url) }
        let folder = Siblings(of: url)
        // The parts are named after the archive's final name (the first part
        // can still be downloading: "x.part1.rar.part")
        let name = finalName(of: url.lastPathComponent)
        let lower = name.lowercased()
        var files = [url]
        if rarPart(of: lower) != nil {
            let stem = ((name as NSString).deletingPathExtension as NSString).deletingPathExtension
            for i in 2... {
                let candidates = [String(format: "%@.part%d.rar", stem, i), String(format: "%@.part%02d.rar", stem, i),
                                  String(format: "%@.part%03d.rar", stem, i)]
                guard let found = candidates.lazy.compactMap({ folder[$0] }).first else { break }
                files.append(found)
            }
        } else {
            let stem = (name as NSString).deletingPathExtension
            for i in 0... {
                guard let part = folder[String(format: "%@.r%02d", stem, i)] else { break }
                files.append(part)
            }
        }
        return files
    }

    /// The files next to an archive, looked up by name ignoring case (the
    /// volumes of "MOVIE.PART1.RAR" are "MOVIE.PART2.RAR" …, also on
    /// case-sensitive volumes). The folder is listed once.
    private struct Siblings {
        private let byName: [String: URL]
        init(of url: URL) {
            let folder = url.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            byName = Dictionary(names.map { ($0.lowercased(), folder.appendingPathComponent($0)) }, uniquingKeysWith: { a, _ in a })
        }
        subscript(name: String) -> URL? { byName[name.lowercased()] }
    }
}

extension GridEntry {
    /// An archive on disk, shown as a folder (not one inside another archive,
    /// not a real folder named like one).
    var isArchive: Bool { kind == .folder && ArchivePath.split(url).map { $0.inner.isEmpty } ?? false }
}

/// A place inside an archive is a file URL running through the archive
/// file: ".../Holiday.zip/Day 1/a.jpg". The model, the history and the grid
/// treat it like any folder or file; reading goes through `ArchiveStore`.
enum ArchivePath {
    /// The archive and the path inside it ("" for its top), for a URL
    /// through an archive; nil otherwise. By the name only (no file system
    /// access), except that folders named like an archive which a listing
    /// has met (`noteFolder`) are folders.
    static func split(_ url: URL) -> (archive: URL, inner: String)? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 1 else { return nil }
        for i in 1..<components.count where ArchiveName.format(of: components[i]) != nil {
            let path = NSString.path(withComponents: Array(components[...i]))
            if isNotedFolder(path) { continue }
            let archive = URL(fileURLWithPath: path, isDirectory: false)
            return (archive, components[(i + 1)...].joined(separator: "/"))
        }
        return nil
    }

    private static let foldersLock = NSLock()
    nonisolated(unsafe) private static var folders: Set<String> = []

    /// A real folder with an archive's name ("Trip.zip/"), met when listing.
    static func noteFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        foldersLock.lock(); folders.insert(path); foldersLock.unlock()
    }

    /// An archive file met when listing, where a folder of that name was
    /// before (trashed and replaced).
    static func noteArchive(_ url: URL) {
        let path = url.standardizedFileURL.path
        foldersLock.lock(); folders.remove(path); foldersLock.unlock()
    }

    private static func isNotedFolder(_ path: String) -> Bool {
        foldersLock.lock(); defer { foldersLock.unlock() }
        return folders.contains(path)
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
        guard FileManager.default.fileExists(atPath: found.archive.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            noteFolder(found.archive)
            return splitChecked(url)   // an archive further in, if any
        }
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
    /// Larger than a picture read into memory may be (`ArchiveStore.largestRead`).
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .needsPassword:          return String(localized: "Wrong password for this archive.")
        case .encryptionUnsupported:  return String(localized: "Schnellbild can't open encrypted 7z archives.")
        case .incomplete:             return String(localized: "The archive is incomplete: still downloading, a part missing, or damaged.")
        case .notFound:               return String(localized: "A file listed in this archive is missing.")
        case .unreadable(let reason): return String(localized: "The archive can't be read: \(reason)")
        case .tooLarge:               return String(localized: "This file is too large to show from inside an archive.")
        }
    }
}

// MARK: - Entries and readers

/// One entry of an archive. `path` is "/"-separated, without a leading or
/// trailing "/".
struct ArchiveItem: Equatable {
    let path: String
    let isDirectory: Bool
    /// Unpacked; -1 where the archive doesn't say.
    let size: Int64
    var knownSize: Int? { size >= 0 ? Int(size) : nil }
    let modified: Date?
    let encrypted: Bool
    /// A RAR hard link or file copy: the entry whose data it has (it has
    /// none of its own).
    var source: String? = nil
}

/// What a walk does with an entry.
enum ArchiveVisit {
    case skip
    case stop
    /// The data in chunks; the sink returns false to end the walk there
    /// (the reader goes no further, not even past the rest of the entry).
    /// `done` follows, with the reason when it didn't end well (nil when the
    /// sink stopped it).
    case read(sink: (UnsafeRawBufferPointer) -> Bool, done: (ArchiveError?) -> Void)
}

/// Reads an archive front to back (the formats are streams; ZIP's central
/// directory makes skipping cheap). Runs on a background thread.
protocol ArchiveReader {
    /// Returns whether the archive was read to its end (false: a partial
    /// download, or a later volume is missing; true also when the visitor
    /// ended the walk). `listOnly` reads the names without unpacking (no
    /// `.read` then).
    func walk(password: String?, listOnly: Bool, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool
}

extension ArchiveReader {
    /// Reads the first file entry at `path` through `sink` and ends the walk
    /// there. Returns nil when it was read whole (or the sink ended it),
    /// else why not: `.notFound` when the walk never got to it (also when
    /// `stop` ended the walk first).
    func readEntry(_ path: String, password: String?, stop: @escaping () -> Bool = { false },
                   sink: @escaping (UnsafeRawBufferPointer) -> Bool) throws -> ArchiveError? {
        var outcome: ArchiveError? = .notFound
        var done = false
        _ = try walk(password: password, listOnly: false) { item in
            if done || stop() { return .stop }
            guard item.path == path, !item.isDirectory else { return .skip }
            return .read(sink: sink, done: { outcome = $0; done = true })
        }
        return outcome
    }
}

/// RAR (all versions, solid, volumes, passwords) through UnRAR.
struct RarReader: ArchiveReader {
    let url: URL

    /// Solid (reaching a file means unpacking every file before it), and
    /// part of a set of volumes.
    static func flags(_ url: URL, password: String?) -> (solid: Bool, volume: Bool) {
        var result: Int32 = 0
        var asked: Int32 = 0
        guard let rar = sb_rar_open(url.path, password, 1, &result, &asked) else { return (false, false) }
        defer { sb_rar_close(rar) }
        return (sb_rar_solid(rar) != 0, sb_rar_volume(rar) != 0)
    }

    func walk(password: String?, listOnly: Bool, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool {
        var result: Int32 = 0
        var asked: Int32 = 0
        guard let rar = sb_rar_open(url.path, password, listOnly ? 1 : 0, &result, &asked) else {
            throw Self.error(result, passwordAsked: asked != 0)
        }
        defer { sb_rar_close(rar) }
        var entry = SBRarEntry()
        var seen = 0
        while true {
            let r = sb_rar_next(rar, &entry)
            // ERAR_END_ARCHIVE; a download still in progress ends where it has got to
            if r == 10 { return sb_rar_volume_missing(rar) == 0 && !ArchiveName.isPartial(url.lastPathComponent) }
            if r != 0 {
                // Encrypted names: a wrong password shows as damaged data
                if seen == 0, sb_rar_headers_encrypted(rar) != 0 { throw ArchiveError.needsPassword }
                if seen > 0 || sb_rar_volume_missing(rar) != 0 { return false }   // ends early
                throw Self.error(r, passwordAsked: sb_rar_password_asked(rar) != 0)
            }
            seen += 1
            if entry.split_before != 0 { _ = sb_rar_skip(rar); continue }   // the rest of a file from the last volume
            // A hard link or file copy: a file with another entry's data,
            // listed with it (a read gets its data through that entry)
            var source: String?
            if entry.redirect_type == 4 || entry.redirect_type == 5 {
                var buffer = [CChar](repeating: 0, count: 4096 * 4)
                sb_rar_redirect_utf8(&entry, &buffer, buffer.count)
                let cleaned = Self.clean(String(cString: buffer).replacingOccurrences(of: "\\", with: "/"))
                if !cleaned.isEmpty { source = cleaned }
            }
            // A link or junction (nothing to show, no data to check a
            // password on); a copy has no data of its own to read
            if entry.redirect_type != 0 && (source == nil || !listOnly) { _ = sb_rar_skip(rar); continue }
            let name = withUnsafeBytes(of: &entry.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            // UnRAR's placeholder for a size not stored (a file packed from a stream)
            let size = entry.size == 0x7fff_ffff_7fff_ffff ? -1 : Int64(clamping: entry.size)
            let item = ArchiveItem(path: Self.clean(name), isDirectory: entry.is_directory != 0, size: size,
                                   modified: entry.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(entry.modified)) : nil,
                                   encrypted: entry.is_encrypted != 0, source: source)
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
                if r == 0 { done(nil); if box.stopped { return true }; continue }
                if sb_rar_volume_missing(rar) != 0 { done(.incomplete); return false }
                // A wrong password: RAR5 says so, RAR4 fails its checksum
                if r == 22 || r == 24 || (item.encrypted && r == 12) { done(.needsPassword) }
                else { done(Self.error(r, passwordAsked: false)) }
            }
        }
    }

    private final class SinkBox {
        private let wrapped: (UnsafeRawBufferPointer) -> Bool
        /// The sink ended the walk.
        var stopped = false
        init(_ sink: @escaping (UnsafeRawBufferPointer) -> Bool) { wrapped = sink }
        func sink(_ bytes: UnsafeRawBufferPointer) -> Bool {
            if wrapped(bytes) { return true }
            stopped = true
            return false
        }
    }

    /// A path inside the archive: no empty, "." or ".." parts (an entry
    /// named "../x.jpg" stays inside the archive, as "x.jpg").
    static func clean(_ path: String) -> String {
        path.split(separator: "/").filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
    }

    static func error(_ code: Int32, passwordAsked: Bool) -> ArchiveError {
        switch code {
        case 22, 24: return .needsPassword
        case 12 where passwordAsked: return .needsPassword
        case 11: return .unreadable(String(localized: "out of memory"))
        case 12: return .unreadable(String(localized: "damaged data"))
        case 13: return .unreadable(String(localized: "damaged archive"))
        case 14: return .unreadable(String(localized: "unknown format"))
        case 15: return .unreadable(String(localized: "can't open the file"))
        case 18: return .unreadable(String(localized: "read error"))
        default: return .unreadable(String(localized: "UnRAR error \(Int(code))"))
        }
    }
}

/// ZIP and 7z through the system's libarchive. ZIP is read by its central
/// directory; without one (a download still in progress, a split archive)
/// front to back.
struct LibArchiveReader: ArchiveReader {
    let volumes: [URL]
    let format: ArchiveFormat

    /// libarchive converts entry names (7z's UTF-16, ZIP's UTF-8 flag) into
    /// the locale's character set; the app's is plain ASCII unless set, and
    /// a name with "Ü" would then be lost. Set for the reading thread only.
    nonisolated(unsafe) private static let utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", nil)

    func walk(password: String?, listOnly: Bool, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool {
        let previous = uselocale(Self.utf8)
        defer { uselocale(previous) }
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
        guard let archive = archive_read_new() else { throw ArchiveError.unreadable(String(localized: "out of memory")) }
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
            let name = Self.name(of: entry)
            let isDirectory = (archive_entry_filetype(entry) & mode_t(SB_AE_IFMT)) == mode_t(SB_AE_IFDIR) || name.hasSuffix("/")
            let item = ArchiveItem(path: RarReader.clean(name), isDirectory: isDirectory,
                                   // Not stored in the header (a ZIP written with data descriptors, read as a stream)
                                   size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : -1,
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
                if stopped { return true }
                if failure == .incomplete { return false }
            }
        }
    }

    /// An entry's name: UTF-8 where the archive says so or the bytes are
    /// valid UTF-8; else a ZIP name in a legacy code page (no UTF-8 flag:
    /// Windows' Explorer and older tools write the system's DOS code page),
    /// read in the code page of the user's language, else DOS Latin 1, so
    /// distinct names stay distinct.
    static func name(of entry: OpaquePointer) -> String {
        if let utf8 = archive_entry_pathname_utf8(entry), let name = String(validatingCString: utf8) { return name }
        guard let raw = archive_entry_pathname(entry) else { return "" }
        return legacyName(Data(bytes: raw, count: strlen(raw)))
    }

    static func legacyName(_ bytes: Data) -> String {
        if let name = String(data: bytes, encoding: .utf8) { return name }
        for encoding in legacyEncodings {
            if let name = String(data: bytes, encoding: encoding) { return name }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The DOS / Windows code pages tried for names, by the user's language;
    /// DOS Latin 1 (CP850) last, which reads any byte.
    static let legacyEncodings: [String.Encoding] = {
        func cf(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        let language = Locale.preferredLanguages.first.map { Locale(identifier: $0).language } ?? Locale.Language(identifier: "en")
        var list: [String.Encoding] = []
        switch language.languageCode?.identifier {
        case "ja": list = [.shiftJIS]
        case "zh": list = [language.script?.identifier == "Hant" ? cf(.big5) : cf(.GB_18030_2000)]
        case "ko": list = [cf(.dosKorean)]
        case "ru", "uk", "be", "bg": list = [cf(.dosRussian)]
        case "el": list = [cf(.dosGreek)]
        case "tr": list = [cf(.dosTurkish)]
        case "cs", "pl", "hu", "sk", "sl", "hr", "ro": list = [cf(.dosLatin2)]
        default: break
        }
        return list + [cf(.dosLatin1)]
    }()

    static func error(_ archive: OpaquePointer) -> ArchiveError {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? String(localized: "unknown error")
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
    /// nil: the store can't be read now (a locked keychain, access denied),
    /// which is not the same as no passwords.
    private let load: () -> [String]?
    private let save: ([String]) -> Void
    private var cached: [String]?
    /// Passwords that opened something while the store couldn't be read:
    /// used, and written into the stored list once it can be read.
    private var unsaved: [String] = []
    /// When reading the store last failed: asked again only after a while
    /// (every index build asks; a keychain that refuses must not be asked
    /// for each archive).
    private var failedAt: Date?
    private let retryAfter: TimeInterval

    init(load: @escaping () -> [String]?, save: @escaping ([String]) -> Void, retryAfter: TimeInterval = 60) {
        self.load = load
        self.save = save
        self.retryAfter = retryAfter
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return unsaved + (cached ?? []).filter { !unsaved.contains($0) }
    }

    /// A password that opened an archive: first in line from now on.
    func remember(_ password: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard var list = cached else {
            unsaved.removeAll { $0 == password }
            unsaved.insert(password, at: 0)
            return
        }
        if list.first == password { return }
        list.removeAll { $0 == password }
        list.insert(password, at: 0)
        cached = list
        save(list)
    }

    /// Reads the store once (again after a failure, after a while); what was
    /// kept unsaved meanwhile goes into it. Called with the lock held.
    private func loadIfNeeded() {
        guard cached == nil else { return }
        if let failedAt, Date().timeIntervalSince(failedAt) < retryAfter { return }
        guard let loaded = load() else { failedAt = Date(); return }
        failedAt = nil
        guard !unsaved.isEmpty else { cached = loaded; return }
        let merged = unsaved + loaded.filter { !unsaved.contains($0) }
        unsaved = []
        cached = merged
        save(merged)
    }

    /// Every saved password goes (Settings): archives that need one ask again.
    func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        unsaved = []
        cached = []
        failedAt = nil
        save([])
    }

    /// How many are saved (Settings).
    var count: Int { all.count }

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
            let status = SecItemCopyMatching(search as CFDictionary, &found)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess, let data = found as? Data,
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
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
        /// Read to the end (false: a partial download, or a missing volume).
        let complete: Bool
        let password: String?
        /// Reaching a file unpacks all before it (solid RAR, 7z): a pass
        /// keeps the pictures it unpacks on the way.
        var solid = false
        /// Read only in part, or one of several volumes: its other files
        /// can change without the first one changing (a missing volume
        /// arrives), so the folder's date is part of its version.
        var watchesFolder = false
        /// The reader it was read with (a ZIP's volumes found once).
        var reader: ArchiveReader?
        /// The archive file's path and version: the byte cache's keys (the
        /// index of the same version read again finds its bytes; a new
        /// version of the file never gets an old one's).
        let bytesKey: String
        /// Entries by their folder ("" for the top), folders implied by
        /// the paths included.
        let children: [String: [ArchiveItem]]
        let byPath: [String: ArchiveItem]

        init(items: [ArchiveItem], complete: Bool, password: String?, bytesKey: String) {
            self.complete = complete
            self.password = password
            self.bytesKey = bytesKey
            var byPath: [String: ArchiveItem] = [:]
            // Not the AppleDouble files the Finder adds to ZIPs ("__MACOSX/")
            for item in items where !item.path.isEmpty && item.path != "__MACOSX" && !item.path.hasPrefix("__MACOSX/") {
                if byPath[item.path] == nil || item.isDirectory { byPath[item.path] = item }
                // The folders above it, which archives often don't list
                var parent = (item.path as NSString).deletingLastPathComponent
                while !parent.isEmpty, byPath[parent] == nil {
                    byPath[parent] = ArchiveItem(path: parent, isDirectory: true, size: 0, modified: item.modified, encrypted: false)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            self.byPath = byPath
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
        /// The containing folder's date when the index was read.
        var folderDate: Date?
        var index: Index?
        /// The version no remembered password opened, and the passwords then.
        var failed: (version: FileVersion?, passwords: [String])?
        var pending: [String: [(id: UUID, continuation: CheckedContinuation<Data, Error>)]] = [:]
        var passRunning = false
        var lastUse = 0
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

    private static func folderDate(of url: URL) -> Date? {
        (try? url.deletingLastPathComponent().resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private var archives: [String: Archive] = [:]
    private var uses = 0
    /// Archives kept with their index; the ones not used longest (and idle) go.
    private static let keptArchives = 200

    /// Forgets the saved passwords, and the archives a password opened
    /// (those not being read right now): they ask again when opened next.
    func forgetPasswords() {
        passwords.forgetAll()
        lock.lock(); defer { lock.unlock() }
        for (key, archive) in archives where archive.index?.password != nil
            && archive.pending.isEmpty && !archive.passRunning {
            archives[key] = nil
        }
    }

    private func archive(_ url: URL) -> Archive {
        let key = BrowserModel.canonicalPath(url)
        lock.lock(); defer { lock.unlock() }
        uses += 1
        if let found = archives[key] { found.lastUse = uses; return found }
        let made = Archive(path: key)
        made.lastUse = uses
        archives[key] = made
        if archives.count > Self.keptArchives {
            let idle = archives.filter { $0.value.pending.isEmpty && !$0.value.passRunning && $0.value !== made }
            for (old, _) in idle.sorted(by: { $0.value.lastUse < $1.value.lastUse }).prefix(archives.count - Self.keptArchives) {
                archives[old] = nil
            }
        }
        return made
    }

    /// What the file is, by its first bytes (comics are often named .cbr
    /// although they are ZIPs, and the other way round); else by its name.
    static func format(of url: URL) -> ArchiveFormat? {
        sniffedFormat(url) ?? ArchiveName.format(of: url.lastPathComponent)
    }

    static func reader(for url: URL, format: ArchiveFormat? = nil) -> ArchiveReader? {
        switch format ?? Self.format(of: url) {
        case .rar:      return RarReader(url: url)
        case .zip:      return LibArchiveReader(volumes: ArchiveName.volumes(of: url), format: .zip)
        case .sevenZip: return LibArchiveReader(volumes: ArchiveName.volumes(of: url), format: .sevenZip)
        case nil:       return nil
        }
    }

    /// The format a file's signature says, if it says one.
    static func sniffedFormat(_ url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 6), head.count >= 4 else { return nil }
        let bytes = [UInt8](head)
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21]) { return .rar }               // "Rar!"
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }   // "PK"
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        return nil
    }

    // MARK: Index

    /// The archive's entries, read once per version of the file. `password`
    /// is one the user just typed: tried first, and remembered when it opens
    /// the archive. Throws `.needsPassword` when no password opens it.
    func index(of url: URL, trying password: String? = nil) async throws -> Index {
        let archive = archive(url)
        // Known: at once, not behind an unpacking pass on the archive's queue
        if password == nil, let known = current(archive, url: url, version: FileVersion(url)) { return known }
        return try await withCheckedThrowingContinuation { continuation in
            archive.queue.async {
                continuation.resume(with: Result { try self.indexOnQueue(archive, url: url, trying: password) })
            }
        }
    }

    private func indexOnQueue(_ archive: Archive, url: URL, trying typed: String?) throws -> Index {
        let version = FileVersion(url)
        if typed == nil, let known = current(archive, url: url, version: version) { return known }
        let folderDate = Self.folderDate(of: url)
        guard let format = Self.format(of: url), let reader = Self.reader(for: url, format: format) else {
            throw ArchiveError.unreadable(String(localized: "unknown format"))
        }
        let remembered = passwords.all
        // No remembered password opened this version of the file: not tried
        // again until a password is typed or another is remembered
        lock.lock()
        let failedBefore = typed == nil && archive.failed.map { $0.version == version && $0.passwords == remembered } == true
        lock.unlock()
        if failedBefore { throw ArchiveError.needsPassword }
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
            // (not hard links or copies: their data is another entry's)
            let protected = items.filter { $0.encrypted && !$0.isDirectory && $0.source == nil }
            // libarchive can't decrypt 7z: no password would help
            if !protected.isEmpty, format == .sevenZip {
                throw ArchiveError.encryptionUnsupported
            }
            // Encrypted data: the password that unpacks a protected file with
            // something in it (an empty one opens with any password): in a
            // solid archive the first such (reaching a later one unpacks all
            // before it), else the smallest
            let flags = format == .rar ? RarReader.flags(url, password: candidate) : (solid: false, volume: false)
            let solid = format == .sevenZip || flags.solid
            let filled = protected.filter { $0.size > 0 }
            if let probe = (solid ? filled.first : filled.min(by: { $0.size < $1.size })) ?? protected.first {
                let tries: [String] = candidate.map { [$0] } ?? remembered
                guard let working = tries.first(where: { Self.opens(reader, probe, with: $0) }) else {
                    if candidate == nil {   // all were tried
                        lock.lock(); archive.failed = (version, remembered); lock.unlock()
                        throw ArchiveError.needsPassword
                    }
                    continue
                }
                password = working
            }
            if let password { passwords.remember(password) }
            let index = Index(items: items, complete: complete, password: password,
                              bytesKey: "\(BrowserModel.canonicalPath(url))|\(version?.size ?? 0)|\(version?.modified?.timeIntervalSince1970 ?? 0)")
            index.solid = solid
            index.reader = reader
            index.watchesFolder = !complete || flags.volume || ((reader as? LibArchiveReader)?.volumes.count ?? 1) > 1
            lock.lock()
            archive.index = index
            archive.version = version
            archive.folderDate = folderDate
            archive.failed = nil
            lock.unlock()
            return index
        }
        // Encrypted names no remembered password opens
        if typed == nil { lock.lock(); archive.failed = (version, remembered); lock.unlock() }
        throw ArchiveError.needsPassword
    }

    /// The index read for this version of the file, if still good. For an
    /// archive read only in part or in volumes, also the folder must be as
    /// it was: a volume added, finished or replaced changes the folder, not
    /// the first volume.
    private func current(_ archive: Archive, url: URL, version: FileVersion?) -> Index? {
        lock.lock()
        let index = archive.index, matches = archive.version == version, folderDate = archive.folderDate
        lock.unlock()
        guard let index, matches else { return nil }
        if index.watchesFolder, Self.folderDate(of: url) != folderDate { return nil }
        return index
    }

    private static func opens(_ reader: ArchiveReader, _ probe: ArchiveItem, with password: String?) -> Bool {
        guard let password else { return false }
        do { return try reader.readEntry(probe.path, password: password, sink: { _ in true }) == nil }
        catch { return false }
    }

    // MARK: Reading

    /// An entry's data. Requests for one archive are served together, in
    /// one pass in the archive's order.
    func data(of url: URL) async throws -> Data {
        guard let (archiveURL, inner) = ArchivePath.split(url), !inner.isEmpty else { throw ArchiveError.notFound }
        let index = try await index(of: archiveURL)
        guard let listed = index.byPath[inner], !listed.isDirectory,
              // A hard link or file copy reads its source's data
              let item = listed.source.map({ index.byPath[$0] }) ?? listed, !item.isDirectory else { throw ArchiveError.notFound }
        if let cached = bytes.object(forKey: Self.bytesKey(index, item.path)) { return cached as Data }
        // A picture is read into memory whole: a stated size beyond any
        // picture (a zip bomb) isn't unpacked at all
        if item.size > Self.largestRead { throw ArchiveError.tooLarge }
        let archive = archive(archiveURL)
        // A request given up (a tile scrolled away) leaves the line: the
        // pass doesn't unpack it for nobody
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                archive.pending[item.path, default: []].append((id, continuation))
                let start = !archive.passRunning
                archive.passRunning = true
                lock.unlock()
                if start { archive.queue.async { self.servePending(archive, url: archiveURL, index: index) } }
            }
        } onCancel: {
            lock.lock()
            let mine = archive.pending[item.path]?.first { $0.id == id }
            archive.pending[item.path]?.removeAll { $0.id == id }
            if archive.pending[item.path]?.isEmpty == true { archive.pending[item.path] = nil }
            lock.unlock()
            mine?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Passes front to back until nothing is waiting. A pass serves what is
    /// waiting when it gets to it; a request for an entry the pass has
    /// already gone by waits for the next pass.
    private func servePending(_ archive: Archive, url: URL, index: Index) {
        guard let reader = index.reader ?? Self.reader(for: url) else {
            lock.lock()
            let waiting = Array(archive.pending.keys)
            archive.passRunning = false
            lock.unlock()
            for path in waiting { finish(archive, path, .failure(ArchiveError.unreadable(String(localized: "unknown format")))) }
            return
        }
        while true {
            lock.lock()
            if archive.pending.isEmpty { archive.passRunning = false; lock.unlock(); return }
            lock.unlock()
            // Answered in this pass; gone by without being read; the pass
            // ended on purpose (nothing more waiting, an entry too large)
            var served = Set<String>()
            var passed = Set<String>()
            var ended = false
            func waiting(for path: String) -> (this: Bool, any: Bool) {
                lock.lock(); defer { lock.unlock() }
                return (archive.pending[path] != nil, archive.pending.keys.contains { !served.contains($0) })
            }
            let walked = Result {
                try reader.walk(password: index.password, listOnly: false) { item in
                    let (wanted, anyLeft) = waiting(for: item.path)
                    guard anyLeft else { ended = true; return .stop }
                    guard !item.isDirectory else { return .skip }
                    let key = Self.bytesKey(index, item.path)
                    // In a solid archive the pictures on the way are unpacked
                    // anyway: kept for the next request (paging through a comic)
                    let keep = !wanted && index.solid && item.size > 0 && item.size < Self.keptEntryLimit
                        && BrowserModel.mediaKind(of: URL(fileURLWithPath: item.path, isDirectory: false)) == .image && self.bytes.object(forKey: key) == nil
                    guard wanted || keep else { passed.insert(item.path); return .skip }
                    if wanted, item.size > Self.largestRead {
                        served.insert(item.path)
                        self.finish(archive, item.path, .failure(ArchiveError.tooLarge))
                        return .skip
                    }
                    let limit = wanted ? Self.largestRead : Self.keptEntryLimit
                    var data = Data()
                    if item.size > 0 { data.reserveCapacity(Int(min(item.size, limit))) }
                    var dropped = false   // nobody wants it any more: its bytes go
                    var tooLarge = false
                    var chunks = 0
                    return .read(sink: { bytes in
                        if dropped { return true }
                        data.append(contentsOf: bytes)
                        if Int64(data.count) > limit {
                            // More than the archive said, or no size said
                            if wanted { tooLarge = true; ended = true; return false }
                            dropped = true; data = Data()
                            return true
                        }
                        chunks += 1
                        // Every few MB: still wanted? (a tile scrolled away)
                        if wanted, chunks % 16 == 0 {
                            let now = waiting(for: item.path)
                            if !now.this {
                                if !now.any { ended = true; return false }
                                dropped = true; data = Data()
                            }
                        }
                        return true
                    }, done: { failure in
                        if tooLarge {
                            served.insert(item.path)
                            self.finish(archive, item.path, .failure(ArchiveError.tooLarge))
                            return
                        }
                        if dropped || ended { passed.insert(item.path); return }
                        if failure == nil, data.count < Self.keptEntryLimit {
                            self.bytes.setObject(data as NSData, forKey: key, cost: data.count)
                        }
                        guard wanted else { return }
                        served.insert(item.path)
                        self.finish(archive, item.path, failure.map { .failure($0) } ?? .success(data))
                    })
                }
            }
            // Ended on purpose: what still waits gets the next pass
            if ended { continue }
            // Waiting for an entry the pass never met: not there (the
            // archive ended early, or doesn't have it). Entries it went by
            // before they were asked for get the next pass.
            lock.lock()
            let unreached = archive.pending.keys.filter { !served.contains($0) && !passed.contains($0) }
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

    /// Entries read lately (pictures, up to 32 MB each), by index and path;
    /// the system empties it when memory runs short.
    private let bytes: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()
    private static let keptEntryLimit: Int64 = 32 << 20
    /// The most read into memory for one entry: beyond any camera's picture
    /// (a 100-megapixel RAW is about 200 MB); more is a decompression bomb
    /// or not a picture.
    static let largestRead: Int64 = 256 << 20

    private static func bytesKey(_ index: Index, _ path: String) -> NSString {
        "\(index.bytesKey)/\(path)" as NSString
    }

    private func finish(_ archive: Archive, _ path: String, _ result: Result<Data, Error>) {
        lock.lock()
        let waiting = archive.pending.removeValue(forKey: path) ?? []
        lock.unlock()
        waiting.forEach { $0.continuation.resume(with: result) }
    }

    // MARK: For the grid

    /// A folder of an archive: its folders and media files as grid entries,
    /// and its other files (archives inside archives among them: not opened).
    func listing(in url: URL, trying password: String? = nil) async throws -> FolderListing {
        guard let (archiveURL, inner) = ArchivePath.split(url) else { return FolderListing() }
        let index = try await index(of: archiveURL, trying: password)
        var listing = FolderListing()
        for item in index.children[inner] ?? [] {
            let itemURL = archiveURL.appendingPathComponent(item.path, isDirectory: item.isDirectory)
            if item.isDirectory {
                listing.entries.append(GridEntry(url: itemURL, kind: .folder, modDate: item.modified))
            } else if let kind = BrowserModel.mediaKind(of: itemURL) {
                listing.entries.append(GridEntry(url: itemURL, kind: kind, modDate: item.modified, byteSize: item.knownSize))
            } else if !itemURL.lastPathComponent.hasPrefix(".") {
                listing.others.append(OtherFile(url: itemURL, byteSize: item.knownSize))
            }
        }
        listing.others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return listing
    }

    /// The media files at any depth below a folder of an archive, in path order.
    func media(below url: URL) async throws -> [URL] {
        guard let (archiveURL, inner) = ArchivePath.split(url) else { return [] }
        let index = try await index(of: archiveURL)
        let prefix = inner.isEmpty ? "" : inner + "/"
        return index.byPath.values
            // (URLs built without asking the file system whether they are folders)
            .filter { !$0.isDirectory && $0.path.hasPrefix(prefix)
                && BrowserModel.mediaKind(of: URL(fileURLWithPath: $0.path, isDirectory: false)) != nil }
            .map(\.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { archiveURL.appendingPathComponent($0, isDirectory: false) }
    }

    /// Names `matcher` takes, at any depth below a folder of an archive.
    func matches(below url: URL, matching matcher: NameMatcher) async throws -> [GridEntry] {
        guard let (archiveURL, inner) = ArchivePath.split(url) else { return [] }
        let index = try await index(of: archiveURL)
        let prefix = inner.isEmpty ? "" : inner + "/"
        return index.byPath.values.compactMap { item in
            guard item.path.hasPrefix(prefix),
                  matcher.matches((item.path as NSString).lastPathComponent) else { return nil }
            let itemURL = archiveURL.appendingPathComponent(item.path, isDirectory: item.isDirectory)
            if item.isDirectory { return GridEntry(url: itemURL, kind: .folder, modDate: item.modified) }
            guard let kind = BrowserModel.mediaKind(of: itemURL) else { return nil }
            return GridEntry(url: itemURL, kind: kind, modDate: item.modified, byteSize: item.knownSize)
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
        // The same limit as inside archives: a multi-gigabyte "picture.svg"
        // isn't read into memory
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if Int64(size) > ArchiveStore.largestRead { throw ArchiveError.tooLarge }
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
}
