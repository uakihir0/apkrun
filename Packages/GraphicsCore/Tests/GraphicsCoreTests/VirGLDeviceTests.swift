import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import GraphicsBridge
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

    init(
        recorder: VirGLRecorder? = nil,
        logger: APKLogger = APKLogger(category: GraphicsLogCategory.device)
    ) throws {
        let ref = EngineRef()
        device = try VirtioGPUDevice.makeVirgl(logger: logger, recorder: recorder) {
            onFence throws(GraphicsFailure) -> any VirGLEngine in
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

/// Mesa 25.2.7 requests capset 2 with version 0, and the kernel forwards the userspace version.
/// The device answers every version up to the cached maximum and refuses a higher one.
@Test func getCapsetAnswersEveryVersionUpToTheCachedMaximum() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.getCapset, body: .getCapset(id: GraphicsCapset.virgl2, version: 2)),
        gpuRequest(.getCapset, body: .getCapset(id: GraphicsCapset.virgl2, version: 0)),
        gpuRequest(.getCapset, body: .getCapset(id: GraphicsCapset.virgl2, version: 1)),
        gpuRequest(.getCapset, body: .getCapset(id: GraphicsCapset.virgl2, version: 3)),
        gpuRequest(.getCapset, body: .getCapset(id: GraphicsCapset.virgl, version: 0)),
        gpuRequest(.getCapset, body: .getCapset(id: GraphicsCapset.virgl, version: 1)),
    ])
    try await eventually { control.completionCounts == [1, 1, 1, 1, 1, 1] }
    let capset2 = VirtioGPUResponseBody.okCapset(data: (0..<8).map { UInt8(truncatingIfNeeded: 2 * 16 + 2 + $0) })
    #expect(try body(control.writtenBuffers[0]) == capset2)
    #expect(try body(control.writtenBuffers[1]) == capset2)
    #expect(try body(control.writtenBuffers[2]) == capset2)
    #expect(try body(control.writtenBuffers[3]) == .error(.invalidParameter))
    #expect(try body(control.writtenBuffers[4]) == body(control.writtenBuffers[5]))
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

/// The backing calls that reach the engine, as "attach 5", "detach 5", or "unref 5", in order.
private func backingCalls(_ engine: FakeVirGLEngine) -> [String] {
    engine.calls.compactMap { call -> String? in
        switch call {
        case .attachBacking(let resource, _): "attach \(resource)"
        case .detachBacking(let resource): "detach \(resource)"
        case .unref(let resource): "unref \(resource)"
        default: nil
        }
    }
}

@Test func attachBackingHandsTheGuestPagesToTheRendererWithoutCopying() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(
                resourceID: 5,
                entries: [
                    VirtioGPUMemoryEntry(address: 0x1000, length: 64),
                    VirtioGPUMemoryEntry(address: 0x2000, length: 32),
                ]
            )
        ),
    ])
    try await eventually { control.completionCounts == [1, 1] }
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUResponseType.okNoData.rawValue)

    let attached = harness.engineRef.engine.calls.compactMap { call -> [VirGLBackingRange]? in
        if case .attachBacking(5, let ranges) = call { return ranges }
        return nil
    }
    let ranges = try #require(attached.first)
    #expect(ranges.map(\.count) == [64, 32])
    // The renderer receives the host memory of each guest view, so it reads and writes the guest's own bytes.
    let first = try #require(harness.guest.memory(at: 0x1000))
    let second = try #require(harness.guest.memory(at: 0x2000))
    #expect(ranges[0].base == (try first.hostMemory().baseAddress))
    #expect(ranges[1].base == (try second.hostMemory().baseAddress))
}

@Test func rejectedBackingLogsItsResourceIDWithoutGuestMemoryDetails() async throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: GraphicsLogCategory.device, sink: sink)
    let harness = try VirGLHarness(logger: logger)
    let control = harness.send([
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(
                resourceID: 128,
                entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)]
            )
        )
    ])
    try await eventually { control.completionCounts == [1] }

    #expect(try body(control.writtenBuffers[0]) == .error(.invalidResourceID))
    let entry = try #require(sink.entries.first { $0.level == .warning })
    #expect(
        entry.publicMessage
            .contains("control_ordinal=1 command=262 context_id=0 resource_id=128 response_error=4611")
    )
    #expect(entry.publicMessage.contains("4096") == false)
}

@Test func backingIsReleasedOnDetachAndUnrefOnlyWhenTheResourceHadIt() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 6))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
        ),
        gpuRequest(.resourceDetachBacking, body: .resourceDetachBacking(resourceID: 5)),
        // The second detach finds no backing, so the renderer is not called.
        gpuRequest(.resourceDetachBacking, body: .resourceDetachBacking(resourceID: 5)),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 6, entries: [VirtioGPUMemoryEntry(address: 0x2000, length: 64)])
        ),
        gpuRequest(.resourceUnref, body: .resourceUnref(resourceID: 6)),
        gpuRequest(.resourceUnref, body: .resourceUnref(resourceID: 5)),
    ])
    try await eventually { control.completionCounts == [1, 1, 1, 1, 1, 1, 1, 1] }
    for index in control.writtenBuffers.indices {
        #expect(gpuResponseType(control.writtenBuffers[index]) == VirtioGPUResponseType.okNoData.rawValue, "\(index)")
    }
    // Unref releases the backing before the resource goes. A resource without backing only goes.
    #expect(
        backingCalls(harness.engineRef.engine)
            == ["attach 5", "detach 5", "attach 6", "detach 6", "unref 6", "unref 5"]
    )
}

@Test func resetLeavesTheRendererBackingToTheRendererWithoutDetaching() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
        ),
    ])
    try await eventually { control.completionCounts == [1, 1] }

    // A reset runs after the guest pages may be invalid, so it must not write through them (IR-843).
    harness.device.deviceWillReset()
    #expect(backingCalls(harness.engineRef.engine) == ["attach 5"])
    #expect(harness.engineRef.engine.calls.last == .reset)
}

@Test func aRendererFailureOnAttachLeavesTheGuestResponseUnchanged() async throws {
    let harness = try VirGLHarness()
    harness.engineRef.engine.fail("resourceAttachBacking")
    let control = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
        ),
    ])
    try await eventually { control.completionCounts == [1, 1] }
    // As for every renderer failure, the guest is answered as before, and the failure is counted (IR-460).
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUResponseType.okNoData.rawValue)
    try await eventually { harness.device.statistics.rendererFailures == 1 }
}

@Test func theInvalidationDrainRunsTheRendererWorkQueuedBeforeIt() throws {
    let harness = try VirGLHarness()
    harness.guest.seed(address: 0x1000, bytes: [UInt8](repeating: 0, count: 64))
    _ = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
        ),
    ])
    // The attach is queued on the render thread, which may read the pages through it. The drain returns only after
    // the renderer has run the attach, so no renderer work can read the pages once the guest memory is invalidated
    // (IR-850).
    harness.device.deviceWillInvalidateGuestMemory()
    #expect(backingCalls(harness.engineRef.engine) == ["attach 5"])
}

@Test func pauseDrainsTheRendererWorkQueuedBeforeIt() throws {
    let harness = try VirGLHarness()
    harness.guest.seed(address: 0x1000, bytes: [UInt8](repeating: 0, count: 64))
    _ = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(resourceID: 5, entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)])
        ),
    ])
    // The VZ adapter calls this on the serialized device queue, so earlier queue notifications have already handed
    // their work to the renderer. Pausing waits for that work to finish before the guest is suspended.
    harness.device.deviceWillPause()
    #expect(backingCalls(harness.engineRef.engine) == ["attach 5"])
}

@Test func aReplaySuppliesZeroedBackingForEachCreatedResourceAndReleasesIt() throws {
    func resource(_ id: UInt32) -> VirGLResourceArguments {
        VirGLResourceArguments(
            resourceID: id,
            target: 2,
            format: 1,
            bind: 2,
            width: 4,
            height: 4,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            sampleCount: 0,
            flags: 0
        )
    }
    let recording = VirGLRecording(operations: [
        .createResource(resource(4)),
        .createResource(resource(5)),
        .unrefResource(id: 5),
    ])

    let supplied = FakeVirGLEngine(onFence: { _ in })
    #expect(replay(recording, onto: supplied, suppliesBacking: true).failures.isEmpty)
    // Resource 5 is released before it goes, and resource 4 is released at the end of the replay.
    #expect(backingCalls(supplied) == ["attach 4", "attach 5", "detach 5", "unref 5", "detach 4"])
    let ranges = supplied.calls.compactMap { call -> [VirGLBackingRange]? in
        if case .attachBacking(4, let ranges) = call { return ranges }
        return nil
    }
    // A 4 × 4 texture of four-byte pixels, as the resource table counts it.
    #expect(ranges.first?.map(\.count) == [64])

    // Without the flag, the replay makes no backing calls, as before.
    let plain = FakeVirGLEngine(onFence: { _ in })
    #expect(replay(recording, onto: plain).failures.isEmpty)
    #expect(backingCalls(plain) == ["unref 5"])
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

@Test func commandOrdinalsCorrelateResourceRejectionsAndRendererFailures() async throws {
    let sink = RecordingLogSink()
    let harness = try VirGLHarness(logger: APKLogger(category: GraphicsLogCategory.device, sink: sink))
    harness.engineRef.engine.fail("resourceAttachBacking")
    harness.engineRef.engine.fail("submit")
    harness.guest.failMapping(address: 0x2000)

    let control = harness.send([
        gpuRequest(.resourceCreate3D, body: .resourceCreate3D(resource3D(id: 5))),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(
                resourceID: 5,
                entries: [VirtioGPUMemoryEntry(address: 0x1000, length: 64)]
            )
        ),
        gpuRequest(.resourceDetachBacking, body: .resourceDetachBacking(resourceID: 5)),
        gpuRequest(
            .resourceAttachBacking,
            body: .resourceAttachBacking(
                resourceID: 5,
                entries: [VirtioGPUMemoryEntry(address: 0x2000, length: 64)]
            )
        ),
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), contextID: 1),
    ])
    try await eventually { control.completionCounts == Array(repeating: 1, count: 6) }

    // A renderer failure still leaves the already-decided guest response unchanged (IR-460).
    #expect(gpuResponseType(control.writtenBuffers[1]) == VirtioGPUResponseType.okNoData.rawValue)
    #expect(gpuResponseType(control.writtenBuffers[3]) == VirtioGPUErrorCode.invalidParameter.rawValue)
    #expect(gpuResponseType(control.writtenBuffers[5]) == VirtioGPUResponseType.okNoData.rawValue)

    let messages = sink.entries.map(\.publicMessage)
    #expect(messages.contains { $0.contains("control_ordinal=1 command=516 context_id=0 resource_id=5") })
    #expect(messages.contains { $0.contains("control_ordinal=2 command=262 context_id=0 resource_id=5") })
    #expect(messages.contains { $0.contains("control_ordinal=3 command=263 context_id=0 resource_id=5") })
    #expect(messages.contains { $0.contains("control_ordinal=4 command=262 context_id=0 resource_id=5") })
    #expect(
        messages.contains {
            $0.contains("command was rejected")
                && $0.contains("control_ordinal=4 command=262 context_id=0 resource_id=5")
                && $0.contains("response_error=4613")
                && $0.contains("rejection_reason=guest_memory_mapping")
        })
    #expect(
        messages.contains {
            $0.contains("operation=resourceAttachBacking")
                && $0.contains("control_ordinal=2 command=262 context_id=0 resource_id=5")
        })
    #expect(messages.contains { $0.contains("control_ordinal=5 command=512 context_id=1") })
    #expect(
        messages.contains {
            $0.contains("operation=submit")
                && $0.contains("control_ordinal=6 command=519 context_id=1")
        })
    #expect(messages.allSatisfy { !$0.contains("0x1000") && !$0.contains("command bytes") })
}

@Test func rendererFailureLogIncludesOperationWithoutDynamicDetail() throws {
    let sink = RecordingLogSink()
    let failureLog = RendererFailureLog(
        logger: APKLogger(category: GraphicsLogCategory.device, sink: sink)
    )
    let dynamicDetail = "guest supplied command data"

    failureLog.record(
        .rendererOperationFailed(operation: "submit", detail: dynamicDetail)
    )

    let entry = try #require(sink.entries.first)
    #expect(entry.publicMessage == "virtio-gpu renderer operation failed: rendererOperationFailed operation=submit")
    #expect(entry.publicMessage.contains(dynamicDetail) == false)
    #expect(entry.errorCode == "graphics.rendererOperationFailed")
    #expect(failureLog.total == 1)
}

@Test func rendererFailureLogIncludesCommandOrdinalForSubmitFailures() throws {
    let sink = RecordingLogSink()
    let failureLog = RendererFailureLog(
        logger: APKLogger(category: GraphicsLogCategory.device, sink: sink)
    )

    failureLog.record(
        .rendererOperationFailed(operation: "submit", detail: "guest command bytes"),
        diagnostic: VirGLCommandDiagnostic(
            ordinal: 12,
            command: 0x0207,
            contextID: 17,
            resourceID: nil
        )
    )

    let entry = try #require(sink.entries.first)
    #expect(
        entry.publicMessage
            == "virtio-gpu renderer operation failed: rendererOperationFailed operation=submit control_ordinal=12 command=519 context_id=17 resource_id=unattributed"
    )
    #expect(entry.publicMessage.contains("guest command bytes") == false)
}

@Test func rendererCallbackCorrelationIsLoggedOnlyInsideItsCommandScope() throws {
    let sink = RecordingLogSink()
    let callbackContext = GraphicsRendererCallbackContext(
        onFenceCompleted: { _ in },
        logger: APKLogger(category: GraphicsLogCategory.renderer, sink: sink)
    )
    let diagnostic = VirGLCommandDiagnostic(
        ordinal: 12,
        command: 0x0207,
        contextID: 17,
        resourceID: 128
    )

    callbackContext.withCommandDiagnostic(diagnostic) {
        callbackContext.logCorrelation(for: Int32(GB_LOG_ERROR))
    }
    callbackContext.logCorrelation(for: Int32(GB_LOG_ERROR))

    let entry = try #require(sink.entries.first)
    #expect(entry.level == .error)
    #expect(
        entry.publicMessage
            == "VirGL renderer callback level=error control_ordinal=12 command=519 context_id=17 resource_id=128"
    )
    #expect(sink.entries.count == 1)
}

@Test func rendererCallbackCorrelationPreservesWarningSeverity() throws {
    let sink = RecordingLogSink()
    let callbackContext = GraphicsRendererCallbackContext(
        onFenceCompleted: { _ in },
        logger: APKLogger(category: GraphicsLogCategory.renderer, sink: sink)
    )

    callbackContext.withCommandDiagnostic(
        VirGLCommandDiagnostic(
            ordinal: 12,
            command: VirtioGPUCommand.submit3D.rawValue,
            contextID: 17,
            resourceID: nil
        )
    ) {
        callbackContext.logCorrelation(for: Int32(GB_LOG_WARNING))
    }

    let entry = try #require(sink.entries.first)
    #expect(entry.level == .warning)
    #expect(
        entry.publicMessage
            == "VirGL renderer callback level=warning control_ordinal=12 command=519 context_id=17 resource_id=unattributed"
    )
}

@Test func rendererFailureLogHidesUnknownOperationLabels() throws {
    let sink = RecordingLogSink()
    let failureLog = RendererFailureLog(
        logger: APKLogger(category: GraphicsLogCategory.device, sink: sink)
    )

    failureLog.record(
        .rendererOperationFailed(operation: "guest supplied operation", detail: "dynamic detail")
    )

    let entry = try #require(sink.entries.first)
    #expect(entry.publicMessage == "virtio-gpu renderer operation failed: rendererOperationFailed operation=unknown")
    #expect(entry.publicMessage.contains("guest supplied operation") == false)
    #expect(entry.publicMessage.contains("dynamic detail") == false)
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
    #expect(replay(decoded, onto: replayed).failures.isEmpty)
    // Backing is not in the recording, and its ranges name live guest pages, so the replay does not make these calls.
    let recordedCalls = ref.engine.calls.filter { call in
        switch call {
        case .capset, .poll, .attachBacking, .detachBacking: return false
        default: return true
        }
    }
    #expect(replayed.calls == recordedCalls)
}

@Test func recorderCountsNonzeroBytesWithoutRecordingGuestData() throws {
    let engine = FakeVirGLEngine(onFence: { _ in })
    let recorder = VirGLRecorder(observingGuestResourceIDs: [4], recordsOperations: false)
    let recordingEngine = RecordingVirGLEngine(wrapping: engine, recorder: recorder)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 1)
    defer { memory.deallocate() }
    let bytes = memory.assumingMemoryBound(to: UInt8.self)
    bytes[0] = 0
    bytes[1] = 0x12
    bytes[2] = 0
    bytes[3] = 0x34
    bytes[4] = 0
    bytes[5] = 0
    bytes[6] = 0
    bytes[7] = 0
    let range = try #require(
        VirGLBackingRange(UnsafeMutableRawBufferPointer(start: memory, count: 8))
    )

    try recordingEngine.attachBacking(resource: 4, ranges: [range])
    try recordingEngine.submit(context: 2, commands: [])

    let observations = recorder.guestBackingObservationsForTest()
    #expect(observations.count == 1)
    #expect(observations[0].resourceID == 4)
    #expect(observations[0].rangeCount == 1)
    #expect(observations[0].sampledByteCount == 8)
    #expect(observations[0].nonzeroByteCount == 2)
    #expect(recorder.recording.operations.isEmpty)
    #expect(recorder.guestBackingObservationIfAttachedForTest(resourceID: 4) == observations[0])

    recordingEngine.detachBacking(resource: 4)
    #expect(recorder.guestBackingObservationIfAttachedForTest(resourceID: 4) == nil)

    try recordingEngine.attachBacking(resource: 4, ranges: [range])
    #expect(recorder.guestBackingObservationIfAttachedForTest(resourceID: 4) == nil)
    try recordingEngine.reset()
    #expect(recorder.guestBackingObservationIfAttachedForTest(resourceID: 4) == nil)
}

@Test func recorderBoundsSamplesAndReobservesAfterDetach() throws {
    let engine = FakeVirGLEngine(onFence: { _ in })
    let recorder = VirGLRecorder(observingGuestResourceIDs: [4], recordsOperations: false)
    let recordingEngine = RecordingVirGLEngine(wrapping: engine, recorder: recorder)
    let sampleMemory = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 1)
    defer { sampleMemory.deallocate() }
    let bytes = sampleMemory.assumingMemoryBound(to: UInt8.self)
    bytes.initialize(repeating: 0, count: 8192)
    let range = try #require(
        VirGLBackingRange(UnsafeMutableRawBufferPointer(start: sampleMemory, count: 8192))
    )

    try recordingEngine.attachBacking(resource: 4, ranges: [range])
    try recordingEngine.submit(context: 2, commands: [])
    let firstObservation = try #require(recorder.guestBackingObservationsForTest().first)
    #expect(firstObservation.sampledByteCount == 4096)
    #expect(firstObservation.nonzeroByteCount == 0)

    bytes[0] = 0x12
    try recordingEngine.submit(context: 2, commands: [])
    #expect(recorder.guestBackingObservationsForTest().first == firstObservation)

    recordingEngine.detachBacking(resource: 4)
    bytes[0] = 0x34
    try recordingEngine.attachBacking(resource: 4, ranges: [range])
    try recordingEngine.submit(context: 2, commands: [])
    let reattachedObservation = try #require(recorder.guestBackingObservationsForTest().first)
    #expect(reattachedObservation.sampledByteCount == 4096)
    #expect(reattachedObservation.nonzeroByteCount == 1)
    #expect(
        recorder.guestBackingObservationIfAttachedForTest(resourceID: 4) == reattachedObservation
    )
    #expect(recorder.recording.operations.isEmpty)
}

/// Sends the same requests as `aRecorderDoesNotChangeTheResponsesOrTheEngineCalls`, with or without a recorder. It
/// returns what the guest received and what the engine was asked to do.
private func sessionResponses(recorder: VirGLRecorder?) async throws -> (
    responses: [[UInt8]], engineCalls: [FakeVirGLEngine.Call]
) {
    let harness = try VirGLHarness(recorder: recorder)
    harness.engineRef.engine.fail("submit")
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: Array("gl".utf8)), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [2, 0, 0, 0]), fence: 7, contextID: 1),
        gpuRequest(.ctxDestroy, body: .ctxDestroy, contextID: 1),
    ])
    // The fence is created on the render thread after its submit, so the release repeats until every response is done.
    try await eventually {
        harness.engineRef.engine.releaseFences()
        return control.completionCounts == [1, 1, 1, 1]
    }
    // Capsets and polls depend on timing, and they change no renderer state, so they are left out.
    let stateCalls = harness.engineRef.engine.calls.filter { call in
        switch call {
        case .capset, .poll: return false
        default: return true
        }
    }
    return (control.writtenBuffers, stateCalls)
}

@Test func aRecorderDoesNotChangeTheResponsesOrTheEngineCalls() async throws {
    let plain = try await sessionResponses(recorder: nil)
    let recorder = VirGLRecorder()
    let recorded = try await sessionResponses(recorder: recorder)

    #expect(recorded.responses == plain.responses)
    #expect(recorded.engineCalls == plain.engineCalls)
    // The rejected submit is recorded too, because the recorder sees the operation before the renderer decides on it.
    #expect(recorder.recording.operations.count == 5)
}

@Test func aWrittenRecordingIsTheReplayFormat() throws {
    let fake = FakeVirGLEngine(onFence: { _ in })
    let recorder = VirGLRecorder()
    let session = RecordingVirGLEngine(wrapping: fake, recorder: recorder)
    try session.createContext(id: 1, name: "gl")
    try session.submit(context: 1, commands: [1, 0, 0, 0])
    try session.createFence(id: 2, context: 1)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "apkrun-recorder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")
    try recorder.writeRecording(to: url)

    // The file is a version-1 recording with an operations array, and it reads back as the recorded session.
    let data = try Data(contentsOf: url)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["version"] as? Int == VirGLRecording.currentVersion)
    #expect(object?["operations"] is [Any])
    let decoded = try VirGLRecording.decoded(from: data)
    #expect(decoded == recorder.recording)
    let replayed = FakeVirGLEngine(onFence: { _ in })
    #expect(replay(decoded, onto: replayed).failures.isEmpty)
    #expect(replayed.calls == fake.calls)
}

@Test func aReplayGoesOnPastAFailingCall() throws {
    let recording = VirGLRecording(operations: [
        .createContext(id: 1, name: "gl"),
        .submit(context: 1, commands: [1, 0, 0, 0]),
        .submit(context: 1, commands: [2, 0, 0, 0]),
        .destroyContext(id: 1),
    ])
    let fake = FakeVirGLEngine(onFence: { _ in })
    fake.fail("submit")
    let outcome = replay(recording, onto: fake)

    // Both submits fail, and the destroy after them still runs, as it does on the device (IR-460).
    #expect(outcome.attempted == 4)
    #expect(outcome.failures.map(\.index) == [1, 2])
    #expect(
        fake.calls == [
            .createContext(1, "gl"),
            .submit(context: 1, bytes: [1, 0, 0, 0]),
            .submit(context: 1, bytes: [2, 0, 0, 0]),
            .destroyContext(1),
        ])
}

@Test func aRecordingFromAnotherVersionIsRejected() throws {
    var recording = VirGLRecording(operations: [.reset])
    recording.version = 2
    let data = try recording.encoded()
    #expect(throws: VirGLRecordingFailure.unsupportedVersion(2)) {
        _ = try VirGLRecording.decoded(from: data)
    }
}

@Test func aFencedDisplayInfoBeyondThirtyTwoBitsIsAnInvalidParameter() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.getDisplayInfo, body: .getDisplayInfo, fence: 1 << 40)
    ])
    try await eventually { control.completionCounts == [1] }
    #expect(gpuResponseType(control.writtenBuffers[0]) == VirtioGPUErrorCode.invalidParameter.rawValue)
}

@Test func aFenceAboveThirtyOneBitsIsCreatedAndWaitsForItsRelease() async throws {
    let harness = try VirGLHarness()
    let control = harness.send([
        gpuRequest(.ctxCreate, body: .ctxCreate(contextInit: 0, debugName: []), contextID: 1),
        gpuRequest(.submit3D, body: .submit3D(commandStream: [1, 0, 0, 0]), fence: 0x8000_0001, contextID: 1),
    ])
    try await eventually { harness.engineRef.engine.calls.contains(.fence(0x8000_0001, context: 1)) }
    #expect(control.completionCounts == [1, 0])
    harness.engineRef.engine.releaseFences()
    try await eventually { control.completionCounts == [1, 1] }
}

@Test func aRendererThatFailsToStartIsDestroyedBeforeTheErrorIsThrown() throws {
    let ref = EngineRef()
    #expect(throws: GraphicsFailure.self) {
        _ = try VirtioGPUDevice.makeVirgl { onFence throws(GraphicsFailure) -> any VirGLEngine in
            let engine = FakeVirGLEngine(onFence: onFence)
            engine.fail("capsetInfo")
            ref.set(engine)
            return engine
        }
    }
    #expect(ref.engine.calls.contains(.destroy))
}
