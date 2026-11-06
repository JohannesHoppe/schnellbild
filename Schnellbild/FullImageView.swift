import SwiftUI
import ImageIO
import AppKit

/// Full-size view for still images. Loads the image via ImageIO downsampled
/// directly to screen size. Zoom: keys +/-/0/1 (via the model) and
/// trackpad pinch; dragging pans when zoomed in.
struct FullImageView: View {
    let url: URL

    @EnvironmentObject var model: BrowserModel
    @State private var image: NSImage?
    /// The loaded picture, and its enhanced version while auto enhance is on.
    @State private var picture: CGImage?
    @State private var enhanced: NSImage?
    @State private var nativeSize: CGSize?
    @State private var panOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let shown = model.enhance ? (enhanced ?? image) : image {
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
                if let thumb = ThumbnailCache.shared.image(for: url) {
                    image = thumb
                }
                let scale = NSScreen.mainBackingScale
                let maxPixel = max(Int(max(geo.size.width, geo.size.height) * scale), 1)
                await load(maxPixel: maxPixel)
                updateActualSizeFactor(in: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                updateActualSizeFactor(in: newSize)
            }
            .task(id: EnhanceJob(url: url, on: model.enhance, ready: picture != nil)) {
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
            enhanced = nil
        }
    }

    /// Exposes the view transform, e.g. "zoom 125 %, rotation 90°, loaded".
    private var accessibilityState: String {
        "zoom \(Int((model.zoom * 100).rounded())) %, rotation \(Int(model.rotation))°, "
            + (image == nil ? "loading" : "loaded")
            + (model.enhance && enhanced != nil ? ", enhanced" : "")
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

        if !Task.isCancelled, let result {
            image = result.0
            nativeSize = result.1
            enhanced = nil
            picture = result.2
        }
    }

    private struct EnhanceJob: Equatable {
        let url: URL
        let on: Bool
        let ready: Bool
    }

    /// Work out the enhanced picture when auto enhance is on (off the main
    /// thread; kept while it stays on).
    private func enhance() async {
        guard model.enhance, enhanced == nil, let picture else { return }
        let result = await Task.detached(priority: .userInitiated) {
            EnhanceRecipe.enhanced(picture)
        }.value
        guard !Task.isCancelled, let result else { return }
        enhanced = NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }
}
