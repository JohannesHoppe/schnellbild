import SwiftUI
import AppKit
import ImageIO

/// Runs `work` off the main actor; cancelling the caller cancels it too, so
/// what it awaits (an archive read) stops, and it can skip what is left.
func detachedCancellable<T: Sendable>(priority: TaskPriority, _ work: @escaping @Sendable () async -> T) async -> T {
    let task = Task.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}

/// A GIF in the full view: an animated one plays (`AnimatedImageView`); a
/// still one is a picture like any other (`FullImageView`: zoom, rotation,
/// auto enhance and the sliders).
struct GIFView: View {
    let url: URL
    /// Whether the GIF at `url` has more than one frame.
    @State private var animated: (url: URL, value: Bool)?

    var body: some View {
        Group {
            if let animated, animated.url == url {
                if animated.value {
                    ZStack { Color.black; AnimatedImageView(url: url) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("animatedImage")
                } else {
                    FullImageView(url: url)
                }
            } else {
                ZStack { Color.black; LoadingSpinner() }
            }
        }
        .task(id: url) {
            let url = self.url
            let frames = await detachedCancellable(priority: .userInitiated) {
                await MediaData.imageSource(url).map(CGImageSourceGetCount)
            }
            guard !Task.isCancelled else { return }
            // Unreadable: the picture view shows it can't be read
            animated = (url, (frames ?? 0) > 1)
        }
    }
}

/// Animated GIFs: `NSImageView` with `animates = true` plays them —
/// SwiftUI's `Image` shows only a still frame. The file is read off the main
/// thread (a large GIF on a slow share would freeze the app).
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        context.coordinator.show(url, in: view)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.show(url, in: nsView)
    }

    @MainActor
    final class Coordinator {
        var url: URL?
        private var loading: Task<Void, Never>?

        func show(_ url: URL, in view: NSImageView) {
            self.url = url
            view.image = nil
            loading?.cancel()
            loading = Task { [weak view] in
                let data = await detachedCancellable(priority: .userInitiated) { try? await MediaData.read(url) }
                guard !Task.isCancelled, self.url == url, let data else { return }
                view?.image = NSImage(data: data)
            }
        }
    }
}

/// Small file inspector (key "i" in the full-size view).
struct InspectorView: View {
    let entry: GridEntry
    @EnvironmentObject var model: BrowserModel
    @State private var dimensions: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.name)
                .font(.headline)
                .lineLimit(3)
            infoRow("Kind", kindText)
            if let dimensions {
                infoRow("Resolution", dimensions)
            }
            if let size = entry.byteSize {
                infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let date = entry.modDate {
                infoRow("Date Modified", date.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task(id: entry.url) { await loadDimensions() }
    }

    /// The inspector shows only what the full view shows: a picture or a video.
    private var kindText: String {
        entry.kind == .video ? String(localized: "Video") : String(localized: "Picture")
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func loadDimensions() async {
        dimensions = nil
        if entry.kind == .video {
            // The player knows it once the video has opened.
            for _ in 0..<40 {
                if model.activePlayerURL == entry.url,
                   let size = model.activePlayer?.videoSize, size.width > 0, size.height > 0 {
                    dimensions = "\(Int(size.width)) × \(Int(size.height)) px"
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            return
        }
        guard entry.kind == .image else { return }
        let url = entry.url
        let found = await detachedCancellable(priority: .utility) { () -> String? in
            guard let size = await MediaInfo.pixelSize(ofAnywhere: url) else { return nil }
            // An SVG states its size as it likes ("1e20")
            guard size.width.isFinite, size.height.isFinite else { return nil }
            return "\(Int(max(0, min(size.width, 1e15)))) × \(Int(max(0, min(size.height, 1e15)))) px"
        }
        // Paged on meanwhile: the next picture's size is on its way
        guard !Task.isCancelled else { return }
        dimensions = found
    }
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
