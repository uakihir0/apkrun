@preconcurrency import Foundation
import RuntimeAPI
import Security

/// Errors returned by the first RuntimeAPI control client.
public enum RuntimeControlClientError: Error, Equatable, Sendable {
    /// The process has no supported APKRun build identity or signing identity.
    case invalidClientIdentity
    /// A reply could not be decoded or was internally inconsistent.
    case malformedReply
    /// The daemon and client use incompatible RuntimeAPI versions.
    case apiVersionMismatch(client: APIVersion, server: APIVersion)
    /// The broker refused to issue a control endpoint.
    case endpointRejected(RuntimeEndpointRejection)
    /// The broker granted access but did not return an endpoint.
    case endpointMissing
    /// An XPC remote object did not implement its declared interface.
    case invalidRemoteProxy
    /// The local broker interface could not be configured to decode its endpoint reply safely.
    case invalidXPCInterface
    /// An XPC operation failed.
    case transportFailure(domain: String, code: Int)
    /// The daemon did not reply before the operation deadline plus the client grace period.
    case requestTimedOut(operation: String)
    /// A side-effecting request was sent, but the client cannot determine whether it completed.
    case operationResultUnknown(operation: String)
    /// The caller cancelled while waiting for a state-changing operation.
    case requestCancelled(operation: String)
    /// The control endpoint returned a catalog-backed error.
    case remoteFailure(code: String, message: String)
    /// JSON encoding failed.
    case encodingFailure
}

extension RuntimeControlClientError: LocalizedError {
    /// A user-readable explanation of the client error.
    public var errorDescription: String? {
        switch self {
        case .invalidClientIdentity:
            "This APKRun client cannot verify the runtime daemon's signing identity."
        case .malformedReply:
            "The runtime daemon returned an invalid reply."
        case .apiVersionMismatch:
            "The runtime daemon and this APKRun client use incompatible API versions. Update APKRun."
        case .endpointRejected(.hostShuttingDown):
            "APKRun's background service is stopping. Try again in a moment."
        case .endpointRejected:
            "The runtime daemon refused this client's control endpoint request."
        case .endpointMissing:
            "The runtime daemon granted control access without returning its endpoint."
        case .invalidRemoteProxy:
            "The runtime daemon did not provide the expected XPC interface."
        case .invalidXPCInterface:
            "This APKRun client could not configure its runtime connection safely."
        case .transportFailure:
            "The runtime daemon could not be reached."
        case .requestTimedOut:
            "APKRun's background service didn't answer in time."
        case .operationResultUnknown:
            "APKRun couldn't confirm whether the operation completed."
        case .requestCancelled:
            "The operation was cancelled."
        case .remoteFailure(_, let message):
            message
        case .encodingFailure:
            "The runtime request could not be encoded."
        }
    }
}

/// The first RuntimeAPI control client. It authenticates the daemon, obtains an anonymous control
/// endpoint through the broker, then reuses that endpoint for status, start, and stop requests.
public actor RuntimeControlClient {
    private static let maximumEndpointAdmissionRetries = 22

    private let clientConfiguration: RuntimeControlClientConfiguration
    private let connectionFactory: any RuntimeXPCConnectionFactory
    private let eventStreamHub: RuntimeEventStreamHub
    private let eventSink: RuntimeEventSinkReceiver
    private var openedControl: OpenedControlConnection?
    private var openingControl: Task<OpenedControlConnection, any Error>?
    private var remoteEventTopics: [EventTopic] = []
    private var eventReconnectID: UUID?
    private var eventReconnectTask: Task<Void, Never>?

    /// Creates a client for the current signed APKRun process.
    ///
    /// The expected daemon identifier and signing requirement are derived from the client bundle.
    /// The requirement is applied to both the broker and anonymous control connections before
    /// either connection is resumed.
    public init(
        clientKind: RuntimeClientKind,
        claimedIdentity: String? = nil
    ) throws(RuntimeControlClientError) {
        clientConfiguration = try RuntimeControlClientConfiguration.current(
            clientKind: clientKind,
            claimedIdentity: claimedIdentity
        )
        connectionFactory = SystemRuntimeXPCConnectionFactory()
        let eventStreamHub = RuntimeEventStreamHub()
        self.eventStreamHub = eventStreamHub
        eventSink = RuntimeEventSinkReceiver(streamHub: eventStreamHub)
    }

    init(
        configuration: RuntimeControlClientConfiguration,
        connectionFactory: any RuntimeXPCConnectionFactory
    ) {
        clientConfiguration = configuration
        self.connectionFactory = connectionFactory
        let eventStreamHub = RuntimeEventStreamHub()
        self.eventStreamHub = eventStreamHub
        eventSink = RuntimeEventSinkReceiver(streamHub: eventStreamHub)
    }

    /// Completes broker hello and control-endpoint authentication, returning the daemon facts.
    @discardableResult
    public func connect() async throws(RuntimeControlClientError) -> RuntimeHelloReply {
        try await ensureControl().hello
    }

    /// Returns a daemon and Android runtime status snapshot.
    public func runtimeStatus() async throws(RuntimeControlClientError) -> RuntimeHostStatus {
        let opened = try await ensureControl()
        do {
            let request = RuntimeStatusRequest(header: makeHeader())
            let data = try Self.encode(request)
            return try Self.decodeControlReply(from: await opened.channel.runtimeStatus(data))
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Returns runtime sizing and any requested diagnostic details.
    public func runtimeInfo(
        _ request: RuntimeInfoRequest = RuntimeInfoRequest()
    ) async throws(RuntimeControlClientError) -> RuntimeInfo {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeInfoControlRequest(header: makeHeader(), request: request)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.runtimeInfo(data)
            return try Self.decodeRuntimeInfoReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Lists the currently open app sessions.
    public func listSessions() async throws(RuntimeControlClientError) -> [SessionSummary] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeListSessionsControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.listSessions(data)
            return try Self.decodeListSessionsReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Returns the resolved global runtime configuration.
    public func configuration() async throws(RuntimeControlClientError) -> ConfigurationSnapshot {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeConfigurationControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.configuration(data)
            return try Self.decodeConfigurationReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Applies a global configuration merge patch and returns the resolved snapshot.
    public func updateConfiguration(
        _ patch: ConfigurationPatch
    ) async throws(RuntimeControlClientError) -> ConfigurationSnapshot {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeUpdateConfigurationControlRequest(
                header: makeHeader(),
                request: patch
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.updateConfiguration(data)
            return try Self.decodeUpdateConfigurationReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Starts Android and waits until the daemon reports it ready.
    public func startRuntime() async throws(RuntimeControlClientError) -> RuntimeHostStatus {
        let opened = try await ensureControl()
        do {
            let request = StartRuntimeRequest(header: makeHeader())
            let data = try Self.encode(request)
            return try Self.decodeControlReply(from: await opened.channel.startRuntime(data))
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Stops Android while leaving the daemon available for another request.
    public func stopRuntime() async throws(RuntimeControlClientError) -> RuntimeHostStatus {
        let opened = try await ensureControl()
        do {
            let request = StopRuntimeRequest(header: makeHeader())
            let data = try Self.encode(request)
            return try Self.decodeControlReply(from: await opened.channel.stopRuntime(data))
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Restarts Android with one request so the client cannot be interrupted between stop and start.
    ///
    /// A transport failure is returned to the caller without replaying this state-changing request.
    public func restartRuntime() async throws(RuntimeControlClientError) -> RuntimeHostStatus {
        let opened = try await ensureControl()
        do {
            let request = RestartRuntimeRequest(header: makeHeader())
            let data = try Self.encode(request)
            let run: @Sendable () async throws(RuntimeControlClientError) -> Data = {
                try await opened.channel.restartRuntime(data)
            }
            let response = try await Self.withTimeout(
                clientConfiguration.restartRequestTimeout,
                operation: "runtimeRestart",
                run: run
            )
            return try Self.decodeControlReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Clears the automatic boot-loop guard without deleting Android data.
    ///
    /// A transport failure is returned to the caller without replaying this state-changing request.
    public func resetRuntime() async throws(RuntimeControlClientError) -> RuntimeHostStatus {
        let opened = try await ensureControl()
        do {
            let request = RuntimeResetControlRequest(header: makeHeader())
            let data = try Self.encode(request)
            return try Self.decodeControlReply(from: await opened.channel.resetRuntime(data))
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Launches the requested package once and returns the session result.
    ///
    /// A transport failure is returned to the caller without replaying this side-effecting request.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeControlClientError)
        -> RuntimeLaunchResult
    {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeLaunchControlRequest(
                header: makeHeader(),
                packageID: request.packageID
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.launch(data)
            return try Self.decodeLaunchReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Terminates the requested package once and returns the termination result.
    ///
    /// A transport failure is returned to the caller without replaying this side-effecting request.
    public func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeControlClientError)
        -> RuntimeTerminateResult
    {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeTerminateControlRequest(
                header: makeHeader(),
                packageID: request.packageID
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.terminate(data)
            return try Self.decodeTerminateReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Lists managed packages or the Android inventory already known to the daemon.
    public func listPackages(
        filter: RuntimePackageFilter = .managed
    ) async throws(RuntimeControlClientError) -> RuntimePackageListResult {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeListPackagesControlRequest(
                header: makeHeader(),
                filter: filter
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.listPackages(data)
            return try Self.decodePackageListReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Returns the daemon's stored details for one package.
    public func packageInfo(
        packageID: RuntimePackageID
    ) async throws(RuntimeControlClientError) -> RuntimePackageDetails {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimePackageInfoControlRequest(
                header: makeHeader(),
                packageID: packageID
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.packageInfo(data)
            return try Self.decodePackageInfoReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Copies and inspects package files without starting Android.
    ///
    /// The file handles are passed once to the daemon. A transport failure is not replayed because
    /// the daemon may already have staged the files.
    public func importPackage(
        _ request: RuntimeImportPackageRequest,
        files: [FileHandle]
    ) async throws(RuntimeControlClientError) -> RuntimeImportPreview {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeImportPackageControlRequest(
                header: makeHeader(),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.importPackage(data, files: files)
            return try Self.decodeImportPackageReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Installs a package import previously inspected by `importPackage`.
    ///
    /// The daemon may have installed the package even when the client loses the reply, so this
    /// state-changing request is sent once and never replayed automatically.
    public func installImported(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeControlClientError) -> RuntimePackageSummary {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeInstallImportedControlRequest(
                header: makeHeader(),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.installImported(data)
            return try Self.decodeInstallImportedReply(from: response)
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            switch clientError {
            case .transportFailure, .requestTimedOut, .requestCancelled, .malformedReply:
                throw .operationResultUnknown(operation: "installImported")
            default:
                throw clientError
            }
        }
    }

    /// Starts installation and returns a handle that can be polled or cancelled.
    ///
    /// The supplied operation ID makes an ambiguous begin reply recoverable. If the begin request
    /// may have reached the daemon but its reply is lost or unusable, the client reconnects and
    /// checks that ID once; it never resends the begin request.
    public func beginInstallImported(
        _ request: RuntimeInstallImportedRequest,
        operationID: OperationID
    ) async throws(RuntimeControlClientError) -> OperationHandle {
        let requestFingerprint: String
        do {
            requestFingerprint = try RuntimeOperationRequestFingerprint.make(for: request)
        } catch {
            throw .encodingFailure
        }
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeBeginInstallImportedControlRequest(
                header: APIRequestHeader(
                    operationID: operationID.rawValue,
                    clientKind: clientConfiguration.clientKind
                ),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.beginInstallImported(data)
            let handle = try Self.decodeBeginInstallImportedReply(from: response)
            guard handle.operationID == operationID, handle.kind == .install else {
                throw RuntimeControlClientError.malformedReply
            }
            return handle
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            switch clientError {
            case .transportFailure, .requestTimedOut, .requestCancelled, .malformedReply, .invalidRemoteProxy:
                do {
                    let snapshot = try await operationStatus(operationID)
                    guard snapshot.operationID == operationID,
                        snapshot.kind == .install,
                        snapshot.requestFingerprint == requestFingerprint
                    else {
                        throw RuntimeControlClientError.operationResultUnknown(
                            operation: "beginInstallImported"
                        )
                    }
                    return OperationHandle(
                        operationID: snapshot.operationID,
                        parent: snapshot.parent,
                        kind: snapshot.kind
                    )
                } catch {
                    throw RuntimeControlClientError.operationResultUnknown(
                        operation: "beginInstallImported"
                    )
                }
            default:
                throw clientError
            }
        }
    }

    /// Starts uninstall or forget and reconciles an ambiguous reply by the requested operation ID.
    public func beginUninstallPackage(
        _ request: RuntimeUninstallPackageRequest,
        operationID: OperationID
    ) async throws(RuntimeControlClientError) -> OperationHandle {
        let requestFingerprint: String
        do {
            requestFingerprint = try RuntimeOperationRequestFingerprint.make(for: request)
        } catch {
            throw .encodingFailure
        }
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeBeginUninstallPackageControlRequest(
                header: APIRequestHeader(
                    operationID: operationID.rawValue,
                    clientKind: clientConfiguration.clientKind
                ),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.beginUninstallPackage(data)
            let handle = try Self.decodeBeginUninstallPackageReply(from: response)
            guard handle.operationID == operationID, handle.kind == .uninstall else {
                throw RuntimeControlClientError.malformedReply
            }
            return handle
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            switch clientError {
            case .transportFailure, .requestTimedOut, .requestCancelled, .malformedReply, .invalidRemoteProxy:
                do {
                    let snapshot = try await operationStatus(operationID)
                    guard snapshot.operationID == operationID,
                        snapshot.kind == .uninstall,
                        snapshot.packageID == request.packageID,
                        snapshot.requestFingerprint == requestFingerprint
                    else {
                        throw RuntimeControlClientError.operationResultUnknown(
                            operation: "beginUninstallPackage"
                        )
                    }
                    return OperationHandle(
                        operationID: snapshot.operationID,
                        parent: snapshot.parent,
                        kind: snapshot.kind
                    )
                } catch {
                    throw RuntimeControlClientError.operationResultUnknown(
                        operation: "beginUninstallPackage"
                    )
                }
            default:
                throw clientError
            }
        }
    }

    /// Returns the latest state for an operation.
    public func operationStatus(
        _ operationID: OperationID
    ) async throws(RuntimeControlClientError) -> OperationSnapshot {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeOperationStatusControlRequest(
                header: makeHeader(),
                operationID: operationID
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.operationStatus(data)
            let snapshot = try Self.decodeOperationStatusReply(from: response)
            guard snapshot.operationID == operationID else {
                throw RuntimeControlClientError.malformedReply
            }
            return snapshot
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Lists running operations and recently completed operations retained by the daemon.
    public func listOperations() async throws(RuntimeControlClientError) -> [OperationSnapshot] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeListOperationsControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.listOperations(data)
            return try Self.decodeListOperationsReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Requests cancellation at the operation's next supported cancellation point.
    public func cancelOperation(_ operationID: OperationID) async throws(RuntimeControlClientError)
        -> CancelReply
    {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeCancelOperationControlRequest(
                header: makeHeader(),
                operationID: operationID
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.cancelOperation(data)
            return try Self.decodeCancelOperationReply(from: response)
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        }
    }

    /// Subscribes to one event topic and returns a stream that remains registered after reconnects.
    public func subscribe(to topic: EventTopic) async throws(RuntimeControlClientError)
        -> AsyncStream<EventEnvelope>
    {
        let subscription = eventStreamHub.makeStream(for: topic) { [weak self] id in
            Task {
                await self?.removeEventSubscriber(id)
            }
        }
        do {
            let opened = try await ensureControl()
            try await ensureEventTopicSubscribed(topic, on: opened)
            return subscription.stream
        } catch let error as RuntimeControlClientError {
            _ = eventStreamHub.removeSubscriber(subscription.id)
            throw error
        } catch {
            _ = eventStreamHub.removeSubscriber(subscription.id)
            throw Self.transportFailure(error)
        }
    }

    private func makeHeader() -> APIRequestHeader {
        APIRequestHeader(clientKind: clientConfiguration.clientKind)
    }

    private func replayEventSubscriptions(on opened: OpenedControlConnection) async throws {
        for topic in eventStreamHub.activeTopics() {
            try await ensureEventTopicSubscribed(topic, on: opened)
        }
        if let current = openedControl, current.channel !== opened.channel {
            try await replayEventSubscriptions(on: current)
        }
    }

    private func ensureEventTopicSubscribed(
        _ topic: EventTopic,
        on initialConnection: OpenedControlConnection
    ) async throws {
        var opened = initialConnection
        while true {
            guard let current = openedControl else {
                opened = try await ensureControl()
                continue
            }
            if current.channel !== opened.channel {
                opened = current
                continue
            }
            if remoteEventTopics.contains(topic) {
                return
            }

            let request = try Self.encode(
                RuntimeSubscribeControlRequest(header: makeHeader(), topics: [topic])
            )
            do {
                let response = try await opened.channel.subscribe(request)
                let reply = try Self.decode(RuntimeSubscribeControlReply.self, from: response)
                if let error = reply.error {
                    throw RuntimeControlClientError.remoteFailure(
                        code: error.code,
                        message: error.message
                    )
                }
                guard reply.result?.contains(topic) == true else {
                    throw RuntimeControlClientError.malformedReply
                }
                guard let latest = openedControl, latest.channel === opened.channel else {
                    opened = try await ensureControl()
                    continue
                }
                if !remoteEventTopics.contains(topic) {
                    remoteEventTopics.append(topic)
                }
                if !eventStreamHub.activeTopics().contains(topic) {
                    await unsubscribeEventTopic(topic, on: opened)
                }
                return
            } catch {
                let clientError = Self.clientError(from: error)
                invalidateAfterTransportFailure(opened.channel, error: clientError)
                throw clientError
            }
        }
    }

    private func removeEventSubscriber(_ id: UUID) async {
        guard let removed = eventStreamHub.removeSubscriber(id) else { return }
        guard removed.lastForTopic else { return }

        if !eventStreamHub.hasSubscribers() {
            eventReconnectTask?.cancel()
            eventReconnectTask = nil
            eventReconnectID = nil
        }
        guard let openedControl,
            remoteEventTopics.contains(removed.topic)
        else {
            return
        }
        await unsubscribeEventTopic(removed.topic, on: openedControl)
    }

    private func unsubscribeEventTopic(
        _ topic: EventTopic,
        on opened: OpenedControlConnection
    ) async {
        guard openedControl?.channel === opened.channel,
            remoteEventTopics.contains(topic)
        else {
            return
        }
        do {
            let request = try Self.encode(
                RuntimeUnsubscribeControlRequest(header: makeHeader(), topics: [topic])
            )
            let response = try await opened.channel.unsubscribe(request)
            let reply = try Self.decode(RuntimeUnsubscribeControlReply.self, from: response)
            if let error = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: error.code,
                    message: error.message
                )
            }
            guard reply.result != nil else {
                throw RuntimeControlClientError.malformedReply
            }
            guard openedControl?.channel === opened.channel else { return }
            remoteEventTopics.removeAll { $0 == topic }
            if eventStreamHub.activeTopics().contains(topic), let current = openedControl {
                try await ensureEventTopicSubscribed(topic, on: current)
            }
        } catch {
            invalidateControlConnection(opened.channel)
        }
    }

    private func controlConnectionWasInterrupted(_ channel: any RuntimeControlChannel) {
        invalidateControlConnection(channel)
    }

    private func invalidateControlConnection(_ channel: any RuntimeControlChannel) {
        guard let openedControl, openedControl.channel === channel else { return }
        eventStreamHub.markResyncRequired(for: eventStreamHub.activeTopics())
        channel.invalidate()
        self.openedControl = nil
        remoteEventTopics = []
        startEventReconnectIfNeeded()
    }

    private func startEventReconnectIfNeeded() {
        guard eventStreamHub.hasSubscribers(), eventReconnectID == nil else { return }
        let reconnectID = UUID()
        eventReconnectID = reconnectID
        let task = Task { [weak self] in
            var retryDelay = Duration.milliseconds(250)
            while !Task.isCancelled {
                guard let self, self.eventStreamHub.hasSubscribers() else { break }
                do {
                    _ = try await self.ensureControl()
                    if await self.openedControlHasEventSubscribers() {
                        break
                    }
                } catch {
                    // Keep the stream registered and retry while any subscriber is still alive.
                }
                do {
                    try await Task.sleep(for: retryDelay)
                } catch {
                    break
                }
                retryDelay = min(retryDelay * 2, .seconds(5))
            }
            await self?.eventReconnectFinished(reconnectID)
        }
        eventReconnectTask = task
    }

    private func openedControlHasEventSubscribers() -> Bool {
        openedControl != nil && !eventStreamHub.activeTopics().isEmpty
    }

    private func eventReconnectFinished(_ reconnectID: UUID) {
        guard eventReconnectID == reconnectID else { return }
        eventReconnectID = nil
        eventReconnectTask = nil
    }

    private func invalidateAfterTransportFailure(
        _ failedChannel: any RuntimeControlChannel,
        error: RuntimeControlClientError
    ) {
        let shouldInvalidate: Bool
        switch error {
        case .transportFailure, .requestTimedOut, .requestCancelled, .malformedReply, .invalidRemoteProxy:
            shouldInvalidate = true
        default:
            shouldInvalidate = false
        }
        guard shouldInvalidate,
            let openedControl,
            openedControl.channel === failedChannel
        else {
            return
        }
        invalidateControlConnection(openedControl.channel)
    }

    private static func withTimeout<Value: Sendable>(
        _ timeout: Duration,
        operation: String,
        run: @escaping @Sendable () async throws(RuntimeControlClientError) -> Value
    ) async throws(RuntimeControlClientError) -> Value {
        let result = await withTaskGroup(
            of: Result<Value, RuntimeControlClientError>.self,
            returning: Result<Value, RuntimeControlClientError>.self
        ) { group in
            group.addTask {
                do {
                    return .success(try await run())
                } catch let error as RuntimeControlClientError {
                    return .failure(error)
                } catch {
                    return .failure(Self.transportFailure(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return .failure(.requestTimedOut(operation: operation))
                }
                return .failure(.requestTimedOut(operation: operation))
            }
            guard let result = await group.next() else {
                group.cancelAll()
                return .failure(.requestTimedOut(operation: operation))
            }
            group.cancelAll()
            return result
        }
        if Task.isCancelled {
            throw .requestCancelled(operation: operation)
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    private func ensureControl() async throws(RuntimeControlClientError) -> OpenedControlConnection {
        if let openedControl {
            do {
                try await replayEventSubscriptions(on: openedControl)
                guard let current = self.openedControl else {
                    return try await ensureControl()
                }
                guard current.channel === openedControl.channel else {
                    return try await ensureControl()
                }
                return current
            } catch {
                invalidateAfterTransportFailure(
                    openedControl.channel,
                    error: Self.clientError(from: error)
                )
                throw Self.clientError(from: error)
            }
        }

        let task: Task<OpenedControlConnection, any Error>
        if let openingControl {
            task = openingControl
        } else {
            task = Task { try await self.openControlEndpoint() }
            openingControl = task
        }

        do {
            let opened = try await task.value
            openingControl = nil
            if let current = openedControl, current.channel === opened.channel {
                try await replayEventSubscriptions(on: current)
                guard let latest = openedControl else {
                    return try await ensureControl()
                }
                guard latest.channel === current.channel else {
                    return try await ensureControl()
                }
                return latest
            }

            openedControl = opened
            remoteEventTopics = []
            opened.channel.setConnectionEventHandler { [weak self, weak channel = opened.channel] in
                guard let channel else { return }
                Task {
                    await self?.controlConnectionWasInterrupted(channel)
                }
            }
            do {
                try await replayEventSubscriptions(on: opened)
                guard let current = openedControl else {
                    return try await ensureControl()
                }
                guard current.channel === opened.channel else {
                    return try await ensureControl()
                }
                return current
            } catch {
                let clientError = Self.clientError(from: error)
                invalidateAfterTransportFailure(opened.channel, error: clientError)
                throw clientError
            }
        } catch {
            openingControl = nil
            if let clientError = error as? RuntimeControlClientError {
                throw clientError
            }
            throw Self.transportFailure(error)
        }
    }

    private func openControlEndpoint() async throws(RuntimeControlClientError) -> OpenedControlConnection {
        var lastError: RuntimeControlClientError = .endpointRejected(.busy)
        for attempt in 0...Self.maximumEndpointAdmissionRetries {
            do {
                switch try await openControlEndpointAttempt() {
                case .rejected(let rejection, let hostState):
                    guard
                        Self.shouldRetryEndpointAdmission(rejection, hostState: hostState),
                        attempt < Self.maximumEndpointAdmissionRetries
                    else {
                        throw RuntimeControlClientError.endpointRejected(rejection)
                    }
                    lastError = .endpointRejected(rejection)
                case .opened(let opened):
                    let probe = RuntimeStatusRequest(
                        header: APIRequestHeader(clientKind: clientConfiguration.clientKind)
                    )
                    do {
                        _ = try await opened.channel.runtimeStatus(Self.encode(probe))
                    } catch {
                        opened.channel.invalidate()
                        throw error
                    }
                    return opened
                }
            } catch {
                guard let clientError = error as? RuntimeControlClientError else {
                    throw Self.transportFailure(error)
                }
                guard case .transportFailure = clientError,
                    attempt < Self.maximumEndpointAdmissionRetries
                else {
                    throw clientError
                }
                lastError = clientError
            }

            do {
                try await Task.sleep(for: Self.endpointAdmissionRetryDelay(attempt: attempt))
            } catch {
                throw lastError
            }
        }
        throw lastError
    }

    private func openControlEndpointAttempt() async throws(RuntimeControlClientError) -> ControlEndpointAttempt {
        let broker = try connectionFactory.makeBroker(
            serviceName: clientConfiguration.serviceName,
            signingRequirement: clientConfiguration.daemonCodeSigningRequirement
        )
        defer { broker.invalidate() }

        let helloRequest = RuntimeHelloRequest(
            clientKind: clientConfiguration.clientKind,
            claimedIdentity: clientConfiguration.claimedIdentity,
            apiVersion: APIVersion.current,
            clientVersion: clientConfiguration.clientVersion,
            clientBuild: clientConfiguration.clientBuild
        )
        let helloData = try Self.encode(helloRequest)
        let helloReply = try Self.decodeHelloReply(from: await broker.hello(helloData))
        guard helloReply.apiVersion.major == APIVersion.current.major,
            helloReply.apiVersion.minor >= APIVersion.current.minor
        else {
            throw .apiVersionMismatch(client: APIVersion.current, server: helloReply.apiVersion)
        }

        let endpointRequest = RuntimeEndpointRequest(
            kind: .control,
            clientKind: clientConfiguration.clientKind,
            claimedIdentity: clientConfiguration.claimedIdentity,
            apiVersion: APIVersion.current
        )
        let endpointReply = try await broker.requestEndpoint(Self.encode(endpointRequest))
        let disposition = try Self.decode(RuntimeEndpointReply.self, from: endpointReply.data)
        switch disposition {
        case .rejected(let rejection):
            return .rejected(rejection, hostState: helloReply.hostState)
        case .granted:
            guard let endpoint = endpointReply.endpoint else {
                throw .endpointMissing
            }
            let control = try connectionFactory.makeControl(
                endpoint: endpoint,
                signingRequirement: clientConfiguration.daemonCodeSigningRequirement,
                eventSink: eventSink
            )
            return .opened(OpenedControlConnection(hello: helloReply, channel: control))
        }
    }

    private static func endpointAdmissionRetryDelay(attempt: Int) -> Duration {
        let milliseconds = min(25 * (1 << min(attempt, 4)), 250)
        return .milliseconds(milliseconds)
    }

    private static func shouldRetryEndpointAdmission(
        _ rejection: RuntimeEndpointRejection,
        hostState: String
    ) -> Bool {
        if rejection == .busy {
            return true
        }
        // API 1.0–1.2 servers encode a transient busy response as
        // `hostShuttingDown`; retry only while hello did not report shutdown.
        return rejection == .hostShuttingDown
            && APIVersion.current.minor < 3
            && hostState != "shuttingDown"
            && hostState != "stopped"
    }

    private static func decodeControlReply(from data: Data) throws(RuntimeControlClientError) -> RuntimeHostStatus {
        let reply = try Self.decode(RuntimeControlReply.self, from: data)
        guard (reply.status != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let error = reply.error {
            throw .remoteFailure(code: error.code, message: error.message)
        }
        guard let status = reply.status else {
            throw .malformedReply
        }
        return status
    }

    private static func decodeRuntimeInfoReply(from data: Data) throws(RuntimeControlClientError) -> RuntimeInfo {
        let reply = try Self.decode(RuntimeInfoControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeListSessionsReply(from data: Data) throws(RuntimeControlClientError)
        -> [SessionSummary]
    {
        let reply = try Self.decode(RuntimeListSessionsControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeConfigurationReply(from data: Data) throws(RuntimeControlClientError)
        -> ConfigurationSnapshot
    {
        let reply = try Self.decode(RuntimeConfigurationControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeUpdateConfigurationReply(from data: Data) throws(RuntimeControlClientError)
        -> ConfigurationSnapshot
    {
        let reply = try Self.decode(RuntimeUpdateConfigurationControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeImportPackageReply(from data: Data) throws(RuntimeControlClientError)
        -> RuntimeImportPreview
    {
        let reply = try Self.decode(RuntimeImportPackageControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeInstallImportedReply(from data: Data) throws(RuntimeControlClientError)
        -> RuntimePackageSummary
    {
        let reply = try Self.decode(RuntimeInstallImportedControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeBeginInstallImportedReply(from data: Data) throws(RuntimeControlClientError)
        -> OperationHandle
    {
        let reply = try Self.decode(RuntimeBeginInstallImportedControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeBeginUninstallPackageReply(from data: Data) throws(RuntimeControlClientError)
        -> OperationHandle
    {
        let reply = try Self.decode(RuntimeBeginUninstallPackageControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeOperationStatusReply(from data: Data) throws(RuntimeControlClientError)
        -> OperationSnapshot
    {
        let reply = try Self.decode(RuntimeOperationStatusControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeListOperationsReply(from data: Data) throws(RuntimeControlClientError)
        -> [OperationSnapshot]
    {
        let reply = try Self.decode(RuntimeListOperationsControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeCancelOperationReply(from data: Data) throws(RuntimeControlClientError)
        -> CancelReply
    {
        let reply = try Self.decode(RuntimeCancelOperationControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func clientError(from error: any Error) -> RuntimeControlClientError {
        (error as? RuntimeControlClientError) ?? .malformedReply
    }

    private static func decodeLaunchReply(from data: Data) throws(RuntimeControlClientError) -> RuntimeLaunchResult {
        let reply = try Self.decode(RuntimeLaunchControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeTerminateReply(from data: Data) throws(RuntimeControlClientError)
        -> RuntimeTerminateResult
    {
        let reply = try Self.decode(RuntimeTerminateControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodePackageListReply(from data: Data) throws(RuntimeControlClientError)
        -> RuntimePackageListResult
    {
        let reply = try Self.decode(RuntimeListPackagesControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodePackageInfoReply(from data: Data) throws(RuntimeControlClientError)
        -> RuntimePackageDetails
    {
        let reply = try Self.decode(RuntimePackageInfoControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func encode<Value: Encodable>(_ value: Value) throws(RuntimeControlClientError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .encodingFailure
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws(RuntimeControlClientError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .malformedReply
        }
    }

    private static func decodeHelloReply(from data: Data) throws(RuntimeControlClientError) -> RuntimeHelloReply {
        do {
            return try JSONDecoder().decode(RuntimeHelloReply.self, from: data)
        } catch {
            if let brokerError = try? JSONDecoder().decode(RuntimeBrokerErrorReply.self, from: data) {
                throw .remoteFailure(code: brokerError.error.code, message: brokerError.error.message)
            }
            throw .malformedReply
        }
    }

    private static func transportFailure(_ error: any Error) -> RuntimeControlClientError {
        let error = error as NSError
        return .transportFailure(domain: error.domain, code: error.code)
    }
}

private struct OpenedControlConnection: Sendable {
    let hello: RuntimeHelloReply
    let channel: any RuntimeControlChannel
}

private enum ControlEndpointAttempt {
    case opened(OpenedControlConnection)
    case rejected(RuntimeEndpointRejection, hostState: String)
}

private struct RuntimeBrokerErrorReply: Decodable {
    let error: RuntimeControlError
}

struct RuntimeControlClientConfiguration: Equatable, Sendable {
    static let maximumRestartRequestTimeout = Duration.seconds(3_675)

    enum BuildIdentity: Equatable, Sendable {
        case development
        case release(teamIdentifier: String)
        case releaseUpdateTest(teamIdentifier: String)
    }

    let clientKind: RuntimeClientKind
    let claimedIdentity: String
    let serviceName: String
    let daemonCodeSigningRequirement: String
    let clientVersion: String?
    let clientBuild: Int?
    let restartRequestTimeout: Duration

    init(
        clientKind: RuntimeClientKind,
        claimedIdentity: String,
        buildIdentity: BuildIdentity,
        clientVersion: String? = nil,
        clientBuild: Int? = nil,
        restartRequestTimeout: Duration = Self.maximumRestartRequestTimeout
    ) throws(RuntimeControlClientError) {
        guard !claimedIdentity.isEmpty else {
            throw .invalidClientIdentity
        }
        self.clientKind = clientKind
        self.claimedIdentity = claimedIdentity
        self.clientVersion = clientVersion
        self.clientBuild = clientBuild
        self.restartRequestTimeout = restartRequestTimeout
        switch buildIdentity {
        case .development:
            serviceName = "io.apkrun.apkrund.dev.xpc"
            daemonCodeSigningRequirement = "identifier \"io.apkrun.apkrund.dev\""
        case .release(let teamIdentifier):
            guard !teamIdentifier.isEmpty,
                teamIdentifier.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) })
            else {
                throw .invalidClientIdentity
            }
            serviceName = "io.apkrun.apkrund.xpc"
            daemonCodeSigningRequirement =
                "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
                + "and identifier \"io.apkrun.apkrund\""
        case .releaseUpdateTest(let teamIdentifier):
            guard !teamIdentifier.isEmpty,
                teamIdentifier.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) })
            else {
                throw .invalidClientIdentity
            }
            serviceName = "io.apkrun.apkrund.updatetest.xpc"
            daemonCodeSigningRequirement =
                "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
                + "and identifier \"io.apkrun.apkrund.updatetest\""
        }
    }

    static func current(
        clientKind: RuntimeClientKind,
        claimedIdentity: String?,
        bundle: Bundle = .main
    ) throws(RuntimeControlClientError) -> Self {
        guard let bundleIdentifier = bundle.bundleIdentifier,
            let buildIdentityValue = bundle.object(forInfoDictionaryKey: "APKRunBuildIdentity") as? String
        else {
            throw .invalidClientIdentity
        }
        let buildIdentity: BuildIdentity
        switch buildIdentityValue {
        case "dev":
            buildIdentity = .development
        case "release":
            buildIdentity = .release(teamIdentifier: try currentTeamIdentifier())
        case "updatetest":
            buildIdentity = .releaseUpdateTest(teamIdentifier: try currentTeamIdentifier())
        default:
            throw .invalidClientIdentity
        }
        let info = bundle.infoDictionary ?? [:]
        return try Self(
            clientKind: clientKind,
            claimedIdentity: claimedIdentity ?? bundleIdentifier,
            buildIdentity: buildIdentity,
            clientVersion: info["CFBundleShortVersionString"] as? String,
            clientBuild: (info["CFBundleVersion"] as? String).flatMap(Int.init)
        )
    }

    private static func currentTeamIdentifier() throws(RuntimeControlClientError) -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw .invalidClientIdentity
        }
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                executableURL as CFURL,
                SecCSFlags(rawValue: 0),
                &staticCode
            ) == errSecSuccess,
            let staticCode,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
            ) == errSecSuccess
        else {
            throw .invalidClientIdentity
        }
        var signingInformation: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation
            ) == errSecSuccess,
            let signingInformation,
            let teamIdentifier =
                (signingInformation as NSDictionary)[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            throw .invalidClientIdentity
        }
        return teamIdentifier
    }
}

struct RuntimeXPCListenerEndpoint: @unchecked Sendable {
    let value: AnyObject
}

struct RuntimeBrokerEndpointReply: Sendable {
    let data: Data
    let endpoint: RuntimeXPCListenerEndpoint?
}

protocol RuntimeBrokerChannel: Sendable {
    func hello(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func requestEndpoint(_ request: Data) async throws(RuntimeControlClientError) -> RuntimeBrokerEndpointReply
    func invalidate()
}

protocol RuntimeControlChannel: AnyObject, Sendable {
    func runtimeStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func runtimeInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func listSessions(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func configuration(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func updateConfiguration(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func startRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func stopRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func restartRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func resetRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func listPackages(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func packageInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func importPackage(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func installImported(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func beginInstallImported(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func beginUninstallPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func cancelOperation(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func listOperations(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func operationStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func subscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func unsubscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func launch(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func terminate(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func setConnectionEventHandler(_ handler: @escaping @Sendable () -> Void)
    func invalidate()
}

extension RuntimeControlChannel {
    func setConnectionEventHandler(_ handler: @escaping @Sendable () -> Void) {}
    func invalidate() {}
}

protocol RuntimeXPCConnectionFactory: Sendable {
    func makeBroker(
        serviceName: String,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeBrokerChannel
    func makeControl(
        endpoint: RuntimeXPCListenerEndpoint,
        signingRequirement: String,
        eventSink: RuntimeEventSinkReceiver
    ) throws(RuntimeControlClientError) -> any RuntimeControlChannel
}

private struct SystemRuntimeXPCConnectionFactory: RuntimeXPCConnectionFactory {
    func makeBroker(
        serviceName: String,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeBrokerChannel {
        let connection = configuredConnection(
            NSXPCConnection(machServiceName: serviceName, options: []),
            interface: try brokerInterface(),
            signingRequirement: signingRequirement
        )
        return XPCBrokerChannel(connection: connection)
    }

    func makeControl(
        endpoint: RuntimeXPCListenerEndpoint,
        signingRequirement: String,
        eventSink: RuntimeEventSinkReceiver
    ) throws(RuntimeControlClientError) -> any RuntimeControlChannel {
        guard let listenerEndpoint = endpoint.value as? NSXPCListenerEndpoint else {
            throw .malformedReply
        }
        let connection = configuredConnection(
            NSXPCConnection(listenerEndpoint: listenerEndpoint),
            interface: try controlInterface(),
            signingRequirement: signingRequirement,
            exportedInterface: NSXPCInterface(with: RuntimeEventSink.self),
            exportedObject: eventSink
        )
        return XPCControlChannel(connection: connection)
    }

    private func configuredConnection(
        _ connection: NSXPCConnection,
        interface: NSXPCInterface,
        signingRequirement: String,
        exportedInterface: NSXPCInterface? = nil,
        exportedObject: AnyObject? = nil
    ) -> NSXPCConnection {
        connection.remoteObjectInterface = interface
        connection.exportedInterface = exportedInterface
        connection.exportedObject = exportedObject
        connection.setCodeSigningRequirement(signingRequirement)
        connection.resume()
        return connection
    }

    private func brokerInterface() throws(RuntimeControlClientError) -> NSXPCInterface {
        let interface = NSXPCInterface(with: RuntimeBrokerXPC.self)
        guard let endpointClasses = NSSet(object: NSXPCListenerEndpoint.self) as? Set<AnyHashable> else {
            throw .invalidXPCInterface
        }
        interface.setClasses(
            endpointClasses,
            for: #selector(RuntimeBrokerXPC.requestEndpoint(_:reply:)),
            argumentIndex: 1,
            ofReply: true
        )
        return interface
    }

    private func controlInterface() throws(RuntimeControlClientError) -> NSXPCInterface {
        let interface = NSXPCInterface(with: RuntimeControlXPC.self)
        guard let fileClasses = NSSet(array: [NSArray.self, FileHandle.self]) as? Set<AnyHashable> else {
            throw .invalidXPCInterface
        }
        interface.setClasses(
            fileClasses,
            for: #selector(RuntimeControlXPC.importPackage(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return interface
    }
}

private final class XPCBrokerChannel: RuntimeBrokerChannel, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func hello(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeBrokerXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.hello(request) { response in finish(.success(response)) }
        }
    }

    func requestEndpoint(_ request: Data) async throws(RuntimeControlClientError) -> RuntimeBrokerEndpointReply {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeBrokerXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.requestEndpoint(request) { response, endpoint in
                let wrappedEndpoint = endpoint.map { RuntimeXPCListenerEndpoint(value: $0) }
                finish(.success(RuntimeBrokerEndpointReply(data: response, endpoint: wrappedEndpoint)))
            }
        }
    }

    func invalidate() {
        connection.invalidate()
    }

    private static func transportFailure(_ error: any Error) -> RuntimeControlClientError {
        let error = error as NSError
        return .transportFailure(domain: error.domain, code: error.code)
    }
}

private final class XPCControlChannel: RuntimeControlChannel, @unchecked Sendable {
    private let connection: NSXPCConnection
    private var eventHandlerRelay: RuntimeXPCConnectionEventRelay?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func runtimeStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.runtimeStatus(request) { response in finish(.success(response)) }
        }
    }

    func runtimeInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.runtimeInfo(request) { response in finish(.success(response)) }
        }
    }

    func listSessions(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.listSessions(request) { response in finish(.success(response)) }
        }
    }

    func configuration(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.configuration(request) { response in finish(.success(response)) }
        }
    }

    func updateConfiguration(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.updateConfiguration(request) { response in finish(.success(response)) }
        }
    }

    func startRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.startRuntime(request) { response in finish(.success(response)) }
        }
    }

    func stopRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.stopRuntime(request) { response in finish(.success(response)) }
        }
    }

    func restartRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        do {
            return try await withTaskCancellationHandler {
                try await withXPCReply { finish in
                    let proxy =
                        connection.remoteObjectProxyWithErrorHandler { error in
                            finish(.failure(Self.transportFailure(error)))
                        } as? any RuntimeControlXPC
                    guard let proxy else {
                        finish(.failure(.invalidRemoteProxy))
                        return
                    }
                    proxy.restartRuntime(request) { response in finish(.success(response)) }
                }
            } onCancel: {
                connection.invalidate()
            }
        } catch let error as RuntimeControlClientError {
            throw error
        } catch {
            throw Self.transportFailure(error)
        }
    }

    func resetRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.resetRuntime(request) { response in finish(.success(response)) }
        }
    }

    func listPackages(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.listPackages(request) { response in finish(.success(response)) }
        }
    }

    func packageInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.packageInfo(request) { response in finish(.success(response)) }
        }
    }

    func importPackage(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.importPackage(request, files: files) { response in finish(.success(response)) }
        }
    }

    func installImported(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.installImported(request) { response in finish(.success(response)) }
        }
    }

    func beginInstallImported(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.beginInstallImported(request) { response in finish(.success(response)) }
        }
    }

    func beginUninstallPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.beginUninstallPackage(request) { response in finish(.success(response)) }
        }
    }

    func cancelOperation(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.cancelOperation(request) { response in finish(.success(response)) }
        }
    }

    func listOperations(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.listOperations(request) { response in finish(.success(response)) }
        }
    }

    func operationStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.operationStatus(request) { response in finish(.success(response)) }
        }
    }

    func subscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.subscribe(request) { response in finish(.success(response)) }
        }
    }

    func unsubscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.unsubscribe(request) { response in finish(.success(response)) }
        }
    }

    func launch(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.launch(request) { response in finish(.success(response)) }
        }
    }

    func terminate(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.terminate(request) { response in finish(.success(response)) }
        }
    }

    func invalidate() {
        connection.invalidate()
    }

    func setConnectionEventHandler(_ handler: @escaping @Sendable () -> Void) {
        let relay = RuntimeXPCConnectionEventRelay(handler)
        eventHandlerRelay = relay
        let callback: @Sendable () -> Void = { [relay] in relay.fire() }
        connection.interruptionHandler = callback
        connection.invalidationHandler = callback
    }

    private static func transportFailure(_ error: any Error) -> RuntimeControlClientError {
        let error = error as NSError
        return .transportFailure(domain: error.domain, code: error.code)
    }
}

private final class RuntimeXPCConnectionEventRelay: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler()
    }
}

private final class XPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func complete<Value: Sendable>(
        _ result: Result<Value, RuntimeControlClientError>,
        continuation: CheckedContinuation<Value, any Error>
    ) {
        let shouldComplete = lock.withLock {
            guard !didComplete else { return false }
            didComplete = true
            return true
        }
        guard shouldComplete else { return }
        continuation.resume(with: result)
    }
}

private func withXPCReply<Value: Sendable>(
    _ invoke: (@escaping (Result<Value, RuntimeControlClientError>) -> Void) -> Void
) async throws(RuntimeControlClientError) -> Value {
    do {
        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate()
            invoke { result in
                gate.complete(result, continuation: continuation)
            }
        }
    } catch let error as RuntimeControlClientError {
        throw error
    } catch {
        let error = error as NSError
        throw .transportFailure(domain: error.domain, code: error.code)
    }
}
