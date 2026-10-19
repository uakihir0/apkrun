import Foundation
import GuestProtocol
import InputCore
import Testing

@testable import RuntimeCore

/// The routing rules of `InputRouter` (runtime-api.md §7.3, input.md §7.1, decision D9), run against a recording
/// channel and a clock that the test moves.

/// A channel that records the batches it is sent. The test sets the backlog, makes sends fail, and delivers acks.
actor RecordingInputChannel: InputChannel {
    private(set) var batches: [GPInputBatch] = []
    private var backlog = 0
    private var sendLimit: Int?
    nonisolated let negotiatedCapabilities: Set<String>?
    nonisolated let acks: AsyncStream<GPInputAck>
    private nonisolated let ackContinuation: AsyncStream<GPInputAck>.Continuation

    init(negotiatedCapabilities: Set<String>? = nil) {
        self.negotiatedCapabilities = negotiatedCapabilities
        let stream = AsyncStream.makeStream(of: GPInputAck.self, bufferingPolicy: .unbounded)
        acks = stream.stream
        ackContinuation = stream.continuation
    }

    func send(_ batch: GPInputBatch) async throws {
        // A send suspends, so that a second route could interleave with this one if the router let it.
        try? await Task.sleep(for: .milliseconds(1))
        if let sendLimit, batches.count >= sendLimit {
            throw GuestProtocolFailure.disconnected
        }
        batches.append(batch)
    }

    var pendingBytes: Int {
        backlog
    }

    func setBacklog(_ bytes: Int) {
        backlog = bytes
    }

    /// Lets the first `count` sends succeed, and fails the ones after them.
    func succeedFirst(_ count: Int) {
        sendLimit = count
    }

    nonisolated func deliverAck(
        batchSeq: UInt64,
        rejected: UInt32,
        receiveToInjectMicros: UInt32 = 0,
        lastEventTimeMillis: UInt64 = 0
    ) {
        var ack = GPInputAck()
        ack.batchSeq = batchSeq
        ack.rejectedEvents = rejected
        ack.receiveToInjectMicros = receiveToInjectMicros
        ack.lastEventTimeMillis = lastEventTimeMillis
        ackContinuation.yield(ack)
    }
}

struct FocusDisplayCall: Equatable, Sendable {
    let displayID: Int32
    let cancelDisplayIDsAlreadySent: [Int32]
}

actor RecordingFocusDisplay {
    private(set) var calls: [FocusDisplayCall] = []

    func focus(_ displayID: Int32, after batches: [GPInputBatch]) {
        let cancelledDisplays = batches.compactMap { batch in
            batch.events.contains(where: { label($0) == "cancelAll" }) ? batch.displayID : nil
        }
        calls.append(
            FocusDisplayCall(
                displayID: displayID,
                cancelDisplayIDsAlreadySent: cancelledDisplays
            )
        )
    }
}

actor RetryableFocusDisplay {
    private(set) var calls = 0

    func focus() throws {
        calls += 1
        if calls == 1 {
            throw GuestProtocolFailure.disconnected
        }
    }
}

/// A clock that the test moves. The router reads it in nanoseconds.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: UInt64 = 0

    var now: UInt64 {
        lock.withLock { nanos }
    }

    func advance(milliseconds: UInt64) {
        lock.withLock { nanos += milliseconds * 1_000_000 }
    }
}

private let stamp = InputTimestamp(hostNanos: 1)
private let display = Int32(7)

private func point(_ x: Double) -> DisplayPoint {
    DisplayPoint(x: x, y: 40)
}

private func touch(_ phase: TouchEvent.Phase, _ x: Double = 0) -> InputEvent {
    .touch(TouchEvent(phase: phase, pointerID: 0, position: point(x), time: stamp))
}

private func hover(_ action: MouseEvent.Action, _ x: Double = 0) -> InputEvent {
    .mouse(MouseEvent(action: action, position: point(x), buttons: MouseButtons(rawValue: 0), time: stamp))
}

private func scroll(_ vertical: Double, _ horizontal: Double = 0, x: Double = 0) -> InputEvent {
    .scroll(ScrollEvent(position: point(x), vertical: vertical, horizontal: horizontal, time: stamp))
}

/// The Guest-side kinds of a batch, in order, for the assertions on the merged output.
private func kinds(_ batch: GPInputBatch) -> [GPInputEvent.OneOf_Kind] {
    batch.events.compactMap(\.kind)
}

private func allEvents(_ channel: RecordingInputChannel) async -> [GPInputEvent] {
    await channel.batches.flatMap(\.events)
}

/// A router over `channel`, with `session` registered on display 7 in `state`.
private func makeRouter(
    _ channel: RecordingInputChannel,
    clock: TestClock,
    session: SessionID,
    state: AppSessionState = .running
) async -> InputRouter {
    let router = InputRouter(channel: channel, clock: { clock.now })
    await router.register(session: session, displayID: display, state: state)
    await router.focusChanged(session, focused: true)
    return router
}

private func eventually(within seconds: Double = 5, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// The kind of a message, for the assertions on the order of a batch.
private func label(_ event: GPInputEvent) -> String {
    switch event.kind {
    case .touch: "touch"
    case .mouse: "mouse"
    case .scroll: "scroll"
    case .key: "key"
    case .longPress: "longPress"
    case .cancelAll: "cancelAll"
    case nil: "none"
    }
}

// MARK: - Ownership and state

@Test(.timeLimit(.minutes(1)))
func aBatchFromAnUnknownSessionIsDroppedAsInvalid() async {
    let channel = RecordingInputChannel()
    let router = InputRouter(channel: channel, clock: { 0 })
    await router.route([touch(.down), touch(.up)], from: .app(UUID()))
    let counters = await router.counters
    #expect(counters.droppedInvalid == 2)
    #expect(await channel.batches.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aDisplayCannotBeRegisteredToTwoSessions() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let first = SessionID.app(UUID())
    let second = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: first)

    let conflictingRegistration = await router.register(session: second, displayID: display, state: .running)
    await router.route([touch(.down)], from: second)

    #expect(conflictingRegistration == .displayAlreadyOwned)
    #expect(await router.counters.droppedInvalid == 1)
    #expect(await channel.batches.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func changingFocusCancelsTheOldSessionAndRoutesOnlyToTheNewOwner() async {
    let channel = RecordingInputChannel()
    let focus = RecordingFocusDisplay()
    let first = SessionID.app(UUID())
    let second = SessionID.app(UUID())
    let router = InputRouter(
        channel: channel,
        clock: { 0 },
        focusDisplay: { displayID in
            await focus.focus(displayID, after: await channel.batches)
        }
    )
    await router.register(session: first, displayID: 7, state: .running)
    await router.register(session: second, displayID: 8, state: .running)

    await router.focusChanged(first, focused: true)
    await router.route([touch(.down)], from: first)
    await router.focusChanged(second, focused: true)
    await router.route([touch(.down), touch(.up)], from: second)
    await router.route([touch(.up)], from: first)

    let batches = await channel.batches
    #expect(batches.map(\.displayID) == [7, 7, 8])
    #expect(label(batches[1].events[0]) == "cancelAll")
    let routedKinds = kinds(batches[2])
    #expect(routedKinds.count == 2)
    #expect(routedKinds.allSatisfy { if case .touch = $0 { true } else { false } })
    let focusCalls = await focus.calls
    #expect(focusCalls.map(\.displayID) == [7, 8])
    #expect(focusCalls[0].cancelDisplayIDsAlreadySent.isEmpty)
    #expect(focusCalls[1].cancelDisplayIDsAlreadySent == [7])
    #expect(await router.counters.droppedNotFocused == 1)
}

@Test(.timeLimit(.minutes(1)))
func aFailedGuestFocusOperationDropsTheSessionInput() async {
    let channel = RecordingInputChannel()
    let session = SessionID.app(UUID())
    let router = InputRouter(
        channel: channel,
        clock: { 0 },
        focusDisplay: { _ in throw GuestProtocolFailure.disconnected }
    )
    await router.register(session: session, displayID: display, state: .running)

    await router.focusChanged(session, focused: true)
    await router.route([touch(.down)], from: session)

    #expect(await channel.batches.isEmpty)
    #expect(await router.counters.droppedNotFocused == 1)
    #expect(await router.counters.eventsSent == 0)
}

@Test(.timeLimit(.minutes(1)))
func aFocusedSessionRetriesGuestFocusAfterItsTaskAppears() async {
    let channel = RecordingInputChannel()
    let session = SessionID.app(UUID())
    let focus = RetryableFocusDisplay()
    let router = InputRouter(
        channel: channel,
        clock: { 0 },
        focusDisplay: { _ in try await focus.focus() }
    )
    await router.register(session: session, displayID: display, state: .running)

    await router.focusChanged(session, focused: true, generation: 7)
    await router.route([touch(.down)], from: session)
    await router.focusChanged(session, focused: true, generation: 7)
    await router.route([touch(.down)], from: session)

    #expect(await focus.calls == 2)
    #expect(await router.counters.droppedNotFocused == 1)
    #expect(await router.counters.eventsSent == 1)
    #expect(await channel.batches.map(\.displayID) == [display])
}

@Test(.timeLimit(.minutes(1)))
func anOlderFocusCallbackCannotTakeFocusBackFromANewerWindow() async {
    let channel = RecordingInputChannel()
    let focus = RecordingFocusDisplay()
    let first = SessionID.app(UUID())
    let second = SessionID.app(UUID())
    let router = InputRouter(
        channel: channel,
        clock: { 0 },
        focusDisplay: { displayID in
            await focus.focus(displayID, after: await channel.batches)
        }
    )
    await router.register(session: first, displayID: 7, state: .running)
    await router.register(session: second, displayID: 8, state: .running)

    await router.focusChanged(second, focused: true, generation: 2)
    await router.focusChanged(first, focused: true, generation: 1)
    await router.route([touch(.down)], from: second)
    await router.route([touch(.down)], from: first)

    #expect(await channel.batches.map(\.displayID) == [8])
    #expect(await focus.calls.map(\.displayID) == [8])
    #expect(await router.counters.droppedNotFocused == 1)
}

@Test(.timeLimit(.minutes(1)))
func endingANonFocusedSessionLeavesItsFocusedSiblingRoutable() async {
    let channel = RecordingInputChannel()
    let focus = RecordingFocusDisplay()
    let focused = SessionID.app(UUID())
    let background = SessionID.app(UUID())
    let router = InputRouter(
        channel: channel,
        clock: { 0 },
        focusDisplay: { displayID in
            await focus.focus(displayID, after: await channel.batches)
        }
    )
    await router.register(session: focused, displayID: 7, state: .running)
    await router.register(session: background, displayID: 8, state: .running)
    await router.focusChanged(focused, focused: true)

    await router.sessionEnded(background)
    await router.route([touch(.down), touch(.up)], from: focused)

    let batches = await channel.batches
    #expect(batches.map(\.displayID) == [7])
    #expect(kinds(batches[0]).count == 2)
    #expect(await focus.calls.map(\.displayID) == [7])
    #expect(await router.counters.droppedNotFocused == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: [AppSessionState.launching, .closing, .ended(.userClosed)])
func aSessionThatDoesNotAcceptInputDropsItsEvents(state: AppSessionState) async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session, state: state)
    await router.route([touch(.down), touch(.up)], from: session)
    let counters = await router.counters
    #expect(counters.droppedNotRunning == 2)
    #expect(await channel.batches.isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [AppSessionState.running, .backgrounded])
func aRunningOrBackgroundedSessionRoutesItsEvents(state: AppSessionState) async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session, state: state)
    await router.route([touch(.down), touch(.up)], from: session)
    #expect(await channel.batches.count == 1)
    #expect(await router.counters.eventsSent == 2)
}

@Test(.timeLimit(.minutes(1)))
func theStateChangesTheNextBatch() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await router.route([touch(.down)], from: session)
    await router.setState(.backgrounded, for: session)
    await router.route([touch(.move)], from: session)
    await router.setState(.ended(.userClosed), for: session)
    await router.route([touch(.up)], from: session)
    #expect(await channel.batches.count == 2)
    #expect(await router.counters.droppedNotRunning == 1)
}

@Test(.timeLimit(.minutes(1)))
func theDisplayComesFromTheLeaseAndNeverFromTheEvent() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await router.route([touch(.down, 100), hover(.hoverMove, 5)], from: session)
    let batch = await channel.batches.first
    #expect(batch?.displayID == display)
    #expect(batch?.hostSendNanos == 0)
}

// MARK: - Rate limit

@Test(.timeLimit(.minutes(1)))
func aSessionIsLimitedToTwoThousandEventsInASlidingSecond() async throws {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    // t = 0: 1500 admitted.
    await router.route(Array(repeating: touch(.move, 1), count: 1_500), from: session)
    clock.advance(milliseconds: 600)
    // t = 600: 500 more fill the window of 2000.
    await router.route(Array(repeating: touch(.move, 2), count: 500), from: session)
    clock.advance(milliseconds: 300)
    // t = 900: the window is full, so the event is dropped.
    await router.route([touch(.move, 3)], from: session)
    #expect(await router.counters.droppedRate == 1)
    clock.advance(milliseconds: 100)
    // t = 1000: the 1500 of t = 0 have left the window, so 1500 fit again.
    await router.route(Array(repeating: touch(.move, 4), count: 1_500), from: session)
    let counters = await router.counters
    #expect(counters.droppedRate == 1)
    #expect(counters.eventsSent == 3_500)
    #expect(await allEvents(channel).count == 3_500)
}

@Test(.timeLimit(.minutes(1)))
func theExcessOverTheLimitIsDroppedInTheOrderOfTheBatch() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    let events = (0..<2_005).map { index in touch(.move, Double(index)) }
    await router.route(events, from: session)
    let sent = await allEvents(channel)
    #expect(sent.count == 2_000)
    #expect(await router.counters.droppedRate == 5)
    // The first events of the batch are the ones that are kept.
    #expect(sent.last?.touch.x == 1_999)
}

@Test(.timeLimit(.minutes(1)))
func aBatchOverTheLimitKeepsEveryGestureEndAndKeyAndDropsOnlyMovesAndScrolls() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    let press = MouseEvent(action: .press(.secondary), position: point(0), buttons: .secondary, time: stamp)
    let release = MouseEvent(action: .release(.secondary), position: point(0), buttons: [], time: stamp)
    let key = KeyEvent(action: .down, androidKeyCode: 29, metaState: [], repeatCount: 0, time: stamp)
    // One DOWN, 1500 moves, and 600 scrolls, then the events that end gestures, a key, and the cancel, all after the limit.
    var batch: [InputEvent] = [touch(.down, 1)]
    batch += Array(repeating: touch(.move, 2), count: 1_500)
    batch += Array(repeating: scroll(1), count: 600)
    batch += [touch(.up, 3), touch(.cancel, 3), .mouse(press), .mouse(release), .key(key), .cancelAll(stamp)]
    await router.route(batch, from: session)
    let sent = await allEvents(channel)
    // The window holds 2000: the DOWN and the 1500 moves, 499 scrolls, then the six events that are never dropped.
    #expect(sent.count == 2_006)
    #expect(sent.filter { label($0) == "scroll" }.count == 499)
    #expect(await router.counters.droppedRate == 101)
    #expect(sent.suffix(6).map(label) == ["touch", "touch", "mouse", "mouse", "key", "cancelAll"])
    #expect(sent.suffix(6).prefix(2).map { $0.touch.phase } == [.up, .cancel])
    // The events that were never dropped count against the window as they pass, so a move in the same second is dropped
    // while the up is kept.
    await router.route([touch(.move, 4), touch(.up, 4)], from: session)
    #expect(await router.counters.droppedRate == 102)
    #expect(await allEvents(channel).count == 2_007)
}

// MARK: - Coalescing

@Test(.timeLimit(.minutes(1)))
func aBacklogAboveSixtyFourKiBMergesConsecutiveMoves() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await channel.setBacklog(InputRouter.coalescingBacklogBytes + 1)
    await router.route(
        [touch(.down, 0), touch(.move, 1), touch(.move, 2), touch(.move, 3), touch(.up, 3)], from: session)
    let sent = await allEvents(channel)
    #expect(sent.count == 3)
    #expect(sent.map { $0.touch.phase } == [.down, .move, .up])
    // The merged move keeps the position of the latest move.
    #expect(sent[1].touch.x == 3)
    #expect(await router.counters.coalesced == 2)
}

@Test(.timeLimit(.minutes(1)))
func aBacklogAtTheLimitDoesNotMerge() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await channel.setBacklog(InputRouter.coalescingBacklogBytes)
    await router.route([touch(.move, 1), touch(.move, 2)], from: session)
    #expect(await allEvents(channel).count == 2)
    #expect(await router.counters.coalesced == 0)
}

@Test(.timeLimit(.minutes(1)))
func hoverMovesMergeAndScrollsAddUpTheirAxes() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await channel.setBacklog(InputRouter.coalescingBacklogBytes + 1)
    await router.route(
        [hover(.hoverMove, 1), hover(.hoverMove, 2), hover(.hoverMove, 3), scroll(1.5, 2, x: 1), scroll(3, -1, x: 9)],
        from: session)
    let sent = await allEvents(channel)
    #expect(sent.count == 2)
    #expect(sent[0].mouse.action == .hoverMove)
    #expect(sent[0].mouse.x == 3)
    #expect(sent[1].scroll.vscroll == 4.5)
    #expect(sent[1].scroll.hscroll == 1)
    #expect(sent[1].scroll.x == 9)
    #expect(await router.counters.coalesced == 3)
}

@Test(.timeLimit(.minutes(1)))
func theEventsThatMustStayAreNeverMerged() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await channel.setBacklog(InputRouter.coalescingBacklogBytes + 1)
    let pairs: [[InputEvent]] = [
        [touch(.down), touch(.down)],
        [touch(.up), touch(.up)],
        [touch(.cancel), touch(.cancel)],
        [
            .mouse(MouseEvent(action: .press(.primary), position: point(0), buttons: .primary, time: stamp)),
            .mouse(MouseEvent(action: .press(.primary), position: point(0), buttons: .primary, time: stamp)),
        ],
        [
            .mouse(MouseEvent(action: .release(.secondary), position: point(0), buttons: [], time: stamp)),
            .mouse(MouseEvent(action: .release(.secondary), position: point(0), buttons: [], time: stamp)),
        ],
        [
            .key(KeyEvent(action: .down, androidKeyCode: 29, metaState: [], repeatCount: 0, time: stamp)),
            .key(KeyEvent(action: .down, androidKeyCode: 29, metaState: [], repeatCount: 0, time: stamp)),
        ],
        [.longPress(point(0), stamp), .longPress(point(0), stamp)],
        [.cancelAll(stamp), .cancelAll(stamp)],
    ]
    for pair in pairs {
        await router.route(pair, from: session)
    }
    #expect(await allEvents(channel).count == pairs.count * 2)
    #expect(await router.counters.coalesced == 0)
}

@Test(.timeLimit(.minutes(1)))
func theOrderOfEventsIsKeptWhenMerging() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await channel.setBacklog(InputRouter.coalescingBacklogBytes + 1)
    await router.route(
        [
            touch(.down), touch(.move, 1), touch(.move, 2), hover(.hoverEnter), hover(.hoverMove, 3), scroll(1),
            scroll(2), touch(.up),
        ],
        from: session)
    let sent = await allEvents(channel)
    #expect(sent.map(label) == ["touch", "touch", "mouse", "mouse", "scroll", "touch"])
    #expect(await router.counters.coalesced == 2)
}

// MARK: - Session end

@Test(.timeLimit(.minutes(1)))
func cancelAllRegisteredDisplaysSendsOneCancellationPerCurrentLease() async {
    let channel = RecordingInputChannel()
    let router = InputRouter(channel: channel, clock: { 1 })
    let first = SessionID.app(UUID())
    let second = SessionID.app(UUID())
    await router.register(session: first, displayID: 7, state: .running)
    await router.register(session: second, displayID: 8, state: .launching)

    await router.cancelAllRegisteredDisplays()
    await router.sessionEnded(second)
    await router.cancelAllRegisteredDisplays()

    let batches = await channel.batches
    #expect(batches.map(\.displayID) == [7, 8, 7])
    #expect(batches.allSatisfy { kinds($0) == [.cancelAll(GPCancelAll())] })
}

@Test(.timeLimit(.minutes(1)))
func sessionEndedSendsCancelAllAndRemovesTheSession() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await router.route([touch(.down)], from: session)
    await router.sessionEnded(session)
    await router.sessionEnded(session)
    let batches = await channel.batches
    #expect(batches.count == 2)
    #expect(batches.last.map(kinds) == [.cancelAll(GPCancelAll())])
    // The session is gone, so a later batch names an unknown session.
    await router.route([touch(.move)], from: session)
    #expect(await router.counters.droppedInvalid == 1)
    #expect(await channel.batches.count == 2)
}

// MARK: - Batches

@Test(.timeLimit(.minutes(1)))
func aLongBatchIsSplitIntoBatchesOfAtMost256Events() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await router.route(Array(repeating: touch(.move, 1), count: 600), from: session)
    let batches = await channel.batches
    #expect(batches.map { $0.events.count } == [256, 256, 88])
    #expect(batches.map(\.batchSeq) == [1, 2, 3])
    #expect(batches.allSatisfy { $0.displayID == display })
}

@Test(.timeLimit(.minutes(1)))
func everyThirtySecondBatchAsksForAnAckAndTheSequenceCountsUp() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    // One batch of 256 events a second stays within the rate limit.
    for _ in 0..<33 {
        await router.route(Array(repeating: touch(.move, 1), count: 256), from: session)
        clock.advance(milliseconds: 1_000)
    }
    let batches = await channel.batches
    #expect(batches.map(\.batchSeq) == Array(1...33).map(UInt64.init))
    #expect(batches.filter(\.ackRequested).map(\.batchSeq) == [32])
}

@Test(.timeLimit(.minutes(1)))
func aBatchThatIsSentInPartsKeepsItsOrderAcrossConcurrentRoutes() async throws {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    let long = Array(repeating: touch(.move, 1), count: 300)
    let short = Array(repeating: touch(.up, 2), count: 10)
    async let first: Void = router.route(long, from: session)
    async let second: Void = router.route(short, from: session)
    await first
    await second
    let sizes = await channel.batches.map { $0.events.count }
    // Either the long batch goes first, or the short one does, and the parts of the long batch stay together.
    #expect(sizes == [256, 44, 10] || sizes == [10, 256, 44])
}

@Test(.timeLimit(.minutes(1)))
func aChannelFailureCountsTheEventsThatWereNotSent() async {
    let channel = RecordingInputChannel()
    let clock = TestClock()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: clock, session: session)
    await channel.succeedFirst(1)
    await router.route(Array(repeating: touch(.move, 1), count: 300), from: session)
    let counters = await router.counters
    #expect(counters.batchesSent == 1)
    #expect(counters.eventsSent == 256)
    #expect(counters.droppedChannel == 44)
}

// MARK: - Acks

@Test(.timeLimit(.minutes(1)))
func rejectedEventsInAnAckAreCountedAsInvalid() async throws {
    let channel = RecordingInputChannel()
    let router = InputRouter(channel: channel, clock: { 0 })
    channel.deliverAck(batchSeq: 32, rejected: 3)
    try await eventually { await router.counters.droppedInvalid == 3 }
    #expect(await router.counters.droppedInvalid == 3)
}

@Test(.timeLimit(.minutes(1)))
func acknowledgementHistoryRetainsSequenceAndRejectionCounts() async throws {
    let channel = RecordingInputChannel()
    let router = InputRouter(channel: channel, clock: { 0 })
    _ = await router.startAcknowledgementHistoryCapture()
    channel.deliverAck(
        batchSeq: 32,
        rejected: 0,
        receiveToInjectMicros: 350,
        lastEventTimeMillis: 12_345
    )
    channel.deliverAck(
        batchSeq: 64,
        rejected: 2,
        receiveToInjectMicros: 900,
        lastEventTimeMillis: 12_678
    )
    try await eventually { await router.acknowledgementHistory.records.count == 2 }
    let records = await router.acknowledgementHistory.records
    #expect(
        records == [
            InputAcknowledgementHistory.Record(
                batchSequence: 32,
                rejectedEvents: 0,
                receiveToInjectMicros: 350,
                lastEventTimeMillis: 12_345
            ),
            InputAcknowledgementHistory.Record(
                batchSequence: 64,
                rejectedEvents: 2,
                receiveToInjectMicros: 900,
                lastEventTimeMillis: 12_678
            ),
        ])
}

@Test(.timeLimit(.minutes(1)))
func acknowledgementHistoryCaptureIsOptInAndCanBeStopped() async throws {
    let channel = RecordingInputChannel()
    let router = InputRouter(channel: channel, clock: { 0 })
    channel.deliverAck(batchSeq: 31, rejected: 1)
    try await eventually { await router.counters.droppedInvalid == 1 }
    #expect(await router.acknowledgementHistory.records.isEmpty)
    #expect(await router.sentEventHistory.records.isEmpty)

    _ = await router.startAcknowledgementHistoryCapture()
    channel.deliverAck(batchSeq: 32, rejected: 0)
    try await eventually { await router.acknowledgementHistory.records.count == 1 }
    let captured = await router.stopAcknowledgementHistoryCapture()
    channel.deliverAck(batchSeq: 33, rejected: 1)
    try await eventually { await router.counters.droppedInvalid == 2 }

    #expect(captured.records.map(\.batchSequence) == [32])
    #expect(captured.records[0].receiveToInjectMicros == 0)
    #expect(captured.records[0].lastEventTimeMillis == 0)
    #expect(await router.acknowledgementHistory.records.map(\.batchSequence) == [32])
}

@Test(.timeLimit(.minutes(1)))
func acknowledgementHistoryExcludesAnEarlierBatchWhoseAckArrivesLate() async throws {
    let channel = RecordingInputChannel()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: TestClock(), session: session)
    await router.route([touch(.down)], from: session)

    _ = await router.startAcknowledgementHistoryCapture()
    channel.deliverAck(batchSeq: 1, rejected: 1)
    try await eventually { await router.counters.droppedInvalid == 1 }
    #expect(await router.acknowledgementHistory.records.isEmpty)

    await router.route([touch(.up)], from: session)
    channel.deliverAck(batchSeq: 2, rejected: 0)
    try await eventually { await router.acknowledgementHistory.records.count == 1 }
    #expect(await router.acknowledgementHistory.records.map(\.batchSequence) == [2])
}

@Test(.timeLimit(.minutes(1)))
func sentEventHistoryCapturesBatchSequenceIndexTimeAndPhase() async {
    let channel = RecordingInputChannel()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: TestClock(), session: session)
    _ = await router.startAcknowledgementHistoryCapture(captureSentEventHistory: true)
    await router.route(
        [
            .touch(TouchEvent(phase: .down, pointerID: 7, position: point(10), time: InputTimestamp(hostNanos: 123))),
            .touch(TouchEvent(phase: .up, pointerID: 7, position: point(10), time: InputTimestamp(hostNanos: 456))),
        ],
        from: session
    )

    let batches = await channel.batches
    let history = await router.sentEventHistory
    #expect(batches.count == 1)
    #expect(batches.first?.events.count == 2)
    #expect(history.records.map(\.batchSequence) == [1, 1])
    #expect(history.records.map(\.eventIndex) == [0, 1])
    #expect(history.records.map(\.hostTimeNanos) == [123, 456])
    #expect(history.records.map(\.kindAndPhase) == ["touch.down", "touch.up"])
    #expect(history.discardedRecords == 0)
}

@Test(.timeLimit(.minutes(1)))
func sentEventHistoryIsOptInAndStopsCapturing() async {
    let channel = RecordingInputChannel()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: TestClock(), session: session)
    await router.route([touch(.down, 1)], from: session)
    #expect(await router.sentEventHistory.records.isEmpty)

    _ = await router.startAcknowledgementHistoryCapture()
    await router.route([touch(.move, 2)], from: session)
    #expect(await router.sentEventHistory.records.isEmpty)

    _ = await router.stopAcknowledgementHistoryCapture()
    _ = await router.startAcknowledgementHistoryCapture(captureSentEventHistory: true)
    await router.route([touch(.move, 3)], from: session)
    let captured = await router.sentEventHistory
    #expect(captured.records.map(\.kindAndPhase) == ["touch.move"])

    _ = await router.stopAcknowledgementHistoryCapture()
    await router.route([touch(.up, 4)], from: session)
    #expect(await router.sentEventHistory.records == captured.records)
}

@Test(.timeLimit(.minutes(1)))
func perEventCaptureUsesSingleEventBatchesAndRequestsEachAck() async {
    let channel = RecordingInputChannel()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: TestClock(), session: session)
    _ = await router.startAcknowledgementHistoryCapture(
        everyBatch: true, captureSentEventHistory: true)
    await router.route([touch(.down, 1), touch(.move, 2), touch(.up, 3)], from: session)

    let batches = await channel.batches
    let history = await router.sentEventHistory
    #expect(batches.map(\.batchSeq) == [1, 2, 3])
    #expect(batches.map { $0.events.count } == [1, 1, 1])
    #expect(batches.allSatisfy { $0.ackRequested })
    #expect(batches.allSatisfy { !$0.traceEventTime })
    #expect(history.records.map(\.batchSequence) == [1, 2, 3])
    #expect(history.records.map(\.eventIndex) == [0, 0, 0])
}

@Test(.timeLimit(.minutes(1)))
func perEventCaptureRequestsGuestEventTimeOnlyWhenCapabilityWasNegotiated() async {
    let channel = RecordingInputChannel(
        negotiatedCapabilities: [GuestCapability.inputAckTrace.rawValue]
    )
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: TestClock(), session: session)
    _ = await router.startAcknowledgementHistoryCapture(everyBatch: true)
    await router.route([touch(.down)], from: session)

    let batches = await channel.batches
    #expect(batches.count == 1)
    #expect(batches[0].ackRequested)
    #expect(batches[0].traceEventTime)
}

@Test(.timeLimit(.minutes(1)))
func sentEventHistoryMakesOverflowExplicit() async {
    let channel = RecordingInputChannel()
    let session = SessionID.app(UUID())
    let router = await makeRouter(channel, clock: TestClock(), session: session)
    _ = await router.startAcknowledgementHistoryCapture(
        everyBatch: true, captureSentEventHistory: true)
    let events = (0..<300).map { index in
        InputEvent.touch(
            TouchEvent(
                phase: .down,
                pointerID: index,
                position: point(Double(index)),
                time: InputTimestamp(hostNanos: UInt64(index))
            )
        )
    }
    await router.route(events, from: session)

    let history = await router.sentEventHistory
    #expect(history.records.count == InputRouter.sentEventHistoryLimit)
    #expect(history.discardedRecords == 300 - InputRouter.sentEventHistoryLimit)
    #expect(history.records.first?.hostTimeNanos == UInt64(300 - InputRouter.sentEventHistoryLimit))
    #expect(history.records.last?.hostTimeNanos == 299)
}

@Test(.timeLimit(.minutes(1)))
func acknowledgementHistoryDiscardsOldRecordsAtItsBound() async throws {
    let channel = RecordingInputChannel()
    let router = InputRouter(channel: channel, clock: { 0 })
    _ = await router.startAcknowledgementHistoryCapture()
    for sequence in 1...300 {
        channel.deliverAck(batchSeq: UInt64(sequence), rejected: 0)
    }
    try await eventually {
        let history = await router.acknowledgementHistory
        return history.records.count == InputRouter.acknowledgementHistoryLimit
            && history.discardedRecords == 300 - InputRouter.acknowledgementHistoryLimit
    }
    let history = await router.acknowledgementHistory
    #expect(history.records.map(\.batchSequence) == Array(45...300).map(UInt64.init))
    #expect(history.records.allSatisfy { $0.rejectedEvents == 0 })
    #expect(history.discardedRecords == 44)
}
