import AppKit
import SwiftUI

/// The About window: version and copyright from the bundle, and the
/// libraries the app is built with, with their licenses. The full license
/// texts ship in the bundle (Contents/Resources/Licenses) and in
/// THIRD-PARTY-NOTICES.md.
@MainActor
enum AboutPanel {
    private static var window: NSWindow?

    /// A window of its own: the system's About panel is narrow and can't be
    /// made wider, so the license lines broke into short scraps.
    static func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = String(localized: "About Schnellbild")
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AboutView())
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
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
        Component(name: "VLCKit 3.7.5 (libVLC 3.0.24)", use: String(localized: "plays the video formats macOS can't (AVI, MKV, WebM …)"),
                  license: String(localized: "© VideoLAN and the VLC authors. GNU Lesser General Public License 2.1 or later. Built from its source without VLC's modules under the GPL; the build script and its changes are in Schnellbild's repository (github.com/JohannesHoppe/schnellbild)."),
                  link: "https://code.videolan.org/videolan/VLCKit"),   // its source; THIRD-PARTY-NOTICES.md has the exact version
        Component(name: "UnRAR 7.2.7", use: String(localized: "reads RAR archives"),
                  // The license's own sentence stays as written (English)
                  license: String(localized: "© Alexander Roshal. The UnRAR license, in its own words:") + " "
                      + "UnRAR source code may be used in any software to handle "
                      + "RAR archives without limitations free of charge, but cannot be used to develop RAR (WinRAR) "
                      + "compatible archiver and to re-create RAR compression algorithm, which is proprietary.",
                  link: "https://www.rarlab.com"),
        Component(name: "libarchive", use: String(localized: "reads ZIP and 7z archives (the copy built into macOS)"),
                  license: String(localized: "© Tim Kientzle and the libarchive contributors. BSD 2-clause license."),
                  link: "https://www.libarchive.org"),
    ]
}

/// What the About window shows: the app, its version and copyright, then
/// every component with what it does here and its license.
private struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text(verbatim: "Schnellbild").font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))").font(.callout).foregroundStyle(.secondary)
            Text(verbatim: info["NSHumanReadableCopyright"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 14) {
                    Text("Schnellbild's own code is free software under the MIT License. The components below keep their own licenses.")
                    link("https://github.com/JohannesHoppe/schnellbild")
                    Text("Built with").font(.headline).padding(.top, 4)
                    ForEach(AboutPanel.components, id: \.name) { component in
                        VStack(spacing: 3) {
                            Text(verbatim: component.name).fontWeight(.semibold)
                            Text(verbatim: component.use)
                            Text(verbatim: component.license).foregroundStyle(.secondary)
                            link(component.link)
                        }
                    }
                    Text("The full license texts are in the app (Contents/Resources/Licenses).").foregroundStyle(.secondary)
                }
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .textSelection(.enabled)
    }

    private func link(_ address: String) -> some View {
        Link(destination: URL(string: address)!) { Text(verbatim: address) }
    }
}

