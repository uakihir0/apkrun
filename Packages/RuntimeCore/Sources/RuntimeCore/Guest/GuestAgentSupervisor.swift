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
/// budget, and the supervisor only reconnects after a restart that it allows.
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
        /// The agent died more often than its budget allows. The supervisor does not reconnect.
        case unavailable
    }

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

    /// Connects and resynchronises. It retries with the backoff until ``connectTimeout`` has passed, then throws
    /// `connectTimedOut`. After the first connection, the keepalive loop runs until ``stop()``.
    public func start(connectTimeout: Duration) async throws(GuestAgentFailure) {
        guard maintenance == nil else {
            return
        }
        state = .connecting
        let deadline = ContinuousClock.now + connectTimeout
        var delay = backoffMinimum
        while true {
            do {
                try await establish()
                break
            } catch {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero {
                    state = .stopped
                    throw .connectTimedOut
                }
                try? await Task.sleep(for: min(delay, remaining))
                delay = min(delay * 2, backoffMaximum)
            }
        }
        state = .ready
        maintenance = Task { await self.maintain() }
    }

    /// Stops the keepalive loop and closes the connection. The state becomes `stopped`.
    public func stop() async {
        maintenance?.cancel()
        maintenance = nil
        recovery?.cancel()
        recovery = nil
        consumer?.cancel()
        consumer = nil
        let closing = connection
        connection = nil
        session = nil
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

    /// Opens a connection, reads its handshake, and resynchronises with `GetSnapshot` before anything else.
    private func establish() async throws(GuestProtocolFailure) {
        let next = GuestConnection(
            endpoint: .guestControl,
            transport: transport,
            hostVersion: hostVersion,
            logSink: logSink
        )
        awaitingSnapshot = true
        buffered = []
        let info = try await next.open()
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
        snapshot.replace(with: fresh)
        awaitingSnapshot = false
        for event in buffered {
            snapshot.apply(event)
            updateContinuation.yield(event)
        }
        buffered = []
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
        recovery?.cancel()
        recovery = Task { await self.lost(.disconnected) }
    }

    // MARK: - Keepalive and recovery

    private func maintain() async {
        var misses = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: keepaliveInterval)
            guard !Task.isCancelled, let current = connection else {
                return
            }
            pingNonce += 1
            do {
                _ = try await current.send(GuestPing(nonce: pingNonce), timeout: pingTimeout)
                misses = 0
                if state == .unresponsive {
                    state = .ready
                }
            } catch {
                misses += 1
                if await !current.isUsable {
                    await lost(.disconnected)
                    misses = 0
                } else if misses >= missLimit {
                    state = .unresponsive
                    await lost(.unresponsive)
                    misses = 0
                }
            }
            if state == .unavailable {
                return
            }
        }
    }

    /// Restarts the agent when the owner allows it, then reconnects with the backoff. A refused restart ends the
    /// supervisor in `unavailable`.
    private func lost(_ reason: GuestAgentLoss) async {
        logger.warning("The Guest Agent connection was lost: \(String(describing: reason), .public)")
        let closing = connection
        connection = nil
        session = nil
        consumer?.cancel()
        consumer = nil
        await closing?.close()
        state = .connecting
        guard await restartAgent(reason) else {
            logger.error(
                "The Guest Agent restart budget is spent, so the agent stays down",
                errorCode: "runtime.requiredAgentUnavailable")
            state = .unavailable
            return
        }
        var delay = backoffMinimum
        while !Task.isCancelled {
            do {
                try await establish()
                state = .ready
                return
            } catch {
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, backoffMaximum)
            }
        }
    }
}
