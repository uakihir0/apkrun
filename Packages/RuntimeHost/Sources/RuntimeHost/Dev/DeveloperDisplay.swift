import Foundation
import IOSurface
import RuntimeCore

/// An event of the developer display: the pool's surfaces once, then each frame that is ready to show.
public enum DeveloperDisplayEvent: @unchecked Sendable {
    /// The presenter is attached. `surfaces` are the pool's buffers, in buffer order.
    case attached(surfaces: [IOSurface])
    /// Buffer `bufferIndex` of `generation` is ready to show as frame `sequence`.
    case frameReady(generation: UInt64, bufferIndex: Int, sequence: UInt64)
}

/// The counters of the developer display (graphics.md §7), as the CLI reads them.
public struct DeveloperDisplayStatistics: Equatable, Sendable {
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

/// The development window's connection to display 0 of an embedded boot (runtime-api.md §15, #023).
///
/// The CLI reads display 0 through this type, because it may not import RuntimeCore or GraphicsCore. The events are
/// the frames of the boot's presenter, and the window reports each displayed frame back through `frameDisplayed`.
public final class DeveloperDisplay: @unchecked Sendable {
    /// The display's pixel width, which is the scanout's mode.
    public let pixelWidth: Int
    /// The display's pixel height.
    public let pixelHeight: Int
    /// The events, in order, until the boot ends.
    public let events: AsyncStream<DeveloperDisplayEvent>

    /// The RuntimeCore display that the boot attaches to its GPU device.
    let core: DevelopmentDisplay

    /// Creates the display for `pixelWidth` x `pixelHeight` pixels. The boot attaches it when it starts.
    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        let core = DevelopmentDisplay(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        self.core = core
        let (stream, continuation) = AsyncStream<DeveloperDisplayEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        events = stream
        Task {
            for await event in core.events {
                switch event {
                case .attached(let surfaces):
                    continuation.yield(.attached(surfaces: surfaces))
                case .frameReady(let generation, let bufferIndex, let sequence):
                    continuation.yield(
                        .frameReady(generation: generation, bufferIndex: bufferIndex, sequence: sequence)
                    )
                }
            }
            continuation.finish()
        }
    }

    /// The window has displayed frame `sequence` (display-and-windowing.md §5.2).
    public func frameDisplayed(sequence: UInt64) {
        core.frameDisplayed(sequence: sequence)
    }

    /// The counters so far, or `nil` before the boot has attached the display.
    public var statistics: DeveloperDisplayStatistics? {
        guard let counters = core.statistics else {
            return nil
        }
        return DeveloperDisplayStatistics(
            framesPresented: counters.framesPresented,
            droppedFrames: counters.droppedFrames,
            presentStalls: counters.presentStalls,
            failedBlits: counters.failedBlits,
            hostReadbacks: counters.hostReadbacks,
            cpuPixelCopies: counters.cpuPixelCopies
        )
    }

    /// Ends the events. The boot calls it when it ends.
    func finish() {
        core.finish()
    }
}
