import Foundation

/// Metadata for one file offered by an Android app to save on the Mac.
public struct ExportOffer: Codable, Equatable, Sendable {
    /// Opaque identifier assigned by the host for this individual offer.
    public let offerID: UUID
    /// A sanitized display name for the offered file.
    public let name: String
    /// The file size in bytes, when known.
    public let size: Int64?
    /// The MIME type reported for the offered file.
    public let type: String

    /// Creates an export offer.
    public init(offerID: UUID, name: String, size: Int64?, type: String) {
        self.offerID = offerID
        self.name = name
        self.size = size
        self.type = type
    }
}

/// A response to one Android file offer.
public struct AcceptExportRequest: Codable, Equatable, Sendable {
    /// The session bound by the authenticated session endpoint. This value is not encoded.
    ///
    /// The initial value on a client-created or decoded request is only a placeholder. A
    /// session endpoint must replace it with the session ID captured when the endpoint was
    /// created before forwarding the request to a ``RuntimeSessionService``.
    public let sessionID: UUID
    /// Opaque host identifier for the offered file.
    public let offerID: UUID
    /// Index of the optional destination handle; nil means the user cancelled.
    public let fileIndex: Int?

    /// Creates an export response. A present destination uses the single handle at index zero.
    public init(offerID: UUID, fileIndex: Int?) {
        sessionID = UUID()
        self.offerID = offerID
        self.fileIndex = fileIndex
    }

    private init(sessionID: UUID, offerID: UUID, fileIndex: Int?) {
        self.sessionID = sessionID
        self.offerID = offerID
        self.fileIndex = fileIndex
    }

    /// Returns a copy bound to the session that owns the authenticated endpoint.
    @_spi(APKRunSessionBinding)
    public func bound(to sessionID: UUID) -> Self {
        Self(sessionID: sessionID, offerID: offerID, fileIndex: fileIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case offerID
        case fileIndex
    }

    /// Decodes an unbound request and replaces any client-supplied session identity with a placeholder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = UUID()
        offerID = try container.decode(UUID.self, forKey: .offerID)
        fileIndex = try container.decodeIfPresent(Int.self, forKey: .fileIndex)
    }

    /// Encodes the offer response without exposing the daemon-bound session identity.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offerID, forKey: .offerID)
        try container.encodeIfPresent(fileIndex, forKey: .fileIndex)
    }

    /// Compares offer response metadata; session identity is bound by the authenticated endpoint.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offerID == rhs.offerID && lhs.fileIndex == rhs.fileIndex
    }
}

/// The authenticated session-channel request to accept or cancel an Android file offer.
public struct RuntimeAcceptExportSessionRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The offered file and selected destination handle, if any.
    public let request: AcceptExportRequest

    /// Creates an export session request.
    public init(header: APIRequestHeader, request: AcceptExportRequest) {
        self.header = header
        self.request = request
    }
}

/// The empty result or typed error returned by an export session request.
public struct RuntimeAcceptExportSessionReply: Codable, Equatable, Sendable {
    /// The empty success result, present after the transfer completes.
    public let result: RuntimeEmpty?
    /// The structured failure, present when the request was rejected or transfer failed.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeEmpty = RuntimeEmpty()) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}
