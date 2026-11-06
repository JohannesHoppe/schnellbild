import SwiftUI
import AppKit
import VLCKit
import CoreImage

/// VLCKit (LibVLC) playback for formats AVFoundation can't handle (AVI, MKV,
/// WebM …). Used only as a fallback; native formats stay on AVKit. Reports
/// state changes from any source (keys, the end of the video) to the model.
@MainActor
final class VLCPlaybackControl: NSObject, PlaybackControl, VLCMediaPlayerDelegate {
    /// One LibVLC instance for all players, without VLC's on-screen display:
    /// the auto enhance snapshots (`snapshotStats`) would otherwise show
    /// "Snapshot taken: <path>" and a preview over the video.
    static let library = VLCLibrary(options: ["--no-osd", "--no-snapshot-preview"])
    let player = VLCMediaPlayer(library: VLCPlaybackControl.library)
    private let url: URL
    private let onStateChange: @MainActor (PlaybackControl, Bool) -> Void
    private weak var drawable: NSView?

    /// Playing from `play()` until a pause or the end. VLC reports "playing"
    /// only once the media has opened, which would make an early Space press
    /// start it instead of pausing it.
    private(set) var isPlaying = true

    /// Sharpening is a VLC video filter chosen when the media opens, so it
    /// follows the look from the next video on; the adjust filter (gamma,
    /// contrast, saturation) switches at once.
    private var sharpen: Bool
    /// Where auto enhance's look goes (the model, for the sliders).
    var onAutoLook: @MainActor (PlaybackControl, Look) -> Void = { _, _ in }

    init(url: URL, enhancement: Enhancement = .off, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void) {
        self.url = url
        self.onStateChange = onStateChange
        switch enhancement {
        case .off: sharpen = false
        case .auto: sharpen = true
        case .manual(let look): sharpen = look.sharpness > 0
        }
        super.init()
        player.media = makeMedia()
        player.delegate = self
    }

    private func makeMedia() -> VLCMedia {
        let media = VLCMedia(url: url)
        if sharpen {
            media.addOption(":video-filter=sharpen")
            media.addOption(":sharpen-sigma=0.08")
        }
        return media
    }

    private var adaptive = AdaptiveLook()
    private var measureTask: Task<Void, Never>?
    /// The next measurement takes its value at once (after a seek).
    private var measureNow = true

    /// VLC hands out no frames to filter, so for auto enhance the picture is
    /// measured from a small snapshot once a second, gliding in between;
    /// the look goes to VLC's adjust filter (VLC's gamma is the inverse of
    /// Core Image's power: > 1 brightens).
    func setEnhancement(_ enhancement: Enhancement) {
        measureTask?.cancel()
        measureTask = nil
        switch enhancement {
        case .off:
            player.adjustFilter.isEnabled = false
        case .manual(let look):
            show(look)
        case .auto:
            show(adaptive.look)
            measureNow = true
            measureTask = Task { [weak self] in
                var sinceMeasure = Double.infinity
                var sinceReport = Double.infinity
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.measureNow || sinceMeasure >= 1 || !self.adaptive.hasPicture {
                        if let stats = await self.snapshotStats(), !Task.isCancelled {
                            self.adaptive.measure(stats, instant: self.measureNow)
                            self.measureNow = false
                        }
                        sinceMeasure = 0
                    } else {
                        self.adaptive.advance(by: 0.2)
                    }
                    guard !Task.isCancelled else { return }
                    self.show(self.adaptive.look)
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

    private func show(_ look: Look) {
        let adjust = player.adjustFilter
        adjust.gamma.value = NSNumber(value: 1 / look.gammaPower)
        adjust.contrast.value = NSNumber(value: look.contrastFactor)
        adjust.saturation.value = NSNumber(value: look.saturationFactor)
        adjust.isEnabled = true
    }

    /// Where the snapshots go: one folder per player, emptied before each
    /// snapshot and removed in `stop()`, so late ones don't pile up.
    private lazy var snapshotFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("schnellbild-vlc-\(UUID().uuidString)", isDirectory: true)

    /// Mean luminance of the frame on screen, from a 64-pixel-wide snapshot
    /// VLC writes to a temporary file; nil unless it plays (a paused picture
    /// doesn't change).
    private func snapshotStats() async -> PictureStats? {
        guard player.isPlaying else { return nil }
        let fm = FileManager.default
        try? fm.removeItem(at: snapshotFolder)
        try? fm.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        let file = snapshotFolder.appendingPathComponent("frame.png")
        player.saveVideoSnapshot(at: file.path, withWidth: 64, andHeight: 0)
        for _ in 0..<10 {   // written asynchronously
            try? await Task.sleep(for: .milliseconds(50))
            if let image = CIImage(contentsOf: file) {
                return PictureStats.of(image)
            }
        }
        return nil
    }

    /// For UI tests: VLC's state and the brightness of the decoded picture
    /// (from a snapshot), to tell "VLC decodes nothing" from "the picture
    /// doesn't reach the screen".
    func diagnostics() async -> String {
        let decoded = await snapshotStats().map { String(format: "%.3f", $0.mean) } ?? "none"
        return "vlc state \(player.state.rawValue), video out \(player.hasVideoOut), "
            + "size \(Int(player.videoSize.width))x\(Int(player.videoSize.height)), decoded \(decoded)"
    }

    /// Render into `view`; the first view starts playback.
    func attach(to view: NSView) {
        guard drawable !== view else { return }
        let first = drawable == nil
        drawable = view
        player.drawable = view
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
        try? FileManager.default.removeItem(at: snapshotFolder)
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
            let thumbnailer = VLCMediaThumbnailer(media: VLCMedia(url: url), delegate: self,
                                                  andVLCLibrary: VLCPlaybackControl.library)
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
