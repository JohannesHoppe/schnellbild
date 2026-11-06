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
    /// Pan while zoomed in, as for pictures.
    @State private var panOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black
            Group {
                if let vlcControl {
                    VLCVideoView(control: vlcControl)
                } else if let avControl {
                    VideoPlayer(player: avControl.player)
                } else if checking {
                    LoadingSpinner()
                }
            }
            // Zoom (keys, pinch) and rotation like a picture; only the view
            // changes. Zoomed in, the player's own control bar is out of
            // reach, the keys still work.
            .rotationEffect(.degrees(model.rotation))
            .scaleEffect(model.zoom)
            .offset(x: panOffset.width + dragTranslation.width, y: panOffset.height + dragTranslation.height)
            if model.zoom > 1 {
                // Takes the drag for panning while zoomed in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture()
                        .updating($dragTranslation) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            panOffset.width += value.translation.width
                            panOffset.height += value.translation.height
                        })
            }
        }
        .clipped()
        .onChange(of: model.zoom) { _, zoom in if zoom == 1 { panOffset = .zero } }
        .onChange(of: url) { _, _ in panOffset = .zero }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(vlcControl != nil ? "video.vlc" : "video.avkit")
        .accessibilityLabel("zoom \(Int((model.zoom * 100).rounded())) %, rotation \(Int(model.rotation))°")
        .task(id: url) {
            stop()
            checking = true
            model.actualSizeFactor = 1   // "1": a video's 100 % is its fitted size

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
