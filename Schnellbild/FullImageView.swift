import SwiftUI
import ImageIO
import CoreImage
import AppKit

/// Full-size view for pictures, animated GIFs included. Loads the image via
/// ImageIO downsampled directly to screen size. Zoom: keys +/-/0/1 (via the
/// model) and trackpad pinch; dragging pans when zoomed in. An animation
/// (a GIF of several frames) plays its frames in place of the picture, at
/// the same size and with the same look, so zoom, rotation and auto
/// enhance work on it alike.
struct FullImageView: View {
    let url: URL

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
    /// The longest side the picture was decoded at: screen size first, the
    /// full size once the user zooms in (a sharp picture where it matters).
    @State private var decodedSide = 0
    /// The animation's frame on screen (with the look), and which one.
    @State private var frame: (image: NSImage, index: Int, count: Int)?
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

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
                        .offset(x: panOffset.width + dragTranslation.width,
                                y: panOffset.height + dragTranslation.height)
                        .gesture(magnifyGesture)
                        .simultaneousGesture(panGesture)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                } else {
                    LoadingSpinner()
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("fullImage")
            .accessibilityLabel(accessibilityState)
            .task(id: url) {
                // Never the previous file's picture: the cached tile, or nothing yet
                image = ThumbnailCache.shared.image(for: url)
                failed = false
                decodedSide = 0
                let scale = NSScreen.windowBackingScale
                let maxPixel = max(Int(max(geo.size.width, geo.size.height) * scale), 1)
                await load(maxPixel: maxPixel, sharper: false)
                updateActualSizeFactor(in: geo.size)
            }
            .task(id: SharpnessJob(url: url, side: wantedSide(in: geo.size), ready: picture != nil)) {
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
            // ↑ / ↓ zoomed in: a fifth of the view further up / down
            .onChange(of: model.panRequest) { _, request in
                guard let request, model.zoom > 1.01 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    panOffset.height += (request.up ? 1 : -1) * geo.size.height / 5
                }
            }
            .task(id: EnhanceJob(url: url, enhancement: model.enhancement, ready: picture != nil, side: decodedSide)) {
                await enhance()
            }
            .task(id: AnimationJob(url: url, side: decodedSide, look: picture == nil ? nil : shownLook, ready: picture != nil)) {
                await animate()
            }
        }
        .onChange(of: model.zoom) { _, newValue in
            if newValue <= 1.01 { panOffset = .zero }
        }
        .onChange(of: url) { _, _ in
            panOffset = .zero
            nativeSize = nil
            picture = nil
            autoLook = nil
            enhanced = nil
            frame = nil
        }
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

    /// Exposes the view transform, e.g. "zoom 125 %, rotation 90°, loaded".
    private var accessibilityState: String {
        "zoom \(Int((model.zoom * 100).rounded())) %, rotation \(Int(model.rotation))°, "
            + (decodedSide > 0 ? "decoded \(decodedSide) px, " : "")
            + (failed ? "failed" : image == nil ? "loading" : "loaded")
            + (shownLook != nil && enhanced?.look == shownLook ? (model.enhance ? ", enhanced" : ", adjusted") : "")
            + (frame.map { ", frame \($0.index + 1) of \($0.count)" } ?? "")
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

    /// Compute the factor at which `zoom` corresponds to 100 % actual pixels.
    private func updateActualSizeFactor(in container: CGSize) {
        guard let ns = nativeSize, ns.width > 0, ns.height > 0,
              container.width > 0, container.height > 0 else { return }
        let scale = NSScreen.windowBackingScale
        let fitScale = min(container.width / ns.width, container.height / ns.height)
        let fitWidth = ns.width * fitScale
        let actualWidth = ns.width / scale          // 100 % in points
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
        let result = await detachedCancellable(priority: .userInitiated) { () -> (NSImage, CGSize, CGImage)? in
            if VectorPicture.isVector(url) {
                guard let rendered = await VectorPicture.render(url, longestSide: maxPixel) else { return nil }
                let cg = rendered.0
                return (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), rendered.1, cg)
            }
            guard let src = await MediaData.imageSource(url), !Task.isCancelled else { return nil }
            let native = MediaInfo.pixelSize(from: src) ?? .zero

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                return nil
            }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            return (img, native, cg)
        }

        guard !Task.isCancelled else { return }
        guard let result else {
            if sharper { return }
            image = nil   // not the tile's file icon: the file can't be shown
            failed = true
            return
        }
        image = result.0
        nativeSize = result.1
        decodedSide = max(result.2.width, result.2.height)
        if !sharper {
            // The same picture decoded larger keeps its look (measured on the
            // smaller one) and the rendered picture until the new one is ready
            enhanced = nil
            autoLook = nil
        }
        picture = result.2
    }

    private struct SharpnessJob: Equatable {
        let url: URL
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
        let view = CGFloat(max(container.width, container.height) * NSScreen.windowBackingScale)
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
        let url: URL
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
        enhanced = (look, side, NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height)))
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
        let url = self.url, side = decodedSide, look = shownLook
        guard let frames = await detachedCancellable(priority: .userInitiated, {
            await AnimationFrames.open(url, side: side)
        }) else { frame = nil; return }
        var index = frame?.count == frames.count ? frame?.index ?? 0 : 0
        while !Task.isCancelled {
            let started = ContinuousClock.now
            let current = index
            let next = await detachedCancellable(priority: .userInitiated) { frames.frame(current, look: look) }
            guard !Task.isCancelled else { return }
            if let next {
                frame = (NSImage(cgImage: next, size: NSSize(width: next.width, height: next.height)), index, frames.count)
            }
            // Its own time, less what decoding it took
            let wait = Duration.seconds(frames.delays[index]) - (ContinuousClock.now - started)
            if wait > .zero { try? await Task.sleep(for: wait) }
            index = (index + 1) % frames.count
        }
    }
}

/// The frames of an animated picture (GIF, also animated PNG and WebP):
/// decoded at a given size, kept while they fit in `budget`, else decoded
/// again each round.
final class AnimationFrames: @unchecked Sendable {
    let count: Int
    /// Seconds per frame, as browsers show them (under 20 ms counts as 100 ms).
    let delays: [Double]
    private let source: CGImageSource
    private let side: Int
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

    /// nil for a picture of one frame (or one that can't be read).
    static func open(_ url: URL, side: Int) async -> AnimationFrames? {
        guard let source = await MediaData.imageSource(url) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        return AnimationFrames(source: source, count: count, side: side)
    }

    static func delay(of source: CGImageSource, at index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dictionaries = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary]
        for key in dictionaries {
            guard let info = props?[key] as? [CFString: Any] else { continue }
            let unclamped = info[kCGImagePropertyGIFUnclampedDelayTime] ?? info[kCGImagePropertyAPNGUnclampedDelayTime]
                ?? info[kCGImagePropertyWebPUnclampedDelayTime]
            let clamped = info[kCGImagePropertyGIFDelayTime] ?? info[kCGImagePropertyAPNGDelayTime] ?? info[kCGImagePropertyWebPDelayTime]
            if let seconds = ((unclamped ?? clamped) as? NSNumber)?.doubleValue {
                return seconds < 0.02 ? 0.1 : seconds
            }
        }
        return 0.1
    }

    /// Frame `index`, with `look` when it changes anything.
    func frame(_ index: Int, look: Look?) -> CGImage? {
        guard index >= 0, index < count else { return nil }
        lock.lock()
        var decoded = kept[index]
        lock.unlock()
        if decoded == nil {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: side
            ]
            decoded = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
            if keeps, let decoded { lock.lock(); kept[index] = decoded; lock.unlock() }
        }
        guard let decoded else { return nil }
        guard let look, !look.isNeutral else { return decoded }
        return Look.render(decoded, with: look) ?? decoded
    }
}

/// SVG and PDF: AppKit's `NSImage` draws them as vector pictures at any
/// size (ImageIO doesn't read SVG, and gives a PDF page neither a size nor
/// more than its 72 dpi pixels). A PDF shows its first page.
enum VectorPicture {
    /// Drawn no larger than this (at most a 64 MB picture, 4096 × 4096 × 4
    /// bytes, at full zoom; the adjusted copy needs as much again).
    static let largestSide = 4096

    static func isVector(_ url: URL) -> Bool { ["svg", "pdf"].contains(url.pathExtension.lowercased()) }

    /// The picture, from disk or from inside an archive (`MediaData`).
    private static func image(_ url: URL) async -> NSImage? {
        guard let data = try? await MediaData.read(url) else { return nil }
        return NSImage(data: data)
    }

    /// The picture's own size (points from its width/height or viewBox).
    static func size(of url: URL) async -> CGSize? {
        guard let image = await image(url), image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size
    }

    /// Drawn with its longest side `longestSide` pixels, on its own
    /// background (transparent where the SVG draws nothing); with its size.
    static func render(_ url: URL, longestSide: Int) async -> (CGImage, CGSize)? {
        guard let image = await image(url) else { return nil }
        return render(image, longestSide: longestSide)
    }

    private static func render(_ image: NSImage, longestSide: Int) -> (CGImage, CGSize)? {
        guard image.size.width > 0, image.size.height > 0, image.size.width.isFinite, image.size.height.isFinite else { return nil }
        let size = image.size
        let scale = CGFloat(max(longestSide, 1)) / max(size.width, size.height)
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = context.makeImage() else { return nil }
        return (cg, size)
    }
}
