// The main display's modes, for the demo video (.github/workflows/demo-video.yml):
//   display_mode list        prints every mode the display offers, the current one marked
//   display_mode set <w> <h> switches to the mode of <w> × <h> points (the one with
//                            the most pixels of that size), for this login session
//   display_mode set largest the same with the largest mode usable for the desktop
// Prints the mode in use at the end ("<w>x<h> points, <pw>x<ph> pixels").
import CoreGraphics
import Foundation

let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []

func describe(_ mode: CGDisplayMode) -> String {
    "\(mode.width)x\(mode.height) points, \(mode.pixelWidth)x\(mode.pixelHeight) pixels, \(mode.refreshRate) Hz"
        + (mode.isUsableForDesktopGUI() ? "" : ", not for the desktop")
}

func current() -> CGDisplayMode? { CGDisplayCopyDisplayMode(display) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "list":
    let now = current()
    print("display \(display): \(CGDisplayPixelsWide(display))x\(CGDisplayPixelsHigh(display)), \(modes.count) modes")
    for mode in modes {
        let isCurrent = now.map { $0.ioDisplayModeID == mode.ioDisplayModeID } ?? false
        print((isCurrent ? "* " : "  ") + describe(mode))
    }

case "set" where args.count > 2:
    let fitting: [CGDisplayMode]
    if args[2] == "largest" {
        let usable = modes.filter { $0.isUsableForDesktopGUI() }
        let most = usable.map { $0.width * $0.height }.max() ?? 0
        fitting = usable.filter { $0.width * $0.height == most }
    } else {
        guard args.count > 3, let w = Int(args[2]), let h = Int(args[3]) else { fail("Usage: display_mode set <w> <h> | largest") }
        fitting = modes.filter { $0.width == w && $0.height == h }
    }
    guard let mode = fitting.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else {
        fail("No such mode")
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { fail("No display configuration") }
    CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
    let result = CGCompleteDisplayConfiguration(config, .forSession)
    guard result == .success else { fail("Switching to \(describe(mode)) failed: \(result.rawValue)") }
    Thread.sleep(forTimeInterval: 2)

default:
    fail("Usage: display_mode list | set <w> <h> | set largest")
}
if let now = current() { print("in use: " + describe(now)) }
