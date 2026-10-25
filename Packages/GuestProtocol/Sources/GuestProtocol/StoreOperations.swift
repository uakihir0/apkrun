import Foundation

/// `InspectArchive` (guest-protocol.md §11.1, operation 100).
public struct GuestInspectArchive: GuestOperation {
    /// The archive metadata returned by operation 100.
    public typealias Result = GPArchiveInfo
    /// The Store Agent operation number.
    public static let number = 100

    /// The artifacts already transferred for inspection.
    public let artifacts: [GPArtifactRef]

    /// Creates an archive inspection request.
    public init(artifacts: [GPArtifactRef]) {
        self.artifacts = artifacts
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "InspectArchive" }
    /// The capability required to inspect archives.
    public var capability: GuestCapability { .storeMetadata }
    /// The default response timeout.
    public var timeout: Duration { .seconds(30) }

    /// Encodes this operation as a protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var value = GPInspectArchive()
        value.artifacts = artifacts
        return .inspectArchive(value)
    }

    /// Decodes the matching protocol result, or returns nil for a mismatched result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPArchiveInfo? {
        if case .inspectArchive(let value) = result { return value }
        return nil
    }
}

/// `BeginInstall` (guest-protocol.md §11.1, operation 101).
public struct GuestBeginInstall: GuestOperation {
    /// The install session identifiers returned by operation 101.
    public typealias Result = GPBeginInstallResult
    /// The Store Agent operation number.
    public static let number = 101

    /// The requested package identity, version, signers, and artifacts.
    public let installRequest: GPInstallRequest

    /// Creates a begin-install request.
    public init(_ installRequest: GPInstallRequest) {
        self.installRequest = installRequest
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "BeginInstall" }
    /// The capability required to install packages.
    public var capability: GuestCapability { .storeInstall }
    /// The default response timeout.
    public var timeout: Duration { .seconds(30) }

    /// Encodes this operation as a protocol request.
    public func request() -> GPRequest.OneOf_Op { .beginInstall(installRequest) }

    /// Decodes the matching protocol result, or returns nil for a mismatched result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPBeginInstallResult? {
        if case .beginInstall(let value) = result { return value }
        return nil
    }
}

/// `CommitInstall` (guest-protocol.md §11.1, operation 102).
public struct GuestCommitInstall: GuestOperation {
    /// The empty result returned after the commit request is accepted.
    public typealias Result = GPEmpty
    /// The Store Agent operation number.
    public static let number = 102

    /// The identifier returned by `BeginInstall`.
    public let installID: String

    /// Creates a commit-install request.
    public init(installID: String) {
        self.installID = installID
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "CommitInstall" }
    /// The capability required to install packages.
    public var capability: GuestCapability { .storeInstall }
    /// The default response timeout.
    public var timeout: Duration { .seconds(30) }

    /// Encodes this operation as a protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var value = GPCommitInstall()
        value.installID = installID
        return .commitInstall(value)
    }

    /// Decodes the matching protocol result, or returns nil for a mismatched result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .commitInstall(let value) = result { return value }
        return nil
    }
}

/// `AbandonInstall` (guest-protocol.md §11.1, operation 103).
public struct GuestAbandonInstall: GuestOperation {
    /// The empty result returned after the install session is abandoned.
    public typealias Result = GPEmpty
    /// The Store Agent operation number.
    public static let number = 103

    /// The identifier returned by `BeginInstall`.
    public let installID: String

    /// Creates an abandon-install request.
    public init(installID: String) {
        self.installID = installID
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "AbandonInstall" }
    /// The capability required to install packages.
    public var capability: GuestCapability { .storeInstall }
    /// The default response timeout.
    public var timeout: Duration { .seconds(30) }

    /// Encodes this operation as a protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var value = GPAbandonInstall()
        value.installID = installID
        return .abandonInstall(value)
    }

    /// Decodes the matching protocol result, or returns nil for a mismatched result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .abandonInstall(let value) = result { return value }
        return nil
    }
}

/// `Uninstall` (guest-protocol.md §11.1, operation 104).
public struct GuestUninstallPackage: GuestOperation {
    /// The outcome returned by the uninstall operation.
    public typealias Result = GPUninstallResult
    /// The Store Agent operation number.
    public static let number = 104

    /// The package to uninstall.
    public let package: String
    /// Whether Android should preserve the package's app data.
    public let keepData: Bool

    /// Creates an uninstall request.
    public init(package: String, keepData: Bool) {
        self.package = package
        self.keepData = keepData
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "Uninstall" }
    /// The capability required to uninstall packages.
    public var capability: GuestCapability { .storeInstall }
    /// The default response timeout.
    public var timeout: Duration { .seconds(120) }

    /// Encodes this operation as a protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var value = GPUninstall()
        value.package = package
        value.keepData = keepData
        return .uninstall(value)
    }

    /// Decodes the matching protocol result, or returns nil for a mismatched result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPUninstallResult? {
        if case .uninstall(let value) = result { return value }
        return nil
    }
}

/// `GetPackageMetadata` (guest-protocol.md §11.1, operation 105).
public struct GuestGetStorePackageMetadata: GuestOperation {
    /// Android's metadata for the requested package.
    public typealias Result = GPStorePackageInfo
    /// The Store Agent operation number.
    public static let number = 105

    /// The package whose metadata is requested.
    public let package: String

    /// Creates a package-metadata request.
    public init(package: String) {
        self.package = package
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "GetPackageMetadata" }
    /// The capability required to query package metadata.
    public var capability: GuestCapability { .storeMetadata }
    /// The default response timeout.
    public var timeout: Duration { .seconds(10) }

    /// Encodes this operation as a protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var value = GPGetPackageMetadata()
        value.package = package
        return .getPackageMetadata(value)
    }

    /// Decodes the matching protocol result, or returns nil for a mismatched result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPStorePackageInfo? {
        if case .getPackageMetadata(let value) = result { return value }
        return nil
    }
}

/// `ListManagedPackages` (guest-protocol.md §11.1, operation 106).
public struct GuestListManagedPackages: GuestOperation {
    /// The matching Android package metadata records.
    public typealias Result = GPStorePackageList
    /// The Store Agent operation number.
    public static let number = 106

    /// Which installed packages Android should return.
    public let filter: GPManagedPackageFilter

    /// Creates a managed-package list request.
    public init(filter: GPManagedPackageFilter) {
        self.filter = filter
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "ListManagedPackages" }
    /// The capability required to query package metadata.
    public var capability: GuestCapability { .storeMetadata }
    /// The default response timeout.
    public var timeout: Duration { .seconds(10) }

    /// Encodes this operation as a protocol request.
    public func request() -> GPRequest.OneOf_Op {
        var value = GPListManagedPackages()
        value.filter = filter
        return .listManagedPackages(value)
    }

    /// Decodes the matching protocol result, or returns nil for a mismatched result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPStorePackageList? {
        if case .listManagedPackages(let value) = result { return value }
        return nil
    }
}
