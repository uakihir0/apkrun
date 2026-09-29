import Foundation

private enum HealthCheckOutcome: Sendable {
    case completed(HealthResult)
    case timedOut
    case cancelled
}

/// A time budget for health checks.
public struct HealthCheckTimeouts: Sendable {
    public let quick: Duration
    public let deep: Duration

    public static let standard = HealthCheckTimeouts(
        quick: .seconds(2),
        deep: .seconds(60)
    )

    public init(quick: Duration, deep: Duration) {
        precondition(quick > .zero && deep > .zero)
        self.quick = quick
        self.deep = deep
    }

    fileprivate func timeout(for cost: HealthCost) -> Duration {
        cost == .quick ? quick : deep
    }
}

/// A safe, idempotent action that a health check may offer.
public protocol HealthFix: Sendable {
    var id: String { get }
    func apply(_ context: HealthContext) async throws
}

/// Context available to health checks.
public struct HealthContext: Sendable {
    public let daemonAvailable: Bool
    public let runtimeRunning: Bool
    public let lastKnown: [HealthCheckID: LastKnown]
    public let buildInfo: BuildInfo
    public let paths: APKRunPaths
    public let clock: any DiagnosticsClock
    public let hostProbe: any HostProbe

    public init(
        daemonAvailable: Bool,
        runtimeRunning: Bool,
        lastKnown: [HealthCheckID: LastKnown] = [:],
        buildInfo: BuildInfo = .current,
        paths: APKRunPaths,
        clock: any DiagnosticsClock = SystemDiagnosticsClock(),
        hostProbe: any HostProbe = SystemHostProbe()
    ) {
        self.daemonAvailable = daemonAvailable
        self.runtimeRunning = runtimeRunning
        self.lastKnown = lastKnown
        self.buildInfo = buildInfo
        self.paths = paths
        self.clock = clock
        self.hostProbe = hostProbe
    }
}

/// A registered health check.
public protocol HealthCheck: Sendable {
    var id: HealthCheckID { get }
    var group: HealthGroup { get }
    var requirement: HealthRequirement { get }
    var cost: HealthCost { get }
    var fix: (any HealthFix)? { get }
    var title: LocalizedText { get }
    func run(_ context: HealthContext) async -> HealthResult
}

public extension HealthCheck {
    var fix: (any HealthFix)? { nil }

    var title: LocalizedText {
        LocalizedText(key: id, fallback: id)
    }
}

/// A duplicate identifier passed to a health check registry.
public enum HealthCheckRegistryError: Error, Equatable, Sendable {
    case duplicateCheck(id: HealthCheckID)
}

/// Owns health checks, enforces their budgets, and preserves deterministic report ordering.
public actor HealthCheckRegistry {
    public static let maximumConcurrentChecks = 8

    private let timeouts: HealthCheckTimeouts
    private let permits: HealthCheckPermitPool
    private var checks: [any HealthCheck]
    private var registeredIDs: Set<HealthCheckID>

    public init(
        checks: [any HealthCheck] = [],
        timeouts: HealthCheckTimeouts = .standard,
        maximumConcurrentChecks: Int = 8
    ) {
        let limit = min(max(1, maximumConcurrentChecks), Self.maximumConcurrentChecks)
        self.timeouts = timeouts
        permits = HealthCheckPermitPool(limit: limit)
        self.checks = []
        registeredIDs = []
        for check in checks {
            let inserted = registeredIDs.insert(check.id).inserted
            precondition(inserted, "Duplicate health check ID: \(check.id)")
            self.checks.append(check)
        }
    }

    /// Adds a check. IDs are unique within a registry.
    public func register(_ check: any HealthCheck) throws {
        guard registeredIDs.insert(check.id).inserted else {
            throw HealthCheckRegistryError.duplicateCheck(id: check.id)
        }
        checks.append(check)
    }

    /// The currently registered check IDs, in registration order.
    public func checkIDs() -> [HealthCheckID] {
        checks.map(\.id)
    }

    /// Runs checks and returns results ordered by group, then registration order.
    public func run(
        deep: Bool = false,
        context: HealthContext
    ) async -> [HealthResult] {
        let registered = checks
        let timeoutPolicy = timeouts
        let permitPool = permits
        return await withTaskGroup(of: (Int, HealthResult).self, returning: [HealthResult].self) { group in
            for (index, check) in registered.enumerated() {
                group.addTask {
                    if let skipped = Self.skipResult(for: check, deep: deep, context: context) {
                        return (index, skipped)
                    }

                    let timeout = timeoutPolicy.timeout(for: check.cost)
                    let continuousClock = ContinuousClock()
                    let deadline = continuousClock.now.advanced(by: timeout)
                    guard await permitPool.acquire(until: deadline) else {
                        if Task.isCancelled {
                            return (index, Self.cancelledResult(for: check, context: context))
                        }
                        return (index, Self.timeoutResult(for: check, context: context))
                    }
                    guard !Task.isCancelled else {
                        await permitPool.release()
                        return (index, Self.cancelledResult(for: check, context: context))
                    }
                    let remaining = continuousClock.now.duration(to: deadline)
                    guard remaining > .zero else {
                        await permitPool.release()
                        return (index, Self.timeoutResult(for: check, context: context))
                    }
                    let outcome = await Self.run(
                        check,
                        context: context,
                        timeout: remaining,
                        permits: permitPool
                    )
                    let result: HealthResult
                    switch outcome {
                    case let .completed(value):
                        result = Self.normalized(value, for: check, measuredAt: context.clock.now)
                    case .timedOut:
                        result = Self.timeoutResult(for: check, context: context)
                    case .cancelled:
                        result = Self.cancelledResult(for: check, context: context)
                    }
                    return (index, result)
                }
            }

            var indexedResults: [(Int, HealthResult)] = []
            for await result in group {
                indexedResults.append(result)
            }

            guard !Task.isCancelled else {
                return []
            }

            let groupOrder = Dictionary(
                uniqueKeysWithValues: HealthGroup.allCases.enumerated().map { ($0.element, $0.offset) }
            )
            return indexedResults
                .sorted { left, right in
                    let leftGroup = groupOrder[left.1.group, default: .max]
                    let rightGroup = groupOrder[right.1.group, default: .max]
                    return leftGroup == rightGroup ? left.0 < right.0 : leftGroup < rightGroup
                }
                .map(\.1)
        }
    }

    private static func skipResult(
        for check: any HealthCheck,
        deep: Bool,
        context: HealthContext
    ) -> HealthResult? {
        let detail: String
        switch check.requirement {
        case .host:
            break
        case .daemon where !context.daemonAvailable:
            detail = "Background service not running"
            return skippedResult(check, detail: detail, context: context)
        case .runningRuntime where !context.daemonAvailable:
            detail = "Background service not running"
            return skippedResult(check, detail: detail, context: context)
        case .runningRuntime where !context.runtimeRunning:
            return skippedResult(
                check,
                detail: "Android is not running",
                context: context
            )
        case .daemon, .runningRuntime:
            break
        }

        if check.cost == .deep && !deep {
            return skippedResult(
                check,
                detail: "Run with --deep to include this check.",
                context: context
            )
        }

        return nil
    }

    private static func skippedResult(
        _ check: any HealthCheck,
        detail: String,
        context: HealthContext
    ) -> HealthResult {
        HealthResult(
            id: check.id,
            group: check.group,
            state: .skipped,
            title: check.title,
            detail: detail,
            error: nil,
            fixAvailable: false,
            lastKnown: context.lastKnown[check.id],
            measuredAt: context.clock.now
        )
    }

    private static func normalized(
        _ result: HealthResult,
        for check: any HealthCheck,
        measuredAt: Date
    ) -> HealthResult {
        let error: ErrorInfo?
        switch result.state {
        case .warning, .failure:
            error = result.error
        case .pass, .info, .skipped:
            error = nil
        }
        return HealthResult(
            id: check.id,
            group: check.group,
            state: result.state,
            title: result.title,
            detail: result.detail,
            error: error,
            fixAvailable: check.fix != nil,
            lastKnown: result.state == .skipped ? result.lastKnown : nil,
            measuredAt: measuredAt
        )
    }

    private static func timeoutResult(
        for check: any HealthCheck,
        context: HealthContext
    ) -> HealthResult {
        HealthResult(
            id: check.id,
            group: check.group,
            state: .warning,
            title: check.title,
            detail: "check timed out",
            error: nil,
            fixAvailable: check.fix != nil,
            lastKnown: nil,
            measuredAt: context.clock.now
        )
    }

    private static func cancelledResult(
        for check: any HealthCheck,
        context: HealthContext
    ) -> HealthResult {
        HealthResult(
            id: check.id,
            group: check.group,
            state: .skipped,
            title: check.title,
            detail: "check cancelled",
            error: nil,
            fixAvailable: false,
            lastKnown: context.lastKnown[check.id],
            measuredAt: context.clock.now
        )
    }

    private static func run(
        _ check: any HealthCheck,
        context: HealthContext,
        timeout: Duration,
        permits: HealthCheckPermitPool
    ) async -> HealthCheckOutcome {
        let gate = HealthCheckCompletionGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let worker = Task {
                    let result = await check.run(context)
                    await gate.complete(.completed(result))
                    await permits.release()
                }
                let timer = Task {
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }
                    await gate.complete(.timedOut)
                }
                Task {
                    await gate.install(
                        continuation: continuation,
                        worker: worker,
                        timer: timer
                    )
                }
            }
        } onCancel: {
            Task {
                await gate.complete(.cancelled)
            }
        }
    }
}

private actor HealthCheckPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        available = limit
    }

    func acquire(until deadline: ContinuousClock.Instant) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        if available > 0 {
            available -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let remaining = ContinuousClock().now.duration(to: deadline)
                guard remaining > .zero else {
                    continuation.resume(returning: false)
                    return
                }
                let timer = Task {
                    do {
                        try await ContinuousClock().sleep(for: remaining)
                    } catch {
                        return
                    }
                    self.resolveWaiter(id, acquired: false)
                }
                waiters.append(Waiter(id: id, continuation: continuation, timer: timer))
            }
        } onCancel: {
            Task {
                await self.resolveWaiter(id, acquired: false)
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.timer.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    private func resolveWaiter(_ id: UUID, acquired: Bool) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.timer.cancel()
        waiter.continuation.resume(returning: acquired)
    }
}

private actor HealthCheckCompletionGate {
    private var outcome: HealthCheckOutcome?
    private var continuation: CheckedContinuation<HealthCheckOutcome, Never>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func install(
        continuation: CheckedContinuation<HealthCheckOutcome, Never>,
        worker: Task<Void, Never>,
        timer: Task<Void, Never>
    ) {
        self.worker = worker
        self.timer = timer
        if let outcome {
            continuation.resume(returning: outcome)
            self.continuation = nil
            cancelLoser(for: outcome)
        } else {
            self.continuation = continuation
        }
    }

    func complete(_ outcome: HealthCheckOutcome) {
        guard self.outcome == nil else {
            return
        }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
        cancelLoser(for: outcome)
    }

    private func cancelLoser(for outcome: HealthCheckOutcome) {
        switch outcome {
        case .completed:
            timer?.cancel()
        case .timedOut:
            worker?.cancel()
        case .cancelled:
            worker?.cancel()
            timer?.cancel()
        }
        worker = nil
        timer = nil
    }
}
