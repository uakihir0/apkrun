import DiagnosticsCore
import Dispatch
import Foundation
import VirtioDeviceCore

// UNCHECKED-SENDABLE: mutable state is guarded by `lock`; queue callbacks run on the device queue.
/// The virtio-gpu device model: the control and cursor queues, the configuration
/// space, `GET_DISPLAY_INFO`, `GET_EDID`, the 2D and 3D commands of the device's
/// path, error responses, and display change events
/// ([graphics.md](../../../../../docs/02-design/graphics.md) §4, §9).
///
/// VZ calls the model callbacks on the device queue. Host calls such as
/// ``enableScanout(_:mode:)`` may come from any thread, so all mutable state is
/// guarded by `lock`. Configuration updates are asynchronous, so a single writer
/// task applies the newest `events_read` value, and a stale generation's writer
/// exits without touching state. This device has no renderer, so it offers
/// `VIRTIO_GPU_F_EDID` only and reports no capsets.
public final class VirtioGPUDevice: VirtioDeviceModel, @unchecked Sendable {
    /// One request and the response it received, for golden-vector capture.
    public struct TraceRecord: Equatable, Sendable {
        /// The queue the element came from: 0 for controlq, 1 for cursorq.
        public let queueIndex: Int
        /// The request bytes copied from the element.
        public let request: [UInt8]
        /// The bytes written to the element, or `nil` when the element got no response.
        public let response: [UInt8]?

        /// Creates a trace record.
        public init(queueIndex: Int, request: [UInt8], response: [UInt8]?) {
            self.queueIndex = queueIndex
            self.request = request
            self.response = response
        }
    }

    /// The device identity, features, queues, and the 16-byte configuration space.
    public let descriptor: VirtioDeviceDescriptor

    private let logger: APKLogger
    private let clock: @Sendable () -> UInt64
    private let traceObserver: (@Sendable (TraceRecord) -> Void)?
    private let lock = NSLock()
    private var scanouts: ScanoutTable
    /// The display generation that the last `GET_DISPLAY_INFO` answered.
    private var reportedGeneration: UInt64
    private var negotiatedEDID = false
    /// The `events_read` value the device wants the guest to see.
    private var eventsReadDesired: UInt32 = 0
    /// The `events_read` value the last successful configuration update wrote.
    private var eventsReadWritten: UInt32 = 0
    private var configurationUpdater: VirtioDeviceConfigurationUpdater?
    /// Bumped on every DRIVER_OK, reset, and stop, so an old writer cannot change new state.
    private var writerEpoch: UInt64 = 0
    private var isWriterRunning = false
    private var writerTask: Task<Void, Never>?
    private var errorLimiter = GuestErrorRateLimiter()
    /// The R-01 spike delay, or `nil`. It is set only for development guests.
    private let hotplugSpikeDelay: Duration?
    private var isHotplugSpikeScheduled = false
    /// The renderer of the `drmVirgl` path, or `nil` for the paths without one.
    private let backend: VirGLBackend?
    /// The guest's 2D and 3D state. Only the device queue reads or writes it.
    private let session: GuestGPUSession
    private let counters = GraphicsCounterBox()
    /// The number of capsets in the configuration space: 2 with VirGL, 0 otherwise.
    private let capsetCount: UInt32

    /// Runs after the `GET_DISPLAY_INFO` snapshot and before the `events_read` decision.
    /// Tests use it to make a host change arrive while a query is in flight.
    package var displayInfoSnapshotHook: (@Sendable () -> Void)?

    /// Creates the device.
    ///
    /// - Parameters:
    ///   - scanouts: The host's scanout table. Scanout 0 is enabled at the test mode by default.
    ///   - logger: Logger for the `io.apkrun.graphics` `device` category.
    ///   - clock: A monotonic clock in nanoseconds, used by the guest-error rate limiter.
    ///   - traceObserver: Receives every request and response, for capturing golden vectors.
    ///   - hotplugSpikeDelay: For the R-01 spike only. After the first DRIVER_OK, scanout 1 is
    ///     enabled after this delay, so a development guest can see whether `events_read`
    ///     raises a config-change interrupt (graphics.md §4.3). `nil` in every other build.
    public convenience init(
        scanouts: ScanoutTable = ScanoutTable(),
        logger: APKLogger = APKLogger(category: GraphicsLogCategory.device),
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        traceObserver: (@Sendable (TraceRecord) -> Void)? = nil,
        hotplugSpikeDelay: Duration? = nil
    ) {
        self.init(
            path: .edidOnly,
            backend: nil,
            scanouts: scanouts,
            logger: logger,
            clock: clock,
            traceObserver: traceObserver,
            hotplugSpikeDelay: hotplugSpikeDelay
        )
    }

    /// The device of the `guestSwiftshader` profile: EDID and host-memory 2D resources, with no renderer (graphics.md §9).
    public static func twoDimensional(
        scanouts: ScanoutTable = ScanoutTable(),
        logger: APKLogger = APKLogger(category: GraphicsLogCategory.device),
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> VirtioGPUDevice {
        VirtioGPUDevice(
            path: .twoD,
            backend: nil,
            scanouts: scanouts,
            logger: logger,
            clock: clock,
            traceObserver: nil,
            hotplugSpikeDelay: nil
        )
    }

    /// The device of the `drmVirgl` profile. It starts the render thread and creates virglrenderer on it, so a renderer
    /// failure is reported here, before the VM starts (graphics.md §8). It offers `VIRTIO_GPU_F_VIRGL` and two capsets.
    public static func virgl(
        scanouts: ScanoutTable = ScanoutTable(),
        logger: APKLogger = APKLogger(category: GraphicsLogCategory.device),
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws(GraphicsFailure) -> VirtioGPUDevice {
        let backend = try VirGLBackend.make(name: "io.apkrun.graphics.render") { onFence throws(GraphicsFailure) in
            try VirGLRenderer(onFenceCompleted: onFence)
        }
        return VirtioGPUDevice(
            path: .virgl,
            backend: backend,
            scanouts: scanouts,
            logger: logger,
            clock: clock,
            traceObserver: nil,
            hotplugSpikeDelay: nil
        )
    }

    /// The device of the `drmVirgl` path with a caller-supplied engine. Tests use it to run the device logic without Metal.
    static func makeVirgl(
        scanouts: ScanoutTable = ScanoutTable(),
        logger: APKLogger = APKLogger(category: GraphicsLogCategory.device),
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        engine makeEngine: @escaping @Sendable (@escaping @Sendable (UInt32) -> Void) throws(GraphicsFailure) -> any VirGLEngine
    ) throws(GraphicsFailure) -> VirtioGPUDevice {
        let backend = try VirGLBackend.make(name: "io.apkrun.graphics.test-render", makeEngine: makeEngine)
        return VirtioGPUDevice(
            path: .virgl,
            backend: backend,
            scanouts: scanouts,
            logger: logger,
            clock: clock,
            traceObserver: nil,
            hotplugSpikeDelay: nil
        )
    }

    private init(
        path: GuestGPUSession.Path,
        backend: VirGLBackend?,
        scanouts: ScanoutTable,
        logger: APKLogger,
        clock: @escaping @Sendable () -> UInt64,
        traceObserver: (@Sendable (TraceRecord) -> Void)?,
        hotplugSpikeDelay: Duration?
    ) {
        self.scanouts = scanouts
        self.reportedGeneration = scanouts.displayGeneration
        self.logger = logger
        self.clock = clock
        self.traceObserver = traceObserver
        self.hotplugSpikeDelay = hotplugSpikeDelay
        self.backend = backend
        session = GuestGPUSession(path: path, backend: backend, counters: counters)
        capsetCount = backend == nil ? 0 : UInt32(VirGLBackend.capsetIDs.count)
        var features = VirtioGPUProtocol.Feature.edid
        if backend != nil {
            features |= VirtioGPUProtocol.Feature.virgl
        }
        descriptor = VirtioDeviceDescriptor(
            name: "virtio-gpu",
            deviceID: VirtioGPUProtocol.deviceID,
            pciClass: VirtioGPUProtocol.pciClass,
            pciSubclass: VirtioGPUProtocol.pciSubclass,
            queueCount: VirtioGPUProtocol.queueCount,
            mandatoryFeatures: 0,
            optionalFeatures: features,
            configurationSpace: VirtioGPUDevice.configurationSpace(
                eventsRead: 0,
                capsetCount: backend == nil ? 0 : UInt32(VirGLBackend.capsetIDs.count)
            )
        )
    }

    /// The configuration bytes of `virtio_gpu_config`: `events_read`, `events_clear`,
    /// `num_scanouts`, and `num_capsets`, all little-endian.
    static func configurationSpace(eventsRead: UInt32, capsetCount: UInt32 = 0) -> Data {
        var writer = VirtioGPUWireWriter(capacity: VirtioGPUProtocol.configurationByteCount)
        writer.writeUInt32(eventsRead)
        writer.writeUInt32(0)
        writer.writeUInt32(UInt32(VirtioGPUProtocol.scanoutCount))
        writer.writeUInt32(capsetCount)
        return Data(writer.bytes)
    }

    /// The pixel-traffic counters of graphics.md §7, with the renderer failures counted by the backend.
    public var statistics: GraphicsCounters {
        var snapshot = counters.snapshot
        snapshot.rendererFailures = backend?.rendererFailures ?? 0
        return snapshot
    }

    // MARK: - VirtioDeviceModel

    /// Records DRIVER_OK, takes the configuration updater, and starts the `events_read` writer if needed.
    public func deviceDidStart(context: VirtioDeviceContext, negotiatedFeatures: UInt64) {
        // The updater is taken on the device queue, as VirtioDeviceCore requires.
        let updater = context.configurationUpdater
        let edid = negotiatedFeatures & VirtioGPUProtocol.Feature.edid != 0
        let spikeDelay: Duration? = lock.withLock {
            writerEpoch &+= 1
            isWriterRunning = false
            configurationUpdater = updater
            negotiatedEDID = edid
            startConfigurationWriterLocked()
            guard let delay = hotplugSpikeDelay, !isHotplugSpikeScheduled else { return nil }
            isHotplugSpikeScheduled = true
            return delay
        }
        if let spikeDelay {
            Task {
                await self.runHotplugSpike(after: spikeDelay)
            }
        }
        logger.info(
            "virtio-gpu DRIVER_OK features=\(negotiatedFeatures, .public) edid=\(edid, .public)"
        )
    }

    /// Drains the notified queue. Each request is answered, and each element is completed once.
    public func queueNotified(index: Int, context: VirtioDeviceContext) {
        let queue: any VirtioQueue
        do {
            queue = try context.queue(index)
        } catch {
            reportGuestError("queue notified before DRIVER_OK", command: nil)
            return
        }
        queue.drain { element in
            self.process(element, queueIndex: index, context: context)
        }
    }

    /// Clears the guest session and resets the renderer. Host scanout configuration is kept.
    public func deviceWillReset() {
        clearGuestSession()
        session.reset()
        backend?.reset()
        logger.info("virtio-gpu reset: guest session cleared, host scanout configuration kept")
    }

    /// Clears the guest session and destroys the renderer at VM stop. Host scanout configuration is kept.
    public func deviceWillStop() {
        clearGuestSession()
        session.reset()
        backend?.shutdown()
        logger.info("virtio-gpu stop")
    }

    // MARK: - Host configuration

    /// Enables `scanout` with `mode` and tells the guest about the change.
    ///
    /// Callable from any thread. A rejected mode throws without changing the table.
    public func enableScanout(_ scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure) {
        lock.lock()
        defer { lock.unlock() }
        let changed = try scanouts.enable(scanout, mode: mode)
        guard changed else { return }
        requestEventsReadLocked(VirtioGPUProtocol.Event.display)
        logger.info(
            "virtio-gpu scanout \(scanout.rawValue, .public) enabled mode=\(mode.description, .public) generation=\(self.scanouts.displayGeneration, .public)"
        )
    }

    /// Disables `scanout` and tells the guest about the change. Callable from any thread.
    public func disableScanout(_ scanout: ScanoutID) {
        lock.lock()
        defer { lock.unlock() }
        guard scanouts.disable(scanout) else { return }
        requestEventsReadLocked(VirtioGPUProtocol.Event.display)
        logger.info(
            "virtio-gpu scanout \(scanout.rawValue, .public) disabled generation=\(self.scanouts.displayGeneration, .public)"
        )
    }

    /// The host's scanout table, as the device currently sees it.
    public var scanoutTable: ScanoutTable {
        lock.withLock { scanouts }
    }

    /// The virtio-gpu features this device offers, named as the `requiredHostCapabilities` of a GPU profile
    /// in the bundle manifest (runtime-image-manifest.md §4.7): `edid` is `VIRTIO_GPU_F_EDID`, and `virgl` is
    /// `VIRTIO_GPU_F_VIRGL`. The set follows the descriptor, so `virgl` appears only with the renderer (#022).
    public var hostCapabilities: Set<String> {
        var names: Set<String> = []
        if descriptor.optionalFeatures & VirtioGPUProtocol.Feature.virgl != 0 {
            names.insert("virgl")
        }
        if descriptor.optionalFeatures & VirtioGPUProtocol.Feature.edid != 0 {
            names.insert("edid")
        }
        return names
    }

    /// Waits until no configuration update is in flight. Tests use it to observe `events_read`.
    package func waitForConfigurationWrites() async {
        while true {
            let task = lock.withLock { isWriterRunning ? writerTask : nil }
            guard let task else { return }
            await task.value
        }
    }

    // MARK: - Requests

    /// The response of one request, and the renderer work it needs (nil when it needs none).
    private struct Reply {
        var bytes: [UInt8]?
        var work: VirGLRenderWork?
    }

    /// Takes one element, copies its request once, and returns it exactly once: now, or when its
    /// work and its fence complete (graphics.md §4.5, §4.7).
    private func process(_ element: consuming VirtioElement, queueIndex: Int, context: VirtioDeviceContext) {
        let copyLimit = VirtioGPUProtocol.Limits.maximumRequestByteCount + 1
        var request: [UInt8] = []
        do {
            request = try element.copyReadable(maxBytes: min(element.readableByteCount, copyLimit))
        } catch {
            reportGuestError("request could not be copied from guest memory", command: nil)
        }
        let header = try? VirtioGPUControlHeader(decodingFrom: request)
        let reply = makeReply(for: request, header: header, queueIndex: queueIndex, context: context)
        if let bytes = reply.bytes, let header {
            deliver(bytes, answering: header, to: element)
        }
        traceObserver?(TraceRecord(queueIndex: queueIndex, request: request, response: reply.bytes))
        finish(element, header: header, work: reply.work)
    }

    /// Completes an element that the device has answered. With a renderer, the element waits in the queue
    /// behind earlier waiting elements, and behind its own renderer work and fence.
    private func finish(
        _ element: consuming VirtioElement,
        header: VirtioGPUControlHeader?,
        work: VirGLRenderWork?
    ) {
        guard let backend else {
            // Without a renderer there is no work to wait for, and every fence completes at once.
            element.complete()
            return
        }
        let fenceRequested = header.map { $0.flags & VirtioGPUProtocol.Flag.fence != 0 } ?? false
        if work != nil || fenceRequested {
            let token = element.deferCompletion().makeCompletionToken()
            backend.execute(
                token: token,
                fence: fenceRequested ? header.flatMap { VirGLBackend.fenceNumber($0.fenceID) } : nil,
                context: header?.contextID ?? 0,
                operation: work ?? { _ in nil }
            )
            return
        }
        if backend.hasWaitingElements {
            let token = element.deferCompletion().makeCompletionToken()
            backend.appendExecuted(token)
            return
        }
        element.complete()
    }

    /// The response for one request, or `nil` when the request is too short for a header.
    private func makeReply(
        for request: [UInt8],
        header: VirtioGPUControlHeader?,
        queueIndex: Int,
        context: VirtioDeviceContext
    ) -> Reply {
        guard let header else {
            reportGuestError("request is shorter than the 24-byte header", command: nil)
            return Reply(bytes: nil, work: nil)
        }
        if request.count > VirtioGPUProtocol.Limits.maximumRequestByteCount {
            reportGuestError("request exceeds the 4 MiB limit", command: header.type)
            return Reply(bytes: errorReply(.invalidParameter, answering: header), work: nil)
        }
        if queueIndex == VirtioGPUProtocol.cursorQueueIndex {
            // The cursor queue belongs to #023. Until then every command gets an error response.
            let isCursorCommand = header.command == .updateCursor || header.command == .moveCursor
            let code: VirtioGPUErrorCode = isCursorCommand ? .unspec : .invalidParameter
            reportGuestError("command on the cursor queue is not implemented", command: header.type)
            return Reply(bytes: errorReply(code, answering: header), work: nil)
        }
        switch header.command {
        case .getDisplayInfo:
            guard request.count == VirtioGPUProtocol.headerByteCount else {
                reportGuestError("GET_DISPLAY_INFO has trailing bytes", command: header.type)
                return Reply(bytes: errorReply(.invalidParameter, answering: header), work: nil)
            }
            return Reply(bytes: displayInfoReply(answering: header), work: nil)
        case .getEDID:
            return Reply(bytes: edidReply(for: request, answering: header), work: nil)
        default:
            break
        }

        // A fence beyond 32 bits cannot name a virglrenderer ctx0 fence (graphics.md §5.2, IR-461).
        if backend != nil, header.flags & VirtioGPUProtocol.Flag.fence != 0,
            VirGLBackend.fenceNumber(header.fenceID) == nil {
            reportGuestError("fence identifier exceeds 32 bits", command: header.type)
            return Reply(bytes: errorReply(.invalidParameter, answering: header), work: nil)
        }
        let decoded: VirtioGPURequest
        do {
            decoded = try VirtioGPUProtocol.decodeRequest(request)
        } catch {
            reportGuestError("request is malformed", command: header.type)
            return Reply(bytes: errorReply(.invalidParameter, answering: header), work: nil)
        }
        if case .unsupported = decoded.body {
            reportGuestError("command is not implemented in this device", command: header.type)
            return Reply(bytes: errorReply(.unspec, answering: header), work: nil)
        }
        let answer = session.reply(to: decoded, context: context)
        if case .error(let code) = answer.response {
            reportGuestError("command was rejected", command: header.type)
            return Reply(
                bytes: errorReply(code, answering: header),
                work: nil
            )
        }
        return Reply(
            bytes: VirtioGPUProtocol.encodeResponse(answer.response, answering: header),
            work: answer.renderWork
        )
    }

    private func edidReply(for request: [UInt8], answering header: VirtioGPUControlHeader) -> [UInt8] {
        guard
            let decoded = try? VirtioGPUProtocol.decodeRequest(request),
            case .getEDID(let rawScanout) = decoded.body
        else {
            reportGuestError("GET_EDID request is malformed", command: header.type)
            return errorReply(.invalidParameter, answering: header)
        }
        guard let scanout = ScanoutID(rawValue: Int(rawScanout)) else {
            reportGuestError("GET_EDID names a scanout outside 0...15", command: header.type)
            return errorReply(.invalidScanoutID, answering: header)
        }
        let (isNegotiated, mode) = lock.withLock {
            (negotiatedEDID, scanouts.state(of: scanout).mode)
        }
        guard isNegotiated else {
            reportGuestError("GET_EDID before VIRTIO_GPU_F_EDID was negotiated", command: header.type)
            return errorReply(.unspec, answering: header)
        }
        do {
            let edid = try EDIDGenerator.make(scanout: scanout, mode: mode)
            return VirtioGPUProtocol.encodeResponse(.okEDID(edid: edid), answering: header)
        } catch {
            reportGuestError("EDID generation failed for the scanout mode", command: header.type)
            return errorReply(.unspec, answering: header)
        }
    }

    /// Answers `GET_DISPLAY_INFO` from one snapshot. It then decides `events_read` for the
    /// guest: a change that arrived after the snapshot keeps the event set (§4.3).
    private func displayInfoReply(answering header: VirtioGPUControlHeader) -> [UInt8] {
        let snapshot = lock.withLock { () -> ScanoutTable in
            reportedGeneration = scanouts.displayGeneration
            return scanouts
        }
        let hook = lock.withLock { displayInfoSnapshotHook }
        hook?()
        let modes = snapshot.allStates.map { (state: ScanoutState) -> VirtioGPUDisplayOne in
            let width = state.isEnabled ? UInt32(state.mode.widthPixels) : 0
            let height = state.isEnabled ? UInt32(state.mode.heightPixels) : 0
            let rect = VirtioGPURect(x: 0, y: 0, width: width, height: height)
            return VirtioGPUDisplayOne(rect: rect, enabled: state.isEnabled ? 1 : 0, flags: 0)
        }
        lock.withLock {
            let hasNewerChange = scanouts.displayGeneration > reportedGeneration
            requestEventsReadLocked(hasNewerChange ? VirtioGPUProtocol.Event.display : 0)
        }
        return VirtioGPUProtocol.encodeResponse(.okDisplayInfo(modes: modes), answering: header)
    }

    private func errorReply(_ code: VirtioGPUErrorCode, answering header: VirtioGPUControlHeader) -> [UInt8] {
        VirtioGPUProtocol.encodeResponse(.error(code), answering: header)
    }

    // MARK: - Delivery

    /// Writes the response in one call, or an error header when the full response does not fit.
    /// When even the header does not fit, the element is completed with zero bytes.
    private func deliver(
        _ response: [UInt8],
        answering header: VirtioGPUControlHeader,
        to element: borrowing VirtioElement
    ) {
        let writableByteCount = element.writableByteCount
        if writableByteCount >= response.count {
            write(response, to: element)
            return
        }
        reportGuestError("response buffer is smaller than the response", command: header.type)
        if writableByteCount >= VirtioGPUProtocol.headerByteCount {
            write(errorReply(.invalidParameter, answering: header), to: element)
        }
    }

    private func write(_ bytes: [UInt8], to element: borrowing VirtioElement) {
        do {
            try bytes.withUnsafeBytes { buffer in
                try element.write(buffer)
            }
        } catch {
            reportGuestError("response could not be written to guest memory", command: nil)
        }
    }

    // MARK: - Configuration writer

    /// Records the wanted `events_read` value and starts the writer if it is idle.
    private func requestEventsReadLocked(_ value: UInt32) {
        eventsReadDesired = value
        startConfigurationWriterLocked()
    }

    private func startConfigurationWriterLocked() {
        guard !isWriterRunning, eventsReadDesired != eventsReadWritten, let updater = configurationUpdater else {
            return
        }
        isWriterRunning = true
        let epoch = writerEpoch
        writerTask = Task {
            await self.runConfigurationWriter(updater: updater, epoch: epoch)
        }
    }

    /// Writes the newest `events_read` value until the device and the guest agree, or until
    /// the generation that owns this writer ends.
    private func runConfigurationWriter(updater: VirtioDeviceConfigurationUpdater, epoch: UInt64) async {
        while true {
            let next: UInt32? = lock.withLock { () -> UInt32? in
                guard epoch == writerEpoch else { return nil }
                guard eventsReadDesired != eventsReadWritten else {
                    isWriterRunning = false
                    return nil
                }
                return eventsReadDesired
            }
            guard let value = next else { return }
            do {
                try await updater.updateConfigurationSpace(
                    VirtioGPUDevice.configurationSpace(eventsRead: value, capsetCount: capsetCount)
                )
                lock.withLock {
                    if epoch == writerEpoch {
                        eventsReadWritten = value
                    }
                }
            } catch {
                let isCurrent = lock.withLock { () -> Bool in
                    guard epoch == writerEpoch else { return false }
                    isWriterRunning = false
                    return true
                }
                if case .notReady = error {
                    logger.info("virtio-gpu configuration update ended with its generation")
                } else if isCurrent {
                    logger.error("virtio-gpu configuration update failed: \(String(describing: error), .public)")
                }
                return
            }
        }
    }

    /// Enables scanout 1 once, after `delay`. It is the R-01 spike, not a product path.
    private func runHotplugSpike(after delay: Duration) async {
        try? await Task.sleep(for: delay)
        guard let scanout = ScanoutID(rawValue: 1) else { return }
        do {
            try enableScanout(scanout, mode: .testDefault)
            logger.info("virtio-gpu R-01 spike enabled scanout 1 after \(delay, .public)")
        } catch {
            logger.error("virtio-gpu R-01 spike could not enable scanout 1")
        }
    }

    private func clearGuestSession() {
        lock.withLock {
            writerEpoch &+= 1
            isWriterRunning = false
            configurationUpdater = nil
            negotiatedEDID = false
            eventsReadDesired = 0
            reportedGeneration = scanouts.displayGeneration
        }
    }

    // MARK: - Diagnostics

    /// Logs a guest-caused problem at most ten times a second, and counts the rest.
    private func reportGuestError(_ reason: String, command: UInt32?) {
        let decision = lock.withLock { errorLimiter.admit(at: clock()) }
        guard case .log(let suppressedCount) = decision else { return }
        logger.warning(
            "virtio-gpu rejected a guest request reason=\(reason, .public) command=\(command ?? 0, .public) suppressed=\(suppressedCount, .public)"
        )
    }
}
