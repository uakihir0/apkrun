import GuestProtocol
import InputCore

/// The conversion of host input events to the messages of the input stream (guest-protocol.md §9, input.md §8).
///
/// A batch carries at most 256 events. Its `batch_seq` counts up from the sequence it is given, and every 32nd batch
/// asks for an ack, so the host can measure the stream round trip (input.md §8).
enum GuestInputEncoding {
    /// The most events in one batch (guest-protocol.md §9). The guest drops a longer batch whole.
    static let maximumEventsPerBatch = 256
    /// Every batch whose sequence is a multiple of this asks for an ack (input.md §8).
    static let ackInterval: UInt64 = 32

    /// The batches for `events`, in order, at most ``maximumEventsPerBatch`` events each. The first batch has
    /// `firstSequence`, and the others count up from it. The display ID is the one of the session's lease.
    static func batches(
        _ events: [InputEvent],
        displayID: Int32,
        firstSequence: UInt64,
        hostSendNanos: UInt64,
        oneEventPerBatch: Bool = false,
        acknowledgeEveryBatch: Bool = false,
        traceEventTime: Bool = false
    ) -> [GPInputBatch] {
        var batches: [GPInputBatch] = []
        var start = 0
        var sequence = firstSequence
        let batchSize = oneEventPerBatch ? 1 : maximumEventsPerBatch
        while start < events.count {
            let end = min(start + batchSize, events.count)
            var batch = GPInputBatch()
            batch.batchSeq = sequence
            batch.displayID = displayID
            batch.hostSendNanos = hostSendNanos
            batch.ackRequested = acknowledgeEveryBatch || sequence % ackInterval == 0
            batch.traceEventTime = traceEventTime && batch.ackRequested
            batch.events = events[start..<end].map(message)
            batches.append(batch)
            start = end
            sequence += 1
        }
        return batches
    }

    /// The message of one event.
    static func message(_ event: InputEvent) -> GPInputEvent {
        var message = GPInputEvent()
        switch event {
        case .touch(let touch):
            message.hostTimeNanos = touch.time.hostNanos
            var body = GPTouchEvent()
            body.phase = phase(touch.phase)
            body.pointerID = Int32(truncatingIfNeeded: touch.pointerID)
            body.x = Float(touch.position.x)
            body.y = Float(touch.position.y)
            message.kind = .touch(body)
        case .mouse(let mouse):
            message.hostTimeNanos = mouse.time.hostNanos
            var body = GPMouseEvent()
            switch mouse.action {
            case .hoverEnter:
                body.action = .hoverEnter
            case .hoverMove:
                body.action = .hoverMove
            case .hoverExit:
                body.action = .hoverExit
            case .press(let button):
                body.action = .press
                body.button = UInt32(bitPattern: button.androidButtonBit)
            case .release(let button):
                body.action = .release
                body.button = UInt32(bitPattern: button.androidButtonBit)
            }
            body.buttonState = UInt32(bitPattern: mouse.buttons.rawValue)
            body.x = Float(mouse.position.x)
            body.y = Float(mouse.position.y)
            message.kind = .mouse(body)
        case .scroll(let scroll):
            message.hostTimeNanos = scroll.time.hostNanos
            var body = GPScrollEvent()
            body.x = Float(scroll.position.x)
            body.y = Float(scroll.position.y)
            body.vscroll = Float(scroll.vertical)
            body.hscroll = Float(scroll.horizontal)
            message.kind = .scroll(body)
        case .key(let key):
            message.hostTimeNanos = key.time.hostNanos
            var body = GPKeyEvent()
            body.action = key.action == .down ? .down : .up
            body.keyCode = key.androidKeyCode
            body.metaState = UInt32(bitPattern: key.metaState.rawValue)
            body.repeatCount = key.repeatCount
            message.kind = .key(body)
        case .longPress(let position, let time):
            message.hostTimeNanos = time.hostNanos
            var body = GPLongPress()
            body.x = Float(position.x)
            body.y = Float(position.y)
            message.kind = .longPress(body)
        case .cancelAll(let time):
            message.hostTimeNanos = time.hostNanos
            message.kind = .cancelAll(GPCancelAll())
        }
        return message
    }

    private static func phase(_ phase: TouchEvent.Phase) -> GPTouchPhase {
        switch phase {
        case .down: .down
        case .move: .move
        case .up: .up
        case .cancel: .cancel
        }
    }
}
