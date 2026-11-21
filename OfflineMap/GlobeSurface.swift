import AppKit
import MetalKit
import QuartzCore

extension GlobeRenderer {
    /// One renderer per map, made off the main thread (compiling the shaders
    /// and loading the globe's data take a moment) and kept while a globe
    /// view of that map is in a window. Its textures (the world and detail
    /// textures, the sky, the city lights, the satellite picture: about
    /// 300 MB of memory shared with the GPU) go with it `keepUnused` after
    /// the last such view left its window; the next globe makes them again.
    @MainActor private static var made: [ObjectIdentifier?: GlobeRenderer] = [:]
    @MainActor private static var waiting: [ObjectIdentifier?: [(GlobeRenderer?) -> Void]] = [:]
    /// The globe views in a window, per map.
    @MainActor private static var inUse: [ObjectIdentifier?: Int] = [:]
    @MainActor private static var dropping: [ObjectIdentifier?: DispatchWorkItem] = [:]
    /// How long a renderer no view shows is kept (switching back to the
    /// Atlas a moment later finds it ready).
    @MainActor static var keepUnused: TimeInterval = 20

    @MainActor static func shared(for map: MapRenderer?, _ done: @escaping (GlobeRenderer?) -> Void) {
        let key = map.map(ObjectIdentifier.init)
        if let renderer = made[key] { return done(renderer) }
        if waiting[key] != nil { waiting[key]?.append(done); return }
        waiting[key] = [done]
        let began = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let renderer = GlobeRenderer(map: map, data: .bundled())
            MapMotion.trace?(String(format: "globe: renderer made in %.0f ms", Date().timeIntervalSince(began) * 1000))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    made[key] = renderer
                    let callbacks = waiting.removeValue(forKey: key) ?? []
                    callbacks.forEach { $0(renderer) }
                    if inUse[key, default: 0] == 0 { scheduleDrop(key) }
                }
            }
        }
    }

    /// A globe view of the map came into a window (true) or left it (false).
    @MainActor static func shown(for map: MapRenderer?, _ shown: Bool) {
        let key = map.map(ObjectIdentifier.init)
        let count = max(0, inUse[key, default: 0] + (shown ? 1 : -1))
        inUse[key] = count
        if count > 0 {
            dropping.removeValue(forKey: key)?.cancel()
        } else {
            scheduleDrop(key)
        }
    }

    @MainActor private static func scheduleDrop(_ key: ObjectIdentifier?) {
        dropping.removeValue(forKey: key)?.cancel()
        let drop = DispatchWorkItem {
            MainActor.assumeIsolated {
                dropping[key] = nil
                guard inUse[key, default: 0] == 0 else { return }
                made[key] = nil
                MapMotion.trace?("globe: renderer let go")
            }
        }
        dropping[key] = drop
        DispatchQueue.main.asyncAfter(deadline: .now() + keepUnused, execute: drop)
    }

    /// Whether a renderer of the map is kept (tests).
    @MainActor static func isKept(for map: MapRenderer?) -> Bool { made[map.map(ObjectIdentifier.init)] != nil }
}

/// The globe's own view: the Metal drawing of the globe (`GlobeRenderer`)
/// over the flat map (`MapSurfaceView`), one camera for both. Below
/// `GlobeProjection.flatZoom` the Metal view shows the globe (flattening on
/// the way); from it on the flat map takes over, once its tiles are drawn
/// (the Metal view fades out over it, at once with Reduce motion). Zooming
/// out of the flat map, the flat map stays over the Metal view until a
/// frame of the globe with its textures is on screen (`revealPending`), so
/// one of the two always shows the map; near the flat zoom the globe's
/// textures for the way out are made ahead (`prewarm`). The view
/// handles every gesture itself, in both modes: drag or two-finger scroll
/// turn the globe (pan the flat map) and keep turning a moment after a drag
/// (not with Reduce motion), pinch, ⌘-scroll, the mouse wheel and double
/// click zoom about the pointer, keeping the place under it.
@MainActor
final class GlobeSurfaceView: NSView, MTKViewDelegate, CameraHolding {
    var camera = MapCamera(center: Coordinate(latitude: 30, longitude: 10), zoom: 2) { didSet { if camera != oldValue { cameraChanged() } } }
    var interactive = true
    var lighting = false { didSet { if lighting != oldValue { redraw(); scheduleClock() } } }
    var exaggerated = true { didSet { if exaggerated != oldValue { redraw() } } }
    /// How much of the cloud cover shows (0 none … 1 all)
    var clouds = 0.0 { didSet { if clouds != oldValue { redraw() } } }
    /// The moment the Sun is placed for (nil: now, updated every minute)
    var date: Date? { didSet { redraw() } }
    var onCameraChange: ((MapCamera) -> Void)?
    /// The camera the owner holds now (the SwiftUI binding's)
    var ownerCamera: (() -> MapCamera)?
    var onInteraction: (() -> Void)?
    /// Boxes in the view where the flat map's labels must not go
    var keepFree: [CGRect] = [] { didSet { flat.keepFree = keepFree } }

    let flat: MapSurfaceView
    private(set) var renderer: GlobeRenderer?
    private var metal: MTKView?
    /// Where the pointer was at the drag's last event (window coordinates)
    private var dragStart: NSPoint?
    private var dragged = false
    /// Recent drag steps (time, dx, dy) for the throw at the end
    private var dragSteps: [(TimeInterval, Double, Double)] = []
    /// The drag tilts and turns the view (⌥ held when it began)
    private var dragTilts = false
    private var velocity: (x: Double, y: Double)?
    private var glide: (from: MapCamera, to: MapCamera, began: TimeInterval, duration: Double)?
    private var link: CADisplayLink?
    private var lastFrame: TimeInterval = 0
    private var clock: Timer?
    private var handoffPending = false
    /// The globe is drawn under the flat map until a frame with its textures is on screen
    private(set) var revealPending = false
    /// Which wait for the globe's frame is the current one (a timer of an earlier one does nothing)
    private var revealToken = 0
    /// How long the flat map waits at most for the globe's first frame
    static let revealTimeout: TimeInterval = 1
    /// How many zoom steps above the flat zoom the globe's textures are made ahead
    static let prewarmSteps = 3.0
    nonisolated(unsafe) private var texturesObserver: NSObjectProtocol?
    /// No Metal: the flat map alone
    private(set) var flatOnly = false

    /// The map it shows (the key of its renderer).
    private let map: MapRenderer?
    /// Counted among the globe views in a window (`GlobeRenderer.shown`).
    private var counted = false

    init(map: MapRenderer?) {
        self.map = map
        flat = MapSurfaceView(renderer: map)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = GlobeScene.space.cgColor
        flat.interactive = false
        flat.isHidden = true
        addSubview(flat)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Globe"))
        // Made early; taken once the view is in a window (`viewDidMoveToWindow`)
        GlobeRenderer.shared(for: map) { [weak self] renderer in
            guard let self, self.window != nil else { return }
            self.attach(renderer)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let texturesObserver { NotificationCenter.default.removeObserver(texturesObserver) }
    }

    /// Out of its window: the Metal view and the renderer go (its textures
    /// with it once no other globe shows them, `GlobeRenderer.shown`).
    private func detach() {
        if let texturesObserver { NotificationCenter.default.removeObserver(texturesObserver) }
        texturesObserver = nil
        metal?.delegate = nil
        metal?.removeFromSuperview()
        metal = nil
        renderer = nil
        handoffPending = false
        if revealPending {
            revealPending = false
            flatOnTop(false)
        }
    }

    /// Shows the globe with this renderer (tests pass their own).
    func attach(_ renderer: GlobeRenderer?) {
        guard self.renderer == nil else { return }
        guard let renderer else {
            flatOnly = true
            camera = held(camera)
            updateMode()
            return
        }
        self.renderer = renderer
        let view = MTKView(frame: bounds, device: renderer.device)
        view.colorPixelFormat = GlobeRenderer.colorFormat
        view.depthStencilPixelFormat = GlobeRenderer.depthFormat
        view.sampleCount = GlobeRenderer.sampleCount
        view.colorspace = MapColor.sRGB
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.delegate = self
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: flat)
        metal = view
        texturesObserver = NotificationCenter.default.addObserver(forName: GlobeTextures.didChange, object: renderer.textures, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        updateMode()
    }

    override var acceptsFirstResponder: Bool { interactive }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var projection: GlobeProjection { GlobeProjection(camera: camera, size: bounds.size) }
    var scene: GlobeScene {
        GlobeScene(camera: camera, size: bounds.size, dark: isDark, lighting: lighting, exaggerated: exaggerated, date: date ?? Date(),
                   clouds: clouds)
    }

    /// Every gesture is the globe's, over the flat map too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, interactive else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        flat.frame = bounds
        metal?.frame = bounds
        if !holdCamera() { updateMode() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleClock()
        let inWindow = window != nil
        if inWindow != counted {
            counted = inWindow
            GlobeRenderer.shown(for: map, inWindow)
        }
        if inWindow {
            if renderer == nil, !flatOnly {
                GlobeRenderer.shared(for: map) { [weak self] renderer in
                    guard let self, self.window != nil else { return }
                    self.attach(renderer)
                }
            }
        } else {
            stopMotion()
            detach()
        }
    }

    /// The camera within the globe's zoom limits; on the flat map with the world filling the view vertically.
    func held(_ c: MapCamera) -> MapCamera {
        guard bounds.width > 0, bounds.height > 0 else { return c }
        if flatOnly { return MapViewport(camera: c, size: bounds.size).clamped() }
        var next = GlobeProjection.held(c, size: bounds.size)
        let p = GlobeProjection(camera: next, size: bounds.size)
        if p.isFlat { next = MapViewport(camera: next, size: bounds.size).panned(by: 0, 0) }
        return next
    }

    private func cameraChanged() {
        updateMode()
    }

    /// Which view shows the camera: the globe (Metal) or the flat map, handing over once its tiles are there.
    func updateMode() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let isFlat = projection.isFlat || flatOnly
        if isFlat {
            if revealPending, let metal {
                // Back on the flat map before the globe showed: it stays the flat map
                revealPending = false
                flatOnTop(false)
                metal.isHidden = true
            }
            flat.isHidden = false
            if flat.camera != camera { flat.camera = camera }
            prewarm()
            if let metal, !metal.isHidden {
                if !handoffPending {
                    handoffPending = true
                    redraw()
                    waitForFlatTiles(since: Date())
                }
            }
        } else {
            handoffPending = false
            if revealPending, metal != nil {
                // Still waiting for the globe's frame: the flat map follows the camera meanwhile
                if flat.camera != camera { flat.camera = camera }
            } else if let metal, metal.isHidden, !flat.isHidden {
                // Out of the flat map: the globe draws under it until its frame is there
                revealPending = true
                revealToken += 1
                let token = revealToken, began = Date()
                flatOnTop(true)
                metal.isHidden = false
                metal.alphaValue = 1
                if flat.camera != camera { flat.camera = camera }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTimeout) { [weak self] in
                    guard let self, self.revealToken == token, self.revealPending else { return }
                    self.revealGlobe(since: began, timedOut: true)
                }
                revealSince = began
            } else if let metal {
                metal.isHidden = false
                // Through the animator, so a fade still running ends at 1, not at 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    metal.animator().alphaValue = 1
                }
                metal.alphaValue = 1
                flat.isHidden = true
            } else {
                flat.isHidden = true
            }
            redraw()
        }
    }

    /// When the current wait for the globe's frame began
    private var revealSince = Date()

    /// The globe's frame with its textures is on screen (or the wait is
    /// over): the flat map goes under it and hides.
    private func revealGlobe(since began: Date, timedOut: Bool) {
        guard revealPending else { return }
        revealPending = false
        flatOnTop(false)
        flat.isHidden = true
        MapMotion.trace?(String(format: "globe: shown over the flat map after %.0f ms%@", Date().timeIntervalSince(began) * 1000,
                                timedOut ? " (its textures not ready)" : ""))
    }

    /// Puts the flat map over the Metal view or back under it (the subviews' order, back to front).
    private func flatOnTop(_ onTop: Bool) {
        var context = onTop
        withUnsafeMutablePointer(to: &context) { pointer in
            sortSubviews({ a, b, context in
                let onTop = context?.load(as: Bool.self) ?? false
                func rank(_ view: NSView) -> Int { view is MapSurfaceView ? (onTop ? 1 : -1) : 0 }
                let ra = rank(a), rb = rank(b)
                return ra < rb ? .orderedAscending : ra > rb ? .orderedDescending : .orderedSame
            }, context: pointer)
        }
    }

    /// On the flat map within `prewarmSteps` of the zoom where the globe
    /// shows again (`GlobeProjection.globeZoom`: the flat zoom, or with a
    /// tilt chosen where it starts to show): the globe's textures for the
    /// camera zoomed out to just below it (the world and detail textures,
    /// the satellite tiles) are made ahead.
    private func prewarm() {
        guard let renderer, !flatOnly, bounds.width > 0, bounds.height > 0 else { return }
        let globeZoom = projection.globeZoom
        guard camera.zoom < globeZoom + Self.prewarmSteps else { return }
        var next = scene
        next.camera.zoom = globeZoom - 0.01
        renderer.textures.prepare(for: next)
    }

    /// Fades the globe out once the flat map's tiles are drawn (at most a second later).
    private func waitForFlatTiles(since start: Date) {
        guard handoffPending, projection.isFlat else { return }
        if flat.allTilesShown || Date().timeIntervalSince(start) > 1 {
            handoffPending = false
            guard let metal else { return }
            if MapMotion.reduced {
                metal.isHidden = true
            } else {
                MapMotion.began("fade")
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.15
                    metal.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.projection.isFlat, !self.handoffPending else { return }
                        self.metal?.isHidden = true
                    }
                })
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.waitForFlatTiles(since: start) }
    }

    func redraw() {
        guard let metal, !metal.isHidden || handoffPending else { return }
        metal.needsDisplay = true
    }

    /// Keeps the Sun where it is now: a new picture every minute while the light is on.
    private func scheduleClock() {
        clock?.invalidate()
        clock = nil
        guard lighting, window != nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.date == nil { self?.redraw() } }
        }
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { redraw() }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let renderer, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = renderer.queue.makeCommandBuffer(), bounds.width > 0 else { return }
            let scene = scene
            let ready = renderer.textures.isReady(for: scene)
            renderer.textures.prepare(for: scene)
            renderer.encode(scene, pass: pass, into: buffer)
            if revealPending, ready {
                // This frame shows the globe whole: the flat map goes once it is on screen
                let token = revealToken, began = revealSince
                drawable.addPresentedHandler { [weak self] _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.revealToken == token else { return }
                            self.revealGlobe(since: began, timedOut: false)
                        }
                    }
                }
            }
            buffer.present(drawable)
            buffer.commit()
        }
    }

    // MARK: Moving

    /// The camera after a move by the user.
    private func moved(to next: MapCamera) {
        let held = held(next)
        guard held != camera else { return }
        camera = held
        onCameraChange?(held)
        onInteraction?()
    }

    private func stopMotion() {
        velocity = nil
        glide = nil
        link?.invalidate()
        link = nil
    }

    private func startLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastFrame = CACurrentMediaTime()
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0.001, now - lastFrame))
        lastFrame = now
        if let g = glide {
            let t = min(1, (now - g.began) / g.duration)
            let e = 1 - pow(1 - t, 3)
            let dLon = Astronomy.wrap180(g.to.center.longitude - g.from.center.longitude)
            let dHeading = Astronomy.wrap180(g.to.heading - g.from.heading)
            let next = MapCamera(center: Coordinate(latitude: g.from.center.latitude + (g.to.center.latitude - g.from.center.latitude) * e,
                                                    longitude: Astronomy.wrap180(g.from.center.longitude + dLon * e)),
                                 zoom: g.from.zoom + (g.to.zoom - g.from.zoom) * e,
                                 pitch: g.from.pitch + (g.to.pitch - g.from.pitch) * e, heading: g.from.heading + dHeading * e)
            camera = held(next)
            onCameraChange?(camera)
            if t >= 1 { glide = nil }
        } else if let v = velocity {
            // A throw slows down within about half a second
            let before = camera
            moved(to: pan(by: v.x * dt, v.y * dt))
            if camera != before { MapMotion.threw(hypot(v.x * dt, v.y * dt)) }
            let decay = exp(-dt / 0.3)
            let next = (x: v.x * decay, y: v.y * decay)
            velocity = hypot(next.x, next.y) < 20 ? nil : next
        }
        if glide == nil && velocity == nil { stopMotion() }
    }

    /// The camera moved by a drag of (dx, dy) points: the globe turns, the flat map pans.
    func pan(by dx: Double, _ dy: Double) -> MapCamera {
        flatOnly ? MapViewport(camera: camera, size: bounds.size).panned(by: dx, dy) : projection.rotated(by: dx, dy)
    }

    /// Glides to the camera (at once with Reduce motion).
    func move(to target: MapCamera, animated: Bool = true) {
        stopMotion()
        let target = held(target)
        if !animated || MapMotion.reduced {
            moved(to: target)
            return
        }
        MapMotion.began("glide")
        onInteraction?()
        glide = (camera, target, CACurrentMediaTime(), 0.35)
        startLink()
    }

    /// Zooms by `steps` (1 doubles) about a point of the view (origin top left), gliding.
    func zoom(by steps: Double, at point: CGPoint? = nil) {
        let anchor = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let from = glide?.to ?? camera
        let target = flatOnly ? MapViewport(camera: from, size: bounds.size).zoomed(to: from.zoom + steps, keeping: anchor)
            : GlobeProjection(camera: from, size: bounds.size).zoomed(to: from.zoom + steps, keeping: anchor)
        move(to: target)
    }

    private func zoomNow(by steps: Double, at point: CGPoint) {
        stopMotion()
        moved(to: flatOnly ? MapViewport(camera: camera, size: bounds.size).zoomed(to: camera.zoom + steps, keeping: point)
              : projection.zoomed(to: camera.zoom + steps, keeping: point))
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        stopMotion()
        dragStart = event.locationInWindow
        dragged = false
        dragSteps = []
        dragTilts = event.modifierFlags.contains(.option) && !flatOnly
        if event.clickCount == 2 && !dragTilts { zoom(by: 1, at: point(event)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, let last = dragStart else { return super.mouseDragged(with: event) }
        dragged = true
        // From the pointer's places (events posted by other programs, such as
        // XCUITest's, carry no deltas); y grows downwards as in deltaY
        let now = event.locationInWindow
        dragStart = now
        let dx = Double(now.x - last.x), dy = Double(last.y - now.y)
        if dragTilts {
            tilt(by: -dy * 0.3, turn: dx * 0.3)
            return
        }
        dragSteps.append((event.timestamp, dx, dy))
        dragSteps.removeAll { event.timestamp - $0.0 > 0.1 }
        moved(to: pan(by: dx, dy))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive else { return super.mouseUp(with: event) }
        dragStart = nil
        guard dragged, !dragTilts else { return }
        NSCursor.arrow.set()
        // The last tenth of a second's speed carries on (not with Reduce motion)
        let recent = dragSteps.filter { event.timestamp - $0.0 <= 0.1 }
        guard !MapMotion.reduced, let first = recent.first, recent.count >= 2 else { return }
        let span = max(0.016, event.timestamp - first.0)
        let vx = recent.reduce(0) { $0 + $1.1 } / span, vy = recent.reduce(0) { $0 + $1.2 } / span
        if hypot(vx, vy) > 150 {
            MapMotion.began("throw")
            velocity = (vx, vy)
            startLink()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard interactive else { return super.scrollWheel(with: event) }
        if event.modifierFlags.contains(.option), !flatOnly {
            // ⌥ with two fingers: up and down tilt, left and right turn
            let k = event.hasPreciseScrollingDeltas ? 0.3 : 3.0
            tilt(by: Double(event.scrollingDeltaY) * k, turn: -Double(event.scrollingDeltaX) * k)
            return
        }
        scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
               command: event.modifierFlags.contains(.command), at: point(event))
    }

    override func magnify(with event: NSEvent) {
        guard interactive else { return super.magnify(with: event) }
        pinch(by: Double(event.magnification), at: point(event))
    }

    override func rotate(with event: NSEvent) {
        guard interactive, !flatOnly else { return super.rotate(with: event) }
        // Two fingers turning turn the view, as in Apple's Maps
        tilt(by: 0, turn: -Double(event.rotation))
    }

    /// Tilts the view by `degrees` (towards the horizon when positive) and
    /// turns it by `turn` degrees clockwise: the tilt and heading chosen,
    /// of which the zoom shows its share (`GlobeProjection.tiltShare`).
    /// Tilting towards the horizon where less than half of the tilt would
    /// show (zoomed in beyond the middle of `fullTiltZoom` … `straightZoom`,
    /// the flat map too) glides out to `fullTiltZoom`, where it shows in full.
    func tilt(by degrees: Double, turn: Double = 0) {
        stopMotion()
        var next = camera
        next.pitch = min(GlobeProjection.maxPitch, max(0, camera.pitch + degrees))
        next.heading = camera.heading + turn
        if degrees > 0, next.pitch > 0, GlobeProjection.tiltShare(zoom: camera.zoom) < 0.5 {
            next.zoom = GlobeProjection.fullTiltZoom
            move(to: next)
            return
        }
        moved(to: next)
    }

    /// The tilt button: with no tilt chosen, the view tilted near the
    /// horizon, gliding out to `fullTiltZoom` when zoomed in further (the
    /// flat map too), where the tilt shows in full; with a tilt chosen
    /// (shown or eased out by the zoom), back to straight down with north up.
    func toggleTilt() {
        var next = camera
        if camera.pitch > 1 {
            next.pitch = 0
            next.heading = 0
        } else {
            next.pitch = 60
            next.zoom = min(camera.zoom, GlobeProjection.fullTiltZoom)
        }
        move(to: next)
    }

    /// A pinch step (AppKit's magnification: 0.1 is 10 % larger) about a point of the view.
    func pinch(by magnification: Double, at point: CGPoint) {
        zoomNow(by: log2(max(0.1, 1 + magnification)), at: point)
    }

    /// A scroll step: a mouse's wheel or ⌘ zooms, a trackpad's two fingers turn the globe (pan the flat map).
    func scroll(dx: Double, dy: Double, precise: Bool, command: Bool, at point: CGPoint) {
        if command || !precise {
            zoomNow(by: dy * (precise ? 0.01 : 0.25), at: point)
        } else {
            stopMotion()
            moved(to: pan(by: dx, dy))
        }
    }

    override func resetCursorRects() {
        if interactive { addCursorRect(bounds, cursor: .openHand) }
    }
}
