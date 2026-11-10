import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import VLCKit

/// Shows VLC's video without VLC's own OpenGL output: VLC hands every
/// decoded picture to these callbacks, written into IOSurface-backed pixel
/// buffers in the video's own form (NV12: brightness, then colour at half
/// resolution, so no colour conversion on the processor), and a layer shows
/// them; the compositor turns them into RGB. So VLC videos need no OpenGL (which
/// macOS deprecates and virtual Macs such as CI runners don't have). The
/// look (`setLook`) is applied here with Core Image, the same `Look.apply`
/// as for AVKit videos and photos; auto enhance measures the picture before
/// it (`latestStats`).
///
/// Uses libVLC's video callbacks (`libvlc_video_set_callbacks`,
/// `libvlc_video_set_format_callbacks`), exported by VLCKit, on the player
/// VLCKit wraps (`-[VLCMediaPlayer libVLCMediaPlayer]`).
final class VLCFrameOutput: @unchecked Sendable {   // state behind `lock`; the layer on the main thread
    /// Shows the pictures, scaled to fit.
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }()

    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    /// Buffers for pictures with the look applied.
    private var lookPool: CVPixelBufferPool?
    private var look = Look.neutral
    /// The last picture VLC showed, as decoded.
    private var latest: CVPixelBuffer?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Counts for UI-test diagnostics: pictures shown with a look, and
    /// renders that failed.
    private var withLook = 0
    private var failed = 0
    /// Time spent in the callbacks, to show the handover costs little.
    private var callbackSeconds = 0.0
    private var callbacks = 0
    /// Each picture's number, so an older one never replaces a newer one on
    /// the layer; and when VLC last showed one (a redraw is only needed
    /// while it doesn't, i.e. paused).
    private var sequence = 0
    private var onLayer = 0
    private var lastDisplay = Date.distantPast
    /// The newest look waiting for a redraw; older ones are skipped.
    private var pendingRedraw: Look?
    /// Renders a new look onto a paused picture off the main thread.
    private let redraw = DispatchQueue(label: "schnellbild.vlc-look")
    /// Locked for VLC to draw into, by the address VLC knows them by. A few
    /// are kept, since VLC may drop a picture without showing it.
    private var drawing: [UnsafeMutableRawPointer: CVPixelBuffer] = [:]
    private var drawingOrder: [UnsafeMutableRawPointer] = []
    /// On screen, and the last few before (the compositor may still read them).
    private var shown: [CVPixelBuffer] = []

    nonisolated(unsafe) private static var heldByPlayer: UInt8 = 0

    /// Connects to a player; call before it plays.
    @MainActor
    func attach(to player: VLCMediaPlayer) {
        guard let api = LibVLCVideo.shared,
              let native = LibVLCVideo.nativePlayer(of: player) else { return }
        // The player holds the output as long as it lives: VLCKit stops it
        // asynchronously and keeps it until then, and its decoder may still
        // open the video output (and call back here) after the app let go
        objc_setAssociatedObject(player, &Self.heldByPlayer, self, .OBJC_ASSOCIATION_RETAIN)
        // Each time VLC opens its video output (`setUp`, again for every
        // media played and every format change) it holds the output, until
        // that output closes (the cleanup callback), so a frame arriving
        // after the player went can't reach a freed object.
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        api.setCallbacks(native, { opaque, planes in
            Unmanaged<VLCFrameOutput>.fromOpaque(opaque!).takeUnretainedValue().lockPicture(planes)
        }, { opaque, picture, _ in
            Unmanaged<VLCFrameOutput>.fromOpaque(opaque!).takeUnretainedValue().unlockPicture(picture)
        }, { opaque, picture in
            Unmanaged<VLCFrameOutput>.fromOpaque(opaque!).takeUnretainedValue().display(picture)
        }, opaque)
        api.setFormatCallbacks(native, { opaque, chroma, width, height, pitches, lines in
            Unmanaged<VLCFrameOutput>.fromOpaque(opaque!.pointee!).takeUnretainedValue()
                .setUp(chroma: chroma!, width: width!, height: height!, pitches: pitches!, lines: lines!)
        }, { opaque in
            Unmanaged<VLCFrameOutput>.fromOpaque(opaque!).release()
        })
    }

    /// VLC tells the picture size; the pictures are NV12 (two planes).
    private func setUp(chroma: UnsafeMutablePointer<CChar>, width: UnsafeMutablePointer<UInt32>,
                       height: UnsafeMutablePointer<UInt32>, pitches: UnsafeMutablePointer<UInt32>,
                       lines: UnsafeMutablePointer<UInt32>) -> UInt32 {
        for (i, c) in "NV12".utf8.enumerated() { chroma[i] = CChar(bitPattern: c) }
        let w = Int(width.pointee), h = Int(height.pointee)
        guard let made = Self.makePool(width: w, height: h, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let forLook = Self.makePool(width: w, height: h, format: kCVPixelFormatType_32BGRA) else { return 0 }
        // The row lengths the buffers really have, so VLC writes into them right
        var probe: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, made, &probe)
        guard let probe, CVPixelBufferGetPlaneCount(probe) == 2 else { return 0 }
        for plane in 0..<2 {
            pitches[plane] = UInt32(CVPixelBufferGetBytesPerRowOfPlane(probe, plane))
            lines[plane] = UInt32(CVPixelBufferGetHeightOfPlane(probe, plane))
        }
        lock.lock()
        // HD and larger use the HD colour standard (BT.709), smaller ones SD (BT.601)
        hd = h > 576
        pool = made
        lookPool = forLook
        latest = nil
        drawing = [:]
        drawingOrder = []
        lock.unlock()
        _ = Unmanaged.passUnretained(self).retain()   // released by the cleanup callback
        return 1
    }

    private var hd = true

    private static func makePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        var made: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
        ] as CFDictionary, &made)
        return made
    }

    private func lockPicture(_ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        let start = Date()
        lock.lock()
        defer {
            callbackSeconds += Date().timeIntervalSince(start)
            lock.unlock()
        }
        var buffer: CVPixelBuffer?
        guard let pool else { return nil }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let colour = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        let matrix = hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        let primaries = hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        planes?.pointee = base
        planes?.advanced(by: 1).pointee = colour
        drawing[base] = buffer
        drawingOrder.append(base)
        if drawingOrder.count > 8 { drawing[drawingOrder.removeFirst()] = nil }
        return base
    }

    private func unlockPicture(_ picture: UnsafeMutableRawPointer?) {
        lock.lock()
        defer { lock.unlock() }
        guard let picture, let buffer = drawing[picture] else { return }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    private func display(_ picture: UnsafeMutableRawPointer?) {
        let start = Date()
        lock.lock()
        guard let picture, let buffer = drawing[picture] else { lock.unlock(); return }
        latest = buffer
        lastDisplay = start
        sequence += 1
        let number = sequence
        let look = self.look
        lock.unlock()
        present(buffer, with: look, number: number)
        lock.lock()
        callbackSeconds += Date().timeIntervalSince(start)
        callbacks += 1
        lock.unlock()
    }

    /// The settings to show the pictures with; a paused picture is drawn
    /// again with them.
    func setLook(_ new: Look) {
        lock.lock()
        guard new != look else { lock.unlock(); return }
        look = new
        // While VLC shows pictures, the next one carries the new look
        let paused = latest != nil && Date().timeIntervalSince(lastDisplay) > 0.15
        let queued = pendingRedraw != nil
        if paused { pendingRedraw = new }
        lock.unlock()
        guard paused, !queued else { return }
        redraw.async { [self] in
            lock.lock()
            let look = pendingRedraw
            pendingRedraw = nil
            let buffer = latest
            let number = sequence
            lock.unlock()
            if let look, let buffer { present(buffer, with: look, number: number) }
        }
    }

    /// Puts a picture on the layer, with the look applied (Core Image, on
    /// the GPU) unless it is neutral.
    private func present(_ buffer: CVPixelBuffer, with look: Look, number: Int) {
        var surfaceBuffer = buffer
        if !look.isNeutral {
            lock.lock()
            let pool = lookPool
            lock.unlock()
            var out: CVPixelBuffer?
            if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
            if let out {
                CVBufferSetAttachment(out, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
                let image = CIImage(cvPixelBuffer: buffer)
                context.render(look.apply(to: image), to: out, bounds: image.extent, colorSpace: sRGB)
                surfaceBuffer = out
                lock.lock(); withLook += 1; lock.unlock()
            } else {
                lock.lock(); failed += 1; lock.unlock()
            }
        }
        lock.lock()
        shown.append(surfaceBuffer)
        if shown.count > 4 { shown.removeFirst() }   // the compositor may still read the last ones
        lock.unlock()
        guard let surface = CVPixelBufferGetIOSurface(surfaceBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let newer = number >= onLayer
            if newer { onLayer = number }
            lock.unlock()
            guard newer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        }
    }

    /// What auto enhance measures: the picture as decoded, before the look;
    /// nil before the first.
    var latestStats: PictureStats? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        return buffer.flatMap { PictureStats.of(CIImage(cvPixelBuffer: $0)) }
    }

    /// For UI tests: what the output did.
    var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        let perFrame = callbacks > 0 ? callbackSeconds / Double(callbacks) * 1000 : 0
        return "with look \(withLook), failed \(failed), exposure \(String(format: "%.2f", look.exposure)), "
            + "handover \(String(format: "%.2f", perFrame)) ms per picture"
    }

    /// For UI tests: the mean luminance of what the layer holds (main thread).
    @MainActor
    var layerBrightness: String {
        guard let contents = layer.contents else { return "none" }
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return "not a surface" }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        var buffer: Unmanaged<CVPixelBuffer>?
        CVPixelBufferCreateWithIOSurface(nil, surface, nil, &buffer)
        guard let pixels = buffer?.takeRetainedValue() else { return "unreadable" }
        return PictureStats.of(CIImage(cvPixelBuffer: pixels)).map { String(format: "%.3f", $0.mean) } ?? "unmeasured"
    }
}

/// libVLC's video callback functions, looked up in VLCKit at run time.
private struct LibVLCVideo {
    typealias Lock = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?
    typealias Unlock = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?) -> Void
    typealias Display = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias Format = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<CChar>?,
                                       UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                                       UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32
    typealias Cleanup = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let setCallbacks: @convention(c) (OpaquePointer, Lock, Unlock, Display, UnsafeMutableRawPointer?) -> Void
    let setFormatCallbacks: @convention(c) (OpaquePointer, Format, Cleanup) -> Void

    static let shared: LibVLCVideo? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let callbacks = dlsym(handle, "libvlc_video_set_callbacks"),
              let format = dlsym(handle, "libvlc_video_set_format_callbacks") else { return nil }
        return LibVLCVideo(setCallbacks: unsafeBitCast(callbacks, to: (@convention(c) (OpaquePointer, Lock, Unlock, Display, UnsafeMutableRawPointer?) -> Void).self),
                           setFormatCallbacks: unsafeBitCast(format, to: (@convention(c) (OpaquePointer, Format, Cleanup) -> Void).self))
    }()

    /// The `libvlc_media_player_t` inside a VLCMediaPlayer.
    static func nativePlayer(of player: VLCMediaPlayer) -> OpaquePointer? {
        let selector = NSSelectorFromString("libVLCMediaPlayer")
        guard player.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> OpaquePointer?
        return unsafeBitCast(player.method(for: selector), to: Getter.self)(player, selector)
    }
}
