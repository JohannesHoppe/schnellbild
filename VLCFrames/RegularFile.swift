import Foundation

/// How every file someone else made is opened for reading, by the app and
/// its thumbnail extension: only a regular file, opened without waiting and
/// checked on the opened descriptor. A FIFO named like a picture or video
/// would make `open(2)` wait for a writer for ever (and a read after it),
/// a device such as a link to /dev/zero never ends, a folder has no bytes.
/// These calls still wait on the disk (a share that stalls): call them on
/// `Blocking`'s threads in the app, never on Swift's cooperative pool.
public enum RegularFile {
    /// A regular file opened for reading, and its size when opened.
    public struct Opened {
        public let handle: FileHandle
        public let size: UInt64
    }

    /// `url` opened for reading; throws the system's error, or `EFTYPE` for
    /// anything that isn't a regular file (a FIFO, a device, a folder).
    public static func open(_ url: URL) throws -> Opened {
        guard url.isFileURL else { throw POSIXError(.ENOENT) }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return Opened(handle: handle, size: UInt64(max(0, info.st_size)))
    }

    /// Whether `url` is a regular file the process may open for reading
    /// (the sandbox's answer, not only the permissions').
    public static func canRead(_ url: URL) -> Bool {
        (try? open(url)) != nil
    }

    /// A regular file's first `count` bytes (fewer when it is shorter); nil
    /// when it can't be opened or isn't a regular file.
    public static func head(of url: URL, count: Int) -> Data? {
        guard let file = try? open(url) else { return nil }
        return try? file.handle.read(upToCount: count) ?? Data()
    }
}
