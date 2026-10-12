/// A pointer event in plain values, as the translator receives it (decision D1: InputCore has no AppKit).
///
/// `WindowingCore.PointerEventAdapter` builds the samples from `NSEvent`s. The window point has the AppKit origin at the
/// bottom-left of the content view. The scroll fields are used only by `.scroll`, and are zero otherwise.
public struct PointerSample: Sendable, Equatable {
    /// The kind of pointer event.
    public enum Kind: Sendable, Equatable {
        /// The left button goes down.
        case leftDown
        /// The pointer moves with the left button down.
        case leftDragged
        /// The left button goes up.
        case leftUp
        /// The right button goes down.
        case rightDown
        /// The pointer moves with the right button down.
        case rightDragged
        /// The right button goes up.
        case rightUp
        /// The pointer moves without a button.
        case moved
        /// The pointer enters the content view.
        case entered
        /// The pointer leaves the content view.
        case exited
        /// The wheel or trackpad scrolls.
        case scroll
    }

    /// The kind of event.
    public var kind: Kind
    /// The window point's x, in points.
    public var windowX: Double
    /// The window point's y, in points, with the origin at the bottom-left.
    public var windowY: Double
    /// Whether the Control key is down. Control with the left button is a secondary click (D3).
    public var controlDown: Bool
    /// The event time.
    public var time: InputTimestamp
    /// The horizontal scroll delta, in points for precise deltas and in lines otherwise (`scrollingDeltaX`).
    public var scrollX: Double
    /// The vertical scroll delta, in points for precise deltas and in lines otherwise (`scrollingDeltaY`).
    public var scrollY: Double
    /// Whether the deltas are precise, in points (`hasPreciseScrollingDeltas`).
    public var precise: Bool
    /// Whether the scroll is a momentum phase (`momentumPhase` is not empty).
    public var momentum: Bool

    /// Creates a sample. The scroll fields default to zero, and the flags to false.
    public init(
        kind: Kind, windowX: Double, windowY: Double, controlDown: Bool = false, time: InputTimestamp,
        scrollX: Double = 0, scrollY: Double = 0, precise: Bool = false, momentum: Bool = false
    ) {
        self.kind = kind
        self.windowX = windowX
        self.windowY = windowY
        self.controlDown = controlDown
        self.time = time
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.precise = precise
        self.momentum = momentum
    }
}
