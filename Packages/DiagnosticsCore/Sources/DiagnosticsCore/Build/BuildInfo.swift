import Foundation

/// The Xcode build configuration recorded in an APKRun product.
public enum BuildConfiguration: String, Codable, Sendable {
    /// A development build.
    case debug

    /// A production build.
    case release
}

/// Version and build metadata embedded in an APKRun executable or bundle.
public struct BuildInfo: Codable, Equatable, Sendable {
    /// The user-facing version, such as `0.1.0`.
    public let marketingVersion: String

    /// The monotonically increasing build number.
    public let buildNumber: String

    /// The build identity, such as `dev` or `release`.
    public let buildIdentity: String

    /// The seven-character Git revision, optionally suffixed with `-dirty`.
    public let gitCommit: String

    /// The configuration from which this product was built.
    public let configuration: BuildConfiguration

    /// Whether this executable includes the development-only embedded runtime.
    public let usesEmbeddedRuntime: Bool

    /// The LaunchAgent label associated with this build identity.
    public var launchAgentLabel: String {
        switch buildIdentity {
        case "dev":
            "io.apkrun.apkrund.dev"
        case "updatetest":
            "io.apkrun.apkrund.updatetest"
        default:
            "io.apkrun.apkrund"
        }
    }

    /// Metadata decoded from the current executable's Info.plist.
    public static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    /// Creates build metadata from an Info.plist dictionary.
    ///
    /// Missing keys use development-safe defaults so SwiftPM products remain usable.
    public init(infoDictionary: [String: Any]) {
        marketingVersion = infoDictionary["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
        buildNumber = infoDictionary["CFBundleVersion"] as? String ?? "0"
        buildIdentity = infoDictionary["APKRunBuildIdentity"] as? String ?? "dev"
        gitCommit = infoDictionary["APKRunGitCommit"] as? String ?? "unknown"

        if let value = infoDictionary["APKRunConfiguration"] as? String,
            let decoded = BuildConfiguration(rawValue: value.lowercased())
        {
            configuration = decoded
        } else {
            #if DEBUG
                configuration = .debug
            #else
                configuration = .release
            #endif
        }

        if let value = infoDictionary["APKRunEmbeddedRuntime"] as? Bool {
            usesEmbeddedRuntime = value
        } else if let value = infoDictionary["APKRunEmbeddedRuntime"] as? String {
            usesEmbeddedRuntime = ["yes", "true", "1"].contains(value.lowercased())
        } else {
            #if APKRUN_EMBEDDED_RUNTIME
                usesEmbeddedRuntime = true
            #else
                usesEmbeddedRuntime = false
            #endif
        }
    }
}
