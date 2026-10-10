import Dispatch
import Foundation

/// The dedicated thread that owns virglrenderer and EGL (graphics.md §4.7).
///
/// Work runs in submission order. While polling is requested, the thread calls the
/// poll handler about every millisecond, and the handler reports whether it is still
/// needed. The thread never waits on the device queue, so a device queue that waits in
/// `sync` cannot deadlock with it.
final class RenderThread: @unchecked Sendable {
    /// The fence poll interval (graphics.md §4.5).
    static let pollInterval: TimeInterval = 0.001

    private let name: String
    private let condition = NSCondition()
    private var pending: [@Sendable () -> Void] = []
    private var isStopRequested = false
    private var hasStopped = false
    private var isPollingRequested = false
    private var nextPollDate = Date.distantPast
    private var pollHandler: (@Sendable () -> Bool)?
    private var thread: Thread?

    /// Creates a stopped render thread. Call `start()` before submitting work.
    init(name: String) {
        self.name = name
    }

    /// Sets the handler that polls fences. It returns `true` while polling is still needed.
    func setPollHandler(_ handler: @escaping @Sendable () -> Bool) {
        condition.lock()
        pollHandler = handler
        condition.unlock()
    }

    /// Starts the thread. Calling it again has no effect.
    func start() {
        condition.lock()
        defer { condition.unlock() }
        guard thread == nil else { return }
        let thread = Thread { [self] in
            run()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// True when the caller runs on this render thread.
    var isCurrentThread: Bool {
        condition.lock()
        let thread = self.thread
        condition.unlock()
        return thread != nil && Thread.current === thread
    }

    /// Queues `work` and returns at once. Work submitted after `stop()` is dropped.
    func submit(_ work: @escaping @Sendable () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        guard !isStopRequested else { return }
        pending.append(work)
        condition.signal()
    }

    /// Runs `work` on the render thread and waits for its result. It runs inline when the caller
    /// is already the render thread. It returns `nil` when the thread has stopped or never started.
    func sync<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        if isCurrentThread {
            return work()
        }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        condition.lock()
        let accepting = !isStopRequested && thread != nil
        if accepting {
            pending.append {
                box.value = work()
                done.signal()
            }
            condition.signal()
        }
        condition.unlock()
        guard accepting else { return nil }
        done.wait()
        return box.value
    }

    /// Requests polling. Called on the render thread after work that created a fence.
    func requestPolling() {
        condition.lock()
        isPollingRequested = true
        condition.unlock()
    }

    /// Stops the thread after the work already queued. Work queued after this call is dropped.
    func stop() {
        condition.lock()
        isStopRequested = true
        condition.signal()
        condition.unlock()
    }

    /// True once the thread has run its last work item and returned.
    var hasExited: Bool {
        condition.lock()
        defer { condition.unlock() }
        return hasStopped
    }

    private func run() {
        while true {
            condition.lock()
            if pending.isEmpty, !isStopRequested {
                if isPollingRequested {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: Self.pollInterval))
                } else {
                    condition.wait()
                }
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            let stopping = isStopRequested
            let handler = pollHandler
            let shouldPoll = isPollingRequested && Date() >= nextPollDate
            condition.unlock()

            for work in batch {
                work()
            }
            if shouldPoll, let handler {
                let needed = handler()
                condition.lock()
                isPollingRequested = needed
                nextPollDate = Date(timeIntervalSinceNow: Self.pollInterval)
                condition.unlock()
            }

            if stopping {
                condition.lock()
                let drained = pending.isEmpty
                if drained {
                    hasStopped = true
                    thread = nil
                }
                condition.unlock()
                if drained {
                    return
                }
            }
        }
    }
}

/// Carries one synchronous result from the render thread to the waiting caller.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    // UNCHECKED-SENDABLE: written on the render thread before the semaphore is signalled, and read after the wait.
    var value: T?
}
