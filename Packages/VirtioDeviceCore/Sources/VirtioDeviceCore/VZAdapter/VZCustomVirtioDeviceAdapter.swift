import Dispatch
import Foundation
import Virtualization

/// Owns a custom device's framework objects and confines their use to its VZ device queue.
// UNCHECKED-SENDABLE: VZ framework callbacks synchronize device state on deviceQueue; didCreateDevice only installs the delegate and publishes the device under lock.
package final class VZCustomVirtioDeviceAdapter:
    NSObject,
    VZCustomVirtioDeviceConfigurationDelegate,
    VZCustomVirtioDeviceDelegate,
    @unchecked Sendable
{
    package let configuration: VZCustomVirtioDeviceConfiguration
    package var provider: VZCustomVirtioDeviceDelegateProvider {
        guard let providerStorage else {
            preconditionFailure("The VZ device delegate provider is unavailable before initialization.")
        }
        return providerStorage
    }

    private let model: any VirtioDeviceModel
    private let descriptor: VirtioDeviceDescriptor
    private let deviceQueue: DispatchQueue
    private let queueToken = UUID()
    private let queueKey = DispatchSpecificKey<UUID>()
    private let contextBackend: VZDeviceContextBackend
    private let deviceLock = NSLock()
    private var providerStorage: VZCustomVirtioDeviceDelegateProvider?
    private var deviceStorage: VZCustomVirtioDevice?
    private var isReady = false
    private var isReleased = false
    private var didNotifyStop = false
    private var currentConfigurationSpace: Data
    private var memoryMappings: [GuestPhysicalRange: VZGuestMemoryStorage] = [:]
    private var queueAdapters: [Int: VZVirtioQueueAdapter] = [:]
    private var pendingElements: [ObjectIdentifier: VZVirtioElementStorage] = [:]
    private var activeConfigurationUpdate: VZConfigurationUpdateRequest?
    private var pendingConfigurationUpdates: [VZConfigurationUpdateRequest] = []
    fileprivate let epoch = VZDeviceEpoch()

    package init(
        model: any VirtioDeviceModel,
        index: Int
    ) throws(VZCustomVirtioDeviceAdapterFailure) {
        let descriptor = model.descriptor
        try Self.validate(descriptor)

        let deviceQueue = DispatchQueue(
            label: "io.apkrun.vm.virtio.\(index)",
            qos: .userInteractive
        )
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = descriptor.deviceID
        configuration.pciClassID = descriptor.pciClass
        configuration.pciSubclassID = descriptor.pciSubclass
        configuration.virtioQueueCount = descriptor.queueCount
        configuration.supportsSaveRestore = false

        let mandatory = VirtioFeatureBits(descriptor.mandatoryFeatures)
        configuration.mandatoryFeatures.subset0 |= mandatory.subset0
        configuration.mandatoryFeatures.subset1 |= mandatory.subset1
        let optional = VirtioFeatureBits(descriptor.optionalFeatures)
        configuration.optionalFeatures.subset0 |= optional.subset0
        configuration.optionalFeatures.subset1 |= optional.subset1
        let effectiveMandatoryFeatures =
            UInt64(configuration.mandatoryFeatures.subset0)
            | (UInt64(configuration.mandatoryFeatures.subset1) << 32)
        let effectiveOptionalFeatures =
            UInt64(configuration.optionalFeatures.subset0)
            | (UInt64(configuration.optionalFeatures.subset1) << 32)
        guard effectiveMandatoryFeatures & effectiveOptionalFeatures == 0 else {
            throw .invalidDescriptor(
                name: descriptor.name,
                reason: "mandatory and optional features overlap after framework defaults"
            )
        }

        if !descriptor.configurationSpace.isEmpty {
            configuration.deviceSpecificConfiguration =
                VZVirtioDeviceSpecificConfiguration(
                    configurationData: descriptor.configurationSpace
                )
        }
        configuration.sharedMemoryRegions = descriptor.sharedMemoryRegions.map {
            VZVirtioSharedMemoryRegionConfiguration(
                regionID: $0.regionID,
                size: $0.sizeBytes
            )
        }

        let contextBackend = VZDeviceContextBackend()
        self.configuration = configuration
        self.model = model
        self.descriptor = descriptor
        self.deviceQueue = deviceQueue
        self.contextBackend = contextBackend
        currentConfigurationSpace = descriptor.configurationSpace
        super.init()

        deviceQueue.setSpecific(key: queueKey, value: queueToken)
        contextBackend.adapter = self
        let provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: deviceQueue,
            delegate: self
        )
        providerStorage = provider
        configuration.provider = provider
    }

    package var device: VZCustomVirtioDevice? {
        deviceLock.withLock { deviceStorage }
    }

    package func customVirtioConfiguration(
        _ deviceConfiguration: VZCustomVirtioDeviceConfiguration,
        didCreateDevice device: VZCustomVirtioDevice
    ) {
        install(device: device)
    }

    package func install(device: VZCustomVirtioDevice) {
        device.delegate = self
        deviceLock.withLock {
            deviceStorage = device
        }
    }

    package func assertOnDeviceQueue() {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        precondition(DispatchQueue.getSpecific(key: queueKey) == queueToken)
    }

    package var isOnDeviceQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == queueToken
    }

    package func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        assertOnDeviceQueue()
        guard !isReleased, !didNotifyStop, let adapterDevice = self.device, adapterDevice === device,
            let negotiated = device.negotiatedFeatures
        else {
            return
        }
        epoch.activate()
        isReady = true
        model.deviceDidStart(
            context: contextForCurrentGeneration(),
            negotiatedFeatures: UInt64(negotiated.subset0)
                | (UInt64(negotiated.subset1) << 32)
        )
    }

    package func customVirtioDevice(
        _ device: VZCustomVirtioDevice,
        didReceiveNotificationFor queue: VZVirtioQueue
    ) {
        assertOnDeviceQueue()
        guard !isReleased, isReady, self.device === device else { return }
        model.queueNotified(
            index: Int(queue.queueIndex),
            context: contextForCurrentGeneration()
        )
    }

    package func customVirtioDeviceWillPause(_ device: VZCustomVirtioDevice) {
        assertOnDeviceQueue()
        guard !isReleased, !didNotifyStop, self.device === device else { return }
        model.deviceWillPause()
    }

    package func customVirtioDeviceWillResume(_ device: VZCustomVirtioDevice) {
        assertOnDeviceQueue()
        guard !isReleased, !didNotifyStop, self.device === device else { return }
        model.deviceWillResume()
    }

    package func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        assertOnDeviceQueue()
        guard !isReleased, !didNotifyStop, self.device === device else { return }
        invalidateGuestState()
        model.deviceWillReset()
    }

    package func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        assertOnDeviceQueue()
        guard !isReleased, self.device === device else { return }
        stopModelAndInvalidateGuestState()
    }

    /// Drains prior device callbacks, invalidates guest-backed state, and
    /// disconnects the weak VZ delegate before the VM driver releases us.
    package func prepareForRelease() {
        let releaseOnDeviceQueue = {
            self.assertOnDeviceQueue()
            if !self.didNotifyStop {
                self.stopModelAndInvalidateGuestState()
            } else {
                self.invalidateGuestState()
            }
            self.isReleased = true
            self.device?.delegate = nil
            self.deviceLock.withLock {
                self.deviceStorage = nil
            }
        }
        if isOnDeviceQueue {
            releaseOnDeviceQueue()
        } else {
            deviceQueue.sync(execute: releaseOnDeviceQueue)
        }
    }

    package func queue(
        _ index: Int,
        generation: UInt64
    ) throws(VirtioFailure) -> any VirtioQueue {
        assertOnDeviceQueue()
        guard isReady, epoch.isCurrent(generation) else {
            throw .notReady
        }
        guard index >= 0, index < Int(descriptor.queueCount),
            let deviceQueue = device?.queue(at: UInt16(index))
        else {
            throw .queueIndexInvalid(index)
        }
        if let queueAdapter = queueAdapters[index] {
            return queueAdapter
        }
        let queueAdapter = VZVirtioQueueAdapter(
            queue: deviceQueue,
            adapter: self,
            generation: epoch.generation
        )
        queueAdapters[index] = queueAdapter
        return queueAdapter
    }

    package func negotiatedFeatures(generation: UInt64) throws(VirtioFailure) -> UInt64 {
        assertOnDeviceQueue()
        guard
            isReady,
            epoch.isCurrent(generation),
            let features = device?.negotiatedFeatures
        else {
            throw .notReady
        }
        return UInt64(features.subset0) | (UInt64(features.subset1) << 32)
    }

    package func mapGuestMemory(
        _ range: GuestPhysicalRange,
        generation: UInt64
    ) throws(VirtioFailure) -> GuestMemory {
        assertOnDeviceQueue()
        guard isReady, epoch.isCurrent(generation), let device else {
            throw .notReady
        }
        _ = try range.validatedEndAddress()
        if let storage = memoryMappings[range] {
            try storage.validate()
            return GuestMemory(range: range, storage: storage)
        }
        guard range.length <= UInt64(Int.max),
            let mapping = device.guestMemoryMapping(
                atPhysicalAddress: range.address,
                length: Int(range.length)
            )
        else {
            throw .guestMemoryRangeInvalid
        }
        let storage = VZGuestMemoryStorage(mapping: mapping)
        storage.adapter = self
        storage.generation = epoch.generation
        memoryMappings[range] = storage
        return GuestMemory(range: range, storage: storage)
    }

    package func updateConfigurationSpace(
        _ bytes: Data,
        generation: UInt64
    ) async throws(VirtioFailure) {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Void, VirtioFailure>, Never>) in
            deviceQueue.async {
                self.assertOnDeviceQueue()
                guard
                    !self.isReleased,
                    self.isReady,
                    self.epoch.isCurrent(generation),
                    self.device != nil
                else {
                    continuation.resume(returning: .failure(.notReady))
                    return
                }
                guard bytes.count == self.currentConfigurationSpace.count else {
                    continuation.resume(
                        returning: .failure(
                            .configSizeMismatch(
                                expected: self.currentConfigurationSpace.count,
                                actual: bytes.count
                            )
                        )
                    )
                    return
                }
                self.pendingConfigurationUpdates.append(
                    VZConfigurationUpdateRequest(
                        bytes: bytes,
                        generation: generation,
                        continuation: continuation
                    )
                )
                self.startNextConfigurationUpdate()
            }
        }
        try result.get()
    }

    package func requestReset(reason _: String, generation: UInt64) {
        deviceQueue.async {
            self.assertOnDeviceQueue()
            guard !self.isReleased, self.epoch.isCurrent(generation) else { return }
            self.device?.requestReset()
        }
    }

    package func isCurrent(generation: UInt64) -> Bool {
        assertOnDeviceQueue()
        return !isReleased && isReady && epoch.isCurrent(generation)
    }

    private func contextForCurrentGeneration() -> VirtioDeviceContext {
        assertOnDeviceQueue()
        return VirtioDeviceContext(
            backend: contextBackend,
            generation: epoch.generation
        )
    }

    fileprivate func retainPending(_ element: VZVirtioElementStorage) {
        assertOnDeviceQueue()
        pendingElements[ObjectIdentifier(element)] = element
    }

    fileprivate func releasePending(_ element: VZVirtioElementStorage) {
        assertOnDeviceQueue()
        pendingElements.removeValue(forKey: ObjectIdentifier(element))
    }

    fileprivate func completePending(_ element: VZVirtioElementStorage) {
        assertOnDeviceQueue()
        guard isCurrent(generation: element.generation) else {
            element.invalidate()
            releasePending(element)
            return
        }
        element.returnToGuest()
        releasePending(element)
    }

    fileprivate func completePendingAsync(_ element: VZVirtioElementStorage) {
        deviceQueue.async {
            self.completePending(element)
        }
    }

    fileprivate func completePendingDeferred(_ element: VZVirtioElementStorage) {
        if isOnDeviceQueue {
            completePending(element)
        } else {
            completePendingAsync(element)
        }
    }

    private func invalidateGuestState() {
        assertOnDeviceQueue()
        epoch.invalidate()
        isReady = false
        activeConfigurationUpdate?.resolve(.failure(.notReady))
        for request in pendingConfigurationUpdates {
            request.resolve(.failure(.notReady))
        }
        pendingConfigurationUpdates.removeAll(keepingCapacity: false)
        for mapping in memoryMappings.values {
            mapping.invalidate()
        }
        memoryMappings.removeAll(keepingCapacity: false)
        let queues = Array(queueAdapters.values)
        queueAdapters.removeAll(keepingCapacity: false)
        for queue in queues {
            queue.invalidate()
        }
        let pending = Array(pendingElements.values)
        pendingElements.removeAll(keepingCapacity: false)
        for element in pending {
            element.invalidate()
        }
    }

    private func stopModelAndInvalidateGuestState() {
        assertOnDeviceQueue()
        guard !didNotifyStop else { return }
        didNotifyStop = true
        invalidateGuestState()
        model.deviceWillStop()
    }

    private func startNextConfigurationUpdate() {
        assertOnDeviceQueue()
        guard activeConfigurationUpdate == nil,
            !pendingConfigurationUpdates.isEmpty
        else {
            return
        }
        guard !isReleased, isReady, let device else {
            let pending = pendingConfigurationUpdates
            pendingConfigurationUpdates.removeAll(keepingCapacity: false)
            for request in pending {
                request.resolve(.failure(.notReady))
            }
            return
        }

        let request = pendingConfigurationUpdates.removeFirst()
        guard request.generation == epoch.generation else {
            request.resolve(.failure(.notReady))
            startNextConfigurationUpdate()
            return
        }
        activeConfigurationUpdate = request
        let configuration = VZVirtioDeviceSpecificConfiguration(
            configurationData: request.bytes
        )
        device.update(configuration) { error in
            self.assertOnDeviceQueue()
            if self.activeConfigurationUpdate === request {
                self.activeConfigurationUpdate = nil
            }
            guard !self.isReleased, self.isReady,
                request.generation == self.epoch.generation
            else {
                request.resolve(.failure(.notReady))
                self.startNextConfigurationUpdate()
                return
            }

            if let error {
                let nsError = error as NSError
                request.resolve(
                    .failure(
                        .configurationUpdateFailed(
                            domain: nsError.domain,
                            code: nsError.code
                        )
                    )
                )
            } else {
                self.currentConfigurationSpace = request.bytes
                request.resolve(.success(()))
            }
            self.startNextConfigurationUpdate()
        }
    }

    private static func validate(
        _ descriptor: VirtioDeviceDescriptor
    ) throws(VZCustomVirtioDeviceAdapterFailure) {
        guard !descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidDescriptor(name: descriptor.name, reason: "name must not be empty")
        }
        guard descriptor.queueCount > 0 else {
            throw .invalidDescriptor(
                name: descriptor.name,
                reason: "queue count must be at least one"
            )
        }
        guard descriptor.mandatoryFeatures & descriptor.optionalFeatures == 0 else {
            throw .invalidDescriptor(
                name: descriptor.name,
                reason: "mandatory and optional features overlap"
            )
        }
        guard
            descriptor.sharedMemoryRegions.count
                <= VZCustomVirtioDeviceConfiguration.maximumAllowedSharedMemoryRegionCount
        else {
            throw .invalidDescriptor(
                name: descriptor.name,
                reason: "shared memory region count exceeds the framework limit"
            )
        }
        var regionIDs = Set<UInt8>()
        for region in descriptor.sharedMemoryRegions {
            guard region.sizeBytes > 0 else {
                throw .invalidDescriptor(
                    name: descriptor.name,
                    reason: "shared memory region size must be greater than zero"
                )
            }
            guard regionIDs.insert(region.regionID).inserted else {
                throw .invalidDescriptor(
                    name: descriptor.name,
                    reason: "shared memory region IDs must be unique"
                )
            }
        }
    }
}

package enum VZCustomVirtioDeviceAdapterFailure: Error, Equatable, Sendable {
    case invalidDescriptor(name: String, reason: String)
}

// UNCHECKED-SENDABLE: the continuation is resolved exactly once on deviceQueue.
private final class VZConfigurationUpdateRequest: @unchecked Sendable {
    let bytes: Data
    let generation: UInt64
    private var continuation: CheckedContinuation<Result<Void, VirtioFailure>, Never>?

    init(
        bytes: Data,
        generation: UInt64,
        continuation: CheckedContinuation<Result<Void, VirtioFailure>, Never>
    ) {
        self.bytes = bytes
        self.generation = generation
        self.continuation = continuation
    }

    func resolve(_ result: Result<Void, VirtioFailure>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}

// UNCHECKED-SENDABLE: synchronous methods assert deviceQueue confinement; async updates enqueue there.
private final class VZDeviceContextBackend: VirtioDeviceContextBackend, @unchecked Sendable {
    weak var adapter: VZCustomVirtioDeviceAdapter?

    func queue(_ index: Int, generation: UInt64) throws(VirtioFailure) -> any VirtioQueue {
        guard let adapter else { throw .notReady }
        return try adapter.queue(index, generation: generation)
    }

    func negotiatedFeatures(generation: UInt64) throws(VirtioFailure) -> UInt64 {
        guard let adapter else { throw .notReady }
        return try adapter.negotiatedFeatures(generation: generation)
    }

    func mapGuestMemory(
        _ range: GuestPhysicalRange,
        generation: UInt64
    ) throws(VirtioFailure) -> GuestMemory {
        guard let adapter else { throw .notReady }
        return try adapter.mapGuestMemory(range, generation: generation)
    }

    func updateConfigurationSpace(
        _ bytes: Data,
        generation: UInt64
    ) async throws(VirtioFailure) {
        guard let adapter else { throw .notReady }
        try await adapter.updateConfigurationSpace(bytes, generation: generation)
    }

    func requestReset(reason: String, generation: UInt64) {
        adapter?.requestReset(reason: reason, generation: generation)
    }
}

package final class VZDeviceEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var storedGeneration: UInt64 = 0
    private var storedIsActive = false

    package init() {}

    package var generation: UInt64 {
        lock.withLock { storedGeneration }
    }

    package var isActive: Bool {
        lock.withLock { storedIsActive }
    }

    package func activate() {
        lock.withLock {
            storedGeneration &+= 1
            storedIsActive = true
        }
    }

    package func invalidate() {
        lock.withLock {
            storedGeneration &+= 1
            storedIsActive = false
        }
    }

    package func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock {
            storedIsActive && storedGeneration == candidate
        }
    }
}

package final class VZDeviceQueueLease<Resource: AnyObject> {
    private weak var owner: AnyObject?
    private var resource: Resource?

    package init(owner: AnyObject, resource: Resource) {
        self.owner = owner
        self.resource = resource
    }

    package func resource(for owner: AnyObject) -> Resource? {
        guard self.owner === owner else { return nil }
        return resource
    }

    package func invalidate() {
        resource = nil
        owner = nil
    }
}

private final class VZVirtioQueueAdapter: VirtioQueue {
    private let queueLease: VZDeviceQueueLease<VZVirtioQueue>
    private weak var adapter: VZCustomVirtioDeviceAdapter?
    private let generation: UInt64

    init(queue: VZVirtioQueue, adapter: VZCustomVirtioDeviceAdapter, generation: UInt64) {
        queueLease = VZDeviceQueueLease(owner: adapter, resource: queue)
        self.adapter = adapter
        self.generation = generation
    }

    func drain(_ body: (consuming VirtioElement) -> Void) {
        guard let adapter else { return }
        adapter.assertOnDeviceQueue()
        guard
            adapter.isCurrent(generation: generation),
            let queue = queueLease.resource(for: adapter)
        else {
            return
        }
        while let element = queue.nextElement() {
            let storage = VZVirtioElementStorage(
                element: element,
                adapter: adapter,
                generation: generation
            )
            body(VirtioElement(storage: storage))
        }
    }

    func invalidate() {
        adapter?.assertOnDeviceQueue()
        queueLease.invalidate()
    }
}

// UNCHECKED-SENDABLE: every VZ element and mutable state access is serialized on its owning adapter's deviceQueue.
private final class VZVirtioElementStorage:
    VirtioElementStorage,
    VZPendingElementTarget,
    @unchecked Sendable
{
    private var element: VZVirtioQueueElement?
    private weak var adapter: VZCustomVirtioDeviceAdapter?
    fileprivate let generation: UInt64
    private let pendingLifecycle: VZPendingElementLifecycle
    private var didRead = false
    private var isCompleted = false
    private var isInvalidated = false

    init(
        element: VZVirtioQueueElement,
        adapter: VZCustomVirtioDeviceAdapter,
        generation: UInt64
    ) {
        self.element = element
        self.adapter = adapter
        self.generation = generation
        pendingLifecycle = VZPendingElementLifecycle(
            epoch: adapter.epoch,
            generation: generation
        )
    }

    var readableByteCount: Int {
        guard isLive, let element else { return 0 }
        return Int(element.readBuffersAvailableByteCount)
    }

    var writableByteCount: Int {
        guard isLive, let element else { return 0 }
        return Int(element.writeBuffersAvailableByteCount)
    }

    func copyReadable(maxBytes: Int) throws(VirtioFailure) -> [UInt8] {
        guard isLive, let element else { throw .guestMemoryInvalidated }
        guard maxBytes >= 0, !didRead else { throw .guestMemoryRangeInvalid }
        didRead = true
        let count = min(maxBytes, Int(element.readBuffersAvailableByteCount))
        let data: Data
        do {
            data = try element.readBytes(withExactLength: count)
        } catch {
            throw Self.map(error as NSError)
        }
        return Array(data)
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws(VirtioFailure) {
        guard isLive, let element else { throw .guestMemoryInvalidated }
        guard bytes.count <= Int(element.writeBuffersAvailableByteCount) else {
            throw .guestMemoryAccessOutOfBounds(
                offset: Int(element.writtenByteCount),
                length: bytes.count,
                capacity: Int(element.writeBuffersByteCount)
            )
        }
        let data = Data(bytes)
        do {
            try element.write(data)
        } catch {
            throw Self.map(error as NSError)
        }
    }

    func complete() {
        guard let adapter else { return }
        adapter.assertOnDeviceQueue()
        guard !isCompleted else {
            preconditionFailure("A VZ virtio element was completed more than once.")
        }
        guard !isInvalidated else { return }
        guard adapter.isCurrent(generation: generation) else {
            invalidate()
            return
        }
        returnToGuest()
    }

    func deferCompletion() -> any PendingElementStorage {
        guard let adapter else {
            invalidate()
            return VZPendingElementStorage(element: self, lifecycle: pendingLifecycle)
        }
        adapter.assertOnDeviceQueue()
        precondition(!isCompleted && !isInvalidated && element != nil)
        adapter.retainPending(self)
        return VZPendingElementStorage(element: self, lifecycle: pendingLifecycle)
    }

    func completeDeferred() {
        guard let adapter else { return }
        adapter.completePendingDeferred(self)
    }

    func invalidate() {
        pendingLifecycle.invalidate()
        isInvalidated = true
        element = nil
    }

    fileprivate func returnToGuest() {
        guard !isCompleted, !isInvalidated, let element else {
            preconditionFailure("A VZ virtio element was completed more than once.")
        }
        isCompleted = true
        element.returnToQueue()
        self.element = nil
    }

    private var isLive: Bool {
        guard let adapter else { return false }
        adapter.assertOnDeviceQueue()
        return
            !isCompleted && !isInvalidated && element != nil
            && adapter.isCurrent(generation: generation)
    }

    private static func map(_ error: NSError) -> VirtioFailure {
        return .queueElementAccessFailed(domain: error.domain, code: error.code)
    }
}

package protocol VZPendingElementTarget: AnyObject, Sendable {
    func completeDeferred()
}

// UNCHECKED-SENDABLE: this lock linearizes pending-handle abandonment against device-queue invalidation.
package final class VZPendingElementLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let epoch: VZDeviceEpoch?
    private let generation: UInt64
    private var isInvalidated = false

    package init() {
        epoch = nil
        generation = 0
    }

    package init(epoch: VZDeviceEpoch, generation: UInt64) {
        self.epoch = epoch
        self.generation = generation
    }

    package func invalidate() {
        lock.withLock {
            isInvalidated = true
        }
    }

    package func abandonIfLive() -> Bool {
        lock.withLock {
            guard !isInvalidated, epoch?.isCurrent(generation) ?? true else {
                return false
            }
            return true
        }
    }
}

// UNCHECKED-SENDABLE: the weak target only schedules completion onto the element's device queue.
package final class VZPendingElementStorage: PendingElementStorage, @unchecked Sendable {
    private weak var element: (any VZPendingElementTarget)?
    private let lifecycle: VZPendingElementLifecycle

    package init(
        element: any VZPendingElementTarget,
        lifecycle: VZPendingElementLifecycle = VZPendingElementLifecycle()
    ) {
        self.element = element
        self.lifecycle = lifecycle
    }

    package func complete() {
        element?.completeDeferred()
    }

    package func abandon() -> Bool {
        guard lifecycle.abandonIfLive() else { return false }
        element?.completeDeferred()
        return true
    }
}

private final class VZGuestMemoryStorage: GuestMemoryStorage {
    private var mapping: VZGuestMemoryMapping?
    weak var adapter: VZCustomVirtioDeviceAdapter?
    var generation: UInt64 = 0

    init(mapping: VZGuestMemoryMapping) {
        self.mapping = mapping
    }

    var byteCount: Int {
        guard let adapter, adapter.isOnDeviceQueue,
            adapter.isCurrent(generation: generation)
        else {
            return 0
        }
        return mapping.map { Int($0.length) } ?? 0
    }

    func validate() throws(VirtioFailure) {
        guard let adapter, adapter.isOnDeviceQueue,
            adapter.isCurrent(generation: generation),
            mapping != nil
        else {
            throw .guestMemoryInvalidated
        }
    }

    func copyBytes(in range: Range<Int>) throws(VirtioFailure) -> [UInt8] {
        try validate()
        guard let mapping else { throw .guestMemoryInvalidated }
        let pointer = mapping.mutableBytes.advanced(by: range.lowerBound)
            .assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: range.count))
    }

    func writeBytes(_ bytes: [UInt8], at offset: Int) throws(VirtioFailure) {
        try validate()
        guard let mapping else { throw .guestMemoryInvalidated }
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { source in
            guard let sourceBaseAddress = source.baseAddress else {
                preconditionFailure("A nonempty guest memory write has no base address.")
            }
            mapping.mutableBytes.advanced(by: offset)
                .copyMemory(from: sourceBaseAddress, byteCount: source.count)
        }
    }

    func invalidate() {
        mapping = nil
    }
}
