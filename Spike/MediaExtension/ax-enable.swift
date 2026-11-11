// Turns on every switch System Settings shows (its windows and sheets), by
// the accessibility API, as a person would click them; prints what it found.
// Usage: swift ax-enable.swift   (System Settings open on the page)
import AppKit
import ApplicationServices

print("accessibility trusted: \(AXIsProcessTrusted())")
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
    print("System Settings isn't running"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

var turned = 0
func visit(_ element: AXUIElement, depth: Int, context: String) {
    guard depth < 40 else { return }
    let role: String = attribute(element, kAXRoleAttribute) ?? ""
    let subrole: String = attribute(element, kAXSubroleAttribute) ?? ""
    let title: String = attribute(element, kAXTitleAttribute) ?? attribute(element, kAXDescriptionAttribute) ?? ""
    var label = context
    if role == "AXStaticText", let text: String = attribute(element, kAXValueAttribute), !text.isEmpty { label = text }
    if role == "AXCheckBox" || subrole == "AXSwitch" {
        let value: NSNumber? = attribute(element, kAXValueAttribute)
        print("switch '\(title)' near '\(label)': \(value?.intValue ?? -1)")
        if value?.intValue == 0 {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            print("  pressed: \(result == .success)")
            turned += 1
        }
    }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    var near = label
    for child in children {
        visit(child, depth: depth + 1, context: near)
        let childRole: String = attribute(child, kAXRoleAttribute) ?? ""
        if childRole == "AXStaticText", let text: String = attribute(child, kAXValueAttribute), !text.isEmpty { near = text }
    }
}
let windows: [AXUIElement] = attribute(root, kAXWindowsAttribute) ?? []
print("windows: \(windows.count)")
for window in windows { visit(window, depth: 0, context: "") }
print("turned on: \(turned)")
