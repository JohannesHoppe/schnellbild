import SwiftUI
import AVKit
import AVFoundation

/// Full-size view for videos. Native formats (MP4/MOV/M4V …) play through AVKit
/// with autoplay and standard controls. Formats AVFoundation can't handle
/// (AVI/MKV/WebM …) fall back to the vendored VLCKit player. Both register a
/// `PlaybackControl` with the model, so Space and ⌘←/⌘→ work for either.
struct VideoDetailView: View {
    let url: URL

    @EnvironmentObject var model: BrowserModel
    @State private var control: AVPlaybackControl?
    @State private var useVLC = false
    @State private var checking = true

    var body: some View {
        ZStack {
            Color.black
            if useVLC {
                VLCVideoView(url: url, model: model)
            } else if let control {
                VideoPlayer(player: control.player)
            } else if checking {
                LoadingSpinner()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(useVLC ? "video.vlc" : "video.avkit")
        .task(id: url) {
            control?.pause()
            model.activePlayer = nil
            control = nil
            useVLC = false
            checking = true

            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }   // the user moved on to another file
            checking = false

            guard playable else {
                useVLC = true   // AVFoundation can't play it — hand off to VLCKit
                return
            }
            let model = self.model
            let new = AVPlaybackControl(player: AVPlayer(playerItem: AVPlayerItem(asset: asset))) { control, playing in
                model.playbackStateChanged(control, isPlaying: playing)
            }
            control = new
            model.activePlayer = new
            new.play()
        }
        .onDisappear {
            control?.pause()
            model.activePlayer = nil
        }
    }
}
