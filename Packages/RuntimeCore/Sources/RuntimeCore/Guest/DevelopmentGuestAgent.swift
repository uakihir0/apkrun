import DiagnosticsCore
import Foundation
import GuestProtocol

/// A relay from the supervisor's restart closure to the coordinator. The coordinator is an actor that holds the
/// supervisor, so the closure cannot capture it while the two are built.
private final class RestartRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (GuestAgentLoss) async -> Bool)?

    func set(_ handler: @escaping @Sendable (GuestAgentLoss) async -> Bool) {
        lock.withLock { self.handler = handler }
    }

    func restart(_ loss: GuestAgentLoss) async -> Bool {
        let current = lock.withLock { handler }
        guard let current else {
            return false
        }
        return await current(loss)
    }
}

/// The result of `LaunchApplication`, as the host reports it (guest-protocol.md §7.1 #14).
public struct GuestLaunchReport: Equatable, Sendable {
    /// The task that the launch started or brought to the front.
    public let taskID: Int32
    /// The component of the task's top activity.
    public let component: String
    /// `started`, `broughtToFront`, or `movedFromDisplay`.
    public let outcome: String

    /// Creates a report.
    public init(taskID: Int32, component: String, outcome: String) {
        self.taskID = taskID
        self.component = component
        self.outcome = outcome
    }
}

/// The development Guest Agent of one boot (guest-components.md §3, §6.1): it installs and starts the agent, keeps
/// the control connection, restarts a dead agent within the restart budget, and removes its forwards when it stops.
public actor DevelopmentGuestAgent {
    /// The control connection, with its keepalive and resync.
    public nonisolated let supervisor: GuestAgentSupervisor

    private let adb: AdbClient
    private let provisioner: GuestAgentProvisioner
    private let logger: APKLogger
    private let clock: @Sendable () -> ContinuousClock.Instant
    private var budget = GuestAgentRestartBudget()
    private var restartsRefused = false

    /// Creates the coordinator for `bundle`, reached through `adb`.
    public init(
        adb: AdbClient,
        bundle: GuestAgentBundle,
        hostVersion: String = "dev",
        logSink: (any LogSink)? = nil,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.adb = adb
        self.clock = clock
        logger = APKLogger(category: RuntimeLogCategory.agents, sink: logSink)
        provisioner = GuestAgentProvisioner(adb: adb, bundle: bundle)
        let relay = RestartRelay()
        supervisor = GuestAgentSupervisor(
            transport: ADBForwardGuestTransport(adb: adb, logSink: logSink),
            hostVersion: hostVersion,
            logSink: logSink,
            restartAgent: { loss in await relay.restart(loss) }
        )
        relay.set { [weak self] loss in
            guard let self else {
                return false
            }
            return await self.handleLoss(loss)
        }
    }

    /// Installs the agent, starts it, and connects within `connectTimeout` (guest-components.md §3.1, §3.2). The
    /// forwards that an earlier boot left behind are removed first, because they would make the forward fail.
    public func start(connectTimeout: Duration = .seconds(5)) async throws(GuestAgentFailure) {
        try await removeForwards()
        try await provisioner.installIfNeeded()
        try await provisioner.startAgent()
        try await supervisor.start(connectTimeout: connectTimeout)
    }

    /// Stops the supervisor and removes the forwards of the agent. It does not power off the guest.
    public func stop() async {
        await supervisor.stop()
        try? await removeForwards()
    }

    /// Launches a package on a display through `LaunchApplication` (guest-components.md §6.4). The result is the task
    /// that the agent reports, and a failure is the protocol failure, named as the agent's error.
    public func launch(package: String, displayID: Int32) async throws(GuestAgentFailure) -> GuestLaunchReport {
        try requireAvailable()
        let result: GPLaunchResult
        do {
            result = try await supervisor.send(GuestLaunchApplication(package: package, displayID: displayID))
        } catch {
            throw .operation(error)
        }
        let outcome: String
        switch result.outcome {
        case .broughtToFront: outcome = "broughtToFront"
        case .movedFromDisplay: outcome = "movedFromDisplay"
        default: outcome = "started"
        }
        return GuestLaunchReport(taskID: result.taskID, component: result.component, outcome: outcome)
    }

    /// Throws `requiredAgentUnavailable` once the restart budget is spent, and the agent stays down.
    public func requireAvailable() throws(GuestAgentFailure) {
        if restartsRefused {
            throw .requiredAgentUnavailable
        }
    }

    /// The decision on a lost agent (guest-components.md §3.3). A connection that closed while the process still runs
    /// reconnects without a restart. A dead or unresponsive agent counts a death, and it is restarted within the budget.
    private func handleLoss(_ loss: GuestAgentLoss) async -> Bool {
        if loss == .disconnected, (try? await provisioner.isRunning()) == true {
            return true
        }
        guard budget.recordDeath(at: clock()) else {
            restartsRefused = true
            return false
        }
        logger.notice("Restarting the Guest Agent after a \(String(describing: loss), .public) loss")
        do {
            try await provisioner.startAgent()
            return true
        } catch {
            restartsRefused = true
            logger.error("The Guest Agent did not restart", errorCode: "runtime.guestAgentStartFailed")
            return false
        }
    }

    /// Removes the forwards of the Guest Agent sockets (`localabstract:apkrun-`).
    private func removeForwards() async throws(GuestAgentFailure) {
        do {
            for forward in try await adb.forwardList() where forward.remote.hasPrefix("localabstract:apkrun-") {
                let port = forward.local.dropFirst("tcp:".count)
                if let number = UInt16(port) {
                    try await adb.forwardRemove(port: number)
                }
            }
        } catch {
            throw .adb(error)
        }
    }
}
