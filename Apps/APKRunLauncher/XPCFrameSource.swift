import AppKit
import Dispatch
import IOSurface
import RuntimeAPI
import RuntimeClient
import WindowingCore

/// Adapts a session's XPC frame events to WindowingCore without reading or copying IOSurface pixels.
final class XPCFrameSource: FrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private let session: RuntimeSessionClient
    private var eventTask: Task<Void, Never>?
    private let continuation: AsyncStream<FrameSourceEvent>.Continuation
    private var current: FrameSurfaceSet
    private var surfaceSets: [UInt64: FrameSurfaceSet]
    private var pendingEvents: [FrameSourceEvent] = []
    private var drainScheduled = false
    private var isStopped = false

    /// Runs on the main queue after the daemon invalidates this session endpoint.
    var onSessionInvalidated: (@MainActor () -> Void)?

    /// The frame events consumed by `SessionWindowController`.
    let frames: AsyncStream<FrameSourceEvent>

    init?(bootstrap: RuntimeSessionBootstrap) {
        session = bootstrap.session
        eventTask = nil
        guard let initial = Self.makeSurfaceSet(
            metadata: bootstrap.descriptor.surfaces,
            surfaces: bootstrap.surfaces,
            zoom: bootstrap.descriptor.windowPrefs.zoom
        ) else {
            return nil
        }
        current = initial
        surfaceSets = [initial.generation: initial]
        let stream = AsyncStream<FrameSourceEvent>.makeStream(of: FrameSourceEvent.self)
        frames = stream.stream
        continuation = stream.continuation

        let sessionEvents = bootstrap.session.events
        eventTask = Task { [weak self] in
            for await event in sessionEvents {
                self?.receive(event)
            }
        }
    }

    var currentSurfaceSet: FrameSurfaceSet {
        lock.withLock { current }
    }

    func surfaceSet(generation: UInt64) -> FrameSurfaceSet? {
        lock.withLock { surfaceSets[generation] }
    }

    var surfaces: [IOSurface] {
        currentSurfaceSet.surfaces
    }

    var generation: UInt64 {
        currentSurfaceSet.generation
    }

    var pixelWidth: Int {
        currentSurfaceSet.pixelWidth
    }

    var pixelHeight: Int {
        currentSurfaceSet.pixelHeight
    }

    /// Reports Core Animation's completion for the corresponding XPC frame.
    func frameDisplayed(generation: UInt64, sequence: UInt64) {
        guard let generation = UInt32(exactly: generation) else { return }
        session.frameDisplayed(FrameDisplayedMessage(generation: generation, frameSeq: sequence))
        lock.withLock {
            surfaceSets = surfaceSets.filter { $0.key >= UInt64(generation) }
        }
    }

    /// Stops event delivery and releases this source's surface-pool references.
    func stop() {
        eventTask?.cancel()
        eventTask = nil
        let shouldFinish = lock.withLock {
            guard !isStopped else { return false }
            isStopped = true
            pendingEvents.removeAll(keepingCapacity: false)
            surfaceSets.removeAll(keepingCapacity: false)
            return true
        }
        if shouldFinish {
            continuation.finish()
        }
    }

    private func receive(_ event: RuntimeSessionEvent) {
        switch event {
        case .frameReady(let message):
            let frameEvent = FrameSourceEvent.frameReady(
                generation: UInt64(message.generation),
                bufferIndex: message.surfaceIndex,
                sequence: message.frameSeq
            )
            enqueue(frameEvent)
        case .surfacesReplaced(let replacement, let surfaces):
            guard let surfaceSet = Self.makeSurfaceSet(
                metadata: replacement.surfaceSet,
                surfaces: surfaces,
                zoom: currentSurfaceSet.zoom
            ) else {
                return
            }
            let accepted = lock.withLock { () -> Bool in
                guard !isStopped, surfaceSet.generation > current.generation else { return false }
                current = surfaceSet
                surfaceSets = surfaceSets.filter { $0.key >= surfaceSet.generation &- 1 }
                surfaceSets[surfaceSet.generation] = surfaceSet
                return true
            }
            if accepted {
                enqueue(.surfacesReplaced(generation: surfaceSet.generation))
            }
        case .invalidated:
            stop()
            DispatchQueue.main.async { [weak self] in
                self?.onSessionInvalidated?()
            }
        }
    }

    private func enqueue(_ event: FrameSourceEvent) {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !isStopped else { return false }
            switch event {
            case .frameReady(let generation, let bufferIndex, _):
                guard let pool = surfaceSets[generation],
                    pool.surfaces.indices.contains(bufferIndex),
                    generation == current.generation
                else {
                    return false
                }
                pendingEvents.removeAll { queued in
                    if case .frameReady = queued {
                        return true
                    }
                    return false
                }
            case .surfacesReplaced(let generation):
                pendingEvents.removeAll { queued in
                    if case .frameReady(let queuedGeneration, _, _) = queued {
                        return queuedGeneration < generation
                    }
                    return false
                }
            }
            pendingEvents.append(event)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainOnMainQueue()
        }
    }

    private func drainOnMainQueue() {
        let events = lock.withLock { () -> [FrameSourceEvent] in
            drainScheduled = false
            let events = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            return events
        }
        for event in events {
            continuation.yield(event)
        }
    }

    private static func makeSurfaceSet(
        metadata: SurfaceSet,
        surfaces: [IOSurface],
        zoom: Double
    ) -> FrameSurfaceSet? {
        let pixelSize = metadata.pixelSize
        guard surfaces.count == SurfaceSet.surfaceCount,
            pixelSize.width > 0,
            pixelSize.height > 0,
            zoom.isFinite,
            zoom > 0
        else {
            return nil
        }
        let renderScale = Double(metadata.densityDpi) / (160 * zoom)
        guard renderScale.isFinite, renderScale > 0,
            surfaces.allSatisfy({
                IOSurfaceGetWidth($0) == pixelSize.width
                    && IOSurfaceGetHeight($0) == pixelSize.height
            })
        else {
            return nil
        }
        let contentSize = CGSize(
            width: Double(pixelSize.width) / renderScale,
            height: Double(pixelSize.height) / renderScale
        )
        guard contentSize.width.isFinite, contentSize.height.isFinite else {
            return nil
        }
        return FrameSurfaceSet(
            generation: UInt64(metadata.generation),
            surfaces: surfaces,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            contentSize: contentSize,
            contentsScale: CGFloat(renderScale),
            zoom: zoom
        )
    }
}

/// Reports occlusion, minimization, and application hide transitions to the session.
@MainActor
final class XPCWindowVisibilityObserver {
    private let windowTitle: String
    private let session: RuntimeSessionClient
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastVisibility: Bool?

    init(windowTitle: String, session: RuntimeSessionClient) {
        self.windowTitle = windowTitle
        self.session = session
    }

    func start() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        notificationTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.publishCurrentVisibility()
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.publishCurrentVisibility()
        }
    }

    func stop() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        publish(false)
    }

    private func publishCurrentVisibility() {
        guard let window = NSApp.windows.first(where: { $0.title == windowTitle }) else {
            publish(false)
            return
        }
        publish(
            !NSApp.isHidden
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        )
    }

    private func publish(_ visible: Bool) {
        guard lastVisibility != visible else { return }
        lastVisibility = visible
        session.visibilityChanged(VisibilityChangedMessage(visible: visible))
    }
}
