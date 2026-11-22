import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import VLCKit
import VLCFrames

/// Shows VLC's video without VLC's own OpenGL output: VLC hands every
/// decoded picture to these callbacks, written into IOSurface-backed pixel
/// buffers in the video's own form (NV12: brightness, then colour at half
/// resolution, so no colour conversion on the processor; P010, the same
/// with 10 bits, for videos of more than 8 bits), and a layer shows them;
/// the compositor turns them into RGB. HDR videos (PQ or HLG, from 10 bits)
/// are tagged as such and shown in EDR, as AVKit's layer shows them. So VLC videos need no OpenGL (which
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
    /// Works on sRGB-encoded values (`setOverlay`).
    private let overlayContext = CIContext(options: [.cacheIntermediates: false,
                                                     .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// For pictures of more than 8 bits with a look: half floats, extended
    /// linear Display P3 (values above 1 are brighter than SDR white).
    private let deepContext = CIContext(options: [.cacheIntermediates: false, .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue)])
    private let extendedLinear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    /// Time spent in the callbacks, to show the handover costs little.
    private var callbackSeconds = 0.0
    private var callbacks = 0
    /// Pictures shown since the media was handed over (`use`): UI tests
    /// wait for the media opened anew to reach the screen.
    private var shownOfMedia = 0
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
    /// asked for here: NV12 (two planes), P010 for a source of more than 8
    /// bits, at the size to show. VLC's size is
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
        let source = String(decoding: (0..<4).map { UInt8(bitPattern: chroma[$0]) }, as: UTF8.self)
        let deep = Self.isDeep(chroma: source)
        let wanted: [UInt8] = Array((deep ? "P010" : "NV12").utf8)
        for i in 0..<4 { chroma[i] = CChar(bitPattern: wanted[i]) }
        lock.lock()
        let media = self.media
        lock.unlock()
        // What the container states is known already; what the decoder finds
        // in the stream comes once this output has opened (`refreshColour`)
        let colour = deep ? media.flatMap(LibVLCVideo.colour(of:)) : nil
        let proposed = (width: Int(width.pointee), height: Int(height.pointee))
        let shown = Self.shownSize(track: media.flatMap(Self.videoTrack(of:)), decoded: proposed)
        let w = shown.width, h = shown.height
        width.pointee = UInt32(w)
        height.pointee = UInt32(h)
        let format = deep
            ? (colour?.fullRange == true ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        // The look keeps an HDR picture's highlights in half floats
        guard let made = Self.makePool(width: w, height: h, format: format),
              let forLook = Self.makePool(width: w, height: h, format: deep ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA)
        else { return 0 }
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
        self.deep = deep
        self.colour = colour
        colourLookups = deep && colour == nil ? Self.colourLookupLimit : 0
        pool = made
        lookPool = forLook
        latest = nil
        drawing = [:]
        drawnOrder = []
        shownSize = CGSize(width: w, height: h)
        decodedSize = proposed
        formatPending = false
        // VLC's earlier output has closed: nothing draws into the old scratch
        let oldScratch = scratch
        scratch = newScratch
        scratchColour = newScratch + lumaBytes
        lock.unlock()
        oldScratch?.deallocate()
        showInEDR(deep && colour?.isHDR == true)
        _ = Unmanaged.passUnretained(self).retain()   // released by the cleanup callback
        return 1
    }

    private var hd = true

    /// The buffers are P010: the source has more than 8 bits (VideoToolbox's
    /// 10-bit pictures, FFmpeg's 10-, 12- or 16-bit ones). Only these are
    /// shown as HDR: an 8-bit source that VLC hands over as such is SDR, or
    /// VideoToolbox has made it 8-bit RGB already.
    private var deep = false
    /// The video's colours once VLC states them (nil: not yet).
    private var colour: VideoColour?
    /// How many more pictures look for the colours the decoder found.
    private var colourLookups = 0
    /// VLC learns those from the decoder right after this output opened,
    /// with the next data it reads: a few pictures in. A video that never
    /// states them is SDR.
    private static let colourLookupLimit = 120
    /// The layer shows EDR (main thread).
    private(set) var showsEDR = false

    /// VLC's chromas of more than 8 bits per sample (`vlc_fourcc.h`):
    /// VideoToolbox's 10-bit pictures, P010, and the planar YUV and RGB
    /// ones with 9, 10, 12 or 16 bits.
    static func isDeep(chroma: String) -> Bool {
        if chroma == "CVPP" || chroma == "P010" { return true }
        let c = Array(chroma)
        guard c.count == 4 else { return false }
        if ["I0", "I2", "I4"].contains(String(c[0...1])), "9ACF".contains(c[2]), "LB".contains(c[3]) { return true }
        return chroma.hasPrefix("GB") && "9ACF".contains(c[2]) && "LB".contains(c[3])
    }

    /// While the colours aren't known, each picture asks VLC again, up to
    /// `colourLookupLimit` pictures.
    private func refreshColour() {
        lock.lock()
        guard colourLookups > 0, let media else { lock.unlock(); return }
        colourLookups -= 1
        lock.unlock()
        guard let found = LibVLCVideo.colour(of: media) else { return }
        lock.lock()
        let still = colour == nil && deep
        if still {
            colour = found
            colourLookups = 0
        }
        lock.unlock()
        if still { showInEDR(found.isHDR) }
    }

    /// HDR pictures show beyond SDR white where the display can (EDR), as in
    /// AVKit's `AVPlayerLayer`; SDR ones within SDR.
    private func showInEDR(_ on: Bool) {
        DispatchQueue.main.async { [self] in
            guard showsEDR != on else { return }
            showsEDR = on
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.wantsExtendedDynamicRangeContent = on
            CATransaction.commit()
        }
    }

    /// The video track's pixel size and pixel shape (VLCKit's track
    /// information).
    struct Track: Equatable {
        var width: Int
        var height: Int
        var sampleAspect: Double
    }

    /// The media the player plays from now on (set with `player.media`).
    /// `newFormat`: VLC opens its output anew for it (decoded in software
    /// after VideoToolbox: another chroma); until then the pictures VLC
    /// still shows of the media before aren't shown here.
    func use(_ media: VLCMedia, newFormat: Bool = false) {
        lock.lock()
        self.media = media
        shownOfMedia = 0
        openings += 1
        formatPending = newFormat
        usedAt = Date()
        lock.unlock()
    }

    /// When the media was handed over (`use`).
    private var usedAt = Date.distantPast

    /// The video track's visible size (`LibVLCVideo.visibleTrack`: the
    /// container's, else the stream's as VLC states it).
    static func videoTrack(of media: VLCMedia) -> Track? {
        LibVLCVideo.visibleTrack(of: media).map { Track(width: $0.width, height: $0.height, sampleAspect: $0.sampleAspect) }
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
        refreshColour()
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
        if deep, let hdr = self.colour, hdr.isHDR {
            hdr.attach(to: buffer)
        } else {
            let matrix = hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
            let primaries = hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
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
        // Held: the picture on the layer stays (`hold`); so do pictures of
        // the media before (its output closes after a new one is handed over)
        // until VLC opens its output for the new one (`use(newFormat:)`; two
        // seconds at most)
        if held || (formatPending && Date().timeIntervalSince(usedAt) < 2) { lock.unlock(); return }
        latest = buffer
        lastDisplay = start
        sequence += 1
        let number = sequence
        let look = self.look
        // The overlay and whether to log this picture, taken together (a
        // test logs the pictures from the overlay set on)
        let overlay = self.overlay
        let logged = shownOfMedia + 1 <= Self.probedFirst || picturesToLog > 0
        if picturesToLog > 0 { picturesToLog -= 1 }
        lock.unlock()
        let presented = present(buffer, with: look, overlay: overlay, number: number)
        lock.lock()
        callbackSeconds += Date().timeIntervalSince(start)
        callbacks += 1
        shownOfMedia += 1
        let ofMedia = shownOfMedia, opening = openings
        lock.unlock()
        guard Self.probing else { return }
        // Outside the handover's time: what the picture shows, for UI tests
        let probe = Self.probe(buffer, shown: logged ? presented : nil)
        lock.lock()
        lastProbePicture = probe
        lock.unlock()
        if logged, let probe {
            BrowserModel.testLog("vlc picture \(ofMedia) of media \(opening): \(probe) | \(BrowserModel.testClock) ms")
        }
    }

    /// UI tests: the next pictures are logged too (`setOverlay(logging:)`).
    private var picturesToLog = 0

    /// Pictures VLC shows while held aren't shown here: the one on the layer
    /// stays (VLC catching up, hidden, to where the video stood).
    private var held = false

    func hold(_ on: Bool) {
        lock.lock()
        held = on
        lock.unlock()
    }

    // MARK: What the pictures show (UI tests)

    /// Under `--ui-testing` each picture's middle is read (its luma: a test
    /// video whose brightness rises with time tells where it is), and the
    /// first ones of each media are looked at for text in their lower part
    /// (subtitles VLC blended in), written to the test log.
    private static let probing = TestSwitches.testLog != nil
    private static let probedFirst = 5
    private var lastProbePicture: PictureProbe?
    /// The media handed over so far (`use`).
    private var openings = 0

    struct PictureProbe: CustomStringConvertible {
        /// The mean luma of the picture's middle (8-bit code values).
        var luma: Int
        /// Text over the lower part: bright and dark pixels side by side.
        var text: Bool?
        /// Where it lies (pixels of the picture): the pixels that differ
        /// from the middle's brightness by more than 40.
        var box: (x0: Int, x1: Int, y0: Int, y1: Int)?
        var description: String {
            "luma \(luma)" + (text.map { $0 ? ", text" : ", no text" } ?? "")
                + (box.map { ", box \($0.x0) \($0.x1) \($0.y0) \($0.y1)" } ?? "")
        }
    }

    /// The last picture shown, as read (UI tests).
    var lastProbe: String {
        lock.lock()
        defer { lock.unlock() }
        return lastProbePicture.map(String.init(describing:)) ?? "none"
    }

    /// Reads a picture: the luma of its middle (8-bit NV12 as VLC handed it
    /// over), and in the picture as shown (`shown`: NV12, or BGRA with a look
    /// or a subtitle line of the app's own) whether it holds text (pixels
    /// away from the middle's even grey of the test videos, anywhere: ASS
    /// lines may lie at the top or at their `\pos`), and its box. Others are
    /// not read.
    static func probe(_ buffer: CVPixelBuffer, shown: CVPixelBuffer?) -> PictureProbe? {
        guard let luma = middleLuma(buffer) else { return nil }
        var probe = PictureProbe(luma: luma)
        if let shown { (probe.text, probe.box) = textBox(shown) }
        return probe
    }

    private static func isNV12(_ buffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private static func middleLuma(_ buffer: CVPixelBuffer) -> Int? {
        guard isNV12(buffer), CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width >= 16, height >= 16 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for y in height / 2 - 4 ..< height / 2 + 4 {
            for x in width / 2 - 4 ..< width / 2 + 4 { sum += Int(bytes[y * row + x]) }
        }
        return sum / 64
    }

    /// The brightness of an NV12 picture's luma or a BGRA picture's green.
    private static func textBox(_ buffer: CVPixelBuffer) -> (Bool?, (x0: Int, x1: Int, y0: Int, y1: Int)?) {
        let nv12 = isNV12(buffer)
        let bgra = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        guard nv12 || bgra, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return (nil, nil) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = nv12 ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        guard let base else { return (nil, nil) }
        let width = nv12 ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = nv12 ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let row = nv12 ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 16, height >= 16 else { return (nil, nil) }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        // Luma, or BGRA's green
        let stride = nv12 ? 1 : 4, offset = nv12 ? 0 : 1
        var sum = 0
        for y in height / 2 - 4 ..< height / 2 + 4 {
            for x in width / 2 - 4 ..< width / 2 + 4 { sum += Int(bytes[y * row + x * stride + offset]) }
        }
        let low = sum / 64 - 40, high = sum / 64 + 40
        var x0 = Int.max, x1 = -1, y0 = Int.max, y1 = -1, count = 0
        // Plain loops over the rows: it runs on VLC's output thread, in a debug build too
        for y in 0 ..< height {
            let line = bytes + y * row + offset
            var x = 0, first = -1, last = -1
            while x < width {
                let v = Int(line[x * stride])
                if v < low || v > high {
                    if first < 0 { first = x }
                    last = x
                    count += 1
                }
                x += 1
            }
            if first >= 0 {
                x0 = min(x0, first); x1 = max(x1, last)
                if y0 == Int.max { y0 = y }
                y1 = y
            }
        }
        guard count > 20 else { return (false, nil) }
        return (true, (x0, x1, y0, y1))
    }

    /// The settings to show the pictures with; a paused picture is drawn
    /// again with them.
    /// A subtitle line the app draws over the pictures (`SubtitleOverlay`),
    /// at the pictures' size; nil none. Drawn into a copy with the look.
    private var overlay: CIImage?

    /// The pictures' size as handed over (what an overlay is drawn at).
    var bufferSize: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return shownSize.map { (Int($0.width), Int($0.height)) }
    }

    /// The size VLC proposed for its pictures (its decoder's, with padding),
    /// which VLC lays subtitles out in (`SubtitleOverlay`).
    private var decodedSize: (width: Int, height: Int)?
    var proposedSize: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return decodedSize
    }
    /// A media handed over with a new format whose output VLC hasn't opened
    /// yet (`use(newFormat:)`): the sizes above are still the media's before
    /// (a media opened again in software pads its pictures otherwise than
    /// VideoToolbox did).
    private var formatPending = false
    var hasFormat: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !formatPending
    }

    /// `logging`: the next pictures with it are logged (UI tests).
    func setOverlay(_ new: CIImage?, logging: Int = 0) {
        lock.lock()
        overlay = new
        picturesToLog = max(picturesToLog, logging)
        redrawIfPaused()
    }

    func setLook(_ new: Look) {
        lock.lock()
        guard new != look else { lock.unlock(); return }
        look = new
        redrawIfPaused()
    }

    /// Called holding `lock`, which it gives up: the last picture drawn
    /// again with the look and overlay of now, unless VLC is showing
    /// pictures (the next one carries them) or a redraw is on its way.
    private func redrawIfPaused() {
        let paused = latest != nil && Date().timeIntervalSince(lastDisplay) > 0.15
        let queued = pendingRedraw != nil
        if paused { pendingRedraw = look }
        lock.unlock()
        guard paused, !queued else { return }
        redraw.async { [self] in
            lock.lock()
            let look = pendingRedraw
            pendingRedraw = nil
            let buffer = latest
            let number = sequence
            let overlay = self.overlay
            lock.unlock()
            if let look, let buffer { present(buffer, with: look, overlay: overlay, number: number) }
        }
    }

    /// Puts a picture on the layer, with the look applied (Core Image, on
    /// the GPU) unless it is neutral. A picture of more than 8 bits goes
    /// through the look in half floats in extended linear light, so an HDR
    /// picture keeps what lies beyond SDR white (Core Image reads PQ and HLG
    /// into values above 1).
    @discardableResult
    private func present(_ buffer: CVPixelBuffer, with look: Look, overlay: CIImage?, number: Int) -> CVPixelBuffer {
        var surfaceBuffer = buffer
        if !look.isNeutral || overlay != nil {
            lock.lock()
            let pool = lookPool
            lock.unlock()
            var out: CVPixelBuffer?
            if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
            if let out {
                let deep = CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_64RGBAHalf
                let space = deep ? extendedLinear : sRGB
                CVBufferSetAttachment(out, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
                let image = CIImage(cvPixelBuffer: buffer)
                var picture = look.isNeutral ? image : look.apply(to: image)
                if let overlay { picture = overlay.composited(over: picture) }
                // A subtitle line is laid over as VLC blends its own: on the
                // gamma-encoded values (a half-transparent shadow over grey
                // as dark as VLC's, not lighter as blended in linear light)
                let renderer = deep ? deepContext : overlay != nil && look.isNeutral ? overlayContext : context
                renderer.render(picture, to: out, bounds: image.extent, colorSpace: space)
                surfaceBuffer = out
            }
        }
        lock.lock()
        shown.append(surfaceBuffer)
        if shown.count > 4 { shown.removeFirst() }   // the compositor may still read the last ones
        lock.unlock()
        guard let surface = CVPixelBufferGetIOSurface(surfaceBuffer)?.takeUnretainedValue() else { return surfaceBuffer }
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
        return surfaceBuffer
    }

    /// What auto enhance measures: the picture as decoded, before the look;
    /// nil before the first. An HDR picture is measured tone-mapped to SDR
    /// (`CIToneMapHeadroom`), as on an SDR screen: its highlights would
    /// otherwise all count as white.
    var latestStats: PictureStats? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        if Self.isHDR(buffer), let toSDR = CIFilter(name: "CIToneMapHeadroom") {
            toSDR.setValue(image, forKey: kCIInputImageKey)
            toSDR.setValue(1, forKey: "inputTargetHeadroom")
            image = toSDR.outputImage ?? image
        }
        return PictureStats.of(image)
    }

    /// The last picture VLC showed, as decoded (tests).
    var latestPicture: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    static func isHDR(_ buffer: CVPixelBuffer) -> Bool {
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        return transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
    }

    /// A picture's format and colours, e.g. "P010 PQ 2020 matrix 2020
    /// mastering light level" (UI tests read it).
    static func describe(_ buffer: CVPixelBuffer) -> String {
        let format: String
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: format = "NV12"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: format = "P010"
        default: format = "other"
        }
        func attachment(_ key: CFString) -> String? { CVBufferCopyAttachment(buffer, key, nil) as? String }
        // Several of CoreVideo's constants are the same string ("ITU_R_709_2"
        // names BT.709's transfer, primaries and matrix), so a list, first match
        let names: [(CFString, String)] = [
            (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, "PQ"),
            (kCVImageBufferTransferFunction_ITU_R_2100_HLG, "HLG"),
            (kCVImageBufferTransferFunction_ITU_R_709_2, "709"),
            (kCVImageBufferColorPrimaries_ITU_R_2020, "2020"),
            (kCVImageBufferColorPrimaries_SMPTE_C, "601"),
            (kCVImageBufferColorPrimaries_P3_D65, "P3"),
            (kCVImageBufferYCbCrMatrix_ITU_R_2020, "2020"),
            (kCVImageBufferYCbCrMatrix_ITU_R_601_4, "601"),
        ]
        func name(_ key: CFString) -> String {
            guard let value = attachment(key) else { return "none" }
            return names.first { $0.0 as String == value }?.1 ?? value
        }
        var text = "\(format) \(name(kCVImageBufferTransferFunctionKey)) \(name(kCVImageBufferColorPrimariesKey)) "
            + "matrix \(name(kCVImageBufferYCbCrMatrixKey))"
        if CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) != nil { text += " mastering" }
        if CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) != nil { text += " light level" }
        return text
    }

    /// For UI tests: what the output did.
    var diagnostics: String {
        lock.lock()
        let perFrame = callbacks > 0 ? callbackSeconds / Double(callbacks) * 1000 : 0
        let picture = latest.map(Self.describe) ?? "none"
        let ofMedia = shownOfMedia, opened = openings
        lock.unlock()
        let edr = Thread.isMainThread ? (showsEDR ? "on" : "off") : "unknown"
        return "handover \(String(format: "%.2f", perFrame)) ms per picture, media \(opened), \(ofMedia) of this media, pictures \(picture), EDR \(edr)"
    }
}
