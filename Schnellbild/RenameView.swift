import SwiftUI

/// Sheet for renaming a folder or file (F2, the Actions menu, or the context
/// menu), also one of the other files listed under the grid. For a file the
/// name without its extension is selected, like Finder.
struct RenameView: View {
    enum Subject {
        case entry(GridEntry)
        case file(OtherFile)
    }
    let subject: Subject

    @EnvironmentObject var model: BrowserModel
    @State private var name: String
    @State private var error: String?
    @FocusState private var fieldFocused: Bool
    /// Renamed already: Return can reach both the field and the default
    /// button, and a second rename would work on the old name.
    @State private var done = false

    init(entry: GridEntry) {
        subject = .entry(entry)
        _name = State(initialValue: entry.url.lastPathComponent)
    }

    init(file: OtherFile) {
        subject = .file(file)
        _name = State(initialValue: file.url.lastPathComponent)
    }

    private var title: Text {
        switch subject {
        case .entry(let entry):
            return entry.kind != .folder ? Text("Rename File")
                : entry.isArchive ? Text("Rename Archive") : Text("Rename Folder")
        case .file:
            return Text("Rename File")
        }
    }

    private var url: URL {
        switch subject {
        case .entry(let entry): return entry.url
        case .file(let file): return file.url
        }
    }

    private func close() {
        switch subject {
        case .entry: model.renameTarget = nil
        case .file: model.renameFileTarget = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title.font(.headline)
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
                Button(action: close) { HStack(spacing: 6) { Text("Cancel"); KeyCap("esc") } }
                    .keyboardShortcut(.cancelAction)
                Button(action: commit) { HStack(spacing: 6) { Text("Rename"); KeyCap("↩") } }
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
        done = true
        Task {
            do {
                switch subject {
                case .entry(let entry): try await model.rename(entry, to: name)
                case .file(let file): try await model.rename(file, to: name)
                }
            } catch {
                self.error = error.localizedDescription
                done = false
            }
        }
    }

    /// Files and archives: select the name without the extension, once the
    /// field is being edited (AppKit selects everything when it gains focus;
    /// that has happened once the field editor is first responder).
    private func selectBaseName() {
        if case .entry(let entry) = subject, entry.kind == .folder, !entry.isArchive { return }
        let length = ((url.lastPathComponent as NSString).deletingPathExtension as NSString).length
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
