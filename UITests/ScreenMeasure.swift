import XCTest
import AppKit

/// What the screen shows, measured by the CI workflow's shell
/// (`.github/workflows/ci.yml`): the test puts "measure:<id>:<x>,<y>,<w>,<h>"
/// (screen points) on the pasteboard, the shell captures that region with
/// `screencapture` and answers with its mean luminance, spread and colour.
/// The test runner itself may not record the screen. Without the shell
/// (SCREEN_MEASURE unset) a test that measures is skipped.
extension SchnellbildUITestCase {
    /// What a screen region shows: mean luminance, its standard deviation
    /// (how even it is) and the mean of each colour channel, all 0 … 1.
    struct ScreenStats {
        let mean: Double
        let spread: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Measures a screen region, in screen points.
    func screenStats(of region: CGRect, file: StaticString = #filePath, line: UInt = #line) throws -> ScreenStats {
        guard ProcessInfo.processInfo.environment["SCREEN_MEASURE"] == "1" else {
            throw XCTSkip("needs the screen-measuring shell of the CI workflow")
        }
        let id = UUID().uuidString.prefix(8)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("measure:\(id):\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
                             forType: .string)
        var answer: ScreenStats?
        eventually("the screen was measured", timeout: 30, file: file, line: line) {
            guard let text = pasteboard.string(forType: .string), text.hasPrefix("measured:\(id):") else { return false }
            let n = text.dropFirst("measured:\(id):".count).split(separator: ":").compactMap { Double($0) }
            if n.count == 5, n[0] >= 0 { answer = ScreenStats(mean: n[0], spread: n[1], red: n[2], green: n[3], blue: n[4]) }
            return true
        }
        return try XCTUnwrap(answer, "the region couldn't be measured", file: file, line: line)
    }
}
