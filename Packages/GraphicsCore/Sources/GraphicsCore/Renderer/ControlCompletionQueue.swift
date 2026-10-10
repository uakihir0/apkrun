import Foundation

/// The controlq elements whose responses wait for the renderer or for a fence (graphics.md §4.5, §4.7).
///
/// The device queue appends an element in the order it received it. The element
/// completes once it has executed and, if it carries a fence, once that fence has
/// completed. Only the head completes, so a response never overtakes an earlier
/// element. The queue is thread-safe. Completions are returned to the caller, which
/// finishes them outside the lock.
final class ControlCompletionQueue<Completion>: @unchecked Sendable {
    /// Identifies one appended element.
    struct Ticket: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    private struct Entry {
        let ticket: Ticket
        let completion: Completion
        var isExecuted: Bool
        var fence: UInt32?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextValue: UInt64 = 1
    /// The highest fence that virglrenderer has reported completed, if any.
    private var completedFence: UInt32?

    /// The number of elements that have not completed.
    var count: Int {
        lock.withLock { entries.count }
    }

    /// True when no element waits.
    var isEmpty: Bool {
        count == 0
    }

    /// True when an executed element waits for a fence, so the render thread must keep polling.
    var isWaitingForFence: Bool {
        lock.withLock {
            entries.contains { $0.isExecuted && $0.fence != nil }
        }
    }

    /// Appends an element at the tail. `executed` is true for an element that needs no renderer work.
    func append(_ completion: Completion, executed: Bool) -> Ticket {
        lock.withLock {
            let ticket = Ticket(value: nextValue)
            nextValue += 1
            entries.append(Entry(ticket: ticket, completion: completion, isExecuted: executed, fence: nil))
            return ticket
        }
    }

    /// Records that the element has executed and carries `fence`, if any. Returns the completions that are now ready, in order.
    func markExecuted(_ ticket: Ticket, fence: UInt32?) -> [Completion] {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.ticket == ticket }) else {
                return []
            }
            entries[index].isExecuted = true
            entries[index].fence = fence
            return drainReadyLocked()
        }
    }

    /// Records a completed fence. It is monotonic: an older report never lowers the value.
    func recordCompletedFence(_ fence: UInt32) {
        lock.withLock {
            completedFence = max(completedFence ?? fence, fence)
        }
    }

    /// Returns the head elements that are ready, in order.
    func drainReady() -> [Completion] {
        lock.withLock { drainReadyLocked() }
    }

    /// Removes every element, ready or not. A reset or stop uses it, because the guest no longer waits for them.
    func removeAll() -> [Completion] {
        lock.withLock {
            let removed = entries.map(\.completion)
            entries.removeAll(keepingCapacity: false)
            return removed
        }
    }

    private func drainReadyLocked() -> [Completion] {
        var ready: [Completion] = []
        while let head = entries.first, isReady(head) {
            ready.append(head.completion)
            entries.removeFirst()
        }
        return ready
    }

    private func isReady(_ entry: Entry) -> Bool {
        guard entry.isExecuted else { return false }
        guard let fence = entry.fence else { return true }
        guard let completedFence else { return false }
        return fence <= completedFence
    }
}
