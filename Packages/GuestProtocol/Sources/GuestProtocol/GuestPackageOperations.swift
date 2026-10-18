import Foundation

/// Reads PackageManager's metadata for one installed package
/// (guest-protocol.md §7.1 operation 19; pulled forward by #027).
public struct GuestQueryPackage: GuestOperation {
    /// The package information returned by the Guest Agent.
    public typealias Result = GPPackageInfo
    /// The stable guest protocol operation number.
    public static let number = 19

    /// The Android package name to query.
    public let package: String

    /// Creates a PackageManager query for `package`.
    public init(package: String) {
        self.package = package
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "QueryPackage" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .packages }
    /// The maximum time allowed for the query.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var query = GPQueryPackage()
        query.package = package
        return .queryPackage(query)
    }

    /// Extracts package metadata from a successful response.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPPackageInfo? {
        if case .queryPackage(let info) = result { return info }
        return nil
    }
}

/// Lists installed packages from PackageManager
/// (guest-protocol.md §7.1 operation 20; pulled forward by #027).
public struct GuestListPackages: GuestOperation {
    /// The package list returned by the Guest Agent.
    public typealias Result = GPPackageList
    /// The stable guest protocol operation number.
    public static let number = 20

    /// The PackageManager filter for the list request.
    public let filter: GPPackageFilter

    /// Creates a package list query, defaulting to user-installed apps.
    public init(filter: GPPackageFilter = .userInstalled) {
        self.filter = filter
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "ListPackages" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .packages }
    /// The maximum time allowed for the query.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var list = GPListPackages()
        list.filter = filter
        return .listPackages(list)
    }

    /// Extracts package summaries from a successful response.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPPackageList? {
        if case .listPackages(let packages) = result { return packages }
        return nil
    }
}
