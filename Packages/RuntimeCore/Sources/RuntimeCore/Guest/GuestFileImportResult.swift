/// One file already transferred to the Android Guest Agent's bulk endpoint.
public struct GuestFileReference: Equatable, Sendable {
    /// Guest bulk-transfer identifier.
    public let transferID: UInt64

    /// Name selected by the host.
    public let name: String

    /// MIME type selected by the host.
    public let mimeType: String

    /// Exact file size in bytes.
    public let size: UInt64

    /// Creates a reference to one transferred file.
    public init(transferID: UInt64, name: String, mimeType: String, size: UInt64) {
        self.transferID = transferID
        self.name = name
        self.mimeType = mimeType
        self.size = size
    }
}

/// The result category reported by Android when a host file drop is delivered.
public enum GuestFileImportDisposition: Equatable, Sendable {
    /// The files were shared to an Android app.
    case shared

    /// Android saved the files to Downloads because no app could receive the share.
    case savedToDownloads

    /// The guest returned an unsupported disposition.
    case unsupported
}

/// The content URIs and disposition returned by Android for a file drop.
public struct GuestFileImportResult: Equatable, Sendable {
    /// Android content URIs corresponding to the transferred files.
    public let contentURIs: [String]

    /// How Android delivered the files.
    public let disposition: GuestFileImportDisposition

    /// Creates the host-facing result of an Android file import.
    public init(contentURIs: [String], disposition: GuestFileImportDisposition) {
        self.contentURIs = contentURIs
        self.disposition = disposition
    }
}
