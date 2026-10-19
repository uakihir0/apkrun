import CoreGraphics
import IOSurface

/// Immutable surfaces and geometry for one scanout pool.
public struct FrameSurfaceSet: @unchecked Sendable {
    /// The pool generation.
    public let generation: UInt64
    /// The IOSurfaces in buffer order.
    public let surfaces: [IOSurface]
    /// The scanout width in pixels.
    public let pixelWidth: Int
    /// The scanout height in pixels.
    public let pixelHeight: Int
    /// The window's logical content size in points.
    public let contentSize: CGSize
    /// Pixels per point used to render the scanout.
    public let contentsScale: CGFloat
    /// The requested UI zoom.
    public let zoom: Double

    /// Creates one immutable generation of scanout surfaces.
    public init(
        generation: UInt64,
        surfaces: [IOSurface],
        pixelWidth: Int,
        pixelHeight: Int,
        contentSize: CGSize,
        contentsScale: CGFloat,
        zoom: Double
    ) {
        self.generation = generation
        self.surfaces = surfaces
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentSize = contentSize
        self.contentsScale = contentsScale
        self.zoom = zoom
    }
}

/// One frame that a display window may show: buffer `bufferIndex` of the pool `generation`, numbered `sequence`.
public enum FrameSourceEvent: Equatable, Sendable {
    /// The source installed this pool generation. It may be recovered from a following frame if this event is dropped.
    case surfacesReplaced(generation: UInt64)
    case frameReady(generation: UInt64, bufferIndex: Int, sequence: UInt64)
}

/// Where a display window gets its frames (display-and-windowing.md §5.3).
///
/// In embedded development mode the source is the CLI's adapter over the runtime's developer display. The wrapper gets
/// the same frames over XPC (#068). The window reads the surfaces and never writes them, and it reports each displayed
/// frame back through `frameDisplayed`.
public protocol FrameSource: Sendable {
    /// The latest installed pool.
    var currentSurfaceSet: FrameSurfaceSet { get }
    /// A pool retained for a frame in flight, or `nil` after that pool has been retired.
    func surfaceSet(generation: UInt64) -> FrameSurfaceSet?
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
    func frameDisplayed(generation: UInt64, sequence: UInt64)
}
