import Combine
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

@MainActor
protocol MenuBarRuntimeService {
    func runtimeStatus() async throws -> RuntimeHostStatus
    func listSessions() async throws -> [RuntimeSessionSnapshot]
    func listPackages() async throws -> RuntimePackageListResult
    func startRuntime() async throws -> RuntimeHostStatus
    func stopRuntime() async throws -> RuntimeHostStatus
    func launch(packageID: RuntimePackageID) async throws
    func subscribe(to topic: EventTopic) async throws -> AsyncStream<EventEnvelope>
}

@MainActor
private final class RuntimeClientMenuBarService: MenuBarRuntimeService {
    private let client: RuntimeControlClient

    init(client: RuntimeControlClient) {
        self.client = client
    }

    func runtimeStatus() async throws -> RuntimeHostStatus {
        try await client.runtimeStatus()
    }

    func listSessions() async throws -> [RuntimeSessionSnapshot] {
        try await client.listSessions()
    }

    func listPackages() async throws -> RuntimePackageListResult {
        try await client.listPackages(filter: .all)
    }

    func startRuntime() async throws -> RuntimeHostStatus {
        try await client.startRuntime()
    }

    func stopRuntime() async throws -> RuntimeHostStatus {
        try await client.stopRuntime()
    }

    func launch(packageID: RuntimePackageID) async throws {
        _ = try await client.launch(RuntimeLaunchRequest(packageID: packageID))
    }

    func subscribe(to topic: EventTopic) async throws -> AsyncStream<EventEnvelope> {
        try await client.subscribe(to: topic)
    }
}

@MainActor
final class MenuBarModel: ObservableObject {
    @Published private(set) var snapshot = MenuBarSnapshot(runtimeStatus: nil)
    @Published private(set) var isConnected = false
    @Published private(set) var isPerformingAction = false
    @Published private(set) var errorMessage: String?
    @Published var isShowingStopConfirmation = false

    private static let observedTopics: [EventTopic] = [
        .runtime, .sessions, .updates, .health,
    ]

    private let service: (any MenuBarRuntimeService)?
    private let snapshotRetryInitialDelay: Duration
    private let subscriptionRetryInitialDelay: Duration
    private var hasStarted = false
    private var listenerGeneration: UInt64 = 0
    private var reloadIsRunning = false
    private var reloadWasRequested = false
    private var topicsRequiringSnapshotAfterReconnect: Set<EventTopic> = []
    private var snapshotRetryTask: Task<Void, Never>?
    private var subscriptionRetryTasks: [EventTopic: Task<Void, Never>] = [:]
    private var eventTasks: [EventTopic: Task<Void, Never>] = [:]

    init(
        service: (any MenuBarRuntimeService)? = nil,
        snapshotRetryInitialDelay: Duration = .seconds(1),
        subscriptionRetryInitialDelay: Duration = .seconds(1)
    ) {
        self.snapshotRetryInitialDelay = snapshotRetryInitialDelay
        self.subscriptionRetryInitialDelay = subscriptionRetryInitialDelay
        if let service {
            self.service = service
        } else if let client = try? RuntimeControlClient(clientKind: .menuBar) {
            self.service = RuntimeClientMenuBarService(client: client)
        } else {
            self.service = nil
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        listenerGeneration &+= 1

        for topic in Self.observedTopics {
            listenForEvents(on: topic, generation: listenerGeneration)
        }
        await reload()
    }

    func reload() async {
        guard let service else {
            isConnected = false
            snapshot = MenuBarSnapshot(runtimeStatus: nil)
            return
        }

        if reloadIsRunning {
            reloadWasRequested = true
            return
        }

        reloadIsRunning = true
        repeat {
            reloadWasRequested = false
            await reloadSnapshot(using: service)
        } while reloadWasRequested
        reloadIsRunning = false
    }

    func requestStopAndroid() async {
        guard let service, !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil
        defer { isPerformingAction = false }
        let actionLogger = makeActionLogger()

        do {
            let sessions = try await service.listSessions()
            isPerformingAction = false
            if sessions.contains(where: { $0.phase != .ended }) {
                isShowingStopConfirmation = true
            } else {
                await stopAndroid()
            }
        } catch {
            logActionFailure(error, using: actionLogger)
            errorMessage = Self.actionFailureMessage
        }
    }

    func confirmStopAndroid() async {
        isShowingStopConfirmation = false
        await stopAndroid()
    }

    func startAndroid() async {
        guard let service, !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil
        defer { isPerformingAction = false }
        let actionLogger = makeActionLogger()

        do {
            _ = try await service.startRuntime()
            actionLogger.notice("Android start requested from the menu bar")
            await reload()
        } catch {
            logActionFailure(error, using: actionLogger)
            await reload()
            errorMessage = Self.actionFailureMessage
        }
    }

    func launch(_ session: MenuBarSession) async {
        guard let service, !isPerformingAction,
            let packageID = RuntimePackageID(rawValue: session.packageID)
        else { return }
        isPerformingAction = true
        errorMessage = nil
        defer { isPerformingAction = false }
        let actionLogger = makeActionLogger(packageID: packageID.rawValue)

        do {
            try await service.launch(packageID: packageID)
            actionLogger.notice("Android app launch requested from the menu bar")
            await reload()
        } catch {
            logActionFailure(error, using: actionLogger)
            await reload()
            errorMessage = Self.actionFailureMessage
        }
    }

    func stopListening() {
        listenerGeneration &+= 1
        for task in subscriptionRetryTasks.values {
            task.cancel()
        }
        for task in eventTasks.values {
            task.cancel()
        }
        subscriptionRetryTasks.removeAll()
        eventTasks.removeAll()
        snapshotRetryTask?.cancel()
        snapshotRetryTask = nil
        topicsRequiringSnapshotAfterReconnect.removeAll()
        hasStarted = false
    }

    private func stopAndroid() async {
        guard let service, !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil
        defer { isPerformingAction = false }
        let actionLogger = makeActionLogger()

        do {
            _ = try await service.stopRuntime()
            actionLogger.notice("Android stop requested from the menu bar")
            await reload()
        } catch {
            logActionFailure(error, using: actionLogger)
            await reload()
            errorMessage = Self.actionFailureMessage
        }
    }

    private func reloadSnapshot(using service: any MenuBarRuntimeService) async {
        do {
            let runtimeStatus = try await service.runtimeStatus()
            let sessions = try await service.listSessions()
            let packages = try await service.listPackages()
            let displayNames = Dictionary(
                uniqueKeysWithValues: packages.packages.map {
                    ($0.packageID.rawValue, $0.displayName)
                }
            )
            var runningSessions: [MenuBarSession] = []
            for session in sessions where session.phase == .running {
                let packageID = session.packageID.rawValue
                let displayName = displayNames[packageID] ?? packageID
                runningSessions.append(
                    MenuBarSession(
                        id: packageID,
                        packageID: packageID,
                        displayName: displayName
                    )
                )
            }
            runningSessions.sort { lhs, rhs in
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return comparison == .orderedSame
                    ? lhs.packageID < rhs.packageID
                    : comparison == .orderedAscending
            }

            snapshot = MenuBarSnapshot(
                runtimeStatus: runtimeStatus,
                sessions: runningSessions,
                hasOpenSessions: sessions.contains { $0.phase != .ended },
                availableUpdates: nil,
                liveHealthNeedsAttention: nil,
                developerModeEnabled: nil
            )
            isConnected = true
            errorMessage = nil
            snapshotRetryTask?.cancel()
            snapshotRetryTask = nil
        } catch {
            snapshot = MenuBarSnapshot(runtimeStatus: nil)
            isConnected = false
            scheduleSnapshotRetry()
        }
    }

    private func scheduleSnapshotRetry() {
        guard hasStarted, snapshotRetryTask == nil else { return }
        let generation = listenerGeneration
        snapshotRetryTask = Task { [weak self] in
            guard let self else { return }
            var retryDelay = self.snapshotRetryInitialDelay
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: retryDelay)
                } catch {
                    return
                }
                guard self.hasStarted, self.listenerGeneration == generation else { return }
                await self.reload()
                guard
                    self.hasStarted, self.listenerGeneration == generation,
                    !self.isConnected, !Task.isCancelled
                else { return }
                retryDelay = min(retryDelay * 2, .seconds(30))
            }
        }
    }

    private func listenForEvents(on topic: EventTopic, generation: UInt64) {
        guard service != nil,
            hasStarted,
            listenerGeneration == generation,
            subscriptionRetryTasks[topic] == nil,
            eventTasks[topic] == nil
        else { return }

        subscriptionRetryTasks[topic] = Task { [weak self] in
            var retryDelay: Duration = .seconds(1)
            while !Task.isCancelled {
                guard let self, let service = self.service else { return }
                do {
                    let stream = try await service.subscribe(to: topic)
                    guard
                        !Task.isCancelled, self.hasStarted,
                        self.listenerGeneration == generation
                    else { return }
                    self.subscriptionRetryTasks[topic] = nil
                    retryDelay = .seconds(1)
                    let requiresSnapshot = self.topicsRequiringSnapshotAfterReconnect.remove(topic) != nil
                    if requiresSnapshot || !self.isConnected {
                        await self.reload()
                    }
                    guard
                        !Task.isCancelled, self.hasStarted,
                        self.listenerGeneration == generation
                    else { return }
                    self.consume(stream, for: topic, generation: generation)
                    return
                } catch {
                    do {
                        try await Task.sleep(for: retryDelay)
                    } catch {
                        return
                    }
                    retryDelay = min(retryDelay * 2, .seconds(30))
                }
            }
        }
    }

    private func consume(
        _ stream: AsyncStream<EventEnvelope>,
        for topic: EventTopic,
        generation: UInt64
    ) {
        eventTasks[topic] = Task { [weak self] in
            for await _ in stream {
                guard
                    !Task.isCancelled, let self,
                    self.hasStarted, self.listenerGeneration == generation
                else { break }
                await self.reload()
            }
            guard
                !Task.isCancelled, let self,
                self.hasStarted, self.listenerGeneration == generation
            else { return }
            self.eventTasks[topic] = nil
            self.isConnected = false
            self.snapshot = MenuBarSnapshot(runtimeStatus: nil)
            self.topicsRequiringSnapshotAfterReconnect.insert(topic)
            do {
                try await Task.sleep(for: self.subscriptionRetryInitialDelay)
            } catch {
                return
            }
            guard self.hasStarted, self.listenerGeneration == generation else { return }
            self.listenForEvents(on: topic, generation: generation)
        }
    }

    private static let actionFailureMessage =
        String(localized: "APKRun couldn't complete this action. Open APKRun for details.")

    private func makeActionLogger(packageID: String? = nil) -> APKLogger {
        APKLogger(
            category: MenuBarLogCategory.status,
            context: LogContext(
                operationID: DiagnosticsCore.OperationID().rawValue,
                packageID: packageID
            )
        )
    }

    private func logActionFailure(_ error: any Error, using logger: APKLogger) {
        let errorCode: String
        if let clientError = error as? RuntimeControlClientError {
            switch clientError {
            case .remoteFailure(let code, _):
                errorCode = code
            case .transportFailure, .requestTimedOut, .endpointRejected(.hostShuttingDown):
                errorCode = "runtime.serviceUnavailable"
            default:
                errorCode = "runtime.internal"
            }
        } else {
            errorCode = "runtime.internal"
        }
        logger.error("Menu bar action failed", errorCode: errorCode)
    }
}
