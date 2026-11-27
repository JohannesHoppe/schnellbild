import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import AppKit
import OfflineMap

/// Full-size view for pictures, animated GIFs included. Loads the image via
/// ImageIO downsampled directly to screen size. Zoom: keys +/-/0/1 (via the
/// model) and trackpad pinch; dragging pans when zoomed in. An animation
/// (a GIF of several frames) plays its frames in place of the picture, at
/// the same size and with the same look, so zoom, rotation and auto
/// enhance work on it alike. A PDF shows one page at a time (the model's
/// `pdfPosition`, ← → as a video's seek), each drawn as a vector picture
/// and zoomed, panned and turned on its own like a picture.
struct FullImageView: View {
    let url: URL
    /// The file's date as listed: a picture another app rewrote in place is
    /// decoded again (its source opened afresh).
    var modified: Date? = nil

    @EnvironmentObject var model: BrowserModel
    @State private var image: NSImage?
    /// The loaded picture, auto enhance's look for it, and the picture with
    /// the look on screen (`model.enhancement`).
    @State private var picture: CGImage?
    @State private var autoLook: Look?
    @State private var enhanced: (look: Look, side: Int, image: NSImage)?
    @State private var nativeSize: CGSize?
    @State private var panOffset: CGSize = .zero
    /// The file couldn't be read as a picture.
    @State private var failed = false
    /// Why, as far as ImageIO tells (nil: it doesn't say).
    @State private var failure: LoadFailure?
    /// The longest side the picture was decoded at: screen size first, the
    /// full size once the user zooms in (a sharp picture where it matters).
    @State private var decodedSide = 0
    /// The animation's frame on screen (with the look), and which one.
    @State private var frame: (image: NSImage, index: Int, count: Int)?
    /// The animation's frames as decoded, kept while the look changes (a
    /// slider moved applies it to each frame anew, nothing is read again).
    @State private var animation: (url: URL, frames: AnimationFrames)?
    /// The PDF shown, opened once and kept while its pages are turned.
    @State private var pdf: PDFPages?
    /// The picture's image source, opened once for its sharper decodes and
    /// its animation (a share asked once, an archive's entry unpacked once;
    /// a large entry's source isn't held, `OpenedPicture.largestHeld`).
    @State private var opened: OpenedPicture?
    /// The file and page whose picture is on screen (a PDF's page stays
    /// while the next one is drawn).
    @State private var drawn: Shown?
    /// Within `fallbackDelay` of another file coming up, not decoded yet:
    /// what was on screen stays (the previous picture, else black), so a
    /// picture decoded in time shows sharp at once, never the tile first.
    @State private var waiting = true
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    /// The pixels per point of the display this view's window is on (100 %
    /// is one picture pixel per pixel there, whichever window has the keys).
    @Environment(\.displayScale) private var displayScale

    /// Black until the picture is decoded; the tile's thumbnail from the
    /// cache, scaled up, only when that takes longer than `fallbackDelay`.
    init(url: URL, modified: Date? = nil) {
        self.url = url
        self.modified = modified
    }

    /// How long a picture may take to decode before the tile's thumbnail
    /// stands in for it (a share, a large RAW): a picture from a local disk
    /// is there before it, so it shows sharp at once, not blurred first and
    /// sharp a moment later.
    static let fallbackDelay: Duration = .milliseconds(150)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let shown = shownImage {
                    Image(nsImage: shown)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(model.rotation))
                        .scaleEffect(model.zoom * pinch * rotationFitScale(in: geo.size))
                        // While pinching, the pan scales with the pinch (about the view's middle)
                        .offset(x: panOffset.width * pinch + dragTranslation.width,
                                y: panOffset.height * pinch + dragTranslation.height)
                        .gesture(magnifyGesture)
                        .simultaneousGesture(panGesture)
                } else if failed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                        Text("This picture can't be shown")
                            .font(.title3.weight(.semibold))
                        if let failure {
                            Text(failure.reason)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(24)
                } else if !waiting {
                    LoadingSpinner()
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("fullImage")
            // The UI tests read the view's state, in English, as the label:
            // XCUITest gets no value from a group like this one
            .accessibilityLabel(test: accessibilityState, spoken: spokenLabel)
            .task(id: shown) {
                failed = false
                failure = nil
                decodedSide = 0
                let maxPixel = max(Int(max(geo.size.width, geo.size.height) * displayScale), 1)
                let ahead = model.picturesAhead
                let anotherFile = pdf?.url != url && drawn?.url != url
                if anotherFile, let ready = ahead.decoded(url, modified: modified, side: maxPixel) {
                    // Decoded ahead (paged to from its neighbour): sharp at once
                    show((ready.image, ready.native, ready.picture, ready.opened), page: 0, sharper: false)
                    MainThreadWatch.log("full view \(url.lastPathComponent): decoded ahead at \(decodedSide) px")
                } else if anotherFile {
                    await loadAnotherFile(maxPixel: maxPixel)
                    MainThreadWatch.log("full view \(url.lastPathComponent): decoded at \(decodedSide) px")
                } else {
                    // Another page of the same PDF, the same file rewritten:
                    // what is shown stays until the new one is drawn
                    waiting = false
                    await load(maxPixel: maxPixel, sharper: false)
                }
                updateActualSizeFactor(in: geo.size)
                // The pictures ← → go to next, decoded while this one is looked at
                if !Task.isCancelled, let image, let picture, let nativeSize, drawn?.url == url, !PDFPages.isPDF(url) {
                    ahead.prepare(current: (url, modified, (image, nativeSize, picture, opened)),
                                  neighbours: model.pictureNeighbours, side: maxPixel)
                }
            }
            .task(id: SharpnessJob(shown: shown, side: wantedSide(in: geo.size), ready: picture != nil)) {
                // The view grew (full screen) or the user zoomed in: decoded
                // again, larger. Not while a window resize is still going on.
                let side = wantedSide(in: geo.size)
                guard picture != nil, side > decodedSide else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await load(maxPixel: side, sharper: true)
            }
            .onChange(of: geo.size) { _, newSize in
                updateActualSizeFactor(in: newSize)
            }
            // Moved to a display of another scale, turned a quarter: 100 % is another zoom
            .onChange(of: displayScale) { updateActualSizeFactor(in: geo.size) }
            .onChange(of: model.rotation) { updateActualSizeFactor(in: geo.size) }
            // ↑ / ↓ zoomed in: a fifth of the view further up / down
            .onChange(of: model.panRequest) { _, request in
                guard let request, model.zoom > 1.01 else { return }
                withAnimation(Motion.animation(.easeOut(duration: 0.15))) {
                    panOffset.height += (request.up ? 1 : -1) * geo.size.height / 5
                }
            }
            .task(id: EnhanceJob(shown: shown, enhancement: model.enhancement, ready: picture != nil, side: decodedSide)) {
                await enhance()
            }
            .task(id: AnimationJob(url: url, side: decodedSide, look: picture == nil ? nil : shownLook, ready: picture != nil)) {
                await animate()
            }
        }
        .onDisappear { model.picturesAhead.clear() }
        .onChange(of: model.zoom) { old, new in
            panOffset = BrowserModel.panOffset(panOffset, zoomedFrom: old, to: new)
        }
        .onChange(of: shown) { old, new in
            let rewritten = old.url == new.url && old.modified != new.modified
            if pdf?.url != new.url || rewritten { pdf = nil }
            if opened?.url != new.url || rewritten { opened = nil }
            panOffset = .zero
            nativeSize = nil
            picture = nil
            autoLook = nil
            enhanced = nil
            frame = nil
            animation = nil
        }
    }

    /// The file, its date and, for a PDF, the page on screen (0 for every
    /// other file).
    private var shown: Shown {
        Shown(url: url, modified: modified, page: PDFPages.isPDF(url) ? model.pdfPage(of: url) : 0)
    }

    struct Shown: Hashable {
        let url: URL
        let modified: Date?
        let page: Int
    }

    /// With a look: the picture rendered with it; while a slider moves, the
    /// last rendered one until the next is ready.
    private var shownImage: NSImage? {
        if let frame { return frame.image }
        if shownLook != nil, let enhanced { return enhanced.image }
        return image
    }

    /// The look to show, nil for the picture as it is (or while auto
    /// enhance is still measuring).
    private var shownLook: Look? {
        switch model.enhancement {
        case .off: return nil
        case .auto: return autoLook
        case .manual(let look): return look
        }
    }

    /// What VoiceOver says: the picture's name and zoom, or why it can't be
    /// shown.
    private var spokenLabel: String {
        let name = url.lastPathComponent
        if failed {
            return [name, String(localized: "This picture can't be shown"), failure?.reason].compactMap { $0 }.joined(separator: ", ")
        }
        let zoom = Double(model.zoom).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "\(name), zoom \(zoom)")
    }

    /// For the UI tests (`--ui-testing`): the view transform, e.g. "zoom 125 %, rotation 90°, loaded".
    private var accessibilityState: String {
        "zoom \(Int((model.zoom * 100).rounded())) %, rotation \(Int(model.rotation))°, "
            + (decodedSide > 0 ? "decoded \(decodedSide) px, " : "")
            + (failed ? "failed" : image == nil || waiting ? "loading" : "loaded")
            + (shownLook != nil && enhanced?.look == shownLook ? (model.enhance ? ", enhanced" : ", adjusted") : "")
            + (frame.map { ", frame \($0.index + 1) of \($0.count)" } ?? "")
            + (pdf.flatMap { pdf in drawn.flatMap { $0.url == url ? ", page \($0.page + 1) of \(pdf.count)" : nil } } ?? "")
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                if model.zoom > 1.01 { state = value.translation }
            }
            .onEnded { value in
                guard model.zoom > 1.01 else { return }
                panOffset.width += value.translation.width
                panOffset.height += value.translation.height
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                model.applyPinch(value.magnification)
            }
    }

    /// Compute the factor at which `zoom` corresponds to 100 % actual pixels:
    /// the picture is drawn at its fitted width times the zoom times
    /// `rotationFitScale`, which a quarter turn adds.
    private func updateActualSizeFactor(in container: CGSize) {
        guard let ns = nativeSize, ns.width > 0, ns.height > 0,
              container.width > 0, container.height > 0 else { return }
        let fitScale = min(container.width / ns.width, container.height / ns.height)
        let fitWidth = ns.width * fitScale * rotationFitScale(in: container)
        let actualWidth = ns.width / displayScale          // 100 % in points
        model.actualSizeFactor = max(actualWidth / max(fitWidth, 1), 0.01)
    }

    /// When rotated a quarter turn, scale the image so its now-swapped bounding
    /// box still fits the window.
    private func rotationFitScale(in container: CGSize) -> CGFloat {
        guard let ns = nativeSize, ns.width > 0, ns.height > 0,
              container.width > 0, container.height > 0 else { return 1 }
        let quarterTurned = Int((model.rotation / 90).rounded()) % 2 != 0
        guard quarterTurned else { return 1 }
        let fit = min(container.width / ns.width, container.height / ns.height)
        let dispW = ns.width * fit
        let dispH = ns.height * fit
        return min(container.width / dispH, container.height / dispW)
    }

    /// Decodes the picture with its longest side `maxPixel`. Paging on
    /// cancels it: an archive read stops, and a decode not yet begun is
    /// skipped. `sharper`: the picture is on screen already and is decoded
    /// again larger; if that fails, the one shown stays.
    private func load(maxPixel: Int, sharper: Bool) async {
        let url = self.url
        var pages: PDFPages?
        if PDFPages.isPDF(url) {
            if let open = pdf, open.url == url {
                pages = open
            } else {
                pages = await detachedCancellable(priority: .userInitiated) { await PDFPages.open(url) }
                guard !Task.isCancelled else { return }
                guard let pages else {
                    if !sharper { image = nil; failed = true; failure = .undecodable }
                    return
                }
                pdf = pages
            }
            if let pages, !sharper { model.pdfOpened(url, pages: pages.count) }
        }
        let page = shown.page
        let kept = sharper && opened?.url == url ? opened : nil
        let attempt = await detachedCancellable(priority: .userInitiated) { [pages] in
            await Self.decode(url, pages: pages, page: page, maxPixel: maxPixel, kept: kept)
        }

        guard !Task.isCancelled, let outcome = attempt else { return }
        let result: (NSImage, CGSize, CGImage, OpenedPicture?)
        switch outcome {
        case .success(let loaded):
            result = loaded
        case .failure(let reason):
            if sharper { return }
            image = nil   // not the tile's file icon: the file can't be shown
            failed = true
            failure = reason
            return
        }
        show(result, page: page, sharper: sharper)
    }

    /// Decodes a file other than the one on screen. What is on screen stays
    /// for `fallbackDelay`; decoded by then, the picture replaces it at
    /// once, else the tile's thumbnail stands in until it is (the spinner
    /// without one). Never the previous file's picture longer than that.
    private func loadAnotherFile(maxPixel: Int) async {
        waiting = true
        let url = self.url
        let fallback = Task { @MainActor in
            try? await Task.sleep(for: Self.fallbackDelay)
            guard !Task.isCancelled else { return }
            image = ThumbnailCache.shared.image(for: url)
            waiting = false
            MainThreadWatch.log("full view \(url.lastPathComponent): \(image == nil ? "the spinner" : "the tile") until decoded")
        }
        defer { fallback.cancel() }
        await load(maxPixel: maxPixel, sharper: false)
        guard !Task.isCancelled else { return }
        fallback.cancel()
        waiting = false
    }

    /// Puts a decoded picture on screen.
    private func show(_ result: (NSImage, CGSize, CGImage, OpenedPicture?), page: Int, sharper: Bool) {
        image = result.0
        waiting = false
        drawn = Shown(url: url, modified: modified, page: page)
        nativeSize = result.1
        decodedSide = max(result.2.width, result.2.height)
        if !sharper {
            // The same picture decoded larger keeps its look (measured on the
            // smaller one) and the rendered picture until the new one is ready
            enhanced = nil
            autoLook = nil
        }
        picture = result.2
        opened = result.3
    }

    /// The picture the full view shows of `url` with `maxPixel` as its
    /// longest side: a PDF's `page` (`pages` open), an SVG drawn, else
    /// ImageIO's picture (`MediaData.picture`, also a preview the file
    /// carries), with its own size and the source kept for sharper decodes.
    /// Nil: cancelled.
    nonisolated static func decode(_ url: URL, pages: PDFPages?, page: Int, maxPixel: Int,
                                   kept: OpenedPicture?) async -> Result<(NSImage, CGSize, CGImage, OpenedPicture?), LoadFailure>? {
        if let pages {
            guard let rendered = pages.render(page: page, longestSide: maxPixel) else { return .failure(.undecodable) }
            return .success((NSImage(pixels: rendered.0), rendered.1, rendered.0, nil))
        }
        if VectorPicture.isVector(url) {
            guard let rendered = await VectorPicture.render(url, longestSide: maxPixel) else { return .failure(.undecodable) }
            return .success((NSImage(pixels: rendered.0), rendered.1, rendered.0, nil))
        }
        var picture: (source: CGImageSource, inMemory: Int)?
        if let source = kept?.source { picture = (source, 0) } else { picture = await MediaData.picture(url) }
        guard var src = picture?.source else { return .failure(.unreadable) }
        guard !Task.isCancelled else { return nil }
        var failure = LoadFailure(status: CGImageSourceGetStatus(src))
        var cg = failure == nil ? MediaInfo.scaledDown(src, at: 0, maxPixel: maxPixel, now: true) : nil
        // One of ImageIO's RAW formats that ImageIO gives no picture of (a
        // camera newer than this macOS) or one all black or blown out (a
        // Blackmagic DNG): LibRaw's development, where it isn't so itself.
        // Asked whenever the file was opened again, also for a sharper
        // decode of a development too large to be held (`largestHeld`)
        if kept?.source == nil, !Task.isCancelled, let developed = await RawDecoder.replacement(of: cg, for: url, maxPixel: maxPixel) {
            src = developed.source
            picture = (developed.source, developed.inMemory)
            failure = nil
            cg = developed.image
        }
        if let failure { return .failure(failure) }
        guard let cg else { return .failure(.undecodable) }
        let native = MediaInfo.pixelSize(from: src) ?? .zero
        return .success((NSImage(pixels: cg), native, cg, kept ?? OpenedPicture(url: url, source: src, inMemory: picture?.inMemory ?? 0)))
    }

    /// Why a picture can't be shown, as far as ImageIO tells.
    enum LoadFailure: Error {
        /// No image source: the file (or its entry in an archive) can't be read.
        case unreadable
        /// ImageIO knows no format for the data.
        case unknownFormat
        /// The data ends before the picture does.
        case truncated
        /// The data doesn't hold a picture ImageIO can decode.
        case undecodable

        init?(status: CGImageSourceStatus) {
            switch status {
            case .statusComplete, .statusIncomplete, .statusReadingHeader: return nil
            case .statusUnknownType: self = .unknownFormat
            case .statusUnexpectedEOF: self = .truncated
            case .statusInvalidData: self = .undecodable
            @unknown default: self = .undecodable
            }
        }

        var reason: String {
            switch self {
            case .unreadable: String(localized: "The file can't be read.")
            case .unknownFormat: String(localized: "Its format isn't known.")
            case .truncated: String(localized: "The file ends too early.")
            case .undecodable: String(localized: "Its data can't be decoded.")
            }
        }
    }

    private struct SharpnessJob: Equatable {
        let shown: Shown
        let side: Int
        let ready: Bool
    }

    /// The longest side to decode at: the view's size in pixels, times the
    /// zoom when zoomed in (a step ahead, so not every zoom step decodes
    /// again), never more than the file has nor more than `largestPixels`
    /// (a picture of 30000 × 30000 pixels would need gigabytes). A vector
    /// picture (SVG, PDF) has no pixels of its own: drawn at the view's
    /// size, zoomed in at the zoomed size.
    private func wantedSide(in container: CGSize) -> Int {
        guard let native = nativeSize, native.width > 0, native.height > 0 else { return 0 }
        let view = CGFloat(max(container.width, container.height) * displayScale)
        if VectorPicture.isVector(url) {
            return min(Int(view * max(model.zoom, 1)), VectorPicture.largestSide)
        }
        let long = max(native.width, native.height), short = max(min(native.width, native.height), 1)
        let full = Int(long)
        let bounded = Int((Self.largestPixels * long / short).squareRoot())
        let zoomed = model.zoom > 1.01 ? view * model.zoom * 1.5 : view
        return max(min(Int(zoomed), full, bounded), 1)
    }

    /// The most pixels a picture is decoded with (256 MB at 4 bytes each;
    /// the adjusted copy needs as much again).
    private static let largestPixels: CGFloat = 64_000_000

    private struct EnhanceJob: Equatable {
        let shown: Shown
        let enhancement: Enhancement
        let ready: Bool
        /// Decoded again at full size: rendered again
        let side: Int
    }

    /// Measures the picture for auto enhance (once per picture) and renders
    /// it with the look, off the main thread. While sliders move, the last
    /// rendered picture stays until the new one is ready.
    private func enhance() async {
        guard model.enhancement != .off, let picture else { return }
        if model.enhance {
            if autoLook == nil {
                let measured = await Task.detached(priority: .userInitiated) {
                    PictureStats.of(CIImage(cgImage: picture)).map(Look.auto(for:))
                }.value
                guard !Task.isCancelled else { return }
                autoLook = measured ?? .neutral
            }
            if let autoLook { model.autoLookMeasured(autoLook) }
        } else {
            try? await Task.sleep(for: .milliseconds(30))   // a slider still moving
        }
        let side = decodedSide
        guard !Task.isCancelled, let look = shownLook, enhanced?.look != look || enhanced?.side != side else { return }
        let result = await Task.detached(priority: .userInitiated) {
            Look.render(picture, with: look)
        }.value
        guard !Task.isCancelled, let result else { return }
        enhanced = (look, side, NSImage(pixels: result))
    }
}

extension FullImageView {
    struct AnimationJob: Equatable {
        let url: URL
        let side: Int
        let look: Look?
        let ready: Bool
    }

    /// Plays an animation's frames in a loop, each for its own time, at the
    /// size the picture was decoded at and with the look shown. Nothing
    /// for a picture of one frame.
    private func animate() async {
        guard picture != nil, decodedSide > 0, !VectorPicture.isVector(url) else { return }
        let side = decodedSide, look = shownLook, url = self.url
        guard let opened, opened.url == url, opened.animated else { frame = nil; animation = nil; return }
        let frames: AnimationFrames
        if let animation, animation.url == url, animation.frames.side == side {
            frames = animation.frames
        } else {
            guard let made = await detachedCancellable(priority: .userInitiated, { () -> AnimationFrames? in
                var source = opened.source
                if source == nil { source = await MediaData.imageSource(url) }
                return source.flatMap { AnimationFrames.of($0, side: side) }
            }) else { frame = nil; animation = nil; return }
            frames = made
            animation = (url, made)
        }
        var index = frame?.count == frames.count ? frame?.index ?? 0 : 0
        while !Task.isCancelled {
            let started = ContinuousClock.now
            let current = index
            let next = await detachedCancellable(priority: .userInitiated) { frames.frame(current, look: look) }
            guard !Task.isCancelled else { return }
            if let next {
                frame = (NSImage(pixels: next), index, frames.count)
            }
            // Its own time, less what decoding it took
            let wait = Duration.seconds(frames.delays[index]) - (ContinuousClock.now - started)
            if wait > .zero { try? await Task.sleep(for: wait) }
            index = (index + 1) % frames.count
        }
    }
}

/// A picture's image source and its file (an image source can be read
/// from any thread). The source of a picture that holds more than
/// `largestHeld` bytes in memory (an archive's entry unpacked whole) isn't
/// held while the picture is on screen: it is opened again for a sharper
/// decode or the animation.
final class OpenedPicture: @unchecked Sendable {
    /// The most bytes in memory a held source may hold.
    static let largestHeld = 32 << 20
    let url: URL
    let source: CGImageSource?
    /// Its images (more than one: an animation, or a TIFF's pages, an icon's sizes …).
    let frames: Int
    /// Its images are an animation's frames (`AnimationFrames.isAnimation`).
    let animated: Bool
    init(url: URL, source: CGImageSource, inMemory: Int) {
        self.url = url
        frames = CGImageSourceGetCount(source)
        animated = AnimationFrames.isAnimation(source)
        self.source = inMemory > Self.largestHeld ? nil : source
    }
}

/// The frames of an animated picture (GIF, animated PNG and WebP, HEIC and
/// AVIF sequences): decoded at a given size, kept while they fit in
/// `budget`, else decoded again each round.
final class AnimationFrames: @unchecked Sendable {
    let count: Int
    /// Seconds per frame, as browsers show them (under 20 ms counts as 100 ms).
    let delays: [Double]
    private let source: CGImageSource
    /// The longest side its frames are decoded at.
    let side: Int
    private let keeps: Bool
    private let lock = NSLock()
    private var kept: [Int: CGImage] = [:]
    /// The most the decoded frames of one animation may take.
    static let budget = 256_000_000

    private init(source: CGImageSource, count: Int, side: Int) {
        self.source = source
        self.count = count
        self.side = side
        delays = (0..<count).map { Self.delay(of: source, at: $0) }
        keeps = count * side * side * 4 <= Self.budget
    }

    /// nil for a picture of one frame, and for one whose images aren't the
    /// frames of an animation: a TIFF's pages, an icon's sizes (ICO, ICNS),
    /// the two pictures of an MPO or a spatial photo.
    static func of(_ source: CGImageSource, side: Int) -> AnimationFrames? {
        guard isAnimation(source) else { return nil }
        return AnimationFrames(source: source, count: CGImageSourceGetCount(source), side: side)
    }

    /// More than one image, and those are an animation's frames: a GIF (its
    /// frames may state no time), else a frame that states its time in
    /// one of the animated formats' dictionaries.
    static func isAnimation(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1 else { return false }
        if (CGImageSourceGetType(source) as String?) == UTType.gif.identifier { return true }
        return statedDelay(of: source, at: 0) != nil
    }

    /// The dictionaries an animation's frames state their times in: GIF,
    /// animated PNG, WebP, HEIC sequence, AVIF sequence.
    private static let timed = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary,
                                kCGImagePropertyHEICSDictionary, kCGImagePropertyAVISDictionary]

    static func delay(of source: CGImageSource, at index: Int) -> Double {
        guard let seconds = statedDelay(of: source, at: index) else { return 0.1 }
        return seconds < 0.02 ? 0.1 : seconds
    }

    /// The time frame `index` states, unclamped where it says so.
    private static func statedDelay(of source: CGImageSource, at index: Int) -> Double? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        for key in timed {
            guard let info = props?[key] as? [CFString: Any] else { continue }
            // The formats share the keys' names ("UnclampedDelayTime",
            // "DelayTime"); AVIF's have no constants of their own
            let unclamped = info[kCGImagePropertyGIFUnclampedDelayTime] ?? info[kCGImagePropertyAPNGUnclampedDelayTime]
                ?? info[kCGImagePropertyWebPUnclampedDelayTime] ?? info[kCGImagePropertyHEICSUnclampedDelayTime]
            let clamped = info[kCGImagePropertyGIFDelayTime] ?? info[kCGImagePropertyAPNGDelayTime]
                ?? info[kCGImagePropertyWebPDelayTime] ?? info[kCGImagePropertyHEICSDelayTime]
            if let seconds = ((unclamped ?? clamped) as? NSNumber)?.doubleValue { return seconds }
        }
        return nil
    }

    /// Frame `index`, with `look` when it changes anything.
    func frame(_ index: Int, look: Look?) -> CGImage? {
        guard index >= 0, index < count else { return nil }
        lock.lock()
        var decoded = kept[index]
        lock.unlock()
        if decoded == nil {
            decoded = MediaInfo.scaledDown(source, at: index, maxPixel: side, now: true)
            if keeps, let decoded { lock.lock(); kept[index] = decoded; lock.unlock() }
        }
        guard let decoded else { return nil }
        guard let look, !look.isNeutral else { return decoded }
        return Look.render(decoded, with: look) ?? decoded
    }
}

/// SVG and PDF, drawn as vector pictures at any size (ImageIO doesn't read
/// SVG, and gives a PDF page neither a size nor more than its 72 dpi
/// pixels): SVG by AppKit's `NSImage`, a PDF by PDFKit (`PDFPages`), here
/// its first page (tiles, the Inspector; the full view pages through it).
enum VectorPicture {
    /// Drawn no larger than this (at most a 64 MB picture, 4096 × 4096 × 4
    /// bytes, at full zoom; the adjusted copy needs as much again).
    static let largestSide = 4096

    static func isVector(_ url: URL) -> Bool {
        let ext = BrowserModel.shownExtension(of: url)
        return ext == "svg" || ext == "svgz" || PDFPages.isPDF(url)
    }

    /// The picture, from disk or from inside an archive (`MediaData`); an
    /// SVG compressed with gzip (".svgz") unpacked first (at most
    /// `Gzip.largestOutput`, 64 MB).
    private static func image(_ url: URL) async -> NSImage? {
        guard let data = try? await MediaData.read(url) else { return nil }
        if BrowserModel.shownExtension(of: url) == "svgz" { return Gzip.decompress(data).flatMap(NSImage.init(data:)) }
        return NSImage(data: data)
    }

    /// The picture's own size (points from its width/height or viewBox).
    static func size(of url: URL) async -> CGSize? {
        if PDFPages.isPDF(url) { return await PDFPages.open(url)?.size(of: 0) }
        guard let image = await image(url), image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size
    }

    /// Drawn with its longest side `longestSide` pixels, on its own
    /// background (transparent where the SVG draws nothing); with its size.
    static func render(_ url: URL, longestSide: Int) async -> (CGImage, CGSize)? {
        if PDFPages.isPDF(url) { return await PDFPages.open(url)?.render(page: 0, longestSide: longestSide) }
        guard let image = await image(url) else { return nil }
        return render(image, longestSide: longestSide)
    }

    private static func render(_ image: NSImage, longestSide: Int) -> (CGImage, CGSize)? {
        guard let context = MediaInfo.bitmap(for: image.size, longestSide: longestSide) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: context.width, height: context.height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { ($0, image.size) }
    }
}

/// Pictures decoded ahead at the full view's size, one set per pane
/// (`BrowserModel.picturesAhead`): the items ← → and the slideshow go to
/// next, so paging shows them sharp from their first frame, not the tile
/// scaled up until the decode arrives. Holds the picture on screen and
/// its neighbours, nothing else (at the view's size a few tens of MB each).
@MainActor final class PicturesAhead {
    typealias Decoded = (image: NSImage, native: CGSize, picture: CGImage, opened: OpenedPicture?)

    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let side: Int
    }

    private var kept: [Key: Decoded] = [:]
    private var work: Task<Void, Never>?

    /// The picture of `url` decoded ahead with `side` as its longest side
    /// asked for, nil when it isn't (yet).
    func decoded(_ url: URL, modified: Date?, side: Int) -> Decoded? {
        kept[Key(url: url, modified: modified, side: side)]
    }

    /// Keeps the picture on screen (`current`) and decodes `neighbours`
    /// one after the other, off the main thread; everything else goes. A
    /// call before they are done stops the decodes still to come.
    func prepare(current: (url: URL, modified: Date?, decoded: Decoded), neighbours: [GridEntry], side: Int) {
        work?.cancel()
        let shown = Key(url: current.url, modified: current.modified, side: side)
        // (a PDF is drawn page by page through its open document)
        let wanted = neighbours.filter { !PDFPages.isPDF($0.url) }
            .map { Key(url: $0.url, modified: $0.previewDate, side: side) }
        kept = kept.filter { wanted.contains($0.key) }
        kept[shown] = current.decoded
        let missing = wanted.filter { kept[$0] == nil }
        guard !missing.isEmpty else { return }
        work = Task { [weak self] in
            for key in missing {
                let outcome = await detachedCancellable(priority: .utility) {
                    await FullImageView.decode(key.url, pages: nil, page: 0, maxPixel: key.side, kept: nil)
                }
                guard !Task.isCancelled, let self else { return }
                if case .success(let loaded)? = outcome {
                    self.kept[key] = (loaded.0, loaded.1, loaded.2, loaded.3)
                }
            }
        }
    }

    /// The full view closed: nothing kept.
    func clear() {
        work?.cancel()
        work = nil
        kept = [:]
    }
}
