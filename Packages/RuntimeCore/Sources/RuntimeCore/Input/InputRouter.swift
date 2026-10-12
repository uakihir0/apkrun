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
}

/// What the router dropped, merged, and sent (input.md §11). The diagnostics snapshot reads a copy of it.
public struct InputCounters: Equatable, Sendable {
    /// Events dropped over the rate limit of their session (`input.dropped.rate`).
    public var droppedRate = 0
    /// Events dropped because their session was not running or backgrounded (`input.dropped.notRunning`).
    public var droppedNotRunning = 0
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
        droppedInvalid += other.droppedInvalid
        droppedChannel += other.droppedChannel
        coalesced += other.coalesced
        eventsSent += other.eventsSent
        batchesSent += other.batchesSent
    }
}

extension InputCounters: CustomStringConvertible {
    /// The counts on one line, under the names of input.md §11, for the development command's output.
    public var description: String {
        "sent=\(eventsSent) batches=\(batchesSent) input.dropped.rate=\(droppedRate) "
            + "input.dropped.notRunning=\(droppedNotRunning) input.dropped.invalid=\(droppedInvalid) "
            + "input.dropped.channel=\(droppedChannel) input.coalesced=\(coalesced)"
    }
}

/// The routing of input to the guest (input.md §7.1, runtime-api.md §7.3). The router keeps the sessions, checks
/// that a session may send, limits its rate, merges events when the guest is behind, and sends the rest as batches.
///
/// Routes are serialised: a batch is sent in full before the next one starts, so the events keep their order across
/// calls. The display of a session comes from its registration (the lease), and never from an event.
public actor InputRouter {
    /// The events per second that one session may send (runtime-api.md §7.3).
    public static let eventsPerSecond = 2_000
    /// The guest backlog above which consecutive moves, hover moves, and scrolls merge (input.md §7.1).
    public static let coalescingBacklogBytes = 64 * 1024
    /// The length of the rate window.
    private static let windowNanoseconds: UInt64 = 1_000_000_000

    /// Returns the time in nanoseconds of a monotonic clock. The rate window and the cancel timestamps use it.
    public typealias Clock = @Sendable () -> UInt64

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
    private let logger: APKLogger
    private var sessions: [SessionID: Entry] = [:]
    private var nextGeneration: UInt64 = 1
    private var nextBatchSequence: UInt64 = 1
    /// Whether a route or an end holds the send turn. The waiters take it in arrival order.
    private var turnTaken = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastWarning: UInt64?

    /// What the router dropped, merged, and sent so far.
    public private(set) var counters = InputCounters()

    /// Creates a router over `channel`. The acks of the channel are read for the rejected counts (input.md §8).
    public init(
        channel: any InputChannel,
        clock: @escaping Clock = InputRouter.monotonicNanoseconds,
        logSink: (any LogSink)? = nil
    ) {
        self.channel = channel
        self.clock = clock
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

    /// Registers a session on the Android display `displayID`, in `state`. A session that is registered again starts
    /// over with an empty rate window.
    public func register(session: SessionID, displayID: Int32, state: AppSessionState) {
        sessions[session] = Entry(generation: nextGeneration, displayID: displayID, state: state)
        nextGeneration += 1
    }

    /// Changes the state of a registered session. A session that is not registered is left alone.
    public func setState(_ state: AppSessionState, for session: SessionID) {
        sessions[session]?.state = state
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
        guard arrival.state.acceptsInput else {
            counters.droppedNotRunning += events.count
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
    /// routed before. A session that is not registered is left alone.
    public func sessionEnded(_ session: SessionID) async {
        guard let ended = sessions.removeValue(forKey: session) else {
            return
        }
        await takeTurn()
        defer { releaseTurn() }
        let now = clock()
        await send([.cancelAll(InputTimestamp(hostNanos: now))], displayID: ended.displayID, at: now)
    }

    // MARK: - Sending

    /// Sends `events` as batches. The caller holds the turn, so the batches keep their order across calls.
    private func send(_ events: [InputEvent], displayID: Int32, at now: UInt64) async {
        let batches = GuestInputEncoding.batches(
            events,
            displayID: displayID,
            firstSequence: nextBatchSequence,
            hostSendNanos: now
        )
        nextBatchSequence += UInt64(batches.count)
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
