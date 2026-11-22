import SwiftUI

/// Asks for the password of a protected archive that none of the remembered
/// passwords opens. What opens it is remembered for every archive.
struct PasswordView: View {
    let request: BrowserModel.PasswordRequest

    @EnvironmentObject var model: BrowserModel
    @State private var password = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password for “\(request.archive)”").font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("passwordField")
                .onSubmit { model.submitPassword(password) }
            if request.wrong {
                Text(ArchiveError.needsPassword.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("passwordWrong")
            }
            Text("Passwords that open an archive are saved in your login keychain and tried on every protected archive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button { model.cancelPassword() } label: { HStack(spacing: 6) { Text("Cancel"); KeyCap("esc") } }
                    .keyboardShortcut(.cancelAction)
                    .toolTip(String(localized: "Back without opening the archive"))
                Button { model.submitPassword(password) } label: { HStack(spacing: 6) { Text("Open"); KeyCap("↩") } }
                    .keyboardShortcut(.defaultAction)
                    .toolTip(String(localized: "Open the archive with this password"))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
    }
}
