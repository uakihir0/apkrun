import Foundation

/// The pixel-traffic counters of graphics.md §7 for one device.
public struct GraphicsCounters: Equatable, Sendable {
    /// GPU-to-CPU reads that the host made on its own initiative. No code path increments it:
    /// the normal path never reads back, and the test-only readback is excluded (graphics.md §7).
    public var hostReadbacks: UInt64 = 0
    /// `TRANSFER_FROM_HOST_3D` requests that the guest made (for example for `glReadPixels`).
    public var guestReadbacks: UInt64 = 0
    /// Bytes that the guest asked to read back.
    public var guestReadbackBytes: UInt64 = 0
    /// Bytes that `TRANSFER_TO_HOST` gathered from guest memory, for uploads.
    public var guestUploadBytes: UInt64 = 0
    /// CPU copies of pixel data for the 2D profile (`cpuPixelCopies`, graphics.md §7). Zero under VirGL.
    public var cpuPixelCopies: UInt64 = 0
    /// Bytes that those copies moved.
    public var cpuPixelCopyBytes: UInt64 = 0
    /// Renderer operations that failed after the guest had its response. See IR-460.
    public var rendererFailures: UInt64 = 0

    /// Creates zeroed counters.
    public init() {}
}

/// The counters of one device, updated on the device queue and read from any thread.
final class GraphicsCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counters = GraphicsCounters()

    /// The current counters.
    var snapshot: GraphicsCounters {
        lock.withLock { counters }
    }

    /// Changes the counters under the lock.
    func update(_ change: (inout GraphicsCounters) -> Void) {
        lock.withLock { change(&counters) }
    }
}
