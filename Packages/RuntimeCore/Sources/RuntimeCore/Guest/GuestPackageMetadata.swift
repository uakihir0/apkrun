/// Filters for PackageManager-backed package queries.
public enum GuestPackageFilter: Equatable, Sendable {
    /// Packages with a launchable activity.
    case launchable

    /// Packages installed for the current Android user.
    case userInstalled

    /// Every package reported by PackageManager.
    case all
}

/// Package metadata returned by the Android Guest Agent.
public struct GuestPackageInfo: Equatable, Sendable {
    /// Android package identifier.
    public let package: String

    /// Package version code.
    public let versionCode: Int64

    /// Human-readable package version.
    public let versionName: String

    /// Default-locale display label.
    public let label: String

    /// Whether Android currently enables the package.
    public let enabled: Bool

    /// Launchable activity component, if one exists.
    public let launchableComponent: String

    /// Package that Android records as the installer.
    public let installerPackage: String

    /// First installation time in milliseconds since the Unix epoch.
    public let firstInstallTimeMs: Int64

    /// Last update time in milliseconds since the Unix epoch.
    public let lastUpdateTimeMs: Int64

    /// Android target SDK version.
    public let targetSdk: Int32

    /// Minimum supported Android SDK version.
    public let minSdk: Int32

    /// SHA-256 digests of the current package signers.
    public let signingSha256: [Data]

    /// Creates a host-facing copy of PackageManager metadata.
    public init(
        package: String,
        versionCode: Int64,
        versionName: String,
        label: String,
        enabled: Bool,
        launchableComponent: String,
        installerPackage: String,
        firstInstallTimeMs: Int64,
        lastUpdateTimeMs: Int64,
        targetSdk: Int32,
        minSdk: Int32,
        signingSha256: [Data]
    ) {
        self.package = package
        self.versionCode = versionCode
        self.versionName = versionName
        self.label = label
        self.enabled = enabled
        self.launchableComponent = launchableComponent
        self.installerPackage = installerPackage
        self.firstInstallTimeMs = firstInstallTimeMs
        self.lastUpdateTimeMs = lastUpdateTimeMs
        self.targetSdk = targetSdk
        self.minSdk = minSdk
        self.signingSha256 = signingSha256
    }
}

/// One package in a filtered PackageManager listing.
public struct GuestPackageSummary: Equatable, Sendable {
    /// Android package identifier.
    public let package: String

    /// Default-locale display label.
    public let label: String

    /// Package version code.
    public let versionCode: Int64

    /// Whether the package has a launchable activity.
    public let launchable: Bool

    /// Whether the package is installed for the current Android user.
    public let userInstalled: Bool

    /// Creates a host-facing package summary.
    public init(package: String, label: String, versionCode: Int64, launchable: Bool, userInstalled: Bool) {
        self.package = package
        self.label = label
        self.versionCode = versionCode
        self.launchable = launchable
        self.userInstalled = userInstalled
    }
}
