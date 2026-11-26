// Two fingers turning on a trackpad, for the Atlas UI test: the CI shell
// posts the gesture event a trackpad makes (CGEvent type 29, HID type
// rotation 5, the degrees in field 113, counterclockwise positive as AppKit
// reads them) at a screen point, in points from the top left. The test
// runner may not post events, the workflow's shell may (see
// .github/workflows/ci.yml).
//
//   trackpad_turn 540 380 -5   →   turned      (or: refused, when posting isn't allowed)
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap { Double($0) }
guard arguments.count == 3,
      let event = CGEvent(source: nil),
      let type = CGEventType(rawValue: 29),
      let hidType = CGEventField(rawValue: 110),
      let degrees = CGEventField(rawValue: 113) else {
    print("usage: trackpad_turn <x> <y> <degrees>")
    exit(2)
}
guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
    print("refused")
    exit(1)
}
event.type = type
event.setIntegerValueField(hidType, value: 5)
event.setDoubleValueField(degrees, value: arguments[2])
event.location = CGPoint(x: arguments[0], y: arguments[1])
event.post(tap: .cghidEventTap)
print("turned")
