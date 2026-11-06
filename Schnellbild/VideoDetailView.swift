import SwiftUI
import AVKit
import AVFoundation

/// Full-size view for videos. Native formats (MP4/MOV/M4V …) play through AVKit
/// with autoplay and standard controls. Formats AVFoundation can't handle
/// (AVI/MKV/WebM …) fall back to the vendored VLCKit player. Either way one
/// `PlaybackControl` is created and registered with the model here, so Space
/// and the arrow keys work for both.
struct VideoDetailView: View {
    let url: URL

    @EnvironmentObject var model: BrowserModel
    @State private var avControl: AVPlaybackControl?
    @State private var vlcControl: VLCPlaybackControl?
    @State private var checking = true

    var body: some View {
        ZStack {
            Color.black
            if let vlcControl {
                VLCVideoView(control: vlcControl)
            } else if let avControl {
                VideoPlayer(player: avControl.player)
            } else if checking {
                LoadingSpinner()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(vlcControl != nil ? "video.vlc" : "video.avkit")
        .task(id: url) {
            stop()
            checking = true

            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }   // the user moved on to another file
            checking = false

            let model = self.model
            let report: @MainActor (PlaybackControl, Bool) -> Void = { control, playing in
                model.playbackStateChanged(control, isPlaying: playing)
            }
            if playable {
                let control = AVPlaybackControl(player: AVPlayer(playerItem: AVPlayerItem(asset: asset)), onStateChange: report)
                avControl = control
                model.activePlayer = control
                control.play()
            } else {
                // AVFoundation can't play it — hand off to VLCKit. It starts
                // playing once its view gives it somewhere to draw.
                let control = VLCPlaybackControl(url: url, enhanced: model.enhance, onStateChange: report)
                vlcControl = control
                model.activePlayer = control
            }
        }
        .onDisappear { stop() }
    }

    private func stop() {
        avControl?.pause()
        vlcControl?.stop()
        model.activePlayer = nil
        avControl = nil
        vlcControl = nil
    }
}
