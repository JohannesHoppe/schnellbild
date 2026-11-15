import AppKit
import QuartzCore

/// Raster tiles of the map, made off the main thread and kept by pixel bytes:
/// a tile asked for and not there yet is drawn on a queue of its own and
/// reported through `onTile`; tiles no longer on screen that haven't started
/// are given up.
@MainActor
final class MapTileStore {
    let renderer: MapRenderer
    var onTile: (() -> Void)?
    private let cache = NSCache<NSString, CGImage>()
    private var pending: [NSString: Operation] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Map tiles"
        q.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
        q.qualityOfService = .userInitiated
        return q
    }()

    init(renderer: MapRenderer) {
        self.renderer = renderer
        cache.totalCostLimit = 192 << 20
    }

    static func name(_ key: TileKey, dark: Bool, scale: CGFloat) -> NSString {
        "\(key.z)/\(key.x)/\(key.y)/\(dark ? 1 : 0)/\(scale)" as NSString
    }

    func cached(_ key: TileKey, dark: Bool, scale: CGFloat) -> CGImage? {
        cache.object(forKey: Self.name(key, dark: dark, scale: scale))
    }

    /// The tile if it is made; else it is asked for.
    func image(_ key: TileKey, dark: Bool, scale: CGFloat) -> CGImage? {
        let name = Self.name(key, dark: dark, scale: scale)
        if let image = cache.object(forKey: name) { return image }
        guard pending[name] == nil else { return nil }
        let renderer = renderer, id = name as String
        let palette = MapPalette.appearance(dark: dark)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false, let image = renderer.renderTile(key, scale: scale, palette: palette) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let name = id as NSString
                    self.pending[name] = nil
                    self.cache.setObject(image, forKey: name, cost: image.bytesPerRow * image.height)
                    self.onTile?()
                }
            }
        }
        pending[name] = operation
        queue.addOperation(operation)
        return nil
    }

    /// Gives up the tiles asked for that aren't among `wanted` and haven't started.
    func keepOnly(_ wanted: Set<NSString>) {
        for (name, operation) in pending where !wanted.contains(name) && !operation.isExecuting {
            operation.cancel()
            pending[name] = nil
        }
    }
}

/// The map's own view: tiles as layers (moved, not redrawn, while the map
/// moves), the labels as one more layer drawn off the main thread for the
/// camera of the moment and moved with the map until the next one is
/// ready. Drag or scroll with two fingers to move, pinch, ⌘-scroll or
/// double-click to zoom.
@MainActor
final class MapSurfaceView: NSView {
    var camera = MapCamera.world { didSet { if camera != oldValue { layoutMap() } } }
    var interactive = true
    /// The camera after a move by the user (drag, scroll, pinch, double click)
    var onCameraChange: ((MapCamera) -> Void)?
    /// The first move by the user
    var onInteraction: (() -> Void)?
    /// Boxes in the view where labels must not go (the attribution, buttons)
    var keepFree: [CGRect] = [] { didSet { if keepFree != oldValue { scheduleLabels() } } }

    private var store: MapTileStore?
    private let tileLayer = CALayer()
    private let labelLayer = CALayer()
    private var tileLayers: [TileKey: CALayer] = [:]
    private var labelCamera: MapCamera?
    private var labelSize: CGSize = .zero
    private var labelsRunning = false
    private var labelsWanted = false
    private var dragStart: NSPoint?
    private var dragged = false
    private var animation: Timer?
    /// Where a glide ends (a second click on + while gliding adds to it)
    private var animationTarget: MapCamera?
    private let labelQueue = DispatchQueue(label: "Map labels", qos: .userInitiated)

    init(renderer: MapRenderer?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.addSublayer(tileLayer)
        layer?.addSublayer(labelLayer)
        labelLayer.contentsGravity = .resize
        if let renderer {
            store = MapTileStore(renderer: renderer)
            store?.onTile = { [weak self] in self?.layoutMap() }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Map"))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { interactive }
    override var mouseDownCanMoveWindow: Bool { false }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var palette: MapPalette { .appearance(dark: isDark) }
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    var viewport: MapViewport { MapViewport(camera: camera, size: bounds.size) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tileLayers.values.forEach { $0.contents = nil }
        layoutMap()
        scheduleLabels()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutMap()
        scheduleLabels()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tileLayer.frame = bounds
        let held = viewport.clamped()
        if held != camera {
            camera = held
            // Reported after SwiftUI's layout pass, which this runs in
            DispatchQueue.main.async { [weak self] in self?.onCameraChange?(held) }
        } else {
            layoutMap()
        }
        scheduleLabels()
    }

    // MARK: Layout

    /// Puts the tiles of the current camera in place: the nearest whole
    /// zoom's tiles, a tile not made yet shown by a larger one's part
    /// meanwhile; then moves the labels with the map.
    func layoutMap() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = palette.water.cgColor
        let dark = isDark, scale = scale, height = bounds.height
        var wanted = Set<NSString>()
        var used = Set<TileKey>()
        if let store {
            let z = Int(min(MapViewport.maxZoom, max(0, camera.zoom.rounded())))
            let n = 1 << z
            for (key, origin, side) in MapRenderer.tiles(for: viewport, zoom: z) {
                let wrapped = TileKey(z: z, x: ((key.x % n) + n) % n, y: key.y)
                wanted.insert(MapTileStore.name(wrapped, dark: dark, scale: scale))
                let tile = tileLayers[key] ?? {
                    let l = CALayer()
                    l.contentsGravity = .resize
                    l.minificationFilter = .trilinear
                    tileLayer.addSublayer(l)
                    tileLayers[key] = l
                    return l
                }()
                used.insert(key)
                // Tiles side by side on whole points so no seam shows between them
                let x0 = origin.x.rounded(), y0 = origin.y.rounded()
                let x1 = (origin.x + side).rounded(), y1 = (origin.y + side).rounded()
                tile.frame = CGRect(x: x0, y: height - y1, width: x1 - x0, height: y1 - y0)
                if let image = store.image(wrapped, dark: dark, scale: scale) {
                    tile.contents = image
                    tile.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                } else if let (image, rect) = placeholder(for: wrapped, dark: dark, scale: scale) {
                    tile.contents = image
                    tile.contentsRect = rect
                } else {
                    tile.contents = nil
                }
            }
            store.keepOnly(wanted)
        }
        for (key, l) in tileLayers where !used.contains(key) {
            l.removeFromSuperlayer()
            tileLayers[key] = nil
        }
        placeLabels()
        CATransaction.commit()
    }

    /// The part of a made tile of a lower zoom that covers the tile.
    private func placeholder(for key: TileKey, dark: Bool, scale: CGFloat) -> (CGImage, CGRect)? {
        guard let store else { return nil }
        for up in 1...min(5, key.z) {
            let parent = TileKey(z: key.z - up, x: key.x >> up, y: key.y >> up)
            guard let image = store.cached(parent, dark: dark, scale: scale) else { continue }
            let n = CGFloat(1 << up)
            let fx = CGFloat(key.x - (parent.x << up)), fy = CGFloat(key.y - (parent.y << up))
            // contentsRect's origin is at the image's bottom left
            return (image, CGRect(x: fx / n, y: (n - 1 - fy) / n, width: 1 / n, height: 1 / n))
        }
        return nil
    }

    /// The label image, made for `labelCamera`, moved and scaled to where the map is now.
    private func placeLabels() {
        guard let rendered = labelCamera, labelSize == bounds.size else { labelLayer.contents = nil; return }
        let before = MapViewport(camera: rendered, size: labelSize)
        let f = pow(2, camera.zoom - rendered.zoom)
        let c0 = before.centerWorld, c1 = viewport.centerWorld
        var tx = Double(c0.x) * f - Double(c1.x) + Double(labelSize.width) / 2 * (1 - f)
        let ty = Double(c0.y) * f - Double(c1.y) + Double(labelSize.height) / 2 * (1 - f)
        let world = viewport.worldSize
        tx -= (tx / world).rounded() * world
        labelLayer.frame = CGRect(x: tx, y: Double(bounds.height) - ty - Double(labelSize.height) * f,
                                  width: Double(labelSize.width) * f, height: Double(labelSize.height) * f)
        scheduleLabels()
    }

    /// Draws the labels for the current camera off the main thread, one
    /// drawing at a time; a camera that changed meanwhile gets the next.
    func scheduleLabels() {
        guard let renderer = store?.renderer, bounds.width > 0 else { return }
        if labelCamera == camera && labelSize == bounds.size { return }
        guard !labelsRunning else { labelsWanted = true; return }
        labelsRunning = true
        labelsWanted = false
        let viewport = viewport, palette = palette, scale = scale, keepFree = keepFree
        labelQueue.async { [weak self] in
            let image = renderer.labelImage(of: viewport, scale: scale, palette: palette, languages: .system, avoiding: keepFree)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.labelsRunning = false
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.labelLayer.contents = image
                    self.labelCamera = viewport.camera
                    self.labelSize = viewport.size
                    self.placeLabels()
                    CATransaction.commit()
                    if self.labelsWanted || self.labelCamera != self.camera { self.scheduleLabels() }
                }
            }
        }
    }

    // MARK: Moving

    private func moved(to next: MapCamera) {
        animation?.invalidate()
        animation = nil
        animationTarget = nil
        let held = MapViewport(camera: next, size: bounds.size).clamped()
        guard held != camera else { return }
        camera = held
        onCameraChange?(held)
        onInteraction?()
    }

    /// Glides to the camera (at once with Reduce motion).
    func animate(to target: MapCamera) {
        animation?.invalidate()
        let target = MapViewport(camera: target, size: bounds.size).clamped()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            moved(to: target)
            return
        }
        animationTarget = target
        let start = camera, began = Date(), duration = 0.25
        var startWorld = WebMercator.unitPoint(start.center)
        let endWorld = WebMercator.unitPoint(target.center)
        if endWorld.x - startWorld.x > 0.5 { startWorld.x += 1 } else if startWorld.x - endWorld.x > 0.5 { startWorld.x -= 1 }
        onInteraction?()
        animation = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(began) / duration)
                let e = 1 - pow(1 - t, 3)
                // The centre moves in the world's square, the zoom in steps of doubling
                let unit = CGPoint(x: startWorld.x + (endWorld.x - startWorld.x) * e, y: startWorld.y + (endWorld.y - startWorld.y) * e)
                let next = MapCamera(center: WebMercator.coordinate(unit: unit), zoom: start.zoom + (target.zoom - start.zoom) * e)
                self.camera = next
                self.onCameraChange?(next)
                if t >= 1 { timer.invalidate(); self.animation = nil; self.animationTarget = nil }
            }
        }
    }

    /// Zooms by `steps` (1 doubles) about a point of the view, gliding.
    func zoom(by steps: Double, at point: CGPoint? = nil) {
        let anchor = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        animate(to: viewport.zoomed(to: (animationTarget?.zoom ?? camera.zoom) + steps, keeping: anchor))
    }

    /// A point of the view (origin top left) from an event.
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        dragStart = event.locationInWindow
        dragged = false
        if event.clickCount == 2 { zoom(by: 1, at: point(event)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, dragStart != nil else { return super.mouseDragged(with: event) }
        dragged = true
        moved(to: viewport.panned(by: Double(event.deltaX), Double(event.deltaY)))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive else { return super.mouseUp(with: event) }
        dragStart = nil
        if dragged { NSCursor.arrow.set() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard interactive else { return super.scrollWheel(with: event) }
        if event.modifierFlags.contains(.command) {
            let delta = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.25)
            moved(to: viewport.zoomed(to: camera.zoom + delta, keeping: point(event)))
        } else {
            let k = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
            moved(to: viewport.panned(by: Double(event.scrollingDeltaX) * k, Double(event.scrollingDeltaY) * k))
        }
    }

    override func magnify(with event: NSEvent) {
        guard interactive else { return super.magnify(with: event) }
        moved(to: viewport.zoomed(to: camera.zoom + log2(max(0.1, 1 + Double(event.magnification))), keeping: point(event)))
    }

    override func resetCursorRects() {
        if interactive { addCursorRect(bounds, cursor: .openHand) }
    }
}
