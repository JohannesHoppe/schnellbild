import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: BrowserModel
    @FocusState private var focused: Bool
    @State private var isDropTargeted = false
    @State private var showInspector = false

    var body: some View {
        Group {
            if model.entries.isEmpty {
                EmptyStateView(isLoading: model.isLoading)
            } else if model.mode == .detail, let entry = model.selectedMediaEntry {
                detail(entry: entry)
            } else {
                ThumbnailGridView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drag & Drop: Ordner (oder Mediendatei) aufs Fenster ziehen.
        .dropDestination(for: URL.self) { urls, _ in
            model.openDropped(urls)
            return !urls.isEmpty
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .overlay { if isDropTargeted { dropHighlight } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.mode == .grid, model.folderURL != nil { statusBar }
        }
        // Tastatur-Fokus liegt auf dem ganzen Inhalt.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; model.restoreLastFolder() }
        .onChange(of: model.entries) { _, _ in focused = true }
        // Backspace eigens behandeln — der Sammel-onKeyPress liefert sie nicht
        // zuverlässig aus. Großansicht: zurück (wie Esc). Liste: Ebene höher.
        .onKeyPress(.delete) {
            if model.mode == .detail {
                model.closeDetail()
            } else {
                model.goToParentFolder()
            }
            return .handled
        }
        .onKeyPress { press in handle(press) }
        .toolbar { toolbarContent }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "Schnellbild")
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
            .padding(6)
            .allowsHitTesting(false)
    }

    // MARK: - Statusleiste

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(statusText).foregroundStyle(.secondary)
            if model.slideshowOn {
                Label("Diashow", systemImage: "play.fill").foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.folderURL?.path ?? "")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        var parts: [String] = []
        if model.folderCount > 0 { parts.append("\(model.folderCount) Ordner") }
        if model.imageCount  > 0 { parts.append("\(model.imageCount) Bilder") }
        if model.videoCount  > 0 { parts.append("\(model.videoCount) Videos") }
        return parts.isEmpty ? "Leer" : parts.joined(separator: " · ")
    }

    // MARK: - Großansicht (Bild / GIF / Video)

    @ViewBuilder
    private func detail(entry: GridEntry) -> some View {
        ZStack {
            if entry.kind == .video {
                VideoDetailView(url: entry.url)
            } else if entry.isGIF {
                ZStack { Color.black; AnimatedImageView(url: entry.url) }
            } else {
                FullImageView(url: entry.url)
            }
        }
        .overlay(alignment: .bottom) { positionBadge(entry: entry) }
        .overlay(alignment: .topTrailing) {
            if showInspector { InspectorView(entry: entry).padding(12) }
        }
    }

    private func positionBadge(entry: GridEntry) -> some View {
        Text("\(model.currentMediaNumber ?? 0) / \(model.mediaCount)  ·  \(entry.name)")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 16)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.chooseFolder() } label: {
                Label("Ordner öffnen", systemImage: "folder")
            }
        }
        if model.mode == .detail {
            ToolbarItem(placement: .principal) {
                Button { model.closeDetail() } label: {
                    Label("Übersicht", systemImage: "square.grid.2x2")
                }
            }
        }
    }

    // MARK: - Tastatur

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Vollbild modus-unabhängig.
        if press.characters == "f" {
            model.toggleFullScreen(); return .handled
        }

        // ⌘ + Pfeil: immer vorheriges/nächstes Medium (wie Phiewer).
        if press.modifiers.contains(.command) {
            switch press.key {
            case .leftArrow, .upArrow:
                model.mode == .detail ? model.stepMedia(-1) : model.step(-1)
                return .handled
            case .rightArrow, .downArrow:
                model.mode == .detail ? model.stepMedia(+1) : model.step(+1)
                return .handled
            default:
                break
            }
        }

        switch model.mode {
        case .grid:
            switch press.key {
            case .return, .space:
                model.activateSelection(); return .handled
            case .rightArrow:
                model.step(+1); return .handled
            case .leftArrow:
                model.step(-1); return .handled
            case .downArrow:
                model.stepRow(+1); return .handled
            case .upArrow:
                model.stepRow(-1); return .handled
            case .home:
                model.select(0); return .handled
            case .end:
                model.select(model.entries.count - 1); return .handled
            default:
                return .ignored
            }

        case .detail:
            switch press.characters {
            case "+", "=": model.zoomIn();         return .handled
            case "-":      model.zoomOut();        return .handled
            case "0":      model.zoomReset();      return .handled
            case "1":      model.zoomActualSize(); return .handled
            case "i":      showInspector.toggle(); return .handled
            case "s":      model.toggleSlideshow(); return .handled
            default:       break
            }
            let isVideo = model.selectedMediaEntry?.kind == .video
            switch press.key {
            case .escape, .return:
                model.closeDetail(); return .handled
            case .space:
                isVideo ? model.togglePlayPause() : model.stepMedia(+1)
                return .handled
            case .leftArrow:
                isVideo ? model.seekVideo(by: -10) : model.stepMedia(-1)
                return .handled
            case .rightArrow:
                isVideo ? model.seekVideo(by: +10) : model.stepMedia(+1)
                return .handled
            case .upArrow:
                model.stepMedia(-1); return .handled
            case .downArrow:
                model.stepMedia(+1); return .handled
            default:
                return .ignored
            }
        }
    }
}

struct EmptyStateView: View {
    let isLoading: Bool
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                Text("Lade Ordner…")
                    .foregroundStyle(.secondary)
            } else if model.folderURL != nil {
                Image(systemName: "folder")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Nichts zum Anzeigen")
                    .font(.title2)
                Text("Keine Bilder, Videos oder Unterordner hier.\nBackspace bringt dich eine Ebene höher.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Anderen Ordner öffnen…") { model.chooseFolder() }
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Kein Ordner geöffnet")
                    .font(.title2)
                Text("Ordner hierher ziehen — oder ⌘O bzw. den Button.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Ordner öffnen…") { model.chooseFolder() }
            }
        }
        .padding(40)
    }
}
