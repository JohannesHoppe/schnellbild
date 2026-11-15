import SwiftUI
import AppKit
import VLCKit
import VLCFrames
import CoreImage

/// Where players stop and are let go: a few at a time on a queue of their
/// own. Each may wait long on a share that stalls; on the system's threads,
/// paging through many videos would hold one thread per video and starve
/// the rest of the app (`Blocking`).
enum VLCStops {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Schnellbild VLC stops"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// A player handed to the queue (only that one thread uses it from then on).
    final class Held: @unchecked Sendable {
        let player: VLCMediaPlayer
        init(_ player: VLCMediaPlayer) { self.player = player }
    }

    static func run(_ work: @escaping @Sendable () -> Void) { queue.addOperation(work) }

    /// The player's last reference given up on the queue (VLC's wait for
    /// its threads happens there): once its control has let go of it too.
    static func release(_ held: Held) {
        let handed = Unmanaged.passRetained(held)
        queue.addOperation {
            var held = handed.takeRetainedValue()
            // (the control's own reference goes right after its deinit)
            for _ in 0..<200 where !isKnownUniquelyReferenced(&held) { usleep(10_000) }
            withExtendedLifetime(held) {}
        }
    }
}

/// UI tests: VLC's messages with the time since the system started (ms),
/// into VLC's own log file, and those about pictures, buffering and
/// subtitles also into the app's test log (`--test-log`), on the clock of
/// the app's own lines there (`BrowserModel.testClock`).
final class VLCTestLogger: NSObject, VLCLogging, @unchecked Sendable {
    var level: VLCLogLevel = .debug
    private let handle: FileHandle
    private let lock = NSLock()
    init(_ handle: FileHandle) { self.handle = handle }

    private static let mirrored = ["first picture", "uffering", "text renderer", "subpicture", "no vout",
                                   "Decoder wait", "starting at time", "seek", "spu decoder", "vout display", "es out"]

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let module = context?.module ?? "-"
        let line = "\(BrowserModel.testClock) [\(logLevel.rawValue)] \(module): \(message)\n"
        lock.lock()
        handle.write(Data(line.utf8))
        lock.unlock()
        if Self.mirrored.contains(where: { message.contains($0) }) {
            BrowserModel.testLog("vlc log: \(module): \(message) | \(BrowserModel.testClock) ms")
        }
    }
}

/// VLCKit (LibVLC) playback for formats AVFoundation can't handle (AVI, MKV,
/// WebM …). Used only as a fallback; native formats stay on AVKit. Reports
/// state changes from any source (keys, the end of the video) to the model.
@MainActor
final class VLCPlaybackControl: NSObject, PlaybackControl, VLCMediaPlayerDelegate, VLCMediaDelegate {
    /// The player, in the box the control hands to `VLCStops` as it goes.
    private let held: VLCStops.Held = {
        _ = VLCPlaybackControl.testLog
        return VLCStops.Held(VLCMediaPlayer())
    }()
    var player: VLCMediaPlayer { held.player }

    /// UI tests: VLC logs everything to /tmp/schnellbild-vlc.log, which the
    /// CI workflow shows when a test fails.
    private static let testLog: Void = {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        let path = "/tmp/schnellbild-vlc.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        let logger = VLCTestLogger(handle)
        logger.level = .debug
        VLCLibrary.shared().loggers = [logger]
    }()
    /// Where the picture goes (no OpenGL; see `VLCFrameOutput`).
    let output = VLCFrameOutput()
    /// What VLC opens: a file, or a stream (a video inside an archive, named
    /// by its path through the archive; a new stream for every opening).
    enum Source {
        /// A file and its first bytes (which reader VLC may use, `VLCSafety`)
        case file(URL, head: Data?)
        case stream(URL, () -> InputStream)
    }
    private let source: Source
    private let onStateChange: @MainActor (PlaybackControl, Bool) -> Void
    private weak var drawable: NSView?

    /// Playing from `play()` until a pause or the end. VLC reports "playing"
    /// only once the media has opened, which would make an early Space press
    /// start it instead of pausing it.
    private(set) var isPlaying = true

    /// Where auto enhance's look goes (the model, for the sliders).
    var onAutoLook: @MainActor (PlaybackControl, Look) -> Void = { _, _ in }

    /// `subtitles`: whether subtitles are on (the model's `showSubtitles`):
    /// off, the video starts at once, its tracks are not read first.
    init(source: Source, subtitles: Bool = true, onStateChange: @escaping @MainActor (PlaybackControl, Bool) -> Void) {
        self.source = source
        self.onStateChange = onStateChange
        super.init()
        let media = makeMedia()
        player.media = media
        player.delegate = self
        output.attach(to: player)
        BrowserModel.testLog("vlc: opening | \(BrowserModel.testClock) ms")
        if subtitles { readTracksFirst(media) }
    }

    // MARK: Tracks before the first picture

    /// The media's tracks read before it plays (a file only: a stream from
    /// an archive can be read once per opening).
    private var parsing = false
    /// Play once the tracks are known (the view is there).
    private var playWhenParsed = false
    /// `play()` was called on the player: its own track lists hold from then on.
    private var started = false

    /// How long the first picture waits for the tracks: a file that takes
    /// longer to read (a slow share) starts in hardware, and subtitles
    /// chosen then open it again in software where it stands
    /// (`decodeInSoftware`).
    static let parseWait: Duration = .milliseconds(300)
    /// UI tests (`--vlc-parse-delay=<ms>`): the tracks arrive that much
    /// later, as from a slow share.
    static let parseDelay: Duration? = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing"), let arg = args.first(where: { $0.hasPrefix("--vlc-parse-delay=") }),
              let ms = Int(arg.dropFirst("--vlc-parse-delay=".count)) else { return nil }
        return .milliseconds(ms)
    }()
    /// When the reading began (test log).
    private var parseBegan = Date()

    /// Reads the file's tracks before it plays (libVLC's preparser: the
    /// same input with the media's options, so the same single demuxer
    /// (`VLCSafety`), local only, no art fetched), so subtitles that are to
    /// show make VLC decode in software from the first picture on, with the
    /// track chosen (`tracksKnown`); at most `parseWait`.
    private func readTracksFirst(_ media: VLCMedia) {
        guard case .file = source else { return }
        media.delegate = self
        parseBegan = Date()
        parsing = media.parse(options: VLCMediaParsingOptions(rawValue: 0), timeout: 5000) == 0
        guard parsing else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.parseWait)
            self?.parseTookTooLong()
        }
    }

    /// The tracks didn't come within `parseWait`: play in hardware (what
    /// the parse brings later is left alone; VLC reports the tracks once it
    /// plays).
    private func parseTookTooLong() {
        guard parsing else { return }
        parsing = false
        BrowserModel.testLog("vlc: tracks not read within \(Self.parseWait), playing")
        if playWhenParsed { startPlaying() }
    }

    nonisolated func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        Task { @MainActor in
            if let delay = Self.parseDelay { try? await Task.sleep(for: delay) }
            self.tracksKnown()
        }
    }

    /// The tracks go to the model, which chooses (`selectSubtitleTrack`);
    /// with subtitles chosen, the media gets software decoding and the
    /// track before it plays.
    private func tracksKnown() {
        guard parsing, let media = player.media else { return }
        parsing = false
        guard player.delegate != nil else { return }   // stopped meanwhile
        BrowserModel.testLog("vlc: tracks read before playing (parse status \(media.parsedStatus.rawValue)), "
            + "\(tracks.subtitles.count) subtitle tracks, in \(Int(Date().timeIntervalSince(parseBegan) * 1000)) ms "
            + "| \(BrowserModel.testClock) ms")
        onTracksChanged(self)
        // The model chooses only what differs from the tracks reported, which
        // name none on before playing: no choice is subtitles off (else VLC
        // would turn on the file's default track)
        if wantedSubtitle == nil, !tracks.subtitles.isEmpty { wantedSubtitle = .some(nil) }
        if case .some(.some(let id)) = wantedSubtitle, tracks.subtitles.contains(where: { $0.id == id }) {
            softwareDecoding = true
            subtitleOnceOpen = id
            media.addOption(":codec=avcodec,all")
            media.addOption(":sub-track-id=\(id)")
            openedInSoftware = true
            BrowserModel.testLog("vlc: software decoding for subtitles from the start, subtitles \(id)")
        }
        if playWhenParsed { startPlaying() }
    }

    private func startPlaying() {
        playWhenParsed = false
        started = true
        BrowserModel.testLog("vlc: play | \(BrowserModel.testClock) ms")
        player.play()
    }

    private func makeMedia(subtitles: Int? = nil) -> VLCMedia {
        let media: VLCMedia
        let name: URL
        var head: Data?
        switch source {
        case .file(let url, let first):     media = VLCMedia(url: url); name = url; head = first
        case .stream(let url, let makeStream): media = VLCMedia(stream: makeStream()); name = url
        }
        VLCSafety.restrict(media, for: name, head: head)
        // No on-screen messages (VLC would draw them into the picture)
        media.addOption(":no-osd")
        // VLCKit turns on "play-and-pause": VLC would pause as soon as it has
        // read the file to its end, before the last pictures are shown, and
        // never report the end (the slideshow waits for it)
        media.addOption(":no-play-and-pause")
        // Subtitles to show: decoded by FFmpeg, not VideoToolbox. VLC draws
        // subtitles into the decoded picture before it converts it for the
        // video callbacks, and can't draw into VideoToolbox's pictures
        // ("blending YUVA to CVPN failed", seen on CI): nothing would show.
        // (FFmpeg takes only the subtitle formats it is trusted with; text
        // ones fall through to VLC's own decoders.)
        if softwareDecoding { media.addOption(":codec=avcodec,all") }
        // The subtitles chosen, from the start: chosen once VLC has opened
        // the file, a line that began at its start would be read already
        // (into the file's default track) and show only from the next one
        if softwareDecoding, let track = subtitles ?? subtitleToOpen {
            media.addOption(":sub-track-id=\(track)")
            BrowserModel.testLog("vlc: media opened with subtitles \(track)")
        }
        return media
    }

    private var adaptive = AdaptiveLook()
    private var measureTask: Task<Void, Never>?
    /// The next measurement takes its value at once (after a seek).
    private var measureNow = true

    /// The look is applied by `VLCFrameOutput`, as Core Image does for
    /// AVKit. For auto enhance the decoded picture is measured once a
    /// second, gliding in between.
    func setEnhancement(_ enhancement: Enhancement) {
        measureTask?.cancel()
        measureTask = nil
        switch enhancement {
        case .off:
            output.setLook(.neutral)
        case .manual(let look):
            output.setLook(look)
        case .auto:
            output.setLook(adaptive.look)
            measureNow = true
            measureTask = Task { [weak self] in
                var sinceMeasure = Double.infinity
                var sinceReport = Double.infinity
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.measureNow || sinceMeasure >= 1 || !self.adaptive.hasPicture {
                        if let stats = await self.pictureStats(), !Task.isCancelled {
                            self.adaptive.measure(stats, instant: self.measureNow)
                            self.measureNow = false
                        }
                        sinceMeasure = 0
                    } else {
                        self.adaptive.advance(by: 0.2)
                    }
                    guard !Task.isCancelled else { return }
                    self.output.setLook(self.adaptive.look)
                    if sinceReport >= 0.25 {
                        self.onAutoLook(self, self.adaptive.look)
                        sinceReport = 0
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    sinceMeasure += 0.2
                    sinceReport += 0.2
                }
            }
        }
    }

    /// The decoded picture on screen, measured (also paused or at the end).
    private func pictureStats() async -> PictureStats? {
        let output = self.output
        return await Task.detached(priority: .utility) { output.latestStats }.value
    }

    /// For UI tests: VLC's state, the pictures it showed and lost, and what
    /// handing them over costs.
    func diagnostics() -> String {
        let stats = player.media?.statistics
        let size = videoSize ?? .zero
        return "vlc state \(player.state.rawValue), decoding \(openedInSoftware ? "software" : "hardware"), "
            + "time \(player.time.intValue), size \(Int(size.width))x\(Int(size.height)), shown \(stats?.displayedPictures ?? 0), lost \(stats?.lostPictures ?? 0), \(output.diagnostics)"
    }

    /// Show the picture in `view`; the first view starts playback.
    func attach(to view: NSView) {
        guard drawable !== view else { return }
        let first = drawable == nil
        drawable = view
        output.layer.frame = view.bounds
        output.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // A view reused for the next video holds only that one's picture
        view.layer?.sublayers?.filter { $0 !== output.layer }.forEach { $0.removeFromSuperlayer() }
        view.layer?.addSublayer(output.layer)
        if first {
            if parsing { playWhenParsed = true } else { startPlaying() }
        }
    }

    /// The picture's size as shown (non-square pixels made square), once
    /// VLC has opened its output.
    var videoSize: CGSize? {
        if let shown = output.pictureSize { return shown }
        let size = player.videoSize
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// Playing, its clock running, with no length (VLC knows none for a
    /// WebM a browser recorded).
    var playsWithoutLength: Bool {
        player.state == .playing && (player.media?.length.intValue ?? 0) <= 0 && player.time.intValue > 0
    }

    /// Ended or stopped: playing opens the video again.
    private var atEnd: Bool { player.state == .ended || player.state == .stopped }

    /// At the end, playing starts over.
    func play() {
        BrowserModel.testLog("vlc play, state \(player.state.rawValue), position \(player.position)")
        isPlaying = true
        if parsing { playWhenParsed = true; return }
        // Not played yet: the media as prepared (its tracks chosen)
        if !started { startPlaying(); return }
        if atEnd {
            player.media = makeMedia()
            if let media = player.media { output.use(media) }
        }
        started = true
        player.play()
    }

    func pause() {
        isPlaying = false
        if parsing { playWhenParsed = false; return }
        player.pause()
    }

    /// Stopping waits for VLC's reading thread; with a read stalled on a
    /// network share that takes until it times out, so it waits off the
    /// main thread (the block keeps the player until then).
    func stop() {
        measureTask?.cancel()
        measureTask = nil
        handoverTask?.cancel()
        player.delegate = nil
        // Nothing else touches it once stopping: the control is going away.
        // (The picture output lives as long as the player: `VLCFrameOutput.attach`.)
        let player = held
        VLCStops.run {
            player.player.stop()
            for _ in 0..<100 where player.player.state != .stopped { usleep(50_000) }
            BrowserModel.testLog("vlc stopped")
        }
    }

    /// VLCKit waits for its reading thread only when the player goes (the
    /// last release): handed to `VLCStops`, so that wait, on a read stalled
    /// on a network share, happens there and never on the main thread.
    deinit { VLCStops.release(held) }

    /// The last seek target: VLC reports the new position only once it has
    /// got there, so quick key presses would otherwise start from the old one.
    private var pendingSeek: (target: Double, at: Date)?

    /// The app's volume, set again once VLC has its audio output (it
    /// opens with the media).
    private var volume = 1.0
    func setVolume(_ volume: Double) {
        self.volume = volume
        player.audio?.volume = Int32((volume * 100).rounded())
    }
    /// VLC's own (without a sound output yet: none).
    var playerVolume: Double? {
        guard let audio = player.audio, audio.volume >= 0 else { return nil }
        return Double(audio.volume) / 100
    }
    var playerSpeed: Double? { Double(player.rate) }

    // MARK: Tracks and speed

    /// Where the tracks go once VLC knows them (the model).
    var onTracksChanged: @MainActor (PlaybackControl) -> Void = { _ in }
    /// The tracks chosen, set again whenever VLC opens the media anew (from
    /// the end) or finds its tracks; `.some(nil)`: no subtitles.
    private var wantedSubtitle: Int??
    private var wantedAudio: Int?
    private var speed = 1.0

    /// Decoding in software, so subtitles can be drawn (`makeMedia`).
    private var softwareDecoding = false
    /// Paused before the media was opened anew for software decoding.
    private var pauseOnceOpen = false
    /// The subtitle track VLC opens the media with in software (`makeMedia`).
    private var subtitleOnceOpen: Int?
    /// The subtitle track a media opened anew starts with: the one chosen
    /// last (none when switched off), else the one it was opened with.
    private var subtitleToOpen: Int? {
        switch wantedSubtitle {
        case .some(let chosen): return chosen
        case .none:             return subtitleOnceOpen
        }
    }
    /// The media in the player is one opened for software decoding.
    private var openedInSoftware = false

    /// Opens the media again, decoded in software, where the picture stands
    /// (once per video, when subtitles are to be shown while it plays in
    /// hardware: hardware decoding is faster). The time is taken right as
    /// the player stops: VLCKit's `stop` hands the closing of the input to
    /// libVLC's own thread (`libvlc_media_player_stop_async`), so nothing
    /// waits here and the picture doesn't go on meanwhile. The new media
    /// starts at that time (`:start-time`, a seek before its first picture)
    /// without a subtitle track: the line running there comes from the app
    /// (`beginHandover`) and VLC's own from the next line on.
    private func decodeInSoftware() {
        guard !softwareDecoding else { return }
        softwareDecoding = true
        let wasPlaying = isPlaying
        let current = Int(player.currentVideoSubTitleIndex)
        if let wanted = wantedSubtitle { subtitleOnceOpen = wanted } else { subtitleOnceOpen = current >= 0 ? current : nil }
        let ended = reachedEnd || player.position >= 0.999
        let time = ended ? 0 : max(timeNow, 0)
        let track = subtitleToOpen
        let index = track.flatMap(subtitleIndex(of:))
        player.stop()
        BrowserModel.testLog("vlc: software decoding for subtitles, stopped at \(time) ms (VLC's last report \(player.time.intValue) ms) "
            + "| \(BrowserModel.testClock) ms")
        Task { @MainActor [weak self] in
            for _ in 0..<100 {
                guard let self, self.player.delegate != nil else { return }   // stopped for good meanwhile
                if self.player.state == .stopped { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self, self.player.delegate != nil else { return }
            BrowserModel.testLog("vlc: last picture before opening again: \(self.output.lastProbe)")
            // From the start VLC reads every line itself; else the app hands over
            let handingOver = time > 0 && track != nil && index != nil
            let media = self.makeMedia(subtitles: handingOver ? Self.noSubtitles : track)
            if time > 0 { media.addOption(":start-time=\(String(format: "%.3f", Double(time) / 1000))") }
            self.player.media = media
            self.output.use(media)
            self.openedInSoftware = true
            self.pauseOnceOpen = !wasPlaying
            if handingOver, let track, let index { self.beginHandover(track: track, index: index, at: Double(time) / 1000) }
            self.player.play()
            BrowserModel.testLog("vlc: opened again in software at \(time) ms, subtitles \(String(describing: track))")
            self.isPlaying = wasPlaying
        }
    }

    /// A subtitle track id no file has: VLC opens the media with none on
    /// (the file's default track would be chosen otherwise), and its first
    /// picture still waits for the buffering (Scripts/vlc-patches/0002).
    static let noSubtitles = 999_999

    // MARK: The running line

    /// From where a subtitle track was switched on in the middle of a video
    /// up to the line VLC reads itself, the app draws the lines
    /// (`SubtitleOverlay`): VLC reads a track chosen while it plays only from
    /// blocks it reads after that, and a seek doesn't go back to where the
    /// running line's block lies. VLC takes the track `readAhead` before the
    /// first line (`firstOfVLC`) that begins more than `readAhead` after the
    /// one before it (or after the time switched at): VLC has then read no
    /// line's block between, so the lines before it are the app's and from
    /// it on VLC's, none twice, none missing.
    private struct Handover {
        var track: Int
        var lines: SubtitleTrackLines
        var firstOfVLC: Double
        var selectAt: Double
        var selected = false
        /// The texts drawn now (redrawn only when they change).
        var shown: [String] = []
    }
    private var handover: Handover?
    private var handoverTask: Task<Void, Never>?
    /// How far VLC reads ahead of the picture at most (its decoders' queues).
    nonisolated static let readAhead = 1.5
    /// How far ahead the lines are read (the app draws up to the first gap).
    nonisolated static let linesAhead = 60.0

    /// The track to show from `time` (seconds): its lines are read off the
    /// main thread; if they can't be (a stream, another format, a damaged
    /// file), VLC takes the track at once, the running line left out.
    private func beginHandover(track: Int, index: Int, at time: Double) {
        endHandover()
        guard case .file(let url, _) = source else {
            player.currentVideoSubTitleIndex = Int32(track)
            return
        }
        // Until the lines are read VLC doesn't take the track (`applyChoices`)
        handover = Handover(track: track, lines: SubtitleTrackLines(kind: .text, lines: []),
                            firstOfVLC: .greatestFiniteMagnitude, selectAt: .greatestFiniteMagnitude)
        handoverTask = Task { @MainActor [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                SubtitleReader.lines(of: url, subtitleIndex: index, from: time, to: time + Self.linesAhead)
            }.value
            guard let self, !Task.isCancelled, self.player.delegate != nil else { return }
            guard let read else {
                BrowserModel.testLog("vlc: lines of subtitles \(track) not read, VLC from its next line")
                self.player.currentVideoSubTitleIndex = Int32(track)
                return
            }
            var previous = time
            var firstOfVLC = read.lines.last.map { $0.start + Self.readAhead * 2 } ?? time
            for line in read.lines where line.start > time {
                if line.start - previous > Self.readAhead { firstOfVLC = line.start; break }
                previous = line.start
            }
            let selectAt = max(time, firstOfVLC - Self.readAhead)
            self.handover = Handover(track: track, lines: read, firstOfVLC: firstOfVLC, selectAt: selectAt)
            let ours = read.lines.filter { $0.start < firstOfVLC }
            BrowserModel.testLog("vlc: handing over subtitles \(track) at \(String(format: "%.3f", time)) s: \(ours.count) lines drawn by the app, "
                + "VLC's from \(String(format: "%.3f", firstOfVLC)) s, chosen at \(String(format: "%.3f", selectAt)) s | \(BrowserModel.testClock) ms")
            self.output.logPictures(5)
            while !Task.isCancelled, self.handover != nil, self.player.delegate != nil {
                self.followHandover()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// Draws the lines of the time shown, chooses the track in VLC at
    /// `selectAt`, and ends once the app's lines are over.
    private func followHandover() {
        guard var handover else { return }
        let now = Double(timeNow) / 1000
        if !handover.selected, now >= handover.selectAt {
            handover.selected = true
            player.currentVideoSubTitleIndex = Int32(handover.track)
            BrowserModel.testLog("vlc: subtitles \(handover.track) to VLC at \(String(format: "%.3f", now)) s | \(BrowserModel.testClock) ms")
        }
        let running = handover.lines.lines.filter { $0.start < handover.firstOfVLC && $0.start <= now && now < $0.end }
        let texts = running.flatMap(\.text)
        if texts != handover.shown {
            handover.shown = texts
            if let size = output.bufferSize, !texts.isEmpty {
                output.setOverlay(SubtitleOverlay.image(texts, kind: handover.lines.kind, style: running.last?.style,
                                                        width: size.width, height: size.height, decoded: output.proposedSize))
            } else {
                output.setOverlay(nil)
            }
            BrowserModel.testLog("vlc: the app draws \(texts) at \(String(format: "%.3f", now)) s | \(BrowserModel.testClock) ms")
            output.logPictures(texts.isEmpty ? 40 : 3)
        }
        let ours = handover.lines.lines.filter { $0.start < handover.firstOfVLC }
        if handover.selected, now >= (ours.map(\.end).max() ?? 0) {
            self.handover = nil
            output.setOverlay(nil)
            BrowserModel.testLog("vlc: the app's lines are over at \(String(format: "%.3f", now)) s | \(BrowserModel.testClock) ms")
            return
        }
        self.handover = handover
    }

    /// Where a track lies among the video's subtitle tracks (the file's
    /// order, as VLC lists them).
    private func subtitleIndex(of track: Int) -> Int? {
        tracks.subtitles.firstIndex { $0.id == track }
    }

    /// Stops drawing (a seek, another track, subtitles off, the end); the
    /// track the handover was for goes to VLC unless another was chosen.
    private func endHandover(selecting: Bool = false) {
        handoverTask?.cancel()
        handoverTask = nil
        if selecting, let handover, !handover.selected { player.currentVideoSubTitleIndex = Int32(handover.track) }
        if handover != nil { output.setOverlay(nil) }
        handover = nil
    }

    var tracks: VideoTracks {
        let info = player.media?.tracksInformation as? [[String: Any]] ?? []
        func list(_ ids: [Any]?, _ type: String) -> [MediaTrack] {
            let ids = (ids as? [NSNumber])?.map(\.intValue).filter { $0 >= 0 } ?? []
            return ids.enumerated().map { number, id in
                let facts = info.first {
                    ($0[VLCMediaTracksInformationId] as? NSNumber)?.intValue == id && $0[VLCMediaTracksInformationType] as? String == type
                }
                let language = facts?[VLCMediaTracksInformationLanguage] as? String
                let title = facts?[VLCMediaTracksInformationDescription] as? String
                return MediaTrack(id: id, name: MediaTrack.name(title: title, language: language, number: number + 1), language: language)
            }
        }
        var tracks = VideoTracks()
        guard started else {
            // Read before playing: the media's own list, the tracks it opens with chosen
            func ids(_ type: String) -> [Any] {
                info.filter { $0[VLCMediaTracksInformationType] as? String == type }.compactMap { $0[VLCMediaTracksInformationId] }
            }
            tracks.audio = list(ids(VLCMediaTracksInformationTypeAudio), VLCMediaTracksInformationTypeAudio)
            tracks.subtitles = list(ids(VLCMediaTracksInformationTypeText), VLCMediaTracksInformationTypeText)
            tracks.subtitleID = softwareDecoding ? subtitleOnceOpen : nil
            return tracks
        }
        tracks.audio = list(player.audioTrackIndexes, VLCMediaTracksInformationTypeAudio)
        tracks.subtitles = list(player.videoSubTitlesIndexes, VLCMediaTracksInformationTypeText)
        let audio = Int(player.currentAudioTrackIndex)
        tracks.audioID = audio >= 0 ? audio : nil
        let subtitle = Int(player.currentVideoSubTitleIndex)
        tracks.subtitleID = subtitle >= 0 ? subtitle : nil
        return tracks
    }

    /// Switched to another track while it plays in software: the app draws
    /// the new track's running line (`beginHandover`).
    func selectSubtitleTrack(_ id: Int?) {
        wantedSubtitle = .some(id)
        let time = Double(timeNow) / 1000
        if let id, softwareDecoding, started, time > 0.2, Int(player.currentVideoSubTitleIndex) != id,
           (player.videoSubTitlesIndexes as? [NSNumber])?.contains(where: { $0.intValue == id }) == true {
            if let index = subtitleIndex(of: id) {
                player.currentVideoSubTitleIndex = -1
                beginHandover(track: id, index: index, at: time)
                return
            }
        }
        endHandover()
        applyChoices()
    }

    func selectAudioTrack(_ id: Int) {
        wantedAudio = id
        applyChoices()
    }

    /// VLC keeps the pitch at other speeds itself.
    func setSpeed(_ speed: Double) {
        self.speed = speed
        player.rate = Float(speed)
    }

    /// The choices made, applied to the tracks VLC has (it opens a media
    /// with the file's default ones).
    private func applyChoices() {
        // The app draws the line VLC can't yet: VLC takes the track later
        if let wanted = wantedSubtitle, handover == nil || handover?.selected == true || handover?.track != wanted {
            let ids = (player.videoSubTitlesIndexes as? [NSNumber])?.map(\.intValue) ?? []
            let target = wanted ?? -1
            if Int(player.currentVideoSubTitleIndex) != target, target == -1 || ids.contains(target) {
                player.currentVideoSubTitleIndex = Int32(target)
            }
        }
        // Subtitles to show: the track chosen, or before any choice the one
        // VLC opened with. Switched off, the file's default track VLC turns
        // on as it finds it (before it takes the -1) is no reason to decode
        // in software (seen on CI: `ramp.mkv` with subtitles off)
        let shows = wantedSubtitle.map { $0 != nil } ?? true
        if shows, Int(player.currentVideoSubTitleIndex) >= 0, !softwareDecoding {
            decodeInSoftware()
            return
        }
        if let wanted = wantedAudio, Int(player.currentAudioTrackIndex) != wanted,
           ((player.audioTrackIndexes as? [NSNumber])?.map(\.intValue) ?? []).contains(wanted) {
            player.currentAudioTrackIndex = Int32(wanted)
        }
        if speed != 1, abs(player.rate - Float(speed)) > 0.001 { player.rate = Float(speed) }
    }

    /// Played to its end: VLC goes on from "ended" to "stopped" quickly,
    /// and its position then is that of the last picture, short of 1.
    private var reachedEnd = false

    func streamFacts() async -> StreamFacts? {
        guard let media = player.media, player.state != .opening else { return nil }
        return StreamFacts.of(media)
    }

    var lengthSeconds: Double? {
        let ms = player.media?.length.intValue ?? 0
        return ms > 0 ? Double(ms) / 1000 : nil
    }

    var progress: Double? {
        if reachedEnd || player.state == .ended { return 1 }
        guard (player.media?.length.intValue ?? 0) > 0 else { return nil }
        let reported = Double(min(max(player.position, 0), 1))
        if let pending = pendingSeek {
            if abs(reported - pending.target) > 0.02, Date().timeIntervalSince(pending.at) < 1.5 {
                return pending.target
            }
            pendingSeek = nil
        }
        return reported
    }

    /// From the end the media is opened again; VLC ignores a position set
    /// before it plays, so it's applied once playback has started.
    private var positionOnceOpen: Float?

    func seek(toProgress progress: Double) {
        endHandover(selecting: true)
        let target = min(max(progress, 0), 1)
        reachedEnd = false
        pendingSeek = (target, Date())
        if atEnd {
            positionOnceOpen = Float(target)
            play()
        } else {
            player.position = Float(target)
        }
        measureNow = true   // a new scene: measure again at once
    }

    /// VLC's time as last reported and when it arrived.
    private var timeReported: (ms: Int, at: Date)?

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let at = Date()
        Task { @MainActor in self.timeReported = (Int(self.player.time.intValue), at) }
    }

    /// The time now: VLC reports it four times a second (its input's
    /// statistics), so while playing the time since its last report is
    /// added (at most a second, at the speed played).
    private var timeNow: Int { timeNow(playing: isPlaying) }

    private func timeNow(playing: Bool) -> Int {
        let ms = Int(player.time.intValue)
        guard player.state == .playing || player.state == .buffering, playing,
              let reported = timeReported, reported.ms == ms else { return ms }
        let since = min(max(Date().timeIntervalSince(reported.at), 0), 1)
        return ms + Int(since * 1000 * Double(player.rate))
    }

    /// A track found or the media playing: the menus list the tracks, the
    /// choices apply to them (the model's first: subtitles it turns off never
    /// make VLC decode in software), and the model learns the tracks as
    /// they are then on. With the tracks read before playing the model has
    /// chosen already and doesn't choose again for the same list: it takes
    /// what the player has on, which before `applyChoices` can still be the
    /// file's default track, so it is told again after them.
    private func tracksFound() {
        onTracksChanged(self)
        applyChoices()
        onTracksChanged(self)
    }

    /// The state is read while the notification is delivered: read later, a
    /// quick "ended" would already be "stopped" and the end missed. It is
    /// handled once VLCKit's callback has returned, since handling it can
    /// move on to the next item and stop this player.
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = (aNotification.object as? VLCMediaPlayer)?.state
        Task { @MainActor in self.stateChanged(to: state ?? self.player.state) }
    }

    private func stateChanged(to state: VLCMediaPlayerState) {
        BrowserModel.testLog("vlc state \(state.rawValue)")
        switch state {
        case .playing:
            reachedEnd = false
            isPlaying = true
            player.audio?.volume = Int32((volume * 100).rounded())
            if let position = positionOnceOpen {
                positionOnceOpen = nil
                player.position = position
            }
            if pauseOnceOpen {
                pauseOnceOpen = false
                player.pause()
            }
            tracksFound()
        case .ended:
            reachedEnd = true
            isPlaying = false
        case .paused, .error:   isPlaying = false
        case .esAdded:
            tracksFound()
            return
        default:                        return
        }
        onStateChange(self, isPlaying)
    }
}

/// The surface a `VLCPlaybackControl` draws into.
struct VLCVideoView: NSViewRepresentable {
    let control: VLCPlaybackControl

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        control.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        control.attach(to: nsView)   // a new control after switching files
    }
}

/// Thumbnails of videos QuickLook has only an icon for (Schnellbild's
/// QuickLook extension not registered yet, or a type it doesn't take): VLC decodes
/// a frame at 30 % of the video (`VLCFrameGrab`). At most two run at a
/// time, since each one opens and decodes the file.
@MainActor
final class VLCThumbnails {
    static let shared = VLCThumbnails()
    private static let limit = 2
    private var running = 0
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// A frame `width` pixels wide (the height follows the video), or nil.
    func thumbnail(for url: URL, width: CGFloat) async -> CGImage? {
        // A finishing call hands its place straight to the next waiting one,
        // so no new call can slip in between
        if running >= Self.limit {
            await withCheckedContinuation { queue.append($0) }
        } else {
            running += 1
        }
        defer {
            if queue.isEmpty { running -= 1 } else { queue.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return nil }
        return await VLCFrameGrab.frame(of: url, width: Int(width.rounded()))
    }
}
