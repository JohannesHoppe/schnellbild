import SwiftUI
import QuickLookThumbnailing

/// Winziges In-Memory-Sicherheitsnetz, damit beim Scrollen nicht ständig neu
/// generiert wird. Der eigentliche, persistente Cache liegt im System
/// (QuickLook) — den fahren wir per `QLThumbnailGenerator` als Trittbrett mit.
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

/// Eine Kachel. Holt ihr Thumbnail vom System (eingebettete Previews, RAW/PSD/PDF
/// inklusive) und cached es in-memory.
struct ThumbnailView: View {
    let url: URL
    let side: CGFloat
    let isSelected: Bool

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))

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
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.image(for: url) {
            image = cached
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
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
