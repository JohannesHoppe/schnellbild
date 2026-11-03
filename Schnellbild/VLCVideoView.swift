import SwiftUI
import AppKit
import VLCKit

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

    init(url: URL, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void) {
        self.url = url
        self.onStateChange = onStateChange
        super.init()
        player.media = VLCMedia(url: url)
        player.delegate = self
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
            player.media = VLCMedia(url: url)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.delegate = nil
        player.stop()
    }

    func seek(by seconds: Double) {
        let step = Int32(abs(seconds).rounded())
        if seconds < 0 { player.jumpBackward(step) } else { player.jumpForward(step) }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            switch self.player.state {
            case .playing:                  self.isPlaying = true
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
