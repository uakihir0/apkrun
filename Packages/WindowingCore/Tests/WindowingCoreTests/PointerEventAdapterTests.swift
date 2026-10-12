import AppKit
import CoreGraphics
import InputCore
import Testing

@testable import WindowingCore

// The synthesized NSEvent and CGEvent scroll events of the T0 tests (D1). They run here and not in InputCoreTests,
// because only WindowingCore may read NSEvent.

private func mouseEvent(
    _ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], seconds: TimeInterval = 12.5
) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: type, location: CGPoint(x: 10, y: 20), modifierFlags: flags, timestamp: seconds,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

/// A scroll event made from a CGEvent, as the system delivers wheel and trackpad scrolls to NSEvent.
private func scrollEvent(pixels: Bool, deltaY: Int32, deltaX: Int32, momentumPhase: Int64 = 0) throws -> NSEvent {
    let units: CGScrollEventUnit = pixels ? .pixel : .line
    let cgEvent = try #require(
        CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0))
    // kCGScrollWheelEventMomentumPhase: 0 is none, 1 begin, 2 continue, 3 end.
    cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    return try #require(NSEvent(cgEvent: cgEvent))
}

private let contentPoint = CGPoint(x: 30, y: 40)

@Test func leftDownIsALeftDownAtTheGivenContentPointAtTheEventTime() throws {
    let event = try mouseEvent(.leftMouseDown, seconds: 12.5)
    let sample = try #require(PointerEventAdapter.sample(for: event, locationInContent: contentPoint))
    #expect(sample.kind == .leftDown)
    #expect(sample.windowX == 30)
    #expect(sample.windowY == 40)
    #expect(!sample.controlDown)
    #expect(sample.time == InputTimestamp(hostNanos: 12_500_000_000))
}

@Test func theLeftAndRightButtonsMapToTheirDownDraggedAndUpKinds() throws {
    let cases: [(NSEvent.EventType, PointerSample.Kind)] = [
        (.leftMouseDown, .leftDown),
        (.leftMouseDragged, .leftDragged),
        (.leftMouseUp, .leftUp),
        (.rightMouseDown, .rightDown),
        (.rightMouseDragged, .rightDragged),
        (.rightMouseUp, .rightUp),
    ]
    for (type, kind) in cases {
        let sample = try #require(
            PointerEventAdapter.sample(for: try mouseEvent(type), locationInContent: contentPoint))
        #expect(sample.kind == kind, "\(type)")
    }
}

@Test func aMoveWithoutAButtonMapsToMoved() throws {
    let event = try mouseEvent(.mouseMoved)
    let sample = try #require(PointerEventAdapter.sample(for: event, locationInContent: contentPoint))
    #expect(sample.kind == .moved)
    #expect(sample.windowX == 30)
    #expect(sample.windowY == 40)
}

// `NSEvent.mouseEvent` refuses the enter and exit types (AppKit raises), so they are made with `enterExitEvent`.
@Test func theTrackingAreaEntryAndExitMapToEnteredAndExited() throws {
    let cases: [(NSEvent.EventType, PointerSample.Kind)] = [
        (.mouseEntered, .entered),
        (.mouseExited, .exited),
    ]
    for (type, kind) in cases {
        let event = try #require(
            NSEvent.enterExitEvent(
                with: type, location: CGPoint(x: 10, y: 20), modifierFlags: [], timestamp: 12.5, windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let sample = try #require(PointerEventAdapter.sample(for: event, locationInContent: contentPoint))
        #expect(sample.kind == kind, "\(type)")
        #expect(sample.windowX == 30)
        #expect(sample.windowY == 40)
    }
}

@Test func controlIsReadFromTheModifierFlags() throws {
    let controlClick = try #require(
        PointerEventAdapter.sample(
            for: try mouseEvent(.leftMouseDown, flags: [.control]), locationInContent: contentPoint))
    #expect(controlClick.controlDown)
    let plainClick = try #require(
        PointerEventAdapter.sample(
            for: try mouseEvent(.leftMouseDown, flags: [.shift]), locationInContent: contentPoint))
    #expect(!plainClick.controlDown)
}

@Test func anOtherMouseButtonIsNotForwarded() throws {
    for type in [NSEvent.EventType.otherMouseDown, .otherMouseDragged, .otherMouseUp] {
        let event = try mouseEvent(type)
        #expect(PointerEventAdapter.sample(for: event, locationInContent: contentPoint) == nil, "\(type)")
    }
}

@Test func aPixelScrollCarriesItsDeltasInPointsAndItsPreciseFlag() throws {
    let event = try scrollEvent(pixels: true, deltaY: 12, deltaX: -8)
    let sample = try #require(PointerEventAdapter.sample(for: event, locationInContent: contentPoint))
    #expect(sample.kind == .scroll)
    #expect(sample.scrollX == -8)
    #expect(sample.scrollY == 12)
    #expect(sample.precise)
    #expect(!sample.momentum)
}

@Test func aLineScrollCarriesItsLinesAndIsNotPrecise() throws {
    let event = try scrollEvent(pixels: false, deltaY: 3, deltaX: -2)
    let sample = try #require(PointerEventAdapter.sample(for: event, locationInContent: contentPoint))
    #expect(sample.kind == .scroll)
    #expect(sample.scrollX == -2)
    #expect(sample.scrollY == 3)
    #expect(!sample.precise)
    #expect(!sample.momentum)
}

@Test func aMomentumScrollIsForwardedWithItsFlag() throws {
    let event = try scrollEvent(pixels: true, deltaY: 6, deltaX: 0, momentumPhase: 2)
    let sample = try #require(PointerEventAdapter.sample(for: event, locationInContent: contentPoint))
    #expect(sample.kind == .scroll)
    #expect(sample.scrollY == 6)
    #expect(sample.momentum)
}
