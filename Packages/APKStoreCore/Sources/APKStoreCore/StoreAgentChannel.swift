import Foundation

/// The package metadata reported by Android's PackageManager.
public struct StorePackageInfo: Sendable, Equatable {
    /// The Android package name.
    public var packageID: PackageID
    /// The label reported by Android.
    public var displayName: String
    /// Android's combined `longVersionCode`.
    public var versionCode: VersionCode
    /// The display version reported by Android, if present.
    public var versionName: String?
    /// Whether Android currently enables the package.
    public var enabled: Bool
    /// The package's launcher component, if one is available.
    public var launchableComponent: String?
    /// The package that installed this package, if reported.
    public var installerPackage: PackageID?
    /// The time Android first installed this package, if reported.
    public var firstInstallTime: Date?
    /// The time Android last updated this package, if reported.
    public var lastUpdateTime: Date?
    /// The target Android API level reported by Android.
    public var targetSDK: Int
    /// The minimum Android API level reported by Android.
    public var minSDK: Int
    /// SHA-256 digests of the package's current signing certificates.
    public var signingDigests: [SHA256Digest]

    /// Creates a snapshot of Android package metadata.
    public init(
        packageID: PackageID,
        displayName: String,
        versionCode: VersionCode,
        versionName: String? = nil,
        enabled: Bool,
        launchableComponent: String? = nil,
        installerPackage: PackageID? = nil,
        firstInstallTime: Date? = nil,
        lastUpdateTime: Date? = nil,
        targetSDK: Int,
        minSDK: Int,
        signingDigests: [SHA256Digest] = []
    ) {
        self.packageID = packageID
        self.displayName = displayName
        self.versionCode = versionCode
        self.versionName = versionName
        self.enabled = enabled
        self.launchableComponent = launchableComponent
        self.installerPackage = installerPackage
        self.firstInstallTime = firstInstallTime
        self.lastUpdateTime = lastUpdateTime
        self.targetSDK = targetSDK
        self.minSDK = minSDK
        self.signingDigests = signingDigests
    }
}

/// One installed package returned by the Guest Agent.
public struct StorePackageSummary: Sendable, Equatable {
    /// The Android package name.
    public var packageID: PackageID
    /// The label reported by Android.
    public var displayName: String
    /// Android's combined `longVersionCode`.
    public var versionCode: VersionCode
    /// Whether Android reports a launcher activity for this package.
    public var launchable: Bool
    /// Whether this is an app installed for the current Android user.
    public var userInstalled: Bool

    /// Creates a summary of an Android-installed package.
    public init(
        packageID: PackageID,
        displayName: String,
        versionCode: VersionCode,
        launchable: Bool,
        userInstalled: Bool
    ) {
        self.packageID = packageID
        self.displayName = displayName
        self.versionCode = versionCode
        self.launchable = launchable
        self.userInstalled = userInstalled
    }
}

/// Limits the packages a Guest Agent list query returns.
public enum StorePackageFilter: Sendable, Equatable {
    case launchable
    case userInstalled
    case all
}

/// The Android operations that an image's package channel can perform.
public struct StoreCapabilities: OptionSet, Sendable, Hashable {
    /// The bit field containing the supported package operations.
    public let rawValue: UInt16

    /// Creates a capability set from its bit field.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The channel can install APK artifacts.
    public static let install = Self(rawValue: 1 << 0)
    /// The channel can query installed package metadata.
    public static let metadata = Self(rawValue: 1 << 1)
    /// The channel can inspect APK artifacts before installation.
    public static let inspect = Self(rawValue: 1 << 2)
    /// The channel can retrieve package icons.
    public static let icons = Self(rawValue: 1 << 3)
    /// The channel can update package update ownership.
    public static let updateOwnership = Self(rawValue: 1 << 4)
    /// The channel can restore a previous APK artifact set.
    public static let rollback = Self(rawValue: 1 << 5)
    /// The channel can reinstall an older package version.
    public static let downgradeReinstall = Self(rawValue: 1 << 6)
}

/// The install facts a channel must check before passing artifacts to Android.
public struct StoreInstallRequest: Sendable, Equatable {
    /// The package name expected from the APK artifacts.
    public var packageID: PackageID
    /// The version expected from the APK artifacts.
    public var versionCode: VersionCode
    /// Whether this operation has explicit approval to install a lower version.
    public var allowDowngrade: Bool

    /// Creates the package identity and version constraints for an install.
    public init(packageID: PackageID, versionCode: VersionCode, allowDowngrade: Bool = false) {
        self.packageID = packageID
        self.versionCode = versionCode
        self.allowDowngrade = allowDowngrade
    }
}

/// The Android package operations exposed to APKStoreCore.
///
/// APKStoreCore owns the policy and persistent records. RuntimeHost supplies the channel
/// implementation and routes Android work through RuntimeCore.
public protocol StoreAgentChannel: Sendable {
    /// Operations supported by this channel's Android image.
    var capabilities: StoreCapabilities { get }

    /// Installs the supplied APK set and returns Android's resulting package metadata.
    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo
    /// Uninstalls a package, optionally preserving its Android app data.
    func uninstall(_ package: PackageID, keepData: Bool) async throws
    /// Returns Android's metadata for an installed package, if present.
    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo?
    /// Lists installed packages selected by `filter`.
    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary]
}

/// The runtime gate injected by RuntimeHost.
public protocol StoreRuntimeAccess: Sendable {
    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T

    func userdataGeneration() async -> UUID?
}
