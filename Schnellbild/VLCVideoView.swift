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
        player.play()

        let coordinator = context.coordinator
        coordinator.player = player
        coordinator.url = url
        coordinator.model = model
        // Not during the view update: publishing from here would re-enter SwiftUI.
        DispatchQueue.main.async { model.activePlayer = coordinator }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        context.coordinator.player?.media = VLCMedia(url: url)
        context.coordinator.player?.play()
        let coordinator = context.coordinator
        DispatchQueue.main.async { coordinator.model?.activePlayer = coordinator }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.player?.stop()
        if coordinator.model?.activePlayer === coordinator {
            coordinator.model?.activePlayer = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: PlaybackControl {
        var player: VLCMediaPlayer?
        var url: URL?
        weak var model: BrowserModel?

        func play()  { player?.play() }
        func pause() { player?.pause() }

        func seek(by seconds: Double) {
            let step = Int32(abs(seconds).rounded())
            if seconds < 0 { player?.jumpBackward(step) } else { player?.jumpForward(step) }
        }
    }
}
