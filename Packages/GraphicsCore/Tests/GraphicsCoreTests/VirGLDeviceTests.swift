import Foundation
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

/// Holds the engine that the device's render thread created, for the test to inspect.
private final class EngineRef: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FakeVirGLEngine?

    func set(_ engine: FakeVirGLEngine) {
        lock.withLock { stored = engine }
    }

    var engine: FakeVirGLEngine {
        lock.withLock { stored! }
    }
}

/// A `drmVirgl` device whose renderer is a fake. The test reads the engine through `engine`.
private struct VirGLHarness {
    let device: VirtioGPUDevice
    let engineRef: EngineRef
    let guest: SeededGuestBackend
    let context: VirtioDeviceContext

    init() throws {
        let ref = EngineRef()
        device = try VirtioGPUDevice.makeVirgl { onFence throws(GraphicsFailure) -> any VirGLEngine in
            let engine = FakeVirGLEngine(onFence: onFence)
            ref.set(engine)
            return engine
        }
        engineRef = ref
        guest = SeededGuestBackend(queues: [FakeVirtioQueue(elements: []), FakeVirtioQueue(elements: [])])
        context = VirtioDeviceContext(backend: guest, generation: 0)
    }

    /// Delivers `requests` to the control queue, in one drain, with `writable` bytes for each response.
    func send(_ requests: [[UInt8]], writable: Int = 4096) -> FakeVirtioQueue {
        let control = FakeVirtioQueue(
            elements: requests.map { (readable: $0, writableByteCount: writable) }
        )
        guest.replaceQueues([control, FakeVirtioQueue(elements: [])])
        device.queueNotified(index: 0, context: context)
        return control
    }
}

private func body(_ bytes: [UInt8]?) throws -> VirtioGPUResponseBody {
    try VirtioGPUProtocol.decodeResponse(try #require(bytes)).body
}

private func resource3D(
    id: UInt32,
    target: UInt32 = 2,
    format: UInt32 = 1,
    width: UInt32 = 4,
    height: UInt32 = 4
) -> VirtioGPUResourceCreate3D {
    VirtioGPUResourceCreate3D(
        resourceID: id,
        target: target,
        format: format,
        bind: 2,
        width: width,
        height: height,
        depth: 1,
        arraySize: 1,
        lastLevel: 0,
        sampleCount: 0,
        flags: 0
    )
}

private func transfer(
    resource: UInt32,
    box: VirtioGPUBox,
    offset: UInt64 = 0
) -> VirtioGPUTransfer3D {
    VirtioGPUTransfer3D(box: box, offset: offset, resourceID: resource, level: 0, stride: 0, layerStride: 0)
}

@Test func theVirGLDeviceOffersVirGLAndTwoCapsets() async throws {
    let harness = try VirGLHarness()
    #expect(harness.device.hostCapabilities == ["edid", "virgl"])
    let configuration = Array(harness.device.descriptor.configurationSpace)
    #expect(configuration[12..<16] == [2, 0, 0, 0])
    let control = harness.send([
        gpuRequest(.getCapsetInfo, body: .getCapsetInfo(index: 0)),
        gpuRequest(.getCapsetInfo, body: .getCapsetInfo(index: 1)),
        gpuRequest(.getCapset, body: .getCapset(id: GraphicsCapset.virgl2, version: 2)),
    ])
    try await eventually { control.completionCounts == [1, 1, 1] }
    #expect(try body(control.writtenBuffers[0]) == .okCapsetInfo(id: GraphicsCapset.virgl, maxVersion: 1, maxSize: 4))
    #expect(try body(control.writtenBuffers[1]) == .okCapsetInfo(id: GraphicsCapset.virgl2, maxVersion: 2, maxSize: 8))
    #expect(
        try body(control.writtenBuffers[2])
            == .okCapset(data: (0..<8).map { UInt8(truncatingIfNeeded: 2 * 16 + 2 + $0) }))
}

@Test func contextsAndSubmissionsReachTheEngineInOrder() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: Array("gl".utf8)), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0, 2, 0, 0, 0]), contextID: 1),
        gpuRequest(.ctxDestroy, body: .ctxDestroy, contextID: 1),
    ])
    try await eventually { control.completionCounts == [1, 1, 1] }
    #expect(
        harness.engineRef.engine.calls.filter { call in
            switch call {
            case .capset, .poll: return false
            default: return true
            }
        } == [
            .createContext(1, "gl"),
            .submit(context: 1, bytes: [1, 0, 0, 0, 2, 0, 0, 0]),
            .destroyContext(1),
        ]
    )
    for buffer in control.writtenBuffers {
        #expect(gpuResponseType(buffer) == VirtioGPUResponseType.okNoData.rawValue)
    }
}

@Test func aSubmitToAnUnknownContextIsAnInvalidContextError() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), contextID: 9)
    ])
    try await eventually { control.completionCounts == [1] }
    #expect(gpuResponseType(control.writtenBuffers[0]) == VirtioGPUErrorCode.invalidContextID.rawValue)
    #expect(
        !harness.engineRef.engine.calls.contains { call in
            if case .submit = call { return true }
            return false
        })
}

@Test func aSubmitThatIsNotWholeWordsIsInvalid() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0, 2, 0]), contextID: 1),
    ])
    try await eventually { control.completionCounts == [1, 1] }
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUErrorCode.invalidParameter.rawValue)
}

@Test func uploadsGatherTheGuestBoxAndCountTheBytes() async throws {
    let harness = try VirGLHarness()
    let pixels = (0..<64).map { UInt8($0) }
    harness.guest.seed(address: 0x1000, bytes: pixels)
    let control = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
        ),
        gpuRequest(
            .transferToHost3D,
            body: .transferToHost3D(transfer(resource: 5, box: gpuBox(width: 4, height: 4)))
        ),
    ])
    try await eventually { control.completionCounts == [1, 1, 1] }
    let uploads = harness.engineRef.engine.calls.compactMap { call -> (VirGLTransfer, [UInt8])? in
        if case .transferWrite(let transfer, let data) = call { return (transfer, data) }
        return nil
    }
    let upload = try #require(uploads.first)
    #expect(upload.0.resourceID == 5)
    #expect(upload.0.stride == 16)
    #expect(upload.1 == pixels)
    #expect(harness.device.statistics.guestUploadBytes == 64)
    #expect(harness.device.statistics.hostReadbacks == 0)
}

@Test func aReadbackWritesOnlyTheBoxIntoGuestMemory() async throws {
    let harness = try VirGLHarness()
    harness.guest.seed(address: 0x1000, bytes: [UInt8](repeating: 0xAA, count: 64))
    harness.engineRef.engine.setReadFill(0x5A)
    let control = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
        ),
        gpuRequest(
            .transferFromHost3D,
            body: .transferFromHost3D(transfer(resource: 5, box: gpuBox(x: 1, y: 1, width: 2, height: 2)))
        ),
    ])
    try await eventually { control.completionCounts == [1, 1, 1] }
    #expect(gpuResponseType(control.writtenBuffers[2]) == VirtioGPUResponseType.okNoData.rawValue)
    let guest = try #require(harness.guest.memory(at: 0x1000))
    let after = try guest.copyBytes(at: 0, count: 64)
    for index in after.indices {
        let inBox = (20..<28).contains(index) || (36..<44).contains(index)
        #expect(after[index] == (inBox ? 0x5A : 0xAA), "byte \(index)")
    }
    let statistics = harness.device.statistics
    #expect(statistics.guestReadbacks == 1)
    #expect(statistics.guestReadbackBytes == 16)
    #expect(statistics.hostReadbacks == 0)
}

@Test func aFencedResponseWaitsForItsFence() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), fence: 7, contextID: 1),
    ])
    try await eventually { harness.engineRef.engine.calls.contains(.fence(7, context: 1)) }
    #expect(control.completionCounts == [1, 0])
    harness.engineRef.engine.releaseFences()
    try await eventually { control.completionCounts == [1, 1] }
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUResponseType.okNoData.rawValue)
}

@Test func aResponseBehindAFencedOneWaitsItsTurn() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), fence: 9, contextID: 1),
        gpuRequest(.getDisplayInfo, body: .getDisplayInfo),
    ])
    try await eventually { control.completionCounts == [1, 0, 0] }
    harness.engineRef.engine.releaseFences()
    try await eventually { control.completionCounts == [1, 1, 1] }
}

@Test func aRendererFailureIsCountedAndTheGuestStillGetsSuccess() async throws {
    let harness = try VirGLHarness()
    harness.engineRef.engine.fail("submit")
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), contextID: 1),
    ])
    try await eventually { control.completionCounts == [1, 1] }
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUResponseType.okNoData.rawValue)
    try await eventually { harness.device.statistics.rendererFailures == 1 }
}

@Test func aFenceBeyondThirtyTwoBitsIsAnInvalidParameter() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), fence: 1 << 40, contextID: 1),
    ])
    try await eventually { control.completionCounts == [1, 1] }
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUErrorCode.invalidParameter.rawValue)
    #expect(
        !harness.engineRef.engine.calls.contains { call in
            if case .submit = call { return true }
            return false
        })
}

@Test func theContextLimitAnswersWithUnspec() async throws {
    let harness = try VirGLHarness()
    let requests = (1...257).map { id in
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: UInt32(id))
    }
    let control = harness.send(requests)
    try await eventually { control.completionCounts.count == 257 && control.completionCounts.allSatisfy { $0 == 1 } }
    #expect(gpuResponseType(control.writtenBuffers[255]) == VirtioGPUResponseType.okNoData.rawValue)
    #expect(gpuResponseType(control.writtenBuffers[256]) == VirtioGPUErrorCode.unspec.rawValue)
}

@Test func aResetResetsTheRendererAndForgetsTheResources() async throws {
    let harness = try VirGLHarness()
    let first = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5)))
    ])
    try await eventually { first.completionCounts == [1] }
    harness.device.deviceWillReset()
    #expect(harness.engineRef.engine.calls.contains(.reset))
    harness.guest.seed(address: 0x1000, bytes: [0, 0, 0, 0])
    let second = harness.send([
        gpuRequest(
            .transferToHost3D,
            body: .transferToHost3D(transfer(resource: 5, box: gpuBox(width: 1, height: 1)))
        ),
        gpuRequest(.resourceUnref, body: .resourceUnref(resourceID: 5)),
    ])
    try await eventually { second.completionCounts == [1, 1] }
    #expect(gpuResponseType(second.writtenBuffers[0]) == VirtioGPUErrorCode.invalidResourceID.rawValue)
}

@Test func aTwoDimensionalDeviceCopiesTheRectangleAndRejects3D() async throws {
    let guest = SeededGuestBackend(queues: [FakeVirtioQueue(elements: []), FakeVirtioQueue(elements: [])])
    let context = VirtioDeviceContext(backend: guest, generation: 0)
    let device = VirtioGPUDevice.twoDimensional()
    #expect(device.hostCapabilities == ["edid"])
    guest.seed(address: 0x1000, bytes: (0..<64).map { UInt8($0) })
    let control = FakeVirtioQueue(elements: [
        (
            readable: gpuRequest(
                .resourceCreate2D, body: .resourceCreate2D(resourceID: 3, format: 1, width: 4, height: 4)),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .resourceAttachBacking,
                body: .resourceAttachBacking(
                    resourceID: 3, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
            ),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .transferToHost2D,
                body: .transferToHost2D(rect: VirtioGPURect(x: 1, y: 1, width: 2, height: 2), offset: 0, resourceID: 3)
            ),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .setScanout,
                body: .setScanout(rect: VirtioGPURect(x: 0, y: 0, width: 4, height: 4), scanoutID: 0, resourceID: 3)
            ),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .resourceFlush,
                body: .resourceFlush(rect: VirtioGPURect(x: 0, y: 0, width: 4, height: 4), resourceID: 3)
            ),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
            writableByteCount: 4096
        ),
        (readable: gpuRequest(.getCapsetInfo, body: .getCapsetInfo(index: 0)), writableByteCount: 4096),
    ])
    guest.replaceQueues([control, FakeVirtioQueue(elements: [])])
    device.queueNotified(index: 0, context: context)
    #expect(control.completionCounts == [1, 1, 1, 1, 1, 1, 1])
    for index in 0..<5 {
        #expect(gpuResponseType(control.writtenBuffers[index]) == VirtioGPUResponseType.okNoData.rawValue, "\(index)")
    }
    #expect(gpuResponseType(control.writtenBuffers[5]) == VirtioGPUErrorCode.unspec.rawValue)
    #expect(gpuResponseType(control.writtenBuffers[6]) == VirtioGPUErrorCode.unspec.rawValue)
    let statistics = device.statistics
    #expect(statistics.cpuPixelCopies == 1)
    #expect(statistics.cpuPixelCopyBytes == 16)
    // The rectangle's last row ends at byte 12 of its row: 2 rows of 16 bytes, plus 12.
    #expect(statistics.guestUploadBytes == 44)
}

@Test func aSetScanoutOutsideTheResourceIsInvalid() async throws {
    let guest = SeededGuestBackend(queues: [FakeVirtioQueue(elements: []), FakeVirtioQueue(elements: [])])
    let context = VirtioDeviceContext(backend: guest, generation: 0)
    let device = VirtioGPUDevice.twoDimensional()
    let control = FakeVirtioQueue(elements: [
        (
            readable: gpuRequest(
                .resourceCreate2D, body: .resourceCreate2D(resourceID: 3, format: 1, width: 4, height: 4)),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .setScanout,
                body: .setScanout(rect: VirtioGPURect(x: 2, y: 0, width: 4, height: 4), scanoutID: 0, resourceID: 3)
            ),
            writableByteCount: 4096
        ),
    ])
    guest.replaceQueues([control, FakeVirtioQueue(elements: [])])
    device.queueNotified(index: 0, context: context)
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUErrorCode.invalidParameter.rawValue)
}

@Test func aRecordedSessionReplaysToTheSameEngineCalls() async throws {
    let recorder = VirGLRecorder()
    let ref = EngineRef()
    let device = try VirtioGPUDevice.makeVirgl(recorder: recorder) {
        onFence throws(GraphicsFailure) -> any VirGLEngine in
        let engine = FakeVirGLEngine(onFence: onFence)
        ref.set(engine)
        return engine
    }
    let guest = SeededGuestBackend(queues: [FakeVirtioQueue(elements: []), FakeVirtioQueue(elements: [])])
    let context = VirtioDeviceContext(backend: guest, generation: 0)
    guest.seed(address: 0x1000, bytes: (0..<64).map { UInt8($0) })
    let control = FakeVirtioQueue(elements: [
        (
            readable: gpuRequest(
                .ctxCreate, body: .ctxCreate(contextInit: 0, debugName: Array("rec".utf8)), contextID: 1),
            writableByteCount: 4096
        ),
        (readable: gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))), writableByteCount: 4096),
        (
            readable: gpuRequest(
                .resourceAttachBacking,
                body: .resourceAttachBacking(
                    resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
            ),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .transferToHost3D, body: .transferToHost3D(transfer(resource: 5, box: gpuBox(width: 4, height: 4)))),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), fence: 3, contextID: 1),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .transferFromHost3D, body: .transferFromHost3D(transfer(resource: 5, box: gpuBox(width: 4, height: 4)))),
            writableByteCount: 4096
        ),
    ])
    guest.replaceQueues([control, FakeVirtioQueue(elements: [])])
    device.queueNotified(index: 0, context: context)
    try await eventually { ref.engine.calls.contains(.fence(3, context: 1)) }
    ref.engine.releaseFences()
    try await eventually { control.completionCounts.allSatisfy { $0 == 1 } }

    let recording = recorder.recording
    let decoded = try VirGLRecording.decoded(from: try recording.encoded())
    #expect(decoded == recording)
    #expect(decoded.operations.count == 6)

    let replayed = FakeVirGLEngine(onFence: { _ in })
    #expect(replay(decoded, onto: replayed) == nil)
    let recordedCalls = ref.engine.calls.filter { call in
        switch call {
        case .capset, .poll: return false
        default: return true
        }
    }
    #expect(replayed.calls == recordedCalls)
}

@Test func aRecordingFromAnotherVersionIsRejected() throws {
    var recording = VirGLRecording(operations: [.reset])
    recording.version = 2
    let data = try recording.encoded()
    #expect(throws: VirGLRecordingFailure.unsupportedVersion(2)) {
        _ = try VirGLRecording.decoded(from: data)
    }
}
