import Foundation

/// The level an app works at ([scope.md](../../../docs/00-product/scope.md)
/// §4, diagnostics.md §10.2).
public enum CompatibilityLevel: String, Codable, Sendable, Equatable {
    /// No known issues.
    case works
    /// Works only with the listed settings or workarounds.
    case compatibilityMode
    /// Does not work; the review button becomes Install Anyway.
    case unsupported
}

/// One known issue of a database entry (diagnostics.md §10.2). Strings
/// ship in `en` and `ja`; `localized` falls back to `en` for any later
/// locale (#93).
public struct CompatibilityIssue: Codable, Sendable, Equatable {
    /// The stable issue identifier.
    public var id: String
    /// The issue title, keyed by locale (`en`, `ja`).
    public var title: [String: String]
    /// What APKRun or the user can do about it, keyed by locale.
    public var workaround: [String: String]?

    /// Creates an issue.
    public init(id: String, title: [String: String], workaround: [String: String]? = nil) {
        self.id = id
        self.title = title
        self.workaround = workaround
    }

    /// The string for `locale`, falling back to `en` then any value.
    public func text(_ strings: [String: String], locale: String) -> String {
        strings[locale] ?? strings["en"] ?? strings.values.first ?? ""
    }
}

/// The inclusive version range an entry applies to; `nil` is open.
public struct CompatibilityVersionRange: Codable, Sendable, Equatable {
    /// The lowest matching version code (inclusive), `nil` = unbounded.
    public var min: Int64?
    /// The highest matching version code (inclusive), `nil` = unbounded.
    public var max: Int64?

    /// Creates a range.
    public init(min: Int64? = nil, max: Int64? = nil) {
        self.min = min
        self.max = max
    }

    /// Whether `versionCode` sits inside the range.
    public func contains(_ versionCode: Int64) -> Bool {
        if let min, versionCode < min { return false }
        if let max, versionCode > max { return false }
        return true
    }

    /// How narrow the range is; `Int64.max` for an open end. Entries
    /// without a range are treated as infinitely wide.
    var span: Int64 {
        (max ?? .max) - (min ?? 0)
    }
}

/// One entry of the compatibility database (diagnostics.md §10.2).
public struct CompatibilityEntry: Codable, Sendable, Equatable {
    /// The Android package name the entry describes.
    public var packageID: String
    /// Signer SHA-256 hex digests; when present the entry applies only to
    /// builds signed by one of them.
    public var signerDigests: [String]?
    /// The version codes the entry applies to; absent matches everything.
    public var versionCodes: CompatibilityVersionRange?
    /// How well the app works.
    public var level: CompatibilityLevel
    /// The known issues.
    public var issues: [CompatibilityIssue]
    /// Per-package settings the app needs in their settings-store string
    /// form (the §10.2 key allowlist is enforced by
    /// `scripts/check-compatibility-db.sh`). JSON Booleans and numbers
    /// decode to their string form (see ``init(from:)``).
    public var recommendedSettings: [String: String]
    /// What the entry was tested with.
    public var testedWith: TestedWith
    /// `lab` or `report` (a reproduced user report).
    public var source: String

    /// The environment a compat entry was verified in.
    public struct TestedWith: Codable, Sendable, Equatable {
        /// The APKRun version.
        public var apkrun: String
        /// The Android image version.
        public var image: String
        /// The test date (ISO-8601 day).
        public var date: String

        /// Creates a testedWith record.
        public init(apkrun: String, image: String, date: String) {
            self.apkrun = apkrun
            self.image = image
            self.date = date
        }
    }

    /// Creates an entry.
    public init(
        packageID: String,
        signerDigests: [String]? = nil,
        versionCodes: CompatibilityVersionRange? = nil,
        level: CompatibilityLevel,
        issues: [CompatibilityIssue] = [],
        recommendedSettings: [String: String] = [:],
        testedWith: TestedWith,
        source: String
    ) {
        self.packageID = packageID
        self.signerDigests = signerDigests
        self.versionCodes = versionCodes
        self.level = level
        self.issues = issues
        self.recommendedSettings = recommendedSettings
        self.testedWith = testedWith
        self.source = source
    }

    /// The §10.2 format allows string, Boolean, and number setting values;
    /// each decodes to its settings-store string form (`false`, `1`, `v`).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageID = try container.decode(String.self, forKey: .packageID)
        signerDigests = try container.decodeIfPresent([String].self, forKey: .signerDigests)
        versionCodes = try container.decodeIfPresent(
            CompatibilityVersionRange.self, forKey: .versionCodes)
        level = try container.decode(CompatibilityLevel.self, forKey: .level)
        issues = try container.decodeIfPresent([CompatibilityIssue].self, forKey: .issues) ?? []
        let rawSettings =
            try container.decodeIfPresent(
                [String: SettingScalar].self, forKey: .recommendedSettings) ?? [:]
        recommendedSettings = rawSettings.mapValues(\.settingsValue)
        testedWith = try container.decode(TestedWith.self, forKey: .testedWith)
        source = try container.decode(String.self, forKey: .source)
    }

    /// One JSON scalar of a §10.2 `recommendedSettings` value.
    private enum SettingScalar: Decodable {
        case string(String)
        case flag(Bool)
        case number(Double)

        /// The settings-store string form.
        var settingsValue: String {
            switch self {
            case .string(let value): return value
            case .flag(let value): return value ? "true" : "false"
            case .number(let value):
                return value.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int64(value)) : String(value)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }
}

/// The shipped compatibility database (diagnostics.md §10). It is advice:
/// it recommends settings and reports known issues, and never blocks an
/// install. apkrund loads it once at start from the app bundle's
/// `Contents/Resources/compatibility.json`.
public struct CompatibilityDatabase: Sendable {
    /// The database's own format version.
    public var schemaVersion: Int
    /// All entries.
    public var entries: [CompatibilityEntry]

    /// The database with no entries.
    public static let empty = CompatibilityDatabase(schemaVersion: 1, entries: [])

    /// Creates a database.
    public init(schemaVersion: Int = 1, entries: [CompatibilityEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    /// The default database file inside `APKRun.app` resolved from the
    /// running executable (`Contents/Helpers/apkrund` →
    /// `Contents/Resources/compatibility.json`, diagnostics.md §10.1).
    public static func bundleURL(executableURL: URL) -> URL {
        executableURL
            .deletingLastPathComponent()  // Contents/Helpers
            .deletingLastPathComponent()  // Contents
            .appendingPathComponent("Resources/compatibility.json")
    }

    /// Loads the file; a missing or invalid file gives an empty database
    /// instead of a failure (§10.2).
    public static func load(from url: URL) -> CompatibilityDatabase {
        guard let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(Document.self, from: data),
            document.schemaVersion == 1
        else {
            return .empty
        }
        return CompatibilityDatabase(
            schemaVersion: document.schemaVersion, entries: document.entries)
    }

    /// The matching entry: package ID first, then signer digest when the
    /// entry lists digests (the database's bare hex digests compare equal
    /// to the canonical `sha256:`-prefixed form), then the version range.
    /// An entry that names a range only matches a known `versionCode` —
    /// without one its applicability cannot be verified. The narrowest
    /// range wins (§10.2).
    public func match(
        packageID: String,
        signerDigests: [String] = [],
        versionCode: Int64? = nil
    ) -> CompatibilityEntry? {
        let callerDigests = Set(signerDigests.map(Self.normalizedDigest))
        let candidates = entries.filter { entry in
            guard entry.packageID == packageID else { return false }
            if let digests = entry.signerDigests {
                guard
                    digests.contains(where: {
                        callerDigests.contains(Self.normalizedDigest($0))
                    })
                else { return false }
            }
            if let range = entry.versionCodes {
                guard let versionCode, range.contains(versionCode) else { return false }
            }
            return true
        }
        var best: CompatibilityEntry?
        var bestSpan = Int64.max
        for candidate in candidates {
            let span = candidate.versionCodes?.span ?? Int64.max
            if best == nil || span < bestSpan {
                best = candidate
                bestSpan = span
            }
        }
        return best
    }

    /// A digest compared without its `sha256:` prefix and case.
    private static func normalizedDigest(_ value: String) -> String {
        var digest = value.lowercased()
        if digest.hasPrefix("sha256:") { digest = String(digest.dropFirst(7)) }
        return digest
    }

    /// The `recommendedSettings` of the matching entry.
    public func recommendations(
        packageID: String,
        signerDigests: [String] = [],
        versionCode: Int64? = nil
    ) -> [String: String] {
        match(
            packageID: packageID,
            signerDigests: signerDigests,
            versionCode: versionCode)?.recommendedSettings ?? [:]
    }

    private struct Document: Decodable {
        var schemaVersion: Int
        var entries: [CompatibilityEntry]
    }
}
