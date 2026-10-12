import AppKit
import CoreGraphics
import InputCore

/// Converts AppKit pointer events into `PointerSample`s (input.md §4.1, decision D1).
///
/// This is the only place that reads `NSEvent`. `InputCore` receives plain values. The kinds that v1 does not forward
/// (other mouse buttons, trackpad gestures, tablet events) produce nil.
public enum PointerEventAdapter {
    /// Returns the sample of `event`, or nil when v1 does not forward the kind of event.
    ///
    /// `locationInContent` is the event's location converted to the content view (`convert(_:from:nil)`), in window
    /// points with the origin at the bottom-left. The scroll deltas and the precise and momentum flags are read only for
    /// `.scrollWheel`.
    public static func sample(for event: NSEvent, locationInContent: CGPoint) -> PointerSample? {
        guard let kind = kind(of: event.type) else { return nil }
        let isScroll = kind == .scroll
        return PointerSample(
            kind: kind,
            windowX: Double(locationInContent.x),
            windowY: Double(locationInContent.y),
            controlDown: event.modifierFlags.contains(.control),
            time: timestamp(seconds: event.timestamp),
            scrollX: isScroll ? Double(event.scrollingDeltaX) : 0,
            scrollY: isScroll ? Double(event.scrollingDeltaY) : 0,
            precise: isScroll && event.hasPreciseScrollingDeltas,
            momentum: isScroll && event.momentumPhase != [])
    }

    private static func kind(of type: NSEvent.EventType) -> PointerSample.Kind? {
        switch type {
        case .leftMouseDown: .leftDown
        case .leftMouseDragged: .leftDragged
        case .leftMouseUp: .leftUp
        case .rightMouseDown: .rightDown
        case .rightMouseDragged: .rightDragged
        case .rightMouseUp: .rightUp
        case .mouseMoved: .moved
        case .mouseEntered: .entered
        case .mouseExited: .exited
        case .scrollWheel: .scroll
        default: nil
        }
    }

    /// `NSEvent.timestamp` is seconds since the system started, the same base as the mach continuous time that
    /// `InputTimestamp` holds. A negative or non-finite value gives zero.
    private static func timestamp(seconds: TimeInterval) -> InputTimestamp {
        guard seconds.isFinite, seconds > 0 else { return InputTimestamp(hostNanos: 0) }
        let nanos = seconds * 1_000_000_000
        guard nanos < Double(UInt64.max) else { return InputTimestamp(hostNanos: UInt64.max) }
        return InputTimestamp(hostNanos: UInt64(nanos))
    }
}
