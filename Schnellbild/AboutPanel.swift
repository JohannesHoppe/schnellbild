import AppKit

/// The About window: version and copyright from the bundle, and the
/// libraries the app is built with, with their licenses. The full license
/// texts ship in the bundle (Contents/Resources/Licenses) and in
/// THIRD-PARTY-NOTICES.md.
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One block per component: name, what it does here, the license.
    struct Component {
        let name: String
        let use: String
        let license: String
        let link: String
    }

    static let components: [Component] = [
        Component(name: "VLCKit 3.6.0 (libVLC)", use: "plays the video formats macOS can't (AVI, MKV, WebM …)",
                  license: "© VideoLAN and the VLC authors. GNU Lesser General Public License 2.1 or later. "
                      + "Used unmodified as its own framework (Contents/Frameworks), which can be replaced.",
                  link: "https://code.videolan.org/videolan/VLCKit"),
        Component(name: "UnRAR 7.3.2", use: "reads RAR archives",
                  license: "© Alexander Roshal. UnRAR license: UnRAR source code may be used in any software to handle "
                      + "RAR archives without limitations free of charge, but cannot be used to develop RAR (WinRAR) "
                      + "compatible archiver and to re-create RAR compression algorithm, which is proprietary.",
                  link: "https://www.rarlab.com"),
        Component(name: "libarchive", use: "reads ZIP and 7z archives (the copy built into macOS)",
                  license: "© Tim Kientzle and the libarchive contributors. BSD 2-clause license.",
                  link: "https://www.libarchive.org"),
    ]

    static func credits() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        func add(_ string: String, font: NSFont, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor,
                                                             .paragraphStyle: paragraph]
            if let link, let url = URL(string: link) { attributes[.link] = url }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        add("Schnellbild is free software under the MIT License.\n", font: body)
        add("https://github.com/JohannesHoppe/schnellbild\n\n", font: body, link: "https://github.com/JohannesHoppe/schnellbild")
        add("Built with\n", font: bold)
        for component in components {
            add("\(component.name)\n", font: bold)
            add("\(component.use)\n\(component.license)\n", font: body)
            add("\(component.link)\n\n", font: body, link: component.link)
        }
        add("The full license texts are in the app (Contents/Resources/Licenses).", font: body)
        return text
    }
}
