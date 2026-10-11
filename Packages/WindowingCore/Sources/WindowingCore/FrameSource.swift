import IOSurface

/// One frame that a display window may show: buffer `bufferIndex` of the pool `generation`, numbered `sequence`.
public enum FrameSourceEvent: Equatable, Sendable {
    case frameReady(generation: UInt64, bufferIndex: Int, sequence: UInt64)
}

/// Where a display window gets its frames (display-and-windowing.md §5.3).
///
/// In embedded development mode the source is the CLI's adapter over the runtime's developer display. The wrapper gets
/// the same frames over XPC (#068). The window reads the surfaces and never writes them, and it reports each displayed
/// frame back through `frameDisplayed`.
public protocol FrameSource: Sendable {
    /// The pool's IOSurfaces, in buffer order.
    var surfaces: [IOSurface] { get }
    /// The pool's generation when the source was made. A new generation replaces the surfaces.
    var generation: UInt64 { get }
    /// The width of each surface in pixels.
    var pixelWidth: Int { get }
    /// The height of each surface in pixels.
    var pixelHeight: Int { get }
    /// The frames, in the order they were ready.
    var frames: AsyncStream<FrameSourceEvent> { get }
    /// The window has displayed frame `sequence`.
    func frameDisplayed(sequence: UInt64)
}
