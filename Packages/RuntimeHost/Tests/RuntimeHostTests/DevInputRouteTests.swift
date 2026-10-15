import DiagnosticsCore
import Foundation
import GuestProtocol
import InputCore
import RuntimeAPI
import RuntimeCore
import Testing

@testable import RuntimeHost

/// The conversion of the wire input to InputCore (runtime-api.md §7.2, decision D10), and the development route
/// (runtime-api.md §7.3).

/// A channel that keeps the batches it is sent.
actor CollectingInputChannel: InputChannel {
    private(set) var batches: [GPInputBatch] = []
    /// The acks of this channel: none, so the stream is finished from the start.
    nonisolated let acks: AsyncStream<GPInputAck>

    init() {
        let stream = AsyncStream.makeStream(of: GPInputAck.self)
        stream.continuation.finish()
        acks = stream.stream
    }

    func send(_ batch: GPInputBatch) async throws {
        batches.append(batch)
    }

    var pendingBytes: Int {
        0
    }
}

actor AcknowledgingInputChannel: InputChannel {
    nonisolated let acks: AsyncStream<GPInputAck>
    private nonisolated let continuation: AsyncStream<GPInputAck>.Continuation
    nonisolated let negotiatedCapabilities: Set<String>?

    init(negotiatedCapabilities: Set<String>? = nil) {
        let stream = AsyncStream.makeStream(of: GPInputAck.self, bufferingPolicy: .unbounded)
        acks = stream.stream
        continuation = stream.continuation
        self.negotiatedCapabilities = negotiatedCapabilities
    }

    func send(_ batch: GPInputBatch) async throws {}

    var pendingBytes: Int {
        0
    }

    nonisolated func deliverAck(
        batchSequence: UInt64,
        rejectedEvents: UInt32,
        receiveToInjectMicros: UInt32 = 0,
        lastEventTimeMillis: UInt64 = 0
    ) {
        var ack = GPInputAck()
        ack.batchSeq = batchSequence
        ack.rejectedEvents = rejectedEvents
        ack.receiveToInjectMicros = receiveToInjectMicros
        ack.lastEventTimeMillis = lastEventTimeMillis
        continuation.yield(ack)
    }

    nonisolated func finish() {
        continuation.finish()
    }
}

private let wireTime = RuntimeAPI.InputTimestamp(hostNanos: 77)
private let wirePoint = RuntimeAPI.DisplayPoint(x: 12.5, y: 3)
private let corePoint = InputCore.DisplayPoint(x: 12.5, y: 3)
private let coreTime = InputCore.InputTimestamp(hostNanos: 77)

@Test func everyWireCaseConvertsToItsInputCoreValue() {
    let touch = RuntimeAPI.WireInputEvent.touch(
        RuntimeAPI.WireTouchEvent(phase: .move, pointerID: 0, position: wirePoint, time: wireTime))
    #expect(
        WireInputConversion.event(touch)
            == .touch(InputCore.TouchEvent(phase: .move, pointerID: 0, position: corePoint, time: coreTime)))

    let mouse = RuntimeAPI.WireInputEvent.mouse(
        RuntimeAPI.WireMouseEvent(action: .hoverExit, position: wirePoint, buttons: 0, time: wireTime))
    #expect(
        WireInputConversion.event(mouse)
            == .mouse(
                InputCore.MouseEvent(action: .hoverExit, position: corePoint, buttons: [], time: coreTime)))

    let scroll = RuntimeAPI.WireInputEvent.scroll(
        RuntimeAPI.WireScrollEvent(position: wirePoint, vertical: -1.5, horizontal: 0.25, time: wireTime))
    #expect(
        WireInputConversion.event(scroll)
            == .scroll(
                InputCore.ScrollEvent(position: corePoint, vertical: -1.5, horizontal: 0.25, time: coreTime)))

    let key = RuntimeAPI.WireInputEvent.key(
        RuntimeAPI.WireKeyEvent(action: .up, androidKeyCode: 66, metaState: 0x1000, repeatCount: 2, time: wireTime))
    #expect(
        WireInputConversion.event(key)
            == .key(
                InputCore.KeyEvent(
                    action: .up,
                    androidKeyCode: 66,
                    metaState: InputCore.AndroidMetaState(rawValue: 0x1000),
                    repeatCount: 2,
                    time: coreTime)))

    #expect(
        WireInputConversion.event(.longPress(wirePoint, wireTime))
            == .longPress(corePoint, coreTime))
    #expect(
        WireInputConversion.event(.cancelAll(wireTime))
            == .cancelAll(coreTime))
}

@Test func everyTouchPhaseConverts() {
    let pairs: [(RuntimeAPI.TouchPhase, InputCore.TouchEvent.Phase)] = [
        (.down, .down), (.move, .move), (.up, .up), (.cancel, .cancel),
    ]
    for (wire, core) in pairs {
        #expect(WireInputConversion.phase(wire) == core)
    }
}

@Test func everyMouseButtonAndMouseActionConverts() {
    let buttons: [(RuntimeAPI.MouseButton, InputCore.MouseButton, Int32)] = [
        (.primary, .primary, 1), (.secondary, .secondary, 2), (.tertiary, .tertiary, 4), (.back, .back, 8),
        (.forward, .forward, 16),
    ]
    for (wire, core, bit) in buttons {
        #expect(WireInputConversion.mouseButton(wire) == core)
        #expect(WireInputConversion.mouseButton(wire).androidButtonBit == bit)
        #expect(WireInputConversion.mouseAction(.press(wire)) == .press(core))
        #expect(WireInputConversion.mouseAction(.release(wire)) == .release(core))
    }
    #expect(WireInputConversion.mouseAction(.hoverEnter) == .hoverEnter)
    #expect(WireInputConversion.mouseAction(.hoverMove) == .hoverMove)
    #expect(WireInputConversion.mouseAction(.hoverExit) == .hoverExit)
}

@Test func keyActionsConvert() {
    #expect(WireInputConversion.keyAction(.down) == .down)
    #expect(WireInputConversion.keyAction(.up) == .up)
}

@Test func aBatchKeepsItsOrderWhenItIsConverted() {
    let wire: [RuntimeAPI.WireInputEvent] = [
        .touch(RuntimeAPI.WireTouchEvent(phase: .down, pointerID: 0, position: wirePoint, time: wireTime)),
        .cancelAll(wireTime),
        .touch(RuntimeAPI.WireTouchEvent(phase: .up, pointerID: 0, position: wirePoint, time: wireTime)),
    ]
    let events = WireInputConversion.events(wire)
    #expect(events.count == 3)
    #expect(events[1] == .cancelAll(coreTime))
    if case .touch(let last) = events[2] {
        #expect(last.phase == .up)
    } else {
        Issue.record("the last event is not a touch")
    }
}

// MARK: - The development route

@Test(.timeLimit(.minutes(1)))
func anUnboundRouteDropsItsEventsAsNotRunning() async {
    let route = DevInputRoute()
    await route.send(
        RuntimeAPI.InputBatch(events: [
            .cancelAll(wireTime),
            .cancelAll(wireTime),
            .cancelAll(wireTime),
        ]))
    let counters = await route.counters()
    #expect(counters.droppedNotRunning == 3)
    #expect(counters.eventsSent == 0)
}

@Test(.timeLimit(.minutes(1)))
func aBoundRouteSendsItsEventsOnDisplayZero() async {
    let channel = CollectingInputChannel()
    let route = DevInputRoute()
    await route.bind(router: InputRouter(channel: channel))
    await route.send(
        RuntimeAPI.InputBatch(events: [
            .touch(RuntimeAPI.WireTouchEvent(phase: .down, pointerID: 0, position: wirePoint, time: wireTime))
        ]))
    let batches = await channel.batches
    #expect(batches.count == 1)
    #expect(batches.first?.displayID == 0)
    #expect(batches.first?.events.first?.touch.phase == .down)
    #expect(await route.counters().eventsSent == 1)
    #expect(await route.sentEventHistory().records.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aBoundRouteExposesTheAcknowledgementCoverageItReceives() async throws {
    let channel = AcknowledgingInputChannel()
    let route = DevInputRoute()
    await route.bind(router: InputRouter(channel: channel))
    await route.send(
        RuntimeAPI.InputBatch(events: [
            .touch(RuntimeAPI.WireTouchEvent(phase: .down, pointerID: 0, position: wirePoint, time: wireTime))
        ]))
    let captureBaseline = await route.startAcknowledgementHistoryCapture()
    #expect(captureBaseline?.batchesSent == 1)
    #expect(captureBaseline?.eventsSent == 1)
    channel.deliverAck(
        batchSequence: 32,
        rejectedEvents: 0,
        receiveToInjectMicros: 250,
        lastEventTimeMillis: 44_001
    )
    channel.deliverAck(
        batchSequence: 64,
        rejectedEvents: 1,
        receiveToInjectMicros: 800,
        lastEventTimeMillis: 44_245
    )

    var history = await route.acknowledgementHistory()
    for _ in 0..<100 where history.records.count < 2 {
        try await Task.sleep(for: .milliseconds(5))
        history = await route.acknowledgementHistory()
    }
    #expect(history.records.map(\.batchSequence) == [32, 64])
    #expect(history.records.map(\.rejectedEvents) == [0, 1])
    #expect(history.records.map(\.receiveToInjectMicros) == [250, 800])
    #expect(history.records.map(\.lastEventTimeMillis) == [44_001, 44_245])
    channel.finish()
    await route.unbind()
}

@Test(.timeLimit(.minutes(1)))
func aBoundRouteReportsWhetherGuestAckEventTimesWereNegotiated() async {
    let supported = DevInputRoute()
    await supported.bind(
        router: InputRouter(channel: AcknowledgingInputChannel(negotiatedCapabilities: ["input.ack_trace.v1"])))
    #expect(await supported.supportsAcknowledgementEventTimeTrace())

    let legacy = DevInputRoute()
    await legacy.bind(router: InputRouter(channel: AcknowledgingInputChannel()))
    #expect(!(await legacy.supportsAcknowledgementEventTimeTrace()))
    #expect(!(await DevInputRoute().supportsAcknowledgementEventTimeTrace()))
}

@Test(.timeLimit(.minutes(1)))
func anOptInPerEventCaptureUsesSingleEventBatches() async {
    let channel = CollectingInputChannel()
    let route = DevInputRoute()
    await route.bind(router: InputRouter(channel: channel))
    let baseline = await route.startAcknowledgementHistoryCapture(everyBatch: true)
    #expect(baseline?.batchesSent == 0)
    await route.send(
        RuntimeAPI.InputBatch(events: [
            .touch(RuntimeAPI.WireTouchEvent(phase: .down, pointerID: 0, position: wirePoint, time: wireTime)),
            .touch(RuntimeAPI.WireTouchEvent(phase: .move, pointerID: 0, position: wirePoint, time: wireTime)),
            .touch(RuntimeAPI.WireTouchEvent(phase: .up, pointerID: 0, position: wirePoint, time: wireTime)),
        ]))

    let batches = await channel.batches
    let history = await route.sentEventHistory()
    #expect(batches.map(\.batchSeq) == [1, 2, 3])
    #expect(batches.map { $0.events.count } == [1, 1, 1])
    #expect(batches.allSatisfy { $0.ackRequested })
    #expect(history.records.map(\.batchSequence) == [1, 2, 3])
    #expect(history.records.map(\.eventIndex) == [0, 0, 0])
    #expect(history.records.map(\.kindAndPhase) == ["touch.down", "touch.move", "touch.up"])
    _ = await route.stopAcknowledgementHistoryCapture()
    await route.unbind()
}

@Test(.timeLimit(.minutes(1)))
func aBatchOfMoreThan512EventsIsCutAt512() async {
    let channel = CollectingInputChannel()
    let route = DevInputRoute()
    await route.bind(router: InputRouter(channel: channel))
    let events = (0..<600).map { index in
        RuntimeAPI.WireInputEvent.touch(
            RuntimeAPI.WireTouchEvent(
                phase: .move, pointerID: 0, position: RuntimeAPI.DisplayPoint(x: Double(index), y: 0), time: wireTime))
    }
    await route.send(RuntimeAPI.InputBatch(events: events))
    let batches = await channel.batches
    #expect(batches.map { $0.events.count } == [256, 256])
    let sent = batches.flatMap(\.events).map(\.touch.x)
    #expect(sent.count == 512)
    #expect(sent.last == 511)
    let counters = await route.counters()
    #expect(counters.droppedInvalid == 88)
    #expect(counters.eventsSent == 512)
}

@Test(.timeLimit(.minutes(1)))
func unbindingEndsTheSessionAndLaterEventsAreDropped() async {
    let channel = CollectingInputChannel()
    let route = DevInputRoute()
    await route.bind(router: InputRouter(channel: channel))
    await route.send(RuntimeAPI.InputBatch(events: [.cancelAll(wireTime)]))
    await route.unbind()
    await route.send(RuntimeAPI.InputBatch(events: [.cancelAll(wireTime)]))
    let batches = await channel.batches
    // The batch of the bound session, then the cancelAll that ends the session.
    #expect(batches.count == 2)
    let counters = await route.counters()
    #expect(counters.droppedNotRunning == 1)
}

@Test(.timeLimit(.minutes(1)))
func aRebindMovesTheSessionToTheNewChannelAndCancelsTheOld() async {
    // The agent restarts, so the binding builds a new router over a new channel (decision D11).
    let oldChannel = CollectingInputChannel()
    let newChannel = CollectingInputChannel()
    let route = DevInputRoute()
    await route.bind(router: InputRouter(channel: oldChannel))
    await route.bind(router: InputRouter(channel: newChannel))
    await route.send(RuntimeAPI.InputBatch(events: [.cancelAll(wireTime)]))
    // The old session ends with a cancelAll on the old channel, and the event goes to the new channel only.
    #expect(await oldChannel.batches.count == 1)
    #expect(await newChannel.batches.count == 1)
    #expect(await newChannel.batches.first?.displayID == 0)
}

@Test(.timeLimit(.minutes(1)))
func aRebindKeepsTheCountsOfTheRouterItReplaces() async {
    // The agent restarts, so the route binds a new router. The old router's counts (its events and its cancelAll at
    // the end of its session) stay in the total of the route.
    let oldChannel = CollectingInputChannel()
    let newChannel = CollectingInputChannel()
    let route = DevInputRoute()
    await route.bind(router: InputRouter(channel: oldChannel))
    await route.send(RuntimeAPI.InputBatch(events: [.cancelAll(wireTime)]))
    await route.bind(router: InputRouter(channel: newChannel))
    await route.send(RuntimeAPI.InputBatch(events: [.cancelAll(wireTime)]))
    // Old router: one cancelAll from the batch and one from the end of its session. New router: one cancelAll.
    let counters = await route.counters()
    #expect(counters.eventsSent == 3)
    #expect(counters.batchesSent == 3)
}

// MARK: - The warning of an unbound route

/// The warning that `apkrun dev boot --window` and `apkrun dev launch` print when the input is not bound. The warning is
/// a typed error, so its text, hint, and code come from the catalog (error-catalog.md runtime.inputNotBound). The CLI
/// prints it with ``ErrorPresenter/cli(_:)``, and the tests check that output.
@Test func anUnboundInputWarningWithoutAnAgentPrintsItsTextHintAndCode() {
    let error = RuntimeFailure.inputNotBound(cause: nil)
    #expect(error.qualifiedCode == "runtime.inputNotBound")
    #expect(ErrorCatalog.cliExit(for: error) == 0)

    let text = ErrorPresenter(locale: Locale(identifier: "en")).cli(error)
    let lines = text.split(separator: "\n").map(String.init)
    #expect(
        lines.first
            == "warning: Pointer and keyboard input are not bound to Android, because the Guest Agent is not running.")
    #expect(
        lines.contains {
            $0.hasPrefix("hint: Pointer and keyboard input stay off for this boot until the Guest Agent is running.")
                && $0.contains("apkrun dev boot --window")
        })
    #expect(lines.contains { $0.hasPrefix("code: runtime.inputNotBound") })
}

@Test func anUnboundInputWarningWithACausePrintsTheCauseAndTheSameHintAndCode() {
    let error = RuntimeFailure.inputNotBound(cause: .connectTimedOut)
    #expect(error.cause?.qualifiedCode == "runtime.guestAgentConnectTimedOut")
    #expect(ErrorCatalog.cliExit(for: error) == 0)

    let text = ErrorPresenter(locale: Locale(identifier: "en")).cli(error)
    let lines = text.split(separator: "\n").map(String.init)
    #expect(
        lines.first
            == "warning: Pointer and keyboard input are not bound to Android. APKRun couldn't connect to the Guest Agent within 5 seconds."
    )
    #expect(
        lines.contains {
            $0.hasPrefix("hint: Pointer and keyboard input stay off for this boot until the Guest Agent is running.")
        })
    #expect(lines.contains { $0.hasPrefix("code: runtime.inputNotBound") })
}
