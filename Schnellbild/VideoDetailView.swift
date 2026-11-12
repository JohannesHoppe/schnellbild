import SwiftUI
import AVKit
import AVFoundation
import VLCFrames

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
    /// The video's stream when it lies inside an archive; closed with the
    /// player, whichever plays it (its unpacking thread stops then).
    @State private var archiveStream: ArchiveEntryStream?
    @State private var checking = true
    /// Pan while zoomed in, as for pictures.
    @State private var panOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    /// The video's picture size, for fitting it when turned a quarter.
    @State private var videoSize: CGSize?
    /// UI tests only: what VLC reports (`VLCPlaybackControl.diagnostics`).
    @State private var vlcDiagnostics = ""
    /// The file playing and its identity on disk: renamed or moved on the
    /// same volume (F2, the other pane), it plays on where it is.
    @State private var playing: (url: URL, file: FileIdentity?)?

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black
            Group {
                if let vlcControl {
                    VLCVideoView(control: vlcControl)
                } else if let avControl {
                    // Turned, its control bar would turn with the picture
                    // (upside down): hidden then, the keys still work
                    AVPlayerViewHost(player: avControl.player,
                                     showsControls: Int(model.rotation.rounded()) % 360 == 0)
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
            if model.zoom > 1.01 {
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
        .onChange(of: model.zoom) { _, zoom in if zoom <= 1.01 { panOffset = .zero } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(vlcControl != nil ? "video.vlc" : "video.avkit")
        .accessibilityLabel("zoom \(Int((model.zoom * 100).rounded())) %, rotation \(Int(model.rotation))°"
                            + (vlcDiagnostics.isEmpty ? "" : ", \(vlcDiagnostics)"))
        .task(id: vlcControl.map(ObjectIdentifier.init)) {
            vlcDiagnostics = ""
            guard Self.uiTesting, let control = vlcControl else { return }
            while !Task.isCancelled {
                vlcDiagnostics = control.diagnostics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: url) {
            // The same file under a new name (renamed, or its folder): the
            // player goes on, position and pause kept
            if let playing, playing.url != url, let file = playing.file,
               avControl != nil || vlcControl != nil, !ArchivePath.isInside(url) {
                let same = await FileIdentity.of(url, is: file)
                guard !Task.isCancelled else { return }
                if same {
                    self.playing = (url, file)
                    model.activePlayerURL = url
                    return
                }
            }
            panOffset = .zero
            stop()
            checking = true
            videoSize = nil
            model.actualSizeFactor = 1   // "1": a video's 100 % is its fitted size

            // Inside an archive: streamed from it, unpacked in memory as it plays
            var stream: ArchiveEntryStream?
            if ArchivePath.isInside(url) {
                stream = try? await ArchiveStore.shared.stream(of: url)
                guard stream != nil, !Task.isCancelled else {
                    stream?.close()
                    // (the spinner is the next video's once this task was left)
                    if !Task.isCancelled { checking = false }
                    return
                }
                archiveStream = stream
            }
            let loader = stream.map { ArchiveResourceLoader(stream: $0, fileName: url.lastPathComponent) }
            let asset = loader?.makeAsset(fileName: url.lastPathComponent) ?? AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { stream?.close(); return }   // the user moved on to another file
            checking = false
            playing = (url, nil)

            let model = self.model
            let report: @MainActor (PlaybackControl, Bool) -> Void = { control, playing in
                model.playbackStateChanged(control, isPlaying: playing)
            }
            let reportLook: @MainActor (PlaybackControl, Look) -> Void = { control, look in
                model.autoLookMeasured(look, from: control)
            }
            if playable && !Self.forceVLC && !Self.playsInVLC(url) {
                let control = AVPlaybackControl(player: AVPlayer(playerItem: AVPlayerItem(asset: asset)), onStateChange: report)
                control.resourceLoader = loader   // the asset holds its delegate weakly
                control.onAutoLook = reportLook
                avControl = control
                model.activePlayer = control
                model.activePlayerURL = url
                control.play()
                await noteFile(url)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await track.load(.naturalSize, .preferredTransform),
                   !Task.isCancelled {   // still this video
                    let turned = size.applying(transform)
                    videoSize = CGSize(width: abs(turned.width), height: abs(turned.height))
                }
            } else {
                // AVFoundation can't play it — hand off to VLCKit. It starts
                // playing once its view gives it somewhere to draw.
                // The file's first bytes, off the main thread (a network share can be slow)
                let head = stream == nil ? await Blocking.run { VLCSafety.head(of: url) } : nil
                guard !Task.isCancelled else { return }
                let source: VLCPlaybackControl.Source = stream.map { stream in .stream(url, { ArchiveInputStream(stream) }) } ?? .file(url, head: head)
                let control = VLCPlaybackControl(source: source, onStateChange: report)
                control.onAutoLook = reportLook
                vlcControl = control
                model.activePlayer = control
                model.activePlayerURL = url
                await noteFile(url)
                // VLC knows the size once the video plays: an AVI inside an
                // archive on a share may take long to open
                var waited = 0.0
                while !Task.isCancelled {
                    if let size = control.videoSize { videoSize = size; break }
                    let step = waited < 5 ? 0.1 : 0.5
                    try? await Task.sleep(for: .seconds(step))
                    waited += step
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

    /// Formats macOS reads only through a media extension: VLC plays them,
    /// with their sound. AVFoundation would call them playable through
    /// Schnellbild's own (picture only, for thumbnails) or another app's
    /// extension, once one is turned on. A transport stream (".ts", a TV
    /// recording) plays through VLC too, which reads every such stream.
    static let vlcFormats: Set<String> = ["mkv", "webm", "wmv", "asf", "flv", "ogv", "vob", "ts"]
    static func playsInVLC(_ url: URL) -> Bool { vlcFormats.contains(url.pathExtension.lowercased()) }

    /// Turned a quarter, the fitted video's now-swapped box is scaled to fit
    /// the view again (as `FullImageView` does for pictures).
    private func quarterTurnFit(in container: CGSize) -> CGFloat {
        guard Int((model.rotation / 90).rounded()) % 2 != 0, let size = videoSize,
              size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return 1 }
        let fit = min(container.width / size.width, container.height / size.height)
        let shownWidth = size.width * fit, shownHeight = size.height * fit
        return min(container.width / shownHeight, container.height / shownWidth)
    }

    /// Notes the identity of the file playing (not inside an archive: the
    /// stream reads the archive by its path).
    private func noteFile(_ url: URL) async {
        guard !ArchivePath.isInside(url) else { return }
        let file = await Blocking.run(.utility) { FileIdentity(of: url) }
        if !Task.isCancelled, playing?.url == url { playing = (url, file) }
    }

    private func stop() {
        playing = nil
        archiveStream?.close()
        archiveStream = nil
        avControl?.pause()
        vlcControl?.stop()
        model.activePlayer = nil
        model.activePlayerURL = nil
        avControl = nil
        vlcControl = nil
    }
}

/// AVKit's player view with floating controls: SwiftUI's `VideoPlayer` has
/// only the inline ones, which (like the minimal ones) dim the whole picture
/// while they show (macOS 26 and later).
struct AVPlayerViewHost: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .floating : .none
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        let style: AVPlayerViewControlsStyle = showsControls ? .floating : .none
        if view.controlsStyle != style { view.controlsStyle = style }
    }
}

/// A file's identity on disk (volume and file number): the same after a
/// rename or a move on the same volume.
struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init?(of url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = info.st_ino
    }

    /// Whether `url` is `file`, read off the main thread; a file system
    /// that doesn't answer within 0.3 s counts as another file, so paging
    /// on never waits for it.
    static func of(_ url: URL, is file: FileIdentity) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { answer in
            DispatchQueue.global(qos: .userInitiated).async {
                let same = FileIdentity(of: url) == file
                if once.claim() { answer.resume(returning: same) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                if once.claim() { answer.resume(returning: false) }
            }
        }
    }
}
