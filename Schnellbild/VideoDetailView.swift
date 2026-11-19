import SwiftUI
import AVKit
import AVFoundation
import Combine
import VLCFrames
import UniformTypeIdentifiers

/// The first value of `object`'s `key` that `accepted` takes, the current one
/// included, as KVO reports it (AVFoundation's item status, its tracks),
/// looked at on the main thread; nil after `limit` or when the task is cancelled.
@MainActor
func firstObserved<Object: NSObject, Value>(_ object: Object, _ key: KeyPath<Object, Value>, within limit: Duration,
                                            where accepted: @escaping @MainActor (Value) -> Bool) async -> Value? {
    let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
    for await value in object.publisher(for: key, options: [.initial, .new]).receive(on: DispatchQueue.main)
        .first(where: { value in MainActor.assumeIsolated { accepted(value) } })
        .timeout(.seconds(seconds), scheduler: DispatchQueue.main).values {
        return value
    }
    return nil
}

/// Full-size view for videos. Native formats (MP4/MOV/M4V …) play through AVKit
/// with autoplay, under the app's own control bar (`VideoControlBar`, both
/// players). Formats AVFoundation can't handle
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
    /// The folder's memory of places the video began in
    /// (`PlaybackPositions.list`): where it stands is remembered there when
    /// it is left.
    @State private var positionList: Int?
    /// Why the video can't play (a download cut off before its index).
    @State private var unplayable: String?
    /// Opened again (a download that grew); with where it stood.
    @State private var opening = 0
    @State private var resumeAt: Double?
    /// UI tests only: why AVKit handed the video over to VLC.
    @State private var takenOver = ""

    /// The zoom and turn (and, for the UI tests, the tracks, speed and what
    /// VLC reports).
    private var accessibilityText: String {
        var text = "zoom \(Int((model.zoom * 100).rounded())) %, rotation \(Int(model.rotation))°"
        if TestSwitches.on {
            text += ", " + Self.describe(model.activePlayer?.tracks ?? model.videoTracks, speed: model.playbackSpeed)
            // What the player itself has (the dual pane's tests: the other pane's player follows)
            if let volume = model.activePlayer?.playerVolume { text += ", player volume \(Int((volume * 100).rounded())) %" }
            if let speed = model.activePlayer?.playerSpeed { text += ", player speed \(speed)" }
        }
        if !vlcDiagnostics.isEmpty { text += ", \(vlcDiagnostics)" }
        if TestSwitches.on, !takenOver.isEmpty { text += ", taken over from AVKit: \(takenOver)" }
        return text
    }

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black
            Group {
                if let vlcControl {
                    VLCVideoView(control: vlcControl)
                } else if let avControl {
                    // The app's own control bar (`VideoControlBar`) serves both players
                    AVPlayerLayerHost(control: avControl)
                } else if let unplayable {
                    Label {
                        Text(unplayable)
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding()
                    .accessibilityIdentifier("video.unplayable")
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
        .onChange(of: model.zoom) { old, new in panOffset = BrowserModel.panOffset(panOffset, zoomedFrom: old, to: new) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(vlcControl != nil ? "video.vlc" : "video.avkit")
        .accessibilityLabel(accessibilityText)
        .task(id: vlcControl.map(ObjectIdentifier.init)) {
            vlcDiagnostics = ""
            guard TestSwitches.on, let control = vlcControl else { return }
            while !Task.isCancelled {
                vlcDiagnostics = control.diagnostics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: Opening(url: url, count: opening)) {
            // The same file under a new name (renamed, or its folder; a
            // download finished): the player goes on, position and pause kept
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
            let reopenAt = resumeAt
            resumeAt = nil
            if reopenAt == nil { panOffset = .zero }
            stop()
            checking = true
            unplayable = nil
            takenOver = ""
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
            // An MP4 whose download stopped before its index: nothing can
            // play it yet, which is said instead of a black view
            if stream == nil, await Blocking.run(.userInitiated, { FileBytes(url).map(MP4Boxes.indexCutOff) ?? false }) {
                guard !Task.isCancelled else { return }
                checking = false
                unplayable = String(localized: "This video can't play until its download is finished: the part that tells how to play it lies at the end of the file.")
                BrowserModel.testLog("video: index cut off | \(url.lastPathComponent)")
                return
            }
            // A reference movie names other files or addresses to play; it plays nothing here
            let asset = loader?.makeAsset(fileName: url.lastPathComponent)
                ?? AVURLAsset(url: url, options: Self.assetOptions(for: url))
            // A video that plays in VLC anyway isn't asked (no wait on AVFoundation)
            let inVLC = Self.forceVLC || Self.playsInVLC(url)
            let playable = inVLC ? false : ((try? await asset.load(.isPlayable)) ?? false)
            guard !Task.isCancelled else { stream?.close(); return }   // the user moved on to another file
            checking = false
            playing = (url, nil)

            let model = self.model
            // Opened again where it stood (a download that grew), else left
            // earlier in this folder: on from there
            let resume = reopenAt.map { PlaybackPositions.Place(seconds: $0, playing: true) }
                ?? model.playbackPositions.place(of: url)
            positionList = model.playbackPositions.list
            let report: @MainActor (PlaybackControl, Bool) -> Void = { control, playing in
                model.playbackStateChanged(control, isPlaying: playing)
            }
            let reportLook: @MainActor (PlaybackControl, Look) -> Void = { control, look in
                model.autoLookMeasured(look, from: control)
            }
            let reportTracks: @MainActor (PlaybackControl) -> Void = { control in model.tracksChanged(from: control) }
            // VLC plays it: a format of its own, or one AVFoundation refused
            // (also once it had opened it: a cut-off download VLC plays as
            // far as its data reaches)
            @MainActor func playInVLC(from place: PlaybackPositions.Place?) async {
                // The file's first bytes, off the main thread (a network share can be slow)
                let head = stream == nil ? await Blocking.run { VLCSafety.head(of: url) } : nil
                guard !Task.isCancelled else { return }
                let source: VLCPlaybackControl.Source = stream.map { stream in .stream(url, { ArchiveInputStream(stream) }) } ?? .file(url, head: head)
                // Subtitles off: no reading of the tracks before the first picture
                let control = VLCPlaybackControl(source: source, subtitles: model.showSubtitles, resume: place,
                                                 onStateChange: report)
                control.onAutoLook = reportLook
                control.onTracksChanged = reportTracks
                vlcControl = control
                model.activePlayer = control
                model.activePlayerURL = url
                await noteFile(url)
                // VLC knows the size once the video plays: an AVI inside an
                // archive on a share may take long to open (asked: VLCKit
                // reports no size)
                var waited = 0.0
                while !Task.isCancelled {
                    if let size = control.videoSize { videoSize = size; break }
                    let step = waited < 5 ? 0.1 : 0.5
                    try? await Task.sleep(for: .seconds(step))
                    waited += step
                }
            }
            if playable && !Self.forceVLC && !Self.playsInVLC(url) {
                let control = AVPlaybackControl(player: AVPlayer(playerItem: AVPlayerItem(asset: asset)), onStateChange: report)
                control.resourceLoader = loader   // the asset holds its delegate weakly
                control.onAutoLook = reportLook
                control.onTracksChanged = reportTracks
                avControl = control
                model.activePlayer = control
                model.activePlayerURL = url
                control.begin(at: resume)
                control.loadTracks()
                await noteFile(url)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await track.load(.naturalSize, .preferredTransform),
                   !Task.isCancelled {   // still this video
                    let turned = size.applying(transform)
                    videoSize = CGSize(width: abs(turned.width), height: abs(turned.height))
                }
                // AVFoundation gives up on it (a download cut off, data it
                // can't read or decode): VLC goes on from where it stood.
                // Asked every half second: AVFoundation reports a failure
                // once, and one around the app's own change is looked at again
                guard let item = control.player.currentItem, stream == nil else { return }
                let failed = ManagedFlag()
                let failure = Locked<NSError?>(nil)   // the error a notification brought
                let token = NotificationToken(AVPlayerItem.failedToPlayToEndTimeNotification, object: item) { note in
                    failure.set(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
                    failed.set()
                }
                while !Task.isCancelled, avControl === control {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, avControl === control, item.status == .failed || failed.isSet else { continue }
                    // Around the app's own changes (enhance on or off, a
                    // redraw, a seek) AVFoundation may report a failure for
                    // a moment: looked at again once that has settled
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, avControl === control else { break }
                    let stopped = item.status == .failed || (failed.isSet && control.player.timeControlStatus != .playing)
                    let error = (item.status == .failed ? item.error as NSError? : nil) ?? failure.value
                    let reason = Self.describeFailure(item.status == .failed, error)
                    guard stopped, !control.changedLately,
                          DownloadName.isPartial(url.lastPathComponent) || AVPlaybackControl.isDataFailure(error) else {
                        BrowserModel.testLog("video: AVKit reported a failure, AVKit plays on | \(url.lastPathComponent) | \(reason)")
                        failed.reset()
                        continue
                    }
                    let seconds = CMTimeGetSeconds(control.player.currentTime())
                    takenOver = reason + " at \(seconds)"
                    BrowserModel.testLog("video: AVKit failed, VLC takes over | \(url.lastPathComponent) | \(takenOver)")
                    control.pause()
                    avControl = nil
                    await playInVLC(from: seconds.isFinite && seconds > 0 ? PlaybackPositions.Place(seconds: seconds, playing: true) : nil)
                    break
                }
                _ = token
            } else {
                // AVFoundation can't play it: VLCKit plays it. It starts
                // playing once its view gives it somewhere to draw.
                await playInVLC(from: resume)
            }
        }
        // A download still growing: once more data has arrived, a video that
        // stopped where the data ended (or couldn't start) opens again, on
        // from where it stood
        .task(id: url) {
            guard DownloadName.isPartial(url.lastPathComponent), !ArchivePath.isInside(url) else { return }
            var size = await Blocking.run(.utility) { Self.fileSize(url) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let now = await Blocking.run(.utility) { Self.fileSize(url) }
                guard !Task.isCancelled, now != size, now != nil else { continue }
                size = now
                let player = model.activePlayer
                let stopped = player.map { !$0.isPlaying && ($0.progress ?? 1) >= 0.97 } ?? false
                guard unplayable != nil || stopped else { continue }
                if let player, let length = player.lengthSeconds, let progress = player.progress {
                    resumeAt = length * progress
                }
                BrowserModel.testLog("video: grew, opened again | \(url.lastPathComponent)")
                opening += 1
            }
        }
        .onDisappear { stop() }
    }

    /// What AVFoundation reported, for the test log and the UI tests' label.
    private static func describeFailure(_ itemFailed: Bool, _ error: NSError?) -> String {
        let underlying = (error?.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? ""
        return (itemFailed ? "item failed" : "failed to play to end")
            + (error.map { ": \($0.domain) \($0.code) \($0.localizedDescription)\(underlying)" } ?? ", no error")
    }

    /// What `.task` is run again for: another file, or the same opened again.
    private struct Opening: Hashable {
        let url: URL
        let count: Int
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int64(info.st_size) : nil
    }

    /// A file of someone else: a reference movie names other files or
    /// addresses to play, so it plays nothing here. A name that doesn't say
    /// the format ("x.mp4.part", "x.xyz" holding an MP4) gets the type the
    /// final name or the content says: AVFoundation goes by the name.
    static func assetOptions(for url: URL) -> [String: Any] {
        var options: [String: Any] = [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue]
        let shown = BrowserModel.shownExtension(of: url)
        if shown != url.pathExtension.lowercased(), let mime = UTType(filenameExtension: shown)?.preferredMIMEType {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }
        return options
    }

    /// UI tests (`--ui-testing --force-vlc`) play every video through VLC, so
    /// the same test videos check both players.
    static let forceVLC = TestSwitches.has("--force-vlc")

    /// For UI tests: the tracks and which are on as the player has them,
    /// the speed ("audio 2/2 de, subtitles 1/2 en, speed 1.25").
    static func describe(_ tracks: VideoTracks, speed: Double) -> String {
        func place(_ id: Int?, _ list: [MediaTrack]) -> String {
            guard let id, let index = list.firstIndex(where: { $0.id == id }) else { return "off/\(list.count)" }
            return "\(index + 1)/\(list.count) \(list[index].language ?? "-")"
        }
        return "audio \(place(tracks.audioID, tracks.audio)), subtitles \(place(tracks.subtitleID, tracks.subtitles)), speed \(speed)"
    }

    /// Formats macOS reads only through a media extension: VLC plays them,
    /// with their sound. AVFoundation would call them playable through
    /// Schnellbild's own (picture only, for thumbnails) or another app's
    /// extension, once one is turned on. A transport stream (".ts", a TV
    /// recording) plays through VLC too, which reads every such stream.
    static let vlcFormats: Set<String> = ["mkv", "webm", "wmv", "asf", "flv", "ogv", "vob", "ts"]
    static func playsInVLC(_ url: URL) -> Bool { vlcFormats.contains(BrowserModel.shownExtension(of: url)) }

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
        // Remembered before the player stops (and reads as paused)
        if let url = playing?.url, let list = positionList, let player = (avControl as PlaybackControl?) ?? vlcControl {
            model.videoLeft(url, player: player, list: list)
        }
        positionList = nil
        playing = nil
        unplayable = nil
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

/// AVKit's picture: an `AVPlayerLayer` in a plain view, which draws the
/// video, HDR as EDR on displays that have it (as AVKit's own views do), and
/// the subtitles chosen. The app's control bar (`VideoControlBar`) is the
/// same for AVKit and VLC, stays where the user put it from video to video
/// and stays upright on a turned video. (`AVPlayerView` keeps drawing
/// subtitles switched off on macOS 15, seen on CI; its inline and minimal
/// controls dim the whole picture while they show, from macOS 26 on.)
struct AVPlayerLayerHost: NSViewRepresentable {
    let control: AVPlaybackControl

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = control.player
        control.layerView = view
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== control.player { view.playerLayer.player = control.player }
        control.layerView = view
    }

    final class PlayerLayerView: NSView {
        private(set) var playerLayer = PlayerLayerView.makeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = playerLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("not from a coder") }

        private static func makeLayer() -> AVPlayerLayer {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.black.cgColor
            return layer
        }

        /// The player in a layer of its own anew: one drawn without the
        /// subtitles a layer may keep on screen (`AVPlaybackControl.clearSubtitleLine`).
        func renewLayer() {
            let player = playerLayer.player
            let fresh = Self.makeLayer()
            fresh.player = player
            playerLayer.player = nil
            playerLayer = fresh
            layer = fresh
        }
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
        let once = ManagedFlag()
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
