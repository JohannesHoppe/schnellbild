import SwiftUI
import AppKit
import ImageIO

/// Animated GIFs: `NSImageView` with `animates = true` plays them —
/// SwiftUI's `Image` shows only a still frame.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        context.coordinator.url = url
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        nsView.image = NSImage(contentsOf: url)
        nsView.animates = true
    }

    final class Coordinator {
        var url: URL?
    }
}

/// Small file inspector (key "i" in the full-size view).
struct InspectorView: View {
    let entry: GridEntry
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
        case .image: return "Image"
        case .video: return "Video"
        case .folder: return "Folder"
        case .parent: return "Parent"
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
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
        guard entry.kind == .image else { return }
        let url = entry.url
        dimensions = await Task.detached(priority: .utility) { () -> String? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
            return "\(w) × \(h) px"
        }.value
    }
}
