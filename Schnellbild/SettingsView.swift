import SwiftUI
import AVFoundation

/// Settings (⌘,): how long a picture stays in the slideshow, the archive
/// passwords Schnellbild has saved, and whether macOS reads MKV and AVCHD itself
/// (Schnellbild's media extension, turned on in System Settings).
struct SettingsView: View {
    @EnvironmentObject var window: WindowModel
    @State private var savedPasswords = ArchiveStore.shared.passwords.count
    @State private var confirming = false
    @State private var formatsOn: Bool?

    var body: some View {
        Form {
            Section("Slideshow") {
                Stepper(value: Binding(get: { window.slideshowSeconds }, set: { window.slideshowSeconds = $0 }),
                        in: BrowserModel.slideshowSecondsRange) {
                    LabeledContent("Each picture stays", value: String(localized: "\(window.slideshowSeconds) s"))
                }
                .accessibilityIdentifier("settings.slideshowSeconds")
                Text("Videos play to their end.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Video formats for macOS") {
                LabeledContent("MKV and AVCHD through macOS",
                               value: formatsOn.map { $0 ? String(localized: "On") : String(localized: "Off") } ?? String(localized: "Checking…"))
                    .accessibilityIdentifier("settings.formatsStatus")
                Button("Open System Settings…") { MediaFormats.openSystemSettings() }
                Text("Turned on (“Schnellbild Video Formats” under Media Extensions), macOS makes the thumbnails of MKV videos and AVCHD camcorder clips itself: Finder and Schnellbild show them at once and macOS keeps them (macOS 26). Off, Schnellbild makes them itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Archive passwords") {
                LabeledContent("Saved passwords", value: "\(savedPasswords)")
                Button("Forget Saved Passwords…") { confirming = true }
                    .disabled(savedPasswords == 0)
                    .accessibilityIdentifier("settings.forgetPasswords")
                Text("Passwords that opened an archive are kept in your keychain, so the archive opens without asking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { savedPasswords = ArchiveStore.shared.passwords.count }
        // Again whenever the window comes back (the user may have turned it on meanwhile)
        .task { formatsOn = await MediaFormats.isOn() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { formatsOn = await MediaFormats.isOn() }
        }
        .confirmationDialog("Forget all saved archive passwords?", isPresented: $confirming) {
            Button("Forget Passwords", role: .destructive) {
                ArchiveStore.shared.forgetPasswords()
                savedPasswords = ArchiveStore.shared.passwords.count
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archives that need a password ask for it again.")
        }
    }
}

/// Schnellbild's media extension (the Matroska format reader). There is no
/// call that tells whether it is turned on; a short MKV in the app that
/// AVFoundation can play says so (an app opted in, as Schnellbild is at
/// launch), as QuickLook Video's app checks its own.
enum MediaFormats {
    static func isOn() async -> Bool {
        guard let url = Bundle.main.url(forResource: "FormatsCheck", withExtension: "mkv") else { return false }
        return (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }

    /// System Settings at its Media Extensions page.
    static func openSystemSettings() {
        let page = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.mediaextension.formatreader"
        if let url = URL(string: page) { NSWorkspace.shared.open(url) }
    }
}

