import APKStoreCore
import Foundation
import RuntimeAPI

/// An event the gentle-update gate reacts to (update-system.md §7.2):
/// the runtime becoming ready, sessions starting and ending, and
/// keepRunning tasks ending.
public enum UpdateRuntimeEvent: Sendable, Equatable {
    /// Android's lifecycle state changed.
    case stateChanged(WireRuntimeState)
    /// A session for the package started.
    case sessionStarted(PackageID)
    /// A session for the package ended; GU4's 15-second timer starts here.
    case sessionEnded(PackageID)
    /// A keepRunning task for the package ended (GU3 re-check).
    case taskEnded(PackageID)
}

/// Why the update system brings the runtime up (update-system.md §3.5).
public enum UpdateStartReason: Sendable, Equatable {
    /// A scheduled or gentle install (§3.5 `.update`).
    case update
    /// `apkrun update --now`: the user asked, so the runtime may resume
    /// even from a suspended state (§7.1 GU1, §7.3).
    case user
}

/// Why the update system ends a package's sessions (update-system.md §7.3).
public enum UpdateSessionEndReason: Sendable, Equatable {
    /// The package is being updated (state-machines.md §3 `.updating`).
    case updating
}

/// A held runtime activity assertion (runtime-daemon.md §5.1). The
/// `storeOperation` kind holds off idle shutdown while an install runs;
/// release it with `release()` or by letting it deinit.
public final class UpdateActivityAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    /// Creates an assertion that runs `onRelease` exactly once.
    public init(onRelease: @escaping @Sendable () -> Void = {}) {
        self.onRelease = onRelease
    }

    /// Releases the assertion; idempotent.
    public func release() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        action = onRelease
        onRelease = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}

/// The runtime surface an update install needs (update-system.md §7.5).
/// RuntimeHost injects the implementation; UpdateCore never imports
/// RuntimeCore. `healthCheckLaunch` arrives with the health-check task.
public protocol UpdateRuntimeAccess: Sendable {
    /// Android's state as the runtime reports it.
    var runtimeState: WireRuntimeState { get async }
    /// State changes, session starts/ends, and task ends (§7.2 triggers).
    var runtimeEvents: AsyncStream<UpdateRuntimeEvent> { get }
    /// GU2 + GU3: the package has an open session (any state but `ended`,
    /// including `backgrounded`) or a keepRunning task; the install must
    /// stay staged.
    func hasActiveUse(_ package: PackageID) async -> Bool
    /// GU4: when the package's last session ended, or `nil` when none is
    /// known. The gate treats `nil` as "long ago".
    func lastSessionEnd(_ package: PackageID) async -> ContinuousClock.Instant?
    /// GU5, hint only: Android agrees the install is gentle. Custom images
    /// answer Store Agent op 110 (`GENTLE_UPDATE`); stock images fall back
    /// to `ListTasks`. The gate never treats a failed query as blocking.
    func androidAllowsGentleInstall(_ package: PackageID) async -> Bool
    /// Brings the runtime up for an update (§3.5, §7.3). Automatic runs
    /// need a ready runtime.
    func ensureReady(_ reason: UpdateStartReason) async throws
    /// GU1: whether a stopped runtime may boot for an automatic install —
    /// the §3.5 headless-boot conditions (setting, staged wait, AC power,
    /// idle user). The gate asks this only while the runtime is `stopped`.
    func mayStartForUpdateInstall() async -> Bool
    /// Ends every session of the package (Update Now, §7.3).
    func endSessions(for package: PackageID, reason: UpdateSessionEndReason) async
    /// Reopens the package after Update Now (§7.3).
    func reopen(_ package: PackageID) async
    /// Holds a `storeOperation` activity assertion for an install's
    /// duration (§7.2; runtime-daemon.md §5.1). Throws when the runtime is
    /// already stopping — the install fails instead of racing shutdown.
    func assertStoreOperation() async throws -> UpdateActivityAssertion
    /// Reports that the caller finished its follow-ups (reopen, queue
    /// drain) after an install. The §3.5 stop runs here — after a reopen
    /// could claim a session — and on the assertion's release as a
    /// fallback.
    func updatesIdle() async
    /// Launches the package on the health-check display for H2–H4
    /// (§8.2): a system-session DisplayPool lease, no window, no
    /// force-stop afterwards.
    func healthCheckLaunch(_ package: PackageID, timeouts: UpdateHealthCheckTimeouts) async
        -> HealthLaunchResult
    /// Whether the package has ever produced a first frame in an APKRun
    /// session (§8.1 `processOnly` level choice).
    func hasDrawnFrame(_ package: PackageID) async -> Bool
}

extension UpdateRuntimeAccess {
    /// Channels without an event source emit nothing.
    public var runtimeEvents: AsyncStream<UpdateRuntimeEvent> { AsyncStream { $0.finish() } }
    /// No session history means no recent session.
    public func lastSessionEnd(_ package: PackageID) async -> ContinuousClock.Instant? { nil }
    /// GU5 is a hint: a channel that cannot ask Android does not block.
    public func androidAllowsGentleInstall(_ package: PackageID) async -> Bool { true }
    /// Ending sessions is a no-op when nothing can run sessions.
    public func endSessions(for package: PackageID, reason: UpdateSessionEndReason) async {}
    /// A channel that cannot boot Android never allows an automatic start.
    public func mayStartForUpdateInstall() async -> Bool { false }
    /// Reopening is a no-op when the channel cannot launch sessions.
    public func reopen(_ package: PackageID) async {}
    /// Runtimes without an idle controller return a no-op assertion.
    public func assertStoreOperation() async -> UpdateActivityAssertion {
        UpdateActivityAssertion()
    }
    /// Nothing to settle on a channel that cannot boot Android.
    public func updatesIdle() async {}
    /// A channel that cannot launch answers like a missing launcher: the
    /// H2–H4 steps then fail as a launch failure.
    public func healthCheckLaunch(_ package: PackageID, timeouts: UpdateHealthCheckTimeouts) async
        -> HealthLaunchResult
    {
        .launchFailed(detail: "no session channel")
    }
    /// A channel without session history cannot prove a frame ever drew.
    public func hasDrawnFrame(_ package: PackageID) async -> Bool { false }
}
