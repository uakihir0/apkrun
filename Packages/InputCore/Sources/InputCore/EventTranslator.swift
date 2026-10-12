/// Translates pointer samples into the events of the guest (input.md §4.1 and §4.4; decisions D2 to D5).
///
/// The translator is a value. It keeps the open gesture, the pressed buttons, whether the pointer hovers, and the
/// pending hover move and scroll. When `hasPending` is true, the caller calls `flush(now:)` from a timer, so that a
/// pending event is sent without a later sample. The events of one call keep the order in which they happened.
///
/// Hover and a button gesture never overlap on the guest, because the framework refuses a hover event while a gesture
/// is open ("Inconsistent event"). So hover samples emit nothing while a gesture is open, a press ends the hover first,
/// and the hover enter and exit alternate: `hovering` is true only between a `hoverEnter` and the `hoverExit` after it.
public struct EventTranslator: Sendable {
    /// The shortest interval between two hover moves: 1/120 s (D4).
    private static let hoverInterval: UInt64 = 1_000_000_000 / 120
    /// The shortest interval between two scroll events: 8 ms (D5).
    private static let scrollInterval: UInt64 = 8_000_000
    /// The scroll factor used when the caller passes an unusable one (`config_verticalScrollFactor`).
    private static let defaultScrollFactorDp = 64.0

    /// The button that a gesture started with.
    private enum Trigger: Sendable, Equatable {
        case left
        case right
    }

    /// The open gesture. A touch gesture is the left button. A mouse gesture holds the secondary button, pressed by the
    /// right button or by Control-click, and remembers which of them started it (D3).
    private enum Gesture: Sendable, Equatable {
        case touch
        case mouse(button: MouseButton, trigger: Trigger)
    }

    /// A hover move held back by the rate limit. The window point is kept, so `flush` maps it with the current mapper.
    private struct PendingHover: Sendable, Equatable {
        var windowX: Double
        var windowY: Double
        var time: InputTimestamp
    }

    /// Scroll deltas held back by the rate limit: the axes are summed, and the position is the latest.
    private struct PendingScroll: Sendable, Equatable {
        var windowX: Double
        var windowY: Double
        var vertical: Double
        var horizontal: Double
        var time: InputTimestamp
    }

    private var mapper: CoordinateMapper
    private let scrollFactorDp: Double
    private let zoom: Double
    private let hoverEnabled: Bool
    private var gesture: Gesture?
    private var pressed: MouseButtons = []
    private var pendingHover: PendingHover?
    private var pendingScroll: PendingScroll?
    /// Whether the guest has a hover (a `hoverEnter` was sent and no `hoverExit` after it). Never true during a gesture.
    private var hovering = false
    private var lastHoverMove: InputTimestamp?
    private var lastScroll: InputTimestamp?
    private var lastTime: InputTimestamp?

    /// Creates a translator for `mapper`.
    ///
    /// `scrollFactorDp` is the display's scroll factor in dp (64 by default), and `zoom` is the window zoom (1 at the
    /// reference scale). A zero, negative, or non-finite value is replaced by its default.
    public init(mapper: CoordinateMapper, scrollFactorDp: Double = 64, zoom: Double = 1, hoverEnabled: Bool = true) {
        self.mapper = mapper
        self.scrollFactorDp =
            scrollFactorDp.isFinite && scrollFactorDp > 0 ? scrollFactorDp : Self.defaultScrollFactorDp
        self.zoom = zoom.isFinite && zoom > 0 ? zoom : 1
        self.hoverEnabled = hoverEnabled
    }

    /// Whether a rate-limited event waits for `flush(now:)`.
    public var hasPending: Bool {
        pendingHover != nil || pendingScroll != nil
    }

    /// Translates one pointer sample. The pending events that are due come first, then the events of the sample.
    ///
    /// A sample with a non-finite value is dropped. A time that goes backwards is replaced by the last time seen.
    public mutating func translate(_ sample: PointerSample) -> [InputEvent] {
        guard sample.windowX.isFinite, sample.windowY.isFinite, sample.scrollX.isFinite, sample.scrollY.isFinite else {
            return []
        }
        let time = clock(sample.time)
        var events = dueEvents(at: time)
        switch sample.kind {
        case .leftDown:
            events += press(.left, sample, at: time)
        case .rightDown:
            events += press(.right, sample, at: time)
        case .leftDragged:
            // A drag is a touch move while a touch gesture is open. Mouse-button drags have no move action (see
            // `rightDragged`), so they are dropped during a mouse gesture.
            if gesture == .touch {
                events += touchMove(sample, at: time)
            }
        case .rightDragged:
            // input.md §4.1 has no row for a drag with a mouse button, and MouseEvent has no move action. The drag is
            // dropped, and the release carries the position.
            break
        case .leftUp:
            events += release(.left, sample, at: time)
        case .rightUp:
            events += release(.right, sample, at: time)
        case .moved:
            events += moved(sample, at: time)
        case .entered:
            events += hoverBoundary(.hoverEnter, sample, at: time)
        case .exited:
            events += hoverBoundary(.hoverExit, sample, at: time)
        case .scroll:
            events += scroll(sample, at: time)
        }
        return events
    }

    /// Emits the pending hover move or scroll that is due at `now` (D4, D5).
    public mutating func flush(now: InputTimestamp) -> [InputEvent] {
        let time = clock(now)
        return dueEvents(at: time)
    }

    /// Cancels everything that is open: the gesture, the pressed buttons, the hover, and the pending events. The result
    /// is always `.cancelAll`, so that the guest ends its own gestures even when the host has lost track of them.
    public mutating func cancelAll(at time: InputTimestamp) -> [InputEvent] {
        let now = clock(time)
        var events = dueEvents(at: now)
        events.append(.cancelAll(now))
        reset()
        return events
    }

    /// The window lost focus. The same as `cancelAll` (input.md §4.2).
    public mutating func focusLost(at time: InputTimestamp) -> [InputEvent] {
        cancelAll(at: time)
    }

    /// Stores `mapper` for the following samples. A gesture that is open when the generation changes is cancelled.
    public mutating func replaceMapper(_ mapper: CoordinateMapper, at time: InputTimestamp) -> [InputEvent] {
        let now = clock(time)
        var events = dueEvents(at: now)
        if gesture != nil, mapper.generation != self.mapper.generation {
            events.append(.cancelAll(now))
            reset()
        }
        self.mapper = mapper
        return events
    }

    /// The time of a sample. A time before the last one seen is replaced by that one, so the stream never goes back.
    private mutating func clock(_ time: InputTimestamp) -> InputTimestamp {
        if let last = lastTime, time < last {
            return last
        }
        lastTime = time
        return time
    }

    private mutating func reset() {
        gesture = nil
        pressed = []
        pendingHover = nil
        pendingScroll = nil
        hovering = false
        lastHoverMove = nil
        lastScroll = nil
    }

    /// The pending hover move and scroll that are due at `time`, in the order in which they happened.
    private mutating func dueEvents(at time: InputTimestamp) -> [InputEvent] {
        var scrollFirst = false
        if let hover = pendingHover, let scroll = pendingScroll {
            scrollFirst = scroll.time < hover.time
        }
        var events: [InputEvent] = []
        if scrollFirst {
            events += emitDueScroll(at: time)
            events += emitDueHover(at: time)
        } else {
            events += emitDueHover(at: time)
            events += emitDueScroll(at: time)
        }
        return events
    }

    private mutating func emitDueHover(at time: InputTimestamp) -> [InputEvent] {
        guard let pending = pendingHover,
            Self.isDue(since: lastHoverMove, at: time, interval: Self.hoverInterval)
        else {
            return []
        }
        pendingHover = nil
        guard let point = mapper.map(windowX: pending.windowX, windowY: pending.windowY) else { return [] }
        lastHoverMove = time
        let event = MouseEvent(action: .hoverMove, position: point, buttons: pressed, time: pending.time)
        return [.mouse(event)]
    }

    private mutating func emitDueScroll(at time: InputTimestamp) -> [InputEvent] {
        guard let pending = pendingScroll,
            Self.isDue(since: lastScroll, at: time, interval: Self.scrollInterval)
        else {
            return []
        }
        pendingScroll = nil
        guard mapper.isUsable else { return [] }
        lastScroll = time
        let point = mapper.clamped(windowX: pending.windowX, windowY: pending.windowY)
        let event = ScrollEvent(
            position: point, vertical: pending.vertical, horizontal: pending.horizontal, time: pending.time)
        return [.scroll(event)]
    }

    /// Whether `interval` nanoseconds have passed since `last`. Without a last event, the event is due at once.
    private static func isDue(since last: InputTimestamp?, at time: InputTimestamp, interval: UInt64) -> Bool {
        guard let last else { return true }
        return time.hostNanos >= last.hostNanos && time.hostNanos - last.hostNanos >= interval
    }

    /// A button goes down. The left button starts a touch gesture, unless Control is down. The right button and
    /// Control-click start a mouse gesture with the secondary button (D3). A press outside the content is dropped (D2).
    /// A press during a hover first ends the hover, so the hover is over before the gesture starts.
    private mutating func press(_ trigger: Trigger, _ sample: PointerSample, at time: InputTimestamp) -> [InputEvent] {
        guard let point = mapper.map(windowX: sample.windowX, windowY: sample.windowY) else { return [] }
        // A press that arrives while a gesture is open means the release was lost. The open gesture is cancelled first.
        var events = abandonGesture(at: time)
        // A hover move that is still pending is older than the press, and it is not sent after it.
        pendingHover = nil
        if hovering {
            hovering = false
            events.append(.mouse(MouseEvent(action: .hoverExit, position: point, buttons: pressed, time: time)))
        }
        if trigger == .left, !sample.controlDown {
            gesture = .touch
            events.append(.touch(TouchEvent(phase: .down, pointerID: 0, position: point, time: time)))
        } else {
            gesture = .mouse(button: .secondary, trigger: trigger)
            pressed = MouseButtons(.secondary)
            let event = MouseEvent(action: .press(.secondary), position: point, buttons: pressed, time: time)
            events.append(.mouse(event))
        }
        return events
    }

    /// Ends an open gesture without a release, and reports it as `.cancelAll`.
    private mutating func abandonGesture(at time: InputTimestamp) -> [InputEvent] {
        guard gesture != nil else { return [] }
        gesture = nil
        pressed = []
        return [.cancelAll(time)]
    }

    /// A button goes up. It ends only the gesture that the same button started, so a left release does not end a right
    /// gesture, and a Control released during a Control-click still ends it with its release (D3). The position is clamped
    /// to the content (D2).
    private mutating func release(_ trigger: Trigger, _ sample: PointerSample, at time: InputTimestamp) -> [InputEvent]
    {
        switch gesture {
        case .touch? where trigger == .left:
            gesture = nil
            let point = mapper.clamped(windowX: sample.windowX, windowY: sample.windowY)
            return [.touch(TouchEvent(phase: .up, pointerID: 0, position: point, time: time))]
        case .mouse(let button, let owner)? where owner == trigger:
            gesture = nil
            pressed = []
            let point = mapper.clamped(windowX: sample.windowX, windowY: sample.windowY)
            let event = MouseEvent(action: .release(button), position: point, buttons: pressed, time: time)
            return [.mouse(event)]
        default:
            return []
        }
    }

    /// A move during a touch gesture is a touch move, clamped to the content (D2).
    private func touchMove(_ sample: PointerSample, at time: InputTimestamp) -> [InputEvent] {
        guard mapper.isUsable else { return [] }
        let point = mapper.clamped(windowX: sample.windowX, windowY: sample.windowY)
        return [.touch(TouchEvent(phase: .move, pointerID: 0, position: point, time: time))]
    }

    /// A move without a button. During a touch gesture it is a drag. During a mouse gesture it is dropped (see
    /// `translate`). Otherwise it is hover, at most 120 per second, with the latest position sent as a trailing move (D4).
    /// A move that starts the hover sends a `hoverEnter` first.
    private mutating func moved(_ sample: PointerSample, at time: InputTimestamp) -> [InputEvent] {
        switch gesture {
        case .touch?:
            return touchMove(sample, at: time)
        case .mouse?:
            return []
        case nil:
            break
        }
        guard hoverEnabled, mapper.isUsable,
            let point = mapper.map(windowX: sample.windowX, windowY: sample.windowY)
        else {
            return []
        }
        var events: [InputEvent] = []
        if !hovering {
            hovering = true
            events.append(.mouse(MouseEvent(action: .hoverEnter, position: point, buttons: pressed, time: time)))
        }
        guard Self.isDue(since: lastHoverMove, at: time, interval: Self.hoverInterval) else {
            pendingHover = PendingHover(windowX: sample.windowX, windowY: sample.windowY, time: time)
            return events
        }
        pendingHover = nil
        lastHoverMove = time
        events.append(.mouse(MouseEvent(action: .hoverMove, position: point, buttons: pressed, time: time)))
        return events
    }

    /// The pointer enters or leaves the content. The event is sent at once, at the clamped position (D4). It is sent only
    /// when it changes the hover: an enter while hovering, an exit while not, and any boundary during a gesture emit
    /// nothing, so that the enter and exit stay alternate.
    private mutating func hoverBoundary(
        _ action: MouseEvent.Action, _ sample: PointerSample, at time: InputTimestamp
    ) -> [InputEvent] {
        guard hoverEnabled, mapper.isUsable, gesture == nil else { return [] }
        switch action {
        case .hoverEnter where !hovering:
            hovering = true
        case .hoverExit where hovering:
            hovering = false
            pendingHover = nil
        default:
            return []
        }
        let point = mapper.clamped(windowX: sample.windowX, windowY: sample.windowY)
        return [.mouse(MouseEvent(action: action, position: point, buttons: pressed, time: time))]
    }

    /// A scroll. The axes of input.md §4.4 are summed, and at most one scroll goes out per 8 ms (D5). A sample with
    /// zero deltas emits nothing. The gesture state does not change.
    private mutating func scroll(_ sample: PointerSample, at time: InputTimestamp) -> [InputEvent] {
        guard mapper.isUsable, sample.scrollX != 0 || sample.scrollY != 0 else { return [] }
        let axes = scrollAxes(sample)
        var pending =
            pendingScroll
            ?? PendingScroll(
                windowX: sample.windowX, windowY: sample.windowY, vertical: 0, horizontal: 0, time: time)
        pending.windowX = sample.windowX
        pending.windowY = sample.windowY
        pending.vertical += axes.vertical
        pending.horizontal += axes.horizontal
        pending.time = time
        pendingScroll = pending
        return emitDueScroll(at: time)
    }

    /// The axis values of input.md §4.4. Precise deltas are in points: they are divided by the zoom to get dp, then by
    /// the scroll factor. Line deltas are used as they are. The horizontal axis is the negated x delta.
    private func scrollAxes(_ sample: PointerSample) -> (vertical: Double, horizontal: Double) {
        guard sample.precise else {
            return (vertical: sample.scrollY, horizontal: -sample.scrollX)
        }
        let dpX = sample.scrollX / zoom
        let dpY = sample.scrollY / zoom
        return (vertical: dpY / scrollFactorDp, horizontal: -dpX / scrollFactorDp)
    }
}
