import SwiftUI
import AppKit
import VLCKit
import VLCFrames
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
    /// What VLC opens: a file, or a stream (a video inside an archive, named
    /// by its path through the archive; a new stream for every opening).
    enum Source {
        /// A file and its first bytes (which reader VLC may use, `VLCSafety`)
        case file(URL, head: Data?)
        case stream(URL, () -> InputStream)
    }
    private let source: Source
    private let onStateChange: @MainActor (PlaybackControl, Bool) -> Void
    private weak var drawable: NSView?

    /// Playing from `play()` until a pause or the end. VLC reports "playing"
    /// only once the media has opened, which would make an early Space press
    /// start it instead of pausing it.
    private(set) var isPlaying = true

    /// Where auto enhance's look goes (the model, for the sliders).
    var onAutoLook: @MainActor (PlaybackControl, Look) -> Void = { _, _ in }

    init(source: Source, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void) {
        self.source = source
        self.onStateChange = onStateChange
        super.init()
        player.media = makeMedia()
        player.delegate = self
        output.attach(to: player)
    }

    private func makeMedia() -> VLCMedia {
        let media: VLCMedia
        let name: URL
        var head: Data?
        switch source {
        case .file(let url, let first):     media = VLCMedia(url: url); name = url; head = first
        case .stream(let url, let makeStream): media = VLCMedia(stream: makeStream()); name = url
        }
        VLCSafety.restrict(media, for: name, head: head)
        // No on-screen messages (VLC would draw them into the picture)
        media.addOption(":no-osd")
        // VLCKit turns on "play-and-pause": VLC would pause as soon as it has
        // read the file to its end, before the last pictures are shown, and
        // never report the end (the slideshow waits for it)
        media.addOption(":no-play-and-pause")
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

    /// The decoded picture on screen, measured (also paused or at the end).
    private func pictureStats() async -> PictureStats? {
        let output = self.output
        return await Task.detached(priority: .utility) { output.latestStats }.value
    }

    /// For UI tests: VLC's state, the pictures it showed and lost, and what
    /// handing them over costs.
    func diagnostics() -> String {
        let stats = player.media?.statistics
        let size = videoSize ?? .zero
        return "vlc state \(player.state.rawValue), size \(Int(size.width))x\(Int(size.height)), "
            + "shown \(stats?.displayedPictures ?? 0), lost \(stats?.lostPictures ?? 0), \(output.diagnostics)"
    }

    /// Show the picture in `view`; the first view starts playback.
    func attach(to view: NSView) {
        guard drawable !== view else { return }
        let first = drawable == nil
        drawable = view
        output.layer.frame = view.bounds
        output.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // A view reused for the next video holds only that one's picture
        view.layer?.sublayers?.filter { $0 !== output.layer }.forEach { $0.removeFromSuperlayer() }
        view.layer?.addSublayer(output.layer)
        if first { player.play() }
    }

    /// The picture's size as shown (non-square pixels made square), once
    /// VLC has opened its output.
    var videoSize: CGSize? {
        if let shown = output.pictureSize { return shown }
        let size = player.videoSize
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// Playing, its clock running, with no length (VLC knows none for a
    /// WebM a browser recorded).
    var playsWithoutLength: Bool {
        player.state == .playing && (player.media?.length.intValue ?? 0) <= 0 && player.time.intValue > 0
    }

    /// Ended or stopped: playing opens the video again.
    private var atEnd: Bool { player.state == .ended || player.state == .stopped }

    /// At the end, playing starts over.
    func play() {
        BrowserModel.testLog("vlc play, state \(player.state.rawValue), position \(player.position)")
        if atEnd {
            player.media = makeMedia()
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Stopping waits for VLC's reading thread; with a read stalled on a
    /// network share that takes until it times out, so it waits off the
    /// main thread (the block keeps the player until then).
    func stop() {
        measureTask?.cancel()
        measureTask = nil
        player.delegate = nil
        // Nothing else touches it once stopping: the control is going away.
        // (The picture output lives as long as the player: `VLCFrameOutput.attach`.)
        // VLCKit reports "stopped" at once and waits for its reading thread
        // only when the player goes (the last release). This block holds the
        // player until the control has gone too, so that last release, and
        // its wait on a read stalled on a network share, happen here and
        // never on the main thread.
        nonisolated(unsafe) let player = self.player
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            player.stop()
            for _ in 0..<100 where player.state != .stopped { usleep(50_000) }
            for _ in 0..<1200 where self != nil { usleep(50_000) }
            BrowserModel.testLog("vlc stopped")
        }
    }

    /// The last seek target: VLC reports the new position only once it has
    /// got there, so quick key presses would otherwise start from the old one.
    private var pendingSeek: (target: Double, at: Date)?

    /// The app's volume, set again once VLC has its audio output (it
    /// opens with the media).
    private var volume = 1.0
    func setVolume(_ volume: Double) {
        self.volume = volume
        player.audio?.volume = Int32((volume * 100).rounded())
    }

    /// Played to its end: VLC goes on from "ended" to "stopped" quickly,
    /// and its position then is that of the last picture, short of 1.
    private var reachedEnd = false

    var lengthSeconds: Double? {
        let ms = player.media?.length.intValue ?? 0
        return ms > 0 ? Double(ms) / 1000 : nil
    }

    var progress: Double? {
        if reachedEnd || player.state == .ended { return 1 }
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
        reachedEnd = false
        pendingSeek = (target, Date())
        if atEnd {
            positionOnceOpen = Float(target)
            play()
        } else {
            player.position = Float(target)
        }
        measureNow = true   // a new scene: measure again at once
    }

    /// The state is read while the notification is delivered: read later, a
    /// quick "ended" would already be "stopped" and the end missed. It is
    /// handled once VLCKit's callback has returned, since handling it can
    /// move on to the next item and stop this player.
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = (aNotification.object as? VLCMediaPlayer)?.state
        Task { @MainActor in self.stateChanged(to: state ?? self.player.state) }
    }

    private func stateChanged(to state: VLCMediaPlayerState) {
        BrowserModel.testLog("vlc state \(state.rawValue)")
        switch state {
        case .playing:
            reachedEnd = false
            isPlaying = true
            player.audio?.volume = Int32((volume * 100).rounded())
            if let position = positionOnceOpen {
                positionOnceOpen = nil
                player.position = position
            }
        case .ended:
            reachedEnd = true
            isPlaying = false
        case .paused, .error:   isPlaying = false
        default:                        return
        }
        onStateChange(self, isPlaying)
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

/// Thumbnails of videos QuickLook has only an icon for (Schnellbild's
/// QuickLook extension not registered yet, or a type it doesn't take): VLC decodes
/// a frame at 30 % of the video (`VLCFrameGrab`). At most two run at a
/// time, since each one opens and decodes the file.
@MainActor
final class VLCThumbnails {
    static let shared = VLCThumbnails()
    private static let limit = 2
    private var running = 0
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// A frame `width` pixels wide (the height follows the video), or nil.
    func thumbnail(for url: URL, width: CGFloat) async -> CGImage? {
        // A finishing call hands its place straight to the next waiting one,
        // so no new call can slip in between
        if running >= Self.limit {
            await withCheckedContinuation { queue.append($0) }
        } else {
            running += 1
        }
        defer {
            if queue.isEmpty { running -= 1 } else { queue.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return nil }
        return await VLCFrameGrab.frame(of: url, width: Int(width.rounded()))
    }
}
