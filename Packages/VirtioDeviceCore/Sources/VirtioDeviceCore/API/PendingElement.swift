import Foundation

/// An owned virtqueue element whose completion is delayed until work finishes.
///
/// This handle is `Sendable`; the VZ adapter returns it to the guest on the
/// device queue even when a completion fence fires on another queue.
public struct PendingElement: ~Copyable, Sendable {
    private var storage: (any PendingElementStorage)?

    package init(storage: any PendingElementStorage) {
        self.storage = storage
    }

    package consuming func makeCompletionToken() -> PendingElementCompletionToken {
        guard let storage = self.storage else {
            preconditionFailure("A deferred virtio queue element was transferred more than once.")
        }
        self.storage = nil
        return PendingElementCompletionToken(storage: storage)
    }

    deinit {
        guard let storage else { return }
        #if DEBUG
            if storage.abandon() {
                assertionFailure("A deferred virtio queue element was dropped without completion.")
            }
        #else
            _ = storage.abandon()
        #endif
    }

    /// Returns the deferred element to the guest.
    public consuming func complete() {
        guard let storage = self.storage else {
            preconditionFailure("A deferred virtio queue element was completed more than once.")
        }
        self.storage = nil
        storage.complete()
    }
}

// UNCHECKED-SENDABLE: the lock makes transfer and completion of the one-shot token atomic.
/// Copyable one-shot completion state for APIs that require an escaping callback.
package final class PendingElementCompletionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (any PendingElementStorage)?

    package init(storage: any PendingElementStorage) {
        self.storage = storage
    }

    package func complete() {
        let storage = lock.withLock {
            let storage = self.storage
            self.storage = nil
            return storage
        }
        guard let storage else {
            preconditionFailure("A deferred virtio queue element was completed more than once.")
        }
        storage.complete()
    }

    deinit {
        let storage = lock.withLock { self.storage }
        guard let storage else { return }
        #if DEBUG
            if storage.abandon() {
                assertionFailure("A deferred virtio queue element token was dropped without completion.")
            }
        #else
            _ = storage.abandon()
        #endif
    }
}
