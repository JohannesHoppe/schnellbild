import AVFoundation
import CoreMedia
import Foundation
import MediaExtension
import OSLog

// Schnellbild's media extension: format readers for macOS's own media
// pipeline, Matroska (MKV) and MPEG transport streams (AVCHD: `.mts`,
// `.m2ts`), with H.264 or HEVC video. The reader says which frames there are
// and when; macOS decodes them (VideoToolbox) and makes the picture, for
// Quick Look thumbnails (Finder, Schnellbild's grid on macOS 26) and for
// playing in AVKit. Other codecs and audio aren't offered: such files fail
// here and Schnellbild's other paths (its Quick Look extension, VLC) take
// them. Runs sandboxed in its own process; it only reads the file macOS
// hands it.

let log = Logger(subsystem: "art.haushoppe.schnellbild.formats", category: "reader")

/// The factory macOS creates; one reader per file, by its extension.
final class FormatReaderFactory: NSObject, MEFormatReaderExtension {
    required override init() { super.init() }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws -> any MEFormatReader {
        let ext = (primaryByteSource.fileName as NSString).pathExtension.lowercased()
        return VideoFormatReader(source: primaryByteSource, container: ["mts", "m2ts"].contains(ext) ? .transportStream : .matroska)
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

/// One frame as the track reader steps through them. `offset` / `length`
/// are where its data lies: in one piece (Matroska), or spread over the
/// packets in that range (transport streams).
struct IndexedFrame: Sendable {
    let offset: Int64
    let length: Int
    let time: Int64             // presentation time, in the track's timescale
    let decodeTime: Int64?      // nil: worked out from the reordering
    let keyframe: Bool
}

/// What a container gives a video track: its frames a part (Matroska
/// cluster, a transport stream's chunk) at a time, the part for a time, and
/// for spread-out frames their data.
struct VideoTrackSource: Sendable {
    let id: CMPersistentTrackID
    let format: CMVideoFormatDescription
    let timescale: CMTimeScale
    let frameDuration: Int64
    let duration: Int64
    let partCount: Int
    let frames: @Sendable (Int) -> [IndexedFrame]?
    let part: @Sendable (Int64) -> Int
    /// The frame's data ready for the decoder, for frames not in one piece; nil: macOS reads them itself.
    let sampleData: (@Sendable (IndexedFrame) throws -> Data)?
}

/// One file: its index, made once, off the caller's thread.
final class VideoFormatReader: NSObject, MEFormatReader, @unchecked Sendable {
    enum Container { case matroska, transportStream }
    private let source: MEByteSource
    private let container: Container
    private let queue = DispatchQueue(label: "art.haushoppe.schnellbild.formats.reader")
    private var loaded: Result<(duration: CMTime, tracks: [VideoTrackReader]), Error>?

    init(source: MEByteSource, container: Container) {
        self.source = source
        self.container = container
    }

    private func load(_ done: @escaping (Result<(duration: CMTime, tracks: [VideoTrackReader]), Error>) -> Void) {
        queue.async { [self] in
            if loaded == nil {
                loaded = Result {
                    let reader = ByteSourceReader(source)
                    let (duration, sources) = container == .matroska ? try Self.matroska(reader) : try Self.transportStream(reader)
                    let tracks = sources.map { VideoTrackReader(source: $0, byteSource: source, queue: queue) }
                    guard !tracks.isEmpty else { throw MEError(.unsupportedFeature) }
                    return (duration, tracks)
                }
                if case .failure(let error) = loaded! { log.info("\(self.source.fileName, privacy: .private): \(String(describing: error), privacy: .public)") }
            }
            done(loaded!)
        }
    }

    func loadFileInfo(completionHandler: @escaping (MEFileInfo?, (any Error)?) -> Void) {
        load { result in
            switch result {
            case .success(let file):
                let info = MEFileInfo()
                info.duration = file.duration
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
            case .success(let file): completionHandler(file.tracks, nil)
            case .failure(let error): completionHandler(nil, error)
            }
        }
    }

    // MARK: Containers

    /// Matroska: each H.264 / HEVC video track, its frames cluster by cluster.
    static func matroska(_ reader: ByteReading) throws -> (CMTime, [VideoTrackSource]) {
        let index = try MatroskaIndex(reader)
        let timescale = CMTimeScale(index.timescale)
        let sources = index.tracks.compactMap { track -> VideoTrackSource? in
            // (frames compressed in the file, e.g. header stripping, would decode to nothing)
            guard track.type == 1, track.width > 0, track.height > 0, !track.codecPrivate.isEmpty, !track.encoded else { return nil }
            let codec: CMVideoCodecType, atom: String
            switch track.codecID {
            case "V_MPEG4/ISO/AVC": (codec, atom) = (kCMVideoCodecType_H264, "avcC")
            case "V_MPEGH/ISO/HEVC": (codec, atom) = (kCMVideoCodecType_HEVC, "hvcC")
            default: return nil
            }
            let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: track.codecPrivate as CFData]] as CFDictionary
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(clamping: track.width),
                                                 height: Int32(clamping: track.height), extensions: extensions,
                                                 formatDescriptionOut: &format) == noErr, let format else { return nil }
            let number = track.number
            let source = VideoTrackSource(
                id: CMPersistentTrackID(clamping: number), format: format, timescale: timescale,
                frameDuration: track.frameDuration(timestampScale: index.timestampScale),
                duration: index.durationUnits, partCount: index.clusters.count,
                frames: { cluster in
                    (try? index.frames(inCluster: cluster, track: number))?.map {
                        IndexedFrame(offset: $0.offset, length: $0.length, time: $0.time, decodeTime: nil, keyframe: $0.keyframe)
                    }
                },
                part: { index.cluster(at: $0) },
                sampleData: nil)
            // A track without a single frame isn't offered
            return (0..<index.clusters.count).contains { !(source.frames($0) ?? []).isEmpty } ? source : nil
        }
        return (CMTime(seconds: index.durationSeconds, preferredTimescale: 1000), sources)
    }

    /// A transport stream: its video stream, chunk by chunk; each frame
    /// gathered from its packets and handed over length-prefixed.
    static func transportStream(_ reader: ByteReading) throws -> (CMTime, [VideoTrackSource]) {
        let index = try TransportIndex(reader)
        // The parameter sets, from the first frame that starts a picture
        var sets: [[UInt8]]?
        search: for chunk in 0..<min(index.chunkCount, 8) {
            for frame in try index.frames(inChunk: chunk) where frame.keyframe {
                if let found = TransportIndex.parameterSets(try index.annexB(of: frame), codec: index.codec) { sets = found; break search }
            }
        }
        guard let sets, let format = makeFormat(sets, codec: index.codec) else { throw MEError(.unsupportedFeature) }
        let codec = index.codec
        let source = VideoTrackSource(
            id: CMPersistentTrackID(clamping: index.videoPID), format: format,
            timescale: CMTimeScale(TransportIndex.timescale), frameDuration: index.frameDuration,
            duration: index.duration, partCount: index.chunkCount,
            frames: { chunk in
                (try? index.frames(inChunk: chunk))?.map {
                    IndexedFrame(offset: $0.offset, length: $0.length, time: $0.time, decodeTime: $0.decodeTime, keyframe: $0.keyframe)
                }
            },
            part: { index.chunk(at: $0) },
            sampleData: { frame in
                let data = TransportIndex.lengthPrefixed(
                    try index.annexB(of: TransportIndex.Frame(offset: frame.offset, length: frame.length, time: frame.time,
                                                              decodeTime: frame.decodeTime ?? frame.time, keyframe: frame.keyframe)),
                    codec: codec)
                guard !data.isEmpty else { throw MEError(.noSamples) }
                return data
            })
        return (CMTime(value: index.duration, timescale: CMTimeScale(TransportIndex.timescale)), [source])
    }

    /// A format description from the stream's parameter sets.
    static func makeFormat(_ sets: [[UInt8]], codec: TransportIndex.Codec) -> CMVideoFormatDescription? {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            buffer.initialize(from: set, count: set.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let status = codec == .h264
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }
}

/// One video track. Its frames are looked up part by part as macOS steps
/// through them, so a thumbnail of a long film reads only the parts around
/// the picture.
final class VideoTrackReader: NSObject, METrackReader, @unchecked Sendable {
    let source: VideoTrackSource
    let byteSource: MEByteSource
    let queue: DispatchQueue
    var timescale: CMTimeScale { source.timescale }

    /// One part's frames: decode order, the presentation order, and decode
    /// times (given, or the presentation times in order held back by the
    /// largest reordering, so no frame is decoded after it is shown).
    struct PartFrames {
        let frames: [IndexedFrame]
        let presentation: [Int]
        let positionInPresentation: [Int]
        let decodeTimes: [Int64]
    }
    private var cache: [Int: PartFrames] = [:]
    private let lock = NSLock()

    init(source: VideoTrackSource, byteSource: MEByteSource, queue: DispatchQueue) {
        self.source = source
        self.byteSource = byteSource
        self.queue = queue
    }

    /// The frames of a part, read on first use; nil if it can't be read.
    func frames(inPart part: Int) -> PartFrames? {
        if let known = lock.withLock({ cache[part] }) { return known }
        guard part >= 0, part < source.partCount, let frames = source.frames(part) else { return nil }
        let order = frames.indices.sorted { frames[$0].time < frames[$1].time }
        var position = Array(repeating: 0, count: frames.count)
        for (i, frame) in order.enumerated() { position[frame] = i }
        let decodeTimes: [Int64]
        if frames.allSatisfy({ $0.decodeTime != nil }) {
            decodeTimes = frames.map { $0.decodeTime! }
        } else {
            let sorted = order.map { frames[$0].time }
            var delay: Int64 = 0
            for (i, frame) in frames.enumerated() { delay = max(delay, sorted[i].saturatingSubtract(frame.time)) }
            decodeTimes = sorted.map { $0.saturatingSubtract(delay) }
        }
        let result = PartFrames(frames: frames, presentation: order, positionInPresentation: position, decodeTimes: decodeTimes)
        lock.withLock {
            if cache.count > 64 { cache.removeAll() }
            cache[part] = result
        }
        return result
    }

    /// The nearest part from `part` on (by `step`) that holds frames.
    func part(from part: Int, step: Int) -> Int? {
        var p = part
        while p >= 0, p < source.partCount {
            if let frames = frames(inPart: p), !frames.frames.isEmpty { return p }
            p += step
        }
        return nil
    }

    func firstPart() -> Int? { part(from: 0, step: 1) }

    func loadTrackInfo(completionHandler: @escaping (METrackInfo?, (any Error)?) -> Void) {
        let info = METrackInfo(__mediaType: kCMMediaType_Video, trackID: source.id, formatDescriptions: [source.format])
        info.naturalSize = CMVideoFormatDescriptionGetPresentationDimensions(source.format, usePixelAspectRatio: true, useCleanAperture: true)
        info.naturalTimescale = timescale
        info.nominalFrameRate = Float32(Double(timescale) / Double(source.frameDuration))
        info.requiresFrameReordering = true
        completionHandler(info, nil)
    }

    func generateSampleCursor(atPresentationTimeStamp presentationTimeStamp: CMTime,
                              completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        queue.async { [self] in
            var target = CMTimeConvertScale(presentationTimeStamp, timescale: timescale, method: .default).value
            // Quick Look asks for its thumbnail at 10 s: a shorter video gives a picture a quarter in
            if source.duration > 0, target > source.duration { target = source.duration / 4 }
            guard let part = part(from: source.part(target), step: -1) ?? firstPart(),
                  let frames = frames(inPart: part) else { return completionHandler(nil, MEError(.noSamples)) }
            var position = 0
            for (i, frame) in frames.presentation.enumerated() where frames.frames[frame].time <= target { position = i }
            completionHandler(VideoCursor(track: self, part: part, index: frames.presentation[position]), nil)
        }
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        queue.async { [self] in
            guard let part = firstPart() else { return completionHandler(nil, MEError(.noSamples)) }
            completionHandler(VideoCursor(track: self, part: part, index: 0), nil)
        }
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        queue.async { [self] in
            guard let part = part(from: source.partCount - 1, step: -1), let frames = frames(inPart: part) else {
                return completionHandler(nil, MEError(.noSamples))
            }
            completionHandler(VideoCursor(track: self, part: part, index: frames.frames.count - 1), nil)
        }
    }
}

/// A position on one frame (a part and the frame's place in it, decode
/// order). macOS steps it, and reads the frame's bytes itself where they lie
/// in one piece (`sampleLocation`), else takes them from
/// `loadSampleBufferContainingSamples`.
final class VideoCursor: NSObject, MESampleCursor, @unchecked Sendable {
    let track: VideoTrackReader
    private(set) var part: Int
    private(set) var index: Int
    private var frames: VideoTrackReader.PartFrames

    init?(track: VideoTrackReader, part: Int, index: Int) {
        guard let frames = track.frames(inPart: part), frames.frames.indices.contains(index) else { return nil }
        self.track = track
        self.part = part
        self.index = index
        self.frames = frames
    }

    private init(copying other: VideoCursor) {
        track = other.track
        part = other.part
        index = other.index
        frames = other.frames
    }

    func copy(with zone: NSZone? = nil) -> Any { VideoCursor(copying: self) }

    private var frame: IndexedFrame { frames.frames[index] }
    private func time(_ value: Int64) -> CMTime { CMTime(value: value, timescale: track.timescale) }

    var presentationTimeStamp: CMTime { time(frame.time) }
    var decodeTimeStamp: CMTime { time(frames.decodeTimes[index]) }
    var currentSampleDuration: CMTime { time(track.source.frameDuration) }
    var currentSampleFormatDescription: CMFormatDescription? { track.source.format }

    var syncInfo: AVSampleCursorSyncInfo {
        AVSampleCursorSyncInfo(sampleIsFullSync: ObjCBool(frame.keyframe), sampleIsPartialSync: false, sampleIsDroppable: false)
    }

    func sampleLocation() throws -> MESampleLocation {
        guard track.source.sampleData == nil else { throw MEError(.locationNotAvailable) }
        return MESampleLocation(byteSource: track.byteSource,
                                sampleLocation: AVSampleCursorStorageRange(offset: frame.offset, length: Int64(frame.length)))
    }

    /// The frame's data gathered by the container, one frame per buffer.
    func loadSampleBufferContainingSamples(to endSampleCursor: (any MESampleCursor)?,
                                           completionHandler: @escaping (CMSampleBuffer?, (any Error)?) -> Void) {
        let frame = frame
        let timing = CMSampleTimingInfo(duration: currentSampleDuration, presentationTimeStamp: presentationTimeStamp,
                                        decodeTimeStamp: decodeTimeStamp)
        let track = track
        track.queue.async {
            do {
                guard let sampleData = track.source.sampleData else { throw MEError(.locationNotAvailable) }
                completionHandler(try Self.sampleBuffer(try sampleData(frame), keyframe: frame.keyframe, timing: timing,
                                                        format: track.source.format), nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    static func sampleBuffer(_ data: Data, keyframe: Bool, timing: CMSampleTimingInfo, format: CMFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard !data.isEmpty,
              CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                   dataLength: data.count) }) == noErr
        else { throw MEError(.internalFailure) }
        var timing = timing, size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { throw MEError(.internalFailure) }
        if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Moves to another part's frames (the next one with frames that way).
    private func move(toPart target: Int, step: Int) -> Bool {
        guard let found = track.part(from: target, step: step), let newFrames = track.frames(inPart: found) else { return false }
        part = found
        frames = newFrames
        return true
    }

    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        track.queue.async { [self] in
            var left = stepCount, done: Int64 = 0
            while left != 0 {
                if left > 0 {
                    if index + 1 < frames.frames.count { index += 1 }
                    else if move(toPart: part + 1, step: 1) { index = 0 }
                    else { break }
                    left -= 1; done += 1
                } else {
                    if index > 0 { index -= 1 }
                    else if move(toPart: part - 1, step: -1) { index = frames.frames.count - 1 }
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
                    else if move(toPart: part + 1, step: 1) { position = 0 }
                    else { break }
                    left -= 1; done += 1
                } else {
                    if position > 0 { position -= 1 }
                    else if move(toPart: part - 1, step: -1) { position = frames.presentation.count - 1 }
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
        let first = track.firstPart() ?? 0
        let start = track.part(from: track.source.part(target), step: -1) ?? first
        guard move(toPart: start, step: -1) || move(toPart: first, step: 1) else { return true }
        let times = byDecodeTime ? frames.decodeTimes : frames.presentation.map { frames.frames[$0].time }
        var position = 0
        for (i, t) in times.enumerated() where t <= target { position = i }
        index = byDecodeTime ? position : frames.presentation[position]
        let pinnedLow = target < (times.first ?? target)
        let lastPart = track.part(from: track.source.partCount - 1, step: -1)
        let pinnedHigh = part == lastPart && target > (times.max() ?? target).saturatingAdd(track.source.frameDuration)
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
