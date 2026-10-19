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

    private let configuration: RuntimeControlClientConfiguration
    private let connectionFactory: any RuntimeXPCConnectionFactory
    private var openedControl: OpenedControlConnection?
    private var openingControl: Task<OpenedControlConnection, any Error>?

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
    }

    init(
        configuration: RuntimeControlClientConfiguration,
        connectionFactory: any RuntimeXPCConnectionFactory
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
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

    private func makeHeader() -> APIRequestHeader {
        APIRequestHeader(clientKind: configuration.clientKind)
    }

    private func invalidateAfterTransportFailure(
        _ failedChannel: any RuntimeControlChannel,
        error: RuntimeControlClientError
    ) {
        let shouldInvalidate: Bool
        switch error {
        case .transportFailure, .requestTimedOut, .requestCancelled:
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
        openedControl.channel.invalidate()
        self.openedControl = nil
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
            return openedControl
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
            openedControl = opened
            openingControl = nil
            return opened
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
                signingRequirement: configuration.daemonCodeSigningRequirement
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
    func startRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func stopRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func restartRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func resetRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func listPackages(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func packageInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func launch(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func terminate(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func invalidate()
}

extension RuntimeControlChannel {
    func invalidate() {}
}

protocol RuntimeXPCConnectionFactory: Sendable {
    func makeBroker(
        serviceName: String,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeBrokerChannel
    func makeControl(
        endpoint: RuntimeXPCListenerEndpoint,
        signingRequirement: String
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
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeControlChannel {
        guard let listenerEndpoint = endpoint.value as? NSXPCListenerEndpoint else {
            throw .malformedReply
        }
        let connection = configuredConnection(
            NSXPCConnection(listenerEndpoint: listenerEndpoint),
            interface: NSXPCInterface(with: RuntimeControlXPC.self),
            signingRequirement: signingRequirement
        )
        return XPCControlChannel(connection: connection)
    }

    private func configuredConnection(
        _ connection: NSXPCConnection,
        interface: NSXPCInterface,
        signingRequirement: String
    ) -> NSXPCConnection {
        connection.remoteObjectInterface = interface
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

    private static func transportFailure(_ error: any Error) -> RuntimeControlClientError {
        let error = error as NSError
        return .transportFailure(domain: error.domain, code: error.code)
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
