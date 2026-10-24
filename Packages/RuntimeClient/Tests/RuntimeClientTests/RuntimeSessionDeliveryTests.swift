import Foundation
import IOSurface
import RuntimeAPI
import Testing

@testable import RuntimeClient

private func sessionTestSurfaces() throws -> [IOSurface] {
    try (0..<SurfaceSet.requiredSurfaceCount).map { _ in
        try #require(
            IOSurface(
                properties: [
                    .width: 16,
                    .height: 24,
                    .bytesPerElement: 4,
                    .bytesPerRow: 64,
                ]
            )
        )
    }
}

private func sessionTestSurfaceSet(generation: UInt32) -> SurfaceSet {
    SurfaceSet(
        generation: generation,
        pixelSize: PixelSize(width: 16, height: 24),
        densityDpi: 160
    )
}

@Test func sessionFrameRecoversPoolWhenReplacementEventWasCoalesced() async throws {
    let hub = RuntimeSessionEventStreamHub()
    let initial = sessionTestSurfaceSet(generation: 1)
    let replacement = sessionTestSurfaceSet(generation: 2)
    #expect(hub.installInitialPool(initial, surfaces: try sessionTestSurfaces()))

    hub.receiveSurfaceReplacement(replacement, surfaces: try sessionTestSurfaces())
    let frame = FrameReady(generation: 2, surfaceIndex: 1, frameSeq: 10, presentationTime: 20)
    hub.receiveFrame(frame)

    var iterator = hub.stream.makeAsyncIterator()
    guard case .frameReady(let delivered)? = await iterator.next() else {
        Issue.record("The coalesced stream should keep the latest frame.")
        return
    }
    #expect(delivered.message == frame)
    #expect(delivered.surfaceSet == replacement)
    #expect(delivered.surfaces.count == SurfaceSet.requiredSurfaceCount)
    #expect(delivered.windowPrefs == WindowPrefs())
}

@Test func sessionHubCarriesUpdatedWindowPreferencesWithResizedGeneration() async throws {
    let hub = RuntimeSessionEventStreamHub()
    let initialPrefs = WindowPrefs(zoom: 1)
    let replacementPrefs = WindowPrefs(zoom: 1.25)
    #expect(
        hub.installInitialPool(
            sessionTestSurfaceSet(generation: 1),
            surfaces: try sessionTestSurfaces(),
            windowPrefs: initialPrefs
        )
    )
    let replacement = sessionTestSurfaceSet(generation: 2)

    #expect(
        hub.installResizedPool(
            replacement,
            surfaces: try sessionTestSurfaces(),
            windowPrefs: replacementPrefs
        )
    )
    #expect(
        !hub.installResizedPool(
            replacement,
            surfaces: try sessionTestSurfaces(),
            windowPrefs: replacementPrefs
        )
    )

    var iterator = hub.stream.makeAsyncIterator()
    guard case .surfacesReplaced(let notice, _, let installedPrefs)? = await iterator.next() else {
        Issue.record("A resized pool should publish its updated window preferences.")
        return
    }
    #expect(notice.surfaceSet == replacement)
    #expect(installedPrefs == replacementPrefs)

    let frame = FrameReady(generation: 2, surfaceIndex: 1, frameSeq: 11, presentationTime: 21)
    hub.receiveFrame(frame)
    guard case .frameReady(let delivered)? = await iterator.next() else {
        Issue.record("Frames must carry the preferences used to resolve their generation.")
        return
    }
    #expect(delivered.message == frame)
    #expect(delivered.windowPrefs == replacementPrefs)
}

@Test(.timeLimit(.minutes(1))) func sessionHubKeepsFutureGenerationFrameUntilResizeReplyInstallsPool() async throws {
    let hub = RuntimeSessionEventStreamHub()
    #expect(hub.installInitialPool(sessionTestSurfaceSet(generation: 1), surfaces: try sessionTestSurfaces()))

    let replacement = sessionTestSurfaceSet(generation: 2)
    let replacementSurfaces = try sessionTestSurfaces()
    let replacementPrefs = WindowPrefs(zoom: 1.25)
    let frame = FrameReady(generation: 2, surfaceIndex: 1, frameSeq: 11, presentationTime: 21)
    hub.receiveFrame(frame)

    #expect(
        hub.installResizedPool(
            replacement,
            surfaces: replacementSurfaces,
            windowPrefs: replacementPrefs
        )
    )
    var iterator = hub.stream.makeAsyncIterator()
    guard case .frameReady(let delivered)? = await iterator.next() else {
        Issue.record("A future-generation frame must be retained until its pool arrives.")
        return
    }
    #expect(delivered.message == frame)
    #expect(delivered.surfaceSet == replacement)
    #expect(delivered.surfaces.count == SurfaceSet.requiredSurfaceCount)
    #expect(delivered.windowPrefs == replacementPrefs)
}

@Test func sessionHubAcceptsPoolReplacementBeforeOpenReply() async throws {
    let hub = RuntimeSessionEventStreamHub()
    let initial = sessionTestSurfaceSet(generation: 1)
    let replacement = sessionTestSurfaceSet(generation: 2)
    let frame = FrameReady(generation: 2, surfaceIndex: 0, frameSeq: 5, presentationTime: 8)

    hub.receiveSurfaceReplacement(replacement, surfaces: try sessionTestSurfaces())
    hub.receiveFrame(frame)

    #expect(hub.installInitialPool(initial, surfaces: try sessionTestSurfaces()))
    #expect(hub.retainedGenerations() == [1, 2])

    var iterator = hub.stream.makeAsyncIterator()
    guard case .frameReady(let delivered)? = await iterator.next() else {
        Issue.record("The first frame for the replacement pool should survive the open-reply race.")
        return
    }
    #expect(delivered.message == frame)
    #expect(delivered.surfaceSet == replacement)
}

@Test func sessionAcknowledgementReleasesOlderSurfacePools() throws {
    let hub = RuntimeSessionEventStreamHub()
    #expect(hub.installInitialPool(sessionTestSurfaceSet(generation: 1), surfaces: try sessionTestSurfaces()))
    hub.receiveSurfaceReplacement(sessionTestSurfaceSet(generation: 2), surfaces: try sessionTestSurfaces())

    #expect(hub.retainedGenerations() == [1, 2])
    hub.acknowledge(FrameDisplayed(generation: 1, frameSeq: 1))
    #expect(hub.retainedGenerations() == [1, 2])
    hub.acknowledge(FrameDisplayed(generation: 2, frameSeq: 2))
    #expect(hub.retainedGenerations() == [2])
}

@Test func sessionHubRejectsInvalidSurfaceSetCardinality() throws {
    let hub = RuntimeSessionEventStreamHub()
    let metadata = sessionTestSurfaceSet(generation: 1)
    #expect(!hub.installInitialPool(metadata, surfaces: Array(try sessionTestSurfaces().prefix(2))))
    #expect(hub.retainedGenerations().isEmpty)
}

@Test func sessionCloseRequestSurvivesCoalescedFrameTraffic() async throws {
    let hub = RuntimeSessionEventStreamHub()
    let closeAcknowledgements = CloseAcknowledgementRecorder()
    #expect(hub.installInitialPool(sessionTestSurfaceSet(generation: 1), surfaces: try sessionTestSurfaces()))

    hub.receiveCloseRequest { closeAcknowledgements.record() }
    for sequence in 1...32 {
        hub.receiveFrame(
            FrameReady(
                generation: 1,
                surfaceIndex: 0,
                frameSeq: UInt64(sequence),
                presentationTime: UInt64(sequence)
            )
        )
    }

    var iterator = hub.closeRequests.makeAsyncIterator()
    guard let request = await iterator.next() else {
        Issue.record("Frame traffic must not replace a queued close request.")
        return
    }
    request.acknowledge()
    #expect(closeAcknowledgements.count == 1)
}

@Test(.timeLimit(.minutes(1))) func sessionResizeGateSerializesConcurrentRequests() async throws {
    let gate = RuntimeSessionResizeGate()
    let sessionID = UUID()
    let initialGeometry = DisplayGeometry(
        pointSize: DisplayPointSize(width: 480, height: 800),
        backingScale: 2,
        zoom: 1
    )
    let firstResizeGeometry = DisplayGeometry(
        pointSize: DisplayPointSize(width: 540, height: 900),
        backingScale: 2,
        zoom: 1.1
    )
    let secondResizeGeometry = DisplayGeometry(
        pointSize: DisplayPointSize(width: 600, height: 1_000),
        backingScale: 2,
        zoom: 1.25
    )
    let resizeHandler = ControlledSessionResizeHandler(sessionID: sessionID)
    let descriptor = SessionDescriptor(
        sessionID: sessionID,
        displayID: 3,
        windowPrefs: WindowPrefs(zoom: initialGeometry.zoom),
        inputPrefs: InputPrefs(),
        windowMode: .secondaryDisplay,
        state: .running,
        surfaces: sessionTestSurfaceSet(generation: 1)
    )
    let (messages, _) = AsyncStream<RuntimeSessionMessage>.makeStream()
    let (closeRequests, _) = AsyncStream<RuntimeSessionCloseRequest>.makeStream()
    let session = RuntimeOpenedSession(
        descriptor: descriptor,
        surfaces: try sessionTestSurfaces(),
        messages: messages,
        closeRequests: closeRequests,
        frameDisplayed: { _ in },
        visibilityChanged: { _ in },
        resize: { geometry in await resizeHandler.resize(geometry) },
        resizeGate: gate
    )

    let firstRequest = Task<SessionResizeOutcome?, Never> {
        do {
            return try await session.resize(firstResizeGeometry)
        } catch {
            return nil
        }
    }
    await resizeHandler.waitUntilFirstRequestStarts()

    let secondStarted = ResizeRequestStarted()
    let secondRequest = Task<SessionResizeOutcome?, Never> {
        await secondStarted.signal()
        do {
            return try await session.resize(secondResizeGeometry)
        } catch {
            return nil
        }
    }
    await secondStarted.wait()
    await gate.waitUntilWaitingCount(atLeast: 1)

    #expect(gate.waitingCount == 1)
    await resizeHandler.releaseFirstRequest()
    #expect(await firstRequest.value == SessionResizeOutcome.applied)
    #expect(await secondRequest.value == SessionResizeOutcome.applied)

    let resizeSnapshot = await resizeHandler.snapshot()
    #expect(resizeSnapshot.maximumActiveRequests == 1)
    #expect(resizeSnapshot.geometries == [firstResizeGeometry, secondResizeGeometry])
    #expect(session.descriptor.surfaces.generation == 3)
    #expect(session.descriptor.windowPrefs.zoom == secondResizeGeometry.zoom)
    #expect(gate.waitingCount == 0)
}

@Test func sessionResizeErrorsPreserveWhetherTheResultIsUncertain() {
    #expect(
        RuntimeControlClientError.transportFailure(domain: "NSCocoaErrorDomain", code: 4097)
            .sessionResizeResultIsUncertain)
    #expect(RuntimeControlClientError.requestTimedOut(operation: "sessionResize").sessionResizeResultIsUncertain)
    #expect(RuntimeControlClientError.operationResultUnknown(operation: "sessionResize").sessionResizeResultIsUncertain)
    #expect(RuntimeControlClientError.malformedReply.sessionResizeResultIsUncertain)
    #expect(!RuntimeControlClientError.requestCancelled(operation: "sessionResize").sessionResizeResultIsUncertain)
    #expect(!RuntimeControlClientError.invalidRemoteProxy.sessionResizeResultIsUncertain)
    #expect(
        RuntimeControlClientError.remoteFailure(code: "runtime.internal", message: "Internal error")
            .sessionResizeResultIsUncertain
    )
    #expect(
        !RuntimeControlClientError.remoteFailure(
            code: "runtime.displayReconfigureFailed",
            message: "The previous display mode was restored."
        )
        .sessionResizeResultIsUncertain
    )
    #expect(!RuntimeControlClientError.encodingFailure.sessionResizeResultIsUncertain)
}

@Test func invalidatedSessionStreamsCanRouteTheExistingEventSinkToAReopenedSession() async throws {
    let previousHub = RuntimeSessionEventStreamHub()
    let reopenedHub = RuntimeSessionEventStreamHub()
    let receiver = RuntimeEventSinkReceiver(
        streamHub: RuntimeEventStreamHub(),
        sessionHub: previousHub
    )
    previousHub.finish()
    #expect(reopenedHub.installInitialPool(sessionTestSurfaceSet(generation: 3), surfaces: try sessionTestSurfaces()))
    receiver.replaceSessionHub(reopenedHub)
    receiver.frameReady(3, surfaceIndex: 2, frameSeq: 44, presentationTime: 55)

    var iterator = reopenedHub.stream.makeAsyncIterator()
    guard case .frameReady(let delivered)? = await iterator.next() else {
        Issue.record("The event sink should deliver frames into the reopened session hub.")
        return
    }
    #expect(delivered.message.frameSeq == 44)
    #expect(delivered.message.surfaceIndex == 2)
}

private final class CloseAcknowledgementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0

    var count: Int {
        lock.withLock { recorded }
    }

    func record() {
        lock.withLock { recorded += 1 }
    }
}

private actor ControlledSessionResizeHandler {
    struct Snapshot: Sendable {
        let maximumActiveRequests: Int
        let geometries: [DisplayGeometry]
    }

    private let sessionID: UUID
    private var activeRequests = 0
    private var maximumActiveRequests = 0
    private var geometries: [DisplayGeometry] = []
    private var didStartFirstRequest = false
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirstRequestContinuation: CheckedContinuation<Void, Never>?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    func resize(_ geometry: DisplayGeometry) async -> RuntimeSessionResizeResult {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        geometries.append(geometry)
        let generation = UInt32(geometries.count + 1)

        if geometries.count == 1 {
            didStartFirstRequest = true
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseFirstRequestContinuation = continuation
            }
        }

        activeRequests -= 1
        let descriptor = SessionDescriptor(
            sessionID: sessionID,
            displayID: 3,
            windowPrefs: WindowPrefs(zoom: geometry.zoom),
            inputPrefs: InputPrefs(),
            windowMode: .secondaryDisplay,
            state: .running,
            surfaces: SurfaceSet(
                generation: generation,
                pixelSize: PixelSize(width: 16, height: 24),
                densityDpi: 160
            )
        )
        return RuntimeSessionResizeResult(outcome: .applied, descriptor: descriptor)
    }

    func waitUntilFirstRequestStarts() async {
        guard !didStartFirstRequest else { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        releaseFirstRequestContinuation?.resume()
        releaseFirstRequestContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(maximumActiveRequests: maximumActiveRequests, geometries: geometries)
    }
}

private actor ResizeRequestStarted {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        didStart = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
