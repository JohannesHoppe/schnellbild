import SwiftUI
import AppKit

/// Settings → Keyboard: every action with its keys, grouped as F1 shows
/// them. A click on a key records a new one in its place, + one more; a key
/// another action holds asks before it moves over. A preset gives every
/// action its keys (Schnellbild's, or as in Phiewer); the actions whose keys
/// differ from Schnellbild's are marked and can be listed alone.
struct ShortcutsSettingsView: View {
    @ObservedObject private var shortcuts = Shortcuts.shared

    /// The key being recorded: for an action, in place of one of its keys
    /// (`replacing`) or as one more.
    struct Recording: Equatable {
        let action: ShortcutAction
        let replacing: KeyChord?
    }

    /// A key typed that other actions hold where this one works too.
    struct Conflict {
        let chord: KeyChord
        let action: ShortcutAction
        let replacing: KeyChord?
        let others: [ShortcutAction]

        var othersText: String { others.map(\.name).joined(separator: ", ") }
    }

    @State private var recording: Recording?
    @State private var monitor: Any?
    @State private var conflict: Conflict?
    /// Why a key typed wasn't taken, shown under its action.
    @State private var refusal: (action: ShortcutAction, text: String)?
    @State private var onlyDiffering = false
    /// Filters the list by an action's name or one of its keys.
    @State private var search = ""
    @State private var pendingPreset: ShortcutPreset?

    private var differing: Int { ShortcutAction.allCases.filter(shortcuts.differsFromStandard).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Keys", selection: Binding(get: { shortcuts.preset }, set: choosePreset)) {
                    Text(verbatim: "Schnellbild").tag(ShortcutPreset.schnellbild)
                    Text("As in Phiewer").tag(ShortcutPreset.phiewer)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("shortcuts.preset")
                Spacer()
                Button("Reset All") { stopRecording(); shortcuts.resetAll() }
                    .disabled(!shortcuts.hasChanges)
                    .accessibilityIdentifier("shortcuts.resetAll")
            }
            Text("Click a key to type a new one, + adds one more. Keys with ⌘ or ⌃ also show in the menus.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search actions or keys, such as “rename” or “⌘R”", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("shortcuts.search")
            HStack {
                Toggle("Only actions whose keys differ from Schnellbild's", isOn: $onlyDiffering)
                    .disabled(differing == 0)
                    .accessibilityIdentifier("shortcuts.onlyDiffering")
                Spacer()
                Text(String(localized: "Keys other than Schnellbild's: \(differing)"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("shortcuts.differing")
            }
            List {
                ForEach(ShortcutGroup.allCases, id: \.self) { group in
                    let actions = ShortcutAction.allCases.filter {
                        $0.group == group && (!onlyDiffering || shortcuts.differsFromStandard($0))
                            && shortcuts.matches($0, search: search)
                    }
                    if !actions.isEmpty {
                        Section(group.name) {
                            ForEach(actions, id: \.self) { action in
                                row(action)
                                if action == .bossKey { bossKeyOffRow }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("shortcuts.list")
            .overlay {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty,
                   !ShortcutAction.allCases.contains(where: { shortcuts.matches($0, search: search) }) {
                    Text("No action has this name or key")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 660, height: 580)
        .onDisappear { stopRecording() }
        .alert(conflict.map { Text(String(localized: "“\($0.chord.text)” is already the key for “\($0.othersText)”.")) } ?? Text(verbatim: ""),
               isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
               presenting: conflict) { conflict in
            Button("Reassign") {
                shortcuts.assign(conflict.chord, to: conflict.action, replacing: conflict.replacing)
                self.conflict = nil
            }
            .accessibilityIdentifier("shortcuts.reassign")
            Button("Cancel", role: .cancel) { self.conflict = nil }
        } message: { conflict in
            Text(String(localized: "Give it to “\(conflict.action.name)”? “\(conflict.othersText)” then loses it."))
        }
        .confirmationDialog("Replace the keys you set yourself?",
                            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
                            presenting: pendingPreset) { preset in
            Button("Replace") { shortcuts.choose(preset); pendingPreset = nil }
            Button("Cancel", role: .cancel) { pendingPreset = nil }
        } message: { _ in
            Text("Every action gets the preset's keys; the keys you changed go.")
        }
    }

    // MARK: A row

    private func row(_ action: ShortcutAction) -> some View {
        let keys = shortcuts.keys(action)
        let changed = shortcuts.isChanged(action)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: action.name)
                    .lineLimit(2)
                    .accessibilityIdentifier("shortcut.\(action.rawValue).title")
                if changed {
                    badge(Text("Changed"), color: .accentColor)
                } else if shortcuts.differsFromStandard(action) {
                    badge(Text(verbatim: "Phiewer"), color: .secondary)
                }
                Spacer(minLength: 8)
                if keys.isEmpty, recording?.action != action {
                    Text("no key").foregroundStyle(.tertiary)
                }
                ForEach(Array(keys.enumerated()), id: \.element) { index, chord in
                    keyButton(action, chord, index: index)
                }
                if recording == Recording(action: action, replacing: nil) {
                    recordingCap
                }
                if recording?.action == action {
                    if let old = recording?.replacing {
                        Button { stopRecording(); shortcuts.remove(old, from: action) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove Key")
                            .accessibilityLabel("Remove Key")
                            .accessibilityIdentifier("shortcut.\(action.rawValue).remove")
                    }
                    Button { stopRecording() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Cancel")
                        .accessibilityLabel("Cancel")
                        .accessibilityIdentifier("shortcut.\(action.rawValue).cancel")
                } else {
                    Button { startRecording(Recording(action: action, replacing: nil)) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a key")
                        .accessibilityLabel("Add a key")
                        .accessibilityIdentifier("shortcut.\(action.rawValue).add")
                }
                Button { stopRecording(); shortcuts.reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset to the preset's keys")
                    .accessibilityLabel("Reset to the preset's keys")
                    .accessibilityIdentifier("shortcut.\(action.rawValue).reset")
                    .opacity(changed ? 1 : 0)
                    .disabled(!changed)
            }
            if action == .bossKey {
                explanation(Text("Every window turns invisible and every video silent at once."))
            }
            if let refusal, refusal.action == action {
                Text(verbatim: refusal.text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("shortcut.\(action.rawValue).refusal")
            }
        }
        .padding(.vertical, 1)
    }

    /// The boss key's release: the boss key as set above, three times (no
    /// key of its own).
    private var bossKeyOffRow: some View {
        let key = shortcuts.keys(.bossKey).first
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Boss key off")
                    .lineLimit(2)
                    .accessibilityIdentifier("shortcut.bossKeyOff.title")
                Spacer(minLength: 8)
                if let key {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in cap(Text(verbatim: key.text), highlighted: false) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: Array(repeating: key.text, count: 3).joined(separator: " ")))
                    .accessibilityIdentifier("shortcut.bossKeyOff.keys")
                } else {
                    Text("no key").foregroundStyle(.tertiary)
                }
            }
            explanation(Text("Press the boss key three times within a second with Schnellbild in front (⌘-Tab)."))
        }
        .padding(.vertical, 1)
    }

    private func explanation(_ text: Text) -> some View {
        text
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func badge(_ text: Text, color: Color) -> some View {
        text.font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }

    private func keyButton(_ action: ShortcutAction, _ chord: KeyChord, index: Int) -> some View {
        Group {
            if recording == Recording(action: action, replacing: chord) {
                recordingCap
            } else {
                Button { startRecording(Recording(action: action, replacing: chord)) } label: {
                    cap(Text(verbatim: chord.text), highlighted: false)
                }
                .buttonStyle(.plain)
                .help("Click to type another key")
                .accessibilityLabel(Text(verbatim: chord.text))
                .accessibilityIdentifier("shortcut.\(action.rawValue).\(index)")
                .contextMenu {
                    Button("Remove Key") { stopRecording(); shortcuts.remove(chord, from: action) }
                }
            }
        }
    }

    private var recordingCap: some View {
        cap(Text("Type a key…"), highlighted: true)
            .accessibilityIdentifier("shortcuts.recording")
    }

    private func cap(_ text: Text, highlighted: Bool) -> some View {
        text.font(.system(size: 12, weight: .semibold))
            .frame(minWidth: 26, minHeight: 20)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(highlighted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(highlighted ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1))
    }

    // MARK: Recording

    private func choosePreset(_ preset: ShortcutPreset) {
        guard preset != shortcuts.preset || shortcuts.hasChanges else { return }
        stopRecording()
        if shortcuts.hasChanges { pendingPreset = preset } else { shortcuts.choose(preset) }
    }

    /// The next key typed (in the Settings window, ahead of everything
    /// else, Esc and ⌫ included) is the new key.
    private func startRecording(_ new: Recording) {
        stopRecording()
        refusal = nil
        recording = new
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func record(_ event: NSEvent) {
        guard let recording else { return }
        stopRecording()
        guard let chord = KeyChord.from(event) else {
            refusal = (recording.action, String(localized: "This key can't be used."))
            return
        }
        guard !Shortcuts.isReserved(chord) else {
            refusal = (recording.action, String(localized: "\(chord.text) belongs to macOS or to text fields and can't be used."))
            return
        }
        let others = shortcuts.conflicts(chord, for: recording.action)
        if others.isEmpty {
            shortcuts.assign(chord, to: recording.action, replacing: recording.replacing)
        } else {
            conflict = Conflict(chord: chord, action: recording.action, replacing: recording.replacing, others: others)
        }
    }
}
