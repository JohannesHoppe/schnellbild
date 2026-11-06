import SwiftUI
import ImageIO
import CoreImage
import AppKit

/// Full-size view for still images. Loads the image via ImageIO downsampled
/// directly to screen size. Zoom: keys +/-/0/1 (via the model) and
/// trackpad pinch; dragging pans when zoomed in.
struct FullImageView: View {
    let url: URL

    @EnvironmentObject var model: BrowserModel
    @State private var image: NSImage?
    /// The loaded picture, auto enhance's look for it, and the picture with
    /// the look on screen (`model.enhancement`).
    @State private var picture: CGImage?
    @State private var autoLook: Look?
    @State private var enhanced: (look: Look, image: NSImage)?
    @State private var nativeSize: CGSize?
    @State private var panOffset: CGSize = .zero
    /// The file couldn't be read as a picture.
    @State private var failed = false
    /// The longest side the picture was decoded at: screen size first, the
    /// full size once the user zooms in (a sharp picture where it matters).
    @State private var decodedSide = 0
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
                let scale = NSScreen.mainBackingScale
                let maxPixel = max(Int(max(geo.size.width, geo.size.height) * scale), 1)
                await load(maxPixel: maxPixel)
                updateActualSizeFactor(in: geo.size)
            }
            .task(id: FullSizeJob(url: url, zoomedIn: model.zoom > 1.01, ready: picture != nil)) {
                guard model.zoom > 1.01, let native = nativeSize else { return }
                let full = Int(max(native.width, native.height))
                guard full > decodedSide else { return }
                await load(maxPixel: full)
            }
            .onChange(of: geo.size) { _, newSize in
                updateActualSizeFactor(in: newSize)
            }
            .task(id: EnhanceJob(url: url, enhancement: model.enhancement, ready: picture != nil, side: decodedSide)) {
                await enhance()
            }
        }
        .onChange(of: model.zoom) { _, newValue in
            if newValue == 1 { panOffset = .zero }
        }
        .onChange(of: url) { _, _ in
            panOffset = .zero
            nativeSize = nil
            picture = nil
            autoLook = nil
            enhanced = nil
        }
    }

    /// With a look: the picture rendered with it; while a slider moves, the
    /// last rendered one until the next is ready.
    private var shownImage: NSImage? {
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
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                if model.zoom > 1 { state = value.translation }
            }
            .onEnded { value in
                guard model.zoom > 1 else { return }
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
        let scale = NSScreen.mainBackingScale
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

    private func load(maxPixel: Int) async {
        let url = self.url
        let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGSize, CGImage)? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
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
        }.value

        guard !Task.isCancelled else { return }
        guard let result else {
            image = nil   // not the tile's file icon: the file can't be shown
            failed = true
            return
        }
        image = result.0
        nativeSize = result.1
        decodedSide = max(result.2.width, result.2.height)
        enhanced = nil
        autoLook = nil
        picture = result.2
    }

    private struct FullSizeJob: Equatable {
        let url: URL
        let zoomedIn: Bool
        let ready: Bool
    }

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
        guard !Task.isCancelled, let look = shownLook, enhanced?.look != look else { return }
        let result = await Task.detached(priority: .userInitiated) {
            Look.render(picture, with: look)
        }.value
        guard !Task.isCancelled, let result else { return }
        enhanced = (look, NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height)))
    }
}
