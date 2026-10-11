import Foundation
import GraphicsCore
import IOSurface

/// The events of a development display: its surfaces, then each frame that is ready to show.
public enum DevelopmentDisplayEvent: @unchecked Sendable {
    /// The presenter is attached, and `surfaces` are the pool's buffers in order.
    case attached(surfaces: [IOSurface])
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

/// Presents scanout 0 of a development boot in the caller's process (graphics.md §6.2, #023).
///
/// The boot attaches the display to its GPU device before the guest starts, so the first frame is not missed. The
/// frames reach the window through `events`, and the window reports each displayed frame through `frameDisplayed`. It
/// exists only in development builds, with `apkrun dev boot --window`.
public final class DevelopmentDisplay: @unchecked Sendable {
    /// The width of the scanout in pixels. It is the mode that the scanout offers.
    public let pixelWidth: Int
    /// The height of the scanout in pixels.
    public let pixelHeight: Int
    /// The events, in order. The stream keeps the newest sixteen frames, since the window only needs the latest.
    public let events: AsyncStream<DevelopmentDisplayEvent>

    private let continuation: AsyncStream<DevelopmentDisplayEvent>.Continuation
    private let lock = NSLock()
    private var presenter: ScanoutPresenter?
    private var device: VirtioGPUDevice?

    /// Creates a display of `pixelWidth` x `pixelHeight` pixels for scanout 0.
    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
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
        let presenter = try device.attachPresenter(scanout, width: pixelWidth, height: pixelHeight)
        lock.withLock {
            self.presenter = presenter
            self.device = device
        }
        continuation.yield(.attached(surfaces: presenter.surfaces))
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

    /// The window has displayed frame `sequence`, so its buffer may be reused (display-and-windowing.md §5.2).
    public func frameDisplayed(sequence: UInt64) {
        let presenter = lock.withLock { self.presenter }
        presenter?.frameDisplayed(upTo: sequence)
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

    /// Ends the events. The device closes the presenter when the VM stops, and the boot calls this when it ends.
    public func finish() {
        continuation.finish()
    }
}
