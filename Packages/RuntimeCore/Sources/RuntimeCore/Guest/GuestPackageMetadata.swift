import Foundation

/// PackageManager metadata exposed by RuntimeCore without generated GuestProtocol messages.
public struct GuestPackageMetadata: Sendable, Equatable {
    /// The package name reported by PackageManager.
    public var package: String
    /// The package label in the Android default locale.
    public var label: String
    /// The installed version code.
    public var versionCode: Int64
    /// The installed version name.
    public var versionName: String
    /// Whether Android reports the package as enabled.
    public var enabled: Bool
    /// The launchable component, or an empty string when none exists.
    public var launchableComponent: String
    /// The installer of record, or an empty string when unavailable.
    public var installerPackage: String
    /// The first installation time in Unix milliseconds.
    public var firstInstallTimeMs: Int64
    /// The last update time in Unix milliseconds.
    public var lastUpdateTimeMs: Int64
    /// The target Android SDK.
    public var targetSDK: Int32
    /// The minimum Android SDK.
    public var minSDK: Int32
    /// SHA-256 digests of the current signing certificates.
    public var signingSHA256: [Data]

    /// Creates a package metadata value without generated GuestProtocol types.
    public init(
        package: String,
        label: String,
        versionCode: Int64,
        versionName: String,
        enabled: Bool,
        launchableComponent: String,
        installerPackage: String,
        firstInstallTimeMs: Int64,
        lastUpdateTimeMs: Int64,
        targetSDK: Int32,
        minSDK: Int32,
        signingSHA256: [Data]
    ) {
        self.package = package
        self.label = label
        self.versionCode = versionCode
        self.versionName = versionName
        self.enabled = enabled
        self.launchableComponent = launchableComponent
        self.installerPackage = installerPackage
        self.firstInstallTimeMs = firstInstallTimeMs
        self.lastUpdateTimeMs = lastUpdateTimeMs
        self.targetSDK = targetSDK
        self.minSDK = minSDK
        self.signingSHA256 = signingSHA256
    }
}

/// A PackageManager package-list entry exposed without generated GuestProtocol messages.
public struct GuestPackageSummary: Sendable, Equatable {
    /// The listed package name.
    public var package: String
    /// The package label in the Android default locale.
    public var label: String
    /// The installed version code.
    public var versionCode: Int64
    /// Whether the package has a launcher activity.
    public var launchable: Bool
    /// Whether the package is installed for the current Android user.
    public var userInstalled: Bool

    /// Creates a package listing value without generated GuestProtocol types.
    public init(package: String, label: String, versionCode: Int64, launchable: Bool, userInstalled: Bool) {
        self.package = package
        self.label = label
        self.versionCode = versionCode
        self.launchable = launchable
        self.userInstalled = userInstalled
    }
}

/// The package-list filter accepted by RuntimeCore's Guest Agent adapter.
public enum GuestPackageFilter: Sendable, Equatable {
    /// List packages that expose a launcher activity.
    case launchable
    /// List packages installed for the current Android user.
    case userInstalled
    /// List every package supported by the Guest Agent.
    case all
}
