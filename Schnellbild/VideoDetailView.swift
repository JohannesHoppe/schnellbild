import SwiftUI
import AVKit
import AVFoundation

/// Full-size view for videos. Native formats (MP4/MOV/M4V …) play through AVKit
/// with autoplay and standard controls. Formats AVFoundation can't handle
/// (AVI/MKV/WebM …) fall back to the vendored VLCKit player.
struct VideoDetailView: View {
    let url: URL

    @EnvironmentObject var model: BrowserModel
    @State private var player: AVPlayer?
    @State private var useVLC = false
    @State private var checking = true

    var body: some View {
        ZStack {
            Color.black
            if useVLC {
                VLCVideoView(url: url)
            } else if let player {
                VideoPlayer(player: player)
            } else if checking {
                LoadingSpinner()
            }
        }
        .task(id: url) {
            player?.pause()
            model.activePlayer = nil
            player = nil
            useVLC = false
            checking = true

            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            checking = false

            guard playable else {
                useVLC = true   // AVFoundation can't play it — hand off to VLCKit
                return
            }
            let item = AVPlayerItem(asset: asset)
            let new = AVPlayer(playerItem: item)
            player = new
            model.activePlayer = new
            new.play()
        }
        .onDisappear {
            player?.pause()
            model.activePlayer = nil
        }
    }
}
