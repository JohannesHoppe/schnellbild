import SwiftUI
import AppKit
import ImageIO
import VLCFrames
import OfflineMap

/// The app's movements (scrolling to the selection, the mini keyboard
/// sliding in, a key lighting up, panning a zoomed picture): none while the
/// user asks for less motion (System Settings → Accessibility → Display →
/// Reduce motion); then things simply are where they go.
enum Motion {
    static var reduced: Bool { MapMotion.reduced }

    static func animation(_ animation: Animation) -> Animation? { reduced ? nil : animation }
}

/// Runs `work` off the main actor; cancelling the caller cancels it too, so
/// what it awaits (an archive read) stops, and it can skip what is left.
func detachedCancellable<T: Sendable>(priority: TaskPriority, _ work: @escaping @Sendable () async -> T) async -> T {
    let task = Task.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}

/// Shared ImageIO helpers.
enum MediaInfo {
    /// Pixel dimensions as shown, from an already-open image source (no
    /// extra file open): EXIF orientations 5 to 8 (a camera held upright)
    /// swap width and height, as the picture is shown turned.
    static func pixelSize(from source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Pixel dimensions, also of a picture inside an archive; for an SVG or
    /// PDF its own size.
    static func pixelSize(ofAnywhere url: URL) async -> CGSize? {
        if VectorPicture.isVector(url) { return await VectorPicture.size(of: url) }
        guard let source = await MediaData.imageSource(url) else { return nil }
        return pixelSize(from: source)
    }

    /// Picture `index` of `source` decoded with its longest side at most
    /// `maxPixel`, turned upright by its EXIF orientation: the picture
    /// itself, not the small preview a camera embeds. `now`: decoded at
    /// once (to be drawn), not when first drawn.
    static func scaledDown(_ source: CGImageSource, at index: Int, maxPixel: Int, now: Bool) -> CGImage? {
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        if now { options[kCGImageSourceShouldCacheImmediately] = true }
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// A bitmap for drawing a picture of `size` (points) with its longest
    /// side `longestSide` pixels: sRGB, 8 bits, transparent; nil for an
    /// empty or endless size.
    static func bitmap(for size: CGSize, longestSide: Int) -> CGContext? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let scale = CGFloat(max(longestSide, 1)) / max(size.width, size.height)
        return CGContext(data: nil, width: max(Int((size.width * scale).rounded()), 1), height: max(Int((size.height * scale).rounded()), 1),
                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

extension NSAlert {
    /// Asks `message` (with `detail` under it) with two buttons: true for
    /// `yes`, the first.
    @MainActor
    static func confirm(_ message: String, detail: String? = nil, yes: String, no: String = String(localized: "Cancel"),
                        warning: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        if warning { alert.alertStyle = .warning }
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension NSImage {
    /// The picture at one point per pixel.
    convenience init(pixels picture: CGImage) {
        self.init(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
    }
}

extension NSScreen {
    /// Backing scale of the main display, with a sane fallback.
    static var mainBackingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
    /// Backing scale of the display the app's window is on (100 % means
    /// one picture pixel per pixel there, also on a second display).
    @MainActor static var windowBackingScale: CGFloat { BrowserModel.appWindow?.backingScaleFactor ?? mainBackingScale }
}

/// The white loading spinner shown over the black full-size background.
struct LoadingSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
    }
}
