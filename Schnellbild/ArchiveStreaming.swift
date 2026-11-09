import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// A file inside an archive, readable at any offset while it is unpacked:
/// the players stream videos from archives through it, nothing is written
/// to disk. One background thread unpacks the entry front to back into
/// chunks of 1 MB, kept in memory within a budget. A read ahead of the
/// unpacking waits for it; a read behind what is still in memory unpacks
/// the entry again from its start (archive formats can't jump inside a
/// packed file). Chunks the player has read are kept longer than chunks
/// only passed on the way (an MP4's index at its end, then its start).
final class ArchiveEntryStream: @unchecked Sendable {
    let size: Int64
    private let reader: ArchiveReader
    private let path: String
    private let password: String?

    static let defaultChunkSize = 1 << 20
    let chunkSize: Int
    /// Chunks unpacked but not read yet (read-ahead, or passed on the way).
    private let unreadLimit: Int
    /// Chunks the player has read.
    private let readLimit: Int

    private let condition = NSCondition()
    private var chunks: [Int: Data] = [:]
    private var unreadOrder: [Int] = []
    private var readOrder: [Int] = []
    /// The chunk the unpacking is at, the one asked for last (the reader's
    /// place, which the read-ahead follows), and the run.
    private var producing = 0
    private var wanted = 0
    private var run = 0
    private var running = false
    private var failure: ArchiveError?
    private var closed = false

    init(size: Int64, reader: ArchiveReader, path: String, password: String?,
         chunkSize: Int = defaultChunkSize, unreadLimit: Int = 48, readLimit: Int = 96) {
        self.chunkSize = chunkSize
        self.unreadLimit = max(unreadLimit, 2)
        self.readLimit = max(readLimit, 1)
        self.size = size
        self.reader = reader
        self.path = path
        self.password = password
    }

    deinit { close() }

    /// Up to `count` bytes from `offset`; empty at the end. Blocks until
    /// they are unpacked; throws when the entry can't be unpacked so far.
    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let end = min(offset + Int64(count), size)
        var result = Data(capacity: Int(end - offset))
        var position = offset
        while position < end {
            let index = Int(position / Int64(chunkSize))
            let chunk = try self.chunk(index)
            let start = Int(position - Int64(index) * Int64(chunkSize))
            let take = min(chunk.count - start, Int(end - position))
            guard take > 0 else { break }
            result.append(chunk[chunk.startIndex + start ..< chunk.startIndex + start + take])
            position += Int64(take)
        }
        return result
    }

    func close() {
        condition.lock()
        closed = true
        run += 1   // the running pass stops
        condition.broadcast()
        condition.unlock()
    }

    private func chunk(_ index: Int) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if closed { throw ArchiveError.notFound }
            if let found = chunks[index] {
                markRead(index)
                return found
            }
            if let failure, !running { throw failure }
            wanted = index
            // Behind the unpacking and no longer in memory: from the start
            if !running || index < producing {
                start()
            }
            condition.broadcast()   // the unpacking may wait for a reader
            condition.wait()
        }
    }

    private func markRead(_ index: Int) {
        if let i = unreadOrder.firstIndex(of: index) { unreadOrder.remove(at: i) }
        if let i = readOrder.firstIndex(of: index) { readOrder.remove(at: i) }
        readOrder.append(index)
        while readOrder.count > readLimit { chunks[readOrder.removeFirst()] = nil }
    }

    /// A new pass from the entry's start. Called with the lock held.
    private func start() {
        run += 1
        let myRun = run
        running = true
        failure = nil
        producing = 0
        let thread = Thread { [weak self] in self?.unpack(run: myRun) }
        thread.qualityOfService = .userInitiated
        thread.name = "archive stream"
        thread.start()
    }

    private func unpack(run myRun: Int) {
        let chunkSize = self.chunkSize
        var buffer = Data(capacity: chunkSize)
        var index = 0
        var outcome: ArchiveError? = .notFound
        var done = false
        func current() -> Bool {
            condition.lock(); defer { condition.unlock() }
            return run == myRun
        }
        func store(_ data: Data, _ i: Int) -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard run == myRun else { return false }
            if chunks[i] == nil {
                chunks[i] = data
                unreadOrder.append(i)
                // The oldest passed-on chunks go first; the one asked for stays
                while unreadOrder.count > unreadLimit {
                    let old = unreadOrder.removeFirst()
                    if old != wanted { chunks[old] = nil }
                }
            }
            producing = i + 1
            condition.broadcast()
            // Far enough ahead of the reader: wait (another chunk asked for, or a new pass)
            while run == myRun, !closed, i >= wanted + unreadLimit / 2 { condition.wait() }
            return run == myRun && !closed
        }
        do {
            _ = try reader.walk(password: password, listOnly: false) { item in
                guard current(), !done else { return .stop }   // nothing after the entry is needed
                guard item.path == path else { return .skip }
                return .read(sink: { bytes in
                    var rest = bytes[...]
                    while !rest.isEmpty {
                        let take = min(chunkSize - buffer.count, rest.count)
                        buffer.append(contentsOf: rest.prefix(take))
                        rest = rest.dropFirst(take)
                        if buffer.count == chunkSize {
                            guard store(buffer, index) else { return false }
                            index += 1
                            buffer = Data(capacity: chunkSize)
                        }
                    }
                    return true
                }, done: { failure in
                    if !buffer.isEmpty { _ = store(buffer, index) }
                    outcome = failure
                    done = true
                })
            }
        } catch let error as ArchiveError {
            outcome = error
        } catch {
            outcome = .unreadable(error.localizedDescription)
        }
        condition.lock()
        if run == myRun {
            running = false
            if let outcome, chunks[wanted] == nil { failure = outcome }
            condition.broadcast()
        }
        condition.unlock()
    }
}

extension ArchiveStore {
    /// A stream of a file inside an archive (a video for the players).
    func stream(of url: URL, chunkSize: Int = ArchiveEntryStream.defaultChunkSize,
                unreadLimit: Int = 48, readLimit: Int = 96) async throws -> ArchiveEntryStream {
        guard let (archiveURL, inner) = ArchivePath.split(url), !inner.isEmpty else { throw ArchiveError.notFound }
        let index = try await index(of: archiveURL)
        guard let item = index.byPath[inner], !item.isDirectory,
              let reader = Self.reader(for: archiveURL) else { throw ArchiveError.notFound }
        return ArchiveEntryStream(size: item.size, reader: reader, path: item.path, password: index.password,
                                  chunkSize: chunkSize, unreadLimit: unreadLimit, readLimit: readLimit)
    }
}

/// Feeds AVKit from an `ArchiveEntryStream`: the asset's URL has a scheme
/// of its own, so AVFoundation asks this delegate for every byte range.
final class ArchiveResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "schnellbild-archive"
    let stream: ArchiveEntryStream
    private let contentType: String
    /// Where the asset's requests arrive.
    let queue = DispatchQueue(label: "archive resource loader")
    /// Where they are served (several at once: AVFoundation asks for the
    /// start and the end of an MP4 together).
    private let work = DispatchQueue(label: "archive resource loader work", qos: .userInitiated, attributes: .concurrent)

    init(stream: ArchiveEntryStream, fileName: String) {
        self.stream = stream
        contentType = UTType(filenameExtension: (fileName as NSString).pathExtension)?.identifier ?? UTType.mpeg4Movie.identifier
    }

    /// An asset reading through this loader.
    func makeAsset(fileName: String) -> AVURLAsset {
        let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video"
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://stream/\(UUID().uuidString)/\(name)")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        nonisolated(unsafe) let request = loadingRequest
        work.async { self.serve(request) }
        return true
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = stream.size
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { request.finishLoading(); return }
        var offset = data.currentOffset
        let end = data.requestsAllDataToEndOfResource ? stream.size : data.requestedOffset + Int64(data.requestedLength)
        do {
            while offset < end, !request.isCancelled {
                let chunk = try stream.read(at: offset, count: Int(min(Int64(stream.chunkSize), end - offset)))
                guard !chunk.isEmpty else { break }
                data.respond(with: chunk)
                offset += Int64(chunk.count)
            }
            if !request.isCancelled { request.finishLoading() }
        } catch {
            if !request.isCancelled { request.finishLoading(with: error) }
        }
    }
}

/// Feeds VLCKit from an `ArchiveEntryStream` (`VLCMedia(stream:)`): VLC
/// reads it in turn and seeks by setting the file offset property. A new
/// one for every opening (VLCKit can't open a closed stream again).
final class ArchiveInputStream: InputStream {
    private let source: ArchiveEntryStream
    private var offset: Int64 = 0
    private var status: Stream.Status = .notOpen

    init(_ source: ArchiveEntryStream) {
        self.source = source
        super.init(data: Data())
    }

    override func open() { status = .open }
    override func close() { status = .closed }
    override var streamStatus: Stream.Status { status }
    override var streamError: Error? { nil }
    override var hasBytesAvailable: Bool { offset < source.size }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard let data = try? source.read(at: offset, count: len) else { status = .error; return -1 }
        data.copyBytes(to: buffer, count: data.count)
        offset += Int64(data.count)
        if data.isEmpty { status = .atEnd }
        return data.count
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? {
        key == .fileCurrentOffsetKey ? NSNumber(value: offset) : nil
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey, let value = property as? NSNumber else { return false }
        offset = min(max(value.int64Value, 0), source.size)
        if status == .atEnd, offset < source.size { status = .open }
        return true
    }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}
