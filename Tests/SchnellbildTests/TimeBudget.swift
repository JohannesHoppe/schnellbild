import XCTest

/// Time budgets that hold on CI's virtual Macs and still catch work that got
/// slower.
///
/// - The work is timed by the CPU time of the thread that does it
///   (`.thread`): time the thread waits while other threads or processes
///   have the runner's cores doesn't count. Work spread over several threads
///   is timed on the wall clock (`.wall`).
/// - The time is the best of `runs`: a slow moment of the runner lengthens
///   one run, slower code every run.
/// - Before each run a fixed reference work (30 000 numbers sorted and
///   counted into cells) is timed on the same clock. When even its best is
///   slower than on an ordinary CI runner (`ordinaryReference`), the runner
///   itself is slow just then (a slower Mac, a virtual Mac whose cores its
///   host gives to others), and the budget grows by that factor. A faster
///   Mac keeps the budget as it is. The work's time against its budget, the
///   factor and the reference's time are printed with every check.
enum TimeBudget {
    enum Clock { case thread, wall }

    /// The reference work's best time on an ordinary CI runner, in seconds
    /// (a debug build; macos-15 about 58 ms, macos-26 about 68 ms, seen
    /// over ten runs each; the work timed alongside goes up and down with it).
    static let ordinaryReference = 0.060

    static func now(_ clock: Clock) -> Double {
        Double(clock_gettime_nsec_np(clock == .thread ? CLOCK_THREAD_CPUTIME_ID : CLOCK_UPTIME_RAW)) / 1e9
    }

    static func seconds(_ clock: Clock, _ work: () throws -> Void) rethrows -> Double {
        let start = now(clock)
        try work()
        return now(clock) - start
    }

    private static var sink = 0

    /// The reference work timed once.
    static func reference(_ clock: Clock) -> Double {
        seconds(clock) {
            var seed: UInt64 = 1
            var values: [Double] = []
            values.reserveCapacity(30_000)
            for _ in 0..<30_000 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                values.append(Double(seed >> 11) / Double(1 << 53))
            }
            values.sort()
            var cells: [Int: Int] = [:]
            for value in values { cells[Int(value * 4096), default: 0] += 1 }
            sink &+= cells.count
        }
    }

    /// Checks that `work`'s best time of `runs` stays under `budget` seconds
    /// (times the runner's slowdown); returns that best time.
    @discardableResult
    static func check(_ what: @autoclosure () -> String, under budget: Double, runs: Int = 3, clock: Clock = .thread,
                      file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) rethrows -> Double {
        var best = Double.infinity, reference = Double.infinity
        for _ in 0..<max(runs, 1) {
            reference = min(reference, Self.reference(clock))
            best = min(best, try seconds(clock, work))
        }
        for _ in 0..<2 { reference = min(reference, Self.reference(clock)) }
        let slowdown = max(1, reference / ordinaryReference)
        let message = String(format: "%.1f ms, budget %.0f ms × %.2f (reference %.1f ms, %@)",
                             best * 1000, budget * 1000, slowdown, reference * 1000, clock == .thread ? "CPU time" : "wall clock")
        print("time budget: \(what()): \(message)")
        XCTAssertLessThan(best, budget * slowdown, "\(what()): \(message)", file: file, line: line)
        return best
    }
}
