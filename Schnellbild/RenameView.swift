import SwiftUI

/// Sheet for renaming a folder or file (F2, the Actions menu, or the context
/// menu). For a file the name without its extension is selected, like Finder.
struct RenameView: View {
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
            Text(entry.kind == .folder ? "Rename Folder" : "Rename File").font(.headline)
            TextField("Name", text: $name)
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
        .onAppear {
            fieldFocused = true
            selectBaseName()
        }
    }

    private func commit() {
        do {
            try model.rename(entry, to: name)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Files: select the name without the extension once the field is
    /// editing (AppKit selects all when it gains focus).
    private func selectBaseName() {
        guard entry.kind != .folder else { return }
        let base = (entry.url.lastPathComponent as NSString).deletingPathExtension
        // After the field has become first responder and selected everything
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: 0, length: (base as NSString).length))
        }
    }
}
