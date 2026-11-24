import Foundation

/// Metadata for one host file passed to the runtime by file handle.
public struct ImportFileInfo: Codable, Equatable, Sendable {
    /// The zero-based position of the file handle in the accompanying array.
    public let fileIndex: Int
    /// The display name supplied by the host file picker or drag operation.
    public let name: String
    /// The file size in bytes.
    public let size: Int64
    /// The Uniform Type Identifier for the file.
    public let uti: String

    /// Creates metadata for one transferred file.
    public init(fileIndex: Int, name: String, size: Int64, uti: String) {
        self.fileIndex = fileIndex
        self.name = name
        self.size = size
        self.uti = uti
    }
}

/// The destination for files imported from the Mac.
public enum ImportTarget: String, Codable, Equatable, Sendable {
    /// Share the files with the package active on the target Android display.
    case shareToApp
}

/// A request to pass host files through one running app session.
public struct ImportFilesRequest: Codable, Equatable, Sendable {
    /// The session bound by the authenticated session endpoint. This value is not encoded.
    ///
    /// The initial value on a client-created or decoded request is only a placeholder. A
    /// session endpoint must replace it with the session ID captured when that endpoint was
    /// created before forwarding the request to a ``RuntimeSessionService``.
    public let sessionID: UUID
    /// Metadata matching the order of the accompanying file handles.
    public let files: [ImportFileInfo]
    /// The requested delivery behavior.
    public let target: ImportTarget

    /// Creates a file-import request. Session identity is supplied by the session endpoint.
    public init(
        files: [ImportFileInfo],
        target: ImportTarget
    ) {
        sessionID = UUID()
        self.files = files
        self.target = target
    }

    private init(sessionID: UUID, files: [ImportFileInfo], target: ImportTarget) {
        self.sessionID = sessionID
        self.files = files
        self.target = target
    }

    /// Returns a copy bound to the session that owns the authenticated endpoint.
    @_spi(APKRunSessionBinding)
    public func bound(to sessionID: UUID) -> Self {
        Self(sessionID: sessionID, files: files, target: target)
    }

    private enum CodingKeys: String, CodingKey {
        case files
        case target
    }

    /// Decodes an unbound request and replaces any client-supplied session identity with a placeholder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = UUID()
        files = try container.decode([ImportFileInfo].self, forKey: .files)
        target = try container.decode(ImportTarget.self, forKey: .target)
    }

    /// Encodes the requested files without exposing the daemon-bound session identity.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(files, forKey: .files)
        try container.encode(target, forKey: .target)
    }

    /// Compares transfer metadata; session identity is bound by the authenticated endpoint.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.files == rhs.files && lhs.target == rhs.target
    }
}

/// The outcome of importing files into Android.
public struct ImportResult: Codable, Equatable, Sendable {
    /// Content URIs returned by the Guest Agent, in file order.
    public let contentURIs: [String]
    /// Whether the package received the share or the files were saved to Downloads.
    public let disposition: ImportDisposition

    /// Creates a file-import result.
    public init(contentURIs: [String], disposition: ImportDisposition) {
        self.contentURIs = contentURIs
        self.disposition = disposition
    }
}

/// The way the Guest Agent handled an imported file set.
public enum ImportDisposition: String, Codable, Equatable, Sendable {
    /// The package accepted a share intent.
    case shared
    /// No share target was available, so the files were saved to Downloads.
    case savedToDownloads
}

/// The authenticated session-channel request used to import files.
public struct RuntimeImportFilesSessionRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The file metadata and delivery behavior.
    public let request: ImportFilesRequest

    /// Creates a file-import session request.
    public init(header: APIRequestHeader, request: ImportFilesRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or typed error returned by a session-channel file-import request.
public struct RuntimeImportFilesSessionReply: Codable, Equatable, Sendable {
    /// The import result, present on success.
    public let result: ImportResult?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: ImportResult) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}
