import SwiftUI
import QuickLookThumbnailing

/// Tiny in-memory safety net so thumbnails aren't constantly regenerated
/// while scrolling. The real, persistent cache lives in the system
/// (QuickLook) — we piggyback on it via `QLThumbnailGenerator`.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 512
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
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
        if let cached = ThumbnailCache.shared.image(for: url) {
            image = cached
            return
        }
        let scale = NSScreen.mainBackingScale
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .all
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            ThumbnailCache.shared.store(rep.nsImage, for: url)
            if !Task.isCancelled { image = rep.nsImage }
        } catch {
            if !Task.isCancelled { failed = true }
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
