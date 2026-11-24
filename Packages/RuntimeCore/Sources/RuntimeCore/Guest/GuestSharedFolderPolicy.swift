/// The access a package may request for one shared-folder root.
public enum GuestSharedFolderAccess: Equatable, Sendable {
    /// The package can read files and folders.
    case readOnly

    /// The package can read and modify files and folders.
    case readWrite
}

/// A host-configured folder root sent to the Android Guest Agent.
public struct GuestSharedFolderRoot: Equatable, Sendable {
    /// Stable identifier used by the guest document provider.
    public let id: String

    /// User-visible folder title without its host path.
    public let title: String

    /// Maximum access allowed by the host configuration.
    public let access: GuestSharedFolderAccess

    /// Creates a root policy for the guest.
    public init(id: String, title: String, access: GuestSharedFolderAccess) {
        self.id = id
        self.title = title
        self.access = access
    }
}

/// A package-level access grant sent to the Android Guest Agent.
public struct GuestPackageSharedFolderAccess: Equatable, Sendable {
    /// Android package identifier.
    public let packageID: String

    /// Maximum access granted to the package.
    public let access: GuestSharedFolderAccess

    /// Creates a package access grant.
    public init(packageID: String, access: GuestSharedFolderAccess) {
        self.packageID = packageID
        self.access = access
    }
}
