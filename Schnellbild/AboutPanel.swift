import AppKit
import SwiftUI

/// The About window: the app, its version and copyright, and every license
/// that comes with it, in full. Schnellbild's own MIT License first, then one
/// section per project the app carries (what it does here, whose it is, its
/// license, the license's text). The texts ship in the bundle: the repository's
/// LICENSE as `Contents/Resources/LICENSE`, the others in
/// `Contents/Resources/Licenses` (Scripts/build_app.sh, project.yml).
@MainActor
enum AboutPanel {
    private static var window: NSWindow?
    private static var keyMonitor: Any?

    /// A window of its own, large and resizable: the license texts run to
    /// about a megabyte (the libraries inside VLCKit).
    static func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            panel.title = String(localized: "About Schnellbild")
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 720, height: 480)
            panel.contentView = NSHostingView(rootView: AboutView(document: LicenseDocument.bundled()))
            panel.center()
            window = panel
            // The find bar's keys and ⌘↑ ⌘↓ go to the license text before the
            // app's menus (⌘F searches the browser, ⌘↑ goes up a folder)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let used = MainActor.assumeIsolated { () -> Bool in
                    guard let text = LicenseNSTextView.shown, let window = text.window,
                          event.window === window, window.isKeyWindow else { return false }
                    return text.handleKey(event)
                }
                return used ? nil : event
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The website's home page, in the language the UI shows (English at the
    /// root, every other language in its folder).
    static var website: String {
        website(for: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func website(for language: String) -> String {
        let site = "https://schnellbild.haushoppe-its.de/"
        return language == "en" ? site : site + language.lowercased() + "/"
    }

    /// The privacy policy on the website, in the language the UI shows
    /// (Scripts/build_site.py: English at the root, every other language in
    /// its folder, German's page named "datenschutz").
    static var privacyPolicy: String {
        privacyPolicy(for: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func privacyPolicy(for language: String) -> String {
        let site = "https://schnellbild.haushoppe-its.de/"
        switch language {
        case "en": return site + "privacy/"
        case "de": return site + "de/datenschutz/"
        default: return site + language.lowercased() + "/privacy/"
        }
    }

    static let repository = "https://github.com/JohannesHoppe/schnellbild"

    /// The VLCKit build the app carries: `VERSION` in Scripts/fetch_vlckit.sh
    /// (AboutPanelTests keeps them the same). Its release holds the complete
    /// source it was built from.
    static let vlckitBuild = "3.7.5-lgpl-20"
    static var vlckitRelease: String { "\(repository)/releases/tag/vlckit-\(vlckitBuild)" }

    /// The credit NASA Earth Observatory gives its Black Marble 2016 maps
    enum BlackMarble {
        static let credit = "NASA Earth Observatory images by Joshua Stevens, using Suomi NPP VIIRS data from Miguel Román, NASA GSFC"
    }

    /// The repository's LICENSE as the bundle carries it.
    static let ownLicense = "LICENSE"
    /// The file in `Licenses` that holds the license files of every library
    /// compiled into VLCKit, one part per library (Scripts/build_vlckit_lgpl.sh).
    static let vlckitLibraries = "VLCKit-third-party-licenses.txt"

    /// Every section of the license text, in order; `files` name the texts in
    /// `Licenses` (or `ownLicense`), shown in full after the section's facts.
    static var sections: [LicenseSection] {
        [
            LicenseSection(
                id: "schnellbild", name: "Schnellbild", listName: "Schnellbild: MIT License",
                holder: "© 2026 HAUS HOPPE - ITS (Johannes Hoppe)", license: "MIT License",
                notes: [String(localized: "Schnellbild's own code is free software under the MIT License. The components below keep their own licenses.")],
                link: repository,
                files: [.init(file: ownLicense)]),
            LicenseSection(
                id: "vlckit", name: "VLCKit 3.7.5 (libVLC 3.0.24)", listName: "VLCKit: GNU LGPL 2.1",
                use: String(localized: "plays the video formats macOS can't (AVI, MKV, WebM …)"),
                holder: String(localized: "© VideoLAN and the VLC authors"),
                license: "GNU Lesser General Public License 2.1 (LGPL-2.1-or-later)",
                notes: [
                    String(localized: "Schnellbild uses an LGPL-only build of VLCKit and libVLC, licensed under the GNU Lesser General Public License 2.1 and built from source without any of VLC's modules under the GPL. VLC as VideoLAN builds it also carries modules under the GPL; they are not in Schnellbild's build."),
                    String(localized: "Schnellbild's build makes eight small changes to VLC (Scripts/vlc-patches, 0001 to 0008): five to its subtitles, two to its audio output on macOS and one that leaves FFmpeg's files under the GPL out of the build."),
                    String(localized: "The complete source of this build, with these changes, is attached to its release: \(vlckitRelease). The script that builds it is Scripts/build_vlckit_lgpl.sh in Schnellbild's repository."),
                ],
                link: "https://code.videolan.org/videolan/VLCKit",
                files: [.init(file: "VLCKit-LGPL-2.1.txt")],
                children: [
                    LicenseSection(
                        id: "vlckit-libraries", name: String(localized: "Libraries included in VLCKit, each under its own license"),
                        listName: String(localized: "Libraries included in VLCKit"),
                        notes: [String(localized: "VLCKit includes FFmpeg and other libraries, each under its own license."),
                                String(localized: "These are the license files from each library's source, as Schnellbild's build collected them.")],
                        librariesFile: vlckitLibraries),
                ]),
            LicenseSection(
                id: "unrar", name: "UnRAR 7.2.7", listName: "UnRAR: " + String(localized: "UnRAR license"),
                use: String(localized: "reads RAR archives"),
                holder: "© Alexander Roshal", license: String(localized: "UnRAR license"),
                link: "https://www.rarlab.com",
                files: [.init(file: "UnRAR-license.txt")]),
            LicenseSection(
                id: "openstreetmap", name: "OpenStreetMap", listName: "OpenStreetMap: ODbL 1.0",
                use: String(localized: "map data for the offline map"),
                holder: String(localized: "© OpenStreetMap contributors"),
                license: "Open Database License (ODbL) 1.0",
                notes: [String(localized: "Made from Protomaps' OpenStreetMap build, with thanks to Protomaps. How the files are made is in Schnellbild's repository.")],
                link: "https://www.openstreetmap.org/copyright",
                files: [.init(heading: String(localized: "Notice of Schnellbild's map files"), file: "OpenStreetMap-data.txt"),
                        .init(heading: "Open Database License (ODbL) 1.0", file: "ODbL-1.0.txt"),
                        .init(heading: "Database Contents License (DbCL) 1.0", file: "DbCL-1.0.txt")]),
            LicenseSection(
                id: "globe", name: String(localized: "Globe data"), listName: String(localized: "Globe data"),
                use: String(localized: "the globe's elevation, night sky and city lights"),
                files: [.init(heading: String(localized: "Notice of Schnellbild's globe files"), file: "Globe-data.txt")],
                children: [
                    LicenseSection(
                        id: "etopo", name: "ETOPO 2022 (NOAA)", listName: "ETOPO 2022: CC0 1.0",
                        use: String(localized: "elevation and ocean depth on the globe"),
                        holder: String(localized: "None (public domain)"),
                        license: "Creative Commons CC0 1.0 Universal",
                        credit: "NOAA National Centers for Environmental Information. 2022: ETOPO 2022 15 Arc-Second Global Relief Model.",
                        notes: [String(localized: "Not to be used for navigation.")],
                        link: "https://doi.org/10.25921/fd45-gt74",
                        files: [.init(file: "CC0-1.0.txt")]),
                    LicenseSection(
                        id: "deep-star-maps", name: "Deep Star Maps 2020 (NASA)",
                        listName: "Deep Star Maps 2020: " + String(localized: "Public domain"),
                        use: String(localized: "the night sky behind the globe"),
                        holder: String(localized: "None (public domain)"),
                        license: String(localized: "Public domain"),
                        credit: "NASA/Goddard Space Flight Center Scientific Visualization Studio. Gaia DR2: ESA/Gaia/DPAC. Hipparcos, Tycho-2.",
                        notes: [String(localized: "No endorsement by NASA is implied.")],
                        link: "https://svs.gsfc.nasa.gov/4851",
                        files: [.init(file: "NASA-SVS-usage.txt")]),
                    LicenseSection(
                        id: "black-marble", name: "Black Marble 2016 (NASA)",
                        listName: "Black Marble 2016: " + String(localized: "NASA's media usage guidelines"),
                        use: String(localized: "the lights on the globe's night side"),
                        holder: "NASA",
                        license: String(localized: "NASA's media usage guidelines"),
                        credit: BlackMarble.credit,
                        notes: [String(localized: "No endorsement by NASA is implied.")],
                        link: "https://science.nasa.gov/earth/earth-observatory/earth-at-night/maps/",
                        files: [.init(file: "NASA-media-usage-guidelines.txt")]),
                    LicenseSection(
                        id: "blue-marble-next-generation", name: "Blue Marble: Next Generation (NASA)",
                        listName: "Blue Marble: Next Generation: " + String(localized: "NASA's media usage guidelines"),
                        use: String(localized: "the colours of the ground on the globe"),
                        holder: "NASA",
                        license: String(localized: "NASA's media usage guidelines"),
                        // As NASA asks: "please credit NASA Earth Observatory"
                        credit: "NASA Earth Observatory (produced by Reto Stöckli, NASA Earth Observatory, NASA Goddard Space Flight Center).",
                        notes: [String(localized: "No endorsement by NASA is implied.")],
                        link: "https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/",
                        files: [.init(file: "NASA-media-usage-guidelines.txt")]),
                    LicenseSection(
                        id: "blue-marble-clouds", name: "The Blue Marble: clouds (NASA)",
                        listName: "The Blue Marble: " + String(localized: "NASA's media usage guidelines"),
                        use: String(localized: "the clouds on the globe"),
                        holder: "NASA",
                        license: String(localized: "NASA's media usage guidelines"),
                        credit: "NASA Goddard Space Flight Center. Image by Reto Stöckli.",
                        notes: [String(localized: "No endorsement by NASA is implied.")],
                        link: "https://science.nasa.gov/earth/earth-observatory/the-blue-marble-true-color-global-imagery-at-1km-resolution/",
                        files: [.init(file: "NASA-media-usage-guidelines.txt")]),
                ]),
        ]
    }
}

/// One project in the license text: its name, what it does in Schnellbild,
/// whose it is, its license and that license's full text; `children` are
/// sections inside it (the libraries VLCKit carries, the globe's sources).
struct LicenseSection: Identifiable {
    struct FileRef {
        var heading: String? = nil
        let file: String
    }

    /// A text shown in full, under its own heading where it has one.
    struct Part {
        var heading: String?
        var body: String
    }

    let id: String
    /// The heading in the text
    let name: String
    /// The name in the list beside the text ("VLCKit: GNU LGPL 2.1")
    let listName: String
    var use: String? = nil
    var holder: String? = nil
    var license: String? = nil
    var credit: String? = nil
    var notes: [String] = []
    var link: String? = nil
    var files: [FileRef] = []
    /// A file of several libraries' licenses, one child section per library
    var librariesFile: String? = nil
    var children: [LicenseSection]? = nil
    /// The texts, once read (`LicenseDocument.load`)
    var parts: [Part] = []

    /// Every file this section and the ones inside it show.
    var allFiles: [String] {
        files.map(\.file) + (librariesFile.map { [$0] } ?? []) + (children ?? []).flatMap(\.allFiles)
    }
}

/// The license text as the window shows it: every section read and laid out
/// in one attributed string, and where each section begins in it.
struct LicenseDocument {
    let sections: [LicenseSection]
    let text: NSAttributedString
    /// Each section's id and the offset of its heading, in text order
    let starts: [(id: String, offset: Int)]

    /// From the app's bundle.
    @MainActor static func bundled() -> LicenseDocument {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")
        return load(licenses: resources.appendingPathComponent("Licenses"),
                    ownLicense: resources.appendingPathComponent(AboutPanel.ownLicense))
    }

    /// Reads every section's texts: from `licenses`, the app's own license
    /// from `ownLicense`.
    @MainActor static func load(licenses: URL, ownLicense: URL) -> LicenseDocument {
        func read(_ file: String) -> String {
            let url = file == AboutPanel.ownLicense ? ownLicense : licenses.appendingPathComponent(file)
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "(\(file) is missing)"
        }
        func resolve(_ section: LicenseSection) -> LicenseSection {
            var section = section
            section.parts += section.files.map { .init(heading: $0.heading, body: read($0.file)) }
            if let file = section.librariesFile {
                let split = splitLibraries(read(file))
                section.parts.append(.init(heading: nil, body: split.intro))
                section.children = (section.children ?? []) + split.libraries.map { library in
                    LicenseSection(id: "\(section.id).\(library.name)", name: library.name, listName: library.name,
                                   parts: [.init(heading: nil, body: library.text)])
                }
            }
            section.children = section.children.map { $0.map(resolve) }
            return section
        }
        let sections = AboutPanel.sections.map(resolve)
        let (text, starts) = LicenseLayout.render(sections)
        return LicenseDocument(sections: sections, text: text, starts: starts)
    }

    /// The parts of VLCKit-third-party-licenses.txt: what comes before the
    /// first library, then each library under its name, as
    /// Scripts/build_vlckit_lgpl.sh writes them (a line of 80 "=", the name,
    /// a line of 80 "=").
    static func splitLibraries(_ text: String) -> (intro: String, libraries: [(name: String, text: String)]) {
        let rule = String(repeating: "=", count: 80)
        let lines = text.components(separatedBy: "\n")
        var intro: [String] = []
        var libraries: [(name: String, lines: [String])] = []
        var i = 0
        while i < lines.count {
            if lines[i] == rule, i + 2 < lines.count, lines[i + 2] == rule, !lines[i + 1].isEmpty {
                libraries.append((lines[i + 1], []))
                i += 3
                continue
            }
            if libraries.isEmpty { intro.append(lines[i]) } else { libraries[libraries.count - 1].lines.append(lines[i]) }
            i += 1
        }
        func trimmed(_ lines: [String]) -> String {
            lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        return (trimmed(intro), libraries.map { ($0.name, trimmed($0.lines)) })
    }
}

/// How the license text looks: a heading per section (a rule above each
/// project), its facts as labelled lines, its notes, then each text in a
/// fixed-width font as written. Colours are the system's, so light and dark
/// follow by themselves.
enum LicenseLayout {
    @MainActor static func render(_ sections: [LicenseSection]) -> (NSAttributedString, [(id: String, offset: Int)]) {
        let out = NSMutableAttributedString()
        var starts: [(id: String, offset: Int)] = []

        func paragraph(spacingBefore: CGFloat = 0, after: CGFloat = 0, block: NSTextBlock? = nil) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = after
            if let block { style.textBlocks = [block] }
            return style
        }
        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let value: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]

        func fact(_ name: String, _ text: String?, link: Bool = false) {
            guard let text, !text.isEmpty else { return }
            let style = paragraph(after: 3)
            add(name + ": ", label.merging([.paragraphStyle: style]) { $1 })
            var attributes = value.merging([.paragraphStyle: style]) { $1 }
            if link, let url = URL(string: text) { attributes[.link] = url }
            add(text + "\n", attributes)
        }

        func section(_ s: LicenseSection, depth: Int) {
            if out.length > 0, !out.string.hasSuffix("\n") { add("\n", value) }
            starts.append((s.id, out.length))
            let size: CGFloat = depth == 0 ? 22 : depth == 1 ? 17 : 14
            var style = paragraph(spacingBefore: depth == 0 ? 0 : 18, after: 8)
            if depth == 0, out.length > 0 {
                // A rule above each project
                let block = NSTextBlock()
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(36, type: .absoluteValueType, for: .margin, edge: .minY)
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setBorderColor(.separatorColor, for: .minY)
                style = paragraph(after: 8, block: block)
            }
            add(s.name + "\n", [.font: NSFont.systemFont(ofSize: size, weight: depth == 2 ? .semibold : .bold),
                                .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            fact(String(localized: "In Schnellbild"), s.use)
            fact(String(localized: "Copyright"), s.holder)
            fact(String(localized: "License"), s.license)
            fact(String(localized: "Credit"), s.credit)
            fact(String(localized: "Website"), s.link, link: true)
            for note in s.notes {
                let start = out.length
                add(note + "\n", value.merging([.paragraphStyle: paragraph(spacingBefore: 4, after: 4)]) { $1 })
                // The web addresses in a note open in the browser (only
                // written-out ones: "build_vlckit_lgpl.sh" reads as a domain)
                let range = NSRange(location: start, length: out.length - start)
                let string = out.string as NSString
                links?.enumerateMatches(in: out.string, range: range) { match, _, _ in
                    if let match, let url = match.url, string.substring(with: match.range).hasPrefix("https://") {
                        out.addAttribute(.link, value: url, range: match.range)
                    }
                }
            }
            for part in s.parts {
                if let heading = part.heading {
                    add(heading + "\n", [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                         .foregroundColor: NSColor.labelColor,
                                         .paragraphStyle: paragraph(spacingBefore: 16, after: 4)])
                }
                // Each line of a text is a paragraph of its own: the room
                // above the text is a short empty line, not paragraph spacing
                add("\n", [.font: NSFont.systemFont(ofSize: 6)])
                add(part.body.trimmingCharacters(in: .newlines) + "\n",
                    [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                     .foregroundColor: NSColor.textColor,
                     .paragraphStyle: paragraph()])
            }
            for child in s.children ?? [] { section(child, depth: min(depth + 1, 2)) }
        }
        for s in sections { section(s, depth: 0) }
        return (out, starts)
    }
}

/// What the About window shows: the app, its version and copyright and the
/// links on top; below, the list of license sections beside the license text.
private struct AboutView: View {
    let document: LicenseDocument
    @State private var selection: String? = "schnellbild"
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(document.sections, children: \.children, selection: $selection) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: section.listName)
                            if let use = section.use {
                                Text(verbatim: use).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("aboutSection.\(section.id)")
                    }
                    .listStyle(.sidebar)
                    .accessibilityIdentifier("aboutLicenseList")
                    Text("⌘F searches the license texts.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .frame(width: 270)
                Divider()
                LicenseTextView(document: document, selection: $selection)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Schnellbild").font(.title.weight(.semibold))
                Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                Text(verbatim: info["NSHumanReadableCopyright"] as? String ?? "").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Link(destination: URL(string: AboutPanel.website)!) { Text(verbatim: "schnellbild.haushoppe-its.de") }
                    Link(destination: URL(string: AboutPanel.repository)!) { Text(verbatim: "GitHub") }
                    Link("Privacy Policy", destination: URL(string: AboutPanel.privacyPolicy)!)
                }
                .font(.callout)
                .padding(.top, 2)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }
}

/// The license text: an `NSTextView` (TextKit 1, laid out only where it is
/// looked at), selectable, with the find bar (⌘F). Choosing a section in the
/// list scrolls its heading to the top; scrolling selects the section on top.
private struct LicenseTextView: NSViewRepresentable {
    let document: LicenseDocument
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // The text's top is the view's top: no insets of the window's bars
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.borderType = .noBorder
        scroll.setAccessibilityIdentifier("aboutLicenseScroll")
        let view = LicenseNSTextView(usingTextLayoutManager: false)
        LicenseNSTextView.shown = view
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 22, height: 20)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textStorage?.setAttributedString(document.text)
        view.setAccessibilityIdentifier("aboutLicenseText")
        view.setAccessibilityLabel(String(localized: "License texts"))
        scroll.documentView = view
        context.coordinator.attach(scroll: scroll, text: view)
        // Laid out, the view starts at the top (the text's inset in view)
        let coordinator = context.coordinator
        DispatchQueue.main.async { coordinator.jump(to: "schnellbild") }
        context.coordinator.onTop = { id in
            if selection != id { selection = id }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onTop = { id in
            if selection != id { selection = id }
        }
        if let id = selection, id != context.coordinator.shown {
            context.coordinator.jump(to: id)
        }
    }

    @MainActor final class Coordinator: NSObject {
        let document: LicenseDocument
        private weak var scroll: NSScrollView?
        private weak var text: NSTextView?
        /// The section whose heading is on top (chosen or scrolled to)
        var shown: String? = "schnellbild"
        var onTop: ((String) -> Void)?
        /// Where the last jump left the view, so its own scrolling doesn't
        /// choose another section
        private var jumpedTo: CGFloat?

        init(document: LicenseDocument) { self.document = document }

        func attach(scroll: NSScrollView, text: NSTextView) {
            self.scroll = scroll
            self.text = text
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        func jump(to id: String) {
            shown = id
            guard let offset = document.starts.first(where: { $0.id == id })?.offset,
                  let text, let scroll, let layout = text.layoutManager else { return }
            if offset == 0 {
                scroll.contentView.scroll(to: .zero)
            } else {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: offset + 1))
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                // A little room above, with the rule over a project's heading
                let top = line.minY + text.textContainerOrigin.y - 24
                let limit = max(0, text.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, top), limit)))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
            jumpedTo = scroll.contentView.bounds.origin.y
        }

        @objc private func scrolled() {
            guard let scroll, let text, let layout = text.layoutManager, let container = text.textContainer else { return }
            let y = scroll.contentView.bounds.origin.y
            if let jumpedTo, abs(jumpedTo - y) < 1 { return }
            jumpedTo = nil
            let probe = NSPoint(x: 30, y: y + 40 - text.textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: probe, in: container)
            let index = layout.characterIndexForGlyph(at: glyph)
            guard let top = document.starts.last(where: { $0.offset <= index })?.id, top != shown else { return }
            shown = top
            onTop?(top)
        }
    }
}

/// The license text view keeps the keys of the find bar and of moving
/// through the text: the app's menus give ⌘F to the browser's search and ⌘↑
/// to the enclosing folder. `AboutPanel`'s key monitor hands it the About
/// window's keys before the menus see them.
final class LicenseNSTextView: NSTextView {
    /// The text view of the About window, once it has been opened.
    @MainActor static weak var shown: LicenseNSTextView?

    /// Carries out a key of the find bar or of moving to the start or end;
    /// false for every other key.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        func find(_ action: NSTextFinder.Action) -> Bool {
            let item = NSMenuItem()
            item.tag = action.rawValue
            performFindPanelAction(item)
            return true
        }
        func scroll(toEnd: Bool) -> Bool {
            // Also from the find bar's field (one line: ⌘↑ ⌘↓ would only move
            // its cursor to the start or end)
            guard let clip = enclosingScrollView?.contentView else { return false }
            clip.scroll(to: NSPoint(x: 0, y: toEnd ? max(0, frame.height - clip.bounds.height) : 0))
            enclosingScrollView?.reflectScrolledClipView(clip)
            return true
        }
        switch (flags, key, event.keyCode) {
        case (.command, "f", _): return find(.showFindInterface)
        case (.command, "g", _): return find(.nextMatch)
        case ([.command, .shift], "g", _): return find(.previousMatch)
        case (.command, "e", _): return find(.setSearchString)
        case (.command, _, 126): return scroll(toEnd: false)
        case (.command, _, 125): return scroll(toEnd: true)
        default: return false
        }
    }
}
