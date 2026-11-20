import APKStoreCore
import Foundation

/// How much of the post-update health check runs (update-system.md §8.1).
public enum HealthCheckLevel: String, Codable, Sendable, Equatable {
    /// H1–H4: the default for packages with a launcher activity.
    case full
    /// H1–H3: the app has never produced a first frame in APKRun.
    case processOnly
    /// H1: no launcher activity, or `update.healthCheckLaunch` is off.
    case versionOnly

    /// The level for a package (§8.1 levels).
    public static func level(
        hasLauncherActivity: Bool,
        healthCheckLaunchEnabled: Bool,
        hasProducedFrame: Bool
    ) -> HealthCheckLevel {
        guard hasLauncherActivity, healthCheckLaunchEnabled else { return .versionOnly }
        return hasProducedFrame ? .full : .processOnly
    }
}

/// The per-step and total budgets of the health check (§8.1).
public struct UpdateHealthCheckTimeouts: Sendable, Equatable {
    /// H1: Android reports the staged versionCode and signer set.
    public var metadata: Duration = .seconds(30)
    /// H2: `LaunchApplication` succeeds on the health-check display.
    public var launch: Duration = .seconds(20)
    /// H3: the process exists 5 s after launch and has not crashed by 15 s.
    public var processAlive: Duration = .seconds(15)
    /// H4: the health-check display receives a frame, after H2.
    public var firstFrame: Duration = .seconds(20)
    /// The whole check never outlives this budget.
    public var total: Duration = .seconds(90)

    /// Creates timeouts; defaults are §8.1.
    public init(
        metadata: Duration = .seconds(30),
        launch: Duration = .seconds(20),
        processAlive: Duration = .seconds(15),
        firstFrame: Duration = .seconds(20),
        total: Duration = .seconds(90)
    ) {
        self.metadata = metadata
        self.launch = launch
        self.processAlive = processAlive
        self.firstFrame = firstFrame
        self.total = total
    }
}

/// What the runtime answered for a health-check launch (§8.2).
public enum HealthLaunchResult: Sendable, Equatable {
    /// The launch succeeded, the process stayed alive, and a frame arrived.
    case frameDrawn
    /// The launch succeeded and the process stayed alive; no frame was
    /// required or one did not arrive in the `firstFrame` window.
    case processAlive
    /// `LaunchApplication` did not succeed.
    case launchFailed(detail: String)
    /// The process vanished or crashed inside the H3 window.
    case processDied(detail: String)
    /// A user session took over the launch: its own launch answers H2–H4
    /// (§8.2). Treat as `processAlive` for the check's purpose.
    case abandoned
}

/// Why the health check failed (§8.1, §8.3).
public enum HealthCheckFailure: Error, Sendable, Equatable {
    /// H1: Android never reported the staged version and signers.
    case versionNotConfirmed(found: VersionCode?)
    /// H2: the health-check launch failed.
    case launchFailed(detail: String)
    /// H3: the process did not stay alive.
    case processDied(detail: String)
    /// H4: no frame arrived on the health-check display.
    case frameNotDrawn
    /// The total 90 s budget ran out inside a step.
    case budgetExceeded(step: String)

    /// The step letter for history rows (§8.1 records the failure point).
    public var step: String {
        switch self {
        case .versionNotConfirmed: "H1"
        case .launchFailed: "H2"
        case .processDied: "H3"
        case .frameNotDrawn: "H4"
        case .budgetExceeded(let step): step
        }
    }

    /// A one-line description for `UpdateFailure.healthCheckFailed(detail:)`.
    public var detail: String {
        switch self {
        case .versionNotConfirmed(let found):
            "versionNotConfirmed(found: \(found.map(String.init) ?? "none"))"
        case .launchFailed(let detail):
            "launchFailed(\(detail))"
        case .processDied(let detail):
            "processDied(\(detail))"
        case .frameNotDrawn:
            "frameNotDrawn"
        case .budgetExceeded(let step):
            "budgetExceeded(\(step))"
        }
    }
}

/// The H1–H4 health check of update-system.md §8.1, clock-injected for tests.
public struct UpdateHealthChecker: Sendable {
    /// Reads Android's metadata for the package (H1).
    public var installedInfo: @Sendable (PackageID) async throws -> StorePackageInfo?
    /// Runs the §8.2 health-check launch (H2–H4).
    public var launch: @Sendable (PackageID, UpdateHealthCheckTimeouts) async -> HealthLaunchResult
    /// The poll interval of H1 and the budget watch.
    public var tick: Duration
    /// The clock; tests inject a manual one.
    public var now: @Sendable () -> ContinuousClock.Instant
    /// Suspends for a tick; tests inject an instant return.
    public var sleep: @Sendable (Duration) async -> Void

    /// Creates a checker; production passes the store and runtime closures.
    public init(
        installedInfo: @escaping @Sendable (PackageID) async throws -> StorePackageInfo?,
        launch: @escaping @Sendable (PackageID, UpdateHealthCheckTimeouts) async -> HealthLaunchResult,
        tick: Duration = .milliseconds(500),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.installedInfo = installedInfo
        self.launch = launch
        self.tick = tick
        self.now = now
        self.sleep = sleep
    }

    /// Runs the check at `level` and returns nil on pass, or the failing step.
    public func run(
        _ package: PackageID,
        expectedVersionCode: VersionCode,
        expectedSigners: Set<SHA256Digest>,
        level: HealthCheckLevel,
        timeouts: UpdateHealthCheckTimeouts = UpdateHealthCheckTimeouts()
    ) async -> HealthCheckFailure? {
        let deadline = now() + timeouts.total
        // H1 (30 s): Android reports the staged versionCode and signer set.
        let h1Deadline = now() + timeouts.metadata
        var found: VersionCode?
        var confirmed = false
        while now() < h1Deadline, now() < deadline {
            if let info = try? await installedInfo(package) {
                found = info.versionCode
                if info.versionCode == expectedVersionCode,
                    Set(info.signingDigests) == expectedSigners
                {
                    confirmed = true
                    break
                }
            }
            await sleep(tick)
        }
        guard confirmed else {
            if now() >= deadline, found == expectedVersionCode {
                return .budgetExceeded(step: "H1")
            }
            return .versionNotConfirmed(found: found)
        }
        guard level != .versionOnly else { return nil }
        if now() >= deadline { return .budgetExceeded(step: "H1") }

        // H2–H4 (§8.2): the runtime launches on the health-check display,
        // watches the process window, and waits for the first frame.
        let remaining = UpdateHealthCheckTimeouts(
            metadata: timeouts.metadata,
            launch: timeouts.launch,
            processAlive: timeouts.processAlive,
            firstFrame: timeouts.firstFrame,
            total: max(.zero, deadline - now())
        )
        switch await launch(package, remaining) {
        case .frameDrawn, .abandoned:
            return nil
        case .processAlive:
            // Alive but no frame: H4 fails only at the `full` level.
            return level == .full ? .frameNotDrawn : nil
        case .launchFailed(let detail):
            return .launchFailed(detail: detail)
        case .processDied(let detail):
            return .processDied(detail: detail)
        }
    }
}
