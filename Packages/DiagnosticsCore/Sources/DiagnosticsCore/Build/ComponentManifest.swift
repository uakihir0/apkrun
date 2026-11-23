import Foundation

/// The schema versions a build understands for each on-disk JSON file
/// (runtime-maintenance.md §5). `write-components.py` copies this table into
/// `components.json`, and `SchemaMigrator` drives migrations from it.
public enum DataSchemas {
    /// Current schema version per owned file, relative to the APKRun data root
    /// ([filesystem-layout.md]). Every entry starts at 1; a change to a file's
    /// shape raises its version and adds a migration step.
    public static let current: [String: Int] = [
        "settings.json": 1,
        "Runtime/state.json": 1,
        "Runtime/instance/instance.json": 1,
        "Packages/journal.jsonl": 1,
        "Updates/state.json": 1,
        "Updates/history.jsonl": 1,
        "Images/update-state.json": 1,
    ]
}

/// The `components.json` manifest a built APKRun.app bundle carries in
/// `Contents/Resources` (build-system.md §5, runtime-maintenance.md §2.1).
public struct ComponentManifest: Codable, Equatable, Sendable {
    /// The user-facing version, such as `1.2.0` (`MARKETING_VERSION`).
    public let version: String

    /// The monotonically increasing build number (`CURRENT_PROJECT_VERSION`).
    public let build: String

    /// The update channel: `stable` for release builds, `dev` otherwise
    /// (`APKRUN_CHANNEL`). No `beta` build exists; a candidate is published on
    /// the beta channel and promoted unchanged.
    public let channel: String

    /// The seven-character Git revision, optionally suffixed with `-dirty`.
    public let commit: String

    /// The RuntimeAPI version of this build (`APIVersion.current`).
    public let runtimeAPI: String

    /// The host-side guest protocol version (`ProtocolVersion.host`).
    public let guestProtocol: String

    /// The schema versions this build understands, from `DataSchemas.current`.
    public let dataSchemas: [String: Int]

    /// SHA-256 of the embedded LaunchAgent plist (§3.7 re-registration).
    public let agentPlistSHA256: String

    /// The `version` of every shipped lock entry, plus the Sparkle version and
    /// `devGuestAgentVersionCode` (build-system.md §5).
    public let components: [String: String]

    /// The manifest packaged inside `bundle`, or `nil` when it has none
    /// (SwiftPM products and unpackaged test binaries).
    public static func packaged(in bundle: Bundle) -> ComponentManifest? {
        guard
            let url = bundle.url(forResource: "components", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ComponentManifest.self, from: data)
    }

    /// The manifest of the running executable's main bundle.
    public static let current = packaged(in: .main)
}
