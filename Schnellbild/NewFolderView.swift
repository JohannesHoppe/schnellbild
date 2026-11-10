import SwiftUI

/// ⇧⌘N: the name of a new folder in the folder shown. Nothing is made until
/// ↩ confirms the name; Esc leaves no folder behind.
struct NewFolderView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var name = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("newFolderField")
                .onSubmit(create)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("newFolderError")
            }
            HStack {
                Spacer()
                Button { model.newFolderRequested = false } label: { HStack(spacing: 6) { Text("Cancel"); KeyCap("esc") } }
                    .keyboardShortcut(.cancelAction)
                Button(action: create) { HStack(spacing: 6) { Text("Create"); KeyCap("↩") } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }

    /// Return reaches both the field and the default button: one folder.
    @State private var done = false

    private func create() {
        guard !done else { return }
        do {
            try model.createFolder(named: name)
            done = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
