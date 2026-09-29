import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing

@Test func healthVerdictChecksEveryRowInPriorityOrder() {
    #expect(verdict([healthResult("host.appleSilicon", .failure)]) == .hostUnsupported)
    #expect(verdict([healthResult("vm.virtualizationSupported", .failure)]) == .hostUnsupported)
    #expect(verdict([healthResult("apkrund.registration", .failure)]) == .serviceUnavailable)
    #expect(verdict([healthResult("apkrund.reachable", .failure)]) == .serviceUnavailable)
    #expect(
        HealthVerdict.evaluate(
            results: [],
            context: HealthVerdictContext(runtimeState: .stopped, provisioningComplete: false)
        ) == .notSetUp
    )
    #expect(verdict([healthResult("runtime.provisioning", .failure)]) == .notSetUp)
    #expect(verdict([healthResult("image.current", .failure)]) == .notSetUp)
    #expect(
        HealthVerdict.evaluate(
            results: [
                healthResult("graphics.renderer", .failure),
                healthResult("runtime.boot", .failure),
            ],
            context: HealthVerdictContext(runtimeState: .failed)
        ) == .graphicsFailure
    )
    #expect(
        HealthVerdict.evaluate(
            results: [],
            context: HealthVerdictContext(
                runtimeState: .failed,
                lastBootFailureCode: "graphics.rendererLost"
            )
        ) == .graphicsFailure
    )
    #expect(
        HealthVerdict.evaluate(
            results: [
                healthResult("runtime.boot", .failure, errorCode: "runtime.graphics")
            ],
            context: HealthVerdictContext(runtimeState: .failed)
        ) == .graphicsFailure
    )
    #expect(
        HealthVerdict.evaluate(
            results: [healthResult("runtime.state", .failure)],
            context: HealthVerdictContext(runtimeState: .other)
        ) == .bootFailure
    )
    #expect(
        HealthVerdict.evaluate(
            results: [healthResult("runtime.boot", .failure)],
            context: HealthVerdictContext(runtimeState: .failed)
        ) == .bootFailure
    )
    #expect(
        HealthVerdict.evaluate(
            results: [],
            context: HealthVerdictContext(runtimeState: .stopped, bootLoopGuarded: true)
        ) == .bootFailure
    )
    #expect(
        HealthVerdict.evaluate(
            results: [healthResult("agent.guest", .failure)],
            context: HealthVerdictContext(runtimeState: .ready)
        ) == .agentUnavailable
    )
    #expect(
        HealthVerdict.evaluate(
            results: [healthResult("agent.store", .failure)],
            context: HealthVerdictContext(runtimeState: .ready)
        ) == .agentUnavailable
    )
    #expect(verdict([healthResult("store.pending", .warning)]) == .degraded)
    #expect(verdict([healthResult("store.pending", .failure)]) == .degraded)
    #expect(verdict([], runtimeState: .stopped) == .stopped)
    #expect(verdict([], runtimeState: .ready) == .healthy)
    #expect(verdict([], runtimeState: .suspended) == .healthy)
}

@Test func healthVerdictStatusLineRetainsStoppedStateAndBootPhase() {
    let warning = healthResult("host.memory", .warning)
    let degraded = HealthVerdict.evaluate(
        results: [warning],
        context: HealthVerdictContext(runtimeState: .stopped)
    )
    #expect(
        degraded.statusLine(results: [warning], runtimeState: .stopped)
            == "Needs attention (1 warning) · Android is not running"
    )
    #expect(
        HealthVerdict.stopped.statusLine(results: [], runtimeState: .stopped)
            == "Healthy · Android is not running"
    )

    let bootResult = healthResult(
        "runtime.boot",
        .failure,
        detail: "stopped at systemServer after 180 s"
    )
    #expect(
        HealthVerdict.bootFailure.statusLine(
            results: [bootResult],
            runtimeState: .failed
        ) == "Android failed to start · stopped at systemServer after 180 s"
    )
    let previousSuccessfulBoot = healthResult(
        "runtime.boot",
        .pass,
        detail: "last boot completed in 31 s"
    )
    #expect(
        HealthVerdict.bootFailure.statusLine(
            results: [previousSuccessfulBoot],
            runtimeState: .failed
        ) == "Android failed to start"
    )
}

@Test func healthVerdictHasStableStatusLineForEveryVerdict() {
    #expect(
        HealthVerdict.hostUnsupported.statusLine(results: [], runtimeState: .failed)
            == "APKRun can't run on this Mac")
    #expect(
        HealthVerdict.serviceUnavailable.statusLine(results: [], runtimeState: .stopped)
            == "Background service not running")
    #expect(
        HealthVerdict.notSetUp.statusLine(results: [], runtimeState: .stopped)
            == "Setup not finished")
    #expect(
        HealthVerdict.graphicsFailure.statusLine(results: [], runtimeState: .failed)
            == "Graphics failed to start")
    #expect(
        HealthVerdict.bootFailure.statusLine(results: [], runtimeState: .failed)
            == "Android failed to start")
    #expect(
        HealthVerdict.agentUnavailable.statusLine(
            results: [healthResult("agent.store", .failure)],
            runtimeState: .ready
        ) == "Store Agent unavailable"
    )
    #expect(HealthVerdict.degraded.statusLine(results: [], runtimeState: .ready) == "Needs attention")
    #expect(HealthVerdict.healthy.statusLine(results: [], runtimeState: .suspended) == "Healthy")
    #expect(HealthVerdict.unknown.statusLine(results: [], runtimeState: .other) == "Health status unavailable")
}

@Test func healthVerdictDecodesFutureCasesAsUnknown() throws {
    let verdict = try JSONDecoder().decode(
        HealthVerdict.self,
        from: Data(#""futureVerdict""#.utf8)
    )
    #expect(verdict == .unknown)
    #expect(
        try JSONDecoder().decode(
            HealthVerdict.self,
            from: JSONEncoder().encode(HealthVerdict.healthy)
        ) == .healthy
    )
}

@Test func healthResultAndReportCodableRoundTrip() throws {
    let measuredAt = Date(timeIntervalSince1970: 1_790_000_000)
    let result = HealthResult(
        id: "host.dataVolume",
        group: .host,
        state: .warning,
        title: LocalizedText(key: "host.dataVolume", fallback: "APKRun data volume"),
        detail: "4 GiB available.",
        error: ErrorInfo(
            code: "diagnostics.lowDiskSpace",
            message: LocalizedText(
                key: "diagnostics.lowDiskSpace",
                parameters: ["available": .bytes(4 * 1_024 * 1_024 * 1_024)],
                fallback: "Only 4 GiB is free."
            ),
            remediation: LocalizedText(
                key: "diagnostics.lowDiskSpace.remediation",
                fallback: "Free up space."
            ),
            action: .openStorageSettings
        ),
        measuredAt: measuredAt
    )
    let report = HealthReport(
        generatedAt: measuredAt,
        build: BuildInfo(infoDictionary: ["CFBundleVersion": "42"]),
        imageVersion: "2026.10.0-arm64",
        runtimeRunning: false,
        verdict: .degraded,
        results: [result]
    )

    let data = try JSONEncoder().encode(report)
    #expect(try JSONDecoder().decode(HealthReport.self, from: data) == report)
}

@Test func healthRegistrySortsByGroupAndKeepsRegistrationOrderWithinGroup() async throws {
    let registry = HealthCheckRegistry(checks: [
        FixtureHealthCheck(id: "graphics.renderer", group: .graphics),
        FixtureHealthCheck(id: "host.memory", group: .host),
        FixtureHealthCheck(id: "host.appleSilicon", group: .host),
        FixtureHealthCheck(id: "apkrund.registration", group: .backgroundService),
    ])
    let context = testingHealthContext()

    let results = await registry.run(
        context: context.healthContext(daemonAvailable: true, runtimeRunning: true)
    )
    #expect(
        results.map(\.id) == [
            "host.memory",
            "host.appleSilicon",
            "apkrund.registration",
            "graphics.renderer",
        ])
}

@Test func healthRegistrySkipsChecksByCostAndRuntimeRequirement() async throws {
    let lastKnown = LastKnown(
        state: .pass,
        detail: "last boot completed in 31 s",
        measuredAt: Date(timeIntervalSince1970: 10)
    )
    let registry = HealthCheckRegistry(checks: [
        FixtureHealthCheck(
            id: "graphics.guestDriver",
            group: .graphics,
            requirement: .daemon,
            cost: .deep
        ),
        FixtureHealthCheck(id: "runtime.boot", group: .android, requirement: .runningRuntime),
        FixtureHealthCheck(id: "runtime.provisioning", group: .android, requirement: .daemon),
    ])
    let context = testingHealthContext()

    let stopped = await registry.run(
        context: context.healthContext(
            daemonAvailable: true,
            runtimeRunning: false,
            lastKnown: ["runtime.boot": lastKnown]
        )
    )
    #expect(stopped.first(where: { $0.id == "runtime.boot" })?.state == .skipped)
    #expect(stopped.first(where: { $0.id == "runtime.boot" })?.detail == "Android is not running")
    #expect(stopped.first(where: { $0.id == "runtime.boot" })?.lastKnown == lastKnown)
    #expect(
        stopped.first(where: { $0.id == "graphics.guestDriver" })?.detail
            == "Run with --deep to include this check."
    )
    #expect(stopped.allSatisfy { $0.error == nil })

    let daemonUnavailable = await registry.run(
        deep: true,
        context: context.healthContext(daemonAvailable: false, runtimeRunning: false)
    )
    #expect(daemonUnavailable.allSatisfy { $0.state == .skipped })
    #expect(daemonUnavailable.allSatisfy { $0.detail == "Background service not running" })
}

@Test func healthRegistryRejectsDuplicateIDs() async throws {
    let registry = HealthCheckRegistry()
    try await registry.register(FixtureHealthCheck(id: "host.memory"))
    await #expect(throws: HealthCheckRegistryError.duplicateCheck(id: "host.memory")) {
        try await registry.register(FixtureHealthCheck(id: "host.memory"))
    }
}

@Test func healthRegistryTimesOutChecksAndCapsConcurrencyAtEight() async {
    let timeoutRegistry = HealthCheckRegistry(
        checks: [FixtureHealthCheck(id: "test.slow", delay: .seconds(1))],
        timeouts: HealthCheckTimeouts(quick: .milliseconds(20), deep: .milliseconds(20))
    )
    let context = testingHealthContext()
    let timedOut = await timeoutRegistry.run(
        context: context.healthContext(daemonAvailable: true, runtimeRunning: true)
    )
    #expect(timedOut.first?.state == .warning)
    #expect(timedOut.first?.detail == "check timed out")
    #expect(timedOut.first?.error == nil)

    let counter = ConcurrentCheckCounter()
    let checks = (0..<24).map { index in
        FixtureHealthCheck(
            id: "test.concurrent.\(index)",
            delay: .milliseconds(10),
            counter: counter
        )
    }
    let registry = HealthCheckRegistry(
        checks: checks,
        timeouts: HealthCheckTimeouts(quick: .seconds(1), deep: .seconds(1))
    )
    let results = await registry.run(
        context: context.healthContext(daemonAvailable: true, runtimeRunning: true)
    )
    #expect(results.count == 24)
    #expect(await counter.maximumObserved() <= 8)
}

@Test func healthRegistryReturnsOnTimeoutForCancellationIgnoringChecks() async {
    let latch = HealthCheckLatch()
    let registry = HealthCheckRegistry(
        checks: [
            BlockingHealthCheck(id: "test.blocked", latch: latch),
            BlockingHealthCheck(id: "test.queued", latch: latch),
        ],
        timeouts: HealthCheckTimeouts(quick: .milliseconds(25), deep: .milliseconds(25)),
        maximumConcurrentChecks: 1
    )
    let context = testingHealthContext()

    let results = await registry.run(
        context: context.healthContext(daemonAvailable: true, runtimeRunning: true)
    )
    #expect(results.count == 2)
    #expect(results.allSatisfy { $0.state == .warning && $0.detail == "check timed out" })
    await latch.release()
}

@Test func healthRegistryCallerCancellationReturnsWithoutWaitingForCheckTimeout() async {
    let latch = HealthCheckLatch()
    let registry = HealthCheckRegistry(
        checks: [BlockingHealthCheck(id: "test.blocked", latch: latch)],
        timeouts: HealthCheckTimeouts(quick: .seconds(10), deep: .seconds(10))
    )
    let context = testingHealthContext()
    let task = Task {
        await registry.run(
            context: context.healthContext(daemonAvailable: true, runtimeRunning: true)
        )
    }

    await latch.waitUntilStarted()
    task.cancel()
    #expect(await task.value.isEmpty)
    await latch.release()
}

@Test func diagnosticsContextTestingProvidesIsolatedDependencies() async {
    let context = DiagnosticsContext.testing()
    let ids = await context.healthChecks.checkIDs()
    #expect(ids.contains("host.appleSilicon"))
    #expect(ids.contains("apkrund.registration"))
    #expect(context.perfTimeline.snapshot().isEmpty)
    #expect(context.paths.logsRoot.path.hasPrefix(context.paths.dataRoot.path))
}

private func verdict(
    _ results: [HealthResult],
    runtimeState: HealthRuntimeState = .ready
) -> HealthVerdict {
    HealthVerdict.evaluate(
        results: results,
        context: HealthVerdictContext(runtimeState: runtimeState)
    )
}

private func healthResult(
    _ id: String,
    _ state: HealthState,
    group: HealthGroup = .host,
    detail: String? = nil,
    errorCode: String? = nil
) -> HealthResult {
    let error = errorCode.map {
        ErrorInfo(
            code: $0,
            message: LocalizedText(key: $0, fallback: "Failure")
        )
    }
    return HealthResult(
        id: id,
        group: group,
        state: state,
        title: LocalizedText(key: id, fallback: id),
        detail: detail,
        error: error,
        measuredAt: Date(timeIntervalSince1970: 0)
    )
}

private func testingHealthContext() -> DiagnosticsContext {
    DiagnosticsContext.testing(
        root: URL(fileURLWithPath: "/tmp/apkrun-health-tests", isDirectory: true)
    )
}

private struct FixtureHealthCheck: HealthCheck {
    let id: HealthCheckID
    var group: HealthGroup = .host
    var requirement: HealthRequirement = .host
    var cost: HealthCost = .quick
    var delay: Duration = .zero
    var counter: ConcurrentCheckCounter?

    var title: LocalizedText {
        LocalizedText(key: id, fallback: id)
    }

    func run(_ context: HealthContext) async -> HealthResult {
        await counter?.begin()
        if delay > .zero {
            try? await ContinuousClock().sleep(for: delay)
        }
        await counter?.end()
        return HealthResult(
            id: id,
            group: group,
            state: .pass,
            title: title,
            detail: nil,
            measuredAt: context.clock.now
        )
    }
}

private struct BlockingHealthCheck: HealthCheck {
    let id: HealthCheckID
    let latch: HealthCheckLatch

    var group: HealthGroup { .host }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var title: LocalizedText { LocalizedText(key: id, fallback: id) }

    func run(_ context: HealthContext) async -> HealthResult {
        await latch.block()
        return HealthResult(
            id: id,
            group: group,
            state: .pass,
            title: title,
            measuredAt: context.clock.now
        )
    }
}

private actor HealthCheckLatch {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        if released {
            return
        }
        await withCheckedContinuation { blockWaiters.append($0) }
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in blockWaiters {
            waiter.resume()
        }
        blockWaiters.removeAll()
    }
}

private actor ConcurrentCheckCounter {
    private var active = 0
    private var maximum = 0

    func begin() {
        active += 1
        maximum = max(maximum, active)
    }

    func end() {
        active -= 1
    }

    func maximumObserved() -> Int {
        maximum
    }
}
