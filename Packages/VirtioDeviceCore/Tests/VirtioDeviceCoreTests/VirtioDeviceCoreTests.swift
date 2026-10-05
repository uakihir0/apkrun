import Foundation
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport
import Virtualization

@Test func descriptorPreservesConfigurationAndSharedMemoryMetadata() {
    let descriptor = VirtioDeviceDescriptor(
        name: "test-entropy",
        deviceID: 4,
        pciClass: 0x10,
        pciSubclass: 0,
        queueCount: 1,
        mandatoryFeatures: 1 << 32,
        optionalFeatures: 1 << 2,
        configurationSpace: Data([0xAA, 0x55]),
        sharedMemoryRegions: [
            SharedMemoryRegionDescriptor(regionID: 3, sizeBytes: 8_192)
        ]
    )

    #expect(descriptor.name == "test-entropy")
    #expect(descriptor.deviceID == 4)
    #expect(descriptor.queueCount == 1)
    #expect(descriptor.mandatoryFeatures == 1 << 32)
    #expect(descriptor.optionalFeatures == 1 << 2)
    #expect(descriptor.configurationSpace == Data([0xAA, 0x55]))
    #expect(
        descriptor.sharedMemoryRegions == [
            SharedMemoryRegionDescriptor(regionID: 3, sizeBytes: 8_192)
        ])
}

@Test func featureBitsSplitAndRecombineAtTheThirtyTwoBitBoundary() {
    let bits = VirtioFeatureBits(0xA5A5_1234_FFFF_0001)

    #expect(bits.subset0 == 0xFFFF_0001)
    #expect(bits.subset1 == 0xA5A5_1234)
    #expect(bits.combined == 0xA5A5_1234_FFFF_0001)
}

@Test func vzAdapterBuildsConfigurationAndKeepsSaveRestoreDisabled() throws {
    let descriptor = VirtioDeviceDescriptor(
        name: "test-device",
        deviceID: 4,
        pciClass: 0x10,
        pciSubclass: 2,
        queueCount: 2,
        mandatoryFeatures: 0x8000_0001_0000_0002,
        optionalFeatures: 0x0000_1000_0000_0004,
        configurationSpace: Data([0x11, 0x22]),
        sharedMemoryRegions: [
            SharedMemoryRegionDescriptor(regionID: 7, sizeBytes: 4096)
        ]
    )
    let adapter = try VZCustomVirtioDeviceAdapter(
        model: DescriptorVirtioDevice(descriptor: descriptor),
        index: 3
    )
    let configuration = adapter.configuration
    let defaults = VZCustomVirtioDeviceConfiguration().optionalFeatures

    #expect(configuration.deviceID == 4)
    #expect(configuration.pciClassID == 0x10)
    #expect(configuration.pciSubclassID == 2)
    #expect(configuration.virtioQueueCount == 2)
    #expect(configuration.mandatoryFeatures.subset0 == 0x0000_0002)
    #expect(configuration.mandatoryFeatures.subset1 == 0x8000_0001)
    #expect(configuration.optionalFeatures.subset0 == (defaults.subset0 | 0x0000_0004))
    #expect(configuration.optionalFeatures.subset1 == (defaults.subset1 | 0x0000_1000))
    #expect(configuration.deviceSpecificConfiguration?.configurationData == Data([0x11, 0x22]))
    #expect(configuration.sharedMemoryRegions.count == 1)
    #expect(configuration.sharedMemoryRegions[0].regionID == 7)
    #expect(configuration.sharedMemoryRegions[0].size == 4096)
    #expect(configuration.supportsSaveRestore == false)
    #expect(configuration.provider === adapter.provider)
    #expect(adapter.provider.delegate === adapter)
}

@Test func vzAdapterRejectsOverlappingFeatureSets() {
    let descriptor = VirtioDeviceDescriptor(
        name: "invalid-features",
        deviceID: 4,
        pciClass: 0x10,
        pciSubclass: 0,
        queueCount: 1,
        mandatoryFeatures: 1 << 5,
        optionalFeatures: 1 << 5
    )

    #expect(
        throws: VZCustomVirtioDeviceAdapterFailure.invalidDescriptor(
            name: "invalid-features",
            reason: "mandatory and optional features overlap"
        )
    ) {
        try VZCustomVirtioDeviceAdapter(
            model: DescriptorVirtioDevice(descriptor: descriptor),
            index: 0
        )
    }
}

@Test func fakeQueueDrainsEveryElementAndCompletesEachExactlyOnce() {
    let queue = FakeVirtioQueue(elements: [
        (readable: [], writableByteCount: 1),
        (readable: [], writableByteCount: 1),
        (readable: [], writableByteCount: 1),
    ])
    var writtenByte: UInt8 = 1

    queue.drain { element in
        withUnsafeBytes(of: &writtenByte) { bytes in
            do {
                try element.write(bytes)
            } catch {
                Issue.record("Writing a byte to the fake queue failed: \(error)")
            }
        }
        element.complete()
        writtenByte += 1
    }

    #expect(queue.remainingElementCount == 0)
    #expect(queue.completionCounts == [1, 1, 1])
    #expect(queue.writtenBuffers == [[1], [2], [3]])
}

@Test func fakeQueueCopiesReadableBuffersOnce() {
    let queue = FakeVirtioQueue(elements: [
        (readable: [0x10, 0x20, 0x30], writableByteCount: 0)
    ])
    var copied: [UInt8] = []

    queue.drain { element in
        do {
            copied = try element.copyReadable(maxBytes: 2)
        } catch {
            Issue.record("Reading the fake queue failed: \(error)")
        }
        #expect(element.readableByteCount == 0)
        element.complete()
    }

    #expect(copied == [0x10, 0x20])
    #expect(queue.completionCounts == [1])
}

@Test func deferredQueueElementCompletesOnlyWhenThePendingHandleCompletes() {
    let queue = FakeVirtioQueue(elements: [
        (readable: [], writableByteCount: 0)
    ])
    var pending: PendingElement?

    queue.drain { element in
        pending = element.deferCompletion()
    }

    #expect(queue.remainingElementCount == 0)
    #expect(queue.completionCounts == [0])

    if let pending {
        pending.complete()
    } else {
        Issue.record("The deferred queue element was not retained.")
    }

    #expect(queue.completionCounts == [1])
}

@Test func deferredQueueElementCanCompleteFromAnotherActor() async {
    let queue = FakeVirtioQueue(elements: [
        (readable: [], writableByteCount: 0)
    ])
    var pending: PendingElement?

    queue.drain { element in
        pending = element.deferCompletion()
    }

    guard let pending else {
        Issue.record("The deferred queue element was not retained.")
        return
    }
    let completionActor = PendingElementCompletionActor()
    await completionActor.complete(consume pending)

    #expect(queue.completionCounts == [1])
}

@Test func pendingCompletionTokenCanCompleteFromAnEscapingTask() async {
    let queue = FakeVirtioQueue(elements: [
        (readable: [], writableByteCount: 0)
    ])
    var pending: PendingElement?

    queue.drain { element in
        pending = element.deferCompletion()
    }

    guard let pending else {
        Issue.record("The deferred queue element was not retained.")
        return
    }
    let token = pending.makeCompletionToken()
    let completionActor = PendingElementCompletionActor()
    let completionTask = Task {
        await completionActor.complete(token)
    }
    await completionTask.value

    #expect(queue.completionCounts == [1])
}

@Test func completingPendingCompletionTokenTwiceFailsInAnExitTest() async {
    await #expect(processExitsWith: .failure) {
        let queue = FakeVirtioQueue(elements: [
            (readable: [], writableByteCount: 0)
        ])
        var token: PendingElementCompletionToken?

        queue.drain { element in
            token = element.deferCompletion().makeCompletionToken()
        }

        guard let token else {
            Issue.record("The deferred queue element token was not retained.")
            return
        }
        token.complete()
        token.complete()
    }
}

@Test func droppingPendingElementAfterResetDoesNotCompleteInvalidatedElement() async {
    await #expect(processExitsWith: .success) {
        let queue = FakeVirtioQueue(elements: [
            (readable: [], writableByteCount: 0)
        ])
        var pending: PendingElement?

        queue.drain { element in
            pending = element.deferCompletion()
        }
        guard pending != nil else {
            Issue.record("The deferred queue element was not retained.")
            return
        }
        queue.invalidatePendingElements()
        pending = nil
    }
}

@Test func retainedDeviceQueueLeaseDoesNotKeepOwnerAliveAndReleasesItsResource() {
    weak var weakOwner: LeaseOwner?
    weak var weakResource: LeaseResource?
    var lease: VZDeviceQueueLease<LeaseResource>?
    do {
        let owner = LeaseOwner()
        let resource = LeaseResource()
        weakOwner = owner
        weakResource = resource
        lease = VZDeviceQueueLease(owner: owner, resource: resource)
    }

    #expect(weakOwner == nil)
    #expect(weakResource != nil)

    lease?.invalidate()

    #expect(weakResource == nil)
}

@Test func retainedPendingHandleDoesNotKeepInvalidatedVZElementStorageAlive() {
    weak var weakTarget: FakeVZPendingElementTarget?
    var pending: PendingElement?
    do {
        let target = FakeVZPendingElementTarget()
        weakTarget = target
        pending = PendingElement(storage: VZPendingElementStorage(element: target))
    }

    #expect(weakTarget == nil)
    guard let pending else {
        Issue.record("The pending element handle was not retained.")
        return
    }
    pending.complete()
}

#if DEBUG
    @Test func droppingAnUncompletedQueueElementFailsInAnExitTest() async {
        await #expect(processExitsWith: .failure) {
            let queue = FakeVirtioQueue(elements: [
                (readable: [], writableByteCount: 0)
            ])
            queue.drain { _ in }
        }
    }

    @Test func droppingAnUncompletedPendingElementFailsInAnExitTest() async {
        await #expect(processExitsWith: .failure) {
            let queue = FakeVirtioQueue(elements: [
                (readable: [], writableByteCount: 0)
            ])
            queue.drain { element in
                let pending = element.deferCompletion()
                _ = pending
            }
        }
    }

    @Test func droppingAnInvalidatedVZPendingElementSucceedsInAnExitTest() async {
        await #expect(processExitsWith: .success) {
            let target = FakeVZPendingElementTarget()
            let lifecycle = VZPendingElementLifecycle()
            var pending: PendingElement? = PendingElement(
                storage: VZPendingElementStorage(element: target, lifecycle: lifecycle)
            )

            precondition(pending != nil)
            lifecycle.invalidate()
            pending = nil
            #expect(target.completionCount == 0)
        }
    }

    @Test func droppingALiveVZPendingElementFailsInAnExitTest() async {
        await #expect(processExitsWith: .failure) {
            let target = FakeVZPendingElementTarget()
            let epoch = VZDeviceEpoch()
            epoch.activate()
            let lifecycle = VZPendingElementLifecycle(
                epoch: epoch,
                generation: epoch.generation
            )
            var pending: PendingElement? = PendingElement(
                storage: VZPendingElementStorage(element: target, lifecycle: lifecycle)
            )

            precondition(pending != nil)
            pending = nil
        }
    }

    @Test func droppingPendingHandleAfterConcurrentEpochInvalidationSucceedsInAnExitTest() async {
        await #expect(processExitsWith: .success) {
            let target = FakeVZPendingElementTarget()
            let epoch = VZDeviceEpoch()
            epoch.activate()
            let lifecycle = VZPendingElementLifecycle(
                epoch: epoch,
                generation: epoch.generation
            )
            var pending: PendingElement? = PendingElement(
                storage: VZPendingElementStorage(element: target, lifecycle: lifecycle)
            )

            let invalidationTask = Task.detached {
                epoch.invalidate()
            }
            await invalidationTask.value
            precondition(!lifecycle.abandonIfLive())
            precondition(pending != nil)
            pending = nil
            #expect(target.completionCount == 0)
        }
    }
#endif

@Test func guestMemoryChecksBoundsAndSupportsWrites() throws {
    let fake = FakeGuestMemory(
        range: GuestPhysicalRange(address: 0x1000, length: 3),
        bytes: [1, 2, 3]
    )

    #expect(try fake.memory.copyBytes(at: 1, count: 2) == [2, 3])
    try fake.memory.writeBytes([9], at: 2)
    #expect(try fake.memory.copyBytes(at: 0, count: 3) == [1, 2, 9])
    #expect(
        throws: VirtioFailure.guestMemoryAccessOutOfBounds(
            offset: -1,
            length: 1,
            capacity: 3
        )
    ) {
        try fake.memory.copyBytes(at: -1, count: 1)
    }
    #expect(
        throws: VirtioFailure.guestMemoryAccessOutOfBounds(
            offset: 2,
            length: 2,
            capacity: 3
        )
    ) {
        try fake.memory.copyBytes(at: 2, count: 2)
    }
    #expect(
        throws: VirtioFailure.guestMemoryAccessOutOfBounds(
            offset: Int.max,
            length: 1,
            capacity: 3
        )
    ) {
        try fake.memory.copyBytes(at: Int.max, count: 1)
    }
}

@Test func guestMemoryViewFailsAfterMappingInvalidation() {
    let fake = FakeGuestMemory(
        range: GuestPhysicalRange(address: 0x2000, length: 4),
        bytes: [1, 2, 3, 4]
    )
    let staleView = fake.memory
    fake.invalidate()

    #expect(throws: VirtioFailure.guestMemoryInvalidated) {
        try staleView.copyBytes(at: 0, count: 0)
    }
    #expect(throws: VirtioFailure.guestMemoryInvalidated) {
        try staleView.writeBytes([5], at: 0)
    }
}

@Test func deviceContextRejectsOperationsBeforeDriverOK() async {
    let fake = FakeVirtioDeviceContext(queueCount: 1, configurationSpace: Data([1, 2]))

    #expect(throws: VirtioFailure.notReady) {
        try fake.context.queue(0)
    }
    #expect(throws: VirtioFailure.notReady) {
        try fake.context.negotiatedFeatures
    }
    #expect(throws: VirtioFailure.notReady) {
        try fake.context.mapGuestMemory(GuestPhysicalRange(address: 0x3000, length: 4))
    }
    await #expect(throws: VirtioFailure.notReady) {
        try await fake.context.updateConfigurationSpace(Data([3, 4]))
    }
}

@Test func deviceContextChecksQueueIndexAndGuestPhysicalOverflow() {
    let fake = FakeVirtioDeviceContext(queueCount: 1)
    fake.setReady(true)

    #expect(throws: VirtioFailure.queueIndexInvalid(1)) {
        try fake.context.queue(1)
    }
    #expect(throws: VirtioFailure.guestMemoryRangeInvalid) {
        try fake.context.mapGuestMemory(
            GuestPhysicalRange(address: UInt64.max - 1, length: 4)
        )
    }
}

@Test func configurationUpdatesRequireTheOriginalSize() async throws {
    let fake = FakeVirtioDeviceContext(
        queueCount: 1,
        configurationSpace: Data(repeating: 0, count: 8)
    )
    fake.setReady(true)

    try await fake.context.updateConfigurationSpace(Data(repeating: 0xA5, count: 8))
    #expect(fake.configurationSpace == Data(repeating: 0xA5, count: 8))
    await #expect(throws: VirtioFailure.configSizeMismatch(expected: 8, actual: 4)) {
        try await fake.context.updateConfigurationSpace(Data(repeating: 0, count: 4))
    }
}

@Test func configurationUpdaterFromAnOldGenerationIsRejected() async throws {
    let fake = FakeVirtioDeviceContext(
        queueCount: 1,
        configurationSpace: Data(repeating: 0, count: 8)
    )
    fake.setReady(true)
    let staleContext = fake.context
    let staleUpdater = staleContext.configurationUpdater

    fake.reset()
    fake.setReady(true)
    let currentUpdater = fake.context.configurationUpdater

    #expect(throws: VirtioFailure.notReady) {
        try staleContext.queue(0)
    }
    #expect(throws: VirtioFailure.notReady) {
        try staleContext.negotiatedFeatures
    }
    #expect(throws: VirtioFailure.notReady) {
        try staleContext.mapGuestMemory(
            GuestPhysicalRange(address: 0x3000, length: 4)
        )
    }
    staleContext.requestReset(reason: "stale-generation test")
    #expect(try fake.context.negotiatedFeatures == 0)

    await #expect(throws: VirtioFailure.notReady) {
        try await staleUpdater.updateConfigurationSpace(Data(repeating: 0x11, count: 8))
    }
    try await currentUpdater.updateConfigurationSpace(Data(repeating: 0x22, count: 8))
    #expect(fake.configurationSpace == Data(repeating: 0x22, count: 8))
}

@Test func entropyDeviceFillsTheSeededStreamAndRestartsAfterReset() {
    let firstQueue = FakeVirtioQueue(elements: [
        (readable: [], writableByteCount: 8),
        (readable: [], writableByteCount: 5),
    ])
    let firstContext = FakeVirtioDeviceContext(
        queueCount: 1,
        configurationSpace: Data(repeating: 0, count: 8),
        queues: [firstQueue]
    )
    firstContext.setReady(true)
    let device = EntropyTestDevice(
        seed: 0,
        performsConfigurationProbe: false
    )

    device.deviceDidStart(context: firstContext.context, negotiatedFeatures: 0)
    device.queueNotified(index: 0, context: firstContext.context)

    let expected: [UInt8] = [
        0xAF, 0xCD, 0x1D, 0x7B, 0x39, 0xA8, 0x20, 0xE2,
        0xF4, 0x65, 0xB9, 0xA1, 0x6A,
    ]
    #expect(firstQueue.writtenBuffers == [Array(expected.prefix(8)), Array(expected.suffix(5))])
    #expect(firstQueue.completionCounts == [1, 1])

    device.deviceWillReset()
    let secondQueue = FakeVirtioQueue(elements: [
        (readable: [], writableByteCount: expected.count)
    ])
    let secondContext = FakeVirtioDeviceContext(
        queueCount: 1,
        configurationSpace: Data(repeating: 0, count: 8),
        queues: [secondQueue]
    )
    secondContext.setReady(true)
    device.deviceDidStart(context: secondContext.context, negotiatedFeatures: 0)
    device.queueNotified(index: 0, context: secondContext.context)

    #expect(secondQueue.writtenBuffers == [expected])
    #expect(secondQueue.completionCounts == [1])
}

@Test func fakeContextResetInvalidatesPreviouslyReturnedGuestMemory() throws {
    let fake = FakeVirtioDeviceContext(queueCount: 0)
    fake.setReady(true)
    let stale = try fake.context.mapGuestMemory(
        GuestPhysicalRange(address: 0x4000, length: 4)
    )

    fake.reset()

    #expect(throws: VirtioFailure.guestMemoryInvalidated) {
        try stale.copyBytes(at: 0, count: 1)
    }
}

private final class DescriptorVirtioDevice: VirtioDeviceModel, Sendable {
    let descriptor: VirtioDeviceDescriptor

    init(descriptor: VirtioDeviceDescriptor) {
        self.descriptor = descriptor
    }
}

private actor PendingElementCompletionActor {
    func complete(_ pending: consuming PendingElement) {
        pending.complete()
    }

    func complete(_ token: PendingElementCompletionToken) {
        token.complete()
    }
}

private final class LeaseOwner {}

private final class LeaseResource {}

private final class FakeVZPendingElementTarget: VZPendingElementTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var completions = 0

    var completionCount: Int {
        lock.withLock { completions }
    }

    func completeDeferred() {
        lock.withLock {
            completions += 1
        }
    }
}
