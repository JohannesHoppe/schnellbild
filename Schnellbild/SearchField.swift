import SwiftUI
import AppKit

/// The always-visible search field (an `NSSearchField`).
///
/// It only takes keyboard focus when clicked or on ⌘F — never on its own when
/// the window appears — so the grid's keyboard shortcuts work right away.
/// Escape, Return and ↓ are routed to `onKey` instead of the field editor.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var isEnabled: Bool
    var onKey: (BrowserModel.KeyInput) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusGatedSearchField {
        let field = FocusGatedSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setAccessibilityIdentifier("searchField")
        field.onFocusGained = { [weak coordinator = context.coordinator] in
            coordinator?.setFocused(true)
        }
        return field
    }

    func updateNSView(_ field: FocusGatedSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.isEnabled = isEnabled
        let editing = field.currentEditor() != nil
        if isFocused, !editing {
            DispatchQueue.main.async { field.focus() }
        } else if !isFocused, editing {
            DispatchQueue.main.async { field.blur() }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) { self.parent = parent }

        func setFocused(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField { searchChanged(field) }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            (obj.object as? FocusGatedSearchField)?.closeFocusGate()
            setFocused(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            case #selector(NSResponder.insertNewline(_:)):   return parent.onKey(.enter)
            case #selector(NSResponder.moveDown(_:)):        return parent.onKey(.down)
            default:                                         return false
            }
        }
    }
}

/// An `NSSearchField` that refuses first responder until the user clicks it
/// or focus is requested explicitly — AppKit would otherwise make it the
/// window's initial first responder and swallow the grid's keys.
final class FocusGatedSearchField: NSSearchField {
    private var focusAllowed = false
    var onFocusGained: (() -> Void)?

    override var acceptsFirstResponder: Bool { focusAllowed && isEnabled }

    override func mouseDown(with event: NSEvent) {
        focusAllowed = true
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusGained?() }
        return became
    }

    func focus() {
        focusAllowed = true
        window?.makeFirstResponder(self)
    }

    func blur() {
        if currentEditor() != nil { window?.makeFirstResponder(nil) }
        focusAllowed = false
    }

    func closeFocusGate() { focusAllowed = false }
}
