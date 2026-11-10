import SwiftUI
import QuickLookThumbnailing

/// Tiny in-memory safety net so thumbnails aren't constantly regenerated
/// while scrolling. The real, persistent cache lives in the system
/// (QuickLook) — we piggyback on it via `QLThumbnailGenerator`.
@MainActor
final class ThumbnailCache {
    /// Grid tiles; the full-size view uses these as its placeholder.
    static let shared = ThumbnailCache(limit: 512)
    /// The small images fanned over folder tiles, kept apart so they don't
    /// push tile thumbnails out.
    static let previews = ThumbnailCache(limit: 512)

    /// One image per file, with the tile size it was made for and the
    /// file's modification date then (a file changed since gets a new one).
    private final class Entry {
        let image: NSImage
        let side: CGFloat
        let modified: Date?
        init(image: NSImage, side: CGFloat, modified: Date?) {
            self.image = image; self.side = side; self.modified = modified
        }
    }
    private let cache = NSCache<NSURL, Entry>()

    init(limit: Int) {
        cache.countLimit = limit
    }

    /// Marks an image that is only the file's icon, not a picture of it.
    static let fileIcon = "file icon"

    /// Any cached image of the file, whatever size it was made for.
    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    /// The system thumbnail for a file (embedded previews, including
    /// RAW/PSD/PDF/video), from memory when the cached one is at least
    /// `side` big — so a smaller tile size reuses it, and a larger one gets
    /// a sharper one. `modified` is the file's date as listed: a file
    /// changed in another app since gets a fresh thumbnail.
    func thumbnail(for url: URL, side: CGFloat, modified: Date? = nil) async -> NSImage? {
        // Inside an archive: the archive file's date (an entry may have none,
        // and a replaced archive can hold other pictures under the same names)
        let archive = ArchivePath.isInside(url) ? ArchivePath.split(url)?.archive : nil
        let modified = await archive.asyncMap(archiveDate(of:)) ?? modified
        if let cached = cache.object(forKey: url as NSURL), cached.side >= side,
           modified == nil || cached.modified == modified { return cached.image }
        if archive != nil {
            guard let image = await Self.archiveThumbnail(for: url, side: side), !Task.isCancelled else { return nil }
            cache.setObject(Entry(image: image, side: side, modified: modified), forKey: url as NSURL)
            return image
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: NSScreen.mainBackingScale,
            representationTypes: .all
        )
        // Cancelled with its tile (scrolled away), so QuickLook works on the
        // tiles still shown; a cancelled request answers with the file's
        // icon, which is never kept
        let rep = await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
        guard !Task.isCancelled else { return nil }
        var image = rep?.nsImage
        if rep?.type == .icon { image?.accessibilityDescription = Self.fileIcon }
        // QuickLook has only the file icon for videos it can't read (AVI,
        // MKV …); VLC, which plays them, makes the frame.
        if rep?.type != .thumbnail, BrowserModel.mediaKind(of: url) == .video, !Task.isCancelled,
           let frame = await VLCThumbnails.shared.thumbnail(for: url, width: side * NSScreen.mainBackingScale) {
            image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        }
        guard let image, !Task.isCancelled else { return nil }
        cache.setObject(Entry(image: image, side: side, modified: modified), forKey: url as NSURL)
        return image
    }

    /// Archive dates as read lately: every picture of an archive asks, and
    /// the date is read off the main thread (a stalled share would block it).
    private var archiveDates: [URL: (date: Date?, read: Date)] = [:]

    private func archiveDate(of archive: URL) async -> Date? {
        if let known = archiveDates[archive], Date().timeIntervalSince(known.read) < 2 { return known.date }
        let date = await Task.detached(priority: .utility) {
            (try? archive.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.value
        if archiveDates.count > 256 { archiveDates.removeAll() }
        archiveDates[archive] = (date, Date())
        return date
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

extension ThumbnailCache {
    /// Inside an archive QuickLook can't look: pictures are unpacked and
    /// scaled down here; videos get a film icon (they'd be unpacked whole).
    static func archiveThumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        guard BrowserModel.mediaKind(of: url) == .image else {
            let icon = NSImage(systemSymbolName: "film", accessibilityDescription: fileIcon)
            icon?.accessibilityDescription = fileIcon
            return icon
        }
        let maxPixel = Int(side * NSScreen.mainBackingScale)
        // Cancelled with its tile (scrolled away): the archive read leaves the line
        return await detachedCancellable(priority: .utility) { () -> NSImage? in
            if VectorPicture.isVector(url) {
                guard let rendered = await VectorPicture.render(url, longestSide: maxPixel) else { return nil }
                return NSImage(cgImage: rendered.0, size: NSSize(width: rendered.0.width, height: rendered.0.height))
            }
            guard let source = await MediaData.imageSource(url), !Task.isCancelled else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,   // not the small preview a camera embeds
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

/// A tile. Fetches its thumbnail from the system (embedded previews, including
/// RAW/PSD/PDF) and caches it in memory.
struct ThumbnailView: View {
    let url: URL
    let side: CGFloat
    let isSelected: Bool
    var isVideo: Bool = false
    var modified: Date? = nil

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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(TileChrome.selectionLabel(isSelected)), \(isVideo ? "video" : "image")"
                                + (image.map { $0.accessibilityDescription == ThumbnailCache.fileIcon ? ", file icon" : ", preview" }
                                   ?? (failed ? ", no preview" : "")))
            .task(id: TileKey(url: url, side: side, modified: modified)) { await load() }
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
        if let img = await ThumbnailCache.shared.thumbnail(for: url, side: side, modified: modified) {
            if !Task.isCancelled { image = img }
        } else if !Task.isCancelled {
            failed = true
        }
    }
}

/// Reloads a tile when its file, its size or the file's date changes.
private struct TileKey: Hashable {
    let url: URL
    let side: CGFloat
    let modified: Date?
}

/// Shared tile chrome: rounded background, fixed square frame, selection ring.
struct TileChrome: ViewModifier {
    let side: CGFloat
    let isSelected: Bool

    /// Start of every tile's accessibility label; the UI tests read it.
    static func selectionLabel(_ isSelected: Bool) -> String {
        isSelected ? "selected" : "not selected"
    }

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
