import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// Großansicht für Videos. Echter AVKit-Player mit Autoplay — aber nur für
/// Formate, die AVFoundation kann (MP4/MOV/M4V …). AVI/MKV/WebM & Co. kann
/// macOS nicht nativ abspielen; dafür gibt es einen sauberen Fallback statt
/// eines Schwarzbilds.
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
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
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
            Text("Dieses Format kann macOS nicht nativ abspielen")
                .font(.headline)
                .foregroundStyle(.white)
            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Mit Standard-App öffnen") {
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut(.defaultAction)
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .padding(.top, 4)
        }
        .padding(40)
    }
}
