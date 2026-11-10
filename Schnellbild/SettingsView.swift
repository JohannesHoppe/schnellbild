import SwiftUI

/// Settings (⌘,): how long a picture stays in the slideshow, and the
/// archive passwords Schnellbild has saved.
struct SettingsView: View {
    @EnvironmentObject var window: WindowModel
    @State private var savedPasswords = ArchiveStore.shared.passwords.count
    @State private var confirming = false

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
