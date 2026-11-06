import SwiftUI
import AppKit
import VLCKit
import CoreImage

/// VLCKit (LibVLC) playback for formats AVFoundation can't handle (AVI, MKV,
/// WebM …). Used only as a fallback; native formats stay on AVKit. Reports
/// state changes from any source (keys, the end of the video) to the model.
@MainActor
final class VLCPlaybackControl: NSObject, PlaybackControl, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    private let url: URL
    private let onStateChange: @MainActor (PlaybackControl, Bool) -> Void
    private weak var drawable: NSView?

    /// Playing from `play()` until a pause or the end. VLC reports "playing"
    /// only once the media has opened, which would make an early Space press
    /// start it instead of pausing it.
    private(set) var isPlaying = true

    /// Sharpening is a VLC video filter chosen when the media opens, so it
    /// follows auto enhance from the next video on; the adjust filter
    /// (gamma, contrast, saturation) switches at once.
    private var sharpen: Bool

    init(url: URL, enhanced: Bool = false, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void) {
        self.url = url
        self.onStateChange = onStateChange
        sharpen = enhanced
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

    private var exposure = AdaptiveExposure()
    private var exposureTask: Task<Void, Never>?
    /// The next measurement takes its value at once (after a seek).
    private var measureNow = true

    /// VLC hands out no frames to filter, so the picture is measured the way
    /// AVKit videos are, from a small snapshot once a second, and corrected
    /// through VLC's adjust filter: gamma both ways (VLC's gamma is the
    /// inverse of Core Image's power: > 1 brightens), gliding in between,
    /// plus a little more contrast and colour.
    func setEnhanced(_ on: Bool) {
        let adjust = player.adjustFilter
        exposureTask?.cancel()
        exposureTask = nil
        guard on else { adjust.isEnabled = false; return }
        adjust.contrast.value = NSNumber(value: 1.08)
        adjust.saturation.value = NSNumber(value: 1.12)
        adjust.gamma.value = NSNumber(value: 1 / exposure.gamma)
        adjust.isEnabled = true
        measureNow = true
        exposureTask = Task { [weak self] in
            var sinceMeasure = Double.infinity
            while !Task.isCancelled {
                guard let self else { return }
                if self.measureNow || sinceMeasure >= 1 || !self.exposure.hasPicture {
                    if let luminance = await self.snapshotLuminance() {
                        _ = self.exposure.measure(luminance: luminance, instant: self.measureNow)
                        self.measureNow = false
                    }
                    sinceMeasure = 0
                } else {
                    self.exposure.advance(by: 0.2)
                }
                self.player.adjustFilter.gamma.value = NSNumber(value: 1 / self.exposure.gamma)
                try? await Task.sleep(for: .milliseconds(200))
                sinceMeasure += 0.2
            }
        }
    }

    /// Where the snapshots go: one folder per player, emptied before each
    /// snapshot and removed in `stop()`, so late ones don't pile up.
    private lazy var snapshotFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("schnellbild-vlc-\(UUID().uuidString)", isDirectory: true)

    /// Mean luminance of the frame on screen, from a 64-pixel-wide snapshot
    /// VLC writes to a temporary file; nil unless it plays (a paused picture
    /// doesn't change).
    private func snapshotLuminance() async -> Double? {
        guard player.isPlaying else { return nil }
        let fm = FileManager.default
        try? fm.removeItem(at: snapshotFolder)
        try? fm.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        let file = snapshotFolder.appendingPathComponent("frame.png")
        player.saveVideoSnapshot(at: file.path, withWidth: 64, andHeight: 0)
        for _ in 0..<10 {   // written asynchronously
            try? await Task.sleep(for: .milliseconds(50))
            if let image = CIImage(contentsOf: file) {
                return EnhanceRecipe.meanLuminance(of: image)
            }
        }
        return nil
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
        exposureTask?.cancel()
        exposureTask = nil
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
