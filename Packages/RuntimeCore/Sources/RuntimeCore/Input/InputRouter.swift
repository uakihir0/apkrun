import DiagnosticsCore
import Foundation
import GuestProtocol
import InputCore

/// The input stream that the router sends its batches through (input.md §8). The production channel is
/// ``GuestInputChannel``, and the tests use a fake.
public protocol InputChannel: Sendable {
    /// Sends one batch on the stream, in order. It throws when the stream cannot carry the batch.
    func send(_ batch: GPInputBatch) async throws
    /// The bytes that the stream holds and has not written yet. The router coalesces above a backlog (input.md §7.1).
    var pendingBytes: Int { get async }
    /// The acks of the stream. The stream finishes when the stream closes.
    var acks: AsyncStream<GPInputAck> { get }
    /// Capabilities negotiated on this stream, or `nil` when this channel does not expose a handshake.
    var negotiatedCapabilities: Set<String>? { get async }
}

extension InputChannel {
    /// Test and local channels may not have a protocol handshake.
    public var negotiatedCapabilities: Set<String>? {
        get async { nil }
    }
}

/// What the router dropped, merged, and sent (input.md §11). The diagnostics snapshot reads a copy of it.
public struct InputCounters: Equatable, Sendable {
    /// Events dropped over the rate limit of their session (`input.dropped.rate`).
    public var droppedRate = 0
    /// Events dropped because their session was not running or backgrounded (`input.dropped.notRunning`).
    public var droppedNotRunning = 0
    /// Events dropped because their session did not own the display or did not have window focus.
    public var droppedNotFocused = 0
    /// Events dropped for a session that is not registered, or rejected by the guest (`input.dropped.invalid`).
    public var droppedInvalid = 0
    /// Events dropped because the input stream could not carry them (`input.dropped.channel`).
    public var droppedChannel = 0
    /// Events merged into the event before them (`input.coalesced`).
    public var coalesced = 0
    /// Events sent on the input stream.
    public var eventsSent = 0
    /// Batches sent on the input stream.
    public var batchesSent = 0

    /// Creates counters with every count at zero.
    public init() {}

    /// Adds the counts of `other` to these.
    public mutating func add(_ other: InputCounters) {
        droppedRate += other.droppedRate
        droppedNotRunning += other.droppedNotRunning
        droppedNotFocused += other.droppedNotFocused
        droppedInvalid += other.droppedInvalid
        droppedChannel += other.droppedChannel
        coalesced += other.coalesced
        eventsSent += other.eventsSent
        batchesSent += other.batchesSent
    }
}

/// The bounded history of guest input acknowledgements (input.md §8).
public struct InputAcknowledgementHistory: Equatable, Sendable {
    /// The most recent acknowledgements, in receive order.
    public let records: [Record]
    /// Records evicted because the bounded history reached its limit.
    public let discardedRecords: Int

    /// One guest acknowledgement received by the router.
    public struct Record: Equatable, Sendable {
        /// The sequence of the guest input batch.
        public let batchSequence: UInt64
        /// Events the guest rejected in that batch.
        public let rejectedEvents: UInt32
        /// Guest-measured time from receiving the batch to injecting its events.
        public let receiveToInjectMicros: UInt32
        /// Guest uptime in milliseconds of the batch's last event, or zero when the guest did not set it.
        public let lastEventTimeMillis: UInt64

        /// Creates an acknowledgement record.
        public init(
            batchSequence: UInt64,
            rejectedEvents: UInt32,
            receiveToInjectMicros: UInt32 = 0,
            lastEventTimeMillis: UInt64 = 0
        ) {
            self.batchSequence = batchSequence
            self.rejectedEvents = rejectedEvents
            self.receiveToInjectMicros = receiveToInjectMicros
            self.lastEventTimeMillis = lastEventTimeMillis
        }
    }

    /// Creates a history snapshot.
    public init(records: [Record], discardedRecords: Int) {
        self.records = records
        self.discardedRecords = discardedRecords
    }
}

/// The bounded history of input events the host successfully sent to the guest.
public struct InputSentEventHistory: Equatable, Sendable {
    /// The most recent sent events, in send order.
    public let records: [Record]
    /// Events evicted because the bounded history reached its limit.
    public let discardedRecords: Int

    /// One event in a successfully sent input batch.
    public struct Record: Equatable, Sendable {
        /// The sequence of the batch that carried the event.
        public let batchSequence: UInt64
        /// The zero-based event position inside the batch.
        public let eventIndex: Int
        /// The event's host monotonic timestamp in nanoseconds.
        public let hostTimeNanos: UInt64
        /// Stable event kind and phase, such as `touch.down` or `key.up`.
        public let kindAndPhase: String

        /// Creates a sent-event record.
        public init(batchSequence: UInt64, eventIndex: Int, hostTimeNanos: UInt64, kindAndPhase: String) {
            self.batchSequence = batchSequence
            self.eventIndex = eventIndex
            self.hostTimeNanos = hostTimeNanos
            self.kindAndPhase = kindAndPhase
        }
    }

    /// Creates a history snapshot.
    public init(records: [Record], discardedRecords: Int) {
        self.records = records
        self.discardedRecords = discardedRecords
    }
}

extension InputCounters: CustomStringConvertible {
    /// The counts on one line for the development command's output: the sends first, then the drop and merge counts of
    /// input.md §11 under their names.
    public var description: String {
        "sent=\(eventsSent) batches=\(batchesSent) input.dropped.rate=\(droppedRate) "
            + "input.dropped.notRunning=\(droppedNotRunning) input.dropped.notFocused=\(droppedNotFocused) "
            + "input.dropped.invalid=\(droppedInvalid) "
            + "input.dropped.channel=\(droppedChannel) input.coalesced=\(coalesced)"
    }
}

/// Why a session could not be registered as the owner of an Android display.
public enum InputRouterRegistrationFailure: Error, Equatable, Sendable {
    /// Another session already owns the display.
    case displayAlreadyOwned
    /// A registered session cannot move to a different display without ending its old lease first.
    case sessionAlreadyOwnsAnotherDisplay
}

/// The routing of input to the guest (input.md §7.1, runtime-api.md §7.3). The router keeps the sessions, checks
/// that a session may send, limits its rate, merges events when the guest is behind, and sends the rest as batches.
///
/// Routes are serialised: a batch is sent in full before the next one starts, so the events keep their order across
/// calls. The display of a session comes from its registration (the lease), and never from an event. Only the focused
/// session may route input; a focus transition cancels any open input on the session losing focus.
public actor InputRouter {
    /// The events per second that one session may send (runtime-api.md §7.3).
    public static let eventsPerSecond = 2_000
    /// The guest backlog above which consecutive moves, hover moves, and scrolls merge (input.md §7.1).
    public static let coalescingBacklogBytes = 64 * 1024
    /// The length of the rate window.
    private static let windowNanoseconds: UInt64 = 1_000_000_000
    /// The most recent guest acknowledgements retained for diagnostics.
    public static let acknowledgementHistoryLimit = 256
    /// The most recent host input events retained during an explicitly enabled trace.
    public static let sentEventHistoryLimit = 256

    /// Returns the time in nanoseconds of a monotonic clock. The rate window and the cancel timestamps use it.
    public typealias Clock = @Sendable () -> UInt64
    /// Moves the Guest Agent's Android task focus to a display.
    public typealias FocusDisplayOperation = @Sendable (Int32) async throws -> Void

    /// A registered session.
    private struct Entry {
        /// Tells a registration from the one that replaced it, so that a batch waiting for its turn can tell.
        let generation: UInt64
        let displayID: Int32
        var state: AppSessionState
        var window = RateWindow()
    }

    /// The events that a session sent in the last second, by the time they were admitted.
    private struct RateWindow {
        private var entries: [(at: UInt64, count: Int)] = []
        private var total = 0

        /// Admits the events of a batch at `now`, in order, and returns the ones that pass and how many were dropped.
        /// A droppable event passes while the window has room for it. An event that is never dropped passes at once, and
        /// it counts against the window as it passes, so the limit still holds for the events after it (input.md §7.1).
        mutating func admit(
            _ events: [InputEvent], at now: UInt64, limit: Int
        ) -> (passed: [InputEvent], dropped: Int) {
            while let first = entries.first, first.at + InputRouter.windowNanoseconds <= now {
                total -= first.count
                entries.removeFirst()
            }
            var passed: [InputEvent] = []
            passed.reserveCapacity(events.count)
            var dropped = 0
            for event in events {
                if InputRouter.isNeverDropped(event) || total + passed.count < limit {
                    passed.append(event)
                } else {
                    dropped += 1
                }
            }
            if !passed.isEmpty {
                entries.append((at: now, count: passed.count))
                total += passed.count
            }
            return (passed, dropped)
        }
    }

    private let channel: any InputChannel
    private let clock: Clock
    private let focusDisplay: FocusDisplayOperation
    private let logger: APKLogger
    private var sessions: [SessionID: Entry] = [:]
    /// Each live display has at most one session owner, from the DisplayPool lease.
    private var displayOwners: [Int32: SessionID] = [:]
    /// Android uses global task focus; input is admitted only for this session.
    private var focusedSession: SessionID?
    /// Older native focus callbacks may arrive after a newer callback from another window.
    private var focusGeneration: UInt64 = 0
    private var nextGeneration: UInt64 = 1
    private var nextBatchSequence: UInt64 = 1
    /// Whether a route or an end holds the send turn. The waiters take it in arrival order.
    private var turnTaken = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastWarning: UInt64?

    /// What the router dropped, merged, and sent so far.
    public private(set) var counters = InputCounters()
    private var acknowledgementRecords: [InputAcknowledgementHistory.Record] = []
    private var discardedAcknowledgementRecords = 0
    private var acknowledgementCaptureStartSequence: UInt64?
    private var sentEventRecords: [InputSentEventHistory.Record] = []
    private var discardedSentEventRecords = 0
    private var capturesAcknowledgementHistory = false
    private var capturesSentEventHistory = false
    private var capturesOneEventPerBatch = false
    private var capturesAcknowledgementEventTime = false

    /// A bounded record of ACKs captured from the current input channel.
    public var acknowledgementHistory: InputAcknowledgementHistory {
        InputAcknowledgementHistory(
            records: acknowledgementRecords,
            discardedRecords: discardedAcknowledgementRecords
        )
    }

    /// A bounded history snapshot of the events successfully sent during the current diagnostic capture.
    public var sentEventHistory: InputSentEventHistory {
        InputSentEventHistory(records: sentEventRecords, discardedRecords: discardedSentEventRecords)
    }

    /// Whether the input peer negotiated the capability needed to join ACKs to guest event timestamps.
    public var supportsAcknowledgementEventTimeTrace: Bool {
        get async {
            await channel.negotiatedCapabilities?.contains(GuestCapability.inputAckTrace.rawValue) == true
        }
    }

    /// Starts bounded ACK capture for an explicitly enabled diagnostic run.
    ///
    /// When `everyBatch` is true, the router places each accepted event in its own batch and requests an ACK for every
    /// batch. It requests guest event times only when the peer negotiated `input.ack_trace.v1`. The default preserves
    /// the normal batching and every-32nd-batch ACK cadence. Sent-event history is a separate, more expensive opt-in
    /// because it formats and retains every event while the capture is active.
    public func startAcknowledgementHistoryCapture(
        everyBatch: Bool = false,
        captureSentEventHistory: Bool = false
    ) async -> InputCounters {
        await takeTurn()
        defer { releaseTurn() }
        acknowledgementRecords.removeAll(keepingCapacity: true)
        discardedAcknowledgementRecords = 0
        acknowledgementCaptureStartSequence = nextBatchSequence
        sentEventRecords.removeAll(keepingCapacity: true)
        discardedSentEventRecords = 0
        capturesAcknowledgementHistory = true
        capturesSentEventHistory = captureSentEventHistory
        capturesOneEventPerBatch = everyBatch
        let capabilityWasNegotiated =
            await channel.negotiatedCapabilities?.contains(GuestCapability.inputAckTrace.rawValue) == true
        capturesAcknowledgementEventTime = everyBatch && capabilityWasNegotiated
        return counters
    }

    /// Stops bounded ACK capture and returns its final snapshot.
    public func stopAcknowledgementHistoryCapture() async -> InputAcknowledgementHistory {
        await takeTurn()
        defer { releaseTurn() }
        capturesAcknowledgementHistory = false
        capturesSentEventHistory = false
        capturesOneEventPerBatch = false
        capturesAcknowledgementEventTime = false
        acknowledgementCaptureStartSequence = nil
        return acknowledgementHistory
    }

    /// Creates a router over `channel`. The acks of the channel are read for the rejected counts (input.md §8).
    public init(
        channel: any InputChannel,
        clock: @escaping Clock = InputRouter.monotonicNanoseconds,
        focusDisplay: @escaping FocusDisplayOperation = { _ in },
        logSink: (any LogSink)? = nil
    ) {
        self.channel = channel
        self.clock = clock
        self.focusDisplay = focusDisplay
        logger = APKLogger(category: InputLogCategory.route, sink: logSink)
        // The reader ends when the channel's acks finish, which is when its connection closes.
        let acks = channel.acks
        Task { [weak self] in
            for await ack in acks {
                await self?.recordAck(ack)
            }
        }
    }

    /// The uptime of the host in nanoseconds, the default clock.
    public static func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Registers `session` as the sole owner of `displayID`, in `state`. Re-registering the same session on its
    /// existing display starts a fresh rate window. A session cannot claim a display held by another session or move
    /// to another display without ending the prior registration first.
    @discardableResult
    public func register(
        session: SessionID,
        displayID: Int32,
        state: AppSessionState
    ) -> InputRouterRegistrationFailure? {
        if let owner = displayOwners[displayID], owner != session {
            return .displayAlreadyOwned
        }
        if let current = sessions[session], current.displayID != displayID {
            return .sessionAlreadyOwnsAnotherDisplay
        }
        sessions[session] = Entry(generation: nextGeneration, displayID: displayID, state: state)
        displayOwners[displayID] = session
        nextGeneration += 1
        return nil
    }

    /// Cancels open input on every display registered when this operation takes the send turn.
    ///
    /// This is used after the input channel reconnects: Android may still have keys or gestures open from the previous
    /// channel, so each live display receives a `cancelAll` on the new one. The display IDs are sent in sorted order.
    public func cancelAllRegisteredDisplays() async {
        await takeTurn()
        defer { releaseTurn() }

        let displayIDs = displayOwners.keys.sorted()
        guard !displayIDs.isEmpty else {
            return
        }
        let now = clock()
        for displayID in displayIDs where displayOwners[displayID] != nil {
            await send([.cancelAll(InputTimestamp(hostNanos: now))], displayID: displayID, at: now)
        }
    }

    /// Changes the state of a registered session. A session that is not registered is left alone.
    public func setState(_ state: AppSessionState, for session: SessionID) {
        sessions[session]?.state = state
    }

    /// Changes which registered session owns Android's global focus. The session losing focus receives `.cancelAll`
    /// before the Guest Agent focuses the new display, so an in-progress gesture cannot remain open on the old app.
    ///
    /// The focus operation is injected because display focus travels over the Guest Agent control channel, separate
    /// from the input stream. If it fails, the router leaves input unfocused rather than sending keys to the wrong app.
    public func focusChanged(
        _ session: SessionID,
        focused: Bool,
        generation suppliedGeneration: UInt64? = nil
    ) async {
        let generation = suppliedGeneration ?? (focusGeneration &+ 1)
        // An equal generation is an explicit retry of the current window's focus. Task appearance can
        // arrive while the first Guest Agent request is still in flight, so take the turn and check
        // again after that request completes. Older window notifications are always stale.
        guard generation >= focusGeneration,
            generation != focusGeneration || focused
        else {
            return
        }
        focusGeneration = max(focusGeneration, generation)
        guard let requested = sessions[session],
            displayOwners[requested.displayID] == session
        else {
            return
        }

        if !focused, focusedSession != session {
            return
        }

        await takeTurn()
        defer { releaseTurn() }

        guard focusGeneration == generation else {
            return
        }
        guard let current = sessions[session],
            current.generation == requested.generation,
            displayOwners[current.displayID] == session
        else {
            return
        }

        if focused {
            // Another equal-generation retry may have waited behind the successful first attempt.
            if focusedSession == session {
                return
            }
            let previousFocus = focusedSession
            focusedSession = nil
            if let previousFocus, previousFocus != session,
                let previous = sessions[previousFocus],
                displayOwners[previous.displayID] == previousFocus
            {
                let now = clock()
                await send([.cancelAll(InputTimestamp(hostNanos: now))], displayID: previous.displayID, at: now)
            }

            // Reserve focus while the Guest Agent operation is in flight. Routes queue behind this turn and re-check
            // focus before sending, so the first event after a native focus notification is not dropped prematurely.
            focusedSession = session
            do {
                try await focusDisplay(current.displayID)
            } catch {
                guard focusGeneration == generation else {
                    return
                }
                if focusedSession == session {
                    focusedSession = nil
                }
                logger.warning("Android display focus could not be changed")
                return
            }

            guard focusGeneration == generation,
                let latest = sessions[session],
                latest.generation == current.generation,
                displayOwners[latest.displayID] == session
            else {
                return
            }
            focusedSession = session
        } else {
            // Re-check after taking the send turn because a newer focus transition may have run while waiting.
            guard focusedSession == session else {
                return
            }
            focusedSession = nil
            let now = clock()
            await send([.cancelAll(InputTimestamp(hostNanos: now))], displayID: current.displayID, at: now)
        }
    }

    /// Routes a batch of events from `session`, in order (runtime-api.md §7.3). Dropped events are counted, and nothing
    /// is returned to the caller.
    public nonisolated func route(_ events: [InputEvent], from session: SessionID) async {
        await Perf.interval("input.route") {
            await self.routeBatch(events, from: session)
        }
    }

    /// Routes one batch. `route` measures it with the `input.route` signpost interval.
    private func routeBatch(_ events: [InputEvent], from session: SessionID) async {
        guard !events.isEmpty else {
            return
        }
        guard let arrival = sessions[session] else {
            counters.droppedInvalid += events.count
            warnOncePerSecond("An input batch named a session that is not registered, so it is dropped")
            return
        }
        guard displayOwners[arrival.displayID] == session else {
            counters.droppedInvalid += events.count
            warnOncePerSecond("An input batch came from a session that does not own its display, so it is dropped")
            return
        }
        guard arrival.state.acceptsInput else {
            counters.droppedNotRunning += events.count
            return
        }
        guard focusedSession == session else {
            counters.droppedNotFocused += events.count
            return
        }
        await takeTurn()
        defer { releaseTurn() }
        // The session may have ended while this batch waited for its turn.
        guard let current = sessions[session], current.generation == arrival.generation,
            current.state.acceptsInput
        else {
            counters.droppedNotRunning += events.count
            return
        }
        guard displayOwners[current.displayID] == session else {
            counters.droppedInvalid += events.count
            return
        }
        guard focusedSession == session else {
            counters.droppedNotFocused += events.count
            return
        }
        let now = clock()
        guard let admission = sessions[session]?.window.admit(events, at: now, limit: Self.eventsPerSecond) else {
            return
        }
        if admission.dropped > 0 {
            counters.droppedRate += admission.dropped
            warnOncePerSecond("Input is over the rate limit, so the excess is dropped")
        }
        var accepted = admission.passed
        guard !accepted.isEmpty else {
            return
        }
        let backlog = await channel.pendingBytes
        if backlog > Self.coalescingBacklogBytes {
            accepted = coalesce(accepted)
        }
        await send(accepted, displayID: current.displayID, at: now)
    }

    /// Ends a session. Its open gestures, buttons, and keys are cancelled on the guest, after the batches that were
    /// routed before when it still owns focus. Set `cancelGuestState` to false only when the Guest Agent input stream
    /// has disconnected; the guest cancels its input state when that stream closes. A previous focus-loss event has
    /// already cancelled the session, and an unfocused session could not have sent input.
    public func sessionEnded(_ session: SessionID, cancelGuestState: Bool = true) async {
        guard let ended = sessions.removeValue(forKey: session) else {
            return
        }
        if displayOwners[ended.displayID] == session {
            displayOwners.removeValue(forKey: ended.displayID)
        }
        let ownsFocus = focusedSession == session
        if ownsFocus {
            focusedSession = nil
        }
        let needsCancellation = cancelGuestState && ownsFocus
        await takeTurn()
        defer { releaseTurn() }
        if needsCancellation {
            let now = clock()
            await send([.cancelAll(InputTimestamp(hostNanos: now))], displayID: ended.displayID, at: now)
        }
    }

    // MARK: - Sending

    /// Sends `events` as batches. The caller holds the turn, so the batches keep their order across calls.
    private func send(_ events: [InputEvent], displayID: Int32, at now: UInt64) async {
        let batches = GuestInputEncoding.batches(
            events,
            displayID: displayID,
            firstSequence: nextBatchSequence,
            hostSendNanos: now,
            oneEventPerBatch: capturesOneEventPerBatch,
            acknowledgeEveryBatch: capturesOneEventPerBatch,
            traceEventTime: capturesAcknowledgementEventTime
        )
        nextBatchSequence += UInt64(batches.count)
        var eventOffset = 0
        for (index, batch) in batches.enumerated() {
            do {
                try await channel.send(batch)
            } catch {
                let unsent = batches[index...].reduce(0) { $0 + $1.events.count }
                counters.droppedChannel += unsent
                let reason = (error as? GuestProtocolFailure)?.catalogName ?? "unknown"
                logger.warning("The input stream could not carry a batch: \(reason, .public)")
                return
            }
            counters.batchesSent += 1
            counters.eventsSent += batch.events.count
            if capturesSentEventHistory {
                let eventEnd = eventOffset + batch.events.count
                recordSentEvents(events[eventOffset..<eventEnd], batchSequence: batch.batchSeq)
            }
            eventOffset += batch.events.count
        }
    }

    /// Appends events from a successfully sent batch to the bounded trace.
    private func recordSentEvents(_ events: ArraySlice<InputEvent>, batchSequence: UInt64) {
        for (eventIndex, event) in events.enumerated() {
            if sentEventRecords.count == Self.sentEventHistoryLimit {
                sentEventRecords.removeFirst()
                discardedSentEventRecords += 1
            }
            let (hostTimeNanos, kindAndPhase) = Self.traceDescription(of: event)
            sentEventRecords.append(
                InputSentEventHistory.Record(
                    batchSequence: batchSequence,
                    eventIndex: eventIndex,
                    hostTimeNanos: hostTimeNanos,
                    kindAndPhase: kindAndPhase
                )
            )
        }
    }

    /// Returns the timestamp and stable kind/phase tag used by the input trace.
    private static func traceDescription(of event: InputEvent) -> (UInt64, String) {
        switch event {
        case .touch(let touch):
            let phase: String
            switch touch.phase {
            case .down: phase = "down"
            case .move: phase = "move"
            case .up: phase = "up"
            case .cancel: phase = "cancel"
            }
            return (touch.time.hostNanos, "touch.\(phase)")
        case .mouse(let mouse):
            let action: String
            switch mouse.action {
            case .hoverEnter: action = "hoverEnter"
            case .hoverMove: action = "hoverMove"
            case .hoverExit: action = "hoverExit"
            case .press: action = "press"
            case .release: action = "release"
            }
            return (mouse.time.hostNanos, "mouse.\(action)")
        case .scroll(let scroll):
            return (scroll.time.hostNanos, "scroll")
        case .key(let key):
            return (key.time.hostNanos, key.action == .down ? "key.down" : "key.up")
        case .longPress(_, let time):
            return (time.hostNanos, "longPress")
        case .cancelAll(let time):
            return (time.hostNanos, "cancelAll")
        }
    }

    /// Whether the rate limit never drops `event`. The touch down, up, and cancel, the button presses and releases, the
    /// hover enter and exit, the key, the long press, and `cancelAll` are kept, so that no gesture or hover stays open
    /// on the guest. Only the touch moves, the hover moves, and the scrolls are droppable (input.md §7.1). A hover enter
    /// and exit are kept too, because a dropped exit would leave the guest hovering.
    static func isNeverDropped(_ event: InputEvent) -> Bool {
        switch event {
        case .touch(let touch):
            touch.phase != .move
        case .mouse(let mouse):
            mouse.action != .hoverMove
        case .scroll:
            false
        case .key, .longPress, .cancelAll:
            true
        }
    }

    /// Merges consecutive moves, hover moves, and scrolls. Every other event stays as it is, and in order (input.md
    /// §7.1). A merged scroll adds up the axes.
    private func coalesce(_ events: [InputEvent]) -> [InputEvent] {
        var output: [InputEvent] = []
        output.reserveCapacity(events.count)
        for event in events {
            if let last = output.last, let merged = Self.merge(last, event) {
                output[output.count - 1] = merged
                counters.coalesced += 1
            } else {
                output.append(event)
            }
        }
        return output
    }

    /// The event that replaces two consecutive events, or nil when they stay apart.
    static func merge(_ earlier: InputEvent, _ later: InputEvent) -> InputEvent? {
        switch (earlier, later) {
        case (.touch(let first), .touch(let second))
        where first.phase == .move && second.phase == .move && first.pointerID == second.pointerID:
            return .touch(
                TouchEvent(phase: .move, pointerID: second.pointerID, position: second.position, time: second.time))
        case (.mouse(let first), .mouse(let second))
        where first.action == .hoverMove && second.action == .hoverMove:
            return .mouse(
                MouseEvent(action: .hoverMove, position: second.position, buttons: second.buttons, time: second.time))
        case (.scroll(let first), .scroll(let second)):
            return .scroll(
                ScrollEvent(
                    position: second.position,
                    vertical: first.vertical + second.vertical,
                    horizontal: first.horizontal + second.horizontal,
                    time: second.time))
        default:
            return nil
        }
    }

    // MARK: - Turns and acks

    /// Takes the send turn, or waits for it. The turn passes to the waiters in arrival order.
    private func takeTurn() async {
        guard turnTaken else {
            turnTaken = true
            return
        }
        await withCheckedContinuation { turnWaiters.append($0) }
    }

    /// Passes the turn to the first waiter, or frees it when nobody waits.
    private func releaseTurn() {
        if turnWaiters.isEmpty {
            turnTaken = false
        } else {
            turnWaiters.removeFirst().resume()
        }
    }

    /// Adds the events that the guest rejected to the invalid count.
    private func recordAck(_ ack: GPInputAck) {
        if capturesAcknowledgementHistory,
            let acknowledgementCaptureStartSequence,
            ack.batchSeq >= acknowledgementCaptureStartSequence
        {
            acknowledgementRecords.append(
                InputAcknowledgementHistory.Record(
                    batchSequence: ack.batchSeq,
                    rejectedEvents: ack.rejectedEvents,
                    receiveToInjectMicros: ack.receiveToInjectMicros,
                    lastEventTimeMillis: ack.lastEventTimeMillis
                )
            )
            if acknowledgementRecords.count > Self.acknowledgementHistoryLimit {
                acknowledgementRecords.removeFirst()
                discardedAcknowledgementRecords += 1
            }
        }
        guard ack.rejectedEvents > 0 else {
            return
        }
        counters.droppedInvalid += Int(ack.rejectedEvents)
    }

    /// Writes a warning, at most one per second, so that a flood of drops does not flood the log.
    private func warnOncePerSecond(_ message: String) {
        let now = clock()
        if let last = lastWarning, now < last + Self.windowNanoseconds {
            return
        }
        lastWarning = now
        logger.warning("\(message, .public)")
    }
}
