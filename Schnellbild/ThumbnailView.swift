import SwiftUI
import QuickLookThumbnailing

/// Tiny in-memory safety net so thumbnails aren't constantly regenerated
/// while scrolling. The real, persistent cache lives in the system
/// (QuickLook) — we piggyback on it via `QLThumbnailGenerator`.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Keyed by file and tile size, so a small folder preview never stands
    /// in for a full-size tile.
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 512
    }

    private func key(_ url: URL, _ side: CGFloat) -> NSString {
        "\(Int(side.rounded()))|\(url.path)" as NSString
    }

    func image(for url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side))
    }

    func store(_ image: NSImage, for url: URL, side: CGFloat) {
        cache.setObject(image, forKey: key(url, side))
    }

    /// The system thumbnail for a file (embedded previews, including
    /// RAW/PSD/PDF/video), from memory when available.
    func thumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        if let cached = image(for: url, side: side) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: NSScreen.mainBackingScale,
            representationTypes: .all
        )
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        store(rep.nsImage, for: url, side: side)
        return rep.nsImage
    }
}

/// A tile. Fetches its thumbnail from the system (embedded previews, including
/// RAW/PSD/PDF) and caches it in memory.
struct ThumbnailView: View {
    let url: URL
    let side: CGFloat
    let isSelected: Bool
    var isVideo: Bool = false

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        content
            .tileChrome(side: side, isSelected: isSelected)
            .overlay(alignment: .bottomTrailing) {
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 26))
                        .padding(6)
                }
            }
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(4)
        } else if failed {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func load() async {
        if let img = await ThumbnailCache.shared.thumbnail(for: url, side: side) {
            if !Task.isCancelled { image = img }
        } else if !Task.isCancelled {
            failed = true
        }
    }
}

/// Shared tile chrome: rounded background, fixed square frame, selection ring.
struct TileChrome: ViewModifier {
    let side: CGFloat
    let isSelected: Bool

    func body(content: Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            content
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
    }
}

extension View {
    func tileChrome(side: CGFloat, isSelected: Bool) -> some View {
        modifier(TileChrome(side: side, isSelected: isSelected))
    }
}
