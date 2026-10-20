import Foundation

/// A random identifier for one user-visible or daemon-owned operation.
///
/// Its wire form is a canonical lowercase UUID v4 string. Operation IDs are stable across client
/// reconnections so the operation can be polled or cancelled after the original request returns.
public struct OperationID: Codable, Equatable, Hashable, Sendable {
    /// The UUID value represented by this identifier.
    public let rawValue: UUID

    /// Creates a fresh UUID v4 operation identifier.
    public init() {
        rawValue = UUID()
    }

    /// Creates an identifier from a UUID v4 value.
    public init?(rawValue: UUID) {
        guard Self.isUUIDv4(rawValue.uuidString.lowercased()) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Parses a canonical lowercase UUID v4 wire value.
    public init?(wire: String) {
        let bytes = Array(wire.utf8)
        guard bytes.count == 36,
            let uuid = UUID(uuidString: wire),
            uuid.uuidString.lowercased() == wire,
            Self.isUUIDv4(wire)
        else {
            return nil
        }
        rawValue = uuid
    }

    /// The canonical lowercase UUID string used on the wire.
    public var wireValue: String {
        rawValue.uuidString.lowercased()
    }

    /// Decodes a canonical lowercase UUID v4 string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let operationID = Self(wire: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Operation ID must be a canonical lowercase UUID v4."
            )
        }
        self = operationID
    }

    /// Encodes the identifier as its canonical lowercase UUID string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    private static func isUUIDv4(_ wire: String) -> Bool {
        let bytes = Array(wire.utf8)
        return bytes.count == 36
            && bytes[14] == 52
            && [56, 57, 97, 98].contains(bytes[19])
    }
}

/// The supported kinds of long-running operations.
public enum OperationKind: String, Codable, Equatable, Sendable {
    /// Copies and inspects APK files.
    case `import`
    /// Inspects an imported package without installing it.
    case inspect
    /// Installs a previously inspected APK set in Android.
    case install
    /// Removes an installed package.
    case uninstall
    /// Repairs a managed package.
    case repair
    /// Restores the previous package version.
    case rollback
    /// Applies a package update.
    case update
    /// Checks for a package update.
    case updateCheck
    /// Creates an app wrapper.
    case wrapperCreate
    /// Refreshes one app wrapper.
    case wrapperRefresh
    /// Refreshes a batch of app wrappers.
    case wrapperRefreshAll
    /// Creates a distribution wrapper.
    case distributionWrapper
    /// Imports the bootstrap package.
    case bootstrapImport
    /// Sets up or repairs the runtime.
    case setup
    /// Resets Android data.
    case resetAndroid
    /// Stops Android as a tracked operation.
    case runtimeStop
    /// Restarts Android as a tracked operation.
    case runtimeRestart
    /// Checks for an Android image update.
    case imageCheck
    /// Downloads an Android image.
    case imageDownload
    /// Installs an Android image.
    case imageInstall
    /// Applies an Android image update.
    case imageApply
    /// Rolls back an Android image update.
    case imageRollback
    /// Collects diagnostics.
    case diagnostics
    /// The daemon reported an operation kind added by a newer API version.
    case unknown

    /// Decodes a known operation kind, preserving unknown future kinds.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    /// Encodes a stable operation kind.
    public func encode(to encoder: any Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown operation kinds cannot be encoded.")
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A stable reference to an operation that survives its initiating XPC request.
public struct OperationHandle: Codable, Equatable, Sendable {
    /// The operation ID supplied by the initiating request.
    public let operationID: OperationID
    /// The parent operation, when this operation was started as a sub-operation.
    public let parent: OperationID?
    /// The kind of work represented by this handle.
    public let kind: OperationKind

    /// Creates an operation handle.
    public init(operationID: OperationID, parent: OperationID? = nil, kind: OperationKind) {
        self.operationID = operationID
        self.parent = parent
        self.kind = kind
    }
}

/// Current progress for a long-running operation.
public struct OperationProgress: Codable, Equatable, Sendable {
    /// Completion fraction from 0 through 1, or `nil` when the operation is indeterminate.
    public let fraction: Double?
    /// The current stage, when the operation has a named stage.
    public let stage: String?
    /// Bytes processed so far, when the operation reports byte progress.
    public let bytes: Int64?
    /// Total bytes expected, when known.
    public let totalBytes: Int64?
    /// A short user-facing progress message.
    public let message: String?

    /// Creates an operation progress snapshot.
    public init(
        fraction: Double? = nil,
        stage: String? = nil,
        bytes: Int64? = nil,
        totalBytes: Int64? = nil,
        message: String? = nil
    ) {
        self.fraction = fraction
        self.stage = stage
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.message = message
    }
}

/// The output value retained when an operation succeeds.
public enum OperationOutput: Codable, Equatable, Sendable {
    /// The operation has no output beyond its success.
    case none
    /// The package installed by the operation.
    case package(RuntimePackageSummary)
    /// The daemon returned an output type added by a newer API version.
    case unknown

    /// Decodes known outputs and maps a future output case to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OperationDynamicCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one operation output case.")
            )
        }
        switch key.stringValue {
        case "none":
            self = .none
        case "package":
            let payload = try container.nestedContainer(keyedBy: OperationDynamicCodingKey.self, forKey: key)
            self = .package(
                try payload.decode(
                    RuntimePackageSummary.self,
                    forKey: OperationDynamicCodingKey(stringValue: "_0")
                ))
        default:
            self = .unknown
        }
    }

    /// Encodes a stable operation output.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: OperationDynamicCodingKey.self)
        switch self {
        case .none:
            _ = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "none")
            )
        case .package(let summary):
            var payload = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "package")
            )
            try payload.encode(summary, forKey: OperationDynamicCodingKey(stringValue: "_0"))
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown operation outputs cannot be encoded.")
            )
        }
    }
}

/// The terminal outcome of a long-running operation.
public enum OperationResult: Codable, Equatable, Sendable {
    /// The operation completed successfully.
    case succeeded(OperationOutput)
    /// The operation failed with a structured error.
    case failed(RuntimeWireError)
    /// The operation stopped at a supported cancellation point.
    case cancelled
    /// The daemon cannot establish the outcome, or the reply contains a future result case.
    case unknown

    /// Decodes known outcomes and maps a future result case to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OperationDynamicCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one operation result case.")
            )
        }
        switch key.stringValue {
        case "succeeded":
            let payload = try container.nestedContainer(keyedBy: OperationDynamicCodingKey.self, forKey: key)
            self = .succeeded(
                try payload.decode(
                    OperationOutput.self,
                    forKey: OperationDynamicCodingKey(stringValue: "_0")
                ))
        case "failed":
            let payload = try container.nestedContainer(keyedBy: OperationDynamicCodingKey.self, forKey: key)
            self = .failed(
                try payload.decode(
                    RuntimeWireError.self,
                    forKey: OperationDynamicCodingKey(stringValue: "_0")
                ))
        case "cancelled":
            self = .cancelled
        case "unknown":
            self = .unknown
        default:
            self = .unknown
        }
    }

    /// Encodes a stable operation result.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: OperationDynamicCodingKey.self)
        switch self {
        case .succeeded(let output):
            var payload = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "succeeded")
            )
            try payload.encode(output, forKey: OperationDynamicCodingKey(stringValue: "_0"))
        case .failed(let error):
            var payload = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "failed")
            )
            try payload.encode(error, forKey: OperationDynamicCodingKey(stringValue: "_0"))
        case .cancelled:
            _ = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "cancelled")
            )
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "unknown")
            )
        }
    }
}

/// A pollable operation state returned by `listOperations` and `operationStatus`.
public struct OperationSnapshot: Codable, Equatable, Sendable {
    /// The stable operation identifier.
    public let operationID: OperationID
    /// The parent operation, when this is a sub-operation.
    public let parent: OperationID?
    /// The operation kind.
    public let kind: OperationKind
    /// The affected Android package, when known.
    public let packageID: RuntimePackageID?
    /// SHA-256 of the canonical request payload, used to reconcile ambiguous begin replies.
    public let requestFingerprint: String?
    /// The client that started this operation, or `nil` for daemon-owned work.
    public let clientKind: RuntimeClientKind?
    /// When the operation began.
    public let startedAt: Date
    /// The latest progress, or `nil` when progress has not been reported.
    public let progress: OperationProgress?
    /// The terminal result, or `nil` while the operation is running.
    public let result: OperationResult?
    /// When the operation finished, or `nil` while it is running.
    public let finishedAt: Date?

    /// Creates an operation snapshot.
    public init(
        operationID: OperationID,
        parent: OperationID? = nil,
        kind: OperationKind,
        packageID: RuntimePackageID? = nil,
        requestFingerprint: String? = nil,
        clientKind: RuntimeClientKind? = nil,
        startedAt: Date,
        progress: OperationProgress? = nil,
        result: OperationResult? = nil,
        finishedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.parent = parent
        self.kind = kind
        self.packageID = packageID
        self.requestFingerprint = requestFingerprint
        self.clientKind = clientKind
        self.startedAt = startedAt
        self.progress = progress
        self.result = result
        self.finishedAt = finishedAt
    }
}

/// The reply to a cancellation request.
public enum CancelReply: Codable, Equatable, Sendable {
    /// Cancellation was requested and will take effect at the next cancellation point.
    case cancelling
    /// The operation passed its last cancellation point and will continue.
    case notCancellable(reason: String)
    /// The operation already ended before cancellation was processed.
    case alreadyFinished(OperationResult)
    /// The daemon returned a cancellation disposition added by a newer API version.
    case unknown

    /// Decodes known cancellation replies and maps a future reply case to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OperationDynamicCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one cancellation reply case.")
            )
        }
        switch key.stringValue {
        case "cancelling":
            self = .cancelling
        case "notCancellable":
            let payload = try container.nestedContainer(keyedBy: OperationDynamicCodingKey.self, forKey: key)
            self = .notCancellable(
                reason: try payload.decode(
                    String.self,
                    forKey: OperationDynamicCodingKey(stringValue: "reason")
                )
            )
        case "alreadyFinished":
            let payload = try container.nestedContainer(keyedBy: OperationDynamicCodingKey.self, forKey: key)
            self = .alreadyFinished(
                try payload.decode(
                    OperationResult.self,
                    forKey: OperationDynamicCodingKey(stringValue: "_0")
                ))
        default:
            self = .unknown
        }
    }

    /// Encodes a stable cancellation reply.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: OperationDynamicCodingKey.self)
        switch self {
        case .cancelling:
            _ = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "cancelling")
            )
        case .notCancellable(let reason):
            var payload = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "notCancellable")
            )
            try payload.encode(reason, forKey: OperationDynamicCodingKey(stringValue: "reason"))
        case .alreadyFinished(let result):
            var payload = container.nestedContainer(
                keyedBy: OperationDynamicCodingKey.self,
                forKey: OperationDynamicCodingKey(stringValue: "alreadyFinished")
            )
            try payload.encode(result, forKey: OperationDynamicCodingKey(stringValue: "_0"))
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath, debugDescription: "Unknown cancellation replies cannot be encoded.")
            )
        }
    }
}

private struct OperationDynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Starts installation of a previously inspected APK set asynchronously.
public struct RuntimeBeginInstallImportedControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata. Its operation ID is reused by the returned handle.
    public let header: APIRequestHeader
    /// The import ticket and install options.
    public let request: RuntimeInstallImportedRequest

    /// Creates a begin-install request.
    public init(header: APIRequestHeader, request: RuntimeInstallImportedRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or structured failure for a begin-install request.
public struct RuntimeBeginInstallImportedControlReply: Codable, Equatable, Sendable {
    /// The long-running install handle, present on success.
    public let result: OperationHandle?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: OperationHandle) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Starts a package uninstall or APKRun-store forget asynchronously.
public struct RuntimeBeginUninstallPackageControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata. Its operation ID is reused by the returned handle.
    public let header: APIRequestHeader
    /// The package and requested uninstall policy.
    public let request: RuntimeUninstallPackageRequest

    /// Creates a begin-uninstall request.
    public init(header: APIRequestHeader, request: RuntimeUninstallPackageRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or structured failure for a begin-uninstall request.
public struct RuntimeBeginUninstallPackageControlReply: Codable, Equatable, Sendable {
    /// The long-running uninstall handle, present on success.
    public let result: OperationHandle?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: OperationHandle) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Requests cancellation of a previously started operation.
public struct RuntimeCancelOperationControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The operation to cancel.
    public let operationID: OperationID

    /// Creates an operation-cancel request.
    public init(header: APIRequestHeader, operationID: OperationID) {
        self.header = header
        self.operationID = operationID
    }
}

/// The result or structured failure for a cancellation request.
public struct RuntimeCancelOperationControlReply: Codable, Equatable, Sendable {
    /// The cancellation disposition, present on success.
    public let result: CancelReply?
    /// The structured failure, including `runtime.operationNotFound`, when the ID is unknown.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: CancelReply) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Lists the operations known to the daemon.
public struct RuntimeListOperationsControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader

    /// Creates a list-operations request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The result or structured failure for a list-operations request.
public struct RuntimeListOperationsControlReply: Codable, Equatable, Sendable {
    /// Running operations and recently finished operations, present on success.
    public let result: [OperationSnapshot]?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: [OperationSnapshot]) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Requests the latest snapshot for one operation.
public struct RuntimeOperationStatusControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The operation to inspect.
    public let operationID: OperationID

    /// Creates an operation-status request.
    public init(header: APIRequestHeader, operationID: OperationID) {
        self.header = header
        self.operationID = operationID
    }
}

/// The result or structured failure for an operation-status request.
public struct RuntimeOperationStatusControlReply: Codable, Equatable, Sendable {
    /// The operation snapshot, present on success.
    public let result: OperationSnapshot?
    /// The structured failure, including `runtime.operationNotFound`, when the ID is unknown.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: OperationSnapshot) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}
