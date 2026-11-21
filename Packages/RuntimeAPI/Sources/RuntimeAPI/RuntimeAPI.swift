@preconcurrency import Foundation

/// The major and minor version used by RuntimeAPI compatibility checks.
public struct APIVersion: Codable, Comparable, Equatable, Sendable {
    /// 1.12 adds the createWrapper long operation, the wrappers event topic, and WrapperInfo;
    /// 1.13 adds approval prompts and decisions, denied wrappers, and broker requestApproval;
    /// 1.14 adds `perfStatistics`, `frameStatistics`, and `RuntimeLaunchRequest.launchTiming`;
    /// 1.15 adds the gentle-update session rules and `update` package changes;
    /// 1.16 adds update ownership and rollback surfaces;
    /// 1.17 adds the `iconChanged` package change (package-store.md §10.2);
    /// 1.18 adds `placeStagedWrapper` for TCC-protected destinations (wrapper.md §6.3);
    /// 1.19 adds `wrapperInfo` (runtime-api.md §10.2).
    /// 1.20 adds `listWrappers`, `removeWrapper`, and `rescanWrappers`
    /// (runtime-api.md §10.5).
    /// 1.21 adds `refreshWrapper` and `refreshAllWrappers` (wrapper.md §9.3).
    /// 1.22 adds `repairPackage` (package-store.md §11.1).
    /// 1.23 adds `listSessions`, `packageIcon`, and `sessions` topic events
    /// (host-ui.md §5.2–§5.3).
    /// 1.24 adds `packageSettings` and `updatePackageSettings` (host-ui.md §7).
    /// 1.25 adds `RuntimePackageDetails.previous`; 1.26 adds the wrapper
    /// endpoint's `importBootstrap` (wrapper-json.md §3.4).
    /// 1.27 adds the notification relays and host notifications
    /// (runtime-api.md §11.3); 1.28 adds `linkPrompt` and
    /// `resolveLinkPrompt` (runtime-api.md §11.2).
    /// 1.29 adds the shared-folder and file operations of §11; 1.30 adds
    /// `SettingApplies` on `updateGlobalConfiguration` (desktop-integration.md
    /// §9). 1.31 adds `selfUpdateStatus` and `noteSelfUpdateStatus`
    /// (runtime-api.md §12.2).
    public static let current = APIVersion(major: 1, minor: 32)

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
    /// The frozen maintenance endpoint (runtime-api.md §12.1): available in
    /// every host state so any two APKRun builds can coordinate an update.
    case maintenance
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
    /// The first-run provisioning state (runtime-daemon.md §9.2). Decoding an older
    /// daemon's reply leaves this nil; clients treat nil as `.notStarted`.
    public let provisioning: WireProvisioningState?

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
        guestAgentProtocolVersion: String? = nil,
        provisioning: WireProvisioningState? = nil
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
        self.provisioning = provisioning
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
    /// The launcher's own stamps for `WRAPPER_PROCESS_START`/`APP_LAUNCH_REQUEST`
    /// in continuous-clock nanoseconds (diagnostics.md §4.2).
    public var launchTiming: LaunchTiming?

    /// Creates a launch request.
    public init(
        header: APIRequestHeader,
        packageID: RuntimePackageID,
        launchTiming: LaunchTiming? = nil
    ) {
        self.header = header
        self.packageID = packageID
        self.launchTiming = launchTiming
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

/// Drops an import ticket through the authenticated control endpoint.
public struct RuntimeDiscardImportControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The ticket to discard.
    public let request: RuntimeDiscardImportRequest

    /// Creates a discard request.
    public init(header: APIRequestHeader, request: RuntimeDiscardImportRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or typed error returned by a control discard-import request.
public struct RuntimeDiscardImportControlReply: Codable, Equatable, Sendable {
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init() {
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        self.error = error
    }
}

/// Adopts an unmanaged Android package through the authenticated control endpoint.
public struct RuntimeAdoptPackageControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The package to adopt.
    public let request: RuntimeAdoptPackageRequest

    /// Creates an adopt request.
    public init(header: APIRequestHeader, request: RuntimeAdoptPackageRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or typed error returned by a control adopt-package request.
public struct RuntimeAdoptPackageControlReply: Codable, Equatable, Sendable {
    /// The adopted package summary, present on success.
    public let summary: RuntimePackageSummary?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(summary: RuntimePackageSummary) {
        self.summary = summary
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        summary = nil
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

/// Returns the composed Mac icon of one package (host-ui.md §5.3).
public struct RuntimePackageIconControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The Android package whose icon is requested.
    public let packageID: RuntimePackageID

    /// Creates a package-icon request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID) {
        self.header = header
        self.packageID = packageID
    }
}

/// The result or typed error returned by a control package-icon request.
public struct RuntimePackageIconControlReply: Codable, Equatable, Sendable {
    /// The icon PNG bytes, present when the package has an icon.
    public let png: Data?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a reply.
    public init(png: Data? = nil, error: RuntimeWireError? = nil) {
        self.png = png
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
    /// Catalog parameters a client needs to finish a deferred step, such as
    /// `stagingToken` on `wrapper.destinationNotAccessible` (wrapper.md §6.3).
    public let parameters: [String: String]

    /// Creates a control error.
    public init(code: String, message: String, parameters: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.parameters = parameters
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
    /// Asks the user to approve an unknown wrapper (wrapper.md §7.3).
    func requestApproval(_ request: Data, reply: @escaping (Data) -> Void)
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
    /// Returns the effective global configuration.
    func configuration(_ request: Data, reply: @escaping (Data) -> Void)
    /// Validates and applies a global configuration merge patch.
    func updateConfiguration(_ request: Data, reply: @escaping (Data) -> Void)
    /// Starts or resumes first-run provisioning and returns its operation handle.
    func setup(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
    /// Resets Android data: backup, delete, re-provision, reinstall managed packages.
    func resetAndroid(_ request: Data, reply: @escaping (Data) -> Void)
    /// Lists managed or all known packages.
    func listPackages(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns details for one package.
    func packageInfo(_ request: Data, reply: @escaping (Data) -> Void)
    /// Lists the live app sessions (host-ui.md §5.2).
    func listSessions(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns the composed Mac icon PNG of one package (host-ui.md §5.3).
    func packageIcon(_ request: Data, reply: @escaping (Data) -> Void)
    /// Copies and inspects APK files without starting Android.
    func importPackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
    /// Starts installation and returns an operation handle without waiting for installation to finish.
    func beginInstallImported(_ request: Data, reply: @escaping (Data) -> Void)
    /// Starts a package uninstall or store forget and returns its operation handle.
    func beginUninstallPackage(_ request: Data, reply: @escaping (Data) -> Void)
    /// Requests cancellation at the operation's next cancellation point, if it is still cancellable.
    func cancelOperation(_ request: Data, reply: @escaping (Data) -> Void)
    /// Lists running operations and recently finished operations retained by the daemon.
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
    /// Drops an import ticket and its private APK copies (runtime-api.md §10).
    func discardImport(_ request: Data, reply: @escaping (Data) -> Void)
    /// Adopts a package Android has but APKRun does not manage (package-store.md §9.3).
    func adoptPackage(_ request: Data, reply: @escaping (Data) -> Void)
    /// Launches an installed package session.
    func launch(_ request: Data, reply: @escaping (Data) -> Void)
    /// Terminates an installed package session.
    func terminate(_ request: Data, reply: @escaping (Data) -> Void)
    /// Checks a wrapper bundle against the registry and the store.
    func verifyWrapper(_ request: Data, reply: @escaping (Data) -> Void)
    /// Starts a wrapper generation; replies with the operation handle.
    func createWrapper(_ request: Data, icon: FileHandle?, reply: @escaping (Data) -> Void)

    /// Completes a staged wrapper placement (wrapper.md §6.3).
    func placeStagedWrapper(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns the registry row of one package's wrapper (runtime-api.md §10.2).
    func wrapperInfo(_ request: Data, reply: @escaping (Data) -> Void)

    /// Lists every registered wrapper with the status the validator
    /// computed (wrapper.md §9.1). Reply: `RuntimeWrapperListControlReply`.
    func listWrappers(_ request: Data, reply: @escaping (Data) -> Void)

    /// Removes a wrapper's registry entry, optionally trashing the bundle
    /// (wrapper.md §9.5). Reply: `RuntimeRemoveWrapperControlReply`.
    func removeWrapper(_ request: Data, reply: @escaping (Data) -> Void)

    /// Scans the Applications folders for APKRun wrapper bundles
    /// (wrapper.md §7.2). Reply: `RuntimeRescanWrappersControlReply`.
    func rescanWrappers(_ request: Data, reply: @escaping (Data) -> Void)

    /// Starts a wrapper refresh (wrapper.md §9.3); replies with the
    /// operation handle. An icon file handle accompanies `change.icon`.
    func refreshWrapper(_ request: Data, icon: FileHandle?, reply: @escaping (Data) -> Void)
    /// Installs the embedded bootstrap package of an approved portable wrapper;
    /// one file handle per `files` item of bootstrap.json (wrapper-json.md §3.4).
    func importBootstrap(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)

    /// Starts a batch refresh (wrapper.md §9.4 Update All Mac Apps);
    /// replies with the operation handle.
    func refreshAllWrappers(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns the approval prompts waiting for APKRun.app.
    func pendingApprovals(_ request: Data, reply: @escaping (Data) -> Void)
    /// Answers an approval prompt (APKRun.app only).
    func decideApproval(_ request: Data, reply: @escaping (Data) -> Void)
    /// Lists wrappers the user denied (Settings → Privacy).
    func deniedWrappers(_ request: Data, reply: @escaping (Data) -> Void)
    /// Removes a denied entry (Settings → Privacy → Remove).
    func clearWrapperDenial(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns host-side performance statistics; developer mode only (diagnostics.md §9.3).
    func perfStatistics(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns per-session graphics statistics; developer mode only; never starts Android.
    func frameStatistics(_ request: Data, reply: @escaping (Data) -> Void)
    /// Pushes a Mac clip toward Android; the reply carries the acknowledged seq (runtime-api.md §11.2).
    func pushClipboard(_ request: Data, reply: @escaping (Data) -> Void)
    /// Reports that the window wrote a guest clip to the Mac pasteboard (runtime-api.md §11.2).
    func clipboardWritten(_ request: Data, reply: @escaping (Data) -> Void)
    /// Reports whether the session's window is the key window (desktop-integration.md §4.1).
    func focusChanged(_ request: Data, reply: @escaping (Data) -> Void)
    /// Answers a link prompt for the session's key window (runtime-api.md §11.2).
    func resolveLinkPrompt(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns the per-kind integration status of a package (runtime-api.md §11).
    func integrationStatus(_ request: Data, reply: @escaping (Data) -> Void)
    /// Imports files the user dropped on the session's window into Android
    /// (runtime-api.md §11.2, desktop-integration.md §6.2). The open
    /// `FileHandle`s travel beside the request, indexed by `fileIndex`.
    func importFiles(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
    /// Answers a "Save to Mac" offer for the session's window
    /// (runtime-api.md §11.2, desktop-integration.md §6.3). Zero or one
    /// `FileHandle` (the picked file, open for writing); none is the cancel.
    func acceptExport(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
    /// Lists the shared-folder roots (runtime-api.md §11.1). Reply:
    /// `RuntimeSharedFoldersControlReply`.
    func sharedFolders(_ request: Data, reply: @escaping (Data) -> Void)
    /// Adds a shared-folder root from a security bookmark (runtime-api.md
    /// §11.1). Reply: `RuntimeSharedFolderControlReply`.
    func addSharedFolder(_ request: Data, reply: @escaping (Data) -> Void)
    /// Removes a shared-folder root (runtime-api.md §11.1). Reply:
    /// `RuntimeRemoveSharedFolderControlReply`.
    func removeSharedFolder(_ request: Data, reply: @escaping (Data) -> Void)
    /// Changes a root's maximum access (runtime-api.md §11.1). Reply:
    /// `RuntimeSharedFolderControlReply`.
    func setSharedFolderAccess(_ request: Data, reply: @escaping (Data) -> Void)
    /// Checks packages for updates (runtime-api.md §9.1).
    func checkForUpdates(_ request: Data, reply: @escaping (Data) -> Void)
    /// Lists per-package update state (runtime-api.md §9.1).
    func listUpdates(_ request: Data, reply: @escaping (Data) -> Void)
    /// Reads update history (runtime-api.md §9.1, update-system.md §10.2).
    func updateHistory(_ request: Data, reply: @escaping (Data) -> Void)
    /// Returns the package's stored `settings.json` groups (host-ui.md §7).
    /// Reply: `RuntimePackageSettingsControlReply`.
    func packageSettings(_ request: Data, reply: @escaping (Data) -> Void)
    /// Applies a `settings.json` patch and returns the stored settings
    /// (host-ui.md §7). Reply: `RuntimeUpdatePackageSettingsControlReply`.
    func updatePackageSettings(_ request: Data, reply: @escaping (Data) -> Void)
    /// Sets a package's update mode and provider (runtime-api.md §9.1).
    func setUpdatePolicy(_ request: Data, reply: @escaping (Data) -> Void)
    /// Sets a package's update authority (runtime-api.md §9.1, update-system.md §2.1).
    func setUpdateAuthority(_ request: Data, reply: @escaping (Data) -> Void)
    /// Rolls a package back to `previous/` (update-system.md §8.5).
    func rollbackPackage(_ request: Data, reply: @escaping (Data) -> Void)
    /// Reads `updates.*` settings (configuration.md §2.7).
    func getConfig(_ request: Data, reply: @escaping (Data) -> Void)
    /// Writes one `updates.*` setting (configuration.md §2.7).
    func setConfig(_ request: Data, reply: @escaping (Data) -> Void)
    /// The self-update probe snapshot (runtime-api.md §12.2). Reply:
    /// `SelfUpdateStatusReply`.
    func selfUpdateStatus(_ request: Data, reply: @escaping (Data) -> Void)
    /// APKRun.app reports Sparkle's result (runtime-api.md §12.2). Reply:
    /// `RuntimeEmptyReply`.
    func noteSelfUpdateStatus(_ request: Data, reply: @escaping (Data) -> Void)
    /// Runs the self-update probe (runtime-api.md §12.2). Reply:
    /// `SelfUpdateStatusReply`.
    func checkSelfUpdate(_ request: Data, reply: @escaping (Data) -> Void)
    /// Adds or removes a version on the package's skip list (§8.4).
    func updateSkipped(_ request: Data, reply: @escaping (Data) -> Void)
    /// Checks and installs a package update now, optionally from files
    /// (runtime-api.md §9.1). File handles travel like `importPackage`.
    func updatePackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
    /// Starts reinstalling a broken package from its retained artifacts
    /// (package-store.md §11.1, runtime-api.md §8.4).
    func beginRepairPackage(_ request: Data, reply: @escaping (Data) -> Void)
    /// Opens a `notificationRelay` stream (wrapper connections only,
    /// runtime-api.md §11.3/§16.4). Reply: `RuntimeStreamHandleControlReply`.
    func notificationRelay(_ request: Data, reply: @escaping (Data) -> Void)
    /// Delivers a `RelayResponse` on an open notification relay stream
    /// (runtime-api.md §11.3). Reply: `RuntimeStreamControlReply`.
    func notificationRelayResponse(_ request: Data, reply: @escaping (Data) -> Void)
    /// Opens the single `hostNotifications` stream (APKRun.app only,
    /// runtime-api.md §11.3/§16.4). Reply: `RuntimeStreamHandleControlReply`.
    func hostNotifications(_ request: Data, reply: @escaping (Data) -> Void)
    /// Delivers a `HostNotificationResponse` on the host notifications stream
    /// (runtime-api.md §11.3). Reply: `RuntimeStreamControlReply`.
    func hostNotificationResponse(_ request: Data, reply: @escaping (Data) -> Void)
    /// Closes one of this connection's streams; idempotent
    /// (runtime-api.md §16.4). Reply: `RuntimeStreamControlReply`.
    func closeStream(_ request: Data, reply: @escaping (Data) -> Void)
    /// Installs an Android image from an `.aar` file (runtime-maintenance.md
    /// §4.7). Reply: `WireImageInstallReply`.
    func installImage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
    /// The image update status (`apkrun image list`). Reply: `WireImageStatusReply`.
    func imageStatus(_ request: Data, reply: @escaping (Data) -> Void)
    /// Applies a `ready` image (`apkrun image apply` / the UI apply gate).
    /// Reply: `WireImageApplyReply`.
    func applyImage(_ request: Data, reply: @escaping (Data) -> Void)
    /// Goes back to the previous image (`apkrun image rollback`).
    /// Reply: `WireImageApplyReply`.
    func rollbackImage(_ request: Data, reply: @escaping (Data) -> Void)
    /// Deletes a recovery point (`apkrun image recovery-points delete`).
    /// Reply: `WireImageApplyReply`.
    func deleteImageRecoveryPoint(_ request: Data, reply: @escaping (Data) -> Void)
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

    /// Drops an import ticket and its private APK copies without starting Android.
    func discardImport(
        _ request: RuntimeDiscardImportRequest
    ) async throws(RuntimeWireError)

    /// Adopts a package Android has but APKRun does not manage (package-store.md §9.3).
    ///
    /// The record gets `installer: external`, `updateAuthority: external`, no artifact, and
    /// `source: adopted`. Requires a running runtime so Android's facts can be read.
    func adoptPackage(
        _ request: RuntimeAdoptPackageRequest
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

/// Frozen maintenance endpoint implemented by apkrund (runtime-api.md §12.1).
///
/// One envelope method carries every maintenance operation so the endpoint
/// stays additive-only: new operations extend `MaintenanceControlOperation`
/// inside `MaintenanceControlRequest` without a new XPC selector. The server
/// ignores the request header's API version and answers in every host state.
@objc public protocol RuntimeMaintenanceXPC {
    /// Performs a maintenance control operation.
    func perform(_ request: Data, reply: @escaping (Data) -> Void)
}
