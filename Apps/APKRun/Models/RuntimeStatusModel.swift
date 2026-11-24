import Foundation
import RuntimeAPI
import RuntimeClient

/// The app's view of apkrund's state (host-ui.md §2.2). Fed by `runtimeStatus`
/// and the `runtime` event topic; views never call XPC directly.
@MainActor
@Observable
final class RuntimeStatusModel {
    private(set) var status: RuntimeHostStatus?
    private(set) var lastError: RuntimeWireError?

    private let makeClient: @Sendable () throws -> RuntimeControlClient
    private var client: RuntimeControlClient?
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// Every subscription failure costs one status poll before the next try,
    /// so a missing or unauthorized daemon does not spin the reconnect loop.
    private static let pollInterval = Duration.seconds(2)

    init(
        makeClient: @escaping @Sendable () throws -> RuntimeControlClient = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        self.makeClient = makeClient
    }

    var provisioning: WireProvisioningState {
        status?.provisioning ?? .notStarted
    }

    var setupComplete: Bool {
        provisioning == .complete
    }

    /// Starts the status loop: an immediate `runtimeStatus`, then a refresh on
    /// every `runtime` topic event and at least every 2 seconds.
    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// One `runtimeStatus` round trip.
    func refresh() async {
        do {
            let control = try controlClient()
            status = try await control.runtimeStatus()
            lastError = nil
        } catch {
            lastError = Self.wireError(for: error)
        }
    }

    /// Sends a `setup` request and returns the provisioning operation handle.
    @discardableResult
    func beginSetup(request: SetupRequest = SetupRequest()) async throws -> OperationHandle {
        do {
            let handle = try await controlClient().setup(request, operationID: RuntimeAPI.OperationID())
            return handle
        } catch {
            let wire = Self.wireError(for: error)
            lastError = wire
            throw wire
        }
    }

    /// Cancels the running provisioning operation, if any.
    func cancelSetup() async {
        guard let client else { return }
        if let operations = try? await client.listOperations() {
            for operation in operations where operation.kind == .setup && operation.result == nil {
                _ = try? await client.cancelOperation(operation.operationID)
            }
        }
    }

    private func controlClient() throws -> RuntimeControlClient {
        if let client { return client }
        let created = try makeClient()
        client = created
        return created
    }

    private func runLoop() async {
        await refresh()
        while !Task.isCancelled {
            do {
                let stream = try await controlClient().subscribe(to: .runtime)
                for await _ in stream {
                    if Task.isCancelled { return }
                    scheduleRefresh()
                }
            } catch {
                lastError = Self.wireError(for: error)
            }
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { return }
            await refresh()
        }
    }

    /// Collapses bursts of events into a single status refresh.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            defer { self?.refreshTask = nil }
            await self?.refresh()
        }
    }

    private static func wireError(for error: any Error) -> RuntimeWireError {
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
