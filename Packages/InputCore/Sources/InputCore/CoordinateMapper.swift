/// A rectangle in window points. The origin is the bottom-left corner, as in AppKit (y up).
public struct DisplayRect: Sendable, Equatable {
    /// The left edge.
    public var x: Double
    /// The bottom edge.
    public var y: Double
    /// The width.
    public var width: Double
    /// The height.
    public var height: Double

    /// Creates a rectangle from its origin and size.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Maps window points to display pixels (input.md §3).
///
/// The content rectangle is in window points, with the origin at the bottom-left. The pixel size is the size of the
/// display. A point outside the content rectangle (the letterbox) is not mapped by `map`, and `clamped` moves it to the
/// nearest edge first. A mapper whose content rectangle or pixel size is empty, negative, or not finite maps nothing.
public struct CoordinateMapper: Sendable, Equatable {
    /// The content rectangle in window points.
    public let contentRect: DisplayRect
    /// The width of the display in pixels.
    public let pixelWidth: Int
    /// The height of the display in pixels.
    public let pixelHeight: Int
    /// Identifies the surface geometry. A change during a gesture cancels the gesture (input.md §3).
    public let generation: UInt64

    /// Creates a mapper for a content rectangle and a display pixel size.
    public init(contentRect: DisplayRect, pixelWidth: Int, pixelHeight: Int, generation: UInt64) {
        self.contentRect = contentRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.generation = generation
    }

    /// Whether the mapper maps anything: a finite, non-empty content rectangle and a positive pixel size.
    public var isUsable: Bool {
        let rect = contentRect
        return rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && pixelWidth > 0 && pixelHeight > 0
    }

    /// Maps a window point to display pixels, or returns nil when the point is outside the content rectangle.
    ///
    /// The content rectangle includes its edges. A point on the top or right edge maps to the last pixel row or column.
    public func map(windowX: Double, windowY: Double) -> DisplayPoint? {
        guard isUsable, windowX.isFinite, windowY.isFinite else { return nil }
        let rect = contentRect
        guard windowX >= rect.x, windowX <= rect.x + rect.width,
            windowY >= rect.y, windowY <= rect.y + rect.height
        else {
            return nil
        }
        return project(windowX: windowX, windowY: windowY)
    }

    /// Clamps a window point into the content rectangle, then maps it to display pixels.
    ///
    /// Used for drags that leave the content, so that a gesture still ends at the edge of the display. A non-finite
    /// point or an unusable mapper gives the pixel origin (0, 0). Callers check `isUsable` and finiteness first.
    public func clamped(windowX: Double, windowY: Double) -> DisplayPoint {
        guard isUsable, windowX.isFinite, windowY.isFinite else { return DisplayPoint(x: 0, y: 0) }
        let rect = contentRect
        let x = min(max(windowX, rect.x), rect.x + rect.width)
        let y = min(max(windowY, rect.y), rect.y + rect.height)
        return project(windowX: x, windowY: y)
    }

    /// The window point that a display pixel comes from: the inverse of `map`, used by the tests and the validation
    /// script. An unusable mapper gives the origin of the content rectangle.
    public func windowPoint(forPixel pixel: DisplayPoint) -> (x: Double, y: Double) {
        guard isUsable else { return (contentRect.x, contentRect.y) }
        let rect = contentRect
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        let x = rect.x + pixel.x * rect.width / width
        let y = rect.y + rect.height - pixel.y * rect.height / height
        return (x, y)
    }

    /// The linear part of the mapping: x_px = (p.x - c.x) * W / c.w, y_px = (c.y + c.h - p.y) * H / c.h.
    private func project(windowX: Double, windowY: Double) -> DisplayPoint {
        let rect = contentRect
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        return DisplayPoint(
            x: (windowX - rect.x) * width / rect.width,
            y: (rect.y + rect.height - windowY) * height / rect.height)
    }
}
