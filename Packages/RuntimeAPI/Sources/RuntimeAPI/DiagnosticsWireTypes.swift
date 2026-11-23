import Foundation

/// A diagnostics report request (runtime-api.md §4.7, diagnostics.md §8.1).
/// The client owns the output file and passes it as the `FileHandle` beside
/// the request; the daemon never opens a user-chosen path.
public struct DiagnosticsRequest: Codable, Equatable, Sendable {
    /// Keep every logcat line, still redacted.
    public var includeLogcat: Bool
    /// Include deep checks and metrics.
    public var deep: Bool
    /// The package whose update history and launch records are added.
    public var focusPackage: String?
    /// Who asked: `app` or `cli` (the manifest's `createdBy`).
    public var createdBy: String

    /// Creates a report request.
    public init(
        includeLogcat: Bool = false,
        deep: Bool = false,
        focusPackage: String? = nil,
        createdBy: String = "app"
    ) {
        self.includeLogcat = includeLogcat
        self.deep = deep
        self.focusPackage = focusPackage
        self.createdBy = createdBy
    }
}

/// Starts a diagnostics report through the authenticated control endpoint.
/// The operation's `FileHandle` rides beside the request.
public struct RuntimeCreateDiagnosticsControlRequest: Codable, Equatable, Sendable {
    /// The request metadata; its operation ID is reused by the returned handle.
    public let header: APIRequestHeader
    /// The report options.
    public let request: DiagnosticsRequest

    /// Creates a report request.
    public init(header: APIRequestHeader, request: DiagnosticsRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or structured failure for a report request.
public struct RuntimeCreateDiagnosticsControlReply: Codable, Equatable, Sendable {
    /// The long-running operation's handle, present on success.
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

/// A bundle item the collector skipped, and why (diagnostics.md §8.1).
public struct WireOmittedItem: Codable, Equatable, Sendable {
    /// The report's path, or a contributor's name.
    public let item: String
    /// The short English reason (e.g. `budgetExceeded`).
    public let reason: String

    /// Creates an omitted-item record.
    public init(item: String, reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// The report's outcome returned as the `diagnostics` operation's output
/// (diagnostics.md §8.1).
public struct DiagnosticsReportInfo: Codable, Equatable, Sendable {
    /// The archive's byte count.
    public let bytes: Int64
    /// Items the collector omitted, with their reasons.
    public let omitted: [WireOmittedItem]
    /// The report's `summary.txt` text.
    public let summary: String

    /// Creates a report outcome.
    public init(bytes: Int64, omitted: [WireOmittedItem], summary: String) {
        self.bytes = bytes
        self.omitted = omitted
        self.summary = summary
    }
}
