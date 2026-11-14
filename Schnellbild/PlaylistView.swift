import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Lays the slideshow's playlist (P) beside the picture: over it (the
/// default) or pinned, the picture making room. It slides in from the
/// right edge (not with Reduce motion). A click on the picture hands the
/// keys back to the show.
struct PlaylistLayout: ViewModifier {
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        let shown = model.slideshow != nil && model.showPlaylist
        let pinned = model.playlistPinned
        GeometryReader { geometry in
            let width = PlaylistPanel.width(model.playlistWidth, total: geometry.size.width)
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded { model.playlistFocused = false },
                                         including: shown && model.playlistFocused ? .all : .subviews)
                if shown, pinned {
                    PlaylistPanel(width: width).transition(.move(edge: .trailing))
                }
            }
            .overlay(alignment: .trailing) {
                if shown, !pinned {
                    PlaylistPanel(width: width)
                        .shadow(color: .black.opacity(0.25), radius: 8)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(Motion.animation(.easeOut(duration: 0.25)), value: shown)
        .animation(Motion.animation(.easeOut(duration: 0.25)), value: pinned)
    }
}

/// The playlist: the slideshow's items in the order they play, each with
/// its preview and name, the one on screen marked. Drag to reorder, a
/// click shows the item (and gives the list ↑ ↓ ⌫ ↩), ⌫ takes the chosen
/// one out of the show (the file stays). Pin and close at the top right,
/// the width by the grip on the left edge (a double click: the standard
/// width).
struct PlaylistPanel: View {
    let width: CGFloat
    @EnvironmentObject var model: BrowserModel

    private static let previewSide: CGFloat = 40
    /// A row's height: the preview and its padding.
    static let rowHeight: CGFloat = previewSide + 6

    /// The width shown: the one chosen, at most most of the pane.
    static func width(_ chosen: Double, total: CGFloat) -> CGFloat {
        min(CGFloat(chosen), max(total * 0.6, CGFloat(BrowserModel.playlistWidthRange.lowerBound)))
    }

    var body: some View {
        HStack(spacing: 0) {
            PlaylistGrip()
            VStack(spacing: 0) {
                header
                Divider()
                list
                Divider()
                footer
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
        // The pointer stays visible while the playlist is open
        .onAppear { NSCursor.setHiddenUntilMouseMoves(false) }
        .onContinuousHover { _ in NSCursor.setHiddenUntilMouseMoves(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playlist")
        .accessibilityIdentifier("playlist")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Playlist").font(.headline)
            if let show = model.slideshow {
                Text(verbatim: show.loading ? String(localized: "\(show.items.count) so far") : "\(show.items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.playlistPinned.toggle() } label: {
                Image(systemName: model.playlistPinned ? "pin.fill" : "pin")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.playlistPinned ? Color.accentColor : Color.secondary)
            .help(model.playlistPinned ? "Unpin: the playlist lies over the picture" : "Pin: the picture makes room for the playlist")
            .accessibilityLabel(model.playlistPinned ? "Unpin playlist" : "Pin playlist")
            .accessibilityIdentifier("playlistPin")
            Button { model.closePlaylist() } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close the playlist (P)")
            .accessibilityLabel("Close playlist")
            .accessibilityIdentifier("playlistClose")
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    // MARK: List

    /// A row dragged within the playlist; only the playlist's rows take it
    /// (not the panes, tiles or the window's drop zones).
    static let dragType = UTType(exportedAs: "art.haushoppe.schnellbild.playlist-item")

    private var list: some View {
        let items = model.slideshow?.items ?? []
        let shownIndex = model.slideshow?.index ?? -1
        let cursor = model.playlistCursorIndex
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, shown: index == shownIndex, chosen: index == cursor)
                            .id(item.id)
                    }
                }
                .padding(4)
            }
            // A click on the list's free space gives it the keys too
            .contentShape(Rectangle())
            .onTapGesture { model.playlistFocused = true }
            // The list has the keys: outlined
            .overlay {
                if model.playlistFocused {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .onAppear { scroll(proxy, to: model.slideshow?.current?.id) }
            .onChange(of: model.slideshow?.current?.id) { _, id in
                if !model.playlistFocused { scroll(proxy, to: id) }
            }
            .onChange(of: model.playlistCursor) { _, _ in
                scroll(proxy, to: model.playlistCursorIndex.flatMap { model.slideshow?.items[$0].id })
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: URL?) {
        guard let id else { return }
        proxy.scrollTo(id)
    }

    /// Where a dragged row would land: before (`after` false) or after the row at `index`.
    @State private var dropMark: (index: Int, after: Bool)?
    /// The row being dragged.
    @State private var dragged: URL?

    private func row(_ item: GridEntry, index: Int, shown: Bool, chosen: Bool) -> some View {
        // The chosen row is filled (the accent while the list has the keys,
        // grey otherwise); the item on screen has the play mark and a bold name
        let filled = chosen && model.playlistFocused
        return HStack(spacing: 8) {
            ThumbnailView(url: item.url, side: Self.previewSide, isSelected: false, isVideo: false, modified: item.modDate)
                .frame(width: Self.previewSide, height: Self.previewSide)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .fontWeight(shown ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.kind == .video ? "Video" : "Picture")
                    .font(.caption)
                    .foregroundStyle(filled ? Color.white.opacity(0.85) : Color.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(filled ? Color.white : Color.accentColor)
                .opacity(shown ? 1 : 0)
        }
        .font(.callout)
        .foregroundStyle(filled ? Color.white : Color.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            filled ? Color.accentColor : chosen ? Color.primary.opacity(0.12) : Color.clear))
        // Where a dragged row would land
        .overlay(alignment: dropMark?.after == true ? .bottom : .top) {
            if dropMark?.index == index {
                Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: dropMark?.after == true ? 2 : -2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.clickPlaylistItem(at: index) }
        .onDrag {
            dragged = item.url
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess) { done in
                done(Data(item.url.path.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [Self.dragType], delegate: PlaylistRowDrop(index: index, mark: $dropMark) { after in
            guard let dragged, let from = model.slideshow?.items.firstIndex(where: { $0.url == dragged }) else { return false }
            model.moveSlideshowItems(from: [from], to: after ? index + 1 : index)
            self.dragged = nil
            return true
        })
        .contextMenu {
            Button("Show") { model.clickPlaylistItem(at: index) }
            Button("Move Up") { model.moveSlideshowItems(from: [index], to: index - 1) }
                .disabled(index == 0)
            Button("Move Down") { model.moveSlideshowItems(from: [index], to: index + 2) }
                .disabled(index + 1 >= (model.slideshow?.items.count ?? 0))
            Divider()
            Button("Take Out of Playlist (the File Stays)") { model.removeFromSlideshow(at: [index]) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EntryAccessibility.label(item, emptyFolder: false, location: nil))
        .accessibilityValue(shown ? String(localized: "Now showing") : "")
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { model.clickPlaylistItem(at: index) }
        .accessibilityAction(named: Text("Move Up")) {
            if index > 0 { model.moveSlideshowItems(from: [index], to: index - 1) }
        }
        .accessibilityAction(named: Text("Move Down")) { model.moveSlideshowItems(from: [index], to: index + 2) }
        .accessibilityAction(named: Text("Take Out of Playlist (the File Stays)")) { model.removeFromSlideshow(at: [index]) }
        .accessibilityIdentifier("playlist.\(item.name)")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.slideshow?.loading == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Adding from subfolders…").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Button {
                    if let index = model.playlistCursorIndex { model.removeFromSlideshow(at: [index]) }
                } label: {
                    ShortcutLabel("Take Out of Playlist", systemImage: "minus.circle", keys: "⌫", showsTitle: true)
                }
                .buttonStyle(.plain)
                .disabled(model.playlistCursorIndex == nil)
                .help("Take the chosen item out of the playlist (⌫ after a click in the list); the file stays where it is")
                .accessibilityIdentifier("playlistTakeOut")
            }
            Text("The file stays where it is.").foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// A row of the playlist as a drop target: the upper half puts the dragged
/// row before it, the lower half after it.
private struct PlaylistRowDrop: DropDelegate {
    let index: Int
    @Binding var mark: (index: Int, after: Bool)?
    let drop: (_ after: Bool) -> Bool

    private func after(_ info: DropInfo) -> Bool { info.location.y > PlaylistPanel.rowHeight / 2 }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [PlaylistPanel.dragType]) }
    func dropEntered(info: DropInfo) { mark = (index, after(info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        mark = (index, after(info))
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if mark?.index == index { mark = nil } }
    func performDrop(info: DropInfo) -> Bool {
        mark = nil
        return drop(after(info))
    }
}

/// The playlist's left edge: dragged, it widens or narrows the playlist; a
/// double click gives it the standard width. Both are remembered.
private struct PlaylistGrip: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: PaneDivider.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? model.playlistWidth
                        startWidth = start
                        model.setPlaylistWidth(start - Double(drag.translation.width))
                    }
                    .onEnded { _ in
                        startWidth = nil
                        model.setPlaylistWidth(model.playlistWidth, remember: true)
                    }
            )
            .onTapGesture(count: 2) { model.setPlaylistWidth(nil, remember: true) }
            .accessibilityElement()
            .accessibilityIdentifier("playlistGrip")
            .accessibilityLabel("Playlist width")
            .help("Drag to widen or narrow the playlist; double-click: standard width")
    }
}
