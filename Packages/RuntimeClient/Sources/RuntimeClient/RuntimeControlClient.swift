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
    case remoteFailure(code: String, message: String, parameters: [String: String] = [:])
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
        case .remoteFailure(_, let message, _):
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

    private let configuration: RuntimeControlClientConfiguration
    private let connectionFactory: any RuntimeXPCConnectionFactory
    private let eventStreamHub: RuntimeEventStreamHub
    private let notificationStreamHub: RuntimeNotificationStreamHub
    private let eventSink: RuntimeEventSinkReceiver
    /// The closest stamp to this process's start (diagnostics.md §4.2,
    /// `WRAPPER_PROCESS_START`): taken when the client is created.
    private let processStartNanos = mach_continuous_time()
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
        configuration = try RuntimeControlClientConfiguration.current(
            clientKind: clientKind,
            claimedIdentity: claimedIdentity
        )
        connectionFactory = SystemRuntimeXPCConnectionFactory()
        let eventStreamHub = RuntimeEventStreamHub()
        self.eventStreamHub = eventStreamHub
        let notificationStreamHub = RuntimeNotificationStreamHub()
        self.notificationStreamHub = notificationStreamHub
        eventSink = RuntimeEventSinkReceiver(
            streamHub: eventStreamHub,
            notificationStreamHub: notificationStreamHub
        )
    }

    init(
        configuration: RuntimeControlClientConfiguration,
        connectionFactory: any RuntimeXPCConnectionFactory
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
        let eventStreamHub = RuntimeEventStreamHub()
        self.eventStreamHub = eventStreamHub
        let notificationStreamHub = RuntimeNotificationStreamHub()
        self.notificationStreamHub = notificationStreamHub
        eventSink = RuntimeEventSinkReceiver(
            streamHub: eventStreamHub,
            notificationStreamHub: notificationStreamHub
        )
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
                configuration.restartRequestTimeout,
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

    /// Starts first-run provisioning and returns a handle that can be polled.
    ///
    /// The supplied operation ID makes an ambiguous begin reply recoverable: if the request may
    /// have reached the daemon but its reply is lost, the client checks that ID once instead of
    /// resending (runtime-daemon.md §9.2).
    public func setup(
        _ request: SetupRequest,
        operationID: OperationID,
        files: [FileHandle] = []
    ) async throws(RuntimeControlClientError) -> OperationHandle {
        let requestFingerprint: String
        do {
            requestFingerprint = try RuntimeOperationRequestFingerprint.make(for: request)
        } catch {
            throw .encodingFailure
        }
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeSetupControlRequest(
                header: APIRequestHeader(
                    operationID: operationID.rawValue,
                    clientKind: configuration.clientKind
                ),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.setup(data, files: files)
            let handle = try Self.decodeSetupReply(from: response)
            guard handle.operationID == operationID, handle.kind == .setup else {
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
                        snapshot.kind == .setup,
                        snapshot.requestFingerprint == requestFingerprint
                    else {
                        throw RuntimeControlClientError.operationResultUnknown(
                            operation: "setup"
                        )
                    }
                    return OperationHandle(
                        operationID: snapshot.operationID,
                        parent: snapshot.parent,
                        kind: snapshot.kind
                    )
                } catch {
                    throw RuntimeControlClientError.operationResultUnknown(
                        operation: "setup"
                    )
                }
            default:
                throw clientError
            }
        }
    }

    /// Starts a Reset Android operation and returns a handle that can be polled
    /// (runtime-daemon.md §9.5).
    public func resetAndroid(
        _ request: ResetAndroidRequest,
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
            let controlRequest = RuntimeResetAndroidControlRequest(
                header: APIRequestHeader(
                    operationID: operationID.rawValue,
                    clientKind: configuration.clientKind
                ),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.resetAndroid(data)
            let handle = try Self.decodeResetAndroidReply(from: response)
            guard handle.operationID == operationID, handle.kind == .resetAndroid else {
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
                        snapshot.kind == .resetAndroid,
                        snapshot.requestFingerprint == requestFingerprint
                    else {
                        throw RuntimeControlClientError.operationResultUnknown(
                            operation: "resetAndroid"
                        )
                    }
                    return OperationHandle(
                        operationID: snapshot.operationID,
                        parent: snapshot.parent,
                        kind: snapshot.kind
                    )
                } catch {
                    throw RuntimeControlClientError.operationResultUnknown(
                        operation: "resetAndroid"
                    )
                }
            default:
                throw clientError
            }
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
            // Stamp APP_LAUNCH_REQUEST just before the send; the caller's own
            // stamps win when it carried them (diagnostics.md §4.2).
            let controlRequest = RuntimeLaunchControlRequest(
                header: makeHeader(),
                packageID: request.packageID,
                launchTiming: request.launchTiming
                    ?? LaunchTiming(
                        processStart: processStartNanos,
                        requestSent: mach_continuous_time()
                    )
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

    /// Verifies a wrapper bundle against the daemon's registry and package store.
    public func verifyWrapper(
        bundleURL: URL,
        deep: Bool = false
    ) async throws(RuntimeControlClientError) -> WrapperVerification {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeVerifyWrapperControlRequest(
                header: makeHeader(),
                bundleURL: bundleURL,
                deep: deep
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.verifyWrapper(data)
            let reply = try Self.decode(RuntimeVerifyWrapperControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Returns the registry row of one package's wrapper (runtime-api.md §10.2).
    public func wrapperInfo(
        packageID: RuntimePackageID
    ) async throws(RuntimeControlClientError) -> WrapperInfo {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeWrapperInfoControlRequest(
                header: makeHeader(),
                packageID: packageID
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.wrapperInfo(data)
            let reply = try Self.decode(RuntimeWrapperInfoControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// The stored `settings.json` of a package; nil when none is stored
    /// (host-ui.md §7).
    public func packageSettings(
        _ packageID: RuntimePackageID
    ) async throws(RuntimeControlClientError) -> PackageSettingsWire? {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimePackageSettingsControlRequest(
                header: makeHeader(),
                request: RuntimePackageSettingsRequest(packageID: packageID))
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.packageSettings(data)
            let reply = try Self.decode(RuntimePackageSettingsControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            return reply.result
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Applies a `settings.json` patch and returns the stored settings
    /// (host-ui.md §7).
    public func updatePackageSettings(
        _ packageID: RuntimePackageID,
        patch: RuntimePackageSettingsPatch
    ) async throws(RuntimeControlClientError) -> PackageSettingsWire {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeUpdatePackageSettingsControlRequest(
                header: makeHeader(),
                request: RuntimeUpdatePackageSettingsRequest(
                    packageID: packageID, patch: patch))
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.updatePackageSettings(data)
            let reply = try Self.decode(
                RuntimeUpdatePackageSettingsControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Lists every registered wrapper with its status (wrapper.md §9.1).
    public func listWrappers() async throws(RuntimeControlClientError) -> [WrapperListEntryWire] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeWrapperListControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.listWrappers(data)
            let reply = try Self.decode(RuntimeWrapperListControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Removes a wrapper's registry entry, optionally trashing the bundle
    /// (wrapper.md §9.5). Returns whether an entry was removed.
    public func removeWrapper(
        packageID: RuntimePackageID,
        trash: Bool
    ) async throws(RuntimeControlClientError) -> Bool {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeRemoveWrapperControlRequest(
                header: makeHeader(), packageID: packageID, trash: trash)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.removeWrapper(data)
            let reply = try Self.decode(RuntimeRemoveWrapperControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Scans the Applications folders for APKRun wrapper bundles
    /// (wrapper.md §7.2); `register` also registers them.
    public func rescanWrappers(
        register: Bool
    ) async throws(RuntimeControlClientError) -> RescanWrappersResult {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeRescanWrappersControlRequest(
                header: makeHeader(), register: register)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.rescanWrappers(data)
            let reply = try Self.decode(RuntimeRescanWrappersControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Starts a wrapper refresh on the daemon and returns the operation
    /// handle (wrapper.md §9.3). `icon` is the replacement icon file sent
    /// next to the request when `change.icon` is true.
    public func refreshWrapper(
        packageID: RuntimePackageID,
        change: WrapperRefreshWire,
        icon: FileHandle?,
        operationID: OperationID
    ) async throws(RuntimeControlClientError) -> OperationHandle {
        let request = RuntimeRefreshWrapperControlRequest(
            header: APIRequestHeader(
                operationID: operationID.rawValue,
                clientKind: configuration.clientKind
            ),
            packageID: packageID,
            change: change
        )
        let requestFingerprint: String
        do {
            requestFingerprint = try RuntimeOperationRequestFingerprint.make(for: request)
        } catch {
            throw .encodingFailure
        }
        let opened = try await ensureControl()
        do {
            let data = try Self.encode(request)
            let response = try await opened.channel.refreshWrapper(data, icon: icon)
            let reply = try Self.decode(RuntimeRefreshWrapperControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let handle = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            guard handle.operationID == operationID, handle.kind == .wrapperRefresh else {
                throw RuntimeControlClientError.malformedReply
            }
            return handle
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            switch clientError {
            case .transportFailure, .requestTimedOut, .requestCancelled, .malformedReply,
                .invalidRemoteProxy:
                do {
                    let snapshot = try await operationStatus(operationID)
                    guard snapshot.operationID == operationID,
                        snapshot.kind == .wrapperRefresh,
                        snapshot.packageID == packageID,
                        snapshot.requestFingerprint == requestFingerprint
                    else {
                        throw RuntimeControlClientError.operationResultUnknown(
                            operation: "refreshWrapper")
                    }
                    return OperationHandle(
                        operationID: snapshot.operationID,
                        parent: snapshot.parent,
                        kind: snapshot.kind
                    )
                } catch {
                    throw RuntimeControlClientError.operationResultUnknown(
                        operation: "refreshWrapper")
                }
            default:
                throw clientError
            }
        }
    }

    /// Starts a batch refresh of registered wrappers (wrapper.md §9.4).
    public func refreshAllWrappers(
        scope: RefreshAllScope,
        launcherOnly: Bool,
        operationID: OperationID
    ) async throws(RuntimeControlClientError) -> OperationHandle {
        let request = RuntimeRefreshAllWrappersControlRequest(
            header: APIRequestHeader(
                operationID: operationID.rawValue,
                clientKind: configuration.clientKind
            ),
            scope: scope,
            launcherOnly: launcherOnly
        )
        let requestFingerprint: String
        do {
            requestFingerprint = try RuntimeOperationRequestFingerprint.make(for: request)
        } catch {
            throw .encodingFailure
        }
        let opened = try await ensureControl()
        do {
            let data = try Self.encode(request)
            let response = try await opened.channel.refreshAllWrappers(data)
            let reply = try Self.decode(RuntimeRefreshAllWrappersControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let handle = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            guard handle.operationID == operationID, handle.kind == .wrapperRefreshAll else {
                throw RuntimeControlClientError.malformedReply
            }
            return handle
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            switch clientError {
            case .transportFailure, .requestTimedOut, .requestCancelled, .malformedReply,
                .invalidRemoteProxy:
                do {
                    let snapshot = try await operationStatus(operationID)
                    guard snapshot.operationID == operationID,
                        snapshot.kind == .wrapperRefreshAll,
                        snapshot.requestFingerprint == requestFingerprint
                    else {
                        throw RuntimeControlClientError.operationResultUnknown(
                            operation: "refreshAllWrappers")
                    }
                    return OperationHandle(
                        operationID: snapshot.operationID,
                        parent: snapshot.parent,
                        kind: snapshot.kind
                    )
                } catch {
                    throw RuntimeControlClientError.operationResultUnknown(
                        operation: "refreshAllWrappers")
                }
            default:
                throw clientError
            }
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

    /// Lists the live app sessions (host-ui.md §5.2).
    public func listSessions() async throws(RuntimeControlClientError) -> [WireSessionSummary] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeListSessionsControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.listSessions(data)
            let reply = try Self.decode(RuntimeListSessionsControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let sessions = reply.sessions else {
                throw RuntimeControlClientError.malformedReply
            }
            return sessions
        } catch let error as RuntimeControlClientError {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: Self.transportFailure(error))
            throw Self.transportFailure(error)
        }
    }

    /// Returns the composed Mac icon PNG of one package (host-ui.md §5.3).
    public func packageIcon(
        packageID: RuntimePackageID
    ) async throws(RuntimeControlClientError) -> Data? {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimePackageIconControlRequest(
                header: makeHeader(), packageID: packageID)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.packageIcon(data)
            let reply = try Self.decode(RuntimePackageIconControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            return reply.png
        } catch let error as RuntimeControlClientError {
            invalidateAfterTransportFailure(opened.channel, error: error)
            throw error
        } catch {
            invalidateAfterTransportFailure(opened.channel, error: Self.transportFailure(error))
            throw Self.transportFailure(error)
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

    /// Starts the `bootstrapImport` operation of an approved portable
    /// wrapper's launcher (wrapper-json.md §3.4). The bootstrap document and
    /// one file handle per declared APK travel with the request.
    public func importBootstrap(
        bundleID: String,
        bootstrapJSON: Data,
        files: [FileHandle]
    ) async throws(RuntimeControlClientError) -> OperationHandle {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeImportBootstrapControlRequest(
                header: makeHeader(),
                bundleID: bundleID,
                bootstrapJSON: bootstrapJSON
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.importBootstrap(data, files: files)
            let reply = try Self.decode(RuntimeImportBootstrapControlReply.self, from: response)
            if let wireError = reply.error {
                throw Self.clientError(from: wireError)
            }
            guard let handle = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return handle
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
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

    /// Drops an import ticket and its private APK copies without starting Android.
    public func discardImport(
        _ request: RuntimeDiscardImportRequest
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeDiscardImportControlRequest(
                header: makeHeader(),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.discardImport(data)
            let reply = try Self.decode(RuntimeDiscardImportControlReply.self, from: response)
            if let error = reply.error {
                throw Self.clientError(from: error)
            }
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Adopts a package Android has but APKRun does not manage (package-store.md §9.3).
    public func adoptPackage(
        _ request: RuntimeAdoptPackageRequest
    ) async throws(RuntimeControlClientError) -> RuntimePackageSummary {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeAdoptPackageControlRequest(
                header: makeHeader(),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.adoptPackage(data)
            let reply = try Self.decode(RuntimeAdoptPackageControlReply.self, from: response)
            if let error = reply.error {
                throw Self.clientError(from: error)
            }
            guard let summary = reply.summary else {
                throw RuntimeControlClientError.malformedReply
            }
            return summary
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
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
                    clientKind: configuration.clientKind
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
                    clientKind: configuration.clientKind
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

    /// Starts wrapper generation on the daemon and returns the operation handle.
    ///
    /// `icon` carries the optional custom icon file sent next to the request.
    /// A transport failure is reconciled through `operationStatus` like every
    /// other long operation, because the daemon deduplicates by operation ID.
    public func createWrapper(
        _ request: WrapperRequest,
        icon: FileHandle?,
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
            let controlRequest = RuntimeCreateWrapperControlRequest(
                header: APIRequestHeader(
                    operationID: operationID.rawValue,
                    clientKind: configuration.clientKind
                ),
                request: request
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.createWrapper(data, icon: icon)
            let reply = try Self.decode(RuntimeCreateWrapperControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let handle = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            guard handle.operationID == operationID, handle.kind == .wrapperCreate else {
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
                        snapshot.kind == .wrapperCreate,
                        snapshot.packageID == request.packageID,
                        snapshot.requestFingerprint == requestFingerprint
                    else {
                        throw RuntimeControlClientError.operationResultUnknown(
                            operation: "createWrapper"
                        )
                    }
                    return OperationHandle(
                        operationID: snapshot.operationID,
                        parent: snapshot.parent,
                        kind: snapshot.kind
                    )
                } catch {
                    throw RuntimeControlClientError.operationResultUnknown(
                        operation: "createWrapper"
                    )
                }
            default:
                throw clientError
            }
        }
    }

    /// Completes a staged wrapper placement after the client moved the
    /// bundle into the protected folder (wrapper.md §6.3). API 1.18+.
    public func placeStagedWrapper(
        stagingToken: String,
        finalURL: URL,
        bookmark: String?
    ) async throws(RuntimeControlClientError) -> WrapperInfo {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimePlaceStagedWrapperControlRequest(
                header: makeHeader(),
                stagingToken: stagingToken,
                finalURL: finalURL,
                bookmark: bookmark
            )
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.placeStagedWrapper(data)
            let reply = try Self.decode(RuntimePlaceStagedWrapperControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message,
                    parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// The approval prompts waiting for APKRun.app (runtime-api.md §10.6).
    public func pendingApprovals() async throws(RuntimeControlClientError) -> [ApprovalPrompt] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimePendingApprovalsControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.pendingApprovals(data)
            let reply = try Self.decode(RuntimePendingApprovalsControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Answers an approval prompt (runtime-api.md §10.6, APKRun.app only).
    public func decideApproval(
        approvalID: ApprovalID,
        allow: Bool
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeDecideApprovalControlRequest(
                header: makeHeader(), approvalID: approvalID, allow: allow)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.decideApproval(data)
            let reply = try Self.decode(RuntimeDecideApprovalControlReply.self, from: response)
            guard (reply.acknowledged == true) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// The wrappers the user denied (runtime-api.md §10.6).
    public func deniedWrappers() async throws(RuntimeControlClientError) -> [DeniedWrapper] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeDeniedWrappersControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.deniedWrappers(data)
            let reply = try Self.decode(RuntimeDeniedWrappersControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Removes a denied entry (runtime-api.md §10.6, Settings → Privacy → Remove).
    public func clearWrapperDenial(
        bundleID: String,
        cdhash: String
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeClearWrapperDenialControlRequest(
                header: makeHeader(), bundleID: bundleID, cdhash: cdhash)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.clearWrapperDenial(data)
            let reply = try Self.decode(RuntimeClearWrapperDenialControlReply.self, from: response)
            guard (reply.acknowledged == true) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Returns host-side performance statistics; developer mode only
    /// (diagnostics.md §9.3, runtime-api.md §13.1).
    public func perfStatistics(
        reset: Bool = false
    ) async throws(RuntimeControlClientError) -> WirePerfStatistics {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimePerfStatisticsControlRequest(
                header: makeHeader(), reset: reset)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.perfStatistics(data)
            let reply = try Self.decode(RuntimePerfStatisticsControlReply.self, from: response)
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Returns per-session graphics statistics; developer mode only.
    /// `sessionID` narrows the reply to one session; `nil` asks for all live sessions.
    public func frameStatistics(
        sessionID: UUID? = nil
    ) async throws(RuntimeControlClientError) -> [SessionGraphicsStatistics] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeFrameStatisticsControlRequest(
                header: makeHeader(), sessionID: sessionID)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.frameStatistics(data)
            let reply = try Self.decode(RuntimeFrameStatisticsControlReply.self, from: response)
            guard (reply.sessions != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let sessions = reply.sessions else {
                throw RuntimeControlClientError.malformedReply
            }
            return sessions
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Pushes a Mac clip toward Android; the reply carries the acknowledged
    /// seq (desktop-integration.md §4.2, runtime-api.md §11.2).
    public func pushClipboard(
        sessionID: UUID, item: ClipItem
    ) async throws(RuntimeControlClientError) -> ClipAck {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimePushClipboardControlRequest(
                header: makeHeader(), sessionID: sessionID, item: item)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.pushClipboard(data)
            let reply = try Self.decode(RuntimePushClipboardControlReply.self, from: response)
            guard (reply.ack != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let ack = reply.ack else {
                throw RuntimeControlClientError.malformedReply
            }
            return ack
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Reports the pasteboard write the window made (one-way; §4.2).
    public func clipboardWritten(
        sessionID: UUID, written: ClipboardWritten
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeClipboardWrittenControlRequest(
                header: makeHeader(), sessionID: sessionID, written: written)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.clipboardWritten(data)
            let reply = try Self.decode(RuntimeClipboardWrittenControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Reports whether the session's window is the key window (one-way; §4.1).
    public func focusChanged(
        sessionID: UUID, isKey: Bool
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeFocusChangedControlRequest(
                header: makeHeader(), sessionID: sessionID, isKey: isKey)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.focusChanged(data)
            let reply = try Self.decode(RuntimeFocusChangedControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Returns the per-kind integration status of a package (runtime-api.md §11).
    public func integrationStatus(
        packageID: RuntimePackageID
    ) async throws(RuntimeControlClientError) -> IntegrationStatus {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeIntegrationStatusControlRequest(
                header: makeHeader(), packageID: packageID)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.integrationStatus(data)
            let reply = try Self.decode(RuntimeIntegrationStatusControlReply.self, from: response)
            guard (reply.status != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let status = reply.status else {
                throw RuntimeControlClientError.malformedReply
            }
            return status
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Checks packages for updates (runtime-api.md §9.1). `packages` nil
    /// selects every `apkrun`-authority package. `checkOnly` reports without
    /// downloading or notifying.
    public func checkForUpdates(
        packages: [RuntimePackageID]? = nil,
        checkOnly: Bool = false
    ) async throws(RuntimeControlClientError) -> (operation: OperationHandle, results: [UpdateCheckResult]) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeCheckForUpdatesControlRequest(
                header: makeHeader(), packages: packages, checkOnly: checkOnly)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.checkForUpdates(data)
            let reply = try Self.decode(RuntimeCheckForUpdatesControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let operation = reply.operation else {
                throw RuntimeControlClientError.malformedReply
            }
            return (operation, reply.results ?? [])
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Lists per-package update state (runtime-api.md §9.1).
    public func listUpdates() async throws(RuntimeControlClientError) -> [PackageUpdateStatus] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeListUpdatesControlRequest(header: makeHeader())
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.listUpdates(data)
            let reply = try Self.decode(RuntimeListUpdatesControlReply.self, from: response)
            guard (reply.updates != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let updates = reply.updates else {
                throw RuntimeControlClientError.malformedReply
            }
            return updates
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Reads update history (runtime-api.md §9.1). `packageID` nil reads every
    /// package; `limit` defaults to 50 and clamps to 1000.
    public func updateHistory(
        packageID: RuntimePackageID? = nil,
        limit: Int? = nil
    ) async throws(RuntimeControlClientError) -> [UpdateHistoryEntry] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeUpdateHistoryControlRequest(
                header: makeHeader(), packageID: packageID, limit: limit)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.updateHistory(data)
            let reply = try Self.decode(RuntimeUpdateHistoryControlReply.self, from: response)
            guard (reply.entries != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let entries = reply.entries else {
                throw RuntimeControlClientError.malformedReply
            }
            return entries
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Sets a package's update mode and provider (runtime-api.md §9.1) and
    /// returns its update status after the write.
    public func setUpdatePolicy(
        packageID: RuntimePackageID,
        policy: UpdatePolicy
    ) async throws(RuntimeControlClientError) -> PackageUpdateStatus {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeSetUpdatePolicyControlRequest(
                header: makeHeader(), packageID: packageID, policy: policy)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.setUpdatePolicy(data)
            let reply = try Self.decode(RuntimeSetUpdatePolicyControlReply.self, from: response)
            guard (reply.status != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let status = reply.status else {
                throw RuntimeControlClientError.malformedReply
            }
            return status
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Sets a package's update authority (runtime-api.md §9.1, update-system.md
    /// §2.1) and returns its update status after the write.
    public func setUpdateAuthority(
        packageID: RuntimePackageID,
        authority: AuthorityChoice
    ) async throws(RuntimeControlClientError) -> PackageUpdateStatus {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeSetUpdateAuthorityControlRequest(
                header: makeHeader(), packageID: packageID, authority: authority)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.setUpdateAuthority(data)
            let reply = try Self.decode(RuntimeSetUpdateAuthorityControlReply.self, from: response)
            guard (reply.status != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let status = reply.status else {
                throw RuntimeControlClientError.malformedReply
            }
            return status
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Rolls a package back to its previous artifact set (runtime-api.md
    /// §9.1, update-system.md §8.5, cli.md §4.3). The reply's
    /// `rolledBackTo`/`unavailable` tells the CLI which §8.5 message to
    /// print.
    /// Reads `updates.*` settings for `apkrun config get`
    /// (configuration.md §2.7). `keys` nil lists every key.
    public func getConfig(
        keys: [String]? = nil
    ) async throws(RuntimeControlClientError) -> [String: String] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeConfigGetControlRequest(
                header: makeHeader(), keys: keys)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.getConfig(data)
            let reply = try Self.decode(RuntimeConfigGetControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let values = reply.values else {
                throw RuntimeControlClientError.malformedReply
            }
            return values
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Writes one `updates.*` setting for `apkrun config set`
    /// (configuration.md §2.7) and returns the values after the write.
    public func setConfig(
        key: String, value: String
    ) async throws(RuntimeControlClientError) -> [String: String] {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeConfigSetControlRequest(
                header: makeHeader(), key: key, value: value)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.setConfig(data)
            let reply = try Self.decode(RuntimeConfigSetControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let values = reply.values else {
                throw RuntimeControlClientError.malformedReply
            }
            return values
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Rolls the package back to its previous version (update-system §7).
    public func rollbackPackage(
        packageID: RuntimePackageID,
        allowDataLoss: Bool = false
    ) async throws(RuntimeControlClientError) -> RuntimeRollbackPackageControlReply {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeRollbackPackageControlRequest(
                header: makeHeader(), packageID: packageID, allowDataLoss: allowDataLoss)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.rollbackPackage(data)
            let reply = try Self.decode(RuntimeRollbackPackageControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard (reply.rolledBackTo != nil) != (reply.unavailable == true) else {
                throw RuntimeControlClientError.malformedReply
            }
            return reply
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Starts reinstalling a broken package from `current/` (package-store.md
    /// §11.1). `apkrun repair` and the app-page Repair button both end here;
    /// the repair is a `repair` long operation.
    public func repairPackage(
        packageID: RuntimePackageID
    ) async throws(RuntimeControlClientError) -> OperationHandle {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeBeginRepairPackageControlRequest(
                header: makeHeader(), request: RuntimePackageRequest(packageID: packageID))
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.beginRepairPackage(data)
            let reply = try Self.decode(RuntimeBeginRepairPackageControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let handle = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return handle
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Adds or removes a versionCode on the package's skip list
    /// (runtime-api.md §9.1, update-system.md §8.4, cli.md §4.3).
    public func updateSkipped(
        packageID: RuntimePackageID,
        versionCode: RuntimeVersionCode,
        skipped: Bool
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeUpdateSkipControlRequest(
                header: makeHeader(), packageID: packageID,
                versionCode: versionCode, skipped: skipped)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.updateSkipped(data)
            let reply = try Self.decode(RuntimeUpdateSkipControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
        }
    }

    /// Checks and installs a package update now (runtime-api.md §9.1).
    /// `options.files` turns the request into a manual file update; the
    /// matching file handles travel like `importPackage`'s.
    /// `outcome` is nil while the run still waits (a staged update gated by
    /// an open session, update-system.md §7.3).
    public func updatePackage(
        packageID: RuntimePackageID,
        options: UpdateNowOptions = UpdateNowOptions(),
        files: [FileHandle] = []
    ) async throws(RuntimeControlClientError) -> (operation: OperationHandle, outcome: WireUpdateOutcome?) {
        let opened = try await ensureControl()
        do {
            let controlRequest = RuntimeUpdatePackageControlRequest(
                header: makeHeader(), packageID: packageID, options: options)
            let data = try Self.encode(controlRequest)
            let response = try await opened.channel.updatePackage(data, files: files)
            let reply = try Self.decode(RuntimeUpdatePackageControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let operation = reply.operation else {
                throw RuntimeControlClientError.malformedReply
            }
            return (operation, reply.outcome)
        } catch {
            let clientError = Self.clientError(from: error)
            invalidateAfterTransportFailure(opened.channel, error: clientError)
            throw clientError
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

    /// Opens (or reuses) this connection's `notificationRelay` stream
    /// (runtime-api.md §11.3) and returns its handle plus the relay events.
    public func notificationRelayStream(
        background: Bool = false
    ) async throws(RuntimeControlClientError) -> (
        handle: StreamHandle, events: AsyncStream<StreamEnvelope>
    ) {
        let opened = try await ensureControl()
        do {
            let data = try Self.encode(
                NotificationRelayRequest(header: makeHeader(), background: background))
            let response = try await opened.channel.notificationRelay(data)
            let reply = try Self.decode(RuntimeStreamHandleControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let handle = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return (handle, notificationStreamHub.register(handle.streamID))
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Sends a `RelayResponse` on an open notification relay stream (§11.3).
    public func sendNotificationRelayResponse(
        _ response: RelayResponse,
        on streamID: StreamID
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let data = try Self.encode(
                RelayResponseRequest(
                    header: makeHeader(), streamID: streamID, response: response))
            let replyData = try await opened.channel.notificationRelayResponse(data)
            let reply = try Self.decode(RuntimeStreamControlReply.self, from: replyData)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Opens the single `hostNotifications` stream (runtime-api.md §11.3);
    /// an existing stream on the daemon side ends with `replaced`.
    public func hostNotificationsStream(
        background: Bool = false
    ) async throws(RuntimeControlClientError) -> (
        handle: StreamHandle, events: AsyncStream<StreamEnvelope>
    ) {
        let opened = try await ensureControl()
        do {
            let data = try Self.encode(
                HostNotificationsRequest(header: makeHeader(), background: background))
            let response = try await opened.channel.hostNotifications(data)
            let reply = try Self.decode(RuntimeStreamHandleControlReply.self, from: response)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            guard let handle = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return (handle, notificationStreamHub.register(handle.streamID))
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Sends a `HostNotificationResponse` on the host notifications stream
    /// (§11.3).
    public func sendHostNotificationResponse(
        _ response: HostNotificationResponse,
        on streamID: StreamID
    ) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let data = try Self.encode(
                HostNotificationResponseRequest(
                    header: makeHeader(), streamID: streamID, response: response))
            let replyData = try await opened.channel.hostNotificationResponse(data)
            let reply = try Self.decode(RuntimeStreamControlReply.self, from: replyData)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    /// Closes one of this connection's streams (§16.4); idempotent.
    public func closeStream(_ streamID: StreamID) async throws(RuntimeControlClientError) {
        let opened = try await ensureControl()
        do {
            let data = try Self.encode(
                CloseStreamRequest(header: makeHeader(), streamID: streamID))
            let replyData = try await opened.channel.closeStream(data)
            let reply = try Self.decode(RuntimeStreamControlReply.self, from: replyData)
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(
                    code: failure.code, message: failure.message, parameters: failure.parameters)
            }
            notificationStreamHub.remove(streamID)
        } catch {
            let failure = error as? RuntimeControlClientError ?? .malformedReply
            invalidateAfterTransportFailure(opened.channel, error: failure)
            throw failure
        }
    }

    private func makeHeader() -> APIRequestHeader {
        APIRequestHeader(clientKind: configuration.clientKind)
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
                        message: error.message,
                        parameters: error.parameters
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
                    message: error.message,
                    parameters: error.parameters
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
        // Open streams die with the connection; an `.ended` never arrives.
        notificationStreamHub.finishAll()
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
                    let probe = RuntimeStatusRequest(header: APIRequestHeader(clientKind: configuration.clientKind))
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
            serviceName: configuration.serviceName,
            signingRequirement: configuration.daemonCodeSigningRequirement
        )
        defer { broker.invalidate() }

        let helloRequest = RuntimeHelloRequest(
            clientKind: configuration.clientKind,
            claimedIdentity: configuration.claimedIdentity,
            apiVersion: APIVersion.current,
            clientVersion: configuration.clientVersion,
            clientBuild: configuration.clientBuild
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
            clientKind: configuration.clientKind,
            claimedIdentity: configuration.claimedIdentity,
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
                signingRequirement: configuration.daemonCodeSigningRequirement,
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
            throw .remoteFailure(code: error.code, message: error.message, parameters: error.parameters)
        }
        guard let status = reply.status else {
            throw .malformedReply
        }
        return status
    }

    private static func decodeImportPackageReply(from data: Data) throws(RuntimeControlClientError)
        -> RuntimeImportPreview
    {
        let reply = try Self.decode(RuntimeImportPackageControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeSetupReply(from data: Data) throws(RuntimeControlClientError)
        -> OperationHandle
    {
        let reply = try Self.decode(RuntimeSetupControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
        }
        guard let result = reply.result else {
            throw .malformedReply
        }
        return result
    }

    private static func decodeResetAndroidReply(from data: Data) throws(RuntimeControlClientError)
        -> OperationHandle
    {
        let reply = try Self.decode(RuntimeResetAndroidControlReply.self, from: data)
        guard (reply.result != nil) != (reply.error != nil) else {
            throw .malformedReply
        }
        if let failure = reply.error {
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
            throw .remoteFailure(code: failure.code, message: failure.message, parameters: failure.parameters)
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
                throw .remoteFailure(
                    code: brokerError.error.code, message: brokerError.error.message,
                    parameters: brokerError.error.parameters)
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
    /// Asks the user to approve an unknown wrapper (runtime-api.md §3.4).
    func requestApproval(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func invalidate()
}

protocol RuntimeControlChannel: AnyObject, Sendable {
    func runtimeStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func startRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func stopRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func restartRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func resetRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func setup(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func resetAndroid(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func listPackages(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func packageInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func listSessions(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func packageIcon(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func importPackage(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func importBootstrap(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func installImported(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func discardImport(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func adoptPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func beginInstallImported(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func beginUninstallPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func cancelOperation(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func listOperations(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func operationStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func subscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func unsubscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func launch(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func terminate(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func verifyWrapper(_ request: Data) async throws(RuntimeControlClientError) -> Data

    /// Starts a wrapper generation; the reply carries the operation handle.
    func createWrapper(_ request: Data, icon: FileHandle?) async throws(RuntimeControlClientError) -> Data
    /// Finishes a staged wrapper placement (wrapper.md §6.3).
    func placeStagedWrapper(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Returns the registry row of one package's wrapper (runtime-api.md §10.2).
    func wrapperInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data

    /// Lists every registered wrapper (wrapper.md §9.1).
    func listWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data

    /// The stored settings of one package (host-ui.md §7).
    func packageSettings(_ request: Data) async throws(RuntimeControlClientError) -> Data

    /// Applies a settings patch (host-ui.md §7).
    func updatePackageSettings(_ request: Data) async throws(RuntimeControlClientError) -> Data

    /// Removes a wrapper's registry entry (wrapper.md §9.5).
    func removeWrapper(_ request: Data) async throws(RuntimeControlClientError) -> Data

    /// Scans the Applications folders for wrapper bundles (wrapper.md §7.2).
    func rescanWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data

    /// Starts a wrapper refresh; the reply carries the operation handle.
    func refreshWrapper(_ request: Data, icon: FileHandle?) async throws(RuntimeControlClientError) -> Data

    /// Starts a batch wrapper refresh; the reply carries the operation handle.
    func refreshAllWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Returns the approval prompts waiting for APKRun.app.
    func pendingApprovals(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Answers an approval prompt.
    func decideApproval(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Lists the wrappers the user denied.
    func deniedWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Removes a denied entry.
    func clearWrapperDenial(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Returns host-side performance statistics; developer mode only.
    func perfStatistics(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Returns per-session graphics statistics; developer mode only.
    func frameStatistics(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Pushes a Mac clip toward Android (desktop-integration.md §4.2).
    func pushClipboard(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Reports a pasteboard write the window made (desktop-integration.md §4.2).
    func clipboardWritten(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Reports whether the session's window is the key window (§4.1).
    func focusChanged(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Returns the per-kind integration status of a package (runtime-api.md §11).
    func integrationStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Checks packages for updates (runtime-api.md §9.1).
    func checkForUpdates(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Lists per-package update state (runtime-api.md §9.1).
    func listUpdates(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Reads update history (runtime-api.md §9.1).
    func updateHistory(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Sets a package's update mode and provider (runtime-api.md §9.1).
    func setUpdatePolicy(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Sets a package's update authority (runtime-api.md §9.1).
    func setUpdateAuthority(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Rolls a package back to `previous/` (runtime-api.md §9.1, update-system.md §8.5).
    func rollbackPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Starts reinstalling a broken package from `current/` (package-store.md §11.1).
    func beginRepairPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Opens a `notificationRelay` stream (wrapper connections only, §11.3).
    func notificationRelay(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Delivers a `RelayResponse` on an open relay stream (§11.3).
    func notificationRelayResponse(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Opens the single `hostNotifications` stream (§11.3).
    func hostNotifications(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Delivers a `HostNotificationResponse` on the host stream (§11.3).
    func hostNotificationResponse(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Closes one of this connection's streams; idempotent (§16.4).
    func closeStream(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Adds or removes a version on the package's skip list (§8.4).
    func updateSkipped(_ request: Data) async throws(RuntimeControlClientError) -> Data
    /// Checks and installs a package update now, optionally from files (runtime-api.md §9.1).
    func updatePackage(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func getConfig(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func setConfig(_ request: Data) async throws(RuntimeControlClientError) -> Data
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
        interface.setClasses(
            fileClasses,
            for: #selector(RuntimeControlXPC.updatePackage(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            fileClasses,
            for: #selector(RuntimeControlXPC.importBootstrap(_:files:reply:)),
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

    func requestApproval(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeBrokerXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.requestApproval(request) { response in finish(.success(response)) }
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

    func setup(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.setup(request, files: files) { response in finish(.success(response)) }
        }
    }

    func resetAndroid(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.resetAndroid(request) { response in finish(.success(response)) }
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

    func packageIcon(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.packageIcon(request) { response in finish(.success(response)) }
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

    func importBootstrap(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.importBootstrap(request, files: files) { response in finish(.success(response)) }
        }
    }

    func discardImport(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.discardImport(request) { response in finish(.success(response)) }
        }
    }

    func adoptPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.adoptPackage(request) { response in finish(.success(response)) }
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

    func notificationRelay(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.notificationRelay(request) { response in finish(.success(response)) }
        }
    }

    func notificationRelayResponse(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.notificationRelayResponse(request) { response in finish(.success(response)) }
        }
    }

    func hostNotifications(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.hostNotifications(request) { response in finish(.success(response)) }
        }
    }

    func hostNotificationResponse(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.hostNotificationResponse(request) { response in finish(.success(response)) }
        }
    }

    func closeStream(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.closeStream(request) { response in finish(.success(response)) }
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

    func verifyWrapper(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.verifyWrapper(request) { response in finish(.success(response)) }
        }
    }

    /// Starts a wrapper generation; the reply carries the operation handle.
    func createWrapper(_ request: Data, icon: FileHandle?) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.createWrapper(request, icon: icon) { response in finish(.success(response)) }
        }
    }

    /// Returns the registry row of one package's wrapper (runtime-api.md §10.2).
    func wrapperInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.wrapperInfo(request) { response in finish(.success(response)) }
        }
    }

    /// Lists every registered wrapper (wrapper.md §9.1).
    func listWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.listWrappers(request) { response in finish(.success(response)) }
        }
    }

    /// The stored settings of one package (host-ui.md §7).
    func packageSettings(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.packageSettings(request) { response in finish(.success(response)) }
        }
    }

    /// Applies a settings patch (host-ui.md §7).
    func updatePackageSettings(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.updatePackageSettings(request) { response in finish(.success(response)) }
        }
    }

    /// Removes a wrapper's registry entry (wrapper.md §9.5).
    func removeWrapper(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.removeWrapper(request) { response in finish(.success(response)) }
        }
    }

    /// Scans the Applications folders for wrapper bundles (wrapper.md §7.2).
    func rescanWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.rescanWrappers(request) { response in finish(.success(response)) }
        }
    }

    /// Starts a wrapper refresh; the reply carries the operation handle.
    func refreshWrapper(_ request: Data, icon: FileHandle?) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.refreshWrapper(request, icon: icon) { response in finish(.success(response)) }
        }
    }

    /// Starts a batch wrapper refresh; the reply carries the operation handle.
    func refreshAllWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.refreshAllWrappers(request) { response in finish(.success(response)) }
        }
    }

    /// Finishes a staged wrapper placement (wrapper.md §6.3).
    func placeStagedWrapper(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.placeStagedWrapper(request) { response in finish(.success(response)) }
        }
    }

    func pendingApprovals(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.pendingApprovals(request) { response in finish(.success(response)) }
        }
    }

    func decideApproval(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.decideApproval(request) { response in finish(.success(response)) }
        }
    }

    func deniedWrappers(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.deniedWrappers(request) { response in finish(.success(response)) }
        }
    }

    func clearWrapperDenial(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.clearWrapperDenial(request) { response in finish(.success(response)) }
        }
    }

    func perfStatistics(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.perfStatistics(request) { response in finish(.success(response)) }
        }
    }

    func frameStatistics(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.frameStatistics(request) { response in finish(.success(response)) }
        }
    }

    func pushClipboard(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.pushClipboard(request) { response in finish(.success(response)) }
        }
    }

    func clipboardWritten(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.clipboardWritten(request) { response in finish(.success(response)) }
        }
    }

    func focusChanged(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.focusChanged(request) { response in finish(.success(response)) }
        }
    }

    func integrationStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.integrationStatus(request) { response in finish(.success(response)) }
        }
    }

    func checkForUpdates(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.checkForUpdates(request) { response in finish(.success(response)) }
        }
    }

    func listUpdates(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.listUpdates(request) { response in finish(.success(response)) }
        }
    }

    func updateHistory(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.updateHistory(request) { response in finish(.success(response)) }
        }
    }

    func setUpdatePolicy(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.setUpdatePolicy(request) { response in finish(.success(response)) }
        }
    }

    func setUpdateAuthority(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.setUpdateAuthority(request) { response in finish(.success(response)) }
        }
    }

    func beginRepairPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.beginRepairPackage(request) { response in finish(.success(response)) }
        }
    }

    func rollbackPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.rollbackPackage(request) { response in finish(.success(response)) }
        }
    }

    func updateSkipped(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.updateSkipped(request) { response in finish(.success(response)) }
        }
    }

    func updatePackage(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.updatePackage(request, files: files) { response in finish(.success(response)) }
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

    func getConfig(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.getConfig(request) { response in finish(.success(response)) }
        }
    }

    func setConfig(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    finish(.failure(Self.transportFailure(error)))
                } as? any RuntimeControlXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.setConfig(request) { response in finish(.success(response)) }
        }
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
