import CoreGraphics
import InputCore

/// The fixed-size geometry of a display window (graphics.md §12 #023, step 3).
///
/// The content keeps the scanout's pixel size. The window never changes the scanout's mode, and when the window is
/// resized the content is scaled with aspect fit.
public enum DisplayGeometry {
    /// The rectangle of `bounds` where content of `contentSize` appears: scaled to fit without cropping, and centered.
    ///
    /// Returns `.zero` when either size is empty.
    public static func aspectFit(contentSize: CGSize, in bounds: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let fitted = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// The mapper of input.md §3 for content of `contentSize` aspect-fit in `bounds`, shown on a display of
    /// `pixelWidth` x `pixelHeight` pixels. The content rectangle is in the coordinates of `bounds`, so a point of the
    /// letterbox maps to nothing.
    public static func coordinateMapper(
        contentSize: CGSize,
        in bounds: CGSize,
        pixelWidth: Int,
        pixelHeight: Int,
        generation: UInt64
    ) -> CoordinateMapper {
        let rect = aspectFit(contentSize: contentSize, in: bounds)
        return CoordinateMapper(
            contentRect: DisplayRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            generation: generation
        )
    }

    /// The window's content size in points for a scanout of `pixelWidth` x `pixelHeight` pixels at `backingScale`
    /// pixels per point, so the surface is shown at its native pixel density.
    public static func contentSize(pixelWidth: Int, pixelHeight: Int, backingScale: CGFloat) -> CGSize {
        let scale = backingScale > 0 ? backingScale : 1
        return CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }
}

/// Decides which frames reach the layer (display-and-windowing.md §5.3).
///
/// A frame reaches the layer when it belongs to the current generation and is newer than the last frame shown. A stale
/// or reordered frame is dropped, so the layer never goes back to an older buffer.
public struct LayerFrameGate: Equatable, Sendable {
    /// The generation whose frames are accepted.
    public private(set) var generation: UInt64
    /// The newest generation announced by the display, even before its first frame arrives.
    public private(set) var newestAnnouncedGeneration: UInt64
    /// The sequence of the last frame accepted. Zero before the first.
    public private(set) var lastShownSequence: UInt64 = 0

    /// Creates a gate that accepts the frames of `generation`.
    public init(generation: UInt64) {
        self.generation = generation
        newestAnnouncedGeneration = generation
    }

    /// Records that the display replaced its surfaces with a newer generation.
    public mutating func announce(generation: UInt64) {
        newestAnnouncedGeneration = max(newestAnnouncedGeneration, generation)
    }

    /// Records a frame and returns `true` when the layer should show it. Returns `false` for a stale generation, or for
    /// a sequence that is not newer than the last one accepted.
    public mutating func accept(generation: UInt64, sequence: UInt64) -> Bool {
        guard generation == self.generation,
            generation >= newestAnnouncedGeneration,
            sequence > lastShownSequence
        else {
            return false
        }
        lastShownSequence = sequence
        return true
    }

    /// Moves to a new generation. Frames of the old one are refused from now on.
    public mutating func switchTo(generation: UInt64) {
        guard generation >= newestAnnouncedGeneration, generation != self.generation else { return }
        self.generation = generation
        lastShownSequence = 0
    }
}

/// The result of applying a native window geometry change to Android and its display surfaces.
public enum DisplayResizeOutcome: Equatable, Sendable {
    /// Android and the host now use the new geometry.
    case applied
    /// The request failed and the previous geometry was restored.
    case rejected
    /// The request completed without replacing the surface generation.
    case unchanged
    /// Restoring the previous geometry failed; input must stay disabled until a newer frame commits.
    case stateUncertain

    /// Combines a coalesced resize result with a later result in the same window update.
    ///
    /// A later rejection cannot erase an earlier uncertain rollback or a successful resize that installed a new
    /// generation. A later successful resize supersedes earlier uncertainty because the window waits for its new frame.
    public func accumulating(_ later: Self) -> Self {
        switch later {
        case .stateUncertain:
            .stateUncertain
        case .applied:
            .applied
        case .unchanged:
            self
        case .rejected:
            switch self {
            case .applied, .stateUncertain: self
            case .rejected, .unchanged: .rejected
            }
        }
    }
}
