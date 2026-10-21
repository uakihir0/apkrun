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
    /// Android uptime from the latest complete snapshot, when available.
    public private(set) var androidUptimeMillis: UInt64?
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
        androidUptimeMillis =
            snapshot.hasSystem && snapshot.system.androidUptimeMs > 0
            ? snapshot.system.androidUptimeMs
            : nil
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

/// A reboot of Android observed while its VirtualMachine remained alive.
public struct GuestAndroidRestart: Equatable, Sendable {
    /// Android uptime from the snapshot before the reboot.
    public let previousUptimeMillis: UInt64
    /// Android uptime from the snapshot after the reboot.
    public let currentUptimeMillis: UInt64

    /// Creates a restart event from two consecutive snapshots.
    public init(previousUptimeMillis: UInt64, currentUptimeMillis: UInt64) {
        self.previousUptimeMillis = previousUptimeMillis
        self.currentUptimeMillis = currentUptimeMillis
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
    private struct SendWaiter {
        let continuation: CheckedContinuation<Void, Never>
        let timeoutTask: Task<Void, Never>
    }

    /// The state of the connection.
    public enum State: Equatable, Sendable {
        /// Not started, or stopped.
        case stopped
        /// Establishing the first connection.
        case connecting
        /// Connected and resynchronised.
        case ready
        /// Reconnecting after a lost connection.
        case reconnecting
        /// Three pings went unanswered.
        case unresponsive
        /// The guest speaks an incompatible protocol version.
        case incompatible
        /// The agent died more often than its budget allows, or it kept violating the protocol. The supervisor does not
        /// reconnect.
        case unavailable
    }

    /// A consistent connection-state/version pair for diagnostics and RuntimeAPI status.
    public struct StatusSnapshot: Equatable, Sendable {
        /// The current connection state.
        public let state: State
        /// The last accepted or refused protocol version.
        public let protocolVersion: ProtocolVersion?

        /// Creates a connection status snapshot.
        public init(state: State, protocolVersion: ProtocolVersion?) {
            self.state = state
            self.protocolVersion = protocolVersion
        }
    }

    /// The protocol violations within ``violationWindow`` that stop the reconnection (guest-protocol.md §12.2).
    public static let violationLimit = 5
    /// The window in which the violations are counted.
    public static let violationWindow: Duration = .seconds(600)

    /// The current state.
    public private(set) var state: State = .stopped
    /// The session of the current connection, or nil while there is none.
    public private(set) var session: GuestSessionInfo?
    /// The most recently accepted or refused protocol version, while one is known.
    public private(set) var protocolVersion: ProtocolVersion?
    /// The state that the events and the snapshot have built.
    public private(set) var snapshot = GuestSnapshotState()
    /// The applied events, in order, for the consumers that act on them (for example a launch waiting for its task).
    public nonisolated let updates: AsyncStream<GPEvent>
    /// Guest Android restarts detected from a decrease in its monotonic uptime.
    public nonisolated let androidRestartEvents: AsyncStream<GuestAndroidRestart>

    private let transport: any GuestTransport
    private let restartAgent: @Sendable (GuestAgentLoss) async -> Bool
    private let keepaliveInterval: Duration
    private let pingTimeout: Duration
    private let missLimit: Int
    private let backoffMinimum: Duration
    private let backoffMaximum: Duration
    private let requestReconnectTimeout: Duration
    private let hostVersion: String
    private let logger: APKLogger
    private let logSink: (any LogSink)?
    private let updateContinuation: AsyncStream<GPEvent>.Continuation
    private let androidRestartContinuation: AsyncStream<GuestAndroidRestart>.Continuation
    private var stateObservers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var resynchronizationHandlers: [UUID: @Sendable (GuestSnapshotState) async -> Void] = [:]
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
    /// Whether this generation reached a usable, resynchronised connection.
    private var hasConnected = false
    /// Requests waiting for the connection to finish reconnecting.
    private var sendWaiters: [UUID: SendWaiter] = [:]
    /// When the recent protocol violations happened.
    private var violations: [ContinuousClock.Instant] = []
    /// Secondary connections belong to the control session whose token they present.
    private var secondaries: [GuestConnection] = []

    /// Creates a supervisor. The timings are the design values unless a test sets shorter ones.
    public init(
        transport: any GuestTransport,
        hostVersion: String = "dev",
        keepaliveInterval: Duration = .seconds(5),
        pingTimeout: Duration = .seconds(5),
        missLimit: Int = 3,
        backoffMinimum: Duration = .milliseconds(100),
        backoffMaximum: Duration = .seconds(2),
        requestReconnectTimeout: Duration = .seconds(5),
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
        self.requestReconnectTimeout = requestReconnectTimeout
        self.restartAgent = restartAgent
        let stream = AsyncStream.makeStream(of: GPEvent.self, bufferingPolicy: .bufferingNewest(1024))
        updates = stream.stream
        updateContinuation = stream.continuation
        let restartStream = AsyncStream.makeStream(
            of: GuestAndroidRestart.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        androidRestartEvents = restartStream.stream
        androidRestartContinuation = restartStream.continuation
    }

    /// Connects and resynchronises. A refused version or a refused Hello ends the attempts at once. Other failures
    /// are retried with the backoff until ``connectTimeout`` has passed, and then `connectTimedOut` is thrown. A
    /// ``stop()`` during the start throws `stopped`. After the first connection, the keepalive loop runs until
    /// ``stop()``.
    public func start(connectTimeout: Duration) async throws(GuestAgentFailure) {
        try await start(until: ContinuousClock.now + connectTimeout)
    }

    /// Connects before the supplied absolute deadline.
    func start(until deadline: ContinuousClock.Instant) async throws(GuestAgentFailure) {
        guard maintenance == nil else {
            return
        }
        hasConnected = false
        updateState(.connecting)
        protocolVersion = nil
        let started = generation
        var delay = backoffMinimum
        while true {
            let remaining = deadline - ContinuousClock.now
            do throws(GuestProtocolFailure) {
                guard remaining > .zero else {
                    throw GuestProtocolFailure.handshakeTimedOut
                }
                let attemptDeadline = min(deadline, ContinuousClock.now + GuestConnection.defaultHandshakeTimeout)
                try await establish(until: attemptDeadline)
                guard ContinuousClock.now < attemptDeadline else {
                    if let expired = connection {
                        await discardConnection(expired, generation: started)
                    }
                    throw GuestProtocolFailure.handshakeTimedOut
                }
                break
            } catch {
                guard generation == started else {
                    throw .stopped
                }
                if !error.isRetriable {
                    markTerminalState(for: error)
                    throw Self.startFailure(error)
                }
                if recordViolation(error) {
                    updateState(.unavailable)
                    logger.error(
                        "The Guest Agent broke the protocol too often, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    throw .requiredAgentUnavailable
                }
                let left = deadline - ContinuousClock.now
                if left <= .zero {
                    updateState(.unavailable)
                    throw Self.startFailure(error)
                }
                try? await Task.sleep(for: min(delay, left))
                guard generation == started else {
                    throw .stopped
                }
                delay = min(delay * 2, backoffMaximum)
            }
        }
        hasConnected = true
        updateState(.ready)
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
        protocolVersion = nil
        awaitingSnapshot = false
        buffered = []
        hasConnected = false
        updateState(.stopped)
        resumeSendWaiters()
        _ = await releaseSecondaries()
        await closing?.close()
        androidRestartContinuation.finish()
    }

    /// Registers a connection that presents the current control session token. The supervisor closes it when that
    /// session ends or this supervisor stops.
    func attachSecondary(_ secondary: GuestConnection, presenting token: Data) -> Bool {
        guard state == .ready, connection != nil, session?.sessionToken == token else {
            return false
        }
        secondaries.append(secondary)
        return true
    }

    /// Reads the connection state and negotiated version together as one status snapshot.
    public func statusSnapshot() -> StatusSnapshot {
        StatusSnapshot(state: state, protocolVersion: protocolVersion)
    }

    /// Streams the current connection state followed by every later transition.
    ///
    /// Registering and yielding the initial state happen in one actor turn, so a caller cannot miss a transition
    /// between reading the snapshot and subscribing.
    public func stateUpdates() -> AsyncStream<State> {
        let id = UUID()
        let stream = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(16))
        stateObservers[id] = stream.continuation
        stream.continuation.onTermination = { @Sendable _ in
            Task { await self.removeStateObserver(id) }
        }
        stream.continuation.yield(state)
        return stream.stream
    }

    /// Registers a host-state reconciler that runs after each complete snapshot and before the connection becomes
    /// ready. When already ready, the current snapshot is delivered once before this method returns.
    ///
    /// Handlers should reconcile host-owned state only. Guest operations needed by a handler must be scheduled to run
    /// after it returns, because ordinary sends wait for this barrier to complete.
    @discardableResult
    public func addResynchronizationHandler(
        _ handler: @escaping @Sendable (GuestSnapshotState) async -> Void
    ) async -> UUID {
        let id = UUID()
        resynchronizationHandlers[id] = handler
        guard state == .ready, let current = connection, await current.isUsable,
            state == .ready, connection === current
        else {
            return id
        }
        await handler(snapshot)
        return id
    }

    /// Removes a previously registered host-state reconciler.
    public func removeResynchronizationHandler(_ id: UUID) {
        resynchronizationHandlers[id] = nil
    }

    /// Sends one operation through the current connection. During a reconnect it waits up to
    /// ``requestReconnectTimeout`` for the new connection to finish its snapshot. Once submitted, an operation is
    /// never retried because the connection may have delivered it before failing.
    public func send<Operation: GuestOperation>(
        _ operation: Operation,
        timeout: Duration? = nil
    ) async throws(GuestProtocolFailure) -> Operation.Result {
        let started = generation
        let deadline = ContinuousClock.now + requestReconnectTimeout
        while true {
            guard !Task.isCancelled, generation == started else {
                throw .agentUnavailable(kind: .guestAgent)
            }
            if state == .ready, let current = connection, await current.isUsable {
                guard !Task.isCancelled, generation == started, state == .ready, connection === current else {
                    continue
                }
                return try await current.send(operation, timeout: timeout)
            }
            guard canWaitForReconnect(generation: started), ContinuousClock.now < deadline else {
                throw .agentUnavailable(kind: .guestAgent)
            }
            await waitForSendAvailability(until: deadline, generation: started)
        }
    }

    /// A state transition wakes queued requests so they can send, fail terminally, or keep waiting.
    private func updateState(_ newState: State) {
        guard state != newState else {
            return
        }
        state = newState
        for (id, continuation) in stateObservers {
            if case .terminated = continuation.yield(newState) {
                stateObservers[id] = nil
            }
        }
        resumeSendWaiters()
    }

    private func removeStateObserver(_ id: UUID) {
        stateObservers[id] = nil
    }

    /// Returns whether this request belongs to a connected generation that is actively reconnecting.
    private func canWaitForReconnect(generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration, hasConnected else {
            return false
        }
        switch state {
        case .ready, .reconnecting, .unresponsive:
            return true
        case .stopped, .connecting, .incompatible, .unavailable:
            return false
        }
    }

    /// Suspends one request until connection state changes, the deadline passes, the supervisor stops, or its task is
    /// cancelled. The caller rechecks all conditions after waking, so racing signals cannot submit twice.
    private func waitForSendAvailability(
        until deadline: ContinuousClock.Instant,
        generation expectedGeneration: UInt64
    ) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, canWaitForReconnect(generation: expectedGeneration) else {
                    continuation.resume()
                    return
                }
                let timeoutTask = Task { [weak self] in
                    do {
                        let remaining = deadline - ContinuousClock.now
                        if remaining > .zero {
                            try await Task.sleep(for: remaining)
                        }
                    } catch {
                        return
                    }
                    await self?.finishSendWaiter(waiterID)
                }
                sendWaiters[waiterID] = SendWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { await self.finishSendWaiter(waiterID) }
        }
    }

    /// Removes and resumes one waiter. Multiple completion signals are safe.
    private func finishSendWaiter(_ waiterID: UUID) {
        guard let waiter = sendWaiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume()
    }

    /// Resumes all waiting requests after a state transition or stop.
    private func resumeSendWaiters() {
        let waiters = Array(sendWaiters.values)
        sendWaiters.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    /// Waits for the event consumer to observe the requested mode on one Android display.
    ///
    /// This reads the supervisor's snapshot, which is updated by its existing single event consumer. It does not create
    /// another iterator over `updates`, so task and display events keep their existing delivery semantics.
    public func waitForDisplayMode(
        displayID: Int32,
        width: Int,
        height: Int,
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let display = snapshot.displays[displayID],
                display.mode.widthPx == width,
                display.mode.heightPx == height
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: - Connection

    /// Opens a connection, reads its handshake, and resynchronises with `GetSnapshot` before anything else. The
    /// connection is kept only when all of that succeeds, and it is closed otherwise.
    private func establish(limit: Duration) async throws(GuestProtocolFailure) {
        try await establish(until: ContinuousClock.now + limit)
    }

    /// Opens and resynchronises within an absolute attempt deadline.
    private func establish(until deadline: ContinuousClock.Instant) async throws(GuestProtocolFailure) {
        let started = generation
        let handshakeTimeout = min(GuestConnection.defaultHandshakeTimeout, deadline - ContinuousClock.now)
        guard handshakeTimeout > .zero else {
            throw .handshakeTimedOut
        }
        let next = GuestConnection(
            endpoint: .guestControl,
            transport: transport,
            hostVersion: hostVersion,
            handshakeTimeout: handshakeTimeout,
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
            protocolVersion = info.agentProtocolVersion
            consumer?.cancel()
            consumer = Task {
                for await event in next.events {
                    self.receive(event)
                }
                await self.connectionEnded(next)
            }
            let snapshotTimeout = deadline - ContinuousClock.now
            guard snapshotTimeout > .zero else {
                throw GuestProtocolFailure.handshakeTimedOut
            }
            let fresh = try await next.send(GuestGetSnapshot(), timeout: snapshotTimeout, grace: .zero)
            guard generation == started, connection === next else {
                throw GuestProtocolFailure.disconnected
            }
            guard ContinuousClock.now < deadline else {
                throw GuestProtocolFailure.handshakeTimedOut
            }
            let previousUptimeMillis = snapshot.androidUptimeMillis
            snapshot.replace(with: fresh)
            if let previousUptimeMillis,
                let currentUptimeMillis = snapshot.androidUptimeMillis,
                currentUptimeMillis < previousUptimeMillis
            {
                androidRestartContinuation.yield(
                    GuestAndroidRestart(
                        previousUptimeMillis: previousUptimeMillis,
                        currentUptimeMillis: currentUptimeMillis
                    )
                )
            }
            var eventsToPublish = buffered
            for event in eventsToPublish {
                snapshot.apply(event)
            }
            buffered = []

            var reconciledHandlerIDs: Set<UUID> = []
            while true {
                let handlers = resynchronizationHandlers.sorted { $0.key.uuidString < $1.key.uuidString }
                for (id, handler) in handlers {
                    guard resynchronizationHandlers[id] != nil else {
                        continue
                    }
                    await handler(snapshot)
                    guard generation == started, connection === next else {
                        throw GuestProtocolFailure.disconnected
                    }
                    reconciledHandlerIDs.insert(id)
                }

                let eventsReceivedDuringReconciliation = buffered
                buffered = []
                if !eventsReceivedDuringReconciliation.isEmpty {
                    eventsToPublish.append(contentsOf: eventsReceivedDuringReconciliation)
                    for event in eventsReceivedDuringReconciliation {
                        snapshot.apply(event)
                    }
                    // Reconcile the updated complete state before allowing queued requests to proceed.
                    continue
                }

                let currentHandlerIDs = Set(resynchronizationHandlers.keys)
                guard currentHandlerIDs.isSubset(of: reconciledHandlerIDs) else {
                    // A handler can be registered while another handler is suspended.
                    continue
                }
                break
            }

            awaitingSnapshot = false
            for event in eventsToPublish {
                updateContinuation.yield(event)
            }
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

    /// Closes a connection that finished after its startup attempt deadline.
    private func discardConnection(_ expired: GuestConnection, generation expectedGeneration: UInt64) async {
        guard generation == expectedGeneration, connection === expired else {
            return
        }
        connection = nil
        session = nil
        protocolVersion = nil
        awaitingSnapshot = false
        buffered = []
        consumer?.cancel()
        consumer = nil
        await expired.close()
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
                        updateState(.ready)
                    }
                } catch {
                    misses += 1
                    if await !current.isUsable {
                        misses = 0
                        await lost(.disconnected, cause: await current.closeReason, from: current)
                    } else if misses >= missLimit {
                        misses = 0
                        updateState(.unresponsive)
                        await lost(.unresponsive, cause: nil, from: current)
                    }
                }
            }
            guard !Task.isCancelled, state != .unavailable, state != .incompatible else {
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
        updateState(.reconnecting)
        let released = await releaseSecondaries()
        if released > 0 {
            logger.notice("The control session ended; \(released, .public) secondary connection(s) are released")
        }
        await dead.close()
        guard generation == started, !Task.isCancelled, maintenance != nil else {
            return
        }
        if let cause, recordViolation(cause) {
            updateState(.unavailable)
            logger.error(
                "The Guest Agent broke the protocol too often, so the agent stays down",
                errorCode: "runtime.requiredAgentUnavailable")
            return
        }
        let restarted = await restartAgent(reason)
        guard generation == started, !Task.isCancelled, maintenance != nil else {
            return
        }
        guard restarted else {
            logger.error(
                "The Guest Agent restart budget is spent, so the agent stays down",
                errorCode: "runtime.requiredAgentUnavailable")
            updateState(.unavailable)
            return
        }
        var delay = backoffMinimum
        while generation == started, !Task.isCancelled {
            do throws(GuestProtocolFailure) {
                try await establish(limit: GuestConnection.defaultHandshakeTimeout)
                hasConnected = true
                updateState(.ready)
                return
            } catch {
                guard generation == started else {
                    return
                }
                if !error.isRetriable {
                    markTerminalState(for: error)
                    logger.error(
                        "The Guest Agent refused the reconnection, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    return
                }
                if recordViolation(error) {
                    updateState(.unavailable)
                    logger.error(
                        "The Guest Agent broke the protocol too often, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    return
                }
                let restarted = await restartAgent(.disconnected)
                guard generation == started, !Task.isCancelled, maintenance != nil else {
                    return
                }
                guard restarted else {
                    logger.error(
                        "The Guest Agent restart budget is spent, so the agent stays down",
                        errorCode: "runtime.requiredAgentUnavailable")
                    updateState(.unavailable)
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

    /// Closes and removes the secondary connections of the ended control session.
    private func releaseSecondaries() async -> Int {
        let released = secondaries
        secondaries.removeAll()
        for secondary in released {
            await secondary.close()
        }
        return released.count
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

    /// Keeps an incompatible version visible to `runtimeStatus`; other terminal failures are unavailable.
    private func markTerminalState(for failure: GuestProtocolFailure) {
        if case .incompatibleVersion(_, let guest) = failure {
            protocolVersion = guest
            updateState(.incompatible)
        } else {
            updateState(.unavailable)
        }
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
