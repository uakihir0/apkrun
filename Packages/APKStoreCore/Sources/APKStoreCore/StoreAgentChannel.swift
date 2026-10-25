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
    /// Earlier certificates in Android's signing lineage.
    public var signingLineage: [SHA256Digest]
    /// Android's signing scheme version.
    public var signingSchemeVersion: Int
    /// The Android package that owns updates, when set.
    public var updateOwner: PackageID?
    /// The package that initiated this installation, when reported.
    public var initiatingPackage: PackageID?
    /// The installed split APK names. `base` is the base APK.
    public var splitNames: [String]
    /// Native ABIs included in the installed APK set.
    public var nativeABIs: [String]
    /// Whether Android reports this package as suspended.
    public var suspended: Bool
    /// The number of permissions requested by the package.
    public var requestedPermissionsCount: Int

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
        signingDigests: [SHA256Digest] = [],
        signingLineage: [SHA256Digest] = [],
        signingSchemeVersion: Int = 0,
        updateOwner: PackageID? = nil,
        initiatingPackage: PackageID? = nil,
        splitNames: [String] = [],
        nativeABIs: [String] = [],
        suspended: Bool = false,
        requestedPermissionsCount: Int = 0
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
        self.signingLineage = signingLineage
        self.signingSchemeVersion = signingSchemeVersion
        self.updateOwner = updateOwner
        self.initiatingPackage = initiatingPackage
        self.splitNames = splitNames
        self.nativeABIs = nativeABIs
        self.suspended = suspended
        self.requestedPermissionsCount = requestedPermissionsCount
    }
}

/// One artifact declared for a Store Agent inspection or install transaction.
public struct StoreArtifactSpec: Sendable, Equatable, Hashable {
    /// Android's install-session artifact name (`base` or a split name).
    public var name: String
    /// Expected artifact length in bytes.
    public var size: UInt64
    /// Expected SHA-256 digest.
    public var sha256: SHA256Digest

    /// Creates a validated artifact specification for one APK file.
    public init(name: String, size: UInt64, sha256: SHA256Digest) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// Facts read by Android's package parser for an APK artifact set.
public struct StoreArchiveInfo: Sendable, Equatable {
    /// The package declared by the APK set.
    public var packageID: PackageID
    /// Android's combined `longVersionCode`.
    public var versionCode: VersionCode
    /// The display version reported by the APK set, if present.
    public var versionName: String?
    /// Split names included in the APK set.
    public var splitNames: [String]
    /// Native ABIs included in the APK set.
    public var nativeABIs: [String]
    /// Minimum Android API level required by the APK set.
    public var minSDK: Int
    /// Target Android API level declared by the APK set.
    public var targetSDK: Int
    /// SHA-256 digests of the APK set's current signing certificates.
    public var signingDigests: [SHA256Digest]
    /// Highest Android APK signing scheme used by the APK set.
    public var signingSchemeVersion: Int

    /// Creates a snapshot of Android-parsed APK facts.
    public init(
        packageID: PackageID,
        versionCode: VersionCode,
        versionName: String? = nil,
        splitNames: [String],
        nativeABIs: [String],
        minSDK: Int,
        targetSDK: Int,
        signingDigests: [SHA256Digest],
        signingSchemeVersion: Int
    ) {
        self.packageID = packageID
        self.versionCode = versionCode
        self.versionName = versionName
        self.splitNames = splitNames
        self.nativeABIs = nativeABIs
        self.minSDK = minSDK
        self.targetSDK = targetSDK
        self.signingDigests = signingDigests
        self.signingSchemeVersion = signingSchemeVersion
    }
}

/// The PackageChanged event emitted by Android's package manager.
public struct StorePackageEvent: Sendable, Equatable {
    /// The package lifecycle change reported by Android.
    public enum Kind: Sendable, Equatable {
        /// Android installed the package.
        case added
        /// Android replaced an installed package.
        case replaced
        /// Android removed the package.
        case removed
        /// Android changed package metadata.
        case changed
    }

    /// The Android package name.
    public var packageID: PackageID
    /// The type of change observed by Android.
    public var kind: Kind
    /// Android's combined `longVersionCode`.
    public var versionCode: VersionCode

    /// Creates a package change reported by Android.
    public init(packageID: PackageID, kind: Kind, versionCode: VersionCode) {
        self.packageID = packageID
        self.kind = kind
        self.versionCode = versionCode
    }
}

/// One installed package returned by the Guest Agent.
public struct StorePackageSummary: Codable, Sendable, Equatable {
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

/// A last-known Android package inventory and the time it was observed.
public struct StoreAndroidInventorySnapshot: Sendable, Equatable {
    /// The time at which PackageManager produced this inventory.
    public var observedAt: Date
    /// Packages returned by the Guest Agent at that time.
    public var packages: [StorePackageSummary]

    /// Creates an inventory snapshot.
    public init(observedAt: Date, packages: [StorePackageSummary]) {
        self.observedAt = observedAt
        self.packages = packages
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
    /// The intended Android install-session operation.
    public enum Mode: Sendable, Equatable {
        case installNew
        case update
        case reinstall
    }

    /// The package name expected from the APK artifacts.
    public var packageID: PackageID
    /// The version expected from the APK artifacts.
    public var versionCode: VersionCode
    /// Whether this operation has explicit approval to install a lower version.
    public var allowDowngrade: Bool
    /// The operation mode used by Android's PackageInstaller.
    public var mode: Mode
    /// Signers already verified by the host, when available.
    public var expectedSignerDigests: [SHA256Digest]
    /// Exact file metadata declared for this install.
    public var artifacts: [StoreArtifactSpec]

    /// Creates the package identity and version constraints for an install.
    public init(
        packageID: PackageID,
        versionCode: VersionCode,
        allowDowngrade: Bool = false,
        mode: Mode = .installNew,
        expectedSignerDigests: [SHA256Digest] = [],
        artifacts: [StoreArtifactSpec] = []
    ) {
        self.packageID = packageID
        self.versionCode = versionCode
        self.allowDowngrade = allowDowngrade
        self.mode = mode
        self.expectedSignerDigests = expectedSignerDigests
        self.artifacts = artifacts
    }
}

/// The Android package operations exposed to APKStoreCore.
///
/// APKStoreCore owns the policy and persistent records. RuntimeHost supplies the channel
/// implementation and routes Android work through RuntimeCore.
public protocol StoreAgentChannel: Sendable {
    /// Operations supported by this channel's Android image.
    var capabilities: StoreCapabilities { get }
    /// Whether the current transport session is still usable.
    var isConnected: Bool { get }
    /// PackageManager changes observed while this channel is connected.
    var packageEvents: AsyncStream<StorePackageEvent> { get }

    /// Inspects APK artifacts with Android's parser without installing them.
    func inspect(_ artifacts: [StoreArtifactSpec], files: [URL]) async throws -> StoreArchiveInfo
    /// Installs the supplied APK set and returns Android's resulting package metadata.
    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo
    /// Uninstalls a package, optionally preserving its Android app data.
    func uninstall(_ package: PackageID, keepData: Bool) async throws
    /// Returns Android's metadata for an installed package, if present.
    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo?
    /// Lists installed packages selected by `filter`.
    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary]
    /// Lists full metadata for packages installed for the current Android user.
    func listManagedPackages() async throws -> [StorePackageInfo]
    /// Closes any persistent guest transport owned by this channel.
    func close() async
}

extension StoreAgentChannel {
    /// Stateless ADB channels revalidate their runtime before being created.
    public var isConnected: Bool { true }

    /// Stateless ADB channels do not own a long-lived Store Agent transport.
    public func close() async {}

    /// Channels that do not keep a Store Agent connection have no live event stream.
    public var packageEvents: AsyncStream<StorePackageEvent> {
        AsyncStream { $0.finish() }
    }

    /// The stock-image channel does not expose Android archive inspection.
    public func inspect(_ artifacts: [StoreArtifactSpec], files: [URL]) async throws -> StoreArchiveInfo {
        _ = artifacts
        _ = files
        throw StoreAgentChannelFailure.capabilityMissing("inspect")
    }

    /// Stock Guest Agent channels return summaries, so query each installed package for full metadata.
    public func listManagedPackages() async throws -> [StorePackageInfo] {
        var packages: [StorePackageInfo] = []
        for summary in try await listPackages(.userInstalled) {
            if let info = try await packageInfo(summary.packageID) {
                packages.append(info)
            }
        }
        return packages
    }
}

/// Failures raised by the store channel abstraction.
public enum StoreAgentChannelFailure: Error, Equatable, Sendable {
    case capabilityMissing(String)
}

/// The runtime gate injected by RuntimeHost.
public protocol StoreRuntimeAccess: Sendable {
    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T

    func userdataGeneration() async -> UUID?
    func close() async
}

extension StoreRuntimeAccess {
    /// Releases any persistent channel owned by the runtime adapter.
    public func close() async {}
}
