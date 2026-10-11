import DiagnosticsCore
import Dispatch
import Foundation
import IOSurface

/// The statistics of one presenter (graphics.md §7).
public struct PresentStatistics: Equatable, Sendable {
    /// Frames the GPU has finished blitting, which the consumer may show (`frameReady`).
    public var framesPresented: UInt64 = 0
    /// Frames replaced before they were presented (`droppedFrames`).
    public var droppedFrames: UInt64 = 0
    /// Waits on a blit fence that exceeded the 100 ms stall timeout (graphics.md §6.2 step 4).
    public var presentStalls: UInt64 = 0
    /// Blits that the GPU or the bridge failed. The frame is not offered, and the buffer is free again.
    public var failedBlits: UInt64 = 0

    /// Creates zeroed statistics.
    public init() {}
}

/// A frame whose blit has finished, so the consumer may show buffer `bufferIndex` of `generation`.
public enum ScanoutFrame: Equatable, Sendable {
    case frameReady(generation: UInt64, bufferIndex: Int, sequence: UInt64)
}

/// Presents one scanout into a pool of IOSurfaces (graphics.md §6.1 to §6.3, #023).
///
/// A flush of the resource bound to the scanout becomes one blit into a free buffer. Only one blit is in flight at a
/// time, and the newest flush that waits replaces the older one (latest frame wins). A serial waiter waits on the
/// fence of each blit. When the fence signals, the buffer is offered and `frameReady` is emitted. The consumer reports
/// `frameDisplayed`, which makes the older buffers reusable. The blit only copies on the GPU, so a frame never passes
/// through host memory.
public final class ScanoutPresenter: @unchecked Sendable {
    /// The stall timeout of the completion waiter (graphics.md §6.2 step 4).
    static let stallTimeoutNanoseconds: UInt64 = 100_000_000
    /// The pause between two polls of a blit fence.
    private static let pollIntervalSeconds: TimeInterval = 0.001
    /// How long `close()` waits for the waiter before it proceeds. The waiter stops within one poll of `close()`.
    private static let closeWaitSeconds: Int = 2

    /// The scanout that the presenter shows.
    public let scanout: ScanoutID
    /// The width of each buffer in pixels.
    public let pixelWidth: Int
    /// The height of each buffer in pixels.
    public let pixelHeight: Int
    /// The IOSurfaces of the pool, in buffer order. The consumer reads them and never writes them.
    public let surfaces: [IOSurface]
    /// The frames that are ready to show. The stream keeps the newest eight, since only the latest frame matters.
    public let frames: AsyncStream<ScanoutFrame>

    private let continuation: AsyncStream<ScanoutFrame>.Continuation
    private let backend: VirGLBackend
    private let pool: SurfacePool
    /// The present target of each buffer, created on the render thread. Read on the device queue and the waiter.
    private let targets: [any PresentTarget]
    private let lock = NSLock()
    private var scheduler = LatestFrameScheduler<PresentRequest>()
    private var nextSequence: UInt64 = 1
    private var statisticsValue = PresentStatistics()
    private var isClosed = false
    private let waiter = DispatchQueue(label: "io.apkrun.graphics.present-waiter")
    private let waits = DispatchGroup()
    private let logger = APKLogger(category: GraphicsLogCategory.present)

    /// Creates a presenter of `width` x `height` pixels, with its three IOSurfaces and their present targets.
    ///
    /// The targets are made on the render thread. The call fails when a surface or a target cannot be made.
    init(scanout: ScanoutID, width: Int, height: Int, backend: VirGLBackend) throws(GraphicsFailure) {
        guard width > 0, height > 0, width <= 4095, height <= 4095 else {
            throw .modeUnsupported(
                mode: DisplayMode(widthPixels: width, heightPixels: height, refreshHz: 60, dotsPerInch: 160))
        }
        guard let pool = SurfacePool.make(pixelWidth: width, pixelHeight: height) else {
            throw .rendererOperationFailed(
                operation: "presentPoolCreate",
                detail: "IOSurface refused a \(width)x\(height) BGRA surface."
            )
        }
        let surfaces = SurfaceList(surfaces: pool.surfaces)
        let made: Result<[any PresentTarget], GraphicsFailure>? = backend.sync { engine in
            var targets: [any PresentTarget] = []
            for surface in surfaces.surfaces {
                do throws(GraphicsFailure) {
                    targets.append(
                        try engine.createPresentTarget(
                            surface: surface,
                            width: UInt32(width),
                            height: UInt32(height)
                        )
                    )
                } catch {
                    for target in targets {
                        engine.destroyPresentTarget(target)
                    }
                    return .failure(error)
                }
            }
            return .success(targets)
        }
        guard let made else {
            throw .rendererOperationFailed(operation: "presentTargetCreate", detail: "The renderer is not running.")
        }
        let targets = try made.get()

        self.scanout = scanout
        self.pixelWidth = width
        self.pixelHeight = height
        self.surfaces = pool.surfaces
        self.pool = pool
        self.targets = targets
        self.backend = backend
        let (stream, continuation) = AsyncStream<ScanoutFrame>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.frames = stream
        self.continuation = continuation
        logger.info(
            "present scanout \(scanout.rawValue, .public) attached: \(width, .public)x\(height, .public), \(targets.count, .public) buffers"
        )
    }

    /// The generation of the pool. It is fixed for the life of the presenter, because #023 has no reallocation.
    public var generation: UInt64 {
        pool.generation
    }

    /// The statistics so far.
    public var statistics: PresentStatistics {
        lock.withLock { statisticsValue }
    }

    /// The device queue asks for a present of `resource` through `source`, the scanout rectangle of SET_SCANOUT.
    ///
    /// Returns the render work that runs the blit, or `nil` when the frame is held. A held frame is replaced by a newer
    /// one, or started when a blit completes or a buffer is displayed. The flush completes at once in both cases,
    /// because the guest's vsync paces it, not the host (graphics.md §6.2 step 3).
    func flush(resource: UInt32, source: VirtioGPURect) -> VirGLRenderWork? {
        lock.withLock {
            guard !isClosed else { return nil }
            let request = PresentRequest(resource: resource, source: source)
            guard let runnable = scheduler.submit(request) else {
                return nil
            }
            if let work = startBlitLocked(runnable) {
                return work
            }
            scheduler.hold(runnable)
            return nil
        }
    }

    /// The consumer displayed frame `sequence` (display-and-windowing.md §5.2, rule 2). Older buffers become reusable,
    /// and a held flush starts when a buffer is free.
    public func frameDisplayed(upTo sequence: UInt64) {
        let work = lock.withLock { () -> VirGLRenderWork? in
            pool.consumerDisplayed(upTo: sequence)
            return startPendingLocked()
        }
        if let work {
            backend.submitRenderWork(work)
        }
    }

    /// The guest reset. The held flush names a resource that the reset unbound, so it is discarded.
    func guestReset() {
        lock.withLock {
            scheduler.discardPending()
        }
    }

    /// Stops presenting and releases the targets. The device calls it before the renderer is destroyed. Calling it
    /// again does nothing.
    public func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            isClosed = true
            scheduler.discardPending()
            continuation.finish()
            return true
        }
        guard shouldClose else { return }
        if waits.wait(timeout: .now() + .seconds(Self.closeWaitSeconds)) == .timedOut {
            logger.warning("present waiter did not return within \(Self.closeWaitSeconds, .public) s of close")
        }
        let targets = targets
        _ = backend.sync { engine in
            for target in targets {
                engine.destroyPresentTarget(target)
            }
        }
    }

    // MARK: - Blit

    /// Starts a blit of `request` into a free buffer, and returns the render work for it. Returns `nil` when no buffer
    /// is free. The caller holds the lock.
    private func startBlitLocked(_ request: PresentRequest) -> VirGLRenderWork? {
        guard let index = pool.acquire() else {
            return nil
        }
        let sequence = nextSequence
        nextSequence &+= 1
        scheduler.beginBlit()
        let target = targets[index]
        return { [self] engine in
            do throws(GraphicsFailure) {
                let fence = try engine.presentBlit(
                    resource: request.resource,
                    sourceRect: request.source,
                    into: target
                )
                self.blitSubmitted(fence, index: index, sequence: sequence)
                return nil
            } catch {
                self.blitFailed(index: index)
                return error
            }
        }
    }

    /// Starts the held flush, if one is waiting and a buffer is free. The caller holds the lock.
    private func startPendingLocked() -> VirGLRenderWork? {
        guard !isClosed, let request = scheduler.takePending() else {
            return nil
        }
        if let work = startBlitLocked(request) {
            return work
        }
        scheduler.hold(request)
        return nil
    }

    /// Hands the fence of a submitted blit to the waiter. Runs on the render thread.
    private func blitSubmitted(_ fence: any PresentFence, index: Int, sequence: UInt64) {
        waits.enter()
        waiter.async { [self] in
            let outcome = awaitFence(fence)
            // The fence is released on the render thread, which owns the renderer's EGL state.
            _ = backend.sync { _ in fence.release() }
            if outcome == .signaled {
                blitCompleted(index: index, sequence: sequence)
            } else {
                blitFailed(index: index)
            }
            waits.leave()
        }
    }

    /// Polls the fence on the render thread until it signals (graphics.md §6.2 step 4). An unsignaled poll is retried
    /// after one millisecond. Every 100 ms without a signal is a stall: it is counted and logged, and the wait goes on.
    /// Only `close()` stops the wait early.
    private func awaitFence(_ fence: any PresentFence) -> PresentWaitOutcome {
        let started = DispatchTime.now().uptimeNanoseconds
        var stalls: UInt64 = 0
        while true {
            let outcome = backend.sync { _ in fence.poll() } ?? .failed
            guard outcome == .timedOut else {
                return outcome
            }
            let closing = lock.withLock { isClosed }
            if closing {
                return .failed
            }
            let waited = DispatchTime.now().uptimeNanoseconds &- started
            if waited >= (stalls &+ 1) &* Self.stallTimeoutNanoseconds {
                stalls &+= 1
                lock.withLock { statisticsValue.presentStalls &+= 1 }
                logger.warning("present blit has not finished after \(stalls, .public) x 100 ms")
            }
            Thread.sleep(forTimeInterval: Self.pollIntervalSeconds)
        }
    }

    /// The blit of `index` finished on the GPU: the buffer is offered, and `frameReady` is emitted.
    private func blitCompleted(index: Int, sequence: UInt64) {
        let work = lock.withLock { () -> VirGLRenderWork? in
            pool.markReady(index, sequence: sequence)
            scheduler.endBlit()
            statisticsValue.framesPresented &+= 1
            statisticsValue.droppedFrames = scheduler.droppedFrames
            continuation.yield(.frameReady(generation: pool.generation, bufferIndex: index, sequence: sequence))
            return startPendingLocked()
        }
        if let work {
            backend.submitRenderWork(work)
        }
    }

    /// The blit of `index` failed, so the buffer is free again and no frame is offered.
    private func blitFailed(index: Int) {
        let work = lock.withLock { () -> VirGLRenderWork? in
            pool.abandon(index)
            scheduler.endBlit()
            statisticsValue.failedBlits &+= 1
            return startPendingLocked()
        }
        if let work {
            backend.submitRenderWork(work)
        }
    }
}

/// A flush's request for one blit. The guest's resource and the scanout rectangle of SET_SCANOUT.
struct PresentRequest: Equatable, Sendable {
    let resource: UInt32
    let source: VirtioGPURect
}

/// Carries the IOSurfaces into the render-thread closure, which only reads their identity.
// UNCHECKED-SENDABLE: the surfaces are created once and never mutated, and the render thread only passes them to the
// bridge while the presenter is alive.
private struct SurfaceList: @unchecked Sendable {
    let surfaces: [IOSurface]
}
