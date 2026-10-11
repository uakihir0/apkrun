import CoreGraphics

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
    /// The sequence of the last frame accepted. Zero before the first.
    public private(set) var lastShownSequence: UInt64 = 0

    /// Creates a gate that accepts the frames of `generation`.
    public init(generation: UInt64) {
        self.generation = generation
    }

    /// Records a frame and returns `true` when the layer should show it. Returns `false` for a stale generation, or for
    /// a sequence that is not newer than the last one accepted.
    public mutating func accept(generation: UInt64, sequence: UInt64) -> Bool {
        guard generation == self.generation, sequence > lastShownSequence else {
            return false
        }
        lastShownSequence = sequence
        return true
    }

    /// Moves to a new generation. Frames of the old one are refused from now on.
    public mutating func switchTo(generation: UInt64) {
        guard generation != self.generation else { return }
        self.generation = generation
        lastShownSequence = 0
    }
}
