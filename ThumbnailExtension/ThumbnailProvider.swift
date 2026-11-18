import AppKit
import ImageIO
import QuickLookThumbnailing
import VLCFrames

/// Thumbnails of the videos QuickLook can't read itself (MKV, WebM, WMV,
/// ASF, FLV, Ogg, VOB: the types in its `Info.plist`): VLC decodes a frame
/// at 30 % of the video; a file no VLC reader may open (`VLCSafety.reader`,
/// such as "setup.dmg.part") gets none at once. Downloads not
/// finished ("x.mp4.part", "x.jpg.crdownload", `DownloadName`) get theirs as
/// far as their data reaches: a picture through ImageIO, a video through
/// VLC. macOS asks for them (Finder, Schnellbild's grid) and keeps them in
/// its own thumbnail cache, so a video is read once, not every time a folder
/// is shown. Runs in the App Sandbox: it may read only the file macOS hands it.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override init() {
        VLCSafety.forgetInjectedOptions()
        super.init()
    }

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maximum = request.maximumSize
        let width = Int((maximum.width * request.scale).rounded())
        Task {
            var frame = Self.picture(of: url, width: width)
            if frame == nil { frame = await VLCFrameGrab.frame(of: url, width: width) }
            guard let frame else {
                return handler(nil, CocoaError(.fileReadCorruptFile))
            }
            // The largest size with the picture's sides that fits the request
            let fit = min(maximum.width / CGFloat(frame.width), maximum.height / CGFloat(frame.height))
            let size = CGSize(width: (CGFloat(frame.width) * fit).rounded(), height: (CGFloat(frame.height) * fit).rounded())
            handler(QLThumbnailReply(contextSize: size) { context in
                // The whole bitmap, whatever scale the context is set up with
                context.interpolationQuality = .high
                context.draw(frame, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                return true
            }, nil)
        }
    }

    /// A picture among the downloads not finished: ImageIO reads it by its
    /// content (QuickLook asks this extension only for the video formats it
    /// claims and for downloads in progress).
    private static func picture(of url: URL, width: Int) -> CGImage? {
        guard DownloadName.isPartial(url.lastPathComponent), let head = VLCSafety.head(of: url),
              let probe = CGImageSourceCreateWithData(head as CFData, nil), CGImageSourceGetType(probe) != nil,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, 16)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Never called. `swift test` links every executable target with its main
/// renamed to `<module>_main`; the extension has none (its entry point is
/// the system's `NSExtensionMain`, and the system's extension start calls
/// a `main` if there is one).
@_cdecl("SchnellbildThumbnails_main")
func testBuildMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 { 0 }
