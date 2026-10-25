import Foundation

/// The maximum access a shared-folder root can grant to Android apps.
public enum SharedFolderAccess: String, Codable, Equatable, Sendable {
    /// Android apps can browse and read files.
    case readOnly
    /// Android apps can browse, read, and modify files.
    case readWrite
}

/// The current host-side availability of a shared-folder root.
public enum SharedFolderAvailability: String, Codable, Equatable, Sendable {
    /// The root bookmark resolves and the host can access the folder.
    case available
    /// The folder was moved or removed.
    case missing
    /// macOS denied access to the folder.
    case privacyDenied
    /// The volume containing the folder is not mounted.
    case offline
    /// The host could not determine the root's availability.
    case unknown
}

/// A folder root exposed through Android's document picker.
///
/// `path` is display metadata only. Clients must use the opaque `id` for root
/// operations and must provide a security-scoped bookmark when adding a root.
public struct SharedFolder: Codable, Equatable, Sendable {
    /// `shared` for APKRun's built-in Shared folder; otherwise an opaque root ID.
    public let id: String
    /// The user-visible folder name.
    public let name: String
    /// A display-only path. It is not accepted as an operation target.
    public let path: String
    /// The maximum access granted by this root.
    public let access: SharedFolderAccess
    /// Whether this is APKRun's built-in Shared folder.
    public let builtIn: Bool
    /// Whether the host can currently access this root.
    public let availability: SharedFolderAvailability

    /// Creates a shared-folder listing entry.
    public init(
        id: String,
        name: String,
        path: String,
        access: SharedFolderAccess,
        builtIn: Bool,
        availability: SharedFolderAvailability
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.access = access
        self.builtIn = builtIn
        self.availability = availability
    }
}

/// Adds a root using bookmark data created by the requesting Mac app.
public struct AddSharedFolderRequest: Codable, Equatable, Sendable {
    /// Security-scoped bookmark data. Raw filesystem paths are not accepted.
    public let bookmark: Data
    /// Maximum access for this root. New roots are read-only by default.
    public let access: SharedFolderAccess

    /// Creates a root-add request.
    public init(bookmark: Data, access: SharedFolderAccess = .readOnly) {
        self.bookmark = bookmark
        self.access = access
    }
}

/// Identifies a shared-folder root for removal.
public struct SharedFolderRequest: Codable, Equatable, Sendable {
    /// The opaque root ID returned by `sharedFolders`.
    public let id: String

    /// Creates a root request.
    public init(id: String) {
        self.id = id
    }
}

/// Changes the maximum access granted by a shared-folder root.
public struct SetSharedFolderAccessRequest: Codable, Equatable, Sendable {
    /// The opaque root ID returned by `sharedFolders`.
    public let id: String
    /// The new maximum access.
    public let access: SharedFolderAccess

    /// Creates an access-change request.
    public init(id: String, access: SharedFolderAccess) {
        self.id = id
        self.access = access
    }
}

/// Lists configured shared-folder roots through the control endpoint.
public struct RuntimeSharedFoldersControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader

    /// Creates a root-list request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// Adds a shared-folder root through the control endpoint.
public struct RuntimeAddSharedFolderControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The bookmark and requested maximum access.
    public let request: AddSharedFolderRequest

    /// Creates a root-add control request.
    public init(header: APIRequestHeader, request: AddSharedFolderRequest) {
        self.header = header
        self.request = request
    }
}

/// Removes a shared-folder root through the control endpoint.
public struct RuntimeRemoveSharedFolderControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The opaque root ID.
    public let request: SharedFolderRequest

    /// Creates a root-removal control request.
    public init(header: APIRequestHeader, request: SharedFolderRequest) {
        self.header = header
        self.request = request
    }
}

/// Changes a shared-folder root's access through the control endpoint.
public struct RuntimeSetSharedFolderAccessControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The root ID and new maximum access.
    public let request: SetSharedFolderAccessRequest

    /// Creates a root-access control request.
    public init(header: APIRequestHeader, request: SetSharedFolderAccessRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or typed error returned by a shared-folder listing request.
public struct RuntimeSharedFoldersControlReply: Codable, Equatable, Sendable {
    /// The configured roots, present on success.
    public let result: [SharedFolder]?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: [SharedFolder]) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a shared-folder add request.
public struct RuntimeAddSharedFolderControlReply: Codable, Equatable, Sendable {
    /// The added root, present on success.
    public let result: SharedFolder?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: SharedFolder) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a shared-folder remove request.
public struct RuntimeRemoveSharedFolderControlReply: Codable, Equatable, Sendable {
    /// The empty success result, present on success.
    public let result: RuntimeEmpty?
    /// The structured failure, present on failure.
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

/// The result or typed error returned by a shared-folder access-change request.
public struct RuntimeSetSharedFolderAccessControlReply: Codable, Equatable, Sendable {
    /// The updated root, present on success.
    public let result: SharedFolder?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: SharedFolder) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}
