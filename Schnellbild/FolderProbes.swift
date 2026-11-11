import Foundation

/// Where the folder tiles look into folders (their previews, whether they
/// hold any media): a queue of its own with a few at a time. These walks
/// wait on the disk, on a network share for long; on Swift's own threads
/// (as many as the Mac has cores) a few hundred folder tiles would hold
/// every one of them, and the search, the listings and the thumbnails would
/// wait behind them.
enum FolderProbes {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Schnellbild folder probes"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        return queue
    }()

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    /// The operation, sendable for the cancellation handler (it is only
    /// cancelled from there, which Operation allows from any thread).
    private final class Handle: @unchecked Sendable {
        let operation = BlockOperation()
    }

    /// The operation's own block asks through this (no cycle through itself).
    private final class WeakHandle: @unchecked Sendable {
        weak var handle: Handle?
        init(_ handle: Handle) { self.handle = handle }
    }

    /// Runs `work` on the queue; `cancelled` tells it the caller went away
    /// (the tile scrolled out). nil when cancelled before it ran.
    static func run<T: Sendable>(_ work: @escaping @Sendable (_ cancelled: @escaping @Sendable () -> Bool) -> T?) async -> T? {
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (answer: CheckedContinuation<T?, Never>) in
                let once = Once()
                let weakHandle = WeakHandle(handle)
                handle.operation.addExecutionBlock {
                    let result = work { weakHandle.handle?.operation.isCancelled ?? true }
                    if once.claim() { answer.resume(returning: result) }
                }
                // Also when cancelled before it ran (its block never runs then)
                handle.operation.completionBlock = { if once.claim() { answer.resume(returning: nil) } }
                queue.addOperation(handle.operation)
            }
        } onCancel: {
            handle.operation.cancel()
        }
    }
}
