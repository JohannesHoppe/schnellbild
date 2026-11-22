// The parts of VLC that the app and its QuickLook thumbnail extension share:
// libVLC's video callbacks, one frame of a video for a thumbnail, and what VLC
// may do with a file someone else made.
import AppKit
import VLCKit

/// libVLC's video callback functions, looked up in VLCKit at run time.
public struct LibVLCVideo {
    public typealias Lock = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?
    public typealias Unlock = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?) -> Void
    public typealias Display = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    public typealias Format = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<CChar>?,
                                       UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                                       UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32
    public typealias Cleanup = @convention(c) (UnsafeMutableRawPointer?) -> Void

    public let setCallbacks: @convention(c) (OpaquePointer, Lock, Unlock, Display, UnsafeMutableRawPointer?) -> Void
    public let setFormatCallbacks: @convention(c) (OpaquePointer, Format, Cleanup) -> Void

    public static let shared: LibVLCVideo? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let callbacks = dlsym(handle, "libvlc_video_set_callbacks"),
              let format = dlsym(handle, "libvlc_video_set_format_callbacks") else { return nil }
        return LibVLCVideo(setCallbacks: unsafeBitCast(callbacks, to: (@convention(c) (OpaquePointer, Lock, Unlock, Display, UnsafeMutableRawPointer?) -> Void).self),
                           setFormatCallbacks: unsafeBitCast(format, to: (@convention(c) (OpaquePointer, Format, Cleanup) -> Void).self))
    }()

    /// `libvlc_media_player_get_state`: libVLC's state of a player
    /// (`libvlc_state_t`), asked on any thread, without VLCKit's
    /// notifications, which come on the main thread.
    public static let playerState: (@convention(c) (OpaquePointer) -> Int32)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "libvlc_media_player_get_state") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (OpaquePointer) -> Int32).self)
    }()

    /// `libvlc_state_t`'s values for a player that is done: stopped, ended,
    /// failed.
    public static let stopped: Int32 = 5, ended: Int32 = 6, failed: Int32 = 7

    /// VLC's chromas of more than 8 bits per sample (`vlc_fourcc.h`):
    /// VideoToolbox's 10-bit pictures, P010, and the planar YUV and RGB
    /// ones with 9, 10, 12 or 16 bits.
    public static func isDeep(chroma: String) -> Bool {
        if chroma == "CVPP" || chroma == "P010" { return true }
        let c = Array(chroma)
        guard c.count == 4 else { return false }
        if ["I0", "I2", "I4"].contains(String(c[0...1])), "9ACF".contains(c[2]), "LB".contains(c[3]) { return true }
        return chroma.hasPrefix("GB") && "9ACF".contains(c[2]) && "LB".contains(c[3])
    }

    /// The `libvlc_media_player_t` inside a VLCMediaPlayer.
    public static func nativePlayer(of player: VLCMediaPlayer) -> OpaquePointer? {
        let selector = NSSelectorFromString("libVLCMediaPlayer")
        guard player.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> OpaquePointer?
        return unsafeBitCast(player.method(for: selector), to: Getter.self)(player, selector)
    }
}

/// One picture of a video, for a tile: VLC decodes a frame at `position`
/// (30 %) of the video into memory. Every libVLC call runs on the grab's own queue and
/// the callbacks never wait for the main thread: stopping a player holds its
/// lock until its threads have ended, so a picture callback waiting for the
/// main thread while the main thread asks that player anything would hang
/// both (VLCKit's own `VLCMediaThumbnailer` waits for the main thread so).
/// A file VLC may not open (`VLCSafety.reader`) gets no player at all; a
/// player that fails or reaches the end without a picture (a file with no
/// video, a broken one) ends the grab at once, not at its timeout.
public final class VLCFrameGrab: @unchecked Sendable {   // state behind `lock`
    /// How a grab ended.
    public enum Outcome: CustomStringConvertible {
        case frame(CGImage)
        /// VLC wasn't asked: no reader may open the file (`VLCSafety`).
        case refused
        /// VLC opened it and failed (`failed`) or got to its end
        /// (`ended`, `stopped`) without a picture.
        case failed(String)
        case timedOut
        case cancelled

        public var image: CGImage? {
            if case .frame(let image) = self { return image }
            return nil
        }

        public var description: String {
            switch self {
            case .frame(let image): return "a frame \(image.width)×\(image.height)"
            case .refused:          return "refused"
            case .failed(let why):  return "failed (\(why))"
            case .timedOut:         return "timed out"
            case .cancelled:        return "cancelled"
            }
        }
    }
    /// How long a player reported as done may still bring its last picture.
    private static let lastPictureWait = 0.5

    private let queue = DispatchQueue(label: "VLCFrameGrab", qos: .utility)
    private let lock = NSLock()
    private let wantedWidth: Int
    private var done: ((Outcome) -> Void)?
    private var player: VLCMediaPlayer?
    private var pixels: UnsafeMutableRawPointer?
    private var size = (width: 0, height: 0)
    /// The media grabbed from, for its visible size.
    private var media: VLCMedia?
    /// The size was the decoder's buffer's (the visible one not known yet):
    /// VLC scaled the visible part into it, and the picture is brought to
    /// the visible shape once VLC states it.
    private var sizeFromBuffer = false
    /// The decoder's pictures have more than 8 bits per sample
    /// (`LibVLCVideo.isDeep`): HDR, or SDR when VLC says so.
    private var deep = false
    /// More than 576 visible rows: BT.709's colours, else BT.601's.
    private var hd = false

    private var finished = false

    private init(width: Int) {
        wantedWidth = max(16, width)
    }

    deinit { pixels?.deallocate() }

    /// Where in the video the frame is taken, as a share of its length.
    private static let position = 0.3

    /// A frame `width` pixels wide (the height follows the video), or nil
    /// (see `grab`).
    public static func frame(of url: URL, width: Int, timeout: Double = 10) async -> CGImage? {
        await grab(of: url, width: width, timeout: timeout).image
    }

    /// A frame `width` pixels wide, or why there is none: refused, VLC
    /// failed or ended without one, `timeout` seconds passed, cancelled.
    public static func grab(of url: URL, width: Int, timeout: Double = 10) async -> Outcome {
        let grab = VLCFrameGrab(width: width)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                grab.lock.lock()
                let cancelled = grab.finished
                if !cancelled { grab.done = { continuation.resume(returning: $0) } }
                grab.lock.unlock()
                guard !cancelled else { return continuation.resume(returning: .cancelled) }
                grab.queue.async { grab.start(url: url) }
                grab.queue.asyncAfter(deadline: .now() + timeout) { grab.finish(with: .timedOut) }
            }
        } onCancel: {
            grab.finish(with: .cancelled)
        }
    }

    private func start(url: URL) {
        lock.lock()
        let over = finished
        lock.unlock()
        guard !over, let api = LibVLCVideo.shared else { return finish(with: .failed("no libVLC")) }
        let head = VLCSafety.head(of: url)
        // No reader may open it (`:demux=none`): no picture can come
        guard VLCSafety.reader(for: url, head: head) != nil else { return finish(with: .refused) }
        let media = VLCMedia(url: url)
        VLCSafety.restrict(media, for: url, head: head)
        // `:no-play-and-pause`: at its end the player ends (VLCKit's default
        // would pause it there), which ends a grab without a picture at once
        for option in [":no-audio", ":no-spu", ":no-osd", ":no-play-and-pause", ":avcodec-threads=1", ":avcodec-skip-idct=4",
                       ":avcodec-skiploopfilter=3", ":deinterlace=-1", ":avi-index=3"] {
            media.addOption(option)
        }
        // Where to start: VLC reads the length from the file (no main thread
        // involved); without one the first picture
        let length = media.lengthWait(until: Date().addingTimeInterval(3)).intValue
        if length > 0 { media.addOption(":start-time=\(Double(length) / 1000 * Self.position)") }
        let player = VLCMediaPlayer()
        player.media = media
        guard let native = LibVLCVideo.nativePlayer(of: player) else { return finish(with: .failed("no native player")) }
        lock.lock()
        self.player = player
        self.media = media
        lock.unlock()
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        api.setCallbacks(native, { opaque, planes in
            Unmanaged<VLCFrameGrab>.fromOpaque(opaque!).takeUnretainedValue().lockPicture(planes)
        }, { _, _, _ in
        }, { opaque, _ in
            Unmanaged<VLCFrameGrab>.fromOpaque(opaque!).takeUnretainedValue().pictureDone()
        }, opaque)
        // The video output holds the grab while it is open (released by the
        // cleanup callback), so a late callback never reaches a freed object
        api.setFormatCallbacks(native, { opaque, chroma, width, height, pitches, lines in
            Unmanaged<VLCFrameGrab>.fromOpaque(opaque!.pointee!).takeUnretainedValue()
                .setUp(chroma: chroma!, width: width!, height: height!, pitches: pitches!, lines: lines!)
        }, { opaque in
            Unmanaged<VLCFrameGrab>.fromOpaque(opaque!).release()
        })
        player.play()
        watch(native, doneSince: nil)
    }

    /// Looks at the player's state every 50 ms on the grab's queue (the
    /// player stays while the grab isn't finished: `finish` stops it on this
    /// queue): failed, it ends the grab; ended or stopped, after
    /// `lastPictureWait` (a picture VLC decoded may still be on its way).
    private func watch(_ native: OpaquePointer, doneSince: Date?) {
        guard let state = LibVLCVideo.playerState else { return }
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            lock.lock()
            let over = finished
            lock.unlock()
            guard !over else { return }
            let now = state(native)
            if now == LibVLCVideo.failed { return finish(with: .failed("error")) }
            guard now == LibVLCVideo.ended || now == LibVLCVideo.stopped else { return watch(native, doneSince: nil) }
            let since = doneSince ?? Date()
            if Date().timeIntervalSince(since) >= Self.lastPictureWait {
                return finish(with: .failed(now == LibVLCVideo.ended ? "ended" : "stopped"))
            }
            watch(native, doneSince: since)
        }
    }

    /// RGBA at the wanted width, the height by the picture's visible shape:
    /// VLC's size here is the decoder's buffer, often padded (240 rows decode
    /// into 256), and VLC scales the visible part to the size set here; so
    /// the track's visible size (its pixels made square) decides, the
    /// buffer's only while it isn't known. The source's chroma and visible
    /// height decide the colours it is shown with (`pictureDone`).
    private func setUp(chroma: UnsafeMutablePointer<CChar>, width: UnsafeMutablePointer<UInt32>,
                       height: UnsafeMutablePointer<UInt32>, pitches: UnsafeMutablePointer<UInt32>,
                       lines: UnsafeMutablePointer<UInt32>) -> UInt32 {
        guard width.pointee > 0, height.pointee > 0 else { return 0 }
        lock.lock()
        let media = self.media
        lock.unlock()
        let source = String(decoding: (0..<4).map { UInt8(bitPattern: chroma[$0]) }, as: UTF8.self)
        var shape = (width: Double(width.pointee), height: Double(height.pointee))
        // The visible height as `VLCFrameOutput` takes it: the track's when it
        // fits in what VLC decodes, else VLC's own
        var visibleHeight = Int(height.pointee)
        let track = media.flatMap(LibVLCVideo.visibleTrack(of:))
        if var track {
            // VLC hands over an upright picture of a video stored turned
            if (track.width > track.height) != (shape.width > shape.height), track.width != track.height {
                swap(&track.width, &track.height)
                track.sampleAspect = 1 / track.sampleAspect
            }
            if track.width <= Int(width.pointee), track.height <= Int(height.pointee) { visibleHeight = track.height }
            let aspect = track.sampleAspect.isFinite && track.sampleAspect > 0 ? min(max(track.sampleAspect, 0.25), 4) : 1
            shape = (Double(track.width) * aspect, Double(track.height))
        }
        let w = min(wantedWidth, 4096)
        let h = max(2, min(4096, Int((shape.height * Double(w) / shape.width).rounded())))
        for (i, c) in "RGBA".utf8.enumerated() { chroma[i] = CChar(bitPattern: c) }
        width.pointee = UInt32(w)
        height.pointee = UInt32(h)
        pitches[0] = UInt32(w * 4)
        lines[0] = UInt32(h)
        lock.lock()
        defer { lock.unlock() }
        pixels?.deallocate()
        pixels = UnsafeMutableRawPointer.allocate(byteCount: w * 4 * h, alignment: 16)
        size = (w, h)
        sizeFromBuffer = track == nil
        deep = LibVLCVideo.isDeep(chroma: source)
        hd = VideoColour.isHD(visibleHeight: visibleHeight)
        _ = Unmanaged.passUnretained(self).retain()
        return 1
    }

    private func lockPicture(_ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        planes?.pointee = pixels
        return nil
    }

    /// The first picture shown is the frame, in the colours the full view
    /// shows: VLC's RGB is the video's own, which `VLCFrameOutput` hands to
    /// the screen tagged with the video's colours (`VideoColour`), so it is
    /// converted to sRGB from the colour space those make. An HDR picture
    /// (and one of more than 8 bits whose colours VLC doesn't state) is
    /// taken as VLC's RGB is.
    private func pictureDone() {
        lock.lock()
        let image = finished ? nil : makeImage()
        let fromBuffer = sizeFromBuffer, media = self.media, deep = self.deep, hd = self.hd
        lock.unlock()
        guard let image else { return }
        // Made at the buffer's shape: brought to the visible one VLC states by now
        var visible: (width: Int, height: Int)?
        if fromBuffer, let media, let resolution = LibVLCVideo.resolution(of: media),
           let buffer = resolution.buffer, buffer != resolution.visible {
            visible = resolution.visible
        }
        let sdr = !deep || media.flatMap(LibVLCVideo.colour(of:)).map { !$0.isHDR } == true
        finish(with: .frame(Self.shown(image, in: sdr ? VideoColour.sdrColourSpace(hd: hd) : nil, visible: visible)))
    }

    /// The picture in sRGB from `colourSpace` (nil: as it is), at the
    /// wanted width with the visible size's shape (nil: as it is).
    private static func shown(_ picture: CGImage, in colourSpace: CGColorSpace?, visible: (width: Int, height: Int)?) -> CGImage {
        let w = picture.width
        let h = visible.map { max(2, Int((Double($0.height) * Double(w) / Double($0.width)).rounded())) } ?? picture.height
        guard colourSpace != nil || h != picture.height,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return picture }
        context.interpolationQuality = .high
        context.draw(colourSpace.flatMap(picture.copy(colorSpace:)) ?? picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? picture
    }

    /// (`lock` held)
    private func makeImage() -> CGImage? {
        guard let pixels, size.width > 0 else { return nil }
        let data = Data(bytes: pixels, count: size.width * 4 * size.height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Answers once, then stops the player on the grab's queue (waiting
    /// there for VLC's threads, which wait for nothing here).
    private func finish(with outcome: Outcome) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let answer = done
        done = nil
        lock.unlock()
        answer?(outcome)
        // The pixels stay until the grab goes: the video output holds it
        // while it may still write into them
        queue.async { [self] in
            lock.lock()
            let player = self.player
            self.player = nil
            lock.unlock()
            player?.stop()
        }
    }
}

/// What VLC may do with a file someone else made. VLC picks its reader by
/// the content, not the name: a file named "video.mkv" that is really a
/// streaming playlist (HLS) would make it fetch from the internet, also for
/// a thumbnail. So VLC is told the one reader it may use: the container the
/// file's first bytes show (a recording named ".mkv" that is a transport
/// stream), from a fixed list of video containers, else the one its
/// extension names (a download's in-progress ending left out: "x.mkv.part"
/// is read as ".mkv"); a file whose bytes show none of them and whose
/// extension names no video opens nothing.
/// One, not a list: VLC takes a reader it is told to use as forced, and some
/// (MPEG program and transport streams) then take any file, so every reader
/// after them in a list would never be asked.
public enum VLCSafety {
    public typealias Reader = (demux: String, ffmpegFormat: String?)

    /// The reader for a file, and FFmpeg's format where FFmpeg reads it
    /// (held to that one format, so FFmpeg can't pick a playlist reader
    /// either); nil: VLC opens nothing. `head`: the file's first bytes.
    public static func reader(for url: URL, head: Data? = nil) -> Reader? {
        // What the content shows wins: none of these readers follows a
        // playlist or an address
        if let shown = head.flatMap(container(in:)) { return shown }
        return reader(forExtension: DownloadName.finalExtension(of: url))
    }

    /// The video container its first bytes show; nil when they show none
    /// of them (a playlist, text, anything else).
    public static func container(in head: Data) -> Reader? {
        let b = [UInt8](head.prefix(400))
        func at(_ i: Int, _ bytes: [UInt8]) -> Bool { b.count >= i + bytes.count && Array(b[i..<i + bytes.count]) == bytes }
        func ascii(_ i: Int, _ text: String) -> Bool { at(i, Array(text.utf8)) }
        if at(0, [0x1A, 0x45, 0xDF, 0xA3]) { return ("mkv", nil) }
        // Transport streams: a sync byte every 188 bytes, or every 192 after a 4-byte time code
        if b.count >= 377, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 { return ("ts", nil) }
        if b.count >= 389, b[4] == 0x47, b[196] == 0x47, b[388] == 0x47 { return ("ts", nil) }
        // F4V (Flash video in an MP4 box structure, its brand "f4v "): VLC's
        // MP4 reader refuses it (modules/demux/mp4/mp4.c), FFmpeg's reads it
        if ascii(4, "ftyp"), ascii(8, "f4v") { return ("avformat", "mov") }
        if ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(where: { ascii(4, $0) }) { return ("mp4", nil) }
        if ascii(0, "RIFF"), ascii(8, "AVI ") { return ("avi", nil) }
        if at(0, [0x00, 0x00, 0x01, 0xBA]) { return ("ps", nil) }
        if at(0, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) { return ("asf", nil) }
        if ascii(0, "FLV") { return ("avformat", "flv") }
        if ascii(0, "OggS") { return ("ogg", nil) }
        // RealMedia (".RMF") and MXF (the header partition pack's key,
        // SMPTE 377M) through FFmpeg, held to that one format
        if ascii(0, ".RMF") { return ("avformat", "rm") }
        if at(0, [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02]) { return ("avformat", "mxf") }
        return nil
    }

    /// A file's first bytes (nil: none to read, e.g. a path through an archive).
    public static func head(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 512)
    }

    static func reader(forExtension ext: String) -> Reader? {
        switch ext.lowercased() {
        case "mkv", "webm":                                  return ("mkv", nil)
        case "avi", "divx":                                  return ("avi", nil)
        // Insta360's ".insv" and GoPro MAX's ".360" are MP4 files
        case "mp4", "m4v", "mov", "qt", "3gp", "3g2", "insv", "360": return ("mp4", nil)
        case "f4v":                                          return ("avformat", "mov")
        case "mpg", "mpeg", "vob":                           return ("ps", nil)
        case "ts", "m2ts", "mts", "m2t":                     return ("ts", nil)
        case "m2v", "m1v":                                   return ("mpgv", nil)   // an MPEG video stream on its own
        case "wmv", "asf":                                   return ("asf", nil)
        case "ogv", "ogg", "ogm":                            return ("ogg", nil)
        case "dv":                                           return ("rawdv", nil)
        case "flv":                                          return ("avformat", "flv")
        case "rm", "rmvb":                                   return ("avformat", "rm")
        case "mxf":                                          return ("avformat", "mxf")
        default:                                             return nil
        }
    }

    /// `url` names the file (for a video inside an archive: its path through
    /// the archive).
    public static func restrict(_ media: VLCMedia, for url: URL, head: Data? = nil) {
        if let reader = reader(for: url, head: head) {
            media.addOption(":demux=\(reader.demux),none")
            if let format = reader.ffmpegFormat { media.addOption(":avformat-format=\(format)") }
        } else {
            media.addOption(":demux=none")
        }
        // No subtitles or other files picked up from next to the video, and
        // no other Matroska files of its folder opened in search of linked
        // segments
        media.addOption(":no-sub-autodetect-file")
        media.addOption(":no-mkv-preload-local-dir")
        // Matroska's chapter codecs are DVD-style menu programs inside the
        // file, which VLC would run
        media.addOption(":no-mkv-use-chapter-codec")
    }

    /// The libVLC options VLCKit starts its shared `VLCLibrary` with on macOS
    /// (`-[VLCLibrary _defaultOptions]`, VLCKit 3.7.5) when its preference
    /// "VLCParams" holds none. A second `VLCLibrary` would lack them and play
    /// nothing, so the shared one gets exactly these.
    public static let libraryOptions = [
        "--play-and-pause", "--no-color", "--no-video-title-show", "--verbose=4", "--no-sout-keep",
        "--vout=macosx", "--text-renderer=freetype", "--extraintf=macosx_dialog_provider",
        "--audio-resampler=soxr",
    ]

    /// VLCKit takes its libVLC options from the preference "VLCParams",
    /// read through `UserDefaults.standard`: the command line's arguments,
    /// then the app's own preferences, then the global domain, which any
    /// local program can write to. Before VLC starts, the app's own domain
    /// gets `libraryOptions` (it is read before the global domain) and a
    /// value from the command line is dropped, so no other value takes effect.
    public static func forgetInjectedOptions(in defaults: UserDefaults = .standard) {
        let key = "VLCParams"
        defaults.set(libraryOptions, forKey: key)
        let arguments = UserDefaults.argumentDomain
        var domain = defaults.volatileDomain(forName: arguments)
        if domain[key] != nil {
            domain[key] = nil
            defaults.removeVolatileDomain(forName: arguments)
            defaults.setVolatileDomain(domain, forName: arguments)
        }
    }
}
