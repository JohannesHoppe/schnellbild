// Two fingers turning on a trackpad, for the Atlas UI test: the CI shell
// posts the gesture a trackpad makes at a screen point (in points from the
// top left), as a began, some changed and an ended event of type 29 (HID
// type rotation 5, the degrees in fields 113 and 114, counterclockwise
// positive as AppKit reads them, the phase in field 132). Without the
// phases the window server doesn't hand the rotation to the app. The test
// runner may not post events, the workflow's shell may (see
// .github/workflows/ci.yml).
//
//   trackpad_turn 540 380 -20 4   →   turned   (-20° in four steps; refused when posting isn't allowed)
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap { Double($0) }
guard arguments.count == 4, arguments[3] >= 1,
      let type = CGEventType(rawValue: 29),
      let hidType = CGEventField(rawValue: 110),
      let phaseField = CGEventField(rawValue: 132),
      let zoomValue = CGEventField(rawValue: 113),
      let rotationValue = CGEventField(rawValue: 114) else {
    print("usage: trackpad_turn <x> <y> <degrees> <steps>")
    exit(2)
}
guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
    print("refused")
    exit(1)
}

enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

func post(_ phase: Phase, degrees: Double) {
    guard let event = CGEvent(source: nil) else { return }
    event.type = type
    event.setIntegerValueField(hidType, value: 5)
    event.setDoubleValueField(zoomValue, value: degrees)
    event.setDoubleValueField(rotationValue, value: degrees)
    event.setIntegerValueField(phaseField, value: phase.rawValue)
    event.location = CGPoint(x: arguments[0], y: arguments[1])
    event.post(tap: .cghidEventTap)
    usleep(20_000)
}

let steps = Int(arguments[3])
post(.began, degrees: 0)
for _ in 0..<steps { post(.changed, degrees: arguments[2] / Double(steps)) }
post(.ended, degrees: 0)
print("turned")
