import APKStoreCore
import DiagnosticsCore
import Foundation

/// Drives the §3 scheduling rules: due checks with jitter and backoff,
/// apkrund-start / timer / wake / launch triggers, and the §3.4 resource
/// limits (update-system.md §3.2–§3.4).
///
/// All time sources are injectable so tests run on a manual clock. Network
/// and power sources are injected too (§3.4): a scheduled check waits for a
/// satisfied path, a background download waits for an inexpensive path and
/// for the low-power rule, while a user-initiated check never waits.
public actor UpdateScheduler {
    /// The phase machine the scheduled checks run through.
    private let coordinator: UpdateCoordinator
    /// `Updates/state.json`; the timer sleeps until the earliest `nextCheckAt`.
    private let stateStore: UpdateStateStore
    /// Managed-package records (authority, provider host, update mode).
    private let store: PackageStore
    /// Builds the provider context a scheduled check runs with.
    private let contextProvider: @Sendable () async -> ProviderContext
    /// The runtime access the install step needs; nil means staging waits.
    private let runtimeProvider: @Sendable () async -> (any UpdateRuntimeAccess)?
    /// The gentle-update gate install requests queue behind.
    private let gateProvider: @Sendable () async -> GentleUpdateGate?
    /// Injected clock; `ContinuousClock` in production (pitfall: never
    /// `SuspendingClock` — checks due during sleep run after wake).
    private let now: @Sendable () -> Date
    /// Injected sleep-until, so tests advance a manual clock.
    private let sleepUntil: @Sendable (Date) async -> Void
    /// §3.4: true when the network path is satisfied (NWPathMonitor).
    private let networkSatisfied: @Sendable () -> Bool
    /// §3.4: true when a background download may start — the path is not
    /// expensive/constrained unless `updates.downloadOnExpensiveNetwork`,
    /// and the set is not over 50 MiB in Low Power Mode.
    private let backgroundDownloadAllowed: @Sendable () -> Bool
    /// §3.3: a wake from sleep delays due checks so networking is up.
    private let wakeDelay: Duration
    /// §3.3: a due package's check after `noteLaunched` waits this long
    /// after the first frame.
    private let launchCheckDelay: Duration
    /// How long the timer waits before retrying a due check it could not
    /// start (offline or at the §3.4 caps) so an overdue package does not
    /// spin the sweep.
    private let retryDelay: Duration

    /// Checks currently running (a due package is never checked twice).
    private var inFlight: Set<PackageID> = []
    /// Checks currently running per provider host (§3.4, at most 2).
    private var inFlightByHost: [String: Int] = [:]
    /// The repeating sleep-until-earliest-due timer.
    private var timerTask: Task<Void, Never>?
    /// The one wake-delayed run (`noteSystemWake`).
    private var wakeTask: Task<Void, Never>?
    /// The 30-second delayed check per launched package.
    private var launchChecks: [PackageID: Task<Void, Never>] = [:]

    /// At most 4 checks in parallel, at most 2 per provider host (§3.4).
    private static let maxParallelChecks = 4
    private static let maxChecksPerHost = 2

    /// Creates a scheduler.
    public init(
        coordinator: UpdateCoordinator,
        stateStore: UpdateStateStore,
        store: PackageStore,
        contextProvider: @escaping @Sendable () async -> ProviderContext,
        runtimeProvider: @escaping @Sendable () async -> (any UpdateRuntimeAccess)?,
        gateProvider: @escaping @Sendable () async -> GentleUpdateGate?,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepUntil: @escaping @Sendable (Date) async -> Void = { target in
            try? await Task.sleep(for: .seconds(target.timeIntervalSinceNow))
        },
        networkSatisfied: @escaping @Sendable () -> Bool = { true },
        backgroundDownloadAllowed: @escaping @Sendable () -> Bool = { true },
        wakeDelay: Duration = .seconds(120),
        launchCheckDelay: Duration = .seconds(30),
        retryDelay: Duration = .seconds(60)
    ) {
        self.coordinator = coordinator
        self.stateStore = stateStore
        self.store = store
        self.contextProvider = contextProvider
        self.runtimeProvider = runtimeProvider
        self.gateProvider = gateProvider
        self.now = now
        self.sleepUntil = sleepUntil
        self.networkSatisfied = networkSatisfied
        self.backgroundDownloadAllowed = backgroundDownloadAllowed
        self.wakeDelay = wakeDelay
        self.launchCheckDelay = launchCheckDelay
        self.retryDelay = retryDelay
    }

    // MARK: - Triggers (§3.3)

    /// apkrund started: run every due check, then keep the timer armed.
    public func start() {
        armTimer()
        Task { await runDueChecks(trigger: .scheduled) }
        Task { await resumeStagedInstalls() }
    }

    /// §7.1 and §3.5: a daemon restart forgets the gate's in-memory queue.
    /// Re-request admission for every staged row so an admitted install —
    /// including the >24 h headless boot — does not wait for the next check.
    private func resumeStagedInstalls() async {
        try? await store.open()
        let staged = await stateStore.allStates()
            .filter { $0.value.phase == "staged" }
            .map(\.key)
        guard !staged.isEmpty else { return }
        guard let runtime = await runtimeProvider(),
            let gate = await gateProvider()
        else { return }
        for packageID in staged {
            if await gate.requestInstall(packageID) {
                _ = await coordinator.resumeStagedInstall(
                    packageID, trigger: .scheduled, runtime: runtime, gate: gate)
                return
            }
        }
    }

    /// apkrund is shutting down: cancel the timer and delayed checks.
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        for (_, task) in launchChecks { task.cancel() }
        launchChecks.removeAll()
    }

    /// The Mac woke from sleep: due checks run after the §3.3 delay.
    public func noteSystemWake() {
        let delay = wakeDelay
        wakeTask?.cancel()
        wakeTask = Task {
            await sleepUntil(
                now().addingTimeInterval(
                    TimeInterval(delay.components.seconds)))
            guard !Task.isCancelled else { return }
            await runDueChecks(trigger: .scheduled)
        }
    }

    /// §3.3 / runtime-daemon §7.1: a session for `packageID` opened. When the
    /// package is due, it is checked 30 s after the first frame, at utility
    /// priority. A package that is not due does nothing.
    public func noteLaunched(_ packageID: PackageID) async {
        guard launchChecks[packageID] == nil else { return }
        let delay = launchCheckDelay
        launchChecks[packageID] = Task {
            await sleepUntil(
                now().addingTimeInterval(
                    TimeInterval(delay.components.seconds)))
            defer { Task { await self.clearLaunchCheck(packageID) } }
            guard !Task.isCancelled else { return }
            guard networkSatisfied() else { return }
            let due = await coordinator.duePackages(now: now())
            guard due.contains(packageID) else { return }
            await runCheck(packageID, trigger: .launchOpportunistic)
        }
    }

    /// Runs every due check within the §3.4 limits. Waits for a satisfied
    /// path; user-initiated checks take a different path and never wait.
    /// Returns the number of checks started.
    @discardableResult
    public func runDueChecks(trigger: UpdateTrigger) async -> Int {
        guard networkSatisfied() else { return 0 }
        try? await store.open()
        let due = await coordinator.duePackages(now: now())
        var started = 0
        for packageID in due where admissible(packageID) {
            started += 1
            Task { await self.runCheck(packageID, trigger: trigger) }
        }
        return started
    }

    /// The earliest `nextCheckAt` of any managed `apkrun` package — the
    /// instant the timer should fire next (§3.3 "sleep until the earliest
    /// nextCheckAt"). nil means nothing is scheduled.
    public func earliestWakeAt() async -> Date? {
        try? await store.open()
        let records = (try? await store.listManagedPackages()) ?? []
        let states = await stateStore.allStates()
        return records.filter {
            $0.updateAuthority == .apkrun && $0.updateProvider != nil
        }.compactMap { states[$0.packageId]?.nextCheckAt }
            .min()
    }

    // MARK: - Internals

    /// True while a check slot is free globally and on the package's host.
    private func admissible(_ packageID: PackageID) -> Bool {
        !inFlight.contains(packageID) && inFlight.count < Self.maxParallelChecks
    }

    /// Runs one package's scheduled pipeline: `checking` → `available` →
    /// `downloading` → `validating` → staging through the gate (§3.1: the
    /// host-only part never touches Android; the install waits for the gate).
    private func runCheck(_ packageID: PackageID, trigger: UpdateTrigger) async {
        guard admissible(packageID) else { return }
        let host = await providerHost(for: packageID)
        if inFlight.count >= Self.maxParallelChecks
            || (inFlightByHost[host] ?? 0) >= Self.maxChecksPerHost
        {
            return
        }
        inFlight.insert(packageID)
        inFlightByHost[host, default: 0] += 1
        defer {
            inFlight.remove(packageID)
            inFlightByHost[host, default: 1] -= 1
            armTimer()
        }

        let outcome = await coordinator.check(
            packageID, trigger: trigger, context: await contextProvider())
        guard case .available(let candidate) = outcome else { return }

        // §3.4: a scheduled background download waits on an inexpensive path
        // and the low-power rule; `notifyOnly` mode stops after the check
        // (§2.2). Manual packages are not in `duePackages` at all (§3.2).
        guard let settings = try? await store.packageSettings(for: packageID),
            settings.updateMode != "notifyOnly", backgroundDownloadAllowed()
        else { return }
        guard let runtime = await runtimeProvider(), let gate = await gateProvider() else {
            return
        }
        let started = now()
        switch await coordinator.download(
            packageID, candidate: candidate, context: await contextProvider(),
            trigger: trigger, started: started)
        {
        case .failed:
            return
        case .downloaded(let downloaded):
            switch await coordinator.validate(
                packageID, ticket: downloaded.ticket, candidate: candidate,
                trigger: trigger, started: started)
            {
            case .failed:
                return
            case .validated(let validated):
                _ = await coordinator.install(
                    packageID, validated: validated, candidate: candidate,
                    trigger: trigger, runtime: runtime, gate: gate,
                    started: started)
            }
        }
    }

    /// The provider host a package's checks count against (§3.4).
    private func providerHost(for packageID: PackageID) async -> String {
        let records = (try? await store.listManagedPackages()) ?? []
        guard
            let ref = records.first(where: { $0.packageId == packageID })?
                .updateProvider
        else { return "" }
        switch ref.configuration {
        case .local: return "local"
        case .direct(let url):
            return URL(string: url)?.host?.lowercased() ?? url
        case .fdroid(let repository, _):
            return URL(string: repository)?.host?.lowercased() ?? repository
        case .github: return "api.github.com"
        }
    }

    /// Re-arms the single timer to fire at `earliestWakeAt`. A deadline that
    /// is still past after a sweep (the check could not start — offline or
    /// the §3.4 caps were full) paces retries with `retryDelay` instead of
    /// refiring the timer in a hot loop.
    private func armTimer() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                guard var wake = await earliestWakeAt() else { return }
                if wake > now() {
                    await sleepUntil(wake)
                    guard !Task.isCancelled else { return }
                }
                _ = await runDueChecks(trigger: .scheduled)
                guard let next = await earliestWakeAt() else { return }
                while next <= now(), !Task.isCancelled {
                    await sleepUntil(
                        now().addingTimeInterval(
                            TimeInterval(retryDelay.components.seconds)))
                    guard !Task.isCancelled else { return }
                    guard let retry = await earliestWakeAt() else { return }
                    if retry > now() {
                        wake = retry
                        break
                    }
                    _ = await runDueChecks(trigger: .scheduled)
                    guard let again = await earliestWakeAt() else { return }
                    wake = again
                    if again > now() { break }
                }
                if wake > now() {
                    continue
                }
            }
        }
    }

    /// Drops the finished delayed launch check for `packageID`.
    private func clearLaunchCheck(_ packageID: PackageID) {
        launchChecks.removeValue(forKey: packageID)
    }
}
