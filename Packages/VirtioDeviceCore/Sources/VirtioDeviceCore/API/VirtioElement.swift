/// An owned virtqueue element.
///
/// The noncopyable value must be completed or moved into a `PendingElement`.
public struct VirtioElement: ~Copyable {
    private var storage: (any VirtioElementStorage)?

    package init(storage: any VirtioElementStorage) {
        self.storage = storage
    }

    deinit {
        guard let storage else { return }
        #if DEBUG
            storage.complete()
            assertionFailure("A virtio queue element was dropped without completion.")
        #else
            storage.complete()
        #endif
    }

    /// Bytes available to copy from the guest's readable buffers.
    public var readableByteCount: Int {
        storage?.readableByteCount ?? 0
    }

    /// Bytes available for the device to write to the guest.
    public var writableByteCount: Int {
        storage?.writableByteCount ?? 0
    }

    /// Copies up to `maxBytes` from the readable buffers in one snapshot.
    public func copyReadable(maxBytes: Int) throws(VirtioFailure) -> [UInt8] {
        guard let storage else {
            throw .guestMemoryInvalidated
        }
        return try storage.copyReadable(maxBytes: maxBytes)
    }

    /// Writes bytes to the guest's writable buffers.
    public func write(_ bytes: UnsafeRawBufferPointer) throws(VirtioFailure) {
        guard let storage else {
            throw .guestMemoryInvalidated
        }
        try storage.write(bytes)
    }

    /// Returns this element to the guest exactly once.
    public consuming func complete() {
        guard let storage = self.storage else {
            preconditionFailure("A virtio queue element was completed more than once.")
        }
        self.storage = nil
        storage.complete()
    }

    /// Transfers this element to a handle that can be completed after a fence.
    public consuming func deferCompletion() -> PendingElement {
        guard let storage = self.storage else {
            preconditionFailure("A virtio queue element was deferred more than once.")
        }
        self.storage = nil
        return PendingElement(storage: storage.deferCompletion())
    }
}

package protocol VirtioElementStorage: AnyObject {
    var readableByteCount: Int { get }
    var writableByteCount: Int { get }
    func copyReadable(maxBytes: Int) throws(VirtioFailure) -> [UInt8]
    func write(_ bytes: UnsafeRawBufferPointer) throws(VirtioFailure)
    func complete()
    func deferCompletion() -> any PendingElementStorage
}

package protocol PendingElementStorage: AnyObject, Sendable {
    func complete()
    func abandon() -> Bool
}
