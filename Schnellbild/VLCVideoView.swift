import SwiftUI
import AppKit
import VLCKit

/// Playback for formats AVFoundation can't handle (AVI, MKV, WebM …), backed by
/// the vendored VLCKit (LibVLC). Used only as a fallback; native formats stay
/// on AVKit.
struct VLCVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let player = VLCMediaPlayer()
        player.drawable = view
        player.media = VLCMedia(url: url)
        player.play()

        context.coordinator.player = player
        context.coordinator.url = url
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        context.coordinator.player?.media = VLCMedia(url: url)
        context.coordinator.player?.play()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.player?.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: VLCMediaPlayer?
        var url: URL?
    }
}
