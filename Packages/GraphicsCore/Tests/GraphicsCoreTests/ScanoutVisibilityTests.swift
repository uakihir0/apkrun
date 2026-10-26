import Dispatch
import Foundation
import IOSurface
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

private final class VisibilityEngineReference: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FakeVirGLEngine?

    func set(_ engine: FakeVirGLEngine) {
        lock.withLock { stored = engine }
    }

    var engine: FakeVirGLEngine {
        lock.withLock { stored! }
    }
}

private final class VisibilityTargetCreationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let proceed = DispatchSemaphore(value: 0)
    private var didReach = false
    private var didContinue = false

    var didReachTargetCreation: Bool {
        lock.withLock { didReach }
    }

    func pauseTargetCreation() {
        lock.withLock { didReach = true }
        _ = proceed.wait(timeout: .now() + .seconds(5))
    }

    func waitForTargetCreationToStart() async throws {
        try await eventually { didReachTargetCreation }
    }

    func continueTargetCreation() {
        let shouldSignal = lock.withLock {
            guard !didContinue else { return false }
            didContinue = true
            return true
        }
        if shouldSignal {
            proceed.signal()
        }
    }
}

private struct VisibilityHarness {
    let device: VirtioGPUDevice
    let engineReference: VisibilityEngineReference
    let guest: SeededGuestBackend
    let context: VirtioDeviceContext

    init() throws {
        let reference = VisibilityEngineReference()
        device = try VirtioGPUDevice.makeVirgl {
            onFence throws(GraphicsFailure) -> any VirGLEngine in
            let engine = FakeVirGLEngine(onFence: onFence)
            reference.set(engine)
            return engine
        }
        engineReference = reference
        guest = SeededGuestBackend(queues: [FakeVirtioQueue(elements: []), FakeVirtioQueue(elements: [])])
        context = VirtioDeviceContext(backend: guest, generation: 0)
    }

    var engine: FakeVirGLEngine {
        engineReference.engine
    }

    func send(_ requests: [(readable: [UInt8], writableByteCount: Int)]) -> FakeVirtioQueue {
        let control = FakeVirtioQueue(elements: requests)
        guest.replaceQueues([control, FakeVirtioQueue(elements: [])])
        device.queueNotified(index: 0, context: context)
        return control
    }
}

private let visibilityTestScanout = ScanoutID(rawValue: 0)!
private let visibilityTestRect = VirtioGPURect(x: 0, y: 0, width: 8, height: 4)

private func visibilityTestBindResourceRequests()
    -> [(readable: [UInt8], writableByteCount: Int)]
{
    [
        (
            readable: gpuRequest(
                .resourceCreate3D,
                body: .resourceCreate3D(
                    VirtioGPUResourceCreate3D(
                        resourceID: 3,
                        target: 2,
                        format: 1,
                        bind: 2,
                        width: 8,
                        height: 4,
                        depth: 1,
                        arraySize: 1,
                        lastLevel: 0,
                        sampleCount: 0,
                        flags: 0
                    )
                )
            ),
            writableByteCount: 4096
        ),
        (
            readable: gpuRequest(
                .setScanout,
                body: .setScanout(rect: visibilityTestRect, scanoutID: 0, resourceID: 3)
            ),
            writableByteCount: 4096
        ),
    ]
}

private func visibilityTestFlushRequest() -> (readable: [UInt8], writableByteCount: Int) {
    (
        readable: gpuRequest(
            .resourceFlush,
            body: .resourceFlush(rect: visibilityTestRect, resourceID: 3)
        ),
        writableByteCount: 4096
    )
}

private func visibilityTestBlitCount(_ engine: FakeVirGLEngine) -> Int {
    engine.calls.reduce(into: 0) { count, call in
        if case .presentBlit = call {
            count += 1
        }
    }
}

private let visibilityTestReplacementMode = DisplayMode(
    widthPixels: 800,
    heightPixels: 600,
    refreshHz: 60,
    dotsPerInch: 160
)

@Test func livePresenterReplacementPreservesAnExistingHiddenState() async throws {
    let harness = try VisibilityHarness()
    let original = try harness.device.attachPresenter(visibilityTestScanout, width: 8, height: 4)
    harness.device.deviceDidStart(context: harness.context, negotiatedFeatures: 0)
    let bound = harness.send(visibilityTestBindResourceRequests())
    try await eventually { bound.completionCounts == [1, 1] }

    harness.device.visibilityChanged(visibilityTestScanout, visible: false)
    let replacement = try harness.device.reconfigurePresenter(
        visibilityTestScanout,
        mode: visibilityTestReplacementMode,
        width: visibilityTestReplacementMode.widthPixels,
        height: visibilityTestReplacementMode.heightPixels
    )
    #expect(replacement.generation == original.generation + 1)

    let hiddenFlush = harness.send([visibilityTestFlushRequest()])
    try await eventually { hiddenFlush.completionCounts == [1] }
    #expect(visibilityTestBlitCount(harness.engine) == 0)
    #expect(replacement.statistics.framesPresented == 0)

    harness.device.visibilityChanged(visibilityTestScanout, visible: true)
    try await eventually { replacement.statistics.framesPresented == 1 }
    #expect(visibilityTestBlitCount(harness.engine) == 1)
    harness.device.deviceWillStop()
}

@Test func aVisibilityChangeDuringCandidateCreationAppliesToTheReplacement() async throws {
    let harness = try VisibilityHarness()
    let original = try harness.device.attachPresenter(visibilityTestScanout, width: 8, height: 4)
    harness.device.deviceDidStart(context: harness.context, negotiatedFeatures: 0)
    let bound = harness.send(visibilityTestBindResourceRequests())
    try await eventually { bound.completionCounts == [1, 1] }

    let targetCreationGate = VisibilityTargetCreationGate()
    defer { targetCreationGate.continueTargetCreation() }
    harness.engine.interceptNextPresentTargetCreation {
        targetCreationGate.pauseTargetCreation()
    }

    let device = harness.device
    let replacementTask = Task.detached {
        try? device.reconfigurePresenter(
            visibilityTestScanout,
            mode: visibilityTestReplacementMode,
            width: visibilityTestReplacementMode.widthPixels,
            height: visibilityTestReplacementMode.heightPixels
        )
    }
    try await targetCreationGate.waitForTargetCreationToStart()

    device.visibilityChanged(visibilityTestScanout, visible: false)
    targetCreationGate.continueTargetCreation()
    let replacement = await replacementTask.value
    #expect(replacement?.generation == original.generation + 1)
    guard let replacement else {
        device.deviceWillStop()
        return
    }

    let hiddenFlush = harness.send([visibilityTestFlushRequest()])
    try await eventually { hiddenFlush.completionCounts == [1] }
    #expect(visibilityTestBlitCount(harness.engine) == 0)
    #expect(replacement.statistics.framesPresented == 0)

    device.visibilityChanged(visibilityTestScanout, visible: true)
    try await eventually { replacement.statistics.framesPresented == 1 }
    #expect(visibilityTestBlitCount(harness.engine) == 1)
    device.deviceWillStop()
}
