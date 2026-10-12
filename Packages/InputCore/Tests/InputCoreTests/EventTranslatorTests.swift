import Testing

@testable import InputCore

// The translation rules of input.md §4.1 and §4.4, with decisions D2 to D5. The content is (0, 0, 512, 384) in window
// points on a 1024 x 768 display, so a window point (x, y) maps to the pixel (2x, 2 * (384 - y)).

private let contentMapper = CoordinateMapper(
    contentRect: DisplayRect(x: 0, y: 0, width: 512, height: 384), pixelWidth: 1024, pixelHeight: 768, generation: 1)

private func at(_ milliseconds: UInt64) -> InputTimestamp {
    InputTimestamp(hostNanos: milliseconds * 1_000_000)
}

private func sample(
    _ kind: PointerSample.Kind, x: Double = 100, y: Double = 300, control: Bool = false, ms: UInt64 = 0
) -> PointerSample {
    PointerSample(kind: kind, windowX: x, windowY: y, controlDown: control, time: at(ms))
}

private func scrollSample(
    x: Double = 100, y: Double = 300, dx: Double = 0, dy: Double = 0, precise: Bool = true, momentum: Bool = false,
    ms: UInt64 = 0
) -> PointerSample {
    PointerSample(
        kind: .scroll, windowX: x, windowY: y, time: at(ms), scrollX: dx, scrollY: dy, precise: precise,
        momentum: momentum)
}

private func touch(_ phase: TouchEvent.Phase, _ x: Double, _ y: Double, ms: UInt64 = 0) -> InputEvent {
    .touch(TouchEvent(phase: phase, pointerID: 0, position: DisplayPoint(x: x, y: y), time: at(ms)))
}

private func mouse(
    _ action: MouseEvent.Action, _ x: Double, _ y: Double, buttons: MouseButtons = [], ms: UInt64 = 0
) -> InputEvent {
    .mouse(MouseEvent(action: action, position: DisplayPoint(x: x, y: y), buttons: buttons, time: at(ms)))
}

private func scroll(
    _ x: Double, _ y: Double, vertical: Double, horizontal: Double, ms: UInt64 = 0
) -> InputEvent {
    .scroll(
        ScrollEvent(
            position: DisplayPoint(x: x, y: y), vertical: vertical, horizontal: horizontal, time: at(ms)))
}

// MARK: Left button as a touch (FR-IN-01)

@Test func leftDownStartsATouchAtTheMappedPoint() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.leftDown)) == [touch(.down, 200, 168)])
}

@Test func leftDragIsATouchMoveAtTheMappedPoint() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.translate(sample(.leftDragged, x: 200, y: 300, ms: 1)) == [touch(.move, 400, 168, ms: 1)])
}

@Test func leftUpEndsTheTouchAtTheMappedPoint() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.translate(sample(.leftUp, x: 200, y: 200, ms: 2)) == [touch(.up, 400, 368, ms: 2)])
    // The gesture has ended, so a later drag is dropped.
    #expect(translator.translate(sample(.leftDragged, ms: 3)) == [])
}

// MARK: Right button and Control-click as a mouse secondary press (D3)

@Test func rightDownIsASecondaryPress() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.rightDown)) == [mouse(.press(.secondary), 200, 168, buttons: .secondary)])
}

@Test func rightUpIsASecondaryReleaseWithNoButtonsLeft() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.rightDown))
    #expect(
        translator.translate(sample(.rightUp, x: 100, y: 300, ms: 4)) == [mouse(.release(.secondary), 200, 168, ms: 4)])
}

@Test func controlClickIsASecondaryPressThenRelease() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(
        translator.translate(sample(.leftDown, control: true))
            == [mouse(.press(.secondary), 200, 168, buttons: .secondary)])
    #expect(
        translator.translate(sample(.leftUp, control: true, ms: 5)) == [mouse(.release(.secondary), 200, 168, ms: 5)])
}

@Test func aControlReleasedDuringAControlClickStillEndsItWithItsRelease() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown, control: true))
    // Control is up when the left button comes up, but the gesture was a secondary click, so it ends with its release.
    #expect(
        translator.translate(sample(.leftUp, control: false, ms: 6)) == [mouse(.release(.secondary), 200, 168, ms: 6)])
    #expect(translator.translate(sample(.leftDragged, ms: 7)) == [])
}

@Test func aLeftReleaseDoesNotEndARightGesture() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.rightDown))
    #expect(translator.translate(sample(.leftUp, ms: 1)) == [])
    #expect(translator.translate(sample(.rightUp, ms: 2)) == [mouse(.release(.secondary), 200, 168, ms: 2)])
}

@Test func aRightDragIsDroppedBecauseMouseEventHasNoMoveAction() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.rightDown))
    #expect(translator.translate(sample(.rightDragged, x: 200, ms: 1)) == [])
    #expect(translator.translate(sample(.moved, x: 200, ms: 2)) == [])
}

// MARK: Hover (D4)

@Test func aMoveWithoutAButtonStartsTheHoverWithAnEnterAndIsAHoverMove() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.moved)) == [mouse(.hoverEnter, 200, 168), mouse(.hoverMove, 200, 168)])
}

@Test func enteringAndExitingAreSentAtOnceAtTheClampedPoint() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.entered)) == [mouse(.hoverEnter, 200, 168)])
    #expect(translator.translate(sample(.exited, x: 600, y: 100, ms: 1)) == [mouse(.hoverExit, 1023, 568, ms: 1)])
}

@Test func hoverMovesAreLimitedTo120HzAndTheLatestPositionIsSentAsATrailingMove() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(
        translator.translate(sample(.moved, x: 100, ms: 0))
            == [mouse(.hoverEnter, 200, 168), mouse(.hoverMove, 200, 168)])
    #expect(translator.translate(sample(.moved, x: 200, ms: 2)) == [])
    #expect(translator.translate(sample(.moved, x: 300, ms: 4)) == [])
    #expect(translator.hasPending)
    // 8 ms is less than 1/120 s, so the trailing move is not due yet.
    #expect(translator.flush(now: at(8)) == [])
    // At 9 ms it is due, and it carries the latest position and its own time.
    #expect(translator.flush(now: at(9)) == [mouse(.hoverMove, 600, 168, ms: 4)])
    #expect(!translator.hasPending)
}

@Test func aMoveAfterTheIntervalIsSentAtOnce() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.moved, ms: 0))
    #expect(translator.translate(sample(.moved, x: 110, ms: 9)) == [mouse(.hoverMove, 220, 168, ms: 9)])
}

@Test func theHoverRateIsAtMost120HzAcrossAOneKilohertzStream() {
    var translator = EventTranslator(mapper: contentMapper)
    var moves = 0
    for milliseconds in UInt64(0)...1000 {
        let events = translator.translate(sample(.moved, x: 100, ms: milliseconds))
        let flushed = translator.flush(now: at(milliseconds))
        moves += (events + flushed).count
    }
    // The trailing move goes out at the first sample or flush after 1/120 s. A 1 kHz stream therefore gives one move
    // every 9 ms: 112 in this second, and never more than 121. The first sample also sends one hover enter.
    #expect(moves <= 121)
    #expect(moves >= 100)
}

@Test func hoverOffEmitsNoHoverButTheTouchStillWorks() {
    var translator = EventTranslator(mapper: contentMapper, hoverEnabled: false)
    #expect(translator.translate(sample(.moved)) == [])
    #expect(translator.translate(sample(.entered)) == [])
    #expect(translator.translate(sample(.exited)) == [])
    #expect(translator.translate(sample(.leftDown)) == [touch(.down, 200, 168)])
}

@Test func aMoveDuringATouchGestureIsADragNotHover() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.translate(sample(.moved, x: 200, ms: 1)) == [touch(.move, 400, 168, ms: 1)])
}

@Test func aMoveDuringAMouseGestureIsDropped() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown, control: true))
    #expect(translator.translate(sample(.moved, x: 200, ms: 1)) == [])
    #expect(translator.translate(sample(.leftDragged, x: 200, ms: 2)) == [])
}

// MARK: Hover and button gestures (D4): hover never overlaps a gesture

@Test func aHoverBoundaryDuringATouchGestureEmitsNothing() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.translate(sample(.entered, ms: 1)) == [])
    #expect(translator.translate(sample(.exited, x: 600, y: 100, ms: 2)) == [])
    #expect(translator.translate(sample(.moved, x: 200, ms: 3)) == [touch(.move, 400, 168, ms: 3)])
    #expect(!translator.hasPending)
    #expect(translator.translate(sample(.leftUp, x: 200, ms: 4)) == [touch(.up, 400, 168, ms: 4)])
}

@Test func aHoverBoundaryDuringAMouseGestureEmitsNothing() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.rightDown))
    #expect(translator.translate(sample(.entered, ms: 1)) == [])
    #expect(translator.translate(sample(.exited, x: 600, y: 100, ms: 2)) == [])
    #expect(translator.translate(sample(.moved, x: 200, ms: 3)) == [])
    #expect(translator.translate(sample(.rightUp, ms: 4)) == [mouse(.release(.secondary), 200, 168, ms: 4)])
}

@Test func aPressDuringAHoverEndsTheHoverBeforeTheGesture() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.entered)) == [mouse(.hoverEnter, 200, 168)])
    #expect(
        translator.translate(sample(.leftDown, ms: 1))
            == [mouse(.hoverExit, 200, 168, ms: 1), touch(.down, 200, 168, ms: 1)])
    #expect(translator.translate(sample(.leftUp, ms: 2)) == [touch(.up, 200, 168, ms: 2)])
}

@Test func aSecondaryPressDuringAHoverEndsTheHoverBeforeTheGesture() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.moved))
    #expect(
        translator.translate(sample(.rightDown, ms: 1))
            == [mouse(.hoverExit, 200, 168, ms: 1), mouse(.press(.secondary), 200, 168, buttons: .secondary, ms: 1)])
}

@Test func theFirstMoveAfterAReleaseStartsANewHoverWithAnEnter() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    // The release does not emit a hover, because the pointer is not hovering during the gesture.
    #expect(translator.translate(sample(.leftUp, ms: 1)) == [touch(.up, 200, 168, ms: 1)])
    #expect(
        translator.translate(sample(.moved, x: 200, ms: 2))
            == [mouse(.hoverEnter, 400, 168, ms: 2), mouse(.hoverMove, 400, 168, ms: 2)])
}

@Test func cancelAllAndFocusLossEndTheHoverSoTheNextMoveStartsOneAgain() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.entered))
    #expect(translator.cancelAll(at: at(1)) == [.cancelAll(at(1))])
    #expect(
        translator.translate(sample(.moved, ms: 2))
            == [mouse(.hoverEnter, 200, 168, ms: 2), mouse(.hoverMove, 200, 168, ms: 2)])
    #expect(translator.focusLost(at: at(3)) == [.cancelAll(at(3))])
    #expect(
        translator.translate(sample(.moved, ms: 4))
            == [mouse(.hoverEnter, 200, 168, ms: 4), mouse(.hoverMove, 200, 168, ms: 4)])
}

/// The kind of an event, for the assertions on the order of a long output.
private func label(_ event: InputEvent) -> String {
    switch event {
    case .touch(let touch):
        switch touch.phase {
        case .down: "down"
        case .move: "drag"
        case .up: "up"
        case .cancel: "cancel"
        }
    case .mouse(let mouse):
        switch mouse.action {
        case .hoverEnter: "enter"
        case .hoverMove: "hover"
        case .hoverExit: "exit"
        case .press: "press"
        case .release: "release"
        }
    case .scroll: "scroll"
    case .key: "key"
    case .longPress: "longPress"
    case .cancelAll: "cancelAll"
    }
}

/// A fixed table of samples: the window x (100 is inside the content, 600 is the letterbox), whether Control is down,
/// and the kind. It mixes hover, both buttons, Control-click, drags, scrolls, boundaries in both orders, and presses
/// in the letterbox. It is a table, not random numbers, so the test runs the same way every time.
private let hoverTable: [(kind: PointerSample.Kind, x: Double, control: Bool)] = [
    (.moved, 100, false), (.moved, 120, false), (.entered, 100, false), (.moved, 130, false),
    (.exited, 100, false), (.exited, 100, false), (.entered, 100, false), (.leftDown, 100, false),
    (.leftDragged, 110, false), (.entered, 100, false), (.exited, 600, false), (.leftUp, 110, false),
    (.moved, 110, false), (.moved, 112, false), (.rightDown, 112, false), (.entered, 112, false),
    (.scroll, 112, false), (.rightUp, 112, false), (.exited, 100, false), (.moved, 100, false),
    (.leftDown, 100, true), (.moved, 100, false), (.leftUp, 100, false), (.scroll, 100, false),
    (.moved, 100, false), (.exited, 100, false), (.entered, 100, false), (.entered, 100, false),
    (.exited, 100, false), (.exited, 100, false), (.moved, 100, false), (.moved, 100, false),
    (.leftDown, 600, false), (.leftDown, 100, false), (.rightDown, 100, false), (.rightUp, 100, false),
    (.moved, 100, false), (.leftDown, 100, false), (.leftUp, 100, false), (.entered, 100, false),
    (.rightDown, 100, false), (.rightUp, 100, false), (.exited, 600, false), (.entered, 100, false),
    (.leftDown, 100, false), (.leftDragged, 300, false), (.leftUp, 100, false), (.scroll, 100, false),
    (.moved, 100, false), (.entered, 100, false), (.exited, 100, false), (.exited, 100, false),
    (.leftDown, 100, true), (.rightDown, 100, false), (.leftUp, 100, true), (.rightUp, 100, false),
    (.moved, 100, false), (.moved, 100, false), (.entered, 100, false), (.leftDown, 100, false),
    (.leftUp, 100, false), (.moved, 100, false), (.exited, 100, false),
]

@Test func theHoverBoundariesAlternateOverALongSequenceAndNeverOverlapAGesture() {
    var translator = EventTranslator(mapper: contentMapper)
    var hovering = false
    var gestureOpen = false
    var enters = 0
    var exits = 0
    var gestures = 0
    for (index, step) in hoverTable.enumerated() {
        let now = UInt64(index)
        let input =
            step.kind == .scroll
            ? scrollSample(x: step.x, dy: 16, ms: now) : sample(step.kind, x: step.x, control: step.control, ms: now)
        // The flush runs after each sample, so a pending hover or scroll is also checked against the gestures.
        let events = translator.translate(input) + translator.flush(now: at(now))
        for event in events {
            switch label(event) {
            case "enter":
                #expect(!hovering && !gestureOpen, "step \(index): a hover enter")
                hovering = true
                enters += 1
            case "exit":
                #expect(hovering && !gestureOpen, "step \(index): a hover exit")
                hovering = false
                exits += 1
            case "hover":
                #expect(hovering && !gestureOpen, "step \(index): a hover move")
            case "down", "press":
                gestureOpen = true
                gestures += 1
            case "up", "release", "cancelAll":
                gestureOpen = false
            default:
                break
            }
        }
    }
    #expect(enters >= 5)
    #expect(exits >= 5)
    #expect(gestures >= 5)
}

// MARK: Scroll (FR-IN-02, input.md §4.4, D5)

@Test func preciseScrollUsesTheScrollFactorAndTheSigns() {
    var translator = EventTranslator(mapper: contentMapper)
    // 128 points down is two steps of the 64 dp factor, and a positive x delta gives a negative horizontal axis.
    let events = translator.translate(scrollSample(dx: 64, dy: 128))
    #expect(events == [scroll(200, 168, vertical: 2, horizontal: -1)])
}

@Test func negativeScrollsReverseTheSigns() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(scrollSample(dx: -64, dy: -64)) == [scroll(200, 168, vertical: -1, horizontal: 1)])
}

@Test func lineScrollUsesTheLinesAsTheAxesWithTheSameSigns() {
    var translator = EventTranslator(mapper: contentMapper)
    let events = translator.translate(scrollSample(dx: 2, dy: 3, precise: false))
    #expect(events == [scroll(200, 168, vertical: 3, horizontal: -2)])
}

@Test func theZoomDividesThePreciseDeltasIntoDp() {
    var translator = EventTranslator(mapper: contentMapper, zoom: 2)
    #expect(translator.translate(scrollSample(dy: 128)) == [scroll(200, 168, vertical: 1, horizontal: 0)])
}

@Test func aScrollIsAtMostOneEventPer8MillisecondsAndThePendingOneIsFlushed() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(scrollSample(dy: 64, ms: 0)) == [scroll(200, 168, vertical: 1, horizontal: 0)])
    #expect(translator.translate(scrollSample(dy: 32, ms: 4)) == [])
    #expect(translator.translate(scrollSample(dy: 32, ms: 6)) == [])
    #expect(translator.hasPending)
    #expect(translator.flush(now: at(7)) == [])
    // The two held deltas add up: 0.5 + 0.5 = 1, at the time of the latest one.
    #expect(translator.flush(now: at(8)) == [scroll(200, 168, vertical: 1, horizontal: 0, ms: 6)])
    #expect(!translator.hasPending)
}

@Test func theNextSampleAfter8MillisecondsSendsTheHeldScrollFirst() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(scrollSample(dy: 64, ms: 0))
    #expect(translator.translate(scrollSample(dy: 32, ms: 4)) == [])
    let events = translator.translate(scrollSample(dy: 16, ms: 9))
    #expect(events == [scroll(200, 168, vertical: 0.5, horizontal: 0, ms: 4)])
    #expect(translator.flush(now: at(17)) == [scroll(200, 168, vertical: 0.25, horizontal: 0, ms: 9)])
}

@Test func momentumScrollsAreForwardedLikeAnyScroll() {
    var translator = EventTranslator(mapper: contentMapper)
    let events = translator.translate(scrollSample(dy: 64, momentum: true))
    #expect(events == [scroll(200, 168, vertical: 1, horizontal: 0)])
}

@Test func aScrollWithZeroDeltasEmitsNothing() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(scrollSample(dx: 0, dy: 0)) == [])
    #expect(!translator.hasPending)
}

@Test func aScrollDuringATouchGestureIsAScrollAndKeepsTheGesture() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.translate(scrollSample(dy: 64, ms: 1)) == [scroll(200, 168, vertical: 1, horizontal: 0, ms: 1)])
    #expect(translator.translate(sample(.leftDragged, x: 200, ms: 2)) == [touch(.move, 400, 168, ms: 2)])
    #expect(translator.translate(sample(.leftUp, x: 200, ms: 3)) == [touch(.up, 400, 168, ms: 3)])
}

@Test func theScrollPositionIsClampedToTheContent() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(
        translator.translate(scrollSample(x: 600, y: 100, dy: 64)) == [scroll(1023, 568, vertical: 1, horizontal: 0)])
}

// MARK: Letterbox, clamping, and the mapper generation (D2)

@Test func aPressInTheLetterboxIsDropped() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.leftDown, x: 600, y: 100)) == [])
    #expect(translator.translate(sample(.rightDown, x: 600, y: 100)) == [])
    // The drags and the release of a dropped press are dropped too, because no gesture is open.
    #expect(translator.translate(sample(.leftDragged, x: 200, y: 300, ms: 1)) == [])
    #expect(translator.translate(sample(.leftUp, x: 200, y: 300, ms: 2)) == [])
}

@Test func aDragThatLeavesTheContentIsClampedAndTheUpIsAtTheEdge() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    // The guest rejects x >= 1024 and y >= 768, so the clamped drag and its UP end on the last pixel (1023, 767).
    #expect(translator.translate(sample(.leftDragged, x: 600, y: 100, ms: 1)) == [touch(.move, 1023, 568, ms: 1)])
    #expect(translator.translate(sample(.leftUp, x: 600, y: -50, ms: 2)) == [touch(.up, 1023, 767, ms: 2)])
    #expect(translator.translate(sample(.leftDown, ms: 3)) == [touch(.down, 200, 168, ms: 3)])
}

@Test func aGenerationChangeDuringAGestureCancelsIt() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    let resized = CoordinateMapper(
        contentRect: DisplayRect(x: 0, y: 0, width: 512, height: 384), pixelWidth: 2048, pixelHeight: 1536,
        generation: 2)
    #expect(translator.replaceMapper(resized, at: at(3)) == [.cancelAll(at(3))])
    #expect(translator.translate(sample(.leftDragged, x: 200, ms: 4)) == [])
    // The new mapper is in use: 100 points map to 400 pixels on the 2048-pixel display.
    #expect(translator.translate(sample(.leftDown, x: 100, y: 300, ms: 5)) == [touch(.down, 400, 336, ms: 5)])
}

@Test func aSameGenerationKeepsTheGesture() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.replaceMapper(contentMapper, at: at(1)) == [])
    #expect(translator.translate(sample(.leftDragged, x: 200, ms: 2)) == [touch(.move, 400, 168, ms: 2)])
}

@Test func replacingTheMapperWithoutAGestureOnlyStoresIt() {
    var translator = EventTranslator(mapper: contentMapper)
    let resized = CoordinateMapper(
        contentRect: DisplayRect(x: 0, y: 0, width: 512, height: 384), pixelWidth: 2048, pixelHeight: 1536,
        generation: 2)
    #expect(translator.replaceMapper(resized, at: at(1)) == [])
    #expect(translator.translate(sample(.leftDown, ms: 2)) == [touch(.down, 400, 336, ms: 2)])
}

// MARK: Cancel (input.md §4.2, §7.3)

@Test func cancelAllEndsAnOpenTouchGesture() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.cancelAll(at: at(5)) == [.cancelAll(at(5))])
    #expect(translator.translate(sample(.leftDragged, ms: 6)) == [])
    #expect(translator.translate(sample(.leftUp, ms: 7)) == [])
}

@Test func cancelAllEndsTheHoverAndDropsTheTrailingMove() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.moved, ms: 0))
    _ = translator.translate(sample(.moved, x: 200, ms: 2))
    #expect(translator.cancelAll(at: at(3)) == [.cancelAll(at(3))])
    #expect(!translator.hasPending)
    #expect(translator.flush(now: at(20)) == [])
}

@Test func cancelAllReleasesAPressedButton() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.rightDown))
    #expect(translator.cancelAll(at: at(1)) == [.cancelAll(at(1))])
    #expect(translator.translate(sample(.rightUp, ms: 2)) == [])
}

@Test func focusLostIsCancelAll() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(translator.focusLost(at: at(2)) == [.cancelAll(at(2))])
}

@Test func aPressWhileAGestureIsOpenCancelsTheOldOne() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.leftDown))
    #expect(
        translator.translate(sample(.rightDown, ms: 1))
            == [.cancelAll(at(1)), mouse(.press(.secondary), 200, 168, buttons: .secondary, ms: 1)])
}

// MARK: Input that cannot be trusted

@Test func nonFiniteValuesAreDropped() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.leftDown, x: .nan)) == [])
    #expect(translator.translate(sample(.moved, y: .infinity)) == [])
    #expect(translator.translate(scrollSample(dy: .infinity)) == [])
    #expect(translator.translate(sample(.leftDown)) == [touch(.down, 200, 168)])
}

@Test func aTimeThatGoesBackwardsIsTakenAsTheLastTime() {
    var translator = EventTranslator(mapper: contentMapper)
    #expect(translator.translate(sample(.leftDown, ms: 10)) == [touch(.down, 200, 168, ms: 10)])
    #expect(translator.translate(sample(.leftDragged, x: 200, ms: 5)) == [touch(.move, 400, 168, ms: 10)])
}

// MARK: Order of the output

@Test func aDueFlushComesBeforeTheEventsOfALaterSample() {
    var translator = EventTranslator(mapper: contentMapper)
    _ = translator.translate(sample(.moved, ms: 0))
    _ = translator.translate(sample(.moved, x: 200, ms: 2))
    // The pending hover move is due, then the press ends the hover, then the press starts the gesture.
    #expect(
        translator.translate(sample(.leftDown, ms: 9))
            == [mouse(.hoverMove, 400, 168, ms: 2), mouse(.hoverExit, 200, 168, ms: 9), touch(.down, 200, 168, ms: 9)])
}
