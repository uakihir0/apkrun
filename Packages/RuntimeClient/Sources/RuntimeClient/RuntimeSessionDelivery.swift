import Dispatch
@preconcurrency import Foundation
import IOSurface
import RuntimeAPI

/// One frame notification paired with the IOSurface generation it names.
///
/// Carrying the generation's surfaces with the frame lets a consumer recover if a buffered replacement
/// notification was superseded before the main queue became available.
public struct RuntimeSessionFrame: @unchecked Sendable {
    /// Frame sequence and presentation timestamp.
    public let message: FrameReady
    /// Metadata for the IOSurface generation containing the frame.
    public let surfaceSet: SurfaceSet
    /// The generation's IOSurfaces in buffer order.
    public let surfaces: [IOSurface]
    /// Window preferences that resolved the frame's display geometry.
    public let windowPrefs: WindowPrefs
}

/// A session message received from apkrund.
public enum RuntimeSessionMessage: @unchecked Sendable {
    /// One buffer is ready; includes its pool in case a replacement notice was coalesced away.
    case frameReady(RuntimeSessionFrame)
    /// A new pool generation is available.
    case surfacesReplaced(SurfacesReplaced, surfaces: [IOSurface], windowPrefs: WindowPrefs)
}

/// A non-coalesced request for the launcher to close its current window.
public struct RuntimeSessionCloseRequest: @unchecked Sendable {
    private let reply: @Sendable () -> Void

    init(reply: @escaping @Sendable () -> Void) {
        self.reply = reply
    }

    /// Confirms that the old window has closed.
    public func acknowledge() {
        reply()
    }
}

struct RuntimeSessionResizeResult: @unchecked Sendable {
    let outcome: SessionResizeOutcome
    let descriptor: SessionDescriptor?
}

/// Keeps resize replies in request order so a stale generation cannot invalidate a newer pool.
final class RuntimeSessionResizeGate: @unchecked Sendable {
    private struct WaiterCountObserver {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterCountObservers: [WaiterCountObserver] = []

    var waitingCount: Int {
        lock.withLock { waiters.count }
    }

    func waitUntilWaitingCount(atLeast minimumCount: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard waiters.count < minimumCount else { return true }
                waiterCountObservers.append(
                    WaiterCountObserver(minimumCount: minimumCount, continuation: continuation)
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func acquire() async {
        await withCheckedContinuation { continuation in
            let (shouldResume, readyObservers) = lock.withLock {
                guard isOccupied else {
                    isOccupied = true
                    return (true, [CheckedContinuation<Void, Never>]())
                }
                waiters.append(continuation)
                let ready = waiterCountObservers.filter { waiters.count >= $0.minimumCount }
                waiterCountObservers.removeAll { waiters.count >= $0.minimumCount }
                return (false, ready.map(\.continuation))
            }
            if shouldResume {
                continuation.resume()
            }
            for observer in readyObservers {
                observer.resume()
            }
        }
    }

    func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !waiters.isEmpty else {
                isOccupied = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// One opened session and its one-way controls over the authenticated control connection.
public final class RuntimeOpenedSession: @unchecked Sendable {
    private let descriptorLock = NSLock()
    private let resizeGate: RuntimeSessionResizeGate
    private var descriptorValue: SessionDescriptor
    /// The latest session metadata returned by apkrund.
    public var descriptor: SessionDescriptor {
        descriptorLock.withLock { descriptorValue }
    }
    /// The initial pool's IOSurfaces in buffer order.
    public let surfaces: [IOSurface]
    /// Coalesced frame and surface-replacement messages.
    public let messages: AsyncStream<RuntimeSessionMessage>
    /// Close requests use a separate stream so frame coalescing cannot drop takeover control.
    public let closeRequests: AsyncStream<RuntimeSessionCloseRequest>

    private let frameDisplayedHandler: @Sendable (FrameDisplayed) -> Void
    private let visibilityChangedHandler: @Sendable (VisibilityChanged) -> Void
    private let resizeHandler:
        @Sendable (DisplayGeometry) async throws(RuntimeControlClientError) -> RuntimeSessionResizeResult

    init(
        descriptor: SessionDescriptor,
        surfaces: [IOSurface],
        messages: AsyncStream<RuntimeSessionMessage>,
        closeRequests: AsyncStream<RuntimeSessionCloseRequest>,
        frameDisplayed: @escaping @Sendable (FrameDisplayed) -> Void,
        visibilityChanged: @escaping @Sendable (VisibilityChanged) -> Void,
        resize:
            @escaping @Sendable (DisplayGeometry) async throws(RuntimeControlClientError)
            -> RuntimeSessionResizeResult,
        resizeGate: RuntimeSessionResizeGate = RuntimeSessionResizeGate()
    ) {
        descriptorValue = descriptor
        self.resizeGate = resizeGate
        self.surfaces = surfaces
        self.messages = messages
        self.closeRequests = closeRequests
        frameDisplayedHandler = frameDisplayed
        visibilityChangedHandler = visibilityChanged
        resizeHandler = resize
    }

    /// Acknowledges a frame after Core Animation commits its IOSurface.
    public func frameDisplayed(_ message: FrameDisplayed) {
        frameDisplayedHandler(message)
    }

    /// Updates the runtime when the app window becomes visible or hidden.
    public func visibilityChanged(_ message: VisibilityChanged) {
        visibilityChangedHandler(message)
    }

    /// Requests a display-mode change for this session.
    public func resize(_ geometry: DisplayGeometry) async throws(RuntimeControlClientError) -> SessionResizeOutcome {
        await resizeGate.acquire()
        defer { resizeGate.release() }
        guard !Task.isCancelled else {
            throw .requestCancelled(operation: "sessionResize")
        }
        let result = try await resizeHandler(geometry)
        if let descriptor = result.descriptor {
            descriptorLock.withLock {
                descriptorValue = descriptor
            }
        }
        return result.outcome
    }
}

/// Retains the current surface pool and the previous pool until its first replacement ACK or one-second deadline.
final class RuntimeSessionEventStreamHub: @unchecked Sendable {
    private struct Pool {
        let metadata: SurfaceSet
        let surfaces: [IOSurface]
        let windowPrefs: WindowPrefs
    }

    private let lock = NSLock()
    private let continuation: AsyncStream<RuntimeSessionMessage>.Continuation
    private let closeRequestContinuation: AsyncStream<RuntimeSessionCloseRequest>.Continuation
    let stream: AsyncStream<RuntimeSessionMessage>
    let closeRequests: AsyncStream<RuntimeSessionCloseRequest>
    private var pools: [UInt32: Pool] = [:]
    private var currentGeneration: UInt32?
    private var pendingFrame: FrameReady?
    private var pendingReplacement: Pool?
    private var didInstallInitialPool = false

    init() {
        let pair = AsyncStream<RuntimeSessionMessage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
        let closeRequests = AsyncStream<RuntimeSessionCloseRequest>.makeStream()
        self.closeRequests = closeRequests.stream
        closeRequestContinuation = closeRequests.continuation
    }

    func installInitialPool(
        _ metadata: SurfaceSet,
        surfaces: [IOSurface],
        windowPrefs: WindowPrefs = WindowPrefs()
    ) -> Bool {
        lock.withLock {
            guard metadata.surfaceCount == SurfaceSet.requiredSurfaceCount,
                surfaces.count == SurfaceSet.requiredSurfaceCount,
                !didInstallInitialPool
            else {
                return false
            }
            pools[metadata.generation] = Pool(metadata: metadata, surfaces: surfaces, windowPrefs: windowPrefs)
            currentGeneration = metadata.generation
            didInstallInitialPool = true

            if let pendingReplacement,
                pendingReplacement.metadata.generation > metadata.generation
            {
                pools[pendingReplacement.metadata.generation] = pendingReplacement
                currentGeneration = pendingReplacement.metadata.generation
                continuation.yield(
                    .surfacesReplaced(
                        SurfacesReplaced(surfaceSet: pendingReplacement.metadata),
                        surfaces: pendingReplacement.surfaces,
                        windowPrefs: pendingReplacement.windowPrefs
                    )
                )
                self.pendingReplacement = nil
            }

            let installedGeneration = self.currentGeneration ?? metadata.generation
            if let pendingFrame, pendingFrame.generation == installedGeneration {
                deliverFrameLocked(pendingFrame)
                self.pendingFrame = nil
            } else if let pendingFrame, pendingFrame.generation < installedGeneration {
                self.pendingFrame = nil
            }
            return true
        }
    }

    func receiveFrame(_ message: FrameReady) {
        lock.withLock {
            guard didInstallInitialPool, let currentGeneration else {
                rememberPendingFrameLocked(message)
                return
            }
            guard message.generation >= currentGeneration else { return }
            guard message.generation == currentGeneration else {
                rememberPendingFrameLocked(message)
                return
            }
            if let pendingFrame, pendingFrame.generation == currentGeneration {
                let newest = pendingFrame.frameSeq > message.frameSeq ? pendingFrame : message
                deliverFrameLocked(newest)
                self.pendingFrame = nil
                return
            }
            deliverFrameLocked(message)
        }
    }

    func receiveSurfaceReplacement(_ metadata: SurfaceSet, surfaces: [IOSurface]) {
        let installedGeneration = lock.withLock { () -> UInt32? in
            guard metadata.surfaceCount == SurfaceSet.requiredSurfaceCount,
                surfaces.count == SurfaceSet.requiredSurfaceCount
            else {
                return nil
            }
            let windowPrefs = currentGeneration.flatMap { pools[$0]?.windowPrefs } ?? WindowPrefs()
            let replacement = Pool(metadata: metadata, surfaces: surfaces, windowPrefs: windowPrefs)
            guard didInstallInitialPool else {
                guard metadata.generation > (pendingReplacement?.metadata.generation ?? 0) else {
                    return nil
                }
                pendingReplacement = replacement
                return metadata.generation
            }
            guard metadata.generation > (currentGeneration ?? 0) else {
                return nil
            }

            pools[metadata.generation] = replacement
            currentGeneration = metadata.generation
            continuation.yield(
                .surfacesReplaced(
                    SurfacesReplaced(surfaceSet: metadata),
                    surfaces: replacement.surfaces,
                    windowPrefs: replacement.windowPrefs
                )
            )
            if let pendingFrame, pendingFrame.generation == metadata.generation {
                deliverFrameLocked(pendingFrame)
                self.pendingFrame = nil
            } else if let pendingFrame, pendingFrame.generation < metadata.generation {
                self.pendingFrame = nil
            }
            return metadata.generation
        }
        guard let installedGeneration else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            self?.releasePools(olderThan: installedGeneration)
        }
    }

    func installResizedPool(
        _ metadata: SurfaceSet,
        surfaces: [IOSurface],
        windowPrefs: WindowPrefs
    ) -> Bool {
        guard metadata.surfaceCount == SurfaceSet.requiredSurfaceCount,
            surfaces.count == SurfaceSet.requiredSurfaceCount
        else {
            return false
        }
        let installed = lock.withLock { () -> Bool in
            guard didInstallInitialPool,
                let currentGeneration,
                metadata.generation > currentGeneration
            else {
                return false
            }
            let replacement = Pool(metadata: metadata, surfaces: surfaces, windowPrefs: windowPrefs)
            pools[metadata.generation] = replacement
            self.currentGeneration = metadata.generation
            continuation.yield(
                .surfacesReplaced(
                    SurfacesReplaced(surfaceSet: metadata),
                    surfaces: surfaces,
                    windowPrefs: windowPrefs
                )
            )
            if let pendingFrame, pendingFrame.generation == metadata.generation {
                deliverFrameLocked(pendingFrame)
                self.pendingFrame = nil
            } else if let pendingFrame, pendingFrame.generation < metadata.generation {
                self.pendingFrame = nil
            }
            return true
        }
        guard installed else { return false }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            self?.releasePools(olderThan: metadata.generation)
        }
        return true
    }

    func receiveCloseRequest(acknowledge: @escaping @Sendable () -> Void) {
        closeRequestContinuation.yield(RuntimeSessionCloseRequest(reply: acknowledge))
    }

    func finish() {
        continuation.finish()
        closeRequestContinuation.finish()
    }

    func acknowledge(_ message: FrameDisplayed) {
        releasePools(olderThan: message.generation)
    }

    func retainedGenerations() -> Set<UInt32> {
        lock.withLock { Set(pools.keys) }
    }

    private func deliverFrameLocked(_ message: FrameReady) {
        guard let pool = pools[message.generation],
            pool.surfaces.indices.contains(message.surfaceIndex)
        else {
            return
        }
        continuation.yield(
            .frameReady(
                RuntimeSessionFrame(
                    message: message,
                    surfaceSet: pool.metadata,
                    surfaces: pool.surfaces,
                    windowPrefs: pool.windowPrefs
                )
            )
        )
    }

    private func rememberPendingFrameLocked(_ message: FrameReady) {
        guard let pendingFrame else {
            self.pendingFrame = message
            return
        }
        if message.generation > pendingFrame.generation
            || (message.generation == pendingFrame.generation && message.frameSeq > pendingFrame.frameSeq)
        {
            self.pendingFrame = message
        }
    }

    private func releasePools(olderThan generation: UInt32) {
        lock.withLock {
            pools = pools.filter { $0.key >= generation }
        }
    }
}
