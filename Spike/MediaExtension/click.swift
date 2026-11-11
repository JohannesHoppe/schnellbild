// Clicks at a screen point (top-left origin), as the mouse would; prints
// whether this process may send such events (Accessibility).
import AppKit
import ApplicationServices

let args = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard args.count == 2 else { print("usage: click.swift x y"); exit(2) }
print("accessibility trusted: \(AXIsProcessTrusted())")
let point = CGPoint(x: args[0], y: args[1])
let source = CGEventSource(stateID: .hidSystemState)
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(150_000)
}
print("clicked \(point)")
