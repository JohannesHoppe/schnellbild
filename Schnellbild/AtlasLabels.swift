import SwiftUI

// The Atlas's overlays with words on them: the header over the map, the
// timeline's labels and the tour's place count. Each word sizes to itself
// in every language (`fixedSize`, controls drawn by SwiftUI, never a width
// given to a label); where a pane is too narrow for one row, the parts go
// onto two (`ViewThatFits`). Their texts come in localized, so
// `AtlasLabelTests` lays them out in all 20 languages.

/// The header's texts, localized by the caller.
struct AtlasHeaderTexts {
    var tour: String
    var tourHelp: String
    var tourLabel: String
    /// The key of the tour, as on the keyboard ("T"); nil without one.
    var tourKey: String?
    /// "13 on the map", or the reading's progress.
    var count: String
    var subfolders: String
    var subfoldersHelp: String
    var walking: String

    @MainActor
    static func localized(onMap: Int, progress: BrowserModel.Progress?, shortcuts: Shortcuts) -> AtlasHeaderTexts {
        AtlasHeaderTexts(
            tour: String(localized: "Tour"),
            tourHelp: String(localized: "Play the tour: the places in the order of time, full screen (\(shortcuts.hint(.startTour)))"),
            tourLabel: String(localized: "Play the tour"),
            tourKey: shortcuts.keys(.startTour).first?.capText,
            count: progress.map { String(localized: "Reading locations: \($0.done) of \($0.total)") } ?? String(localized: "\(onMap) on the map"),
            subfolders: String(localized: "Include subfolders"),
            subfoldersHelp: String(localized: "The photos and videos of every subfolder too, archives included"),
            walking: String(localized: "Reading subfolders…"))
    }
}

/// The header over the map: Tour, the count (or the reading's progress),
/// Include subfolders; on one row where it fits, else on two.
struct AtlasHeader: View {
    let texts: AtlasHeaderTexts
    let progress: BrowserModel.Progress?
    let tourEnabled: Bool
    /// Include subfolders shows (not while searching: the results come from every subfolder anyway).
    let showsSubfolders: Bool
    @Binding var subfolders: Bool
    let walking: Bool
    let onTour: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tourButton
                divider
                countLabel
                if showsSubfolders {
                    divider
                    subfolderToggle
                }
            }
            .modifier(HeaderChrome(shape: .capsule))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    tourButton
                    divider
                    countLabel
                }
                if showsSubfolders { subfolderToggle }
            }
            .modifier(HeaderChrome(shape: .rounded))
            // The narrowest panes: one part a row, the progress over its words
            VStack(alignment: .leading, spacing: 4) {
                tourButton
                countLabel(stacked: true)
                if showsSubfolders { subfolderToggle(stacked: true) }
            }
            .modifier(HeaderChrome(shape: .rounded))
        }
    }

    private var divider: some View { Divider().frame(height: 14) }

    // (each part on its own for `AtlasLabelTests`)
    var tourButton: some View {
        Button(action: onTour) {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                Text(verbatim: texts.tour).fixedSize()
                if let key = texts.tourKey { KeyCap(key) }
            }
        }
        .buttonStyle(HeaderButtonStyle())
        .disabled(!tourEnabled)
        .help(texts.tourHelp)
        .accessibilityLabel(Text(verbatim: texts.tourLabel))
        .accessibilityIdentifier("tourButton")
    }

    var countLabel: some View { countLabel(stacked: false) }

    func countLabel(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 50)
            }
            // (one part a row: words that don't fit go onto the next line, never cut)
            Text(verbatim: texts.count).fixedSize(horizontal: !stacked, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("atlasCount")
    }

    var subfolderToggle: some View { subfolderToggle(stacked: false) }

    func subfolderToggle(stacked: Bool) -> some View {
        HStack(spacing: 6) {
            // (one part a row: the words go onto a second line rather than out of the pane)
            Toggle(isOn: $subfolders) { Text(verbatim: texts.subfolders).font(.caption).fixedSize(horizontal: !stacked, vertical: true) }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .fixedSize(horizontal: !stacked, vertical: true)
                .help(texts.subfoldersHelp)
                .accessibilityIdentifier("atlasSubfolders")
            if walking {
                ProgressView().controlSize(.mini)
                    .help(texts.walking)
                    .accessibilityLabel(Text(verbatim: texts.walking))
                    .accessibilityIdentifier("atlasWalking")
            }
        }
    }
}

/// The header's material and outline: a capsule on one row, a rounded box on two.
private struct HeaderChrome: ViewModifier {
    enum Shape { case capsule, rounded }
    let shape: Shape

    func body(content: Content) -> some View {
        let padded = content.padding(.horizontal, 10).padding(.vertical, 6)
        switch shape {
        case .capsule:
            padded.background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.separator, lineWidth: 0.5))
        case .rounded:
            padded.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        }
    }
}

/// A button drawn by SwiftUI that sizes to its label in every language (a
/// borderless button showed "Viag…" and "Mat…" for Portuguese's "Viagem"
/// and Finnish's "Matka" in the screenshots): pressed it dims, disabled it fades.
struct HeaderButtonStyle: ButtonStyle {
    /// The word's colour: as the bar's other words, or the accent for a link (Show All).
    var link = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(!enabled ? Color.secondary : link ? Color.accentColor : Color.primary)
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// The timeline's texts, localized by the caller.
struct TimelineTexts {
    var from: String
    var to: String
    /// "6 of 14" while narrowed; nil for the whole span.
    var count: String?
    var showAll: String
    var showAllHelp: String
}

/// The timeline's labels: the range's start and end, and while narrowed
/// the count and Show All; on one row where they fit, else on two.
struct TimelineLabels: View {
    let texts: TimelineTexts
    let onShowAll: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                from
                Spacer(minLength: 8)
                narrowed
                Spacer(minLength: 8)
                to
            }
            VStack(spacing: 2) {
                HStack {
                    from
                    Spacer(minLength: 8)
                    to
                }
                HStack { narrowed }
            }
            // The narrowest panes: one part a row
            VStack(alignment: .leading, spacing: 2) {
                from
                to
                HStack { narrowed }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    var from: some View { Text(verbatim: texts.from).fixedSize().accessibilityIdentifier("timeline.from") }
    var to: some View { Text(verbatim: texts.to).fixedSize().accessibilityIdentifier("timeline.to") }

    @ViewBuilder var narrowed: some View {
        if let count = texts.count {
            Text(verbatim: count).fixedSize().accessibilityIdentifier("timeline.count")
            Button(action: onShowAll) { Text(verbatim: texts.showAll).fixedSize() }
                .buttonStyle(HeaderButtonStyle(link: true))
                .help(texts.showAllHelp)
                .accessibilityIdentifier("timeline.all")
        }
    }
}
