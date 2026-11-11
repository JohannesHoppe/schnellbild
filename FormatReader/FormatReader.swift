import AVFoundation
import CoreMedia
import Foundation
import MediaExtension
import OSLog

// Schnellbild's media extension: a Matroska format reader (MKV with H.264 or
// HEVC video) for macOS's own media pipeline. The reader says where each
// frame lies in the file; macOS reads and decodes it (VideoToolbox) and
// makes the picture, for Quick Look thumbnails (Finder, Schnellbild's grid
// on macOS 26) and for playing in AVKit. Other codecs and audio aren't
// offered: such files fail here and Schnellbild's other paths (its Quick
// Look extension, VLC) take them. Runs sandboxed in its own process; it
// only reads the file macOS hands it.

let log = Logger(subsystem: "art.haushoppe.schnellbild.formats", category: "matroska")

/// The factory macOS creates; one reader per file.
final class FormatReaderFactory: NSObject, MEFormatReaderExtension {
    required override init() { super.init() }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws -> any MEFormatReader {
        // AVCHD is claimed only for Quick Look's sake (Info.plist): macOS reads it itself
        guard (primaryByteSource.fileName as NSString).pathExtension.lowercased() == "mkv" else { throw MEError(.unsupportedFeature) }
        return MatroskaFormatReader(source: primaryByteSource)
    }
}

/// The byte source, read synchronously on the reader's own queue (macOS
/// answers its reads on its own threads).
final class ByteSourceReader: ByteReading, @unchecked Sendable {
    let source: MEByteSource
    var length: Int64 { source.fileLength }

    init(_ source: MEByteSource) { self.source = source }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset < source.fileLength, count > 0 else { return Data() }
        let wanted = Int(min(Int64(count), source.fileLength - offset))
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .success(Data())
        source.read(length: wanted, from: offset) { data, error in
            result = data.map { .success($0) } ?? .failure(error ?? MEError(.parsingFailure))
            done.signal()
        }
        done.wait()
        return try result.get()
    }
}

/// One file: its index, made once, off the caller's thread.
final class MatroskaFormatReader: NSObject, MEFormatReader, @unchecked Sendable {
    private let source: MEByteSource
    private let queue = DispatchQueue(label: "art.haushoppe.schnellbild.formats.reader")
    private var loaded: Result<(MatroskaIndex, [MatroskaTrackReader]), Error>?

    init(source: MEByteSource) { self.source = source }

    private func load(_ done: @escaping (Result<(MatroskaIndex, [MatroskaTrackReader]), Error>) -> Void) {
        queue.async { [self] in
            if loaded == nil {
                loaded = Result {
                    let index = try MatroskaIndex(ByteSourceReader(source))
                    let tracks = index.tracks.compactMap { MatroskaTrackReader(index: index, track: $0, source: source, queue: queue) }
                    guard !tracks.isEmpty else { throw MEError(.unsupportedFeature) }
                    return (index, tracks)
                }
                if case .failure(let error) = loaded! { log.info("\(self.source.fileName, privacy: .public): \(String(describing: error), privacy: .public)") }
            }
            done(loaded!)
        }
    }

    func loadFileInfo(completionHandler: @escaping (MEFileInfo?, (any Error)?) -> Void) {
        load { result in
            switch result {
            case .success((let index, _)):
                let info = MEFileInfo()
                info.duration = CMTime(seconds: index.duration * Double(index.timestampScale) / 1e9, preferredTimescale: 1000)
                completionHandler(info, nil)
            case .failure(let error): completionHandler(nil, error)
            }
        }
    }

    func loadMetadata(completionHandler: @escaping ([AVMetadataItem]?, (any Error)?) -> Void) {
        completionHandler([], nil)
    }

    func loadTrackReaders(completionHandler: @escaping ([any METrackReader]?, (any Error)?) -> Void) {
        load { result in
            switch result {
            case .success((_, let tracks)): completionHandler(tracks, nil)
            case .failure(let error): completionHandler(nil, error)
            }
        }
    }
}

/// One video track. Its frames are looked up cluster by cluster as macOS
/// steps through them, so a thumbnail of a long film reads only the
/// clusters around the picture.
final class MatroskaTrackReader: NSObject, METrackReader, @unchecked Sendable {
    let index: MatroskaIndex
    let number: UInt64
    let source: MEByteSource
    let queue: DispatchQueue
    let format: CMVideoFormatDescription
    let size: CGSize
    let timescale: CMTimeScale
    let frameDuration: Int64

    /// One cluster's frames of this track: decode order, the presentation
    /// order, and decode times (presentation times in order, held back by
    /// the largest reordering, so no frame is decoded after it is shown).
    struct ClusterFrames {
        let frames: [MatroskaIndex.Frame]
        let presentation: [Int]
        let positionInPresentation: [Int]
        let decodeTimes: [Int64]
    }
    private var cache: [Int: ClusterFrames] = [:]
    private let lock = NSLock()

    init?(index: MatroskaIndex, track: MatroskaIndex.Track, source: MEByteSource, queue: DispatchQueue) {
        guard track.type == 1, track.width > 0, track.height > 0 else { return nil }
        let codec: CMVideoCodecType, atom: String
        switch track.codecID {
        case "V_MPEG4/ISO/AVC": (codec, atom) = (kCMVideoCodecType_H264, "avcC")
        case "V_MPEGH/ISO/HEVC": (codec, atom) = (kCMVideoCodecType_HEVC, "hvcC")
        default: return nil
        }
        guard !track.codecPrivate.isEmpty else { return nil }
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: track.codecPrivate as CFData]] as CFDictionary
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(clamping: track.width),
                                             height: Int32(clamping: track.height), extensions: extensions,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        self.index = index
        number = track.number
        self.source = source
        self.queue = queue
        self.format = format
        size = CGSize(width: track.width, height: track.height)
        timescale = CMTimeScale(clamping: 1_000_000_000 / index.timestampScale)
        frameDuration = max(1, Int64(track.defaultDuration / index.timestampScale))
        super.init()
        // A track without a single frame in its first cluster that has any isn't offered
        guard firstCluster() != nil else { return nil }
    }

    /// The frames of a cluster, read on first use; nil if it can't be read.
    func frames(inCluster cluster: Int) -> ClusterFrames? {
        if let known = lock.withLock({ cache[cluster] }) { return known }
        guard cluster >= 0, cluster < index.clusters.count,
              let frames = try? index.frames(inCluster: cluster, track: number) else { return nil }
        let order = frames.indices.sorted { frames[$0].time < frames[$1].time }
        var position = Array(repeating: 0, count: frames.count)
        for (i, frame) in order.enumerated() { position[frame] = i }
        let sorted = order.map { frames[$0].time }
        var delay: Int64 = 0
        for (i, frame) in frames.enumerated() { delay = max(delay, sorted[i] - frame.time) }
        let result = ClusterFrames(frames: frames, presentation: order, positionInPresentation: position,
                                   decodeTimes: sorted.map { $0 - delay })
        lock.withLock {
            if cache.count > 64 { cache.removeAll() }
            cache[cluster] = result
        }
        return result
    }

    /// The nearest cluster from `cluster` on (by `step`) that holds frames of this track.
    func cluster(from cluster: Int, step: Int) -> Int? {
        var c = cluster
        while c >= 0, c < index.clusters.count {
            if let frames = frames(inCluster: c), !frames.frames.isEmpty { return c }
            c += step
        }
        return nil
    }

    private func firstCluster() -> Int? { cluster(from: 0, step: 1) }

    func loadTrackInfo(completionHandler: @escaping (METrackInfo?, (any Error)?) -> Void) {
        let info = METrackInfo(__mediaType: kCMMediaType_Video, trackID: CMPersistentTrackID(clamping: number), formatDescriptions: [format])
        info.naturalSize = size
        info.naturalTimescale = timescale
        info.nominalFrameRate = Float32(Double(timescale) / Double(frameDuration))
        info.requiresFrameReordering = true
        completionHandler(info, nil)
    }

    func generateSampleCursor(atPresentationTimeStamp presentationTimeStamp: CMTime,
                              completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        queue.async { [self] in
            var target = CMTimeConvertScale(presentationTimeStamp, timescale: timescale, method: .default).value
            // Quick Look asks for its thumbnail at 10 s: a shorter video gives a picture a quarter in
            let end = Int64(index.duration)
            if end > 0, target > end { target = end / 4 }
            guard let cluster = cluster(from: index.cluster(at: target), step: -1) ?? firstCluster(),
                  let frames = frames(inCluster: cluster) else { return completionHandler(nil, MEError(.noSamples)) }
            var position = 0
            for (i, frame) in frames.presentation.enumerated() where frames.frames[frame].time <= target { position = i }
            completionHandler(MatroskaCursor(track: self, cluster: cluster, index: frames.presentation[position]), nil)
        }
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        queue.async { [self] in
            guard let cluster = firstCluster() else { return completionHandler(nil, MEError(.noSamples)) }
            completionHandler(MatroskaCursor(track: self, cluster: cluster, index: 0), nil)
        }
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        queue.async { [self] in
            guard let cluster = cluster(from: index.clusters.count - 1, step: -1), let frames = frames(inCluster: cluster) else {
                return completionHandler(nil, MEError(.noSamples))
            }
            completionHandler(MatroskaCursor(track: self, cluster: cluster, index: frames.frames.count - 1), nil)
        }
    }
}

/// A position on one frame (a cluster and the frame's place in it, decode
/// order); macOS steps it and reads the frame's bytes itself (`sampleLocation`).
final class MatroskaCursor: NSObject, MESampleCursor, @unchecked Sendable {
    let track: MatroskaTrackReader
    private(set) var cluster: Int
    private(set) var index: Int
    private var frames: MatroskaTrackReader.ClusterFrames

    init?(track: MatroskaTrackReader, cluster: Int, index: Int) {
        guard let frames = track.frames(inCluster: cluster), frames.frames.indices.contains(index) else { return nil }
        self.track = track
        self.cluster = cluster
        self.index = index
        self.frames = frames
    }

    private init(copying other: MatroskaCursor) {
        track = other.track
        cluster = other.cluster
        index = other.index
        frames = other.frames
    }

    func copy(with zone: NSZone? = nil) -> Any { MatroskaCursor(copying: self) }

    private var frame: MatroskaIndex.Frame { frames.frames[index] }
    private func time(_ value: Int64) -> CMTime { CMTime(value: value, timescale: track.timescale) }

    var presentationTimeStamp: CMTime { time(frame.time) }
    var decodeTimeStamp: CMTime { time(frames.decodeTimes[index]) }
    var currentSampleDuration: CMTime { time(track.frameDuration) }
    var currentSampleFormatDescription: CMFormatDescription? { track.format }

    var syncInfo: AVSampleCursorSyncInfo {
        AVSampleCursorSyncInfo(sampleIsFullSync: ObjCBool(frame.keyframe), sampleIsPartialSync: false, sampleIsDroppable: false)
    }

    func sampleLocation() throws -> MESampleLocation {
        MESampleLocation(byteSource: track.source,
                         sampleLocation: AVSampleCursorStorageRange(offset: frame.offset, length: Int64(frame.length)))
    }

    /// Moves to another cluster's frames (the next one with frames of this track that way).
    private func move(toCluster target: Int, step: Int) -> Bool {
        guard let found = track.cluster(from: target, step: step), let newFrames = track.frames(inCluster: found) else { return false }
        cluster = found
        frames = newFrames
        return true
    }

    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        track.queue.async { [self] in
            var left = stepCount, done: Int64 = 0
            while left != 0 {
                if left > 0 {
                    if index + 1 < frames.frames.count { index += 1 }
                    else if move(toCluster: cluster + 1, step: 1) { index = 0 }
                    else { break }
                    left -= 1; done += 1
                } else {
                    if index > 0 { index -= 1 }
                    else if move(toCluster: cluster - 1, step: -1) { index = frames.frames.count - 1 }
                    else { break }
                    left += 1; done -= 1
                }
            }
            completionHandler(done, nil)
        }
    }

    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        track.queue.async { [self] in
            var left = stepCount, done: Int64 = 0
            var position = frames.positionInPresentation[index]
            while left != 0 {
                if left > 0 {
                    if position + 1 < frames.presentation.count { position += 1 }
                    else if move(toCluster: cluster + 1, step: 1) { position = 0 }
                    else { break }
                    left -= 1; done += 1
                } else {
                    if position > 0 { position -= 1 }
                    else if move(toCluster: cluster - 1, step: -1) { position = frames.presentation.count - 1 }
                    else { break }
                    left += 1; done -= 1
                }
                index = frames.presentation[position]
            }
            completionHandler(done, nil)
        }
    }

    /// To the last frame at or before `target` (in decode or presentation
    /// time); pinned when the time lies outside the track.
    private func seek(to target: Int64, byDecodeTime: Bool) -> Bool {
        let first = track.cluster(from: 0, step: 1) ?? 0
        let start = track.cluster(from: track.index.cluster(at: target), step: -1) ?? first
        guard move(toCluster: start, step: -1) || move(toCluster: first, step: 1) else { return true }
        let times = byDecodeTime ? frames.decodeTimes : frames.presentation.map { frames.frames[$0].time }
        var position = 0
        for (i, t) in times.enumerated() where t <= target { position = i }
        index = byDecodeTime ? position : frames.presentation[position]
        let pinnedLow = target < (times.first ?? target)
        let lastCluster = track.cluster(from: track.index.clusters.count - 1, step: -1)
        let pinnedHigh = cluster == lastCluster && target > (times.max() ?? target) + track.frameDuration
        return pinnedLow || pinnedHigh
    }

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping (CMTime, Bool, (any Error)?) -> Void) {
        track.queue.async { [self] in
            let goal = CMTimeConvertScale(CMTimeAdd(decodeTimeStamp, deltaDecodeTime), timescale: track.timescale, method: .default).value
            let pinned = seek(to: goal, byDecodeTime: true)
            completionHandler(decodeTimeStamp, pinned, nil)
        }
    }

    func stepByPresentationTime(_ deltaPresentationTime: CMTime, completionHandler: @escaping (CMTime, Bool, (any Error)?) -> Void) {
        track.queue.async { [self] in
            let goal = CMTimeConvertScale(CMTimeAdd(presentationTimeStamp, deltaPresentationTime), timescale: track.timescale, method: .default).value
            let pinned = seek(to: goal, byDecodeTime: false)
            completionHandler(presentationTimeStamp, pinned, nil)
        }
    }
}
