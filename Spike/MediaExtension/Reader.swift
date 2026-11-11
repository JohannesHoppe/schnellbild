import AVFoundation
import CoreMedia
import Foundation
import MediaExtension
import OSLog

// A Matroska format reader for H.264 and HEVC video, for macOS's own media
// pipeline: the reader says where each frame lies in the file, macOS reads
// and decodes it (VideoToolbox) and makes the picture. No audio yet.

let log = Logger(subsystem: "art.haushoppe.schnellbild.spike", category: "reader")

/// Also a line in the extension's container (the CI probe reads it): the log
/// can miss a short-lived process.
func note(_ line: String) {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("spike-notes.txt")
    let text = line + "\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
    } else {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class SpikeFactory: NSObject, MEFormatReaderExtension {
    required override init() {
        super.init()
        note("factory started in pid \(getpid())")
    }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws -> any MEFormatReader {
        note("asked for \(primaryByteSource.fileName) (\(primaryByteSource.contentType?.identifier ?? "unknown"))")
        return MKVFormatReader(source: primaryByteSource)
    }
}

/// The whole file, parsed once when first asked.
final class MKVFormatReader: NSObject, MEFormatReader {
    let source: MEByteSource
    private var parsed: (file: MKVFile, tracks: [MKVTrackReader])?
    private let lock = NSLock()

    init(source: MEByteSource) { self.source = source }

    private func load(_ done: @escaping ((file: MKVFile, tracks: [MKVTrackReader])?, Error?) -> Void) {
        if let parsed = lock.withLock({ parsed }) { return done(parsed, nil) }
        // A prototype: the whole file at once (files of a few hundred MB at most)
        source.read(length: Int(min(source.fileLength, 512 << 20)), from: 0) { [self] data, error in
            guard let data else { return done(nil, error ?? MEError(.parsingFailure)) }
            do {
                let file = try MKVFile(data)
                let tracks = file.tracks.compactMap { MKVTrackReader(file: file, track: $0, source: source) }
                let result = (file, tracks)
                lock.withLock { parsed = result }
                note("parsed \(source.fileName): \(tracks.count) video track(s), \(file.samples.values.map(\.count).reduce(0, +)) samples")
                done(result, nil)
            } catch {
                note("can't parse \(source.fileName): \(error)")
                done(nil, MEError(.parsingFailure))
            }
        }
    }

    func loadFileInfo(completionHandler: @escaping (MEFileInfo?, (any Error)?) -> Void) {
        load { parsed, error in
            guard let parsed else { return completionHandler(nil, error) }
            let info = MEFileInfo()
            let nanoseconds = parsed.file.duration * Double(parsed.file.timestampScale)
            info.duration = CMTime(seconds: nanoseconds / 1e9, preferredTimescale: 1000)
            completionHandler(info, nil)
        }
    }

    func loadMetadata(completionHandler: @escaping ([AVMetadataItem]?, (any Error)?) -> Void) {
        completionHandler([], nil)
    }

    func loadTrackReaders(completionHandler: @escaping ([any METrackReader]?, (any Error)?) -> Void) {
        load { parsed, error in completionHandler(parsed?.tracks, error) }
    }
}

/// One video track: its format and its frames, in decode and in presentation order.
final class MKVTrackReader: NSObject, METrackReader {
    let source: MEByteSource
    let trackID: CMPersistentTrackID
    let format: CMVideoFormatDescription
    let size: CGSize
    /// CMTime timescale: timestamp units per second.
    let timescale: CMTimeScale
    let samples: [MKVFile.Sample]          // decode (file) order
    let decodeTimes: [Int64]               // per sample, decode order
    let presentationOrder: [Int]           // sample indices sorted by presentation time
    let positionInPresentation: [Int]      // the reverse
    let frameDuration: Int64
    let reorders: Bool

    init?(file: MKVFile, track: MKVFile.Track, source: MEByteSource) {
        guard track.type == 1, let samples = file.samples[track.number], !samples.isEmpty else { return nil }
        let codec: CMVideoCodecType, atom: String
        switch track.codecID {
        case "V_MPEG4/ISO/AVC": (codec, atom) = (kCMVideoCodecType_H264, "avcC")
        case "V_MPEGH/ISO/HEVC": (codec, atom) = (kCMVideoCodecType_HEVC, "hvcC")
        default: return nil   // others need a decoder of our own
        }
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: track.codecPrivate as CFData]] as CFDictionary
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(track.width), height: Int32(track.height),
                                             extensions: extensions, formatDescriptionOut: &format) == noErr, let format else { return nil }
        self.source = source
        self.format = format
        trackID = CMPersistentTrackID(clamping: track.number)
        size = CGSize(width: track.width, height: track.height)
        timescale = CMTimeScale(clamping: 1_000_000_000 / max(file.timestampScale, 1))
        self.samples = samples
        let order = samples.indices.sorted { samples[$0].time < samples[$1].time }
        presentationOrder = order
        var position = Array(repeating: 0, count: samples.count)
        for (i, sample) in order.enumerated() { position[sample] = i }
        positionInPresentation = position
        let perFrame = track.defaultDuration > 0
            ? Int64(track.defaultDuration / max(file.timestampScale, 1))
            : (samples.count > 1 ? max(1, (samples[order.last!].time - samples[order.first!].time) / Int64(samples.count - 1)) : 1)
        frameDuration = max(perFrame, 1)
        reorders = order != Array(samples.indices)
        // Decode times: the presentation times in order, held back by the
        // largest reordering so no frame is decoded after it is shown
        let sortedTimes = order.map { samples[$0].time }
        var delay: Int64 = 0
        for (i, sample) in samples.enumerated() { delay = max(delay, sortedTimes[i] - sample.time) }
        decodeTimes = sortedTimes.map { $0 - delay }
    }

    func loadTrackInfo(completionHandler: @escaping (METrackInfo?, (any Error)?) -> Void) {
        let info = METrackInfo(__mediaType: kCMMediaType_Video, trackID: trackID, formatDescriptions: [format])
        info.naturalSize = size
        info.naturalTimescale = timescale
        info.nominalFrameRate = Float32(Double(timescale) / Double(frameDuration))
        info.requiresFrameReordering = reorders
        completionHandler(info, nil)
    }

    func generateSampleCursor(atPresentationTimeStamp presentationTimeStamp: CMTime,
                              completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        var target = CMTimeConvertScale(presentationTimeStamp, timescale: timescale, method: .default).value
        // Quick Look asks for its thumbnail at 10 s: in a shorter video, a quarter in
        let last = samples[presentationOrder.last!].time
        if target > last { target = samples[presentationOrder.first!].time + (last - samples[presentationOrder.first!].time) / 4 }
        // The last frame shown at or before the time
        var position = 0
        for (i, sample) in presentationOrder.enumerated() where samples[sample].time <= target { position = i }
        completionHandler(MKVCursor(track: self, index: presentationOrder[position]), nil)
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        completionHandler(MKVCursor(track: self, index: 0), nil)
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        completionHandler(MKVCursor(track: self, index: samples.count - 1), nil)
    }
}

/// A position on one frame of a track; macOS steps it around and reads the
/// frame's bytes from the file itself (`sampleLocation`).
final class MKVCursor: NSObject, MESampleCursor {
    let track: MKVTrackReader
    var index: Int   // decode order

    init(track: MKVTrackReader, index: Int) {
        self.track = track
        self.index = index
    }

    func copy(with zone: NSZone? = nil) -> Any { MKVCursor(track: track, index: index) }

    private var sample: MKVFile.Sample { track.samples[index] }
    private func time(_ value: Int64) -> CMTime { CMTime(value: value, timescale: track.timescale) }

    var presentationTimeStamp: CMTime { time(sample.time) }
    var decodeTimeStamp: CMTime { time(track.decodeTimes[index]) }
    var currentSampleDuration: CMTime { time(track.frameDuration) }
    var currentSampleFormatDescription: CMFormatDescription? { track.format }

    var syncInfo: AVSampleCursorSyncInfo {
        AVSampleCursorSyncInfo(sampleIsFullSync: ObjCBool(sample.keyframe), sampleIsPartialSync: false, sampleIsDroppable: false)
    }

    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        let target = max(0, min(track.samples.count - 1, index + Int(stepCount)))
        let actual = Int64(target - index)
        index = target
        completionHandler(actual, nil)
    }

    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        let position = track.positionInPresentation[index]
        let target = max(0, min(track.samples.count - 1, position + Int(stepCount)))
        index = track.presentationOrder[target]
        completionHandler(Int64(target - position), nil)
    }

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping (CMTime, Bool, (any Error)?) -> Void) {
        let goal = CMTimeAdd(decodeTimeStamp, deltaDecodeTime)
        let value = CMTimeConvertScale(goal, timescale: track.timescale, method: .default).value
        var target = 0
        for (i, t) in track.decodeTimes.enumerated() where t <= value { target = i }
        let pinned = value < track.decodeTimes.first! || value > track.decodeTimes.last!
        index = target
        completionHandler(decodeTimeStamp, pinned, nil)
    }

    func stepByPresentationTime(_ deltaPresentationTime: CMTime, completionHandler: @escaping (CMTime, Bool, (any Error)?) -> Void) {
        let goal = CMTimeAdd(presentationTimeStamp, deltaPresentationTime)
        let value = CMTimeConvertScale(goal, timescale: track.timescale, method: .default).value
        var position = 0
        for (i, sample) in track.presentationOrder.enumerated() where track.samples[sample].time <= value { position = i }
        let first = track.samples[track.presentationOrder.first!].time, last = track.samples[track.presentationOrder.last!].time
        index = track.presentationOrder[position]
        completionHandler(presentationTimeStamp, value < first || value > last, nil)
    }

    func sampleLocation() throws -> MESampleLocation {
        MESampleLocation(byteSource: track.source,
                         sampleLocation: AVSampleCursorStorageRange(offset: sample.offset, length: Int64(sample.length)))
    }
}
