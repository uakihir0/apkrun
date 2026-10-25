import Foundation

/// `ImportFiles`: shares a set of host-transferred files with an Android app (guest-protocol.md §7.1 #45).
public struct GuestImportFilesOperation: GuestOperation {
    /// The decoded result.
    public typealias Result = GPImportResult
    /// The operation number in guest-protocol.md §7.1.
    public static let number = 45

    /// The receiving Android package.
    public let package: String
    /// The display on which Android should present the share.
    public let displayID: Int32
    /// The bulk transfer references announced by this operation.
    public let files: [GPFileRef]
    /// Creates an operation to share files with an Android app.
    public init(package: String, displayID: Int32, files: [GPFileRef]) {
        self.package = package
        self.displayID = displayID
        self.files = files
    }

    /// The operation's protocol name.
    public var operationName: String { "ImportFiles" }
    /// The capability required by this operation.
    public var capability: GuestCapability { .files }
    /// The time allowed for Android to process the share intent.
    public var timeout: Duration { .seconds(600) }

    /// Builds the protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPImportFiles()
        request.target = .shareToPackage
        request.package = package
        request.displayID = displayID
        request.files = files
        return .importFiles(request)
    }

    /// Decodes the matching result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPImportResult? {
        if case .importFiles(let imported) = result { return imported }
        return nil
    }
}

/// `ResolveExport`: decides whether a guest file offer may leave Android (guest-protocol.md §7.1 #51).
public struct GuestResolveExportOperation: GuestOperation {
    /// The decoded result.
    public typealias Result = GPExportStart
    /// The operation number in guest-protocol.md §7.1.
    public static let number = 51

    /// The guest-generated ID of the offered file.
    public let offerID: UInt64
    /// Whether the host accepted the offer.
    public let decision: GPExportDecision

    /// Creates a response to one guest file offer.
    public init(offerID: UInt64, decision: GPExportDecision) {
        self.offerID = offerID
        self.decision = decision
    }

    /// The operation's protocol name.
    public var operationName: String { "ResolveExport" }
    /// The capability required by this operation.
    public var capability: GuestCapability { .files }
    /// The guest reserves an accepted transfer before returning its stream ID.
    public var timeout: Duration { .seconds(30) }

    /// Builds the protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPResolveExport()
        request.offerID = offerID
        request.decision = decision
        return .resolveExport(request)
    }

    /// Decodes the matching result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPExportStart? {
        if case .resolveExport(let start) = result { return start }
        return nil
    }
}

/// `SetSharedFolderAccess`: replaces the package grants used by MacFilesProvider (guest-protocol.md §7.1 #52).
public struct GuestSetSharedFolderAccessOperation: GuestOperation {
    /// The decoded result.
    public typealias Result = GPEmpty
    /// The operation number in guest-protocol.md §7.1.
    public static let number = 52

    /// The shared-folder roots and maximum access for each root.
    public let roots: [GPSharedRoot]
    /// The package-specific access entries.
    public let access: [GPPackageAccess]

    /// Creates a replacement shared-folder policy.
    public init(roots: [GPSharedRoot], access: [GPPackageAccess]) {
        self.roots = roots
        self.access = access
    }

    /// The operation's protocol name.
    public var operationName: String { "SetSharedFolderAccess" }
    /// The capability required by this operation.
    public var capability: GuestCapability { .filesShared }
    /// This operation is a bounded policy replacement.
    public var timeout: Duration { .seconds(30) }

    /// Builds the protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSetSharedFolderAccess()
        request.roots = roots
        request.access = access
        return .setSharedFolderAccess(request)
    }

    /// Decodes the matching result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setSharedFolderAccess(let empty) = result { return empty }
        return nil
    }
}
