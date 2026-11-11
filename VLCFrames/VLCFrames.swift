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

    /// The `libvlc_media_player_t` inside a VLCMediaPlayer.
    public static func nativePlayer(of player: VLCMediaPlayer) -> OpaquePointer? {
        let selector = NSSelectorFromString("libVLCMediaPlayer")
        guard player.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> OpaquePointer?
        return unsafeBitCast(player.method(for: selector), to: Getter.self)(player, selector)
    }
}

/// One picture of a video, for a tile: VLC decodes a frame at `position` of
/// the video into memory. Every libVLC call runs on the grab's own queue and
/// the callbacks never wait for the main thread: stopping a player holds its
/// lock until its threads have ended, so a picture callback waiting for the
/// main thread while the main thread asks that player anything would hang
/// both (VLCKit's own `VLCMediaThumbnailer` waits for the main thread so).
public final class VLCFrameGrab: @unchecked Sendable {   // state behind `lock`
    private let queue = DispatchQueue(label: "VLCFrameGrab", qos: .utility)
    private let lock = NSLock()
    private let wantedWidth: Int
    private var done: ((CGImage?) -> Void)?
    private var player: VLCMediaPlayer?
    private var pixels: UnsafeMutableRawPointer?
    private var size = (width: 0, height: 0)

    private var finished = false

    private init(width: Int) {
        wantedWidth = max(16, width)
    }

    deinit { pixels?.deallocate() }

    /// A frame `width` pixels wide (the height follows the video), or nil
    /// after `timeout` seconds or when cancelled.
    public static func frame(of url: URL, width: Int, at position: Double = 0.3, timeout: Double = 10) async -> CGImage? {
        let grab = VLCFrameGrab(width: width)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                grab.lock.lock()
                let cancelled = grab.finished
                if !cancelled { grab.done = { continuation.resume(returning: $0) } }
                grab.lock.unlock()
                guard !cancelled else { return continuation.resume(returning: nil) }
                grab.queue.async { grab.start(url: url, position: position) }
                grab.queue.asyncAfter(deadline: .now() + timeout) { grab.finish(with: nil) }
            }
        } onCancel: {
            grab.finish(with: nil)
        }
    }

    private func start(url: URL, position: Double) {
        lock.lock()
        let over = finished
        lock.unlock()
        guard !over, let api = LibVLCVideo.shared else { return finish(with: nil) }
        let media = VLCMedia(url: url)
        VLCSafety.restrict(media, for: url)
        for option in [":no-audio", ":no-spu", ":no-osd", ":avcodec-threads=1", ":avcodec-skip-idct=4",
                       ":avcodec-skiploopfilter=3", ":deinterlace=-1", ":avi-index=3"] {
            media.addOption(option)
        }
        // Where to start: VLC reads the length from the file (no main thread
        // involved); without one the first picture
        let length = media.lengthWait(until: Date().addingTimeInterval(3)).intValue
        if length > 0 { media.addOption(":start-time=\(Double(length) / 1000 * position)") }
        let player = VLCMediaPlayer()
        player.media = media
        guard let native = LibVLCVideo.nativePlayer(of: player) else { return finish(with: nil) }
        lock.lock()
        self.player = player
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
    }

    /// RGBA at the wanted width, the height by the decoded picture's sides.
    private func setUp(chroma: UnsafeMutablePointer<CChar>, width: UnsafeMutablePointer<UInt32>,
                       height: UnsafeMutablePointer<UInt32>, pitches: UnsafeMutablePointer<UInt32>,
                       lines: UnsafeMutablePointer<UInt32>) -> UInt32 {
        guard width.pointee > 0, height.pointee > 0 else { return 0 }
        let w = min(wantedWidth, 4096)
        let h = max(2, min(4096, Int((Double(height.pointee) * Double(w) / Double(width.pointee)).rounded())))
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
        _ = Unmanaged.passUnretained(self).retain()
        return 1
    }

    private func lockPicture(_ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        planes?.pointee = pixels
        return nil
    }

    /// The first picture shown is the frame.
    private func pictureDone() {
        lock.lock()
        let image = finished ? nil : makeImage()
        lock.unlock()
        if let image { finish(with: image) }
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
    private func finish(with image: CGImage?) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let answer = done
        done = nil
        lock.unlock()
        answer?(image)
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
/// a thumbnail. So the file's extension names the one reader VLC may use.
/// One, not a list: VLC takes a reader it is told to use as forced, and some
/// (MPEG program and transport streams) then take any file, so every reader
/// after them in a list would never be asked.
public enum VLCSafety {
    /// The reader for a file's extension, and FFmpeg's format where FFmpeg
    /// reads it (held to that one format, so FFmpeg can't pick a playlist
    /// reader either); nil: VLC opens nothing.
    public static func reader(for url: URL) -> (demux: String, ffmpegFormat: String?)? {
        switch url.pathExtension.lowercased() {
        case "mkv", "webm":                                  return ("mkv", nil)
        case "avi":                                          return ("avi", nil)
        case "mp4", "m4v", "mov", "qt", "3gp", "3g2":        return ("mp4", nil)
        case "mpg", "mpeg", "vob":                           return ("ps", nil)
        case "ts", "m2ts", "mts":                            return ("ts", nil)
        case "m2v":                                          return ("mpgv", nil)   // an MPEG video stream on its own
        case "wmv", "asf":                                   return ("asf", nil)
        case "ogv", "ogg":                                   return ("ogg", nil)
        case "dv":                                           return ("rawdv", nil)
        case "flv":                                          return ("avformat", "flv")
        default:                                             return nil
        }
    }

    /// `url` names the file (for a video inside an archive: its path through
    /// the archive).
    public static func restrict(_ media: VLCMedia, for url: URL) {
        if let reader = reader(for: url) {
            media.addOption(":demux=\(reader.demux),none")
            if let format = reader.ffmpegFormat { media.addOption(":avformat-format=\(format)") }
        } else {
            media.addOption(":demux=none")
        }
        // No subtitles or other files picked up from next to the video
        media.addOption(":no-sub-autodetect-file")
    }

    /// VLCKit reads extra libVLC options from the app's preferences
    /// ("VLCParams"); another program could put some there. Removed before
    /// VLC starts.
    public static func forgetInjectedOptions(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "VLCParams")
    }
}
