import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import VLCKit
import VLCFrames

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
    /// Handed to VLC to draw into, by the address VLC knows them by: from
    /// `lock` until it is both unlocked (VLC no longer writes into it) and
    /// shown (`display`; VLC calls the two in either order). One still
    /// locked is never let go: its memory would go back to the pool and to
    /// the next picture while VLC still writes into it. Of those unlocked
    /// but not shown, a few are kept, since VLC may drop a picture without
    /// showing it.
    private struct Drawn {
        let buffer: CVPixelBuffer
        var unlocked = false
        var displayed = false
    }
    private var drawing: [UnsafeMutableRawPointer: Drawn] = [:]
    /// Unlocked, not shown yet, oldest first.
    private var drawnOrder: [UnsafeMutableRawPointer] = []
    /// On screen, and the last few before (the compositor may still read them).
    private var shown: [CVPixelBuffer] = []

    nonisolated(unsafe) private static var heldByPlayer: UInt8 = 0

    /// The media the player plays, for its video track's size and pixel
    /// shape when VLC opens its output (on VLC's thread: the player's own
    /// `media` is replaced on the main thread, `use`).
    private var media: VLCMedia?
    /// The pictures' size as shown (the track's visible size, its pixels
    /// made square); nil until VLC has opened its output.
    private var shownSize: CGSize?
    /// Where VLC draws a picture no buffer could be had for (it writes
    /// through the plane pointers whatever `lock` returns): two planes,
    /// freed with the output.
    private var scratch: UnsafeMutableRawPointer?
    private var scratchColour: UnsafeMutableRawPointer?

    deinit { scratch?.deallocate() }

    /// Connects to a player; call before it plays.
    @MainActor
    func attach(to player: VLCMediaPlayer) {
        guard let api = LibVLCVideo.shared,
              let native = LibVLCVideo.nativePlayer(of: player) else { return }
        // The player holds the output as long as it lives: VLCKit stops it
        // asynchronously and keeps it until then, and its decoder may still
        // open the video output (and call back here) after the app let go
        objc_setAssociatedObject(player, &Self.heldByPlayer, self, .OBJC_ASSOCIATION_RETAIN)
        if let media = player.media { use(media) }
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

    /// VLC tells the decoder's picture format and size and takes the one
    /// asked for here: NV12 (two planes) at the size to show. VLC's size is
    /// the decoder's buffer, often padded (1080 rows decode into 1088 or
    /// 1152), and VLC scales its visible part to whatever size is set here;
    /// so the buffers get the track's visible size with its pixels made
    /// square (a 720 × 576 PAL video at 16:9 is shown 1024 × 576), and VLC
    /// scales only for such non-square pixels.
    private func setUp(chroma: UnsafeMutablePointer<CChar>, width: UnsafeMutablePointer<UInt32>,
                       height: UnsafeMutablePointer<UInt32>, pitches: UnsafeMutablePointer<UInt32>,
                       lines: UnsafeMutablePointer<UInt32>) -> UInt32 {
        // JPEG-style chromas (J420, J422 …) use the full 0-255 range; VLC
        // converts them to NV12 without changing the values
        let fullRange = chroma[0] == CChar(bitPattern: UInt8(ascii: "J"))
        for (i, c) in "NV12".utf8.enumerated() { chroma[i] = CChar(bitPattern: c) }
        lock.lock()
        let media = self.media
        lock.unlock()
        let shown = Self.shownSize(track: media.flatMap(Self.videoTrack(of:)),
                                   decoded: (Int(width.pointee), Int(height.pointee)))
        let w = shown.width, h = shown.height
        width.pointee = UInt32(w)
        height.pointee = UInt32(h)
        let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let made = Self.makePool(width: w, height: h, format: format),
              let forLook = Self.makePool(width: w, height: h, format: kCVPixelFormatType_32BGRA) else { return 0 }
        // The row lengths the buffers really have, so VLC writes into them right
        var probe: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, made, &probe)
        guard let probe, CVPixelBufferGetPlaneCount(probe) == 2 else { return 0 }
        for plane in 0..<2 {
            pitches[plane] = UInt32(CVPixelBufferGetBytesPerRowOfPlane(probe, plane))
            lines[plane] = UInt32(CVPixelBufferGetHeightOfPlane(probe, plane))
        }
        let lumaBytes = Int(pitches[0]) * Int(lines[0])
        let newScratch = UnsafeMutableRawPointer.allocate(byteCount: lumaBytes + Int(pitches[1]) * Int(lines[1]), alignment: 64)
        lock.lock()
        // HD and larger use the HD colour standard (BT.709), smaller ones SD
        // (BT.601), decided by the visible height as VLC does
        hd = shown.visibleHeight > 576
        pool = made
        lookPool = forLook
        latest = nil
        drawing = [:]
        drawnOrder = []
        shownSize = CGSize(width: w, height: h)
        // VLC's earlier output has closed: nothing draws into the old scratch
        let oldScratch = scratch
        scratch = newScratch
        scratchColour = newScratch + lumaBytes
        lock.unlock()
        oldScratch?.deallocate()
        _ = Unmanaged.passUnretained(self).retain()   // released by the cleanup callback
        return 1
    }

    private var hd = true

    /// The video track's pixel size and pixel shape (VLCKit's track
    /// information).
    struct Track: Equatable {
        var width: Int
        var height: Int
        var sampleAspect: Double
    }

    /// The media the player plays from now on (set with `player.media`).
    func use(_ media: VLCMedia) {
        lock.lock()
        self.media = media
        lock.unlock()
    }

    static func videoTrack(of media: VLCMedia) -> Track? {
        guard let tracks = media.tracksInformation as? [[String: Any]] else { return nil }
        for track in tracks where track[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo {
            let number = { (key: String) in (track[key] as? NSNumber)?.intValue ?? 0 }
            let width = number(VLCMediaTracksInformationVideoWidth), height = number(VLCMediaTracksInformationVideoHeight)
            guard width > 0, height > 0 else { continue }
            let num = number(VLCMediaTracksInformationSourceAspectRatio)
            let den = number(VLCMediaTracksInformationSourceAspectRatioDenominator)
            return Track(width: width, height: height, sampleAspect: num > 0 && den > 0 ? Double(num) / Double(den) : 1)
        }
        return nil
    }

    /// The size the pictures are shown at: the track's visible size when it
    /// fits in what VLC decodes (else VLC's own size), turned as VLC turns
    /// the picture, with non-square pixels widened (or made taller); even
    /// sides, as NV12 needs. `visibleHeight`: before the pixels are made
    /// square.
    static func shownSize(track: Track?, decoded: (width: Int, height: Int)) -> (width: Int, height: Int, visibleHeight: Int) {
        var w = decoded.width, h = decoded.height
        var aspect = 1.0
        if var track {
            // VLC hands over an upright picture of a video stored turned
            if (track.width > track.height) != (w > h), track.width != track.height, w != h {
                swap(&track.width, &track.height)
                track.sampleAspect = 1 / track.sampleAspect
            }
            if track.width <= w, track.height <= h { w = track.width; h = track.height }
            if track.sampleAspect.isFinite, abs(track.sampleAspect - 1) > 0.01 {
                aspect = min(max(track.sampleAspect, 0.25), 4)
            }
        }
        let visibleHeight = h
        if aspect > 1 { w = Int((Double(w) * aspect).rounded()) } else if aspect < 1 { h = Int((Double(h) / aspect).rounded()) }
        func even(_ side: Int) -> Int { max(2, side + side % 2) }
        return (even(w), even(h), visibleHeight)
    }

    /// The pictures' size as shown, once VLC has opened its output.
    var pictureSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return shownSize
    }

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
        // Without a buffer VLC draws into the scratch planes: a picture
        // never shown
        func intoScratch() -> UnsafeMutableRawPointer? {
            planes?.pointee = scratch
            planes?.advanced(by: 1).pointee = scratchColour
            return scratch
        }
        var buffer: CVPixelBuffer?
        guard let pool else { return intoScratch() }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return intoScratch() }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let colour = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return intoScratch()
        }
        let matrix = hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        let primaries = hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        planes?.pointee = base
        planes?.advanced(by: 1).pointee = colour
        drawing[base] = Drawn(buffer: buffer)
        return base
    }

    private func unlockPicture(_ picture: UnsafeMutableRawPointer?) {
        lock.lock()
        defer { lock.unlock() }
        guard let picture, var drawn = drawing[picture], !drawn.unlocked else { return }
        CVPixelBufferUnlockBaseAddress(drawn.buffer, [])
        // VLC is done writing into it: shown already, it goes; else it waits
        // to be shown, among a few (VLC drops some pictures unshown)
        guard !drawn.displayed else { drawing[picture] = nil; return }
        drawn.unlocked = true
        drawing[picture] = drawn
        drawnOrder.append(picture)
        while drawnOrder.count > 8 { drawing[drawnOrder.removeFirst()] = nil }
    }

    private func display(_ picture: UnsafeMutableRawPointer?) {
        let start = Date()
        lock.lock()
        guard let picture, var drawn = drawing[picture] else { lock.unlock(); return }
        let buffer = drawn.buffer
        if drawn.unlocked {
            drawing[picture] = nil
            if let i = drawnOrder.firstIndex(of: picture) { drawnOrder.remove(at: i) }
        } else {
            drawn.displayed = true
            drawing[picture] = drawn
        }
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
        return "handover \(String(format: "%.2f", perFrame)) ms per picture"
    }
}
