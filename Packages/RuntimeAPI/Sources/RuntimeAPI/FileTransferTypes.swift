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

/// A request to pass host files to one package on one Android display.
public struct ImportFilesRequest: Codable, Equatable, Sendable {
    /// The package that receives the files.
    public let packageID: RuntimePackageID
    /// The Android display on which the package is running.
    public let displayID: DisplayID
    /// Metadata matching the order of the accompanying file handles.
    public let files: [ImportFileInfo]
    /// The requested delivery behavior.
    public let target: ImportTarget

    /// Creates a file-import request.
    public init(
        packageID: RuntimePackageID,
        displayID: DisplayID,
        files: [ImportFileInfo],
        target: ImportTarget
    ) {
        self.packageID = packageID
        self.displayID = displayID
        self.files = files
        self.target = target
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

/// The authenticated control request used to import files.
public struct RuntimeImportFilesControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The package, display, and file metadata.
    public let request: ImportFilesRequest

    /// Creates a file-import control request.
    public init(header: APIRequestHeader, request: ImportFilesRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or typed error returned by a control file-import request.
public struct RuntimeImportFilesControlReply: Codable, Equatable, Sendable {
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
