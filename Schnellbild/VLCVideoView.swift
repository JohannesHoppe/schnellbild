import SwiftUI
import AppKit
import VLCKit
import CoreImage

/// VLCKit (LibVLC) playback for formats AVFoundation can't handle (AVI, MKV,
/// WebM …). Used only as a fallback; native formats stay on AVKit. Reports
/// state changes from any source (keys, the end of the video) to the model.
@MainActor
final class VLCPlaybackControl: NSObject, PlaybackControl, VLCMediaPlayerDelegate {
    let player: VLCMediaPlayer = {
        _ = VLCPlaybackControl.testLog
        return VLCMediaPlayer()
    }()

    /// UI tests: VLC logs everything to /tmp/schnellbild-vlc.log, which the
    /// CI workflow shows when a test fails.
    private static let testLog: Void = {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        let path = "/tmp/schnellbild-vlc.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        let logger = VLCFileLogger.create(with: handle)
        logger.level = .debug
        VLCLibrary.shared().loggers = [logger]
    }()
    /// Where the picture goes (no OpenGL; see `VLCFrameOutput`).
    let output = VLCFrameOutput()
    private let url: URL
    private let onStateChange: @MainActor (PlaybackControl, Bool) -> Void
    private weak var drawable: NSView?

    /// Playing from `play()` until a pause or the end. VLC reports "playing"
    /// only once the media has opened, which would make an early Space press
    /// start it instead of pausing it.
    private(set) var isPlaying = true

    /// Where auto enhance's look goes (the model, for the sliders).
    var onAutoLook: @MainActor (PlaybackControl, Look) -> Void = { _, _ in }

    init(url: URL, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void) {
        self.url = url
        self.onStateChange = onStateChange
        super.init()
        player.media = makeMedia()
        player.delegate = self
        output.attach(to: player)
    }

    private func makeMedia() -> VLCMedia {
        let media = VLCMedia(url: url)
        // No on-screen messages (VLC would draw them into the picture)
        media.addOption(":no-osd")
        return media
    }

    private var adaptive = AdaptiveLook()
    private var measureTask: Task<Void, Never>?
    /// The next measurement takes its value at once (after a seek).
    private var measureNow = true

    /// The look is applied by `VLCFrameOutput`, as Core Image does for
    /// AVKit. For auto enhance the decoded picture is measured once a
    /// second, gliding in between.
    func setEnhancement(_ enhancement: Enhancement) {
        measureTask?.cancel()
        measureTask = nil
        switch enhancement {
        case .off:
            output.setLook(.neutral)
        case .manual(let look):
            output.setLook(look)
        case .auto:
            output.setLook(adaptive.look)
            measureNow = true
            measureTask = Task { [weak self] in
                var sinceMeasure = Double.infinity
                var sinceReport = Double.infinity
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.measureNow || sinceMeasure >= 1 || !self.adaptive.hasPicture {
                        if let stats = await self.pictureStats(), !Task.isCancelled {
                            self.adaptive.measure(stats, instant: self.measureNow)
                            self.measureNow = false
                        }
                        sinceMeasure = 0
                    } else {
                        self.adaptive.advance(by: 0.2)
                    }
                    guard !Task.isCancelled else { return }
                    self.output.setLook(self.adaptive.look)
                    if sinceReport >= 0.25 {
                        self.onAutoLook(self, self.adaptive.look)
                        sinceReport = 0
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    sinceMeasure += 0.2
                    sinceReport += 0.2
                }
            }
        }
    }

    /// The picture on screen, measured; nil unless it plays (a paused
    /// picture doesn't change).
    private func pictureStats() async -> PictureStats? {
        guard player.isPlaying else { return nil }
        let output = self.output
        return await Task.detached(priority: .utility) { output.latestStats }.value
    }

    /// For UI tests: VLC's state and the brightness of the picture it hands
    /// over, to tell "VLC decodes nothing" from "the picture doesn't reach
    /// the screen".
    func diagnostics() async -> String {
        let decoded = await pictureStats().map { String(format: "%.3f", $0.mean) } ?? "none"
        let stats = player.media?.statistics
        return "vlc state \(player.state.rawValue), "
            + "size \(Int(player.videoSize.width))x\(Int(player.videoSize.height)), decoded \(decoded), "
            + "shown \(stats?.displayedPictures ?? 0), lost \(stats?.lostPictures ?? 0)"
    }

    /// Show the picture in `view`; the first view starts playback.
    func attach(to view: NSView) {
        guard drawable !== view else { return }
        let first = drawable == nil
        drawable = view
        output.layer.frame = view.bounds
        output.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(output.layer)
        if first { player.play() }
    }

    /// At the end, playing starts over.
    func play() {
        if player.state == .ended || player.state == .stopped {
            player.media = makeMedia()
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        measureTask?.cancel()
        measureTask = nil
        player.delegate = nil
        player.stop()
    }

    /// The last seek target: VLC reports the new position only once it has
    /// got there, so quick key presses would otherwise start from the old one.
    private var pendingSeek: (target: Double, at: Date)?

    var progress: Double? {
        if player.state == .ended { return 1 }
        guard (player.media?.length.intValue ?? 0) > 0 else { return nil }
        let reported = Double(min(max(player.position, 0), 1))
        if let pending = pendingSeek {
            if abs(reported - pending.target) > 0.02, Date().timeIntervalSince(pending.at) < 1.5 {
                return pending.target
            }
            pendingSeek = nil
        }
        return reported
    }

    /// From the end the media is opened again; VLC ignores a position set
    /// before it plays, so it's applied once playback has started.
    private var positionOnceOpen: Float?

    func seek(toProgress progress: Double) {
        let target = min(max(progress, 0), 1)
        pendingSeek = (target, Date())
        if player.state == .ended || player.state == .stopped {
            positionOnceOpen = Float(target)
            play()
        } else {
            player.position = Float(target)
        }
        measureNow = true   // a new scene: measure again at once
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            switch self.player.state {
            case .playing:
                self.isPlaying = true
                if let position = self.positionOnceOpen {
                    self.positionOnceOpen = nil
                    self.player.position = position
                }
            case .paused, .ended, .error:   self.isPlaying = false
            default:                        return
            }
            self.onStateChange(self, self.isPlaying)
        }
    }
}

/// The surface a `VLCPlaybackControl` draws into.
struct VLCVideoView: NSViewRepresentable {
    let control: VLCPlaybackControl

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        control.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        control.attach(to: nsView)   // a new control after switching files
    }
}

/// Thumbnails of videos QuickLook can't read (AVI, MKV, WebM …): VLC decodes
/// a frame at 30 % of the video. At most two run at a time, since each one
/// opens and decodes the file.
@MainActor
final class VLCThumbnails: NSObject, VLCMediaThumbnailerDelegate {
    static let shared = VLCThumbnails()
    private static let limit = 2
    private var running = 0
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var pending: [ObjectIdentifier: (thumbnailer: VLCMediaThumbnailer, done: CheckedContinuation<CGImage?, Never>)] = [:]

    /// A frame `width` pixels wide (the height follows the video), or nil.
    func thumbnail(for url: URL, width: CGFloat) async -> CGImage? {
        if running >= Self.limit {
            await withCheckedContinuation { queue.append($0) }
        }
        running += 1
        defer {
            running -= 1
            if !queue.isEmpty { queue.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { done in
            let thumbnailer = VLCMediaThumbnailer(media: VLCMedia(url: url), delegate: self, andVLCLibrary: nil)
            thumbnailer.thumbnailWidth = width
            thumbnailer.thumbnailHeight = 0
            pending[ObjectIdentifier(thumbnailer)] = (thumbnailer, done)
            thumbnailer.fetchThumbnail()
        }
    }

    private func finish(_ thumbnailer: VLCMediaThumbnailer, with image: CGImage?) {
        pending.removeValue(forKey: ObjectIdentifier(thumbnailer))?.done.resume(returning: image)
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        MainActor.assumeIsolated { finish(mediaThumbnailer, with: nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        MainActor.assumeIsolated { finish(mediaThumbnailer, with: thumbnail) }
    }
}
