import Foundation
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

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
        case unref(UInt32)
        case transferWrite(VirGLTransfer, [UInt8])
        case transferRead(VirGLTransfer)
        case fence(UInt32, context: UInt32)
        case poll
        case reset
        case destroy
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
        let fake = lock.withLock { () -> FakeGuestMemory in
            let bytes = seeds[range.address] ?? [UInt8](repeating: 0, count: Int(range.length))
            let fake = FakeGuestMemory(range: range, bytes: bytes)
            views[range.address] = fake
            return fake
        }
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
