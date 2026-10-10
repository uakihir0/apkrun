import DiagnosticsCore
import Foundation
import VirtioDeviceCore

/// A capset that the device answers from its cache (graphics.md §4.2).
struct VirGLCapset: Equatable, Sendable {
    let id: UInt32
    let version: UInt32
    let bytes: [UInt8]
}

/// Counts the renderer operations that failed, and logs each one. The guest is not told (IR-460).
final class RendererFailureLog: @unchecked Sendable {
    private let logger = APKLogger(category: GraphicsLogCategory.device)
    private let lock = NSLock()
    private var count: UInt64 = 0

    /// The number of failures recorded so far.
    var total: UInt64 {
        lock.withLock { count }
    }

    func record(_ failure: GraphicsFailure) {
        lock.withLock { count += 1 }
        logger.error(
            "virtio-gpu renderer operation failed: \(failure.code, .public)",
            errorCode: failure.qualifiedCode
        )
    }
}

/// The renderer side of the virtio-gpu device: the render thread, the engine that it owns,
/// the cached capsets, and the queue of elements that wait for execution or a fence
/// (graphics.md §4.5, §4.7, §5.2).
///
/// The device queue never touches the engine. It submits operations, which run on the
/// render thread in order. The engine is created on that thread, before the VM starts, so
/// a renderer failure is reported before Android boots (graphics.md §8).
final class VirGLBackend: @unchecked Sendable {
    /// Holds the engine. Only the render thread reads or writes it.
    final class EngineBox: @unchecked Sendable {
        // UNCHECKED-SENDABLE: confined to the render thread. Every access runs in a render-thread closure.
        var engine: (any VirGLEngine)?
    }

    /// The capsets this device offers, in the order of `GET_CAPSET_INFO` indices.
    static let capsetIDs: [UInt32] = [GraphicsCapset.virgl, GraphicsCapset.virgl2]

    private let renderThread: RenderThread
    private let engineBox: EngineBox
    private let completions: ControlCompletionQueue<PendingElementCompletionToken>
    private let capsetsByID: [UInt32: VirGLCapset]
    /// Shared with the render-thread closures, which must not capture the backend itself.
    private let failures = RendererFailureLog()
    private let stateLock = NSLock()
    private var isShutDown = false

    /// The capsets, in `GET_CAPSET_INFO` index order.
    var capsets: [VirGLCapset] {
        Self.capsetIDs.compactMap { capsetsByID[$0] }
    }

    /// The number of renderer operations that failed.
    var rendererFailures: UInt64 {
        failures.total
    }

    private init(
        renderThread: RenderThread,
        engineBox: EngineBox,
        completions: ControlCompletionQueue<PendingElementCompletionToken>,
        capsetsByID: [UInt32: VirGLCapset]
    ) {
        self.renderThread = renderThread
        self.engineBox = engineBox
        self.completions = completions
        self.capsetsByID = capsetsByID
    }

    deinit {
        shutdown()
    }

    /// Starts the render thread, creates the engine on it, and caches the capsets.
    ///
    /// - Parameter makeEngine: Creates the engine on the render thread. It receives the
    ///   callback that the engine calls for each fence it completes.
    static func make(
        name: String,
        makeEngine:
            @escaping @Sendable (@escaping @Sendable (UInt32) -> Void) throws(GraphicsFailure) -> any VirGLEngine
    ) throws(GraphicsFailure) -> VirGLBackend {
        let renderThread = RenderThread(name: name)
        let completions = ControlCompletionQueue<PendingElementCompletionToken>()
        let engineBox = EngineBox()
        renderThread.start()

        let created: Result<[UInt32: VirGLCapset], GraphicsFailure>? = renderThread.sync {
            let onFence: @Sendable (UInt32) -> Void = { fence in
                completions.recordCompletedFence(fence)
            }
            do throws(GraphicsFailure) {
                let engine = try makeEngine(onFence)
                engineBox.engine = engine
                var capsets: [UInt32: VirGLCapset] = [:]
                for id in VirGLBackend.capsetIDs {
                    let info = try engine.capsetInfo(id: id)
                    var bytes = [UInt8](repeating: 0, count: Int(info.maxSizeBytes))
                    try engine.fillCapset(id: id, version: info.maxVersion, into: &bytes)
                    capsets[id] = VirGLCapset(id: id, version: info.maxVersion, bytes: bytes)
                }
                return .success(capsets)
            } catch {
                return .failure(error)
            }
        }
        guard let created else {
            renderThread.stop()
            throw GraphicsFailure.rendererOperationFailed(
                operation: "start",
                detail: "The render thread did not run the renderer creation."
            )
        }
        switch created {
        case .failure(let failure):
            // A capset that is missing after the engine exists must still destroy it, or the next renderer
            // in this process would be refused: virglrenderer admits one instance at a time (graphics.md §5.2).
            _ = renderThread.sync { () -> Bool in
                if let engine = engineBox.engine {
                    try? engine.destroy()
                }
                engineBox.engine = nil
                return true
            }
            renderThread.stop()
            throw failure
        case .success(let capsets):
            renderThread.setPollHandler {
                // Poll, then complete the elements that the poll made ready, in order.
                engineBox.engine?.poll()
                for token in completions.drainReady() {
                    token.complete()
                }
                return completions.isWaitingForFence
            }
            return VirGLBackend(
                renderThread: renderThread,
                engineBox: engineBox,
                completions: completions,
                capsetsByID: capsets
            )
        }
    }

    /// The fence number that virglrenderer takes for a guest fence ID, or `nil` when the ID does not fit in 32 bits.
    static func fenceNumber(_ fenceID: UInt64) -> UInt32? {
        UInt32(exactly: fenceID)
    }

    /// True when some element is still waiting, so a new response must wait its turn.
    var hasWaitingElements: Bool {
        !completions.isEmpty
    }

    /// Queues a response that needs no renderer work behind the waiting elements. It completes at its turn.
    func appendExecuted(_ token: PendingElementCompletionToken) {
        _ = completions.append(token, executed: true)
        let completions = self.completions
        renderThread.submit {
            for ready in completions.drainReady() {
                ready.complete()
            }
        }
    }

    /// Runs `operation` on the render thread after the work already queued. It then creates `fence`, if one is
    /// given, and completes the element once it reaches the head of the queue and its fence has completed.
    ///
    /// A failure from `operation`, or from the fence creation, is counted and logged. The guest's response does
    /// not change. A fence that cannot be created completes at once, so the queue cannot wait on it forever.
    func execute(
        token: PendingElementCompletionToken,
        fence: UInt32?,
        context: UInt32,
        operation: @escaping @Sendable (any VirGLEngine) -> GraphicsFailure?
    ) {
        let ticket = completions.append(token, executed: false)
        let completions = self.completions
        let engineBox = self.engineBox
        let failures = self.failures
        let renderThread = self.renderThread
        renderThread.submit {
            var fenceForQueue = fence
            if let engine = engineBox.engine {
                if let failure = operation(engine) {
                    failures.record(failure)
                }
                if let fence {
                    do throws(GraphicsFailure) {
                        try engine.createFence(id: fence, context: context)
                    } catch {
                        failures.record(error)
                        fenceForQueue = nil
                    }
                }
            }
            let ready = completions.markExecuted(ticket, fence: fenceForQueue)
            if fenceForQueue != nil {
                renderThread.requestPolling()
            }
            for token in ready {
                token.complete()
            }
        }
    }

    /// Runs `body` on the render thread and waits for its result. Returns `nil` once the engine is gone.
    func sync<T: Sendable>(_ body: @escaping @Sendable (any VirGLEngine) -> T) -> T? {
        let engineBox = self.engineBox
        let result: T?? = renderThread.sync { () -> T? in
            guard let engine = engineBox.engine else { return nil }
            return body(engine)
        }
        return result ?? nil
    }

    /// Resets the renderer. Every waiting element is returned, because the guest reset and no longer waits.
    func reset() {
        let engineBox = self.engineBox
        let completions = self.completions
        let failures = self.failures
        _ = renderThread.sync { () -> Bool in
            if let engine = engineBox.engine {
                do throws(GraphicsFailure) {
                    try engine.reset()
                } catch {
                    failures.record(error)
                }
            }
            for token in completions.removeAll() {
                token.complete()
            }
            return true
        }
    }

    /// Destroys the engine and stops the render thread. Every waiting element is returned. Calling it again does nothing.
    func shutdown() {
        let alreadyStopped = stateLock.withLock { () -> Bool in
            let stopped = isShutDown
            isShutDown = true
            return stopped
        }
        guard !alreadyStopped else { return }
        let engineBox = self.engineBox
        let completions = self.completions
        let failures = self.failures
        _ = renderThread.sync { () -> Bool in
            for token in completions.removeAll() {
                token.complete()
            }
            if let engine = engineBox.engine {
                do throws(GraphicsFailure) {
                    try engine.destroy()
                } catch {
                    failures.record(error)
                }
            }
            engineBox.engine = nil
            return true
        }
        renderThread.stop()
    }
}
