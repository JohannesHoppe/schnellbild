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
    /// The video's picture size, for fitting it when turned a quarter.
    @State private var videoSize: CGSize?
    /// UI tests only: what VLC reports (`VLCPlaybackControl.diagnostics`).
    @State private var vlcDiagnostics = ""

    var body: some View {
        GeometryReader { geo in
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
            .scaleEffect(model.zoom * quarterTurnFit(in: geo.size))
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
        }
        .clipped()
        .onChange(of: model.zoom) { _, zoom in if zoom == 1 { panOffset = .zero } }
        .onChange(of: url) { _, _ in panOffset = .zero }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(vlcControl != nil ? "video.vlc" : "video.avkit")
        .accessibilityLabel("zoom \(Int((model.zoom * 100).rounded())) %, rotation \(Int(model.rotation))°"
                            + (vlcDiagnostics.isEmpty ? "" : ", \(vlcDiagnostics)"))
        .task(id: vlcControl.map(ObjectIdentifier.init)) {
            vlcDiagnostics = ""
            guard Self.uiTesting, let control = vlcControl else { return }
            while !Task.isCancelled {
                vlcDiagnostics = await control.diagnostics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: url) {
            stop()
            checking = true
            videoSize = nil
            model.actualSizeFactor = 1   // "1": a video's 100 % is its fitted size

            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }   // the user moved on to another file
            checking = false

            let model = self.model
            let report: @MainActor (PlaybackControl, Bool) -> Void = { control, playing in
                model.playbackStateChanged(control, isPlaying: playing)
            }
            let reportLook: @MainActor (PlaybackControl, Look) -> Void = { control, look in
                model.autoLookMeasured(look, from: control)
            }
            if playable && !Self.forceVLC {
                let control = AVPlaybackControl(player: AVPlayer(playerItem: AVPlayerItem(asset: asset)), onStateChange: report)
                control.onAutoLook = reportLook
                avControl = control
                model.activePlayer = control
                control.play()
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let turned = size.applying(transform)
                    videoSize = CGSize(width: abs(turned.width), height: abs(turned.height))
                }
            } else {
                // AVFoundation can't play it — hand off to VLCKit. It starts
                // playing once its view gives it somewhere to draw.
                let control = VLCPlaybackControl(url: url, onStateChange: report)
                control.onAutoLook = reportLook
                vlcControl = control
                model.activePlayer = control
                // VLC knows the size once the video plays
                for _ in 0..<50 where !Task.isCancelled {
                    let size = control.player.videoSize
                    if size.width > 0, size.height > 0 { videoSize = size; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        .onDisappear { stop() }
    }

    /// UI tests (`--ui-testing --force-vlc`) play every video through VLC, so
    /// the same test videos check both players.
    static let uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    static let forceVLC = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        && ProcessInfo.processInfo.arguments.contains("--force-vlc")

    /// Turned a quarter, the fitted video's now-swapped box is scaled to fit
    /// the view again (as `FullImageView` does for pictures).
    private func quarterTurnFit(in container: CGSize) -> CGFloat {
        guard Int((model.rotation / 90).rounded()) % 2 != 0, let size = videoSize,
              size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return 1 }
        let fit = min(container.width / size.width, container.height / size.height)
        let shownWidth = size.width * fit, shownHeight = size.height * fit
        return min(container.width / shownHeight, container.height / shownWidth)
    }

    private func stop() {
        avControl?.pause()
        vlcControl?.stop()
        model.activePlayer = nil
        avControl = nil
        vlcControl = nil
    }
}
