import Foundation

/// `InspectArchive` (guest-protocol.md §11.1, operation 100).
public struct GuestInspectArchive: GuestOperation {
    public typealias Result = GPArchiveInfo
    public static let number = 100

    public let artifacts: [GPArtifactRef]

    public init(artifacts: [GPArtifactRef]) {
        self.artifacts = artifacts
    }

    public var operationName: String { "InspectArchive" }
    public var capability: GuestCapability { .storeMetadata }
    public var timeout: Duration { .seconds(30) }

    public func request() -> GPRequest.OneOf_Op {
        var value = GPInspectArchive()
        value.artifacts = artifacts
        return .inspectArchive(value)
    }

    public static func decode(_ result: GPResponse.OneOf_Result) -> GPArchiveInfo? {
        if case .inspectArchive(let value) = result { return value }
        return nil
    }
}

/// `BeginInstall` (guest-protocol.md §11.1, operation 101).
public struct GuestBeginInstall: GuestOperation {
    public typealias Result = GPBeginInstallResult
    public static let number = 101

    public let installRequest: GPInstallRequest

    public init(_ installRequest: GPInstallRequest) {
        self.installRequest = installRequest
    }

    public var operationName: String { "BeginInstall" }
    public var capability: GuestCapability { .storeInstall }
    public var timeout: Duration { .seconds(30) }

    public func request() -> GPRequest.OneOf_Op { .beginInstall(installRequest) }

    public static func decode(_ result: GPResponse.OneOf_Result) -> GPBeginInstallResult? {
        if case .beginInstall(let value) = result { return value }
        return nil
    }
}

/// `CommitInstall` (guest-protocol.md §11.1, operation 102).
public struct GuestCommitInstall: GuestOperation {
    public typealias Result = GPEmpty
    public static let number = 102

    public let installID: String

    public init(installID: String) {
        self.installID = installID
    }

    public var operationName: String { "CommitInstall" }
    public var capability: GuestCapability { .storeInstall }
    public var timeout: Duration { .seconds(30) }

    public func request() -> GPRequest.OneOf_Op {
        var value = GPCommitInstall()
        value.installID = installID
        return .commitInstall(value)
    }

    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .commitInstall(let value) = result { return value }
        return nil
    }
}

/// `AbandonInstall` (guest-protocol.md §11.1, operation 103).
public struct GuestAbandonInstall: GuestOperation {
    public typealias Result = GPEmpty
    public static let number = 103

    public let installID: String

    public init(installID: String) {
        self.installID = installID
    }

    public var operationName: String { "AbandonInstall" }
    public var capability: GuestCapability { .storeInstall }
    public var timeout: Duration { .seconds(30) }

    public func request() -> GPRequest.OneOf_Op {
        var value = GPAbandonInstall()
        value.installID = installID
        return .abandonInstall(value)
    }

    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .abandonInstall(let value) = result { return value }
        return nil
    }
}

/// `Uninstall` (guest-protocol.md §11.1, operation 104).
public struct GuestUninstallPackage: GuestOperation {
    public typealias Result = GPUninstallResult
    public static let number = 104

    public let package: String
    public let keepData: Bool

    public init(package: String, keepData: Bool) {
        self.package = package
        self.keepData = keepData
    }

    public var operationName: String { "Uninstall" }
    public var capability: GuestCapability { .storeInstall }
    public var timeout: Duration { .seconds(30) }

    public func request() -> GPRequest.OneOf_Op {
        var value = GPUninstall()
        value.package = package
        value.keepData = keepData
        return .uninstall(value)
    }

    public static func decode(_ result: GPResponse.OneOf_Result) -> GPUninstallResult? {
        if case .uninstall(let value) = result { return value }
        return nil
    }
}

/// `GetPackageMetadata` (guest-protocol.md §11.1, operation 105).
public struct GuestGetStorePackageMetadata: GuestOperation {
    public typealias Result = GPStorePackageInfo
    public static let number = 105

    public let package: String

    public init(package: String) {
        self.package = package
    }

    public var operationName: String { "GetPackageMetadata" }
    public var capability: GuestCapability { .storeMetadata }
    public var timeout: Duration { .seconds(10) }

    public func request() -> GPRequest.OneOf_Op {
        var value = GPGetPackageMetadata()
        value.package = package
        return .getPackageMetadata(value)
    }

    public static func decode(_ result: GPResponse.OneOf_Result) -> GPStorePackageInfo? {
        if case .getPackageMetadata(let value) = result { return value }
        return nil
    }
}

/// `ListManagedPackages` (guest-protocol.md §11.1, operation 106).
public struct GuestListManagedPackages: GuestOperation {
    public typealias Result = GPStorePackageList
    public static let number = 106

    public let filter: GPManagedPackageFilter

    public init(filter: GPManagedPackageFilter) {
        self.filter = filter
    }

    public var operationName: String { "ListManagedPackages" }
    public var capability: GuestCapability { .storeMetadata }
    public var timeout: Duration { .seconds(10) }

    public func request() -> GPRequest.OneOf_Op {
        var value = GPListManagedPackages()
        value.filter = filter
        return .listManagedPackages(value)
    }

    public static func decode(_ result: GPResponse.OneOf_Result) -> GPStorePackageList? {
        if case .listManagedPackages(let value) = result { return value }
        return nil
    }
}
