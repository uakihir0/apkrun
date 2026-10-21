import DiagnosticsCore
import Foundation
import GraphicsCore
import IOSurface

/// One immutable pool generation of the development display.
public struct DevelopmentSurfaceSet: @unchecked Sendable {
    /// The presenter generation.
    public let generation: UInt64
    /// The surfaces in buffer order.
    public let surfaces: [IOSurface]
    /// The resolved Android display geometry.
    public let mode: ResolvedDisplayMode

    /// Creates a surface set for a presenter generation.
    public init(generation: UInt64, surfaces: [IOSurface], mode: ResolvedDisplayMode) {
        self.generation = generation
        self.surfaces = surfaces
        self.mode = mode
    }

    /// The active width in pixels.
    public var pixelWidth: Int { mode.pixelSize.width }
    /// The active height in pixels.
    public var pixelHeight: Int { mode.pixelSize.height }
    /// The window's logical size in points.
    public var contentSize: CGSize {
        let scale = max(mode.renderScale, 0.01)
        return CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale)
    }
}

/// The events of a development display: its surface generations and ready frames.
public enum DevelopmentDisplayEvent: @unchecked Sendable {
    /// The presenter is attached and its initial pool is ready.
    case attached(surfaceSet: DevelopmentSurfaceSet)
    /// A reconfigured pool replaced the previous generation.
    case surfacesReplaced(surfaceSet: DevelopmentSurfaceSet)
    /// Buffer `bufferIndex` of `generation` is ready to show as frame `sequence`.
    case frameReady(generation: UInt64, bufferIndex: Int, sequence: UInt64)
}

/// The counters of a development display, for the window's statistics (graphics.md §7).
public struct DevelopmentDisplayStatistics: Equatable, Sendable {
    /// Frames the GPU has finished blitting.
    public var framesPresented: UInt64
    /// Frames replaced before they were shown.
    public var droppedFrames: UInt64
    /// Waits on a blit that exceeded the stall timeout.
    public var presentStalls: UInt64
    /// Blits that failed. Their frames are not shown.
    public var failedBlits: UInt64
    /// GPU-to-CPU readbacks made by the host. Must stay zero on the normal path.
    public var hostReadbacks: UInt64
    /// CPU copies of pixel data. Must stay zero on the drmVirgl path.
    public var cpuPixelCopies: UInt64
}

/// A development display resize failure, including whether restoring the prior mode failed.
public enum DevelopmentDisplayReconfigurationFailure: Error, Equatable, Sendable {
    /// A graphics operation failed before the display mode could be changed.
    case graphics(GraphicsFailure)
    /// Android did not accept the requested mode, and the prior mode was restored.
    case guestRejectedMode
    /// The requested mode failed and at least one prior-mode restoration operation failed.
    case modeRestorationFailed(hostModeRestored: Bool, guestModeRestored: Bool)
}

/// Presents scanout 0 of a development boot in the caller's process (graphics.md §6.2, #24).
///
/// The boot attaches the display to its GPU device before the guest starts, so the first frame is not missed. The
/// frames reach the window through `events`, and the window reports each displayed frame through `frameDisplayed`. It
/// exists only in development builds, with `apkrun dev boot --window`.
public final class DevelopmentDisplay: @unchecked Sendable {
    /// The resolved mode advertised through scanout 0 and its EDID.
    public var mode: ResolvedDisplayMode {
        lock.withLock { modeValue }
    }
    /// The latest presenter and the geometry it represents.
    public var currentSurfaceSet: DevelopmentSurfaceSet? {
        lock.withLock {
            guard let generation = presenter?.generation ?? poolHandle?.generation else { return nil }
            return surfaceSets[generation]
        }
    }
    /// A frame handle for the currently attached primary presenter, when one exists.
    public var currentPoolHandle: ScanoutPoolHandle? {
        let device = lock.withLock { self.device }
        guard let device, let scanout = ScanoutID(rawValue: 0) else { return nil }
        return device.poolHandle(for: scanout)
    }
    /// The highest sequence assigned to an accepted flush, including requests not yet relayed as ready.
    ///
    /// Launch readiness reads this producer watermark after Android reports its task visible. The event relay may
    /// still have an earlier frame queued, so its latest delivered sequence alone is not sufficient.
    public var latestIssuedFrameSequence: UInt64 {
        let (device, poolHandle) = lock.withLock { (self.device, self.poolHandle) }
        if let poolHandle {
            return poolHandle.latestIssuedFrameSequence
        }
        guard let device, let scanout = ScanoutID(rawValue: 0) else {
            return 0
        }
        return device.poolHandle(for: scanout)?.latestIssuedFrameSequence ?? 0
    }
    /// Whether this window is backed by a directly attached presenter with the display-0 resize path.
    public var supportsWindowResize: Bool {
        lock.withLock { device != nil }
    }
    /// The width of the scanout in pixels. It is the mode that the scanout offers.
    public var pixelWidth: Int { mode.pixelSize.width }
    /// The height of the scanout in pixels.
    public var pixelHeight: Int { mode.pixelSize.height }
    /// The events, in order. The stream keeps the newest sixteen frames, since the window only needs the latest.
    public let events: AsyncStream<DevelopmentDisplayEvent>

    private let continuation: AsyncStream<DevelopmentDisplayEvent>.Continuation
    private let lock = NSLock()
    private let logger = APKLogger(category: RuntimeLogCategory.supervisor)
    private var modeValue: ResolvedDisplayMode
    private var presenter: ScanoutPresenter?
    private var device: VirtioGPUDevice?
    private var poolHandle: ScanoutPoolHandle?
    private var surfaceSets: [UInt64: DevelopmentSurfaceSet] = [:]
    private var densityUpdater: (@Sendable (ResolvedDisplayMode) async -> Bool)?

    /// Creates a display using a mode resolved from the window geometry.
    public init(mode: ResolvedDisplayMode) {
        modeValue = mode
        let (stream, continuation) = AsyncStream<DevelopmentDisplayEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        events = stream
        self.continuation = continuation
    }

    /// Creates a fixed-density display for existing embedded test clients.
    public init(pixelWidth: Int, pixelHeight: Int) {
        let mode = ResolvedDisplayMode(
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            densityDpi: 160,
            renderScale: 1,
            zoom: 1,
            refreshHz: 60
        )
        modeValue = mode
        let (stream, continuation) = AsyncStream<DevelopmentDisplayEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        events = stream
        self.continuation = continuation
    }

    /// Attaches the presenter to the boot's GPU device. The supervisor calls it before the guest starts.
    func attach(to device: VirtioGPUDevice) throws(GraphicsFailure) {
        guard let scanout = ScanoutID(rawValue: 0) else {
            throw .modeUnsupported(mode: DisplayMode.testDefault)
        }
        let graphicsMode = DisplayMode(
            widthPixels: mode.pixelSize.width,
            heightPixels: mode.pixelSize.height,
            refreshHz: mode.refreshHz,
            dotsPerInch: mode.densityDpi
        )
        try device.enableScanout(scanout, mode: graphicsMode)
        let presenter = try device.attachPresenter(scanout, width: pixelWidth, height: pixelHeight)
        let surfaceSet = DevelopmentSurfaceSet(
            generation: presenter.generation,
            surfaces: presenter.surfaces,
            mode: mode
        )
        lock.withLock {
            self.presenter = presenter
            self.device = device
            poolHandle = nil
            surfaceSets[presenter.generation] = surfaceSet
        }
        continuation.yield(.attached(surfaceSet: surfaceSet))
        relayFrames(from: presenter)
    }

    /// Attaches a lease's existing scanout pool to the development window.
    ///
    /// The pool remains owned by DisplayPool. This display only relays its frames and acknowledges them after the
    /// native window commits the corresponding IOSurface.
    public func attach(lease: DisplayLease) throws(GraphicsFailure) {
        guard !lease.pool.surfaces.isEmpty else {
            throw .configUpdateFailed(detail: "The leased display has no IOSurface buffers.")
        }
        guard
            lease.pool.surfaces.allSatisfy({
                IOSurfaceGetWidth($0) == lease.mode.pixelSize.width
                    && IOSurfaceGetHeight($0) == lease.mode.pixelSize.height
            })
        else {
            throw .configUpdateFailed(detail: "The leased IOSurface dimensions do not match its display mode.")
        }
        let surfaceSet = DevelopmentSurfaceSet(
            generation: lease.pool.generation,
            surfaces: lease.pool.surfaces,
            mode: lease.mode
        )
        let installed = lock.withLock { () -> Bool in
            guard presenter == nil, poolHandle == nil else { return false }
            modeValue = lease.mode
            poolHandle = lease.pool
            surfaceSets[lease.pool.generation] = surfaceSet
            return true
        }
        guard installed else {
            throw .configUpdateFailed(detail: "A display pool is already attached to this window.")
        }
        continuation.yield(.attached(surfaceSet: surfaceSet))
        relayFrames(from: lease.pool)
    }

    /// Installs the Guest Agent path used to wait for Android's mode change and apply its density.
    func setDensityUpdater(_ updater: @escaping @Sendable (ResolvedDisplayMode) async -> Bool) {
        lock.withLock { densityUpdater = updater }
    }

    /// Advertises scanout 0's mode, waits for Android to apply the matching policy, then replaces its surfaces.
    public func reconfigure(to mode: ResolvedDisplayMode) async throws(DevelopmentDisplayReconfigurationFailure) {
        guard let scanout = ScanoutID(rawValue: 0) else {
            throw .graphics(.modeUnsupported(mode: .testDefault))
        }
        let (device, densityUpdater, previousMode) = lock.withLock {
            (self.device, self.densityUpdater, modeValue)
        }
        guard let device, let densityUpdater else {
            throw .graphics(
                .configUpdateFailed(detail: "The development display is not ready to be resized.")
            )
        }
        let displayMode = Self.graphicsMode(for: mode)
        let previousDisplayMode = Self.graphicsMode(for: previousMode)

        // Let Android observe the requested mode before exposing a new host pool or input geometry to the window.
        do throws(GraphicsFailure) {
            try device.enableScanout(scanout, mode: displayMode)
        } catch {
            throw .graphics(error)
        }
        guard await densityUpdater(mode) else {
            let restoration = await restoreMode(
                device: device,
                scanout: scanout,
                displayMode: previousDisplayMode,
                mode: previousMode,
                densityUpdater: densityUpdater
            )
            logger.warning(
                "display resize was rejected because Android did not apply mode \(displayMode.description, .public); prior display policy restoration host=\(restoration.hostModeRestored, .public) guest=\(restoration.guestModeRestored, .public)"
            )
            guard restoration.hostModeRestored, restoration.guestModeRestored else {
                throw .modeRestorationFailed(
                    hostModeRestored: restoration.hostModeRestored,
                    guestModeRestored: restoration.guestModeRestored
                )
            }
            throw .guestRejectedMode
        }

        let presenter: ScanoutPresenter
        do throws(GraphicsFailure) {
            presenter = try device.reconfigurePresenter(
                scanout,
                mode: displayMode,
                width: mode.pixelSize.width,
                height: mode.pixelSize.height
            )
        } catch {
            let restoration = await restoreMode(
                device: device,
                scanout: scanout,
                displayMode: previousDisplayMode,
                mode: previousMode,
                densityUpdater: densityUpdater
            )
            logger.warning(
                "display pool replacement failed after Android applied the requested mode; prior display policy restoration host=\(restoration.hostModeRestored, .public) guest=\(restoration.guestModeRestored, .public)"
            )
            guard restoration.hostModeRestored, restoration.guestModeRestored else {
                throw .modeRestorationFailed(
                    hostModeRestored: restoration.hostModeRestored,
                    guestModeRestored: restoration.guestModeRestored
                )
            }
            throw .graphics(error)
        }
        let surfaceSet = DevelopmentSurfaceSet(
            generation: presenter.generation,
            surfaces: presenter.surfaces,
            mode: mode
        )
        lock.withLock {
            self.presenter = presenter
            modeValue = mode
            surfaceSets[presenter.generation] = surfaceSet
        }
        continuation.yield(.surfacesReplaced(surfaceSet: surfaceSet))
        relayFrames(from: presenter)
        retireOldSurfaceSets(after: presenter.generation)
    }

    private func restoreMode(
        device: VirtioGPUDevice,
        scanout: ScanoutID,
        displayMode: DisplayMode,
        mode: ResolvedDisplayMode,
        densityUpdater: @escaping @Sendable (ResolvedDisplayMode) async -> Bool
    ) async -> (hostModeRestored: Bool, guestModeRestored: Bool) {
        let hostModeRestored: Bool
        do throws(GraphicsFailure) {
            try device.enableScanout(scanout, mode: displayMode)
            hostModeRestored = true
        } catch {
            hostModeRestored = false
        }
        let guestModeRestored = await densityUpdater(mode)
        return (hostModeRestored, guestModeRestored)
    }

    /// Returns a pool set while its generation is still in use by a window frame.
    public func surfaceSet(generation: UInt64) -> DevelopmentSurfaceSet? {
        lock.withLock { surfaceSets[generation] }
    }

    /// The window displayed a frame, so its presenter may reuse the buffer.
    public func frameDisplayed(generation: UInt64, sequence: UInt64) {
        let (device, scanout, poolHandle) = lock.withLock {
            (self.device, ScanoutID(rawValue: 0), self.poolHandle)
        }
        if let poolHandle, poolHandle.generation == generation {
            poolHandle.frameDisplayed(sequence: sequence)
            lock.withLock {
                surfaceSets = surfaceSets.filter { $0.key >= generation }
            }
            return
        }
        guard let device, let scanout else { return }
        device.frameDisplayed(scanout: scanout, generation: generation, sequence: sequence)
        if let activeGeneration = lock.withLock({ presenter?.generation }), activeGeneration == generation {
            lock.withLock {
                surfaceSets = surfaceSets.filter { $0.key >= generation }
            }
        }
    }

    private static func graphicsMode(for mode: ResolvedDisplayMode) -> DisplayMode {
        DisplayMode(
            widthPixels: mode.pixelSize.width,
            heightPixels: mode.pixelSize.height,
            refreshHz: mode.refreshHz,
            dotsPerInch: mode.densityDpi
        )
    }

    /// Bounds old surface retention if a resized guest never commits a frame from its replacement pool.
    private func retireOldSurfaceSets(after generation: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            lock.withLock {
                guard presenter?.generation == generation else { return }
                surfaceSets = surfaceSets.filter { $0.key >= generation }
            }
        }
    }

    /// The counters so far, or `nil` before the presenter is attached.
    public var statistics: DevelopmentDisplayStatistics? {
        let (presenter, device) = lock.withLock { (self.presenter, self.device) }
        guard let presenter, let device else {
            return nil
        }
        let presented = presenter.statistics
        let counters = device.statistics
        return DevelopmentDisplayStatistics(
            framesPresented: presented.framesPresented,
            droppedFrames: presented.droppedFrames,
            presentStalls: presented.presentStalls,
            failedBlits: presented.failedBlits,
            hostReadbacks: counters.hostReadbacks,
            cpuPixelCopies: counters.cpuPixelCopies
        )
    }

    /// Ends the events, and closes the presenter. The boot calls this when it ends, so a boot that fails before the VM
    /// starts releases the presenter's targets too. Closing twice is harmless.
    public func finish() {
        let presenter = lock.withLock { self.presenter }
        presenter?.close()
        continuation.finish()
    }

    private func relayFrames(from presenter: ScanoutPresenter) {
        let continuation = continuation
        Task {
            for await frame in presenter.frames {
                if case .frameReady(let generation, let bufferIndex, let sequence) = frame {
                    continuation.yield(
                        .frameReady(generation: generation, bufferIndex: bufferIndex, sequence: sequence)
                    )
                }
            }
        }
    }

    private func relayFrames(from pool: ScanoutPoolHandle) {
        let continuation = continuation
        Task {
            for await frame in pool.frames {
                if case .frameReady(let generation, let bufferIndex, let sequence) = frame {
                    continuation.yield(
                        .frameReady(generation: generation, bufferIndex: bufferIndex, sequence: sequence)
                    )
                }
            }
        }
    }
}
