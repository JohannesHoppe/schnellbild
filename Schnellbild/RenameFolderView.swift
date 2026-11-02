import SwiftUI

/// Sheet for renaming a folder (F2, the Actions menu, or a folder's context menu).
struct RenameFolderView: View {
    let entry: GridEntry

    @EnvironmentObject var model: BrowserModel
    @State private var name: String
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    init(entry: GridEntry) {
        self.entry = entry
        _name = State(initialValue: entry.url.lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Folder").font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier("renameField")
                .onSubmit(commit)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("renameError")
            }
            HStack {
                Spacer()
                Button("Cancel") { model.renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }

    private func commit() {
        do {
            try model.renameFolder(entry, to: name)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
