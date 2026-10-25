import Foundation
import RuntimeAPI

/// Operations announced by a connected Store Agent.
public struct RuntimeStoreCapabilities: OptionSet, Sendable, Hashable {
    /// The capability bits negotiated with the Store Agent.
    public let rawValue: UInt16

    /// Creates a capability set from its raw bits.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Package installation is available.
    public static let install = Self(rawValue: 1 << 0)
    /// Package metadata queries are available.
    public static let metadata = Self(rawValue: 1 << 1)
    /// APK archive inspection is available.
    public static let inspect = Self(rawValue: 1 << 2)
}

/// The Android package listing requested from the Store Agent.
public enum RuntimeStorePackageFilter: Sendable, Equatable {
    /// Return packages that expose a launcher activity.
    case launchable
    /// Return packages installed for the current Android user.
    case userInstalled
    /// Return every package supported by the Store Agent.
    case all
}

/// A package artifact descriptor accepted by the Store Agent runtime client.
public struct RuntimeStoreArtifactSpec: Sendable, Equatable, Hashable {
    /// The APK or split name.
    public var name: String
    /// The exact artifact size in bytes.
    public var size: UInt64
    /// The lowercase SHA-256 hex digest, without a prefix.
    public var sha256: String

    /// Creates an artifact descriptor.
    public init(name: String, size: UInt64, sha256: String) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// Store Agent install parameters, independent of APKStoreCore's policy types.
public struct RuntimeStoreInstallRequest: Sendable, Equatable {
    /// The requested PackageInstaller operation.
    public enum Mode: Sendable, Equatable {
        /// Create a new package installation.
        case installNew
        /// Update an existing package.
        case update
        /// Reinstall the package with the requested install options.
        case reinstall
    }

    /// The package whose installation was requested.
    public var packageID: RuntimePackageID
    /// The required installed version.
    public var versionCode: RuntimeVersionCode
    /// Whether the guest may install a lower version. Store Agent installs reject this.
    public var allowDowngrade: Bool
    /// The installation operation.
    public var mode: Mode
    /// Lowercase SHA-256 hex digests, without prefixes.
    public var expectedSignerDigests: [String]
    /// The artifacts that make up the APK set.
    public var artifacts: [RuntimeStoreArtifactSpec]

    /// Creates an install request using RuntimeCore-owned package and artifact values.
    public init(
        packageID: RuntimePackageID,
        versionCode: RuntimeVersionCode,
        allowDowngrade: Bool = false,
        mode: Mode = .installNew,
        expectedSignerDigests: [String] = [],
        artifacts: [RuntimeStoreArtifactSpec] = []
    ) {
        self.packageID = packageID
        self.versionCode = versionCode
        self.allowDowngrade = allowDowngrade
        self.mode = mode
        self.expectedSignerDigests = expectedSignerDigests
        self.artifacts = artifacts
    }
}

/// APK facts returned by the Store Agent's Android package parser.
public struct RuntimeStoreArchiveInfo: Sendable, Equatable {
    /// The package identity parsed from the archive.
    public var packageID: RuntimePackageID
    /// The version parsed from the archive.
    public var versionCode: RuntimeVersionCode
    /// The optional version name from the archive.
    public var versionName: String?
    /// The names of the APK splits in the set.
    public var splitNames: [String]
    /// The native ABIs contained by the archive.
    public var nativeABIs: [String]
    /// The minimum Android SDK required by the archive.
    public var minSDK: Int
    /// The target Android SDK declared by the archive.
    public var targetSDK: Int
    /// Lowercase SHA-256 hex digests, without prefixes.
    public var signingDigests: [String]
    /// The Android APK signing scheme version.
    public var signingSchemeVersion: Int

    /// Creates an immutable projection of archive facts.
    public init(
        packageID: RuntimePackageID,
        versionCode: RuntimeVersionCode,
        versionName: String? = nil,
        splitNames: [String],
        nativeABIs: [String],
        minSDK: Int,
        targetSDK: Int,
        signingDigests: [String],
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

/// Package metadata read from Android's PackageManager through the Store Agent.
public struct RuntimeStorePackageInfo: Sendable, Equatable {
    /// The package identity reported by PackageManager.
    public var packageID: RuntimePackageID
    /// The package label in the Android default locale.
    public var displayName: String
    /// The installed version code.
    public var versionCode: RuntimeVersionCode
    /// The installed version name, if present.
    public var versionName: String?
    /// Whether Android reports the package as enabled.
    public var enabled: Bool
    /// The launchable component, if one exists.
    public var launchableComponent: String?
    /// The installer of record, if Android reports one.
    public var installerPackage: RuntimePackageID?
    /// The first installation time.
    public var firstInstallTime: Date?
    /// The last package update time.
    public var lastUpdateTime: Date?
    /// The target Android SDK.
    public var targetSDK: Int
    /// The minimum Android SDK.
    public var minSDK: Int
    /// Lowercase SHA-256 hex digests, without prefixes.
    public var signingDigests: [String]
    /// Earlier certificates in Android's signing lineage.
    public var signingLineage: [String]
    /// The APK signing scheme version.
    public var signingSchemeVersion: Int
    /// The package authorized to own updates, if set.
    public var updateOwner: RuntimePackageID?
    /// The package that initiated this installation, if available.
    public var initiatingPackage: RuntimePackageID?
    /// The installed APK split names.
    public var splitNames: [String]
    /// The native ABIs exposed by the installed package.
    public var nativeABIs: [String]
    /// Whether Android reports the package as suspended.
    public var suspended: Bool
    /// The number of permissions declared by the package.
    public var requestedPermissionsCount: Int

    /// Creates a package metadata projection.
    public init(
        packageID: RuntimePackageID,
        displayName: String,
        versionCode: RuntimeVersionCode,
        versionName: String? = nil,
        enabled: Bool,
        launchableComponent: String? = nil,
        installerPackage: RuntimePackageID? = nil,
        firstInstallTime: Date? = nil,
        lastUpdateTime: Date? = nil,
        targetSDK: Int,
        minSDK: Int,
        signingDigests: [String] = [],
        signingLineage: [String] = [],
        signingSchemeVersion: Int = 0,
        updateOwner: RuntimePackageID? = nil,
        initiatingPackage: RuntimePackageID? = nil,
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

/// A package summary for listing installed packages.
public struct RuntimeStorePackageSummary: Sendable, Equatable {
    /// The listed package identity.
    public var packageID: RuntimePackageID
    /// The package label in the Android default locale.
    public var displayName: String
    /// The installed version code.
    public var versionCode: RuntimeVersionCode
    /// Whether the package has a launcher activity.
    public var launchable: Bool
    /// Whether the package is installed for the current Android user.
    public var userInstalled: Bool

    /// Creates a package listing projection.
    public init(
        packageID: RuntimePackageID,
        displayName: String,
        versionCode: RuntimeVersionCode,
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

/// A package lifecycle event reported by Android.
public struct RuntimeStorePackageEvent: Sendable, Equatable {
    /// The package lifecycle change observed in Android.
    public enum Kind: Sendable, Equatable {
        /// Android added the package.
        case added
        /// Android replaced the package with an update.
        case replaced
        /// Android removed the package.
        case removed
        /// Android changed package state or metadata.
        case changed
    }

    /// The package whose state changed.
    public var packageID: RuntimePackageID
    /// The kind of package change.
    public var kind: Kind
    /// The package version after the change, or zero when removed.
    public var versionCode: RuntimeVersionCode

    /// Creates a package lifecycle event.
    public init(packageID: RuntimePackageID, kind: Kind, versionCode: RuntimeVersionCode) {
        self.packageID = packageID
        self.kind = kind
        self.versionCode = versionCode
    }
}
