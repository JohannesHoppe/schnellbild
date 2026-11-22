import SwiftUI
import AppKit

extension View {
    /// The control's tooltip: SwiftUI's help (what VoiceOver reads as the
    /// control's help) and the same text as AppKit's tooltip of a view laid
    /// over it. SwiftUI's own tooltips don't show in a pane: on CI (macOS 15
    /// and 26) the status bar's and the search bar's controls showed none
    /// over the grid, the list and an empty folder, while the toolbar's did;
    /// why is unknown. AppKit's showed on every one of them
    /// (`TooltipUITests`). Empty: none.
    @ViewBuilder func toolTip(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            help(text).overlay(ToolTipArea(text: text).accessibilityHidden(true))
        }
    }
}

/// A view that only carries a tooltip: every click, drag and hover goes
/// through it to the control below (`hitTest` finds nothing), while AppKit
/// shows its `toolTip` when the pointer rests over it.
struct ToolTipArea: NSViewRepresentable {
    let text: String

    final class Area: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    func makeNSView(context: Context) -> Area { Area() }

    func updateNSView(_ view: Area, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
}
