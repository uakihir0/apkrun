import Foundation
import IOSurface

/// One generation of IOSurfaces for a scanout.
///
/// The pool keeps its presenter alive and acknowledges displayed frames back to GraphicsCore. Consumers read the
/// surfaces only; all rendering remains on the GPU.
public struct ScanoutPoolHandle: @unchecked Sendable {
    /// The scanout generation represented by these surfaces.
    public let generation: UInt64
    /// The IOSurfaces in buffer order.
    public let surfaces: [IOSurface]
    /// Completed guest frames for this presenter generation.
    public let frames: AsyncStream<ScanoutFrame>

    private let acknowledgeFrame: @Sendable (UInt64) -> Void

    /// Creates a pool handle. The optional acknowledgement closure is primarily useful to scanout fakes.
    public init(
        generation: UInt64,
        surfaces: [IOSurface],
        frames: AsyncStream<ScanoutFrame>,
        acknowledgeFrame: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.generation = generation
        self.surfaces = surfaces
        self.frames = frames
        self.acknowledgeFrame = acknowledgeFrame
    }

    /// Makes a buffer reusable after its frame is committed by the consumer.
    public func frameDisplayed(sequence: UInt64) {
        acknowledgeFrame(sequence)
    }

    init(presenter: ScanoutPresenter, device: VirtioGPUDevice) {
        self.init(
            generation: presenter.generation,
            surfaces: presenter.surfaces,
            frames: presenter.frames,
            acknowledgeFrame: { sequence in
                device.frameDisplayed(
                    scanout: presenter.scanout,
                    generation: presenter.generation,
                    sequence: sequence
                )
            }
        )
    }
}

/// The display-pool-facing operations of the virtio-gpu scanouts.
///
/// RuntimeCore owns allocation policy; GraphicsCore owns scanout modes, presenter generations, and IOSurfaces.
public protocol ScanoutController: Sendable {
    /// Enables or changes a connector and updates the guest's display-change event.
    func configure(_ scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure)

    /// Disables a connector and updates the guest's display-change event.
    func disable(_ scanout: ScanoutID)

    /// Attaches a fresh IOSurface pool to an already configured scanout.
    func attach(
        _ scanout: ScanoutID,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle

    /// Replaces the pool after Android accepted the new display mode.
    func reconfigure(
        _ scanout: ScanoutID,
        mode: DisplayMode,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle

    /// Detaches one pool. A generation mismatch leaves a newer lease untouched.
    func detachPool(_ scanout: ScanoutID, generation: UInt64?)

    /// Stops presenting while a scanout is hidden. Becoming visible requests a fresh present of its bound resource.
    func visibilityChanged(_ scanout: ScanoutID, visible: Bool)

    /// Re-presents the resource currently bound to a scanout without waiting for another guest flush.
    func requestPresent(_ scanout: ScanoutID)
}

extension ScanoutController {
    /// Compatibility default for controllers that do not own a live presenter.
    public func visibilityChanged(_ scanout: ScanoutID, visible: Bool) {}

    /// Compatibility default for controllers that do not own a live presenter.
    public func requestPresent(_ scanout: ScanoutID) {}
}

/// Production scanout operations backed by one running or booting virtio-gpu device.
public final class VirtioGPUScanoutController: ScanoutController, Sendable {
    private let device: VirtioGPUDevice

    /// Creates the scanout controller for the VM's GPU device.
    public init(device: VirtioGPUDevice) {
        self.device = device
    }

    /// Enables or changes the selected scanout.
    public func configure(_ scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure) {
        try device.enableScanout(scanout, mode: mode)
    }

    /// Disables the selected scanout.
    public func disable(_ scanout: ScanoutID) {
        device.disableScanout(scanout)
    }

    /// Attaches a newly allocated IOSurface pool to the selected scanout.
    public func attach(
        _ scanout: ScanoutID,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle {
        ScanoutPoolHandle(presenter: try device.attachPresenter(scanout, width: width, height: height), device: device)
    }

    /// Replaces the selected scanout's presenter pool after its mode changes.
    public func reconfigure(
        _ scanout: ScanoutID,
        mode: DisplayMode,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle {
        ScanoutPoolHandle(
            presenter: try device.reconfigurePresenter(scanout, mode: mode, width: width, height: height),
            device: device
        )
    }

    /// Detaches the pool only when its generation still owns the scanout.
    public func detachPool(_ scanout: ScanoutID, generation: UInt64?) {
        _ = device.detachPresenter(scanout, generation: generation)
    }

    /// Pauses hidden scanouts and immediately refreshes the bound resource when visibility returns.
    public func visibilityChanged(_ scanout: ScanoutID, visible: Bool) {
        device.visibilityChanged(scanout, visible: visible)
    }

    /// Re-presents the resource currently bound to the selected scanout.
    public func requestPresent(_ scanout: ScanoutID) {
        device.requestPresent(scanout)
    }
}
