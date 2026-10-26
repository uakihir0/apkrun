import Foundation
import IOSurface
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

/// Holds the engine that the device's render thread created, for the test to inspect.
private final class PresenterEngineRef: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FakeVirGLEngine?

    func set(_ engine: FakeVirGLEngine) {
        lock.withLock { stored = engine }
    }

    var engine: FakeVirGLEngine {
        lock.withLock { stored! }
    }
}

private final class ReplacementCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func markCompleted() {
        lock.withLock { didComplete = true }
    }

    var completed: Bool {
        lock.withLock { didComplete }
    }
}

/// A `drmVirgl` device with a fake renderer, and a control queue that delivers guest requests to it.
private struct PresenterHarness {
    let device: VirtioGPUDevice
    let engineRef: PresenterEngineRef
    let guest: SeededGuestBackend
    let context: VirtioDeviceContext

    init() throws {
        let ref = PresenterEngineRef()
        device = try VirtioGPUDevice.makeVirgl {
            onFence throws(GraphicsFailure) -> any VirGLEngine in
            let engine = FakeVirGLEngine(onFence: onFence)
            ref.set(engine)
            return engine
        }
        engineRef = ref
        guest = SeededGuestBackend(queues: [FakeVirtioQueue(elements: []), FakeVirtioQueue(elements: [])])
        context = VirtioDeviceContext(backend: guest, generation: 0)
    }

    var engine: FakeVirGLEngine {
        engineRef.engine
    }

    /// Delivers `requests` to the control queue in one drain, and returns the queue that records the answers.
    func send(_ requests: [(readable: [UInt8], writableByteCount: Int)]) -> FakeVirtioQueue {
        let control = FakeVirtioQueue(elements: requests)
        guest.replaceQueues([control, FakeVirtioQueue(elements: [])])
        device.queueNotified(index: 0, context: context)
        return control
    }
}

private let scanoutZero = ScanoutID(rawValue: 0)!

/// The requests that bind a 8 x 4 resource to scanout 0 and flush it.
private func bindAndFlush(resource: UInt32, rect: VirtioGPURect) -> [(readable: [UInt8], writableByteCount: Int)] {
    [
        (
            readable: gpuRequest(
                .resourceCreate3D,
                body: .resourceCreate3D(
                    VirtioGPUResourceCreate3D(
                        resourceID: resource,
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
                body: .setScanout(rect: rect, scanoutID: 0, resourceID: resource)
            ),
            writableByteCount: 4096
        ),
    ]
}

private func flushRequest(resource: UInt32, rect: VirtioGPURect) -> (readable: [UInt8], writableByteCount: Int) {
    (
        readable: gpuRequest(.resourceFlush, body: .resourceFlush(rect: rect, resourceID: resource)),
        writableByteCount: 4096
    )
}

private let fullRect = VirtioGPURect(x: 0, y: 0, width: 8, height: 4)

private func blitCalls(_ engine: FakeVirGLEngine) -> [FakeVirGLEngine.Call] {
    engine.calls.filter { call in
        if case .presentBlit = call { return true }
        return false
    }
}

@Test func aFlushOfAPresentingScanoutBlitsIntoAnIOSurfaceAndOffersTheFrame() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)

    #expect(presenter.surfaces.count == 3)
    for surface in presenter.surfaces {
        #expect(surface.width == 8)
        #expect(surface.height == 4)
        #expect(surface.bytesPerElement == 4)
        #expect(surface.bytesPerRow == 64)
    }
    var frames = presenter.frames.makeAsyncIterator()

    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }

    #expect(blitCalls(harness.engine) == [.presentBlit(resource: 3, source: fullRect, target: 1)])
    try await eventually { presenter.statistics.framesPresented == 1 }
    guard
        case .frameReady(
            let generation,
            let bufferIndex,
            let sequence,
            let presentationTime
        )? = await frames.next()
    else {
        Issue.record("A completed blit should publish a frame for the consumer.")
        return
    }
    #expect(generation == 1)
    #expect(bufferIndex == 0)
    #expect(sequence == 1)
    #expect(presentationTime > 0)
    // The present path never reads pixels back or copies them on the CPU (graphics.md §6.2, §7).
    #expect(harness.device.statistics.hostReadbacks == 0)
    #expect(harness.device.statistics.cpuPixelCopies == 0)
    presenter.close()
}

@Test func hiddenFlushesCoalesceAndVisibilityRestoresTheBoundResource() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    let scanouts = VirtioGPUScanoutController(device: harness.device)
    let initial = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { initial.completionCounts == [1, 1, 1] }
    try await eventually { presenter.statistics.framesPresented == 1 }

    scanouts.visibilityChanged(scanoutZero, visible: false)
    let hidden = harness.send([
        flushRequest(resource: 3, rect: fullRect),
        flushRequest(resource: 3, rect: fullRect),
        flushRequest(resource: 3, rect: fullRect),
    ])
    try await eventually { hidden.completionCounts == [1, 1, 1] }
    #expect(blitCalls(harness.engine).count == 1)
    #expect(presenter.statistics.droppedFrames == 2)

    scanouts.visibilityChanged(scanoutZero, visible: true)
    try await eventually { presenter.statistics.framesPresented == 2 }
    #expect(blitCalls(harness.engine).count == 2)
    // Resuming requests the current scanout binding, replacing the held hidden request.
    #expect(presenter.statistics.droppedFrames == 3)
    presenter.close()
}

@Test func anInFlightBlitDoesNotDrainPendingFramesUntilTheScanoutIsVisible() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    let scanouts = VirtioGPUScanoutController(device: harness.device)
    harness.engine.autoCompletePresentFences = false
    let initial = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { initial.completionCounts == [1, 1, 1] }
    try await eventually { blitCalls(harness.engine).count == 1 }

    scanouts.visibilityChanged(scanoutZero, visible: false)
    let hidden = harness.send([
        flushRequest(resource: 3, rect: fullRect),
        flushRequest(resource: 3, rect: fullRect),
    ])
    try await eventually { hidden.completionCounts == [1, 1] }
    harness.engine.completePresentFences()
    try await eventually { presenter.statistics.framesPresented == 1 }
    #expect(blitCalls(harness.engine).count == 1)

    scanouts.visibilityChanged(scanoutZero, visible: true)
    try await eventually { blitCalls(harness.engine).count == 2 }
    harness.engine.completePresentFences()
    try await eventually { presenter.statistics.framesPresented == 2 }
    #expect(presenter.statistics.droppedFrames == 2)
    presenter.close()
}

@Test func theTargetsAreMadeOnceForEachBufferOfTheScanout() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    presenter.close()
    let calls = harness.engine.calls
    #expect(calls.filter { $0 == .presentTargetCreate(width: 8, height: 4) }.count == 3)
    #expect(calls.filter { if case .presentTargetDestroy = $0 { true } else { false } }.count == 3)
}

@Test func aFlushWhileABlitIsInFlightIsHeldAndTheNewestHeldFrameIsPresented() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    harness.engine.autoCompletePresentFences = false
    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }
    // Two more flushes arrive while the first blit is in flight. The second is held, and the third replaces it.
    let more = harness.send([flushRequest(resource: 3, rect: fullRect), flushRequest(resource: 3, rect: fullRect)])
    try await eventually { more.completionCounts == [1, 1] }
    #expect(blitCalls(harness.engine).count == 1)

    harness.engine.completePresentFences()
    try await eventually { blitCalls(harness.engine).count == 2 }
    #expect(presenter.statistics.framesPresented == 1)
    harness.engine.completePresentFences()
    try await eventually { presenter.statistics.framesPresented == 2 }
    #expect(presenter.statistics.droppedFrames == 1)
    presenter.close()
}

@Test func aFrameIsHeldWhileNoBufferIsFreeUntilTheConsumerDisplaysOne() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }
    // Three frames fill the three buffers, which the consumer does not display. Each flush waits until its frame is
    // offered, so no flush is held behind an earlier blit.
    try await eventually { presenter.statistics.framesPresented == 1 }
    for expected: UInt64 in 2...3 {
        let next = harness.send([flushRequest(resource: 3, rect: fullRect)])
        try await eventually { next.completionCounts == [1] }
        try await eventually { presenter.statistics.framesPresented == expected }
    }
    #expect(presenter.statistics.framesPresented == 3)
    #expect(blitCalls(harness.engine).count == 3)

    // A fourth flush finds no free buffer, so it is held and no blit starts.
    let held = harness.send([flushRequest(resource: 3, rect: fullRect)])
    try await eventually { held.completionCounts == [1] }
    #expect(blitCalls(harness.engine).count == 3)

    // The consumer displays frame 3, which frees frames 1 and 2 (display-and-windowing.md §5.2). The held frame starts.
    presenter.frameDisplayed(upTo: 3)
    try await eventually { presenter.statistics.framesPresented == 4 }
    #expect(blitCalls(harness.engine).count == 4)
    presenter.close()
}

@Test func aFailedBlitReturnsItsBufferAndCountsARendererFailure() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    harness.engine.fail("presentBlit")
    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }
    // The guest still gets its answer, and the failure is counted, not reported (IR-460).
    try await eventually { harness.device.statistics.rendererFailures == 1 }
    #expect(presenter.statistics.framesPresented == 0)
    #expect(gpuResponseType(control.writtenBuffers[2]) == VirtioGPUResponseType.okNoData.rawValue)

    // The buffer came back, so the next flush renders into the first buffer again.
    let next = harness.send([flushRequest(resource: 3, rect: fullRect)])
    try await eventually { next.completionCounts == [1] }
    try await eventually { harness.device.statistics.rendererFailures == 2 }
    #expect(blitCalls(harness.engine).count == 2)
    presenter.close()
}

@Test func aStalledFenceIsCountedAndWaitedOnUntilItSignals() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    harness.engine.autoCompletePresentFences = false
    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }
    // The 100 ms stall timeout is counted, and the wait goes on.
    try await eventually { presenter.statistics.presentStalls >= 1 }
    #expect(presenter.statistics.framesPresented == 0)
    harness.engine.completePresentFences()
    try await eventually { presenter.statistics.framesPresented == 1 }
    presenter.close()
}

@Test func aFlushOfAScanoutWithoutAPresenterCompletesWithoutABlit() async throws {
    let harness = try PresenterHarness()
    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }
    #expect(blitCalls(harness.engine).isEmpty)
    #expect(gpuResponseType(control.writtenBuffers[2]) == VirtioGPUResponseType.okNoData.rawValue)
}

@Test func aGuestResetDiscardsAHeldFlushAndCompletesTheInFlightBlit() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    harness.engine.autoCompletePresentFences = false
    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }
    let held = harness.send([flushRequest(resource: 3, rect: fullRect)])
    try await eventually { held.completionCounts == [1] }
    harness.device.deviceWillReset()
    harness.engine.completePresentFences()
    try await eventually { presenter.statistics.framesPresented == 1 }
    // The held flush named a resource the reset unbound, so no second blit starts.
    try await Task.sleep(for: .milliseconds(50))
    #expect(blitCalls(harness.engine).count == 1)
    presenter.close()
}

@Test func aClosedPresenterRefusesFlushesAndReleasesItsTargets() async throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    presenter.close()
    presenter.close()
    let control = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { control.completionCounts == [1, 1, 1] }
    #expect(blitCalls(harness.engine).isEmpty)
    let destroyed = harness.engine.calls.filter { if case .presentTargetDestroy = $0 { true } else { false } }
    #expect(destroyed.count == 3)
}

@Test func aPresenterCannotBeAttachedAfterTheGuestStarts() throws {
    let harness = try PresenterHarness()
    harness.device.deviceDidStart(context: harness.context, negotiatedFeatures: 0)
    #expect(throws: GraphicsFailure.self) {
        _ = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    }
}

@Test func livePresenterReplacementAdvancesGenerationAndClosesTheOldPresenterAfterItsBlit() async throws {
    let harness = try PresenterHarness()
    let oldPresenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    harness.device.deviceDidStart(context: harness.context, negotiatedFeatures: 0)
    var oldFrames = oldPresenter.frames.makeAsyncIterator()

    let first = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { first.completionCounts == [1, 1, 1] && oldPresenter.statistics.framesPresented == 1 }
    guard
        case .frameReady(
            let oldGeneration,
            let oldBufferIndex,
            let oldSequence,
            let oldPresentationTime
        )? = await oldFrames.next()
    else {
        Issue.record("The old presenter should publish its completed frame.")
        return
    }
    #expect(oldGeneration == 1)
    #expect(oldBufferIndex == 0)
    #expect(oldSequence == 1)
    #expect(oldPresentationTime > 0)

    let mode = DisplayMode(widthPixels: 800, heightPixels: 600, refreshHz: 60, dotsPerInch: 160)
    let newPresenter = try harness.device.reconfigurePresenter(
        scanoutZero, mode: mode, width: mode.widthPixels, height: mode.heightPixels)
    #expect(newPresenter.generation == 2)
    #expect(newPresenter.surfaces.first?.width == 800)
    #expect(newPresenter.surfaces.first?.height == 600)
    #expect(harness.engine.calls.filter { if case .presentTargetDestroy = $0 { true } else { false } }.count == 3)

    var newFrames = newPresenter.frames.makeAsyncIterator()
    let second = harness.send([flushRequest(resource: 3, rect: fullRect)])
    try await eventually { second.completionCounts == [1] && newPresenter.statistics.framesPresented == 1 }
    guard
        case .frameReady(
            let newGeneration,
            let newBufferIndex,
            let newSequence,
            let newPresentationTime
        )? = await newFrames.next()
    else {
        Issue.record("The replacement presenter should publish its completed frame.")
        return
    }
    #expect(newGeneration == 2)
    #expect(newBufferIndex == 0)
    #expect(newSequence == 2)
    #expect(newPresentationTime > 0)

    harness.device.frameDisplayed(scanout: scanoutZero, generation: 2, sequence: 2)
    harness.device.deviceWillStop()
}

@Test func livePresenterReplacementWaitsForTheOldScanoutFence() async throws {
    let harness = try PresenterHarness()
    let oldPresenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    harness.device.deviceDidStart(context: harness.context, negotiatedFeatures: 0)
    harness.engine.autoCompletePresentFences = false
    let first = harness.send(
        bindAndFlush(resource: 3, rect: fullRect) + [flushRequest(resource: 3, rect: fullRect)]
    )
    try await eventually { first.completionCounts == [1, 1, 1] && blitCalls(harness.engine).count == 1 }

    let completion = ReplacementCompletion()
    let mode = DisplayMode(widthPixels: 800, heightPixels: 600, refreshHz: 60, dotsPerInch: 160)
    let device = harness.device
    let replacement = Task.detached {
        defer { completion.markCompleted() }
        return try? device.reconfigurePresenter(
            scanoutZero, mode: mode, width: mode.widthPixels, height: mode.heightPixels)
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!completion.completed)
    #expect(blitCalls(harness.engine).count == 1)
    #expect(harness.engine.calls.filter { if case .presentTargetDestroy = $0 { true } else { false } }.isEmpty)

    harness.engine.completePresentFences()
    let newPresenter = await replacement.value
    #expect(completion.completed)
    #expect(newPresenter?.generation == 2)
    #expect(oldPresenter.statistics.framesPresented == 1)
    #expect(harness.engine.calls.filter { if case .presentTargetDestroy = $0 { true } else { false } }.count == 3)
    harness.device.deviceWillStop()
}

@Test func failedLivePresenterReplacementLeavesTheCurrentModeAndPoolAttached() throws {
    let harness = try PresenterHarness()
    let presenter = try harness.device.attachPresenter(scanoutZero, width: 8, height: 4)
    harness.device.deviceDidStart(context: harness.context, negotiatedFeatures: 0)
    let invalid = DisplayMode(widthPixels: 4096, heightPixels: 600, refreshHz: 60, dotsPerInch: 160)

    #expect(throws: GraphicsFailure.self) {
        _ = try harness.device.reconfigurePresenter(scanoutZero, mode: invalid, width: 4096, height: 600)
    }
    #expect(harness.device.scanoutTable.state(of: scanoutZero).mode == .testDefault)
    #expect(presenter.generation == 1)

    let mismatched = DisplayMode(widthPixels: 800, heightPixels: 600, refreshHz: 60, dotsPerInch: 160)
    #expect(throws: GraphicsFailure.self) {
        _ = try harness.device.reconfigurePresenter(scanoutZero, mode: mismatched, width: 640, height: 600)
    }
    #expect(harness.device.scanoutTable.state(of: scanoutZero).mode == .testDefault)
    #expect(presenter.generation == 1)
    harness.device.deviceWillStop()
}

@Test func onlyTheVirGLDeviceCanAttachAPresenter() throws {
    #expect(throws: GraphicsFailure.self) {
        _ = try VirtioGPUDevice.twoDimensional().attachPresenter(scanoutZero, width: 8, height: 4)
    }
}

@Test func aPresenterRefusesAnImpossibleSize() throws {
    let harness = try PresenterHarness()
    #expect(throws: GraphicsFailure.self) {
        _ = try harness.device.attachPresenter(scanoutZero, width: 0, height: 4)
    }
    #expect(throws: GraphicsFailure.self) {
        _ = try harness.device.attachPresenter(scanoutZero, width: 4096, height: 4)
    }
}
