import SwiftUI
import OfflineMap

/// The switches UI tests launch the app with (`--ui-testing`, then
/// `--name` or `--name=value`). Every switch counts only together with
/// `--ui-testing`, so a user's command line never turns one on. Read once.
/// (`--open=<path>` is no test switch: `BrowserModel.openFromLaunchArguments`.)
enum TestSwitches {
    private static let arguments = ProcessInfo.processInfo.arguments
    /// The app runs under a UI test.
    static let on = arguments.contains("--ui-testing")

    /// Whether the test turned `flag` on (`"--force-vlc"`).
    static func has(_ flag: String) -> Bool { on && arguments.contains(flag) }

    /// What the test gave `name` (`"--test-log="`: what follows the `=`).
    static func value(_ name: String) -> String? {
        guard on, let argument = arguments.first(where: { $0.hasPrefix(name) }) else { return nil }
        return String(argument.dropFirst(name.count))
    }

    /// A time the test gave `name` in milliseconds (`"--search-delay="`).
    static func milliseconds(_ name: String) -> Duration? { value(name).flatMap(Int.init).map { .milliseconds($0) } }

    /// The test log's file (`--test-log=<name>`, `BrowserModel.testLog`).
    static let testLog: String? = value("--test-log=").map { BrowserModel.testLogFile($0).path }
}

extension View {
    /// The state the UI tests read, in English in every language, under
    /// `--ui-testing`; else what VoiceOver reads.
    func accessibilityValue(test: @autoclosure () -> String, spoken: @autoclosure () -> String = "") -> some View {
        accessibilityValue(TestSwitches.on ? test() : spoken())
    }

    /// As `accessibilityValue(test:spoken:)`, as the label: XCUITest gets no
    /// value from a group of elements.
    func accessibilityLabel(test: @autoclosure () -> String, spoken: @autoclosure () -> String) -> some View {
        accessibilityLabel(TestSwitches.on ? test() : spoken())
    }
}

/// Under `--watch-main-thread` with a test log: a line for every time the
/// main thread answered late (more than `limit`), with when it was asked,
/// and the map's and the globe's own lines (`MapMotion.trace`), each with
/// the time since 1970, so a test's recording can be read against the log.
enum MainThreadWatch {
    static let limit: TimeInterval = 0.15
    static let on = TestSwitches.has("--watch-main-thread") && TestSwitches.testLog != nil

    /// A line of the test log with the time since 1970 in front (only while watching).
    nonisolated static func log(_ line: @autoclosure () -> String) {
        guard on else { return }
        BrowserModel.testLog(String(format: "%.3f ", Date().timeIntervalSince1970) + line())
    }

    static func start() {
        guard on else { return }
        MapMotion.trace = { log($0) }
        let thread = Thread {
            while true {
                let asked = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let waited = Date().timeIntervalSince(asked)
                if waited > limit {
                    BrowserModel.testLog(String(format: "%.3f main thread busy for %.0f ms", asked.timeIntervalSince1970, waited * 1000))
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        thread.name = "Main thread watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
