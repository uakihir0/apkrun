import Foundation
import IOSurface
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

/// A present target of the fake engine.
final class FakePresentTarget: PresentTarget, @unchecked Sendable {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

/// A present fence of the fake engine. It signals on `complete()`, or at once when created signaled.
final class FakePresentFence: PresentFence, @unchecked Sendable {
    private let condition = NSCondition()
    private var isSignaled: Bool

    init(signaled: Bool) {
        isSignaled = signaled
    }

    func complete() {
        condition.lock()
        isSignaled = true
        condition.broadcast()
        condition.unlock()
    }

    func poll() -> PresentWaitOutcome {
        condition.lock()
        defer { condition.unlock() }
        return isSignaled ? .signaled : .timedOut
    }

    func release() {}
}

/// A renderer that records each call and completes fences only when the test releases them.
///
/// The engine runs on the render thread, so its calls are recorded under a lock. Tests read
/// the record from their own thread.
final class FakeVirGLEngine: VirGLEngine, @unchecked Sendable {
    enum Call: Equatable {
        case capset(UInt32)
        case createContext(UInt32, String)
        case destroyContext(UInt32)
        case attach(context: UInt32, resource: UInt32)
        case detach(context: UInt32, resource: UInt32)
        case submit(context: UInt32, bytes: [UInt8])
        case createResource(VirGLResourceArguments)
        case attachBacking(resource: UInt32, ranges: [VirGLBackingRange])
        case detachBacking(resource: UInt32)
        case unref(UInt32)
        case transferWrite(VirGLTransfer, [UInt8])
        case transferRead(VirGLTransfer)
        case fence(UInt32, context: UInt32)
        case poll
        case reset
        case destroy
        case presentTargetCreate(width: UInt32, height: UInt32)
        case presentTargetDestroy(target: Int)
        case presentBlit(resource: UInt32, source: VirtioGPURect, target: Int)
    }

    private let lock = NSLock()
    private let onFence: @Sendable (UInt32) -> Void
    private var recorded: [Call] = []
    private var pendingFences: [UInt32] = []
    private var failing: Set<String> = []
    /// The byte that `transferRead` writes into every byte of the box.
    private var readFill: UInt8 = 0x5A

    init(onFence: @escaping @Sendable (UInt32) -> Void) {
        self.onFence = onFence
    }

    /// The calls so far, in order.
    var calls: [Call] {
        lock.withLock { recorded }
    }

    /// Makes the named operation fail with a renderer error. Operations are named by the case, for example `submit`.
    func fail(_ operation: String) {
        lock.withLock { _ = failing.insert(operation) }
    }

    /// Sets the byte that a readback writes.
    func setReadFill(_ value: UInt8) {
        lock.withLock { readFill = value }
    }

    /// Completes every fence created so far, as virglrenderer does once the GPU has finished.
    func releaseFences() {
        let fences = lock.withLock { () -> [UInt32] in
            let fences = pendingFences
            pendingFences.removeAll()
            return fences
        }
        for fence in fences {
            onFence(fence)
        }
    }

    private func record(_ call: Call, operation: String) throws(GraphicsFailure) {
        let shouldFail = lock.withLock { () -> Bool in
            recorded.append(call)
            return failing.contains(operation)
        }
        if shouldFail {
            throw GraphicsFailure.rendererOperationFailed(operation: operation, detail: "injected failure")
        }
    }

    /// Whether the fences of `presentBlit` signal at once. A test that holds them clears it and calls `completePresentFences`.
    var autoCompletePresentFences = true
    private var nextPresentTargetID = 1
    private var presentFences: [FakePresentFence] = []

    /// Signals every present fence created so far, as the GPU does once a blit has finished.
    func completePresentFences() {
        let fences = lock.withLock { presentFences }
        for fence in fences {
            fence.complete()
        }
    }

    func createPresentTarget(surface: IOSurface, width: UInt32, height: UInt32) throws(GraphicsFailure)
        -> any PresentTarget
    {
        try record(.presentTargetCreate(width: width, height: height), operation: "presentTargetCreate")
        let id = lock.withLock { () -> Int in
            let id = nextPresentTargetID
            nextPresentTargetID += 1
            return id
        }
        return FakePresentTarget(id: id)
    }

    func destroyPresentTarget(_ target: any PresentTarget) {
        guard let target = target as? FakePresentTarget else { return }
        lock.withLock { recorded.append(.presentTargetDestroy(target: target.id)) }
    }

    func presentBlit(
        resource: UInt32,
        sourceRect: VirtioGPURect,
        into target: any PresentTarget
    ) throws(GraphicsFailure) -> any PresentFence {
        let id = (target as? FakePresentTarget)?.id ?? -1
        // The fence is registered before the call is recorded, so a test that sees the call can complete the fence.
        let fence = FakePresentFence(signaled: autoCompletePresentFences)
        lock.withLock { presentFences.append(fence) }
        try record(.presentBlit(resource: resource, source: sourceRect, target: id), operation: "presentBlit")
        return fence
    }

    func capsetInfo(id: UInt32) throws(GraphicsFailure) -> GraphicsCapsetInfo {
        try record(.capset(id), operation: "capsetInfo")
        switch id {
        case GraphicsCapset.virgl:
            return GraphicsCapsetInfo(maxVersion: 1, maxSizeBytes: 4)
        case GraphicsCapset.virgl2:
            return GraphicsCapsetInfo(maxVersion: 2, maxSizeBytes: 8)
        default:
            throw GraphicsFailure.rendererOperationFailed(operation: "capsetInfo", detail: "unknown capset")
        }
    }

    func fillCapset(id: UInt32, version: UInt32, into buffer: inout [UInt8]) throws(GraphicsFailure) {
        try record(.capset(id), operation: "capsetFill")
        for index in buffer.indices {
            buffer[index] = UInt8(truncatingIfNeeded: Int(id) * 16 + Int(version) + index)
        }
    }

    func createContext(id: UInt32, name: String) throws(GraphicsFailure) {
        try record(.createContext(id, name), operation: "contextCreate")
    }

    func destroyContext(id: UInt32) throws(GraphicsFailure) {
        try record(.destroyContext(id), operation: "contextDestroy")
    }

    func attachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure) {
        try record(.attach(context: context, resource: resource), operation: "contextAttachResource")
    }

    func detachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure) {
        try record(.detach(context: context, resource: resource), operation: "contextDetachResource")
    }

    func submit(context: UInt32, commands: [UInt8]) throws(GraphicsFailure) {
        try record(.submit(context: context, bytes: commands), operation: "submit")
    }

    func createResource(_ arguments: VirGLResourceArguments) throws(GraphicsFailure) {
        try record(.createResource(arguments), operation: "resourceCreate")
    }

    func unrefResource(id: UInt32) {
        lock.withLock { recorded.append(.unref(id)) }
    }

    func attachBacking(resource: UInt32, ranges: [VirGLBackingRange]) throws(GraphicsFailure) {
        try record(.attachBacking(resource: resource, ranges: ranges), operation: "resourceAttachBacking")
    }

    func detachBacking(resource: UInt32) {
        lock.withLock { recorded.append(.detachBacking(resource: resource)) }
    }

    func transferWrite(_ transfer: VirGLTransfer, data: inout [UInt8]) throws(GraphicsFailure) {
        try record(.transferWrite(transfer, data), operation: "transferWrite")
    }

    func transferRead(_ transfer: VirGLTransfer, into data: inout [UInt8]) throws(GraphicsFailure) {
        try record(.transferRead(transfer), operation: "transferRead")
        let fill = lock.withLock { readFill }
        for index in data.indices {
            data[index] = fill
        }
    }

    func createFence(id: UInt32, context: UInt32) throws(GraphicsFailure) {
        try record(.fence(id, context: context), operation: "fenceCreate")
        lock.withLock { pendingFences.append(id) }
    }

    func poll() {
        lock.withLock { recorded.append(.poll) }
    }

    func reset() throws(GraphicsFailure) {
        try record(.reset, operation: "reset")
    }

    func destroy() throws(GraphicsFailure) {
        try record(.destroy, operation: "destroy")
    }
}

/// A device context whose guest memory is seeded by address. It is reachable only from tests.
final class SeededGuestBackend: VirtioDeviceContextBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var seeds: [UInt64: [UInt8]] = [:]
    private var unmappedAddresses: Set<UInt64> = []
    private var views: [UInt64: FakeGuestMemory] = [:]
    private var queues: [FakeVirtioQueue]

    init(queues: [FakeVirtioQueue]) {
        self.queues = queues
    }

    /// Replaces the queues that the device drains, so one device can serve several batches.
    func replaceQueues(_ replacement: [FakeVirtioQueue]) {
        lock.withLock { queues = replacement }
    }

    /// Sets the bytes that the range starting at `address` holds when the device maps it.
    func seed(address: UInt64, bytes: [UInt8]) {
        lock.withLock { seeds[address] = bytes }
    }

    /// Makes mapping the range at `address` fail as if it were outside guest memory.
    func failMapping(address: UInt64) {
        lock.withLock { unmappedAddresses.insert(address) }
    }

    /// The view of the range at `address`, as the device mapped it.
    func memory(at address: UInt64) -> GuestMemory? {
        lock.withLock { views[address]?.memory }
    }

    func queue(_ index: Int, generation: UInt64) throws(VirtioFailure) -> any VirtioQueue {
        let queues = lock.withLock { self.queues }
        guard queues.indices.contains(index) else { throw .queueIndexInvalid(index) }
        return queues[index]
    }

    func negotiatedFeatures(generation: UInt64) throws(VirtioFailure) -> UInt64 {
        0
    }

    func mapGuestMemory(
        _ range: GuestPhysicalRange,
        generation: UInt64
    ) throws(VirtioFailure) -> GuestMemory {
        _ = try range.validatedEndAddress()
        let (isUnmapped, bytes) = lock.withLock {
            (
                unmappedAddresses.contains(range.address),
                seeds[range.address] ?? [UInt8](repeating: 0, count: Int(range.length))
            )
        }
        guard !isUnmapped else { throw .guestMemoryRangeInvalid }
        let fake = FakeGuestMemory(range: range, bytes: bytes)
        lock.withLock { views[range.address] = fake }
        return fake.memory
    }

    func updateConfigurationSpace(_ bytes: Data, generation: UInt64) async throws(VirtioFailure) {}

    func requestReset(reason: String, generation: UInt64) {}
}

/// Builds a control request, with the header that the Linux driver sends.
func gpuRequest(
    _ command: VirtioGPUCommand,
    body: VirtioGPURequestBody,
    fence: UInt64? = nil,
    contextID: UInt32 = 0
) -> [UInt8] {
    let header = VirtioGPUControlHeader(
        type: command.rawValue,
        flags: fence == nil ? 0 : VirtioGPUProtocol.Flag.fence,
        fenceID: fence ?? 0,
        contextID: contextID
    )
    return VirtioGPUProtocol.encodeRequest(VirtioGPURequest(header: header, body: body))
}

/// The response type code in the first four bytes of a response.
func gpuResponseType(_ bytes: [UInt8]?) -> UInt32? {
    guard let bytes, bytes.count >= 4 else { return nil }
    return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
}

/// Builds a box with the given origin and extent.
func gpuBox(x: UInt32 = 0, y: UInt32 = 0, z: UInt32 = 0, width: UInt32, height: UInt32, depth: UInt32 = 1)
    -> VirtioGPUBox
{
    VirtioGPUBox(x: x, y: y, z: z, width: width, height: height, depth: depth)
}
