import SwiftUI
import AppKit

/// Where the control bar sits over a video: its middle as a share of the
/// video area's width and height, the same for every video, pane and window,
/// remembered; nil: the bottom middle.
@MainActor
final class VideoBarPlacement: ObservableObject {
    static let shared = VideoBarPlacement()
    static let key = "videoBarCenter"
    /// Room kept between the bar and the edges of the video area.
    static let margin: CGFloat = 12
    static let bottomMargin: CGFloat = 16

    @Published private(set) var center: CGPoint?
    private var defaults: UserDefaults = .standard

    /// The app's preferences (the UI tests' own suite under `--ui-testing`),
    /// before the first video shows.
    func use(_ defaults: UserDefaults) {
        self.defaults = defaults
        if let pair = defaults.array(forKey: Self.key) as? [Double], pair.count == 2,
           pair.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            center = CGPoint(x: pair[0], y: pair[1])
        } else {
            center = nil
        }
    }

    func set(_ fraction: CGPoint) {
        let x = min(max(fraction.x, 0), 1), y = min(max(fraction.y, 0), 1)
        center = CGPoint(x: x, y: y)
        defaults.set([Double(x), Double(y)], forKey: Self.key)
    }

    func reset() {
        center = nil
        defaults.removeObject(forKey: Self.key)
    }

    /// The bar's middle in the area: at its share of the area, held inside
    /// it (a smaller window, a pane made narrower), so the whole bar shows.
    static func place(_ fraction: CGPoint?, bar: CGSize, in area: CGSize) -> CGPoint {
        let wanted = fraction.map { CGPoint(x: $0.x * area.width, y: $0.y * area.height) }
            ?? CGPoint(x: area.width / 2, y: area.height - bottomMargin - bar.height / 2)
        func hold(_ value: CGFloat, _ size: CGFloat, _ room: CGFloat) -> CGFloat {
            let low = size / 2 + margin, high = room - size / 2 - margin
            return low > high ? room / 2 : min(max(value, low), high)
        }
        return CGPoint(x: hold(wanted.x, bar.width, area.width), y: hold(wanted.y, bar.height, area.height))
    }

    /// A middle in the area as a share of it (what is remembered).
    static func fraction(of point: CGPoint, in area: CGSize) -> CGPoint {
        guard area.width > 0, area.height > 0 else { return CGPoint(x: 0.5, y: 0.9) }
        return CGPoint(x: point.x / area.width, y: point.y / area.height)
    }
}

/// Whether a menu is open (the bar stays while one of its menus is).
@MainActor
final class MenuTracking: ObservableObject {
    static let shared = MenuTracking()
    @Published private(set) var open = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuTracking.shared.open += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuTracking.shared.open = max(0, MenuTracking.shared.open - 1) }
        })
    }
}

/// What lies over a video in the full view and the slideshow: the control
/// bar, shown while the mouse moves over the video (as AVKit's own) and
/// upright and in its place however the video is zoomed or turned; the
/// note on speed and tracks; the context menu.
struct VideoChrome: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var placement = VideoBarPlacement.shared
    @ObservedObject private var menus = MenuTracking.shared
    @State private var visible = false
    @State private var overBar = false
    @State private var dragging = false
    @State private var hide: Task<Void, Never>?
    @State private var barSize = CGSize(width: 560, height: 44)
    /// The bar's middle while it is dragged.
    @State private var dragCenter: CGPoint?
    @State private var dragStart: CGPoint?

    /// How long the bar stays after the mouse stops.
    static let idle: Duration = .seconds(3)
    /// UI tests and the README screenshots (`--hold-video-bar`): once shown, it stays.
    static let holds = TestSwitches.has("--hold-video-bar")

    var body: some View {
        GeometryReader { geo in
            let area = geo.size
            ZStack {
                VideoMouseCatcher(onMove: activity, onExit: mouseLeft, menu: { VideoMenus.contextMenu(model) })
                if visible || NSWorkspace.shared.isVoiceOverEnabled {
                    VideoControlBar(areaWidth: area.width, dragging: $dragging,
                                    onDrag: { translation in drag(translation, area: area) },
                                    onDragEnd: { endDrag(area: area) })
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                        .onHover { inside in
                            overBar = inside
                            if !inside { scheduleHide() }
                        }
                        .position(dragCenter ?? VideoBarPlacement.place(placement.center, bar: barSize, in: area))
                        .transition(.opacity)
                }
                PlaybackNoticeView()
            }
            .coordinateSpace(name: "videoChrome")
            .animation(Motion.animation(.easeOut(duration: 0.2)), value: visible)
        }
        .onChange(of: menus.open) { _, open in if open == 0 { scheduleHide() } }
        .onDisappear { hide?.cancel() }
    }

    private func activity() {
        visible = true
        scheduleHide()
    }

    private func mouseLeft() {
        guard !overBar, !dragging, menus.open == 0, !Self.holds else { return }
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !overBar, !dragging, menus.open == 0 else { return }
            visible = false
        }
    }

    private func scheduleHide() {
        hide?.cancel()
        guard !Self.holds else { return }
        hide = Task { @MainActor in
            try? await Task.sleep(for: Self.idle)
            guard !Task.isCancelled else { return }
            // Stays while the mouse is on it, a menu is open or it is dragged
            if overBar || dragging || menus.open > 0 { scheduleHide(); return }
            visible = false
        }
    }

    private func drag(_ translation: CGSize, area: CGSize) {
        let start = dragStart ?? VideoBarPlacement.place(placement.center, bar: barSize, in: area)
        dragStart = start
        let moved = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
        dragCenter = VideoBarPlacement.place(VideoBarPlacement.fraction(of: moved, in: area), bar: barSize, in: area)
    }

    private func endDrag(area: CGSize) {
        if let dragCenter { placement.set(VideoBarPlacement.fraction(of: dragCenter, in: area)) }
        dragCenter = nil
        dragStart = nil
        scheduleHide()
    }
}

/// The control bar: play / pause, the position (drag it), the time played
/// and left, the volume, the speed, the subtitles and the audio track (when
/// the video has them), full screen. Dragged by its grip; a double click on
/// the grip puts it back at the bottom middle.
struct VideoControlBar: View {
    @EnvironmentObject var model: BrowserModel
    /// The keys the tooltips name (Settings → Keyboard).
    @ObservedObject private var shortcuts = Shortcuts.shared
    let areaWidth: CGFloat
    @Binding var dragging: Bool
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void
    /// The position while the slider is dragged.
    @State private var scrubbing: Double?

    private var width: CGFloat { max(min(areaWidth - 2 * VideoBarPlacement.margin, 620), 200) }

    var body: some View {
        HStack(spacing: 10) {
            grip
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.videoPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.videoPaused ? String(localized: "Play (\(playKeys))") : String(localized: "Pause (\(playKeys))"))
            .accessibilityLabel(model.videoPaused ? "Play" : "Pause")
            .accessibilityIdentifier("videoBar.playPause")
            position
            if width >= 480 { volume }
            speedMenu
            if !model.videoTracks.subtitles.isEmpty { subtitlesMenu }
            if model.videoTracks.audio.count > 1 { audioMenu }
            Button { model.toggleFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Full Screen (\(shortcuts.hint(.fullScreen)))"))
            .accessibilityLabel("Full Screen")
            .accessibilityIdentifier("videoBar.fullScreen")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video controls")
        .accessibilityIdentifier("videoBar")
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(.degrees(90))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 24)
            // The mouse on it goes through AppKit: a SwiftUI drag and double
            // tap on one view moved nothing on CI
            .overlay(GripHandle(onDrag: { translation in
                dragging = true
                onDrag(translation)
            }, onEnd: {
                dragging = false
                onDragEnd()
            }, onDoubleClick: { model.resetVideoBarPosition() }))
            .help("Drag to move the control bar; double-click: back to the bottom")
            .accessibilityElement()
            .accessibilityLabel("Move control bar")
            .accessibilityAction(named: "Reset Control Bar Position") { model.resetVideoBarPosition() }
            .accessibilityIdentifier("videoBar.grip")
    }

    private var position: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let progress = scrubbing ?? min(max(model.activePlayer?.progress ?? 0, 0), 1)
            let length = model.activePlayer?.lengthSeconds
            HStack(spacing: 8) {
                Text(verbatim: length.map { VideoProgressBar.clock($0 * progress) } ?? "0:00")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { progress }, set: { value in
                    scrubbing = value
                    model.activePlayer?.seek(toProgress: value)
                }), in: 0...1) { editing in
                    if !editing { scrubbing = nil }
                }
                .controlSize(.small)
                .frame(minWidth: 60)
                .accessibilityLabel("Position")
                .accessibilityValue(length.map { VideoProgressBar.clock($0 * progress) } ?? progress.formatted(.percent.precision(.fractionLength(0))))
                .accessibilityIdentifier("videoBar.position")
                Text(verbatim: "−" + (length.map { VideoProgressBar.clock($0 * (1 - progress)) } ?? "0:00"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var volume: some View {
        HStack(spacing: 4) {
            Image(systemName: model.volume == 0 ? "speaker.slash.fill" : model.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 60)
                .help(String(localized: "Volume (\(HelpKeys.pair(.fullUp, .fullDown).text(shortcuts) ?? String(localized: "no key")))"))
                .accessibilityLabel("Volume")
                .accessibilityValue(model.volume.formatted(.percent.precision(.fractionLength(0))))
                .accessibilityIdentifier("videoBar.volume")
        }
    }

    /// Play / pause: Space in the full view, as the slideshow's pause there.
    private var playKeys: String { shortcuts.hint(model.slideshow == nil ? .fullSpace : .showPause) }

    private var speedMenu: some View {
        Menu {
            VideoMenus.speedPicker(model)
        } label: {
            Text(verbatim: PlaybackSpeed.text(model.playbackSpeed)).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Speed (\(HelpKeys.pair(.slower, .faster).text(shortcuts) ?? String(localized: "no key")))"))
        .accessibilityLabel("Speed")
        .accessibilityValue(PlaybackSpeed.text(model.playbackSpeed))
        .accessibilityIdentifier("videoBar.speed")
    }

    private var subtitlesMenu: some View {
        Menu {
            VideoMenus.subtitlePicker(model)
        } label: {
            Image(systemName: model.videoTracks.subtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Subtitles (\([shortcuts.text(.subtitles), shortcuts.text(.nextSubtitle)].filter { !$0.isEmpty }.joined(separator: ", ")))"))
        .accessibilityLabel("Subtitles")
        .accessibilityValue(model.videoTracks.currentSubtitle?.name ?? String(localized: "Off"))
        .accessibilityIdentifier("videoBar.subtitles")
    }

    private var audioMenu: some View {
        Menu {
            VideoMenus.audioPicker(model)
        } label: {
            Image(systemName: "waveform")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Audio track (\(shortcuts.hint(.nextAudio)))"))
        .accessibilityLabel("Audio Track")
        .accessibilityValue(model.videoTracks.currentAudio?.name ?? "")
        .accessibilityIdentifier("videoBar.audio")
    }
}

/// The choices of speed, subtitles and audio track: the same in the control
/// bar, the Video menu and the full view's context menu.
@MainActor
enum VideoMenus {
    static func speedPicker(_ model: BrowserModel) -> some View {
        Picker("Speed", selection: Binding(get: { model.playbackSpeed }, set: { model.setSpeed($0) })) {
            ForEach(PlaybackSpeed.steps, id: \.self) { speed in
                Text(verbatim: PlaybackSpeed.text(speed)).tag(speed)
            }
        }
        .pickerStyle(.inline)
    }

    static func subtitlePicker(_ model: BrowserModel) -> some View {
        Picker("Subtitles", selection: Binding(get: { model.videoTracks.subtitleID }, set: { model.selectSubtitle($0) })) {
            Text("Off").tag(Int?.none)
            ForEach(model.videoTracks.subtitles) { track in
                Text(verbatim: track.name).tag(Int?.some(track.id))
            }
        }
        .pickerStyle(.inline)
    }

    static func audioPicker(_ model: BrowserModel) -> some View {
        Picker("Audio Track", selection: Binding(get: { model.videoTracks.audioID ?? -1 }, set: { model.selectAudio($0) })) {
            ForEach(model.videoTracks.audio) { track in
                Text(verbatim: track.name).tag(track.id)
            }
        }
        .pickerStyle(.inline)
    }

    /// The full view's context menu on a video (a right click on it).
    static func contextMenu(_ model: BrowserModel) -> NSMenu {
        let menu = NSMenu()
        let tracks = model.videoTracks
        let subtitles = NSMenu()
        if tracks.subtitles.isEmpty {
            subtitles.addItem(ActionItem(String(localized: "This video has no subtitles"), action: nil))
        } else {
            subtitles.addItem(ActionItem(String(localized: "Off"), on: tracks.subtitleID == nil) { model.selectSubtitle(nil) })
            for track in tracks.subtitles {
                subtitles.addItem(ActionItem(track.name, on: track.id == tracks.subtitleID) { model.selectSubtitle(track.id) })
            }
        }
        menu.addItem(submenu(String(localized: "Subtitles"), subtitles))
        if tracks.audio.count > 1 {
            let audio = NSMenu()
            for track in tracks.audio {
                audio.addItem(ActionItem(track.name, on: track.id == tracks.audioID) { model.selectAudio(track.id) })
            }
            menu.addItem(submenu(String(localized: "Audio Track"), audio))
        }
        let speeds = NSMenu()
        for speed in PlaybackSpeed.steps {
            speeds.addItem(ActionItem(PlaybackSpeed.text(speed), on: abs(speed - model.playbackSpeed) < 0.001) { model.setSpeed(speed) })
        }
        menu.addItem(submenu(String(localized: "Speed"), speeds))
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "Reset Control Bar Position")) { model.resetVideoBarPosition() })
        return menu
    }

    private static func submenu(_ title: String, _ items: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        items.title = title
        item.submenu = items
        return item
    }

    /// A menu item that runs a closure (nil: shown disabled).
    final class ActionItem: NSMenuItem {
        private var run: (() -> Void)?

        init(_ title: String, on: Bool = false, action: (() -> Void)?) {
            run = action
            super.init(title: title, action: action == nil ? nil : #selector(fire), keyEquivalent: "")
            target = self
            state = on ? .on : .off
            isEnabled = action != nil
        }

        required init(coder: NSCoder) { fatalError("not from a nib") }

        @objc private func fire() { run?() }
    }
}

/// The control bar's grip: a drag moves the bar (by how far the mouse went
/// since it was pressed, in the view's points, y down), a double click puts
/// it back.
struct GripHandle: NSViewRepresentable {
    let onDrag: (CGSize) -> Void
    let onEnd: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> GripView { update(GripView()) }
    func updateNSView(_ view: GripView, context: Context) { _ = update(view) }

    private func update(_ view: GripView) -> GripView {
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
        return view
    }

    final class GripView: NSView {
        var onDrag: (CGSize) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        private var start: NSPoint?
        private var moved = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { false }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { start = nil; onDoubleClick(); return }
            start = event.locationInWindow
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = event.locationInWindow
            moved = true
            NSCursor.closedHand.set()
            onDrag(CGSize(width: now.x - start.x, height: start.y - now.y))
        }

        override func mouseUp(with event: NSEvent) {
            if start != nil, moved { onEnd() }
            start = nil
            moved = false
        }
    }
}

/// A clear layer over the video that sees the mouse move (the control bar
/// shows) and takes right clicks (the context menu); every other click goes
/// through to the video and the bar.
struct VideoMouseCatcher: NSViewRepresentable {
    let onMove: () -> Void
    let onExit: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        update(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { update(view) }

    private func update(_ view: CatcherView) {
        view.onMove = onMove
        view.onExit = onExit
        view.makeMenu = menu
    }

    final class CatcherView: NSView {
        var onMove: () -> Void = {}
        var onExit: () -> Void = {}
        var makeMenu: () -> NSMenu = { NSMenu() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) { onMove() }
        override func mouseEntered(with event: NSEvent) { onMove() }
        override func mouseExited(with event: NSEvent) { onExit() }

        /// Only a right click (or a click with ⌃) lands here.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let right = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return right ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
        override func mouseDown(with event: NSEvent) {
            // ⌃-click
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
        }
    }
}

/// The speed, subtitles or audio track just chosen, shown a moment (as the
/// volume is).
struct PlaybackNoticeView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        BriefNotice(trigger: model.playbackNotice, animation: Motion.animation(.easeOut(duration: 0.15))) { shown in
            HStack(spacing: 10) {
                Image(systemName: shown.symbol).font(.title2)
                Text(verbatim: shown.text)
            }
            .noticePlate()
            .accessibilityLabel(shown.text)
            .accessibilityIdentifier("playbackNotice")
        }
        .allowsHitTesting(false)
    }
}
