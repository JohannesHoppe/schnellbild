import SwiftUI
import AppKit
import ImageIO

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
                let data = await Task.detached(priority: .userInitiated) { try? await MediaData.read(url) }.value
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
            infoRow("Type", kindText)
            if let dimensions {
                infoRow("Resolution", dimensions)
            }
            if let size = entry.byteSize {
                infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let date = entry.modDate {
                infoRow("Modified", date.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task(id: entry.url) { await loadDimensions() }
    }

    private var kindText: String {
        switch entry.kind {
        case .image: return String(localized: "Image")
        case .video: return String(localized: "Video")
        case .folder: return String(localized: "Folder")
        case .parent: return String(localized: "Parent")
        }
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
                if let size = model.activePlayer?.videoSize, size.width > 0, size.height > 0 {
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
        dimensions = await Task.detached(priority: .utility) { () -> String? in
            guard let size = await MediaInfo.pixelSize(ofAnywhere: url) else { return nil }
            return "\(Int(size.width)) × \(Int(size.height)) px"
        }.value
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

    /// Pixel dimensions, also of a picture inside an archive.
    static func pixelSize(ofAnywhere url: URL) async -> CGSize? {
        guard ArchivePath.isInside(url) else { return pixelSize(of: url) }
        if VectorPicture.isVector(url) {
            guard let data = try? await MediaData.read(url), let image = NSImage(data: data) else { return nil }
            return image.size
        }
        guard let source = await MediaData.imageSource(url) else { return nil }
        return pixelSize(from: source)
    }

    /// Pixel dimensions for a file URL; for an SVG its own size.
    static func pixelSize(of url: URL) -> CGSize? {
        if VectorPicture.isVector(url) { return VectorPicture.size(of: url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(from: source)
    }
}

extension NSScreen {
    /// Backing scale of the main display, with a sane fallback.
    static var mainBackingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
}

/// The white loading spinner shown over the black full-size background.
struct LoadingSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
    }
}
