import SwiftUI
import AppKit
import VLCKit

/// Playback for formats AVFoundation can't handle (AVI, MKV, WebM …), backed by
/// the vendored VLCKit (LibVLC). Used only as a fallback; native formats stay
/// on AVKit.
struct VLCVideoView: NSViewRepresentable {
    let url: URL
    let model: BrowserModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let player = VLCMediaPlayer()
        player.drawable = view
        player.media = VLCMedia(url: url)

        let coordinator = context.coordinator
        coordinator.player = player
        coordinator.url = url
        coordinator.model = model
        player.delegate = coordinator
        player.play()
        coordinator.register()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        context.coordinator.player?.media = VLCMedia(url: url)
        context.coordinator.player?.play()
        context.coordinator.register()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.isLive = false
        coordinator.player?.delegate = nil
        coordinator.player?.stop()
        if coordinator.model?.activePlayer === coordinator {
            coordinator.model?.activePlayer = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, PlaybackControl, VLCMediaPlayerDelegate {
        var player: VLCMediaPlayer?
        var url: URL?
        weak var model: BrowserModel?
        /// False once the view is gone; a registration still queued then must
        /// not replace the player that took over.
        var isLive = true

        /// Become the model's active player — not during the view update
        /// (publishing from there would re-enter SwiftUI), and only if this
        /// view still shows the selected video by then.
        func register() {
            let url = url
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isLive, let model = self.model,
                      model.selectedMediaEntry?.url == url else { return }
                model.activePlayer = self
            }
        }

        /// Playing from `play()` until a pause or the end. VLC reports
        /// "playing" only once the media has opened, which would make an early
        /// Space press start it instead of pausing it.
        private(set) var isPlaying = true

        /// At the end, playing starts over.
        func play() {
            if player?.state == .ended || player?.state == .stopped, let url {
                player?.media = VLCMedia(url: url)
            }
            player?.play()
            isPlaying = true
        }

        func pause() {
            player?.pause()
            isPlaying = false
        }

        func seek(by seconds: Double) {
            let step = Int32(abs(seconds).rounded())
            if seconds < 0 { player?.jumpBackward(step) } else { player?.jumpForward(step) }
        }

        nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
            Task { @MainActor in
                guard self.isLive, let player = self.player else { return }
                switch player.state {
                case .playing:                  self.isPlaying = true
                case .paused, .ended, .error:   self.isPlaying = false
                default:                        return
                }
                self.model?.playbackStateChanged(self, isPlaying: self.isPlaying)
            }
        }
    }
}
