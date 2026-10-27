import Foundation
import RuntimeAPI

/// The validated, versioned contents of `Wrappers/registry.json`.
public struct WrapperRegistryFile: Codable, Equatable, Sendable {
    /// Failures raised while validating registry data.
    public enum Failure: Error, Equatable, Sendable {
        /// The file or one of its records does not satisfy the registry schema.
        case invalidDocument
        /// The registry uses a schema version this build does not understand.
        case unsupportedSchemaVersion(Int)
        /// The encoded registry exceeds the 4 MiB limit.
        case fileTooLarge
        /// A filesystem operation failed. The domain and code omit path-bearing metadata.
        case ioFailure(domain: String, code: Int)
    }

    /// The schema version currently written by APKRun.
    public static let currentSchemaVersion = 1

    /// One authorized wrapper and the one package it may open.
    public struct Entry: Codable, Equatable, Sendable {
        /// How the wrapper was created.
        public enum Kind: String, Codable, Sendable {
            /// A wrapper generated from a package already in this APKRun installation.
            case local
            /// A wrapper that contains a portable bootstrap set.
            case portable
            /// A wrapper intended for distribution.
            case distribution
        }

        /// The durable state of one wrapper generation or refresh.
        public enum State: String, Codable, Sendable {
            /// The wrapper is authorized to open its package.
            case active
            /// A wrapper bundle is being generated.
            case pending
            /// A new launcher is staged while the old launcher remains authorized.
            case refreshing
        }

        /// The source of the wrapper's authorization.
        public enum Approval: String, Codable, Sendable {
            /// APKRun generated and signed the wrapper on this Mac.
            case generated
            /// The user approved the wrapper.
            case user
        }

        /// User-selected wrapper name and icon overrides.
        public struct Customization: Codable, Equatable, Sendable {
            /// The custom name, or `nil` to use the Android app label.
            public let displayName: String?

            /// The custom icon file name, or `nil` to use the Android app icon.
            public let iconFile: String?

            /// Creates the nullable customization fields stored in the registry.
            public init(displayName: String?, iconFile: String?) {
                self.displayName = displayName
                self.iconFile = iconFile
            }

            private enum CodingKeys: String, CodingKey {
                case displayName
                case iconFile
            }

            /// Decodes the required nullable customization fields.
            public init(from decoder: any Decoder) throws {
                try requireRegistryKeys(
                    decoder,
                    required: ["displayName", "iconFile"]
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                iconFile = try container.decodeIfPresent(String.self, forKey: .iconFile)
            }

            /// Encodes both fields, including `null` for unset customizations.
            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(displayName, forKey: .displayName)
                try container.encode(iconFile, forKey: .iconFile)
            }
        }

        /// The wrapper's code-signing identifier.
        public let bundleID: String

        /// The only Android package this wrapper may open.
        public let packageID: RuntimePackageID

        /// How this wrapper was created.
        public let kind: Kind

        /// Whether the bundle is active, pending, or refreshing.
        public let state: State

        /// The last known absolute path of the wrapper bundle.
        public let path: String

        /// Security-scoped bookmark for active or refreshing wrappers.
        public let bookmark: Data?

        /// Temporary bundle path used during generation or refresh.
        public let stagingPath: String?

        /// The authorized code directory hash.
        public let cdhash: String

        /// The new code directory hash while a launcher refresh is in progress.
        public let pendingCdhash: String?

        /// The APKRun version that built the launcher.
        public let launcherVersion: String

        /// The RuntimeAPI version implemented by the launcher.
        public let launcherAPI: String

        /// The wrapper manifest format version.
        public let formatVersion: Int

        /// The wrapper's file name without the `.app` suffix.
        public let fileName: String

        /// The display name presented by macOS.
        public let displayName: String

        /// User-selected name and icon overrides.
        public let customization: Customization

        /// SHA-256 digest of the Android icon master, or `nil` when unavailable or overridden.
        public let iconDigest: String?

        /// Whether APKRun generated or the user approved this wrapper.
        public let approval: Approval

        /// When the registry entry was created.
        public let createdAt: Date

        /// When the latest launcher refresh completed, or `nil` before one.
        public let refreshedAt: Date?

        /// When this wrapper was last statically validated, or `nil` before validation.
        public let lastValidatedAt: Date?

        /// Creates and validates one registry entry.
        public init(
            bundleID: String,
            packageID: RuntimePackageID,
            kind: Kind,
            state: State,
            path: String,
            bookmark: Data? = nil,
            stagingPath: String? = nil,
            cdhash: String,
            pendingCdhash: String? = nil,
            launcherVersion: String,
            launcherAPI: String,
            formatVersion: Int,
            fileName: String,
            displayName: String,
            customization: Customization,
            iconDigest: String?,
            approval: Approval,
            createdAt: Date,
            refreshedAt: Date?,
            lastValidatedAt: Date?
        ) throws(WrapperRegistryFile.Failure) {
            self.bundleID = bundleID
            self.packageID = packageID
            self.kind = kind
            self.state = state
            self.path = path
            self.bookmark = bookmark
            self.stagingPath = stagingPath
            self.cdhash = cdhash
            self.pendingCdhash = pendingCdhash
            self.launcherVersion = launcherVersion
            self.launcherAPI = launcherAPI
            self.formatVersion = formatVersion
            self.fileName = fileName
            self.displayName = displayName
            self.customization = customization
            self.iconDigest = iconDigest
            self.approval = approval
            self.createdAt = createdAt
            self.refreshedAt = refreshedAt
            self.lastValidatedAt = lastValidatedAt
            try validate()
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case packageID = "packageId"
            case kind
            case state
            case path
            case bookmark
            case stagingPath
            case cdhash
            case pendingCdhash
            case launcherVersion
            case launcherAPI
            case formatVersion
            case fileName
            case displayName
            case customization
            case iconDigest
            case approval
            case createdAt
            case refreshedAt
            case lastValidatedAt
        }

        /// Decodes and validates one registry entry.
        public init(from decoder: any Decoder) throws {
            let requiredKeys = [
                "bundleId", "packageId", "kind", "state", "path", "cdhash", "launcherVersion",
                "launcherAPI", "formatVersion", "fileName", "displayName", "customization",
                "iconDigest", "approval", "createdAt", "refreshedAt", "lastValidatedAt",
            ]
            try requireRegistryKeys(decoder, required: Set(requiredKeys))
            let presentKeys = try registryKeyNames(decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try container.decode(String.self, forKey: .bundleID)
            packageID = try container.decode(RuntimePackageID.self, forKey: .packageID)
            kind = try container.decode(Kind.self, forKey: .kind)
            state = try container.decode(State.self, forKey: .state)
            path = try container.decode(String.self, forKey: .path)
            bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
            stagingPath = try container.decodeIfPresent(String.self, forKey: .stagingPath)
            cdhash = try container.decode(String.self, forKey: .cdhash)
            pendingCdhash = try container.decodeIfPresent(String.self, forKey: .pendingCdhash)
            launcherVersion = try container.decode(String.self, forKey: .launcherVersion)
            launcherAPI = try container.decode(String.self, forKey: .launcherAPI)
            formatVersion = try container.decode(Int.self, forKey: .formatVersion)
            fileName = try container.decode(String.self, forKey: .fileName)
            displayName = try container.decode(String.self, forKey: .displayName)
            customization = try container.decode(Customization.self, forKey: .customization)
            iconDigest = try container.decodeIfPresent(String.self, forKey: .iconDigest)
            approval = try container.decode(Approval.self, forKey: .approval)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            refreshedAt = try container.decodeIfPresent(Date.self, forKey: .refreshedAt)
            lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
            try validateStateKeys(presentKeys)
            try validate()
        }

        /// Encodes required nullable metadata and only the state-specific optional fields.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(packageID, forKey: .packageID)
            try container.encode(kind, forKey: .kind)
            try container.encode(state, forKey: .state)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(bookmark, forKey: .bookmark)
            try container.encodeIfPresent(stagingPath, forKey: .stagingPath)
            try container.encode(cdhash, forKey: .cdhash)
            try container.encodeIfPresent(pendingCdhash, forKey: .pendingCdhash)
            try container.encode(launcherVersion, forKey: .launcherVersion)
            try container.encode(launcherAPI, forKey: .launcherAPI)
            try container.encode(formatVersion, forKey: .formatVersion)
            try container.encode(fileName, forKey: .fileName)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(customization, forKey: .customization)
            try container.encode(iconDigest, forKey: .iconDigest)
            try container.encode(approval, forKey: .approval)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(refreshedAt, forKey: .refreshedAt)
            try container.encode(lastValidatedAt, forKey: .lastValidatedAt)
        }

        private func validate() throws(WrapperRegistryFile.Failure) {
            guard
                bundleID == BundleIDMapper.map(packageID),
                WrapperRegistryFile.isValidBundleID(bundleID),
                WrapperRegistryFile.isValidAppPath(path),
                WrapperRegistryFile.isValidCDHash(cdhash),
                formatVersion >= 1,
                WrapperRegistryFile.isValidVersion(launcherVersion, components: 3, maximumBytes: 32),
                WrapperRegistryFile.isValidVersion(launcherAPI, components: 2, maximumBytes: 16),
                !fileName.isEmpty,
                fileName.utf8.count <= 251,
                !fileName.contains("/"),
                WrapperRegistryFile.isValidLabel(displayName),
                WrapperRegistryFile.isValidLabel(customization.displayName),
                customization.iconFile == nil || customization.iconFile == "\(bundleID).png",
                customization.iconFile == nil || iconDigest == nil,
                WrapperRegistryFile.isValidBookmark(bookmark),
                WrapperRegistryFile.isValidAppPath(stagingPath, allowingNil: true)
            else {
                throw .invalidDocument
            }
            if let iconDigest, !WrapperRegistryFile.isValidSHA256(iconDigest) {
                throw .invalidDocument
            }
            if let refreshedAt, refreshedAt < createdAt {
                throw .invalidDocument
            }

            switch state {
            case .active:
                guard bookmark != nil, stagingPath == nil, pendingCdhash == nil else {
                    throw .invalidDocument
                }
            case .pending:
                guard bookmark == nil, stagingPath != nil, pendingCdhash == nil else {
                    throw .invalidDocument
                }
            case .refreshing:
                guard
                    bookmark != nil,
                    stagingPath != nil,
                    let pendingCdhash,
                    WrapperRegistryFile.isValidCDHash(pendingCdhash),
                    pendingCdhash != cdhash
                else {
                    throw .invalidDocument
                }
            }
        }

        private func validateStateKeys(_ presentKeys: Set<String>) throws(WrapperRegistryFile.Failure) {
            let hasBookmark = presentKeys.contains("bookmark")
            let hasStagingPath = presentKeys.contains("stagingPath")
            let hasPendingCdhash = presentKeys.contains("pendingCdhash")
            switch state {
            case .active:
                guard hasBookmark, !hasStagingPath, !hasPendingCdhash else {
                    throw .invalidDocument
                }
            case .pending:
                guard !hasBookmark, hasStagingPath, !hasPendingCdhash else {
                    throw .invalidDocument
                }
            case .refreshing:
                guard hasBookmark, hasStagingPath, hasPendingCdhash else {
                    throw .invalidDocument
                }
            }
        }
    }

    /// A wrapper bundle denied for a particular code directory hash until a deadline.
    public struct DeniedEntry: Codable, Equatable, Sendable {
        /// The wrapper's bundle identifier.
        public let bundleID: String

        /// The refused code directory hash.
        public let cdhash: String

        /// The end of the denial period.
        public let until: Date

        /// Creates and validates one denial record.
        public init(bundleID: String, cdhash: String, until: Date) throws(WrapperRegistryFile.Failure) {
            self.bundleID = bundleID
            self.cdhash = cdhash
            self.until = until
            try validate()
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case cdhash
            case until
        }

        /// Decodes and validates one denial record.
        public init(from decoder: any Decoder) throws {
            try requireRegistryKeys(
                decoder,
                required: ["bundleId", "cdhash", "until"]
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try container.decode(String.self, forKey: .bundleID)
            cdhash = try container.decode(String.self, forKey: .cdhash)
            until = try container.decode(Date.self, forKey: .until)
            try validate()
        }

        /// Encodes the exact denied bundle identifier, hash, and deadline.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(cdhash, forKey: .cdhash)
            try container.encode(until, forKey: .until)
        }

        private func validate() throws(WrapperRegistryFile.Failure) {
            guard WrapperRegistryFile.isValidBundleID(bundleID), WrapperRegistryFile.isValidCDHash(cdhash) else {
                throw .invalidDocument
            }
        }
    }

    /// The registry schema version.
    public let schemaVersion: Int

    /// Authorized wrapper entries, sorted by bundle identifier.
    public let wrappers: [Entry]

    /// Denied wrapper hashes, sorted by bundle identifier and then code directory hash.
    public let denied: [DeniedEntry]

    /// Creates a canonical registry document and validates its entries.
    public init(wrappers: [Entry] = [], denied: [DeniedEntry] = []) throws(Failure) {
        schemaVersion = Self.currentSchemaVersion
        self.wrappers = wrappers.sorted { $0.bundleID < $1.bundleID }
        self.denied = denied.sorted {
            if $0.bundleID == $1.bundleID {
                return $0.cdhash < $1.cdhash
            }
            return $0.bundleID < $1.bundleID
        }
        try validate(requireSorted: true)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case wrappers
        case denied
    }

    /// Decodes a strictly validated schema-versioned registry.
    public init(from decoder: any Decoder) throws {
        try requireRegistryKeys(
            decoder,
            required: ["schemaVersion", "wrappers", "denied"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let wrappers = try container.decode([Entry].self, forKey: .wrappers)
        let denied = try container.decode([DeniedEntry].self, forKey: .denied)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw Failure.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.wrappers = wrappers
        self.denied = denied
        try validate(requireSorted: true)
    }

    /// Encodes a validated registry with its arrays in canonical order.
    public func encode(to encoder: any Encoder) throws {
        try validate(requireSorted: true)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(wrappers, forKey: .wrappers)
        try container.encode(denied, forKey: .denied)
    }

    func validateForWriting() throws(Failure) {
        try validate(requireSorted: true)
    }

    private func validate(requireSorted: Bool) throws(Failure) {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw .unsupportedSchemaVersion(schemaVersion)
        }
        guard wrappers.count <= 1000, denied.count <= 1000 else {
            throw .invalidDocument
        }
        guard
            Set(wrappers.map { $0.bundleID.lowercased() }).count == wrappers.count,
            Set(wrappers.map(\.packageID)).count == wrappers.count,
            Set(denied.map { "\($0.bundleID.lowercased())|\($0.cdhash)" }).count == denied.count
        else {
            throw .invalidDocument
        }
        if requireSorted {
            guard
                wrappers == wrappers.sorted(by: { $0.bundleID < $1.bundleID }),
                denied
                    == denied.sorted(by: {
                        if $0.bundleID == $1.bundleID {
                            return $0.cdhash < $1.cdhash
                        }
                        return $0.bundleID < $1.bundleID
                    })
            else {
                throw .invalidDocument
            }
        }
    }

    fileprivate static func isValidBundleID(_ value: String) -> Bool {
        let prefix = "io.apkrun.android."
        guard value.hasPrefix(prefix), value.count <= 255 else {
            return false
        }
        let suffix = value.dropFirst(prefix.count)
        return !suffix.isEmpty
            && suffix.unicodeScalars.allSatisfy { scalar in
                (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value)
                    || scalar.value == 45
                    || scalar.value == 46
            }
    }

    fileprivate static func isValidAppPath(_ value: String?, allowingNil: Bool = false) -> Bool {
        guard let value else {
            return allowingNil
        }
        let finalComponent = value.split(separator: "/", omittingEmptySubsequences: false).last
        let appName = finalComponent.map(String.init) ?? ""
        return value.hasPrefix("/")
            && value.hasSuffix(".app")
            && appName.hasSuffix(".app")
            && appName.count > ".app".count
            && value.utf8.count >= 6
            && value.utf8.count <= 1024
            && !value.utf8.contains(0)
    }

    fileprivate static func isValidCDHash(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    fileprivate static func isValidSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.utf8.count == 64
            && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    fileprivate static func isValidVersion(_ value: String, components: Int, maximumBytes: Int) -> Bool {
        guard value.utf8.count <= maximumBytes else {
            return false
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == components else {
            return false
        }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else {
                return false
            }
            return part == "0" || part.first != "0"
        }
    }

    fileprivate static func isValidLabel(_ value: String?) -> Bool {
        guard let value else {
            return true
        }
        return (1...1024).contains(value.unicodeScalars.count)
    }

    fileprivate static func isValidBookmark(_ bookmark: Data?) -> Bool {
        guard let bookmark else {
            return true
        }
        return (1...8192).contains(bookmark.count)
    }
}

private struct WrapperRegistryCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func registryKeyNames(_ decoder: any Decoder) throws -> Set<String> {
    let container = try decoder.container(keyedBy: WrapperRegistryCodingKey.self)
    return Set(container.allKeys.map(\.stringValue))
}

private func requireRegistryKeys(
    _ decoder: any Decoder,
    required: Set<String>
) throws {
    let present = try registryKeyNames(decoder)
    guard required.isSubset(of: present) else {
        throw WrapperRegistryFile.Failure.invalidDocument
    }
}
