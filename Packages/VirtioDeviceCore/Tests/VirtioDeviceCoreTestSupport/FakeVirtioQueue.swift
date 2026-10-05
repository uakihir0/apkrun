import Foundation
import VirtioDeviceCore

/// Queue-backed virtio elements for device-model unit tests.
public final class FakeVirtioQueue: VirtioQueue {
    private var elements: [ElementState]
    private var nextElementIndex = 0

    /// Creates a queue with one element per readable/writable buffer pair.
    public init(elements: [(readable: [UInt8], writableByteCount: Int)]) {
        self.elements = elements.map {
            ElementState(readable: $0.readable, writableByteCount: $0.writableByteCount)
        }
    }

    /// The number of elements not yet delivered to a drain callback.
    public var remainingElementCount: Int {
        elements.count - nextElementIndex
    }

    /// Completion counts for elements in their original queue order.
    public var completionCounts: [Int] {
        elements.map(\.completionCount)
    }

    /// Writable bytes captured from elements in their original queue order.
    public var writtenBuffers: [[UInt8]] {
        elements.map(\.writtenBytes)
    }

    public func drain(_ body: (consuming VirtioElement) -> Void) {
        while elements.indices.contains(nextElementIndex) {
            let element = elements[nextElementIndex]
            nextElementIndex += 1
            body(VirtioElement(storage: element))
        }
    }

    /// Invalidates elements already handed to a device model, as a reset does.
    public func invalidatePendingElements() {
        for element in elements {
            element.invalidate()
        }
    }
}

// UNCHECKED-SENDABLE: mutable fake element state is protected by its lock.
private final class ElementState: VirtioElementStorage, PendingElementStorage, @unchecked Sendable {
    private let readable: [UInt8]
    private let writableCapacity: Int
    private let lock = NSLock()
    private var didCopyReadable = false
    private var storedWrittenBytes: [UInt8] = []
    private var storedCompletionCount = 0
    private var isInvalidated = false

    init(readable: [UInt8], writableByteCount: Int) {
        precondition(writableByteCount >= 0)
        self.readable = readable
        writableCapacity = writableByteCount
    }

    var readableByteCount: Int {
        lock.withLock {
            didCopyReadable || isInvalidated ? 0 : readable.count
        }
    }

    var writableByteCount: Int {
        lock.withLock {
            writableCapacity - storedWrittenBytes.count
        }
    }

    var writtenBytes: [UInt8] {
        lock.withLock { storedWrittenBytes }
    }

    var completionCount: Int {
        lock.withLock { storedCompletionCount }
    }

    func copyReadable(maxBytes: Int) throws(VirtioFailure) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else {
            throw .guestMemoryInvalidated
        }
        guard maxBytes >= 0, !didCopyReadable else {
            throw .guestMemoryRangeInvalid
        }
        didCopyReadable = true
        return Array(readable.prefix(maxBytes))
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws(VirtioFailure) {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else {
            throw .guestMemoryInvalidated
        }
        let remainingByteCount = writableCapacity - storedWrittenBytes.count
        guard bytes.count <= remainingByteCount else {
            throw .guestMemoryAccessOutOfBounds(
                offset: storedWrittenBytes.count,
                length: bytes.count,
                capacity: writableCapacity
            )
        }
        if let baseAddress = bytes.baseAddress, bytes.count > 0 {
            storedWrittenBytes.append(
                contentsOf: UnsafeBufferPointer(
                    start: baseAddress.assumingMemoryBound(to: UInt8.self),
                    count: bytes.count
                ))
        }
    }

    func complete() {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return }
        precondition(storedCompletionCount == 0, "A fake queue element was completed more than once.")
        storedCompletionCount = 1
    }

    func abandon() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return false }
        precondition(storedCompletionCount == 0, "A fake queue element was completed more than once.")
        storedCompletionCount = 1
        return true
    }

    func deferCompletion() -> any PendingElementStorage {
        self
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        isInvalidated = true
    }
}
