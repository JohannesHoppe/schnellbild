import SwiftUI

/// Sheet for renaming a folder or file (F2, the Actions menu, or the context
/// menu). For a file the name without its extension is selected, like Finder.
struct RenameView: View {
    let entry: GridEntry

    @EnvironmentObject var model: BrowserModel
    @State private var name: String
    @State private var error: String?
    @FocusState private var fieldFocused: Bool
    /// Renamed already: Return can reach both the field and the default
    /// button, and a second rename would work on the old name.
    @State private var done = false

    init(entry: GridEntry) {
        self.entry = entry
        _name = State(initialValue: entry.url.lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (entry.kind == .folder ? Text("Rename Folder") : Text("Rename File")).font(.headline)
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
        BrowserModel.testLog("rename confirmed")
        guard !done else { return }
        do {
            try model.rename(entry, to: name)
            done = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Files: select the name without the extension, once the field is
    /// being edited (AppKit selects everything when it gains focus; that has
    /// happened once the field editor is first responder).
    private func selectBaseName() {
        guard entry.kind != .folder else { return }
        let length = ((entry.url.lastPathComponent as NSString).deletingPathExtension as NSString).length
        Task { @MainActor in
            for _ in 0..<50 {   // up to a second
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.setSelectedRange(NSRange(location: 0, length: length))
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}
