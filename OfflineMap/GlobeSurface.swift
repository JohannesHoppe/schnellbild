import AppKit
import MetalKit
import QuartzCore

extension GlobeRenderer {
    /// One renderer per map, made off the main thread (compiling the shaders
    /// and loading the globe's data take a moment) and kept.
    @MainActor private static var made: [ObjectIdentifier?: GlobeRenderer] = [:]
    @MainActor private static var waiting: [ObjectIdentifier?: [(GlobeRenderer?) -> Void]] = [:]

    @MainActor static func shared(for map: MapRenderer?, _ done: @escaping (GlobeRenderer?) -> Void) {
        let key = map.map(ObjectIdentifier.init)
        if let renderer = made[key] { return done(renderer) }
        if waiting[key] != nil { waiting[key]?.append(done); return }
        waiting[key] = [done]
        DispatchQueue.global(qos: .userInitiated).async {
            let renderer = GlobeRenderer(map: map)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    made[key] = renderer
                    let callbacks = waiting.removeValue(forKey: key) ?? []
                    callbacks.forEach { $0(renderer) }
                }
            }
        }
    }
}

/// The globe's own view: the Metal drawing of the globe (`GlobeRenderer`)
/// over the flat map (`MapSurfaceView`), one camera for both. Below
/// `GlobeProjection.flatZoom` the Metal view shows the globe (flattening on
/// the way); from it on the flat map takes over, once its tiles are drawn
/// (the Metal view fades out over it, at once with Reduce motion). The view
/// handles every gesture itself, in both modes: drag or two-finger scroll
/// turn the globe (pan the flat map) and keep turning a moment after a drag
/// (not with Reduce motion), pinch, ⌘-scroll, the mouse wheel and double
/// click zoom about the pointer, keeping the place under it.
@MainActor
final class GlobeSurfaceView: NSView, MTKViewDelegate {
    var camera = MapCamera(center: Coordinate(latitude: 30, longitude: 10), zoom: 2) { didSet { if camera != oldValue { cameraChanged() } } }
    var interactive = true
    var lighting = false { didSet { if lighting != oldValue { redraw(); scheduleClock() } } }
    var exaggerated = true { didSet { if exaggerated != oldValue { redraw() } } }
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
    private var velocity: (x: Double, y: Double)?
    private var glide: (from: MapCamera, to: MapCamera, began: TimeInterval, duration: Double)?
    private var link: CADisplayLink?
    private var lastFrame: TimeInterval = 0
    private var clock: Timer?
    private var handoffPending = false
    nonisolated(unsafe) private var texturesObserver: NSObjectProtocol?
    /// No Metal: the flat map alone
    private(set) var flatOnly = false

    init(map: MapRenderer?) {
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
        GlobeRenderer.shared(for: map) { [weak self] renderer in self?.attach(renderer) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let texturesObserver { NotificationCenter.default.removeObserver(texturesObserver) }
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
        GlobeScene(camera: camera, size: bounds.size, dark: isDark, lighting: lighting, exaggerated: exaggerated, date: date ?? Date())
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
        let held = held(camera)
        if held != camera {
            camera = held
            // Reported after SwiftUI's layout pass, which this runs in: the
            // camera the owner holds then (it may have set another meanwhile),
            // held in this size
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let owner = self.ownerCamera else { self.onCameraChange?(held); return }
                let wanted = owner()
                let now = self.held(wanted)
                if now != self.camera { self.camera = now }
                if now != wanted { self.onCameraChange?(now) }
            }
        } else {
            updateMode()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleClock()
        if window == nil { stopMotion() }
    }

    /// The camera within the globe's zoom limits; on the flat map with the world filling the view vertically.
    func held(_ c: MapCamera) -> MapCamera {
        guard bounds.width > 0, bounds.height > 0 else { return c }
        if flatOnly { return MapViewport(camera: c, size: bounds.size).clamped() }
        var next = c
        next.zoom = min(MapViewport.maxZoom, max(GlobeProjection.minZoom(for: bounds.size), c.zoom))
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
            flat.isHidden = false
            if flat.camera != camera { flat.camera = camera }
            if let metal, !metal.isHidden {
                if !handoffPending {
                    handoffPending = true
                    redraw()
                    waitForFlatTiles(since: Date())
                }
            }
        } else {
            handoffPending = false
            if let metal {
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
            renderer.textures.prepare(for: scene)
            renderer.encode(scene, pass: pass, into: buffer)
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
            let next = MapCamera(center: Coordinate(latitude: g.from.center.latitude + (g.to.center.latitude - g.from.center.latitude) * e,
                                                    longitude: Astronomy.wrap180(g.from.center.longitude + dLon * e)),
                                 zoom: g.from.zoom + (g.to.zoom - g.from.zoom) * e)
            camera = held(next)
            onCameraChange?(camera)
            if t >= 1 { glide = nil }
        } else if let v = velocity {
            // A throw slows down within about half a second
            moved(to: pan(by: v.x * dt, v.y * dt))
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

    /// A point of the view (origin top left) from an event.
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        stopMotion()
        dragStart = event.locationInWindow
        dragged = false
        dragSteps = []
        if event.clickCount == 2 { zoom(by: 1, at: point(event)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, let last = dragStart else { return super.mouseDragged(with: event) }
        dragged = true
        // From the pointer's places (events posted by other programs, such as
        // XCUITest's, carry no deltas); y grows downwards as in deltaY
        let now = event.locationInWindow
        dragStart = now
        let dx = Double(now.x - last.x), dy = Double(last.y - now.y)
        dragSteps.append((event.timestamp, dx, dy))
        dragSteps.removeAll { event.timestamp - $0.0 > 0.1 }
        moved(to: pan(by: dx, dy))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive else { return super.mouseUp(with: event) }
        dragStart = nil
        guard dragged else { return }
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
        scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
               command: event.modifierFlags.contains(.command), at: point(event))
    }

    override func magnify(with event: NSEvent) {
        guard interactive else { return super.magnify(with: event) }
        pinch(by: Double(event.magnification), at: point(event))
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
