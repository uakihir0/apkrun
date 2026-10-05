import Foundation
import VirtioDeviceCore

/// A mutable test context that models DRIVER_OK and fixed-size configuration updates.
public final class FakeVirtioDeviceContext {
    private let backend: Backend

    /// The device context passed to production device-model callbacks.
    public var context: VirtioDeviceContext {
        VirtioDeviceContext(backend: backend, generation: backend.generation)
    }

    /// Creates a context with its driver initially not ready.
    public init(
        queueCount: Int,
        configurationSpace: Data = Data(),
        queues: [FakeVirtioQueue]? = nil
    ) {
        backend = Backend(
            queueCount: queueCount,
            configurationSpace: configurationSpace,
            queues: queues
        )
    }

    /// Marks the fake device ready or not ready.
    public func setReady(_ isReady: Bool) {
        backend.setReady(isReady)
    }

    /// Resets the device and invalidates every previously mapped guest range.
    public func reset() {
        backend.reset()
    }

    /// The current device-specific configuration bytes.
    public var configurationSpace: Data {
        backend.configurationSpace
    }
}

// UNCHECKED-SENDABLE: tests call the fake synchronously and model the context's serialized device queue.
private final class Backend: VirtioDeviceContextBackend, @unchecked Sendable {
    private let queueCount: Int
    private let queueObjects: [FakeVirtioQueue]
    private var mappedMemory: [FakeGuestMemory] = []
    private(set) var isReady = false
    private(set) var generation: UInt64 = 0
    var configurationSpace: Data

    init(
        queueCount: Int,
        configurationSpace: Data,
        queues: [FakeVirtioQueue]?
    ) {
        precondition(queueCount >= 0)
        self.queueCount = queueCount
        self.configurationSpace = configurationSpace
        if let queues {
            precondition(queues.count == queueCount)
            queueObjects = queues
        } else {
            queueObjects = (0..<queueCount).map { _ in FakeVirtioQueue(elements: []) }
        }
    }

    func queue(_ index: Int, generation: UInt64) throws(VirtioFailure) -> any VirtioQueue {
        guard isReady, generation == self.generation else {
            throw .notReady
        }
        guard queueObjects.indices.contains(index) else {
            throw .queueIndexInvalid(index)
        }
        return queueObjects[index]
    }

    func negotiatedFeatures(generation: UInt64) throws(VirtioFailure) -> UInt64 {
        guard isReady, generation == self.generation else {
            throw .notReady
        }
        return 0
    }

    func mapGuestMemory(
        _ range: GuestPhysicalRange,
        generation: UInt64
    ) throws(VirtioFailure) -> GuestMemory {
        guard isReady, generation == self.generation else {
            throw .notReady
        }
        let end = try range.validatedEndAddress()
        let size = range.length
        guard size <= UInt64(Int.max), end >= range.address else {
            throw .guestMemoryRangeInvalid
        }
        let fake = FakeGuestMemory(
            range: range,
            bytes: Array(repeating: 0, count: Int(size))
        )
        mappedMemory.append(fake)
        return fake.memory
    }

    func updateConfigurationSpace(
        _ bytes: Data,
        generation: UInt64
    ) async throws(VirtioFailure) {
        guard isReady, generation == self.generation else {
            throw .notReady
        }
        guard bytes.count == configurationSpace.count else {
            throw .configSizeMismatch(
                expected: configurationSpace.count,
                actual: bytes.count
            )
        }
        configurationSpace = bytes
    }

    func requestReset(reason: String, generation: UInt64) {
        _ = reason
        guard isReady, generation == self.generation else { return }
        reset()
    }

    func setReady(_ isReady: Bool) {
        guard self.isReady != isReady else { return }
        generation &+= 1
        self.isReady = isReady
    }

    func reset() {
        isReady = false
        generation &+= 1
        for memory in mappedMemory {
            memory.invalidate()
        }
        mappedMemory.removeAll(keepingCapacity: false)
    }
}
