@preconcurrency import Foundation

/// The major and minor version used by RuntimeAPI compatibility checks.
public struct APIVersion: Codable, Comparable, Equatable, Sendable {
    /// Version 1.0 introduces the authenticated control endpoint; 1.1 adds Guest Agent status fields;
    /// 1.2 adds control-endpoint launch and terminate operations; 1.3 adds bounded endpoint admission;
    /// 1.4 adds package queries; 1.5 adds runtime reset; 1.6 adds one-request runtime restart;
    /// 1.7 adds daemon-backed package import and install; 1.8 adds asynchronous install handles
    /// and a pollable operation registry; 1.9 adds topic subscriptions and batched event delivery;
    /// 1.10 adds package install change events.
    public static let current = APIVersion(major: 1, minor: 10)

    /// The incompatible protocol generation.
    public let major: Int
    /// An additive change within the generation.
    public let minor: Int

    /// Creates a protocol version.
    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Orders versions by major generation, then by additive minor version.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major
    }
}

/// The kind of APKRun process requesting an XPC endpoint.
public enum RuntimeClientKind: String, Codable, Equatable, Sendable {
    /// APKRun.app.
    case app
    /// The menu bar app.
    case menuBar
    /// The `apkrun` command line tool.
    case cli
    /// The generic APKRun launcher.
    case launcher
    /// A generated wrapper launcher.
    case wrapper
}

/// A version and identity announcement sent to the public broker.
public struct RuntimeHelloRequest: Codable, Equatable, Sendable {
    /// The client class used to choose the capability endpoint.
    public let clientKind: RuntimeClientKind
    /// The client's bundle or code identifier. This claim does not authorize access.
    public let claimedIdentity: String
    /// The client's RuntimeAPI version.
    public let apiVersion: APIVersion
    /// The client marketing version, when present.
    public let clientVersion: String?
    /// The client build number, when present.
    public let clientBuild: Int?

    /// Creates a broker hello request.
    public init(
        clientKind: RuntimeClientKind,
        claimedIdentity: String,
        apiVersion: APIVersion,
        clientVersion: String? = nil,
        clientBuild: Int? = nil
    ) {
        self.clientKind = clientKind
        self.claimedIdentity = claimedIdentity
        self.apiVersion = apiVersion
        self.clientVersion = clientVersion
        self.clientBuild = clientBuild
    }
}

/// The server facts returned by the broker before it grants an endpoint.
public struct RuntimeHelloReply: Codable, Equatable, Sendable {
    /// The APKRun marketing version.
    public let runtimeVersion: String
    /// The APKRun build number.
    public let runtimeBuild: Int
    /// The RuntimeAPI version implemented by the server.
    public let apiVersion: APIVersion
    /// The daemon state at the time of the request.
    public let hostState: String

    /// Creates a hello reply.
    public init(runtimeVersion: String, runtimeBuild: Int, apiVersion: APIVersion, hostState: String) {
        self.runtimeVersion = runtimeVersion
        self.runtimeBuild = runtimeBuild
        self.apiVersion = apiVersion
        self.hostState = hostState
    }
}

/// The first daemon version exposes only the authenticated control endpoint.
public enum RuntimeEndpointKind: String, Codable, Equatable, Sendable {
    /// APKRun.app, menu bar, CLI, and launcher control surface.
    case control
}

/// Requests one authenticated endpoint from the broker.
public struct RuntimeEndpointRequest: Codable, Equatable, Sendable {
    /// The endpoint requested.
    public let kind: RuntimeEndpointKind
    /// The client type, checked again on the endpoint request.
    public let clientKind: RuntimeClientKind
    /// The client's code identifier, used only to select an allowed endpoint.
    public let claimedIdentity: String
    /// The client's RuntimeAPI version.
    public let apiVersion: APIVersion

    /// Creates an endpoint request.
    public init(
        kind: RuntimeEndpointKind = .control,
        clientKind: RuntimeClientKind,
        claimedIdentity: String,
        apiVersion: APIVersion
    ) {
        self.kind = kind
        self.clientKind = clientKind
        self.claimedIdentity = claimedIdentity
        self.apiVersion = apiVersion
    }
}

/// A public broker rejection reason. The protected endpoint is the authorization boundary.
public enum RuntimeEndpointRejection: String, Codable, Equatable, Sendable {
    /// The broker does not serve this client identity.
    case unknownClient
    /// The endpoint request was malformed or unsupported.
    case malformedRequest
    /// The daemon is draining requests before shutdown.
    case hostShuttingDown
    /// The daemon has reached its control connection or request limit.
    case busy
    /// A newer broker returned a rejection reason this client does not know.
    case unknown

    /// Decodes known rejection reasons and preserves forward compatibility.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    /// Encodes a stable broker rejection reason.
    public func encode(to encoder: any Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown rejection reasons cannot be encoded.")
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The broker's JSON response; the endpoint travels in the adjacent XPC reply argument.
public enum RuntimeEndpointReply: Codable, Equatable, Sendable {
    /// The broker returned the requested protected endpoint.
    case granted
    /// No endpoint was returned.
    case rejected(RuntimeEndpointRejection)
}

/// The normalized state of the Guest Agent connection observed by the runtime host.
public enum GuestAgentConnectionState: String, Codable, Equatable, Sendable {
    /// The Guest Agent cannot exist yet because the runtime has not reached its connection phase.
    case notStarted
    /// The initial connection is being established.
    case connecting
    /// The Guest Agent is connected and synchronized.
    case connected
    /// The host is restoring a connection that was lost.
    case reconnecting
    /// The Guest Agent missed its keepalive responses.
    case unresponsive
    /// The Guest Agent cannot be reached and the host stopped retrying.
    case unavailable
    /// The Guest Agent's protocol version is incompatible with the host.
    case incompatible
    /// The host received a state added by a newer API version.
    case unknown

    /// Decodes an unrecognized state as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes this state using its normalized wire value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The RuntimeHost status snapshot served by the control endpoint.
public struct RuntimeHostStatus: Codable, Equatable, Sendable {
    /// `starting`, `running`, `degraded`, `shuttingDown`, or `stopped`.
    public let hostState: String
    /// `stopped`, `booting(<phase>)`, `ready`, `stopping`, or `failed`.
    public let runtimeState: String
    /// The estimated boot progress, from 0 to 0.95 while booting.
    public let bootProgress: Double?
    /// The startup step that failed, when the daemon is serving in a degraded state.
    public let startupFailureStep: Int?
    /// The stable error-catalog code for the degraded startup step.
    public let startupFailureCode: String?
    /// Whether recent daemon exits activate the automatic boot guard.
    public let crashLoopActive: Bool
    /// The current daemon process ID.
    public let daemonPID: Int32
    /// The installed image version, when available.
    public let imageVersion: String?
    /// The normalized Guest Agent state, or nil when this host cannot observe one.
    public let guestAgentState: GuestAgentConnectionState?
    /// The Guest Agent protocol version from its latest handshake, when available.
    public let guestAgentProtocolVersion: String?

    /// Creates a status snapshot.
    public init(
        hostState: String,
        runtimeState: String,
        bootProgress: Double?,
        startupFailureStep: Int?,
        startupFailureCode: String?,
        crashLoopActive: Bool,
        daemonPID: Int32,
        imageVersion: String?,
        guestAgentState: GuestAgentConnectionState? = nil,
        guestAgentProtocolVersion: String? = nil
    ) {
        self.hostState = hostState
        self.runtimeState = runtimeState
        self.bootProgress = bootProgress
        self.startupFailureStep = startupFailureStep
        self.startupFailureCode = startupFailureCode
        self.crashLoopActive = crashLoopActive
        self.daemonPID = daemonPID
        self.imageVersion = imageVersion
        self.guestAgentState = guestAgentState
        self.guestAgentProtocolVersion = guestAgentProtocolVersion
    }
}

/// Identifies and versions a control request.
public struct APIRequestHeader: Codable, Equatable, Sendable {
    /// The client's RuntimeAPI version.
    public let apiVersion: APIVersion
    /// A stable ID for log correlation.
    public let operationID: UUID
    /// The client identity established by its endpoint listener.
    public let clientKind: RuntimeClientKind

    /// Creates a request header.
    public init(
        apiVersion: APIVersion = .current,
        operationID: UUID = UUID(),
        clientKind: RuntimeClientKind
    ) {
        self.apiVersion = apiVersion
        self.operationID = operationID
        self.clientKind = clientKind
    }
}

/// A status request.
public struct RuntimeStatusRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a status request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// Starts Android on demand.
public struct StartRuntimeRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a start request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// Stops Android while leaving the daemon available.
public struct StopRuntimeRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a stop request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// Stops and starts Android within one authenticated control request.
public struct RestartRuntimeRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a runtime-restart request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// Clears the runtime failure and boot-loop guard through the authenticated control endpoint.
public struct RuntimeResetControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a runtime-reset request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// Starts an installed package session through the authenticated control endpoint.
public struct RuntimeLaunchControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The Android package to launch.
    public let packageID: RuntimePackageID

    /// Creates a launch request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID) {
        self.header = header
        self.packageID = packageID
    }
}

/// Terminates an installed package session through the authenticated control endpoint.
public struct RuntimeTerminateControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The Android package to terminate.
    public let packageID: RuntimePackageID

    /// Creates a terminate request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID) {
        self.header = header
        self.packageID = packageID
    }
}

/// Lists packages through the authenticated control endpoint.
public struct RuntimeListPackagesControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The package records to include.
    public let filter: RuntimePackageFilter

    /// Creates a package-list request.
    public init(header: APIRequestHeader, filter: RuntimePackageFilter = .managed) {
        self.header = header
        self.filter = filter
    }
}

/// Returns package details through the authenticated control endpoint.
public struct RuntimePackageInfoControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The Android package to inspect.
    public let packageID: RuntimePackageID

    /// Creates a package-info request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID) {
        self.header = header
        self.packageID = packageID
    }
}

/// Copies and inspects APK files through the authenticated control endpoint.
public struct RuntimeImportPackageControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The package files and import origin.
    public let request: RuntimeImportPackageRequest

    /// Creates a package-import request.
    public init(header: APIRequestHeader, request: RuntimeImportPackageRequest) {
        self.header = header
        self.request = request
    }
}

/// Installs a package import through the authenticated control endpoint.
public struct RuntimeInstallImportedControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The inspected package and installation options.
    public let request: RuntimeInstallImportedRequest

    /// Creates an imported-package install request.
    public init(header: APIRequestHeader, request: RuntimeInstallImportedRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or typed error returned by a control launch request.
public struct RuntimeLaunchControlReply: Codable, Equatable, Sendable {
    /// The launched session result, present on success.
    public let result: RuntimeLaunchResult?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeLaunchResult) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a control package-import request.
public struct RuntimeImportPackageControlReply: Codable, Equatable, Sendable {
    /// The inspected package preview, present on success.
    public let result: RuntimeImportPreview?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeImportPreview) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a control package-install request.
public struct RuntimeInstallImportedControlReply: Codable, Equatable, Sendable {
    /// The installed package summary, present on success.
    public let result: RuntimePackageSummary?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimePackageSummary) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a control terminate request.
public struct RuntimeTerminateControlReply: Codable, Equatable, Sendable {
    /// The termination result, present on success.
    public let result: RuntimeTerminateResult?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeTerminateResult) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a control package-list request.
public struct RuntimeListPackagesControlReply: Codable, Equatable, Sendable {
    /// The package inventory, present on success.
    public let result: RuntimePackageListResult?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimePackageListResult) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a control package-info request.
public struct RuntimePackageInfoControlReply: Codable, Equatable, Sendable {
    /// The package details, present on success.
    public let result: RuntimePackageDetails?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimePackageDetails) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// A safe, catalog-backed error summary for the first control operations.
public struct RuntimeControlError: Codable, Equatable, Sendable {
    /// The qualified error-catalog code.
    public let code: String
    /// A short user-facing summary.
    public let message: String

    /// Creates a control error.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A control endpoint reply. Exactly one of `status` and `error` is present.
public struct RuntimeControlReply: Codable, Equatable, Sendable {
    /// The runtime snapshot for a successful operation.
    public let status: RuntimeHostStatus?
    /// A safe error summary for a rejected or failed operation.
    public let error: RuntimeControlError?

    /// Creates a successful control reply.
    public init(status: RuntimeHostStatus) {
        self.status = status
        error = nil
    }

    /// Creates an error control reply.
    public init(error: RuntimeControlError) {
        status = nil
        self.error = error
    }
}

/// The public broker interface. It does not expose runtime capabilities.
@objc public protocol RuntimeBrokerXPC {
    /// Identifies the daemon without rejecting a version mismatch.
    func hello(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns only an anonymous endpoint protected by a code-signing requirement.
    func requestEndpoint(_ request: Data, reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void)
}

/// Authenticated control endpoint operations implemented by apkrund.
@objc public protocol RuntimeControlXPC {
    /// Returns runtime and daemon status.
    func runtimeStatus(_ request: Data, reply: @escaping (Data) -> Void)
    /// Starts Android and waits for it to become ready.
    func startRuntime(_ request: Data, reply: @escaping (Data) -> Void)
    /// Stops Android but leaves the daemon running.
    func stopRuntime(_ request: Data, reply: @escaping (Data) -> Void)
    /// Restarts Android in one request and returns its final runtime status.
    func restartRuntime(_ request: Data, reply: @escaping (Data) -> Void)
    /// Clears a runtime failure and boot-loop guard without deleting Android data.
    func resetRuntime(_ request: Data, reply: @escaping (Data) -> Void)
    /// Lists managed or all known packages.
    func listPackages(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns details for one package.
    func packageInfo(_ request: Data, reply: @escaping (Data) -> Void)
    /// Copies and inspects APK files without starting Android.
    func importPackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
    /// Starts installation and returns an operation handle without waiting for installation to finish.
    func beginInstallImported(_ request: Data, reply: @escaping (Data) -> Void)
    /// Requests cancellation at the operation's next cancellation point, if it is still cancellable.
    func cancelOperation(_ request: Data, reply: @escaping (Data) -> Void)
    /// Lists running operations and recently finished operations retained by the daemon.
    func listOperations(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns the latest snapshot for one operation, or a typed not-found error.
    func operationStatus(_ request: Data, reply: @escaping (Data) -> Void)
    /// Subscribes this connection to the requested topics.
    func subscribe(_ request: Data, reply: @escaping (Data) -> Void)
    /// Removes this connection's subscriptions to the requested topics.
    func unsubscribe(_ request: Data, reply: @escaping (Data) -> Void)
    /// Installs a previously inspected import synchronously.
    func installImported(_ request: Data, reply: @escaping (Data) -> Void)
    /// Launches an installed package session.
    func launch(_ request: Data, reply: @escaping (Data) -> Void)
    /// Terminates an installed package session.
    func terminate(_ request: Data, reply: @escaping (Data) -> Void)
}

/// Client-exported callback for event batches from the authenticated control endpoint.
@objc public protocol RuntimeEventSink {
    /// Confirms that the client exported an event receiver on this connection.
    func handshake(reply: @escaping (Bool) -> Void)
    /// Delivers a JSON array of event envelopes. The client replies after decoding the batch.
    func deliver(_ batch: Data, reply: @escaping () -> Void)
}

/// Runtime package operations. Package identity is resolved by the runtime before launch.
public protocol RuntimePackageService: Sendable {
    /// Copies and inspects APK files, returning a preview ticket without starting Android.
    func importPackage(
        _ request: RuntimeImportPackageRequest,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> RuntimeImportPreview

    /// Installs a previously inspected import into Android through the runtime's package channel.
    func installImported(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary

    /// Uninstalls a package and applies the requested Android-data policy.
    func uninstallPackage(
        _ request: RuntimeUninstallPackageRequest
    ) async throws(RuntimeWireError)

    /// Lists the most recently reconciled packages. This may work while Android is stopped.
    func listPackages(
        _ request: RuntimeListPackagesRequest
    ) async throws(RuntimeWireError) -> RuntimePackageListResult

    /// Returns the package record and the Android facts known to the host.
    func packageInfo(
        _ request: RuntimePackageRequest
    ) async throws(RuntimeWireError) -> RuntimePackageDetails
}

/// Runtime session operations. Package identity is resolved by the runtime before launch.
public protocol RuntimeSessionService: Sendable {
    /// Starts an application session and returns its initial runtime state.
    func launch(
        _ request: RuntimeLaunchRequest
    ) async throws(RuntimeWireError) -> RuntimeLaunchResult

    /// Ends the application's session and asks Android to stop its tasks.
    func terminate(
        _ request: RuntimeTerminateRequest
    ) async throws(RuntimeWireError) -> RuntimeTerminateResult
}

/// The package and application session operations shared by embedded and daemon clients.
public protocol RuntimeService: RuntimePackageService, RuntimeSessionService {}
