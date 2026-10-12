import GuestProtocol
import InputCore
import Testing

@testable import RuntimeCore

/// The conversion of `InputEvent` to the messages of the input stream (guest-protocol.md §9, input.md §8).

private let stamp = InputTimestamp(hostNanos: 42_000)

@Test func touchEventsMapToTheTouchMessage() {
    let phases: [(TouchEvent.Phase, GPTouchPhase)] = [(.down, .down), (.move, .move), (.up, .up), (.cancel, .cancel)]
    for (phase, expected) in phases {
        let message = GuestInputEncoding.message(
            .touch(TouchEvent(phase: phase, pointerID: 0, position: DisplayPoint(x: 10.5, y: 20), time: stamp)))
        #expect(message.hostTimeNanos == 42_000)
        #expect(message.touch.phase == expected)
        #expect(message.touch.pointerID == 0)
        #expect(message.touch.x == 10.5)
        #expect(message.touch.y == 20)
    }
}

@Test func mouseEventsMapTheirActionsAndButtons() {
    let hoverEnter = GuestInputEncoding.message(
        .mouse(MouseEvent(action: .hoverEnter, position: DisplayPoint(x: 1, y: 2), buttons: [], time: stamp)))
    #expect(hoverEnter.mouse.action == .hoverEnter)
    #expect(hoverEnter.mouse.button == 0)
    #expect(hoverEnter.mouse.buttonState == 0)

    let hoverMove = GuestInputEncoding.message(
        .mouse(MouseEvent(action: .hoverMove, position: DisplayPoint(x: 3, y: 4), buttons: [], time: stamp)))
    #expect(hoverMove.mouse.action == .hoverMove)
    #expect(hoverMove.mouse.x == 3)
    #expect(hoverMove.mouse.y == 4)

    let hoverExit = GuestInputEncoding.message(
        .mouse(MouseEvent(action: .hoverExit, position: DisplayPoint(x: 0, y: 0), buttons: [], time: stamp)))
    #expect(hoverExit.mouse.action == .hoverExit)

    let press = GuestInputEncoding.message(
        .mouse(
            MouseEvent(
                action: .press(.secondary), position: DisplayPoint(x: 5, y: 6), buttons: .secondary, time: stamp)))
    #expect(press.mouse.action == .press)
    #expect(press.mouse.button == 2)
    #expect(press.mouse.buttonState == 2)

    let release = GuestInputEncoding.message(
        .mouse(MouseEvent(action: .release(.primary), position: DisplayPoint(x: 5, y: 6), buttons: [], time: stamp)))
    #expect(release.mouse.action == .release)
    #expect(release.mouse.button == 1)
    #expect(release.mouse.buttonState == 0)
}

@Test func theButtonFieldsCarryTheAndroidBits() {
    let buttons: [(MouseButton, UInt32)] = [(.primary, 1), (.secondary, 2), (.tertiary, 4), (.back, 8), (.forward, 16)]
    for (button, bit) in buttons {
        let press = GuestInputEncoding.message(
            .mouse(
                MouseEvent(
                    action: .press(button), position: DisplayPoint(x: 0, y: 0), buttons: MouseButtons(button),
                    time: stamp)))
        #expect(press.mouse.button == bit)
        #expect(press.mouse.buttonState == bit)
        let release = GuestInputEncoding.message(
            .mouse(MouseEvent(action: .release(button), position: DisplayPoint(x: 0, y: 0), buttons: [], time: stamp)))
        #expect(release.mouse.button == bit)
    }
}

@Test func scrollEventsCarryTheAxisValues() {
    let message = GuestInputEncoding.message(
        .scroll(ScrollEvent(position: DisplayPoint(x: 7, y: 8), vertical: -2.5, horizontal: 1.25, time: stamp)))
    #expect(message.hostTimeNanos == 42_000)
    #expect(message.scroll.x == 7)
    #expect(message.scroll.y == 8)
    #expect(message.scroll.vscroll == -2.5)
    #expect(message.scroll.hscroll == 1.25)
}

@Test func keyEventsCarryTheCodeAndTheModifiers() {
    let down = GuestInputEncoding.message(
        .key(KeyEvent(action: .down, androidKeyCode: 29, metaState: [.ctrlOn, .shiftOn], repeatCount: 0, time: stamp)))
    #expect(down.key.action == .down)
    #expect(down.key.keyCode == 29)
    #expect(down.key.metaState == 0x1000 | 0x1)
    #expect(down.key.repeatCount == 0)

    let up = GuestInputEncoding.message(
        .key(KeyEvent(action: .up, androidKeyCode: 66, metaState: [], repeatCount: 3, time: stamp)))
    #expect(up.key.action == .up)
    #expect(up.key.keyCode == 66)
    #expect(up.key.repeatCount == 3)
}

@Test func longPressAndCancelAllMapTheirMessages() {
    let longPress = GuestInputEncoding.message(.longPress(DisplayPoint(x: 9, y: 10), stamp))
    #expect(longPress.longPress.x == 9)
    #expect(longPress.longPress.y == 10)
    #expect(longPress.hostTimeNanos == 42_000)

    let cancel = GuestInputEncoding.message(.cancelAll(stamp))
    #expect(cancel.kind == .cancelAll(GPCancelAll()))
    #expect(cancel.hostTimeNanos == 42_000)
}

@Test func batchesHoldAtMost256EventsAndCountUpFromTheFirstSequence() {
    let events = (0..<600).map { index in
        InputEvent.touch(
            TouchEvent(phase: .move, pointerID: 0, position: DisplayPoint(x: Double(index), y: 0), time: stamp))
    }
    let batches = GuestInputEncoding.batches(events, displayID: 7, firstSequence: 5, hostSendNanos: 99)
    #expect(batches.map { $0.events.count } == [256, 256, 88])
    #expect(batches.map(\.batchSeq) == [5, 6, 7])
    #expect(batches.allSatisfy { $0.displayID == 7 && $0.hostSendNanos == 99 })
    // The events keep their order across the batches.
    #expect(batches.flatMap(\.events).map(\.touch.x) == events.indices.map { Float($0) })
}

@Test func theThirtySecondBatchAsksForAnAck() {
    // The first batch of a stream is 1, so the 32nd batch has the sequence 32.
    let events = [InputEvent.cancelAll(stamp)]
    let thirtyTwo = GuestInputEncoding.batches(events, displayID: 0, firstSequence: 32, hostSendNanos: 0)
    #expect(thirtyTwo.map(\.batchSeq) == [32])
    #expect(thirtyTwo.map(\.ackRequested) == [true])
    let thirtyThree = GuestInputEncoding.batches(events, displayID: 0, firstSequence: 33, hostSendNanos: 0)
    #expect(thirtyThree.map(\.ackRequested) == [false])
}

@Test func noEventsMeansNoBatches() {
    #expect(GuestInputEncoding.batches([], displayID: 0, firstSequence: 1, hostSendNanos: 0).isEmpty)
}
