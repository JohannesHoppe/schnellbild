import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import VLCKit

/// Shows VLC's video without VLC's own OpenGL output: VLC hands every
/// decoded picture to these callbacks, written into IOSurface-backed pixel
/// buffers, and a layer shows them. So VLC videos need no OpenGL (which
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
    /// Renders a new look onto a paused picture off the main thread.
    private let redraw = DispatchQueue(label: "schnellbild.vlc-look")
    /// Locked for VLC to draw into, by the address VLC knows them by. A few
    /// are kept, since VLC may drop a picture without showing it.
    private var drawing: [UnsafeMutableRawPointer: CVPixelBuffer] = [:]
    private var drawingOrder: [UnsafeMutableRawPointer] = []
    /// On screen, and the last few before (the compositor may still read them).
    private var shown: [CVPixelBuffer] = []

    /// Connects to a player; call before it plays.
    @MainActor
    func attach(to player: VLCMediaPlayer) {
        guard let api = LibVLCVideo.shared,
              let native = LibVLCVideo.nativePlayer(of: player) else { return }
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
        }, { _ in })
    }

    /// VLC tells the picture size; the pictures are BGRA, one plane.
    private func setUp(chroma: UnsafeMutablePointer<CChar>, width: UnsafeMutablePointer<UInt32>,
                       height: UnsafeMutablePointer<UInt32>, pitches: UnsafeMutablePointer<UInt32>,
                       lines: UnsafeMutablePointer<UInt32>) -> UInt32 {
        for (i, c) in "BGRA".utf8.enumerated() { chroma[i] = CChar(bitPattern: c) }
        let w = Int(width.pointee), h = Int(height.pointee)
        guard let made = Self.makePool(width: w, height: h), let forLook = Self.makePool(width: w, height: h) else { return 0 }
        // The row length the buffers really have, so VLC writes into them right
        var probe: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, made, &probe)
        guard let probe else { return 0 }
        pitches.pointee = UInt32(CVPixelBufferGetBytesPerRow(probe))
        lines.pointee = UInt32(h)
        lock.lock()
        pool = made
        lookPool = forLook
        latest = nil
        drawing = [:]
        drawingOrder = []
        lock.unlock()
        return 1
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        var made: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
        ] as CFDictionary, &made)
        return made
    }

    private func lockPicture(_ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        var buffer: CVPixelBuffer?
        guard let pool else { return nil }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        planes?.pointee = base
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
        lock.lock()
        guard let picture, let buffer = drawing[picture] else { lock.unlock(); return }
        latest = buffer
        let look = self.look
        lock.unlock()
        present(buffer, with: look)
    }

    /// The settings to show the pictures with; a paused picture is drawn
    /// again with them.
    func setLook(_ new: Look) {
        lock.lock()
        guard new != look else { lock.unlock(); return }
        look = new
        let buffer = latest
        lock.unlock()
        guard let buffer else { return }
        redraw.async { [self] in present(buffer, with: new) }
    }

    /// Puts a picture on the layer, with the look applied (Core Image, on
    /// the GPU) unless it is neutral.
    private func present(_ buffer: CVPixelBuffer, with look: Look) {
        var surfaceBuffer = buffer
        if !look.isNeutral {
            lock.lock()
            let pool = lookPool
            lock.unlock()
            var out: CVPixelBuffer?
            if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
            if let out {
                CVBufferSetAttachment(out, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
                // VLC's alpha byte isn't meant as transparency
                let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: sRGB])
                    .settingAlphaOne(in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
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
        DispatchQueue.main.async { [layer] in
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
        return buffer.flatMap {
            let image = CIImage(cvPixelBuffer: $0, options: [.colorSpace: sRGB])
            return PictureStats.of(image.settingAlphaOne(in: image.extent))
        }
    }

    /// For UI tests: what the output did.
    var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        var alpha = "-"
        if let latest, CVPixelBufferLockBaseAddress(latest, .readOnly) == kCVReturnSuccess {
            if let base = CVPixelBufferGetBaseAddress(latest) { alpha = "\(base.load(fromByteOffset: 3, as: UInt8.self))" }
            CVPixelBufferUnlockBaseAddress(latest, .readOnly)
        }
        return "with look \(withLook), failed \(failed), exposure \(String(format: "%.2f", look.exposure)), alpha \(alpha)"
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
