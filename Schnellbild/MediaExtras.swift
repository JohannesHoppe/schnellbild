import SwiftUI
import AppKit
import ImageIO
import VLCFrames

/// Runs `work` off the main actor; cancelling the caller cancels it too, so
/// what it awaits (an archive read) stops, and it can skip what is left.
func detachedCancellable<T: Sendable>(priority: TaskPriority, _ work: @escaping @Sendable () async -> T) async -> T {
    let task = Task.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}

/// Small file inspector (key "i" in the full-size view).
struct InspectorView: View {
    let entry: GridEntry
    @EnvironmentObject var model: BrowserModel
    @State private var dimensions: String?
    @State private var taken: Date?
    @State private var facts: FileFacts?
    @State private var streams: StreamFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.name)
                .font(.headline)
                .lineLimit(3)
            infoRow("Kind", kindText)
            if let format = facts?.format {
                infoRow("Format", format)
            }
            if let dimensions {
                infoRow("Resolution", dimensions)
            }
            if let video = streams?.video {
                infoRow("Video", video)
            }
            if let audio = streams?.audio {
                infoRow("Audio", audio)
            }
            if let seconds = streams?.seconds, seconds.isFinite, seconds > 0 {
                infoRow("Duration", Self.duration(seconds))
            }
            if let bitrate = StreamFacts.bitrate(bytes: entry.byteSize, seconds: streams?.seconds) {
                infoRow("Bitrate", StreamFacts.describeBitrate(bitrate))
            }
            if let depth = facts?.depth, depth > 0 {
                infoRow("Bit Depth", "\(depth) bit")
            }
            if let profile = facts?.profile {
                infoRow("Profile", profile)
            }
            if let camera = facts?.camera {
                infoRow("Camera", camera)
            }
            if let size = entry.byteSize {
                infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let taken {
                infoRow("Date Taken", taken.formatted(date: .abbreviated, time: .shortened))
            }
            if let date = entry.modDate {
                infoRow("Date Modified", date.formatted(date: .abbreviated, time: .shortened))
            }
            if let recommended = facts?.recommendedExtension {
                let content = facts?.format ?? ""
                Label(String(localized: "The file extension doesn't match the content (\(content)). Recommended: .\(recommended)"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wrongExtension")
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task(id: entry.url) { await loadDimensions() }
        .task(id: entry.url) { await loadCaptureDate() }
        .task(id: entry.url) { await loadFacts() }
        .task(id: entry.url) { await loadStreams() }
    }

    /// "3:05", "1:02:07".
    static func duration(_ seconds: Double) -> String {
        let length = Duration.seconds(Int(seconds.rounded()))
        return length.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// The format by the content, and whether the extension fits it.
    private func loadFacts() async {
        facts = nil
        let url = entry.url
        let kind = entry.kind
        let found = await detachedCancellable(priority: .utility) { () -> FileFacts? in
            switch kind {
            case .image:
                guard !VectorPicture.isVector(url), let source = await MediaData.imageSource(url) else { return nil }
                return FileFacts.picture(source, named: url)
            case .video:
                // Inside an archive there are no first bytes to read without unpacking
                guard !ArchivePath.isInside(url) else { return nil }
                return FileFacts.video(head: VLCSafety.head(of: url), named: url)
            default:
                return nil
            }
        }
        guard !Task.isCancelled else { return }
        facts = found
    }

    /// The codecs, from the player once it has opened the video.
    private func loadStreams() async {
        streams = nil
        guard entry.kind == .video else { return }
        for _ in 0..<40 {
            if model.activePlayerURL == entry.url, let player = model.activePlayer,
               let found = await player.streamFacts(), !found.isEmpty {
                guard !Task.isCancelled else { return }
                streams = found
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }

    /// The inspector shows only what the full view shows: a picture or a video.
    private var kindText: String {
        entry.kind == .video ? String(localized: "Video") : String(localized: "Picture")
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    /// EXIF's capture date (pictures), the creation date (videos).
    private func loadCaptureDate() async {
        taken = nil
        let url = entry.url
        let found = await detachedCancellable(priority: .utility) { await BrowserModel.captureDate(of: url) }
        guard !Task.isCancelled else { return }
        taken = found
    }

    private func loadDimensions() async {
        dimensions = nil
        if entry.kind == .video {
            // The player knows it once the video has opened.
            for _ in 0..<40 {
                if model.activePlayerURL == entry.url,
                   let size = model.activePlayer?.videoSize, size.width > 0, size.height > 0 {
                    dimensions = "\(Int(size.width)) × \(Int(size.height)) px"
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            return
        }
        guard entry.kind == .image else { return }
        let url = entry.url
        let found = await detachedCancellable(priority: .utility) { () -> String? in
            guard let size = await MediaInfo.pixelSize(ofAnywhere: url) else { return nil }
            // An SVG states its size as it likes ("1e20")
            guard size.width.isFinite, size.height.isFinite else { return nil }
            return "\(Int(max(0, min(size.width, 1e15)))) × \(Int(max(0, min(size.height, 1e15)))) px"
        }
        // Paged on meanwhile: the next picture's size is on its way
        guard !Task.isCancelled else { return }
        dimensions = found
    }
}

/// Shared ImageIO helpers.
enum MediaInfo {
    /// Pixel dimensions as shown, from an already-open image source (no
    /// extra file open): EXIF orientations 5 to 8 (a camera held upright)
    /// swap width and height, as the picture is shown turned.
    static func pixelSize(from source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Pixel dimensions, also of a picture inside an archive; for an SVG or
    /// PDF its own size.
    static func pixelSize(ofAnywhere url: URL) async -> CGSize? {
        if VectorPicture.isVector(url) { return await VectorPicture.size(of: url) }
        guard let source = await MediaData.imageSource(url) else { return nil }
        return pixelSize(from: source)
    }
}

extension NSScreen {
    /// Backing scale of the main display, with a sane fallback.
    static var mainBackingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
    /// Backing scale of the display the app's window is on (100 % means
    /// one picture pixel per pixel there, also on a second display).
    @MainActor static var windowBackingScale: CGFloat { BrowserModel.appWindow?.backingScaleFactor ?? mainBackingScale }
}

/// The white loading spinner shown over the black full-size background.
struct LoadingSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
    }
}
