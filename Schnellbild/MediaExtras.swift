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
