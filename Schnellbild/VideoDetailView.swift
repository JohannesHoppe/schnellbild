import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// Full-size view for videos. A real AVKit player with autoplay — but only for
/// formats AVFoundation supports (MP4/MOV/M4V …). macOS can't natively play
/// AVI/MKV/WebM & co.; for those there's a clean fallback instead of a
/// black frame.
struct VideoDetailView: View {
    let url: URL

    @EnvironmentObject var model: BrowserModel
    @State private var player: AVPlayer?
    @State private var unplayable = false
    @State private var checking = true

    var body: some View {
        ZStack {
            Color.black
            if unplayable {
                fallback
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
            unplayable = false
            checking = true

            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            checking = false

            guard playable else {
                unplayable = true
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

    private var fallback: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("macOS can't play this format natively")
                .font(.headline)
                .foregroundStyle(.white)
            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Open with Default App") { model.openInDefaultApp() }
                    .keyboardShortcut(.defaultAction)
                Button("Reveal in Finder") { model.revealInFinder() }
            }
            .padding(.top, 4)
        }
        .padding(40)
    }
}
