import SwiftUI
import QuickLookThumbnailing
import VLCFrames

/// The thumbnails of this session in memory, limited by their pixels
/// rather than their number: a search with thousands of results stays
/// whole while scrolling back and forth. Beyond it, QuickLook keeps its own
/// thumbnails on disk.
@MainActor
final class ThumbnailCache {
    /// Grid tiles; the full-size view uses these as its placeholder. An
    /// eighth of the Mac's memory, at most 2 GB (a 256-pixel tile is a
    /// quarter of a megabyte: about 8000 tiles in 2 GB).
    static let shared = ThumbnailCache(megabytes: min(2048, Int(ProcessInfo.processInfo.physicalMemory >> 23)))
    /// The small images fanned over folder tiles, kept apart so they don't
    /// push tile thumbnails out.
    static let previews = ThumbnailCache(megabytes: 256)

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

    init(megabytes: Int) {
        cache.totalCostLimit = megabytes << 20
    }

    /// What an image takes in memory: its pixels, four bytes each.
    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(pixels, Int(image.size.width * image.size.height)) * 4
    }

    func keep(_ image: NSImage, side: CGFloat, modified: Date?, for url: URL) {
        cache.setObject(Entry(image: image, side: side, modified: modified), forKey: url as NSURL, cost: Self.cost(of: image))
    }

    /// Marks an image that is only the file's icon, not a picture of it.
    nonisolated static let fileIcon = "file icon"

    /// From memory only, asking no one: what a tile made again (scrolled
    /// back into view) shows at once. `modified` nil takes any date; the
    /// tile's own load checks it afterwards. Not for archive entries (their
    /// date is the archive's, read off the main thread).
    func cached(for url: URL, side: CGFloat, modified: Date?) -> NSImage? {
        // (the memory first: asked on every redraw of a tile, mostly for nothing)
        guard let entry = cache.object(forKey: url as NSURL), entry.side >= side,
              modified == nil || entry.modified == modified, !ArchivePath.isInside(url) else { return nil }
        return entry.image
    }

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
            keep(image, side: side, modified: modified, for: url)
            return image
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: NSScreen.mainBackingScale,
            representationTypes: .all
        )
        if BrowserModel.mediaKind(of: url) == .video {
            guard let image = await Self.videoThumbnail(for: url, request: request, width: side * NSScreen.mainBackingScale),
                  !Task.isCancelled else { return nil }
            keep(image, side: side, modified: modified, for: url)
            return image
        }
        // PostScript, Illustrator, ZIP documents, Netpbm bitmaps: what the app
        // shows of them (QuickLook draws an Illustrator file's placeholder
        // page, or only an icon); ASTC textures, which QuickLook turns upside
        // down (`MediaInfo.orientationIgnored`); QOI, PCX and the RAW formats
        // LibRaw reads: QuickLook knows none of them
        let ext = DownloadName.finalExtension(of: url)
        if EmbeddedPreview.extensions.contains(ext) || EmbeddedPreview.showsPreview(url) || ext == "astc"
            || PictureDecoders.decodes(url) {
            guard let image = await Self.pictureThumbnail(of: url, side: side), !Task.isCancelled else { return nil }
            keep(image, side: side, modified: modified, for: url)
            return image
        }
        let rep = await Self.quickLook(request)
        guard !Task.isCancelled else { return nil }
        var image = rep?.nsImage
        if rep?.type == .icon { image?.accessibilityDescription = Self.fileIcon }
        // A picture QuickLook doesn't know by its name ("x.jpg.part", "IMG"):
        // ImageIO reads it by its content, as far as its bytes reach; an
        // SVG or PDF QuickLook gave no picture of is drawn here
        if rep?.type != .thumbnail, BrowserModel.mediaKind(of: url) == .image, !Task.isCancelled,
           let picture = await Self.pictureThumbnail(of: url, side: side) {
            image = picture
        } else if rep?.type == .thumbnail, RawDecoder.isImageIORaw(url), !Task.isCancelled,
                  let shown = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let tile = await RawDecoder.thumbnailReplacement(of: shown, for: url, maxPixel: Int(side * NSScreen.mainBackingScale)) {
            // QuickLook's picture of a RAW black or blown out (a Blackmagic DNG): LibRaw's
            image = NSImage(pixels: tile)
        }
        guard let image, !Task.isCancelled else { return nil }
        keep(image, side: side, modified: modified, for: url)
        return image
    }

    /// QuickLook's best picture of a file. Cancelled with its tile
    /// (scrolled away), so QuickLook works on the tiles still shown; a
    /// cancelled request answers with the file's icon, which is never kept.
    nonisolated private static func quickLook(_ request: QLThumbnailGenerator.Request) async -> QLThumbnailRepresentation? {
        await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }

    /// How long QuickLook has for a video before VLC is asked as well.
    nonisolated static let quickLookHeadStart: Duration = .seconds(3)

    private enum VideoAnswer {
        case quickLook(QLThumbnailRepresentation?)
        case vlc(VLCFrameGrab.Outcome)
        case headStartOver
    }

    /// A video's tile. MKV, WebM, WMV, ASF, FLV, Ogg and VOB come from
    /// Schnellbild's QuickLook extension, the formats macOS reads from its
    /// own, and macOS keeps them in its cache. QuickLook gets
    /// `quickLookHeadStart`; when it has only the icon or hasn't answered by
    /// then, VLC decodes a frame here as well (`VLCThumbnails`: the
    /// extension not registered yet, a type it doesn't claim such as AVI, a
    /// busy extension), and the first picture of either is the tile's. A
    /// VLC grab that timed out (a busy Mac, a share slow to answer) is tried
    /// once more; one VLC refused or failed on is not. Without a picture
    /// the tile shows QuickLook's icon. `--test-log` names the producer and
    /// why the other gave none.
    nonisolated private static func videoThumbnail(for url: URL, request: QLThumbnailGenerator.Request, width: CGFloat) async -> NSImage? {
        let name = url.lastPathComponent
        let began = Date()
        func took() -> String { String(format: "%.1f s", Date().timeIntervalSince(began)) }
        // The producers run as tasks of their own, their answers come in
        // order: the first picture is taken at once, without waiting for the
        // other to end (QuickLook's extension may take long to give up after
        // its request is cancelled)
        let (answers, answer) = AsyncStream.makeStream(of: VideoAnswer.self)
        var producers: [Task<Void, Never>] = []
        var pending = 0
        func run(_ work: @escaping @Sendable () async -> VideoAnswer) {
            pending += 1
            producers.append(Task { answer.yield(await work()) })
        }
        let stop = { (producers: [Task<Void, Never>]) in
            producers.forEach { $0.cancel() }
            answer.finish()
        }
        return await withTaskCancellationHandler { () async -> NSImage? in
            run { .quickLook(await quickLook(request)) }
            run {
                try? await Task.sleep(for: quickLookHeadStart)
                return .headStartOver
            }
            var icon: NSImage?
            var vlcTries = 0
            var quickLookSaid = "no answer"
            func askVLC() {
                guard vlcTries == 0 else { return }
                vlcTries = 1
                run { .vlc(await VLCThumbnails.shared.thumbnail(for: url, width: width)) }
            }
            for await next in answers {
                pending -= 1
                switch next {
                case .quickLook(let rep):
                    if rep?.type == .thumbnail, let image = rep?.nsImage {
                        BrowserModel.testLog("tile \(name): QuickLook's picture after \(took())")
                        stop(producers)
                        return image
                    }
                    quickLookSaid = rep.map { $0.type == .icon ? "the icon" : "a low-quality thumbnail" } ?? "nothing"
                    if let image = rep?.nsImage {
                        if rep?.type == .icon { image.accessibilityDescription = fileIcon }
                        icon = image
                    }
                    askVLC()
                case .headStartOver:
                    askVLC()
                case .vlc(let outcome):
                    if let frame = outcome.image {
                        BrowserModel.testLog("tile \(name): VLC's frame after \(took()), QuickLook: \(quickLookSaid)")
                        stop(producers)
                        return NSImage(pixels: frame)
                    }
                    BrowserModel.testLog("tile \(name): VLC \(outcome) after \(took()) (try \(vlcTries)), QuickLook: \(quickLookSaid)")
                    if case .timedOut = outcome, vlcTries == 1, !Task.isCancelled {
                        vlcTries = 2
                        run { .vlc(await VLCThumbnails.shared.thumbnail(for: url, width: width)) }
                    }
                }
                if pending == 0 || Task.isCancelled { break }
            }
            stop(producers)
            return icon
        } onCancel: {
            answer.finish()
        }
    }
    /// A picture scaled down by ImageIO, off the main thread; an SVG, PDF or
    /// Illustrator file (which ImageIO can't read) drawn as the full view
    /// draws it (`VectorPicture`), for when QuickLook answered with the icon
    /// or not at all; a file shown by the picture it carries through that
    /// picture (`MediaData.imageSource`, `EmbeddedPreview`). An SVG AppKit
    /// can't draw either (broken XML, a web font without a picture size)
    /// keeps QuickLook's icon.
    static func pictureThumbnail(of url: URL, side: CGFloat) async -> NSImage? {
        let maxPixel = Int(side * NSScreen.mainBackingScale)
        return await detachedCancellable(priority: .utility) { () -> NSImage? in
            if VectorPicture.isVector(url) {
                guard let rendered = await VectorPicture.render(url, longestSide: maxPixel) else { return nil }
                return NSImage(pixels: rendered.0)
            }
            return await decodedThumbnail(of: url, maxPixel: maxPixel).map { NSImage(pixels: $0) }
        }
    }

    /// A picture's tile through `MediaData`: a RAW file LibRaw reads from
    /// the preview it carries; one of ImageIO's RAW formats that ImageIO
    /// gives no picture of (a camera newer than this macOS) through LibRaw
    /// too; else ImageIO scaled down.
    static func decodedThumbnail(of url: URL, maxPixel: Int) async -> CGImage? {
        if PictureDecoders.format(of: url) == .raw { return await RawDecoder.thumbnail(of: url, maxPixel: maxPixel) }
        let source = await MediaData.imageSource(url)
        let cg = Task.isCancelled ? nil : source.flatMap { MediaInfo.scaledDown($0, at: 0, maxPixel: maxPixel, now: false) }
        // ImageIO's RAW without a picture, or with a black or blown out one
        if !Task.isCancelled, let tile = await RawDecoder.thumbnailReplacement(of: cg, for: url, maxPixel: maxPixel) { return tile }
        return cg
    }

    /// Archive dates as read lately: every picture of an archive asks, and
    /// the date is read off the main thread (a stalled share would block it).
    private var archiveDates: [URL: (date: Date?, read: Date)] = [:]

    private func archiveDate(of archive: URL) async -> Date? {
        if let known = archiveDates[archive], Date().timeIntervalSince(known.read) < 2 { return known.date }
        let date = await Blocking.modificationDate(of: archive)
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
                return NSImage(pixels: rendered.0)
            }
            return await decodedThumbnail(of: url, maxPixel: maxPixel).map { NSImage(pixels: $0) }
        }
    }
}

/// A tile. Fetches its thumbnail from the system (embedded previews, including
/// RAW/PSD/PDF) and caches it in memory.
struct ThumbnailView: View {
    let url: URL
    let side: CGFloat
    /// The cursor is on it (the ring).
    let isSelected: Bool
    /// Marked (⌘ / ⇧ / Insert): tinted, with a checkmark.
    var isMarked: Bool = false
    var isVideo: Bool = false
    var modified: Date? = nil
    /// A download not finished ("x.mp4.part") or an entry of an archive cut
    /// off: a small arrow in the corner, this as its tooltip.
    var unfinished: String? = nil

    @State private var image: NSImage?
    @State private var failed = false

    init(url: URL, side: CGFloat, isSelected: Bool, isMarked: Bool = false, isVideo: Bool = false, modified: Date? = nil,
         unfinished: String? = nil) {
        self.url = url
        self.side = side
        self.isSelected = isSelected
        self.isMarked = isMarked
        self.isVideo = isVideo
        self.modified = modified
        self.unfinished = unfinished
        // Scrolled back into view: the picture at once, not a spinner first
        _image = State(initialValue: ThumbnailCache.shared.cached(for: url, side: side, modified: modified))
    }

    var body: some View {
        content
            .tileChrome(side: side, isSelected: isSelected, isMarked: isMarked, unfinished: unfinished)
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
            // The label ("name, kind") comes from the grid's cell; the UI
            // tests read the tile's state here
            .accessibilityValue(test: "\(TileChrome.selectionLabel(isSelected || isMarked)), \(isVideo ? "video" : "image")"
                                    + (unfinished != nil ? ", unfinished" : "")
                                    + (image.map { $0.accessibilityDescription == ThumbnailCache.fileIcon ? ", file icon" : ", preview" }
                                       ?? (failed ? ", no preview" : "")),
                                spoken: TileChrome.spokenState(marked: isMarked, failed: failed))
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
                .help("This picture can't be shown")
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

/// Shared tile chrome: rounded background, fixed square frame; the ring for
/// the cursor, a tint and a checkmark for a marked item (both on a marked
/// item under the cursor).
struct TileChrome: ViewModifier {
    let side: CGFloat
    let isSelected: Bool
    var isMarked = false
    /// A download not finished: a small arrow in the lower left corner,
    /// clear of the video's play sign and the mark's checkmark.
    var unfinished: String? = nil
    @Environment(\.colorSchemeContrast) private var contrast

    /// Start of every tile's state under `--ui-testing`; the UI tests read it.
    static func selectionLabel(_ isSelected: Bool) -> String {
        isSelected ? "selected" : "not selected"
    }

    /// What VoiceOver says after a tile's name and kind (selected or marked
    /// is the element's trait).
    static func spokenState(marked: Bool, failed: Bool = false) -> String {
        [marked ? String(localized: "marked") : nil, failed ? String(localized: "This picture can't be shown") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isMarked ? Color.accentColor.opacity(increased ? 0.45 : 0.28)
                      : Color(nsColor: .quaternaryLabelColor).opacity(increased ? 0.8 : 0.4))
            content
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .overlay(alignment: .topTrailing) {
            if isMarked {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: min(18, side * 0.4)))
                    .padding(side < 60 ? 1 : 5)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let unfinished { DownloadBadge(note: unfinished, size: min(16, side * 0.3)).padding(side < 60 ? 1 : 6) }
        }
    }
}

/// The sign of a download not finished ("x.mp4.part", "x.rar.crdownload")
/// or of an entry an archive cut off doesn't hold whole: small and quiet, on
/// tiles, its meaning as the tooltip.
struct DownloadBadge: View {
    let note: String
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.5))
            .font(.system(size: size))
            .help(note)
            .accessibilityHidden(true)
    }
}

extension View {
    func tileChrome(side: CGFloat, isSelected: Bool, isMarked: Bool = false, unfinished: String? = nil) -> some View {
        modifier(TileChrome(side: side, isSelected: isSelected, isMarked: isMarked, unfinished: unfinished))
    }
}
