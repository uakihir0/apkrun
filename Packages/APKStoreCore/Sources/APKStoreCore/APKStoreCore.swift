import CryptoKit
import Foundation

/// An Android package name.
///
/// Android package names are case-sensitive and contain at least two dot-separated
/// ASCII segments. Each segment starts with a letter and continues with letters,
/// digits, or underscores.
public struct PackageID: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    /// The validated Android package name.
    public let rawValue: String

    /// Creates a package ID when `rawValue` follows Android's package-name grammar.
    public init?(rawValue: String) {
        guard rawValue.utf8.count <= 255 else { return nil }

        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
            segments.allSatisfy(Self.isValidSegment)
        else {
            return nil
        }

        self.rawValue = rawValue
    }

    /// Decodes and validates a package-name string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let packageID = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Android package name."
            )
        }
        self = packageID
    }

    /// Encodes the package ID as its raw string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Orders package IDs lexicographically by their case-sensitive names.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isValidSegment(_ segment: Substring) -> Bool {
        guard let first = segment.utf8.first, isASCIILetter(first) else { return false }
        return segment.utf8.dropFirst().allSatisfy {
            isASCIILetter($0) || (48...57).contains($0) || $0 == 95
        }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// Android's longVersionCode, including versionCodeMajor in its high 32 bits.
public typealias VersionCode = Int64

/// A lowercase SHA-256 digest serialized as `sha256:<64 lowercase hex characters>`.
public struct SHA256Digest: RawRepresentable, Codable, Sendable, Hashable {
    /// The canonical `sha256:`-prefixed digest string.
    public let rawValue: String

    /// The 64 lowercase hexadecimal characters without the `sha256:` prefix.
    public var hexValue: String {
        String(rawValue.dropFirst("sha256:".count))
    }

    /// Creates a digest from its canonical `sha256:`-prefixed string.
    public init?(rawValue: String) {
        guard rawValue.hasPrefix("sha256:") else { return nil }
        let hex = rawValue.dropFirst("sha256:".count)
        guard hex.utf8.count == 64,
            hex.utf8.allSatisfy(Self.isLowercaseHexDigit)
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Creates a digest from exactly 64 lowercase hexadecimal characters.
    public init?(hex: String) {
        self.init(rawValue: "sha256:\(hex)")
    }

    /// Computes a SHA-256 digest over the provided bytes.
    public init(data: Data) {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        self.rawValue = "sha256:\(hex)"
    }

    /// Decodes and validates a canonical digest string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let digest = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid SHA-256 digest."
            )
        }
        self = digest
    }

    /// Encodes the digest as its canonical string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

/// What a caller hands to the package store.
public enum PackageArtifact: Sendable, Hashable {
    case apk(URL)
    case splitSet(base: URL, splits: [URL])
}

/// One file of an inspected APK set.
public struct ArtifactFile: Codable, Sendable, Hashable {
    /// The normalized stored filename, such as `base.apk`.
    public var name: String
    /// The Android split name, or `nil` for the base APK.
    public var splitName: String?
    /// The file size in bytes.
    public var size: Int64
    /// The SHA-256 digest of the APK bytes.
    public var sha256: SHA256Digest

    /// Creates an artifact-file summary.
    public init(name: String, splitName: String?, size: Int64, sha256: SHA256Digest) {
        self.name = name
        self.splitName = splitName
        self.size = size
        self.sha256 = sha256
    }
}

/// Provenance for the host-side inspection recorded in `artifact.json`.
///
/// The design specifies these values but does not yet standardize their JSON
/// property names; these names are a practical baseline for the initial store.
public struct InspectionProvenance: Codable, Sendable, Hashable {
    /// The version string reported by the bundled aapt2 executable.
    public var aapt2Version: String
    /// The APKRun verifier version used for host checks.
    public var verifierVersion: String
    /// When host inspection completed.
    public var inspectedAt: Date
    /// The host checks performed during inspection.
    public var hostChecksPerformed: [String]

    /// Creates inspection metadata for an artifact set.
    public init(
        aapt2Version: String,
        verifierVersion: String,
        inspectedAt: Date,
        hostChecksPerformed: [String]
    ) {
        self.aapt2Version = aapt2Version
        self.verifierVersion = verifierVersion
        self.inspectedAt = inspectedAt
        self.hostChecksPerformed = hostChecksPerformed
    }
}

/// The content of `artifact.json` in a package artifact slot.
public struct ArtifactSet: Codable, Sendable, Hashable {
    /// The artifact metadata schema version.
    public var schemaVersion: Int
    /// The package name contained in the APK set.
    public var packageID: PackageID
    /// Android's long version code for the set.
    public var versionCode: VersionCode
    /// The display-only Android version name, when present.
    public var versionName: String?
    /// The base APK followed by splits ordered by split name.
    public var files: [ArtifactFile]
    /// The canonical digest of all files in the set.
    public var setDigest: SHA256Digest
    /// The current signer digests for the set.
    public var signerDigests: [SHA256Digest]
    /// The signing lineage, oldest signer first.
    public var lineage: [SHA256Digest]
    /// The host inspection provenance for the set.
    public var inspection: InspectionProvenance

    /// Creates metadata for a verified APK set.
    public init(
        schemaVersion: Int = 1,
        packageID: PackageID,
        versionCode: VersionCode,
        versionName: String? = nil,
        files: [ArtifactFile],
        setDigest: SHA256Digest,
        signerDigests: [SHA256Digest],
        lineage: [SHA256Digest],
        inspection: InspectionProvenance
    ) {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.versionCode = versionCode
        self.versionName = versionName
        self.files = files
        self.setDigest = setDigest
        self.signerDigests = signerDigests
        self.lineage = lineage
        self.inspection = inspection
    }

    /// Computes §3.3's digest from files sorted by their stored file name.
    ///
    /// Duplicate names are rejected because they do not describe a valid set and
    /// would otherwise make the canonical input ambiguous.
    public static func computeSetDigest(for files: [ArtifactFile]) throws -> SHA256Digest {
        var seenNames = Set<String>()
        for file in files {
            guard seenNames.insert(file.name).inserted else {
                throw SetDigestError.duplicateFileName(file.name)
            }
        }

        let canonicalLines = files.sorted { $0.name < $1.name }.map {
            "\($0.name)\t\($0.sha256.hexValue)\n"
        }.joined()
        return SHA256Digest(data: Data(canonicalLines.utf8))
    }
}

/// Errors raised while computing the canonical digest of an APK set.
public enum SetDigestError: Error, Equatable, Sendable {
    case duplicateFileName(String)
}

/// The installer recorded for an Android package.
public enum Installer: String, Codable, Sendable {
    case apkrun
    case external
}

/// The single authority allowed to update a package.
public enum UpdateAuthority: String, Codable, Sendable {
    case apkrun
    case googlePlay
    case external
    case manual
}

/// A supported Android application update provider.
public enum ProviderType: String, Codable, Sendable, Hashable {
    case local
    case direct
    case fdroid
    case github
}

/// The GitHub release channel selected by a provider configuration.
public enum GitHubReleaseChannel: String, Codable, Sendable, Hashable {
    case stable
    case prerelease
}

/// Provider-specific configuration stored with a package record.
public enum ProviderConfiguration: Sendable, Hashable {
    case local(path: String, bookmark: String)
    case direct(url: String)
    case fdroid(repository: String, fingerprint: String)
    case github(repository: String, assetPattern: String, channel: GitHubReleaseChannel)
}

/// A provider type paired with its provider-specific stored configuration.
public struct UpdateProviderRef: Codable, Sendable, Hashable {
    /// The provider type associated with the configuration.
    public var type: ProviderType
    /// The provider-specific configuration fields.
    public var configuration: ProviderConfiguration

    /// Creates a provider reference.
    public init(type: ProviderType, configuration: ProviderConfiguration) {
        self.type = type
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case configuration
    }

    /// Decodes the flat provider configuration selected by its provider type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ProviderType.self, forKey: .type)
        let configurationDecoder = try container.superDecoder(forKey: .configuration)
        self.type = type
        self.configuration = try ProviderConfiguration(from: configurationDecoder, type: type)
    }

    /// Encodes the provider reference with a flat provider-specific configuration.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try configuration.encode(to: container.superEncoder(forKey: .configuration), type: type)
    }
}

private struct ProviderConfigurationCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

extension ProviderConfiguration {
    fileprivate init(from decoder: any Decoder, type: ProviderType) throws {
        let container = try decoder.container(keyedBy: ProviderConfigurationCodingKey.self)
        switch type {
        case .local:
            self = .local(
                path: try container.decode(String.self, forKey: Self.key("path")),
                bookmark: try container.decode(String.self, forKey: Self.key("bookmark"))
            )
        case .direct:
            self = .direct(url: try container.decode(String.self, forKey: Self.key("url")))
        case .fdroid:
            self = .fdroid(
                repository: try container.decode(String.self, forKey: Self.key("repository")),
                fingerprint: try container.decode(String.self, forKey: Self.key("fingerprint"))
            )
        case .github:
            self = .github(
                repository: try container.decode(String.self, forKey: Self.key("repository")),
                assetPattern: try container.decode(String.self, forKey: Self.key("assetPattern")),
                channel: try container.decode(
                    GitHubReleaseChannel.self,
                    forKey: Self.key("channel")
                )
            )
        }
    }

    fileprivate func encode(to encoder: any Encoder, type: ProviderType) throws {
        var container = encoder.container(keyedBy: ProviderConfigurationCodingKey.self)
        switch (type, self) {
        case (.local, .local(let path, let bookmark)):
            try container.encode(path, forKey: Self.key("path"))
            try container.encode(bookmark, forKey: Self.key("bookmark"))
        case (.direct, .direct(let url)):
            try container.encode(url, forKey: Self.key("url"))
        case (.fdroid, .fdroid(let repository, let fingerprint)):
            try container.encode(repository, forKey: Self.key("repository"))
            try container.encode(fingerprint, forKey: Self.key("fingerprint"))
        case (.github, .github(let repository, let assetPattern, let channel)):
            try container.encode(repository, forKey: Self.key("repository"))
            try container.encode(assetPattern, forKey: Self.key("assetPattern"))
            try container.encode(channel, forKey: Self.key("channel"))
        default:
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Provider configuration does not match its provider type."
                )
            )
        }
    }

    private static func key(_ name: String) -> ProviderConfigurationCodingKey {
        guard let key = ProviderConfigurationCodingKey(stringValue: name) else {
            preconditionFailure("Provider configuration keys are non-empty strings.")
        }
        return key
    }
}

/// A summary of one installed or retained artifact slot.
public struct ArtifactSlotSummary: Codable, Sendable, Hashable {
    /// Android's long version code for this slot.
    public var versionCode: VersionCode
    /// The display-only Android version name, when present.
    public var versionName: String?
    /// The digest of all APK files in the slot.
    public var setDigest: SHA256Digest
    /// The combined size of the APK files in bytes.
    public var size: Int64
    /// The number of APK files in the slot.
    public var fileCount: Int

    /// Creates a summary for a non-staged artifact slot.
    public init(
        versionCode: VersionCode,
        versionName: String? = nil,
        setDigest: SHA256Digest,
        size: Int64,
        fileCount: Int
    ) {
        self.versionCode = versionCode
        self.versionName = versionName
        self.setDigest = setDigest
        self.size = size
        self.fileCount = fileCount
    }
}

/// The source that supplied a staged artifact set.
public enum ArtifactOriginType: String, Codable, Sendable, Hashable {
    case local
    case direct
    case fdroid
    case github
    case manualFile
}

/// Provenance recorded for a staged artifact set.
public struct ArtifactOrigin: Codable, Sendable, Hashable {
    /// The provider or local source kind.
    public var type: ArtifactOriginType
    /// The sanitized source URL, when one is available.
    public var url: String?
    /// Digests declared by the source, in artifact order.
    public var declaredDigests: [SHA256Digest]?

    /// Creates an artifact-origin summary.
    public init(
        type: ArtifactOriginType,
        url: String? = nil,
        declaredDigests: [SHA256Digest]? = nil
    ) {
        self.type = type
        self.url = url
        self.declaredDigests = declaredDigests
    }
}

/// A summary of a staged artifact slot, including its origin.
public struct StagedArtifactSlotSummary: Codable, Sendable, Hashable {
    /// Android's long version code for the staged set.
    public var versionCode: VersionCode
    /// The display-only Android version name, when present.
    public var versionName: String?
    /// The digest of all APK files in the staged set.
    public var setDigest: SHA256Digest
    /// The combined size of the staged APK files in bytes.
    public var size: Int64
    /// The number of APK files in the staged set.
    public var fileCount: Int
    /// The source that supplied the staged set.
    public var origin: ArtifactOrigin

    /// Creates a staged artifact-slot summary.
    public init(
        versionCode: VersionCode,
        versionName: String? = nil,
        setDigest: SHA256Digest,
        size: Int64,
        fileCount: Int,
        origin: ArtifactOrigin
    ) {
        self.versionCode = versionCode
        self.versionName = versionName
        self.setDigest = setDigest
        self.size = size
        self.fileCount = fileCount
        self.origin = origin
    }
}

/// Summaries of the current, previous, and staged package artifact slots.
public struct ArtifactSlots: Codable, Sendable, Hashable {
    /// The set Android should currently have installed.
    public var current: ArtifactSlotSummary?
    /// The last known-good set retained for rollback.
    public var previous: ArtifactSlotSummary?
    /// A verified update waiting for installation.
    public var staged: StagedArtifactSlotSummary?
    /// Whether the current artifact set matches Android's installed package.
    public var currentMatchesAndroid: Bool

    /// Creates an artifact-slot summary.
    public init(
        current: ArtifactSlotSummary? = nil,
        previous: ArtifactSlotSummary? = nil,
        staged: StagedArtifactSlotSummary? = nil,
        currentMatchesAndroid: Bool
    ) {
        self.current = current
        self.previous = previous
        self.staged = staged
        self.currentMatchesAndroid = currentMatchesAndroid
    }
}

/// The last known facts read from Android's PackageManager.
public struct AndroidPackageFacts: Codable, Sendable, Hashable {
    /// The package that owns update installation, when set.
    public var updateOwner: PackageID?
    /// The package recorded as the installer, when available.
    public var installerOfRecord: PackageID?
    /// When Android first installed the package.
    public var firstInstallTime: Date?
    /// When Android last updated the package.
    public var lastUpdateTime: Date?
    /// The package's minimum supported Android SDK.
    public var minSdk: Int
    /// The package's target Android SDK.
    public var targetSdk: Int
    /// Native ABIs present in the installed package.
    public var nativeAbis: [String]
    /// The generation identifier of the guest userdata image.
    public var userdataGeneration: UUID
    /// When these package facts were last read from Android.
    public var lastSyncedAt: Date

    /// Creates a snapshot of Android package facts.
    public init(
        updateOwner: PackageID? = nil,
        installerOfRecord: PackageID? = nil,
        firstInstallTime: Date? = nil,
        lastUpdateTime: Date? = nil,
        minSdk: Int,
        targetSdk: Int,
        nativeAbis: [String],
        userdataGeneration: UUID,
        lastSyncedAt: Date
    ) {
        self.updateOwner = updateOwner
        self.installerOfRecord = installerOfRecord
        self.firstInstallTime = firstInstallTime
        self.lastUpdateTime = lastUpdateTime
        self.minSdk = minSdk
        self.targetSdk = targetSdk
        self.nativeAbis = nativeAbis
        self.userdataGeneration = userdataGeneration
        self.lastSyncedAt = lastSyncedAt
    }
}

/// The category of the event that first brought a package to this Mac.
public enum PackageSourceKind: String, Codable, Sendable, Hashable {
    case file
    case provider
    case wrapperBootstrap
    case adopted
}

/// The user-facing entry point that initiated an import.
public enum ImportOrigin: String, Codable, Sendable, Hashable {
    case addFlow
    case document
    case dropOnHome
    case cli
    case wrap
}

/// A recognized package container format.
public enum PackageContainerKind: String, Codable, Sendable, Hashable {
    case apk
    case apks
    case xapk
    case apkm
    case zip
}

/// Immutable provenance describing how a package first arrived on this Mac.
public struct PackageSource: Codable, Sendable, Hashable {
    /// The initial source category.
    public var kind: PackageSourceKind
    /// When the initial import or adoption began.
    public var at: Date
    /// The entry point for a user-supplied file import.
    public var origin: ImportOrigin?
    /// The original file names, without parent paths.
    public var fileNames: [String]?
    /// The detected container format, when applicable.
    public var container: PackageContainerKind?
    /// The provider that supplied the first install, when applicable.
    public var providerType: ProviderType?
    /// The bundle ID of the wrapper that carried the bootstrap APK.
    public var wrapperBundleId: String?

    /// Creates package-source provenance.
    public init(
        kind: PackageSourceKind,
        at: Date,
        origin: ImportOrigin? = nil,
        fileNames: [String]? = nil,
        container: PackageContainerKind? = nil,
        providerType: ProviderType? = nil,
        wrapperBundleId: String? = nil
    ) {
        self.kind = kind
        self.at = at
        self.origin = origin
        self.fileNames = fileNames
        self.container = container
        self.providerType = providerType
        self.wrapperBundleId = wrapperBundleId
    }
}

/// The underlying system error details retained in a stored error.
public struct StoredErrorUnderlying: Codable, Sendable, Hashable {
    /// The system error domain.
    public var domain: String
    /// The system error code.
    public var code: Int

    /// Creates a system-error summary without user information.
    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// A privacy-filtered parameter value in a stored error.
public enum StoredErrorParameter: Codable, Sendable, Hashable {
    case text(String)
    case bytes(Int64)
    case count(Int64)
    case durationMs(Int64)
    case fileName(String)

    private enum CodingKeys: String, CodingKey {
        case text
        case bytes
        case count
        case durationMs
        case fileName
    }

    /// Decodes exactly one supported parameter value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid error parameter.")
            )
        }
        switch key {
        case .text: self = .text(try container.decode(String.self, forKey: .text))
        case .bytes: self = .bytes(try container.decode(Int64.self, forKey: .bytes))
        case .count: self = .count(try container.decode(Int64.self, forKey: .count))
        case .durationMs: self = .durationMs(try container.decode(Int64.self, forKey: .durationMs))
        case .fileName: self = .fileName(try container.decode(String.self, forKey: .fileName))
        }
    }

    /// Encodes the parameter as a single-key tagged object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value): try container.encode(value, forKey: .text)
        case .bytes(let value): try container.encode(value, forKey: .bytes)
        case .count(let value): try container.encode(value, forKey: .count)
        case .durationMs(let value): try container.encode(value, forKey: .durationMs)
        case .fileName(let value): try container.encode(value, forKey: .fileName)
        }
    }
}

/// A persisted, privacy-filtered error without runtime-only context.
public final class StoredError: Codable, Sendable, Hashable {
    /// The error domain.
    public let domain: String
    /// The qualified error code.
    public let code: String
    /// Parameters used to render the error.
    public let parameters: [String: StoredErrorParameter]
    /// A nested cause, when the error is wrapped.
    public let cause: StoredError?
    /// The underlying system error without user information.
    public let underlying: StoredErrorUnderlying?

    /// Creates a stored error.
    public init(
        domain: String,
        code: String,
        parameters: [String: StoredErrorParameter] = [:],
        cause: StoredError? = nil,
        underlying: StoredErrorUnderlying? = nil
    ) {
        self.domain = domain
        self.code = code
        self.parameters = parameters
        self.cause = cause
        self.underlying = underlying
    }

    /// Compares stored errors by their serialized values.
    public static func == (lhs: StoredError, rhs: StoredError) -> Bool {
        lhs.domain == rhs.domain
            && lhs.code == rhs.code
            && lhs.parameters == rhs.parameters
            && lhs.cause == rhs.cause
            && lhs.underlying == rhs.underlying
    }

    /// Adds the serialized values to a hash.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(domain)
        hasher.combine(code)
        hasher.combine(parameters)
        hasher.combine(cause)
        hasher.combine(underlying)
    }
}

/// Why an installed package needs to be restored from its stored APK set.
public enum ReinstallReason: String, Codable, Sendable {
    case userdataReset
    case userdataRestored
}

/// Why the store considers a package broken.
public enum BrokenReason: Sendable, Equatable {
    case removedInAndroid
    case signerChanged
    case artifactMissing
    case reinstallFailed(StoredError)

    private enum CodingKeys: String, CodingKey {
        case reinstallFailed
        case payload = "_0"
    }
}

extension BrokenReason: Codable {
    /// Decodes a persisted broken reason.
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
            let value = try? container.decode(String.self)
        {
            switch value {
            case "removedInAndroid": self = .removedInAndroid
            case "signerChanged": self = .signerChanged
            case "artifactMissing": self = .artifactMissing
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown broken reason."
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys == [.reinstallFailed] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid broken reason.")
            )
        }
        let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .reinstallFailed)
        self = .reinstallFailed(try payload.decode(StoredError.self, forKey: .payload))
    }

    /// Encodes a broken reason using the metadata schema's tagged form.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .removedInAndroid:
            var container = encoder.singleValueContainer()
            try container.encode("removedInAndroid")
        case .signerChanged:
            var container = encoder.singleValueContainer()
            try container.encode("signerChanged")
        case .artifactMissing:
            var container = encoder.singleValueContainer()
            try container.encode("artifactMissing")
        case .reinstallFailed(let error):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .reinstallFailed)
            try payload.encode(error, forKey: .payload)
        }
    }
}

/// Stable states written to `metadata.json`.
///
/// Import, install, update, and uninstall progress is transient and is derived
/// while operations are running; only the stable states in the metadata schema
/// are encoded here.
public enum PackageState: Sendable, Equatable {
    case installed
    case uninstalledKeepingData
    case needsReinstall(ReinstallReason)
    case broken(BrokenReason)

    private enum CodingKeys: String, CodingKey {
        case needsReinstall
        case broken
        case payload = "_0"
    }
}

extension PackageState: Codable {
    /// Decodes a stable state from `metadata.json`.
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
            let value = try? container.decode(String.self)
        {
            switch value {
            case "installed": self = .installed
            case "uninstalledKeepingData": self = .uninstalledKeepingData
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown stable package state."
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid package state.")
            )
        }

        switch key {
        case .needsReinstall:
            let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .needsReinstall)
            self = .needsReinstall(try payload.decode(ReinstallReason.self, forKey: .payload))
        case .broken:
            let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .broken)
            self = .broken(try payload.decode(BrokenReason.self, forKey: .payload))
        case .payload:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid package state.")
            )
        }
    }

    /// Encodes a stable state using the metadata schema's tagged form.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .installed:
            var container = encoder.singleValueContainer()
            try container.encode("installed")
        case .uninstalledKeepingData:
            var container = encoder.singleValueContainer()
            try container.encode("uninstalledKeepingData")
        case .needsReinstall(let reason):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .needsReinstall)
            try payload.encode(reason, forKey: .payload)
        case .broken(let reason):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .broken)
            try payload.encode(reason, forKey: .payload)
        }
    }
}

/// The package operation summarized in the record.
public enum OperationKind: String, Codable, Sendable, Hashable {
    case firstInstall
    case reinstall
    case update
    case rollback
    case uninstall
    case adopt
}

/// The terminal result of a package operation.
public enum OperationResult: String, Codable, Sendable, Hashable {
    case succeeded
    case failed
    case interrupted
    case rollbackUnavailable
}

/// The result of an update health check.
public enum HealthResult: String, Codable, Sendable, Hashable {
    case passed
    case failed
}

/// The most recently completed operation recorded for a package.
public struct OperationSummary: Codable, Sendable, Hashable {
    /// The operation kind.
    public var kind: OperationKind
    /// The operation's stable identifier.
    public var operationID: UUID
    /// When the operation began.
    public var startedAt: Date
    /// When the operation finished.
    public var finishedAt: Date
    /// The version installed before a reinstall, update, or rollback.
    public var fromVersionCode: VersionCode?
    /// The target version code.
    public var toVersionCode: VersionCode?
    /// Whether the operation succeeded, failed, or was interrupted.
    public var result: OperationResult
    /// Whether the post-update health check is still pending.
    public var healthPending: Bool?
    /// The result of the post-update health check, when available.
    public var healthResult: HealthResult?
    /// Consecutive failures for a boot-time reinstall.
    public var failureCount: Int?
    /// The privacy-filtered operation error, when one occurred.
    public var error: StoredError?

    /// Creates a completed operation summary.
    public init(
        kind: OperationKind,
        operationID: UUID,
        startedAt: Date,
        finishedAt: Date,
        fromVersionCode: VersionCode? = nil,
        toVersionCode: VersionCode? = nil,
        result: OperationResult,
        healthPending: Bool? = nil,
        healthResult: HealthResult? = nil,
        failureCount: Int? = nil,
        error: StoredError? = nil
    ) {
        self.kind = kind
        self.operationID = operationID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.fromVersionCode = fromVersionCode
        self.toVersionCode = toVersionCode
        self.result = result
        self.healthPending = healthPending
        self.healthResult = healthResult
        self.failureCount = failureCount
        self.error = error
    }
}

/// The persistent metadata record for one managed Android package.
public struct PackageRecord: Codable, Sendable, Equatable {
    /// The package-record schema version.
    public var schemaVersion: Int
    /// The Android package name; it does not change for this record.
    public var packageId: PackageID
    /// The Android label in the guest's current locale.
    public var displayName: String
    /// Android's installed long version code.
    public var versionCode: VersionCode
    /// The display-only Android version name, when present.
    public var versionName: String?
    /// The current signer set reported by Android.
    public var signingCertificates: [SHA256Digest]
    /// The signing history, oldest signer first.
    public var signingLineage: [SHA256Digest]
    /// Which installer installed the package in Android.
    public var installer: Installer
    /// The sole authority allowed to update the package.
    public var updateAuthority: UpdateAuthority
    /// The configured provider, if one is attached.
    public var updateProvider: UpdateProviderRef?
    /// The latest stable state persisted for the package.
    public var state: PackageState
    /// Summaries of the package's retained artifact slots.
    public var artifacts: ArtifactSlots
    /// The last known Android package facts.
    public var android: AndroidPackageFacts
    /// How this package first arrived on this Mac.
    public var source: PackageSource
    /// The most recently completed operation, if any.
    public var lastOperation: OperationSummary?
    /// When the record was first created.
    public var createdAt: Date
    /// When the record was last updated.
    public var updatedAt: Date

    /// Creates a package record, defaulting new packages to manual updates.
    public init(
        schemaVersion: Int = 1,
        packageId: PackageID,
        displayName: String,
        versionCode: VersionCode,
        versionName: String? = nil,
        signingCertificates: [SHA256Digest],
        signingLineage: [SHA256Digest] = [],
        installer: Installer,
        updateAuthority: UpdateAuthority = .manual,
        updateProvider: UpdateProviderRef? = nil,
        state: PackageState,
        artifacts: ArtifactSlots,
        android: AndroidPackageFacts,
        source: PackageSource,
        lastOperation: OperationSummary? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.packageId = packageId
        self.displayName = displayName
        self.versionCode = versionCode
        self.versionName = versionName
        self.signingCertificates = signingCertificates
        self.signingLineage = signingLineage
        self.installer = installer
        self.updateAuthority = updateAuthority
        self.updateProvider = updateProvider
        self.state = state
        self.artifacts = artifacts
        self.android = android
        self.source = source
        self.lastOperation = lastOperation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Identifies a package directory whose persisted metadata cannot be read safely.
///
/// `detail` is a stable, non-sensitive reason code. It never contains decoded package
/// contents or file paths.
public struct PackageRecordIssue: Sendable, Equatable {
    /// The package identity recovered from the record or its directory name.
    public let packageID: PackageID
    /// A stable reason such as `invalidMetadata` or `unsupportedSchemaVersion`.
    public let detail: String

    /// Creates a package record issue.
    public init(packageID: PackageID, detail: String) {
        self.packageID = packageID
        self.detail = detail
    }
}
