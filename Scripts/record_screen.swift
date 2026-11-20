// Records the main display into a movie until it gets SIGINT or SIGTERM,
// for the demo video (.github/workflows/demo-video.yml):
//   record_screen <out.mov> <bundle id> [fps]
// Only the windows of the app with that bundle id are recorded: nothing of
// the system's comes in, also not the dot macOS shows in a full-screen
// space's corner while the screen is recorded.
// ScreenCaptureKit's stream at the display's pixel size, without the
// pointer, each frame written by AVAssetWriter as H.264 (High, quality 0.9)
// with the frame's own time: the stream sends a frame only when the screen
// changed, so the movie's frame rate varies. The movie starts with the
// first frame; "recording <time>" is printed then, with the time that frame
// was taken (seconds since 1970). The permission to record the
// screen comes from the shell that starts it.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "record_screen")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var stream: SCStream?
    private var started = false
    private(set) var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.9,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { fail("The writer takes no H.264 input") }
        writer.add(input)
        // Ready before the first frame comes: the movie starts with that frame
        guard writer.startWriting() else { fail("Writing failed: \(String(describing: writer.error))") }
        super.init()
    }

    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        guard input.isReadyForMoreMediaData else { return }
        if !started {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        guard input.append(buffer) else { return }
        frames += 1
        if frames == 1 {
            // When the movie's first frame was taken, on the wall clock (seconds since 1970)
            let age = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), buffer.presentationTimeStamp).seconds
            print(String(format: "recording %.3f", Date().timeIntervalSince1970 - age)); fflush(stdout)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("The stream stopped: \(error)\n".data(using: .utf8)!)
    }

    func stop() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.started else { self.writer.cancelWriting(); done.resume(); return }
                // The last picture lasts until now (the stream sends only changes)
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                self.writer.finishWriting { done.resume() }
            }
        }
        if writer.status != .completed { fail("Finishing failed: \(String(describing: writer.error))") }
        print("wrote \(frames) frames"); fflush(stdout)
    }
}

let args = CommandLine.arguments
guard args.count > 2 else { fail("Usage: record_screen <out.mov> <bundle id> [fps]") }
let url = URL(fileURLWithPath: args[1])
let bundleID = args[2]
let fps = args.count > 3 ? Int(args[3]) ?? 60 : 60
let id = CGMainDisplayID()
let width = CGDisplayPixelsWide(id), height = CGDisplayPixelsHigh(id)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let stopSources = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { fail("No main display") }
        let apps = content.applications.filter { $0.bundleIdentifier == bundleID }
        guard !apps.isEmpty else { fail("\(bundleID) isn't running") }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let recorder = try Recorder(url: url, width: width, height: height)
        try await recorder.start(filter: filter, width: width, height: height, fps: fps)
        for source in stopSources {
            source.setEventHandler {
                Task { await recorder.stop(); exit(0) }
            }
            source.resume()
        }
    } catch {
        fail("Recording failed: \(error)")
    }
}
dispatchMain()
