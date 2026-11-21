import Foundation
import RuntimeAPI
import RuntimeClient

/// Base class for the home models (host-ui.md §5.2): one `makeService` seam,
/// a topic subscription loop with a poll fallback, and a shared
/// `serviceUnreachable` flag that drives the **Restart Service** banner.
@MainActor
@Observable
class TopicPollingModel {
    /// True while apkrund is unreachable; the views show the banner.
    private(set) var serviceUnreachable = false
    /// The last typed failure, for diagnostics detail.
    private(set) var lastError: RuntimeWireError?

    private let topics: [EventTopic]
    /// Reload on a timer even while subscriptions stay open — for topics the
    /// daemon never publishes (§5.1 Updates).
    private let refreshInterval: Duration?
    private let makeService: @Sendable () throws -> any RuntimeService
    private var service: (any RuntimeService)?
    private var loopTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    /// Every subscription failure costs one reload before the next try, so a
    /// missing or unauthorized daemon does not spin the reconnect loop.
    static let pollInterval = Duration.seconds(2)

    init(
        topics: [EventTopic],
        refreshInterval: Duration? = nil,
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        self.topics = topics
        self.refreshInterval = refreshInterval
        self.makeService = makeService
    }

    /// Starts the loop: an immediate reload, then a reload on every topic event
    /// and at least every `pollInterval` while the service is down.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        reloadTask?.cancel()
        reloadTask = nil
    }

    /// The service instance, creating it through the seam on first use.
    func requireService() throws -> any RuntimeService {
        if let service { return service }
        let created = try makeService()
        service = created
        return created
    }

    /// Drops the cached service so the next reload reconnects.
    func invalidateService() {
        service = nil
    }

    /// One data round trip; subclasses override. Must set
    /// `serviceUnreachable` through `markReachable`/`markUnreachable`.
    func reload() async {}

    /// Collapses bursts of events into a single reload.
    func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            defer { self?.reloadTask = nil }
            await self?.reload()
        }
    }

    func markReachable() {
        serviceUnreachable = false
        lastError = nil
    }

    func markUnreachable(_ error: any Error) {
        serviceUnreachable = true
        lastError = Self.wireError(for: error)
    }

    private func runLoop() async {
        await reload()
        while !Task.isCancelled {
            if let service = try? requireService() {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        if let refreshInterval {
                            group.addTask { [weak self] in
                                while !Task.isCancelled {
                                    try? await Task.sleep(for: refreshInterval)
                                    if Task.isCancelled { return }
                                    await self?.scheduleReload()
                                }
                            }
                        }
                        for topic in topics {
                            group.addTask { [weak self] in
                                let stream = try await service.subscribe(to: topic)
                                for await _ in stream {
                                    if Task.isCancelled { return }
                                    await self?.scheduleReload()
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                } catch {
                    markUnreachable(error)
                }
            }
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { return }
            await reload()
        }
    }

    static func wireError(for error: any Error) -> RuntimeWireError {
        if let wire = error as? RuntimeWireError { return wire }
        if let clientError = error as? RuntimeControlClientError,
            case .remoteFailure(let code, let message, _) = clientError
        {
            return RuntimeWireError(domain: "runtime", code: code, message: message)
        }
        return .runtime(
            "serviceUnavailable",
            message: "APKRun's background service isn't running.",
            remediation: "Open APKRun once, or restart its background service."
        )
    }
}
