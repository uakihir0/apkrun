import DiagnosticsCore
import Foundation
import GuestProtocol

/// The restart budget of the Guest Agent (guest-components.md §3.3): at most ``limit`` restarts within ``window``.
/// The death that exceeds it is not restarted, and the host reports `requiredAgentUnavailable`.
public struct GuestAgentRestartBudget: Sendable {
    /// The restarts allowed in one window.
    public static let limit = 3
    /// The window of the budget.
    public static let window: Duration = .seconds(60)

    private var deaths: [ContinuousClock.Instant] = []

    /// Creates an empty budget.
    public init() {}

    /// Records a death at `now`, and returns whether the agent may be restarted. A death past the limit returns false.
    public mutating func recordDeath(at now: ContinuousClock.Instant) -> Bool {
        deaths.removeAll { now - $0 > Self.window }
        deaths.append(now)
        return deaths.count <= Self.limit
    }
}

/// The state of the Guest Agent that the host keeps from its events (guest-protocol.md §6, §7.2).
public struct GuestSnapshotState: Equatable, Sendable {
    /// The displays of the guest, by display ID.
    public private(set) var displays: [Int32: GPDisplayInfo] = [:]
    /// The tasks of the guest, by task ID.
    public private(set) var tasks: [Int32: GPTaskInfo] = [:]
    /// The display that has the focus.
    public private(set) var focusedDisplayID: Int32 = 0

    /// Creates an empty state.
    public init() {}

    /// Replaces the state with a snapshot. Events that were buffered for the snapshot are applied after this.
    public mutating func replace(with snapshot: GPSnapshot) {
        displays = Dictionary(snapshot.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { _, last in last })
        tasks = Dictionary(snapshot.tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { _, last in last })
        focusedDisplayID = snapshot.focusedDisplayID
    }

    /// Applies one event. Applying an event twice gives the same state, so the events that a snapshot already
    /// contains can be applied again without harm (guest-protocol.md §6).
    public mutating func apply(_ event: GPEvent) {
        guard let kind = event.kind else {
            return
        }
        switch kind {
        case .displayAdded(let display), .displayChanged(let display):
            displays[display.displayID] = display
        case .displayRemoved(let removed):
            displays[removed.displayID] = nil
        case .taskAppeared(let task), .taskChanged(let task):
            tasks[task.taskID] = task
        case .taskVanished(let vanished):
            tasks[vanished.taskID] = nil
        case .focusedDisplayChanged(let focused):
            focusedDisplayID = focused.displayID
        default:
            break
        }
    }
}

/// Why the Guest Agent connection was lost (guest-components.md §3.3).
public enum GuestAgentLoss: Equatable, Sendable {
    /// The connection closed, or a request failed for a reason other than a missed answer.
    case disconnected
    /// The agent missed its answers to three pings, so it is unresponsive.
    case unresponsive
}

/// Keeps one control connection to the Guest Agent (guest-protocol.md §6, guest-components.md §3.3): keepalive
/// pings, reconnection with a backoff from 100 ms to 2 s, and a resync with `GetSnapshot` after every handshake.
///
/// When the agent is lost, ``restartAgent`` decides whether it may be restarted. That closure owns the restart
/// budget, and the supervisor only reconnects after a restart that it allows. Five protocol violations within ten
/// minutes stop the reconnection (guest-protocol.md §12.2).
public actor GuestAgentSupervisor {
    /// The state of the connection.
    public enum State: Equatable, Sendable {
        /// Not started, or stopped.
        case stopped
        /// Connecting, or reconnecting after a loss.
        case connecting
        /// Connected and resynchronised.
        case ready
        /// Three pings went unanswered.
        case unresponsive
        /// The agent died more often than its budget allows, or it kept violating the protocol. The supervisor does not
        /// reconnect.
        case unavailable
    }

    /// The protocol violations within ``violationWindow`` that stop the reconnection (guest-protocol.md §12.2).
    public static let violationLimit = 5
    /// The window in which the violations are counted.
    public static let violationWindow: Duration = .seconds(600)

    /// The current state.
    public private(set) var state: State = .stopped
    /// The session of the current connection, or nil while there is none.
    public private(set) var session: GuestSessionInfo?
    /// The state that the events and the snapshot have built.
    public private(set) var snapshot = GuestSnapshotState()
    /// The applied events, in order, for the consumers that act on them (for example a launch waiting for its task).
    public nonisolated let updates: AsyncStream<GPEvent>

    private let transport: any GuestTransport
    private let restartAgent: @Sendable (GuestAgentLoss) async -> Bool
    private let keepaliveInterval: Duration
    private let pingTimeout: Duration
    private let missLimit: Int
    private let backoffMinimum: Duration
    private let backoffMaximum: Duration
    private let hostVersion: String
    private let logger: APKLogger
    private let logSink: (any LogSink)?
    private let updateContinuation: AsyncStream<GPEvent>.Continuation
    private var connection: GuestConnection?
    private var consumer: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    /// The recovery after a lost connection. It runs apart from the consumer, which it cancels when it replaces it.
    private var recovery: Task<Void, Never>?
    private var awaitingSnapshot = false
    private var buffered: [GPEvent] = []
    private var pingNonce: UInt64 = 0
    /// Counts the stops, so that a start or a recovery in flight can tell that it was stopped.
    private var generation: UInt64 = 0
    /// When the recent protocol violations happened.
    private var violations: [ContinuousClock.Instant] = []

    /// Creates a supervisor. The timings are the design values unless a test sets shorter ones.
    public init(
        transport: any GuestTransport,
        hostVersion: String = "dev",
        keepaliveInterval: Duration = .seconds(5),
        pingTimeout: Duration = .seconds(5),
        missLimit: Int = 3,
        backoffMinimum: Duration = .milliseconds(100),
        backoffMaximum: Duration = .seconds(2),
        logSink: (any LogSink)? = nil,
        restartAgent: @escaping @Sendable (GuestAgentLoss) async -> Bool
    ) {
        self.logSink = logSink
        logger = APKLogger(category: RuntimeLogCategory.agents, sink: logSink)
        self.transport = transport
        self.hostVersion = hostVersion
        self.keepaliveInterval = keepaliveInterval
        self.pingTimeout = pingTimeout
        self.missLimit = missLimit
        self.backoffMinimum = backoffMinimum
        self.backoffMaximum = backoffMaximum
        self.restartAgent = restartAgent
        let stream = AsyncStream.makeStream(of: GPEvent.self, bufferingPolicy: .bufferingNewest(1024))
        updates = stream.stream
        updateContinuation = stream.continuation
    }

    /// Connects and resynchronises. A refused version or a refused Hello ends the attempts at once. Other failures
    /// are retried with the backoff until ``connectTimeout`` has passed, and then `connectTimedOut` is thrown. A
    /// ``stop()`` during the start throws `stopped`. After the first connection, the keepalive loop runs until
    /// ``stop()``.
    public func start(connectTimeout: Duration) async throws(GuestAgentFailure) {
        guard maintenance == nil else {
            return
        }
        state = .connecting
        let started = generation
        let deadline = ContinuousClock.now + connectTimeout
        var delay = backoffMinimum
        while true {
            let remaining = deadline - ContinuousClock.now
            do throws(GuestProtocolFailure) {
                guard remaining > .zero else {
                    throw GuestProtocolFailure.handshakeTimedOut
                }
                try await establish(limit: min(GuestConnection.defaultHandshakeTimeout, remaining))
                break
            } catch {
                guard generation == started else {
                    throw .stopped
                }
                if !error.isRetriable {
                    state = .stopped
                    throw Self.startFailure(error)
                }
                if recordViolation(error) {
                    state = .unavailable
                    logger.error(
                        "The Guest Agent broke the protocol too often, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    throw .requiredAgentUnavailable
                }
                let left = deadline - ContinuousClock.now
                if left <= .zero {
                    state = .stopped
                    throw Self.startFailure(error)
                }
                try? await Task.sleep(for: min(delay, left))
                guard generation == started else {
                    throw .stopped
                }
                delay = min(delay * 2, backoffMaximum)
            }
        }
        state = .ready
        maintenance = Task { await self.maintain() }
    }

    /// Stops the keepalive loop and closes the connection. The state becomes `stopped`, and a start in flight throws
    /// `stopped`.
    public func stop() async {
        generation += 1
        maintenance?.cancel()
        maintenance = nil
        recovery?.cancel()
        recovery = nil
        consumer?.cancel()
        consumer = nil
        let closing = connection
        connection = nil
        session = nil
        awaitingSnapshot = false
        buffered = []
        await closing?.close()
        state = .stopped
    }

    /// Sends one operation through the current connection. Without a connection the call fails with
    /// `agentUnavailable`.
    public func send<Operation: GuestOperation>(
        _ operation: Operation,
        timeout: Duration? = nil
    ) async throws(GuestProtocolFailure) -> Operation.Result {
        guard let connection, await connection.isUsable else {
            throw .agentUnavailable(kind: .guestAgent)
        }
        return try await connection.send(operation, timeout: timeout)
    }

    // MARK: - Connection

    /// Opens a connection, reads its handshake, and resynchronises with `GetSnapshot` before anything else. The
    /// connection is kept only when all of that succeeds, and it is closed otherwise.
    private func establish(limit: Duration) async throws(GuestProtocolFailure) {
        let started = generation
        let next = GuestConnection(
            endpoint: .guestControl,
            transport: transport,
            hostVersion: hostVersion,
            handshakeTimeout: limit,
            logSink: logSink
        )
        awaitingSnapshot = true
        buffered = []
        do throws(GuestProtocolFailure) {
            let info = try await next.open()
            guard generation == started else {
                throw GuestProtocolFailure.disconnected
            }
            connection = next
            session = info
            consumer?.cancel()
            consumer = Task {
                for await event in next.events {
                    self.receive(event)
                }
                await self.connectionEnded(next)
            }
            let fresh = try await next.send(GuestGetSnapshot())
            guard generation == started, connection === next else {
                throw GuestProtocolFailure.disconnected
            }
            snapshot.replace(with: fresh)
            awaitingSnapshot = false
            for event in buffered {
                snapshot.apply(event)
                updateContinuation.yield(event)
            }
            buffered = []
        } catch {
            awaitingSnapshot = false
            buffered = []
            if connection === next {
                connection = nil
                session = nil
                consumer?.cancel()
                consumer = nil
            }
            await next.close()
            throw error
        }
    }

    /// Buffers the events that arrive before the snapshot response, and applies the others at once.
    private func receive(_ event: GPEvent) {
        if awaitingSnapshot {
            buffered.append(event)
            return
        }
        snapshot.apply(event)
        updateContinuation.yield(event)
    }

    /// The connection's event stream ended, so the connection is gone.
    private func connectionEnded(_ ended: GuestConnection) async {
        guard connection === ended, maintenance != nil else {
            return
        }
        let cause = await ended.closeReason
        recovery?.cancel()
        recovery = Task { await self.lost(.disconnected, cause: cause, from: ended) }
    }

    // MARK: - Keepalive and recovery

    /// Pings the agent every ``keepaliveInterval``, counted from the start of each ping, so that three misses take
    /// about 15 seconds. A failed connection is reported once, and the loop continues with the next connection.
    private func maintain() async {
        var misses = 0
        while !Task.isCancelled {
            let cycleStart = ContinuousClock.now
            if let current = connection {
                pingNonce += 1
                do {
                    // The ping has no grace period, so a missed answer counts at the ping's own timeout.
                    _ = try await current.send(GuestPing(nonce: pingNonce), timeout: pingTimeout, grace: .zero)
                    misses = 0
                    if state == .unresponsive {
                        state = .ready
                    }
                } catch {
                    misses += 1
                    if await !current.isUsable {
                        misses = 0
                        await lost(.disconnected, cause: await current.closeReason, from: current)
                    } else if misses >= missLimit {
                        misses = 0
                        state = .unresponsive
                        await lost(.unresponsive, cause: nil, from: current)
                    }
                }
            }
            guard !Task.isCancelled, state != .unavailable else {
                return
            }
            let elapsed = ContinuousClock.now - cycleStart
            if elapsed < keepaliveInterval {
                try? await Task.sleep(for: keepaliveInterval - elapsed)
            }
        }
    }

    /// Restarts the agent when the owner allows it, then reconnects with the backoff. A loss is handled once: a
    /// connection that was already replaced or closed is ignored, so a second report of the same death takes no second
    /// budget entry. A failed attempt asks the owner again, so that an agent which died before it connected is
    /// restarted within the budget (guest-components.md §3.3). A refused restart, a non-retriable failure, or too many
    /// protocol violations end the supervisor in `unavailable`.
    private func lost(_ reason: GuestAgentLoss, cause: GuestProtocolFailure?, from dead: GuestConnection) async {
        guard connection === dead, maintenance != nil else {
            return
        }
        let started = generation
        logger.warning("The Guest Agent connection was lost: \(String(describing: reason), .public)")
        connection = nil
        session = nil
        consumer?.cancel()
        consumer = nil
        await dead.close()
        state = .connecting
        if let cause, recordViolation(cause) {
            state = .unavailable
            logger.error(
                "The Guest Agent broke the protocol too often, so the agent stays down",
                errorCode: "runtime.requiredAgentUnavailable")
            return
        }
        guard await restartAgent(reason) else {
            logger.error(
                "The Guest Agent restart budget is spent, so the agent stays down",
                errorCode: "runtime.requiredAgentUnavailable")
            state = .unavailable
            return
        }
        var delay = backoffMinimum
        while generation == started, !Task.isCancelled {
            do throws(GuestProtocolFailure) {
                try await establish(limit: GuestConnection.defaultHandshakeTimeout)
                state = .ready
                return
            } catch {
                guard generation == started else {
                    return
                }
                if !error.isRetriable {
                    state = .unavailable
                    logger.error(
                        "The Guest Agent refused the reconnection, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    return
                }
                if recordViolation(error) {
                    state = .unavailable
                    logger.error(
                        "The Guest Agent broke the protocol too often, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    return
                }
                guard await restartAgent(.disconnected) else {
                    logger.error(
                        "The Guest Agent restart budget is spent, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    state = .unavailable
                    return
                }
                guard generation == started else {
                    return
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, backoffMaximum)
            }
        }
    }

    /// Counts a protocol violation (guest-protocol.md §12.2), and reports whether the count within
    /// ``violationWindow`` has reached ``violationLimit``. Other failures are not violations.
    private func recordViolation(_ failure: GuestProtocolFailure) -> Bool {
        guard failure == .malformedFrame || failure == .frameTooLarge else {
            return false
        }
        let now = ContinuousClock.now
        violations.removeAll { now - $0 > Self.violationWindow }
        violations.append(now)
        return violations.count >= Self.violationLimit
    }

    /// The start failure of a handshake that did not complete. A refused version or Hello is named, and a connection
    /// that never came up is `connectTimedOut`.
    private static func startFailure(_ failure: GuestProtocolFailure) -> GuestAgentFailure {
        switch failure {
        case .incompatibleVersion:
            .handshakeFailed(reason: "incompatibleVersion")
        case .handshakeFailed(let reason):
            .handshakeFailed(reason: String(describing: reason))
        default:
            .connectTimedOut
        }
    }
}

extension GuestProtocolFailure {
    /// Whether another attempt can succeed. A refused version, or a refused Hello other than a duplicate session, is
    /// refused again on every attempt.
    fileprivate var isRetriable: Bool {
        switch self {
        case .incompatibleVersion:
            false
        case .handshakeFailed(let reason):
            reason == .duplicateSession
        default:
            true
        }
    }
}
