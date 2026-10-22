import Foundation

/// A validated Android application ID on the RuntimeAPI boundary.
///
/// This is intentionally distinct from `APKStoreCore.PackageID`; the API module must not depend
/// on the package store. Its string representation is the Android package name.
public struct RuntimePackageID: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    /// The validated, case-sensitive Android package name.
    public let rawValue: String

    /// Creates an ID when `rawValue` follows Android's package-name grammar.
    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else {
            return nil
        }

        var segmentStart = 0
        var segmentCount = 0
        for (index, byte) in bytes.enumerated() {
            if byte == 46 {  // "."
                guard Self.isValidSegment(bytes[segmentStart..<index]) else {
                    return nil
                }
                segmentStart = index + 1
                segmentCount += 1
            }
        }
        guard Self.isValidSegment(bytes[segmentStart..<bytes.count]) else {
            return nil
        }

        segmentCount += 1
        guard segmentCount >= 2 else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Orders package IDs by their raw package-name value.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Decodes and validates the string wire representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let packageID = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Android package ID."
            )
        }
        self = packageID
    }

    /// Encodes the package ID as a JSON string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValidSegment(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let first = bytes.first, isASCIILetter(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { isASCIILetter($0) || isASCIIDigit($0) || $0 == 95 }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}

/// Android's `longVersionCode`, including `versionCodeMajor`.
public typealias RuntimeVersionCode = Int64

/// An opaque, short-lived preview ticket returned by `importPackage`.
public struct RuntimeImportTicket: RawRepresentable, Codable, Sendable, Hashable {
    /// The opaque store-issued ticket value.
    public let rawValue: String

    /// Creates a non-empty, bounded ticket without NUL characters.
    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue),
            uuid.uuidString.lowercased() == rawValue
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates the string wire representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let ticket = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid import ticket."
            )
        }
        self = ticket
    }

    /// Encodes the ticket as a JSON string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How a package import entered APKRun.
public enum RuntimeImportOrigin: String, Codable, Sendable, Equatable {
    case addFlow
    case document
    case dropOnHome
    case cli
    case wrap
}

/// Metadata describing a file attached to an import request.
public struct RuntimeImportSourceFile: Codable, Sendable, Equatable {
    /// Index into the `files` side-channel array passed to `importPackage`.
    public var fileIndex: Int
    /// A display-only basename. Callers must not send a full local path.
    public var name: String

    /// Creates source metadata for one attached file.
    public init(fileIndex: Int, name: String) {
        self.fileIndex = fileIndex
        self.name = name
    }
}

/// A request to copy and inspect a single APK or an APK split set.
public struct RuntimeImportPackageRequest: Codable, Sendable, Equatable {
    /// The files that form one APK or split set.
    public var files: [RuntimeImportSourceFile]
    /// The UI or command that initiated the import.
    public var origin: RuntimeImportOrigin

    /// Creates an import request.
    public init(files: [RuntimeImportSourceFile], origin: RuntimeImportOrigin) {
        self.files = files
        self.origin = origin
    }
}

/// A canonical SHA-256 digest used by package wire values.
public struct RuntimeSHA256Digest: RawRepresentable, Codable, Sendable, Hashable {
    /// The canonical lowercase `sha256:` digest string.
    public let rawValue: String

    /// Creates a digest from its canonical lowercase string representation.
    public init?(rawValue: String) {
        let prefix = "sha256:"
        guard rawValue.hasPrefix(prefix), rawValue.utf8.count == prefix.utf8.count + 64,
            rawValue.dropFirst(prefix.count).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates the canonical string representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let digest = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid SHA-256 digest.")
        }
        self = digest
    }

    /// Encodes the digest as its canonical string representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One APK included in the selected package artifact set.
public struct RuntimeArtifactFile: Codable, Sendable, Equatable {
    /// The store filename, for example `base.apk`.
    public var name: String
    /// The Android split name, or `nil` for the base APK.
    public var splitName: String?
    /// The file size in bytes.
    public var size: Int64
    /// The lowercase SHA-256 digest.
    public var sha256: RuntimeSHA256Digest

    /// Creates artifact metadata.
    public init(name: String, splitName: String? = nil, size: Int64, sha256: RuntimeSHA256Digest) {
        self.name = name
        self.splitName = splitName
        self.size = size
        self.sha256 = sha256
    }
}

/// The relationship of an inspected import to the currently known package.
public enum RuntimeImportRelation: Codable, Sendable, Equatable {
    case newPackage
    case sameAsInstalled
    case reinstallSameVersion
    case update(from: RuntimeVersionCode)
    case downgrade(from: RuntimeVersionCode)
    case otherSigner
    case uninstalledWithData(RuntimeVersionCode)
    case unknown

    private enum PayloadKey: String, CodingKey {
        case from
        case versionCode
    }

    private enum EmptyKey: String, CodingKey {
        case unused
    }

    /// Decodes the tagged import relationship from its wire representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeDynamicCodingKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Empty import relation."))
        }
        switch key.stringValue {
        case "newPackage": self = .newPackage
        case "sameAsInstalled": self = .sameAsInstalled
        case "reinstallSameVersion": self = .reinstallSameVersion
        case "otherSigner": self = .otherSigner
        case "update", "downgrade":
            let payload = try container.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
            let from = try payload.decode(RuntimeVersionCode.self, forKey: .from)
            self = key.stringValue == "update" ? .update(from: from) : .downgrade(from: from)
        case "uninstalledWithData":
            let payload = try container.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
            self = .uninstalledWithData(try payload.decode(RuntimeVersionCode.self, forKey: .versionCode))
        default:
            self = .unknown
        }
    }

    /// Encodes the tagged import relationship.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeDynamicCodingKey.self)
        switch self {
        case .newPackage:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("newPackage", encoder: encoder)
            )
        case .sameAsInstalled:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("sameAsInstalled", encoder: encoder)
            )
        case .reinstallSameVersion:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("reinstallSameVersion", encoder: encoder)
            )
        case .update(let from), .downgrade(let from):
            let name = self.isUpdate ? "update" : "downgrade"
            var payload = container.nestedContainer(
                keyedBy: PayloadKey.self,
                forKey: try RuntimeDynamicCodingKey.validated(name, encoder: encoder)
            )
            try payload.encode(from, forKey: .from)
        case .otherSigner:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("otherSigner", encoder: encoder)
            )
        case .uninstalledWithData(let versionCode):
            var payload = container.nestedContainer(
                keyedBy: PayloadKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("uninstalledWithData", encoder: encoder)
            )
            try payload.encode(versionCode, forKey: .versionCode)
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("unknown", encoder: encoder)
            )
        }
    }

    private var isUpdate: Bool {
        if case .update = self { true } else { false }
    }
}

/// A non-fatal observation from APK inspection.
public enum RuntimeImportWarning: Codable, Sendable, Equatable {
    case missingHardwareFeature(feature: String)
    case certificateOnlyVerification
    case signingNotChecked
    case debuggable
    case lowTargetSDK(target: Int)
}

/// The preview returned before a client asks the runtime to install an import.
public struct RuntimeImportPreview: Codable, Sendable, Equatable {
    /// The short-lived ticket required by `installImported`.
    public var ticket: RuntimeImportTicket
    /// The package name reported by the host inspector.
    public var packageID: RuntimePackageID
    /// The best host-side label found for the package.
    public var displayName: String
    /// Android's `longVersionCode`.
    public var versionCode: RuntimeVersionCode
    /// The display-only version string, if present.
    public var versionName: String?
    /// The current signer SHA-256 digests reported by APK inspection.
    public var signerDigests: [RuntimeSHA256Digest]
    /// APK files selected for installation.
    public var files: [RuntimeArtifactFile]
    /// Split names excluded by split selection.
    public var excludedSplits: [String]
    /// The import's relationship to the installed or retained package.
    public var relation: RuntimeImportRelation
    /// Non-fatal observations from host inspection.
    public var warnings: [RuntimeImportWarning]

    private enum CodingKeys: String, CodingKey {
        case ticket
        case packageID
        case displayName
        case versionCode
        case versionName
        case signerDigests
        case files
        case excludedSplits
        case relation
        case warnings
    }

    /// Creates an import preview.
    public init(
        ticket: RuntimeImportTicket,
        packageID: RuntimePackageID,
        displayName: String,
        versionCode: RuntimeVersionCode,
        versionName: String? = nil,
        signerDigests: [RuntimeSHA256Digest] = [],
        files: [RuntimeArtifactFile],
        excludedSplits: [String] = [],
        relation: RuntimeImportRelation,
        warnings: [RuntimeImportWarning] = []
    ) {
        self.ticket = ticket
        self.packageID = packageID
        self.displayName = displayName
        self.versionCode = versionCode
        self.versionName = versionName
        self.signerDigests = signerDigests
        self.files = files
        self.excludedSplits = excludedSplits
        self.relation = relation
        self.warnings = warnings
    }

    /// Decodes previews from earlier API minors that did not include signer digests.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try container.decode(RuntimeImportTicket.self, forKey: .ticket)
        packageID = try container.decode(RuntimePackageID.self, forKey: .packageID)
        displayName = try container.decode(String.self, forKey: .displayName)
        versionCode = try container.decode(RuntimeVersionCode.self, forKey: .versionCode)
        versionName = try container.decodeIfPresent(String.self, forKey: .versionName)
        signerDigests = try container.decodeIfPresent([RuntimeSHA256Digest].self, forKey: .signerDigests) ?? []
        files = try container.decode([RuntimeArtifactFile].self, forKey: .files)
        excludedSplits = try container.decode([String].self, forKey: .excludedSplits)
        relation = try container.decode(RuntimeImportRelation.self, forKey: .relation)
        warnings = try container.decode([RuntimeImportWarning].self, forKey: .warnings)
    }
}

/// The package update authority exposed to clients.
public enum RuntimeUpdateAuthority: String, Codable, Sendable, Equatable {
    case apkrun
    case googlePlay
    case external
    case manual
}

/// The package state exposed to clients.
public enum RuntimePackageState: Codable, Sendable, Equatable {
    case installing
    case installed
    case uninstalling
    case uninstalledKeepingData
    case broken(String)
    case unknown

    private enum PayloadKey: String, CodingKey {
        case reason
    }

    private enum EmptyKey: String, CodingKey {
        case unused
    }

    /// Decodes the tagged package state from its wire representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeDynamicCodingKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Empty package state."))
        }
        switch key.stringValue {
        case "installing": self = .installing
        case "installed": self = .installed
        case "uninstalling": self = .uninstalling
        case "uninstalledKeepingData": self = .uninstalledKeepingData
        case "broken":
            let payload = try container.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
            self = .broken(try payload.decode(String.self, forKey: .reason))
        default: self = .unknown
        }
    }

    /// Encodes the tagged package state.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeDynamicCodingKey.self)
        switch self {
        case .installing:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("installing", encoder: encoder)
            )
        case .installed:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("installed", encoder: encoder)
            )
        case .uninstalling:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("uninstalling", encoder: encoder)
            )
        case .uninstalledKeepingData:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("uninstalledKeepingData", encoder: encoder)
            )
        case .broken(let reason):
            var payload = container.nestedContainer(
                keyedBy: PayloadKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("broken", encoder: encoder)
            )
            try payload.encode(reason, forKey: .reason)
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: EmptyKey.self,
                forKey: try RuntimeDynamicCodingKey.validated("unknown", encoder: encoder)
            )
        }
    }
}

/// A compact row for package lists and successful installs.
public struct RuntimePackageSummary: Codable, Sendable, Equatable {
    /// The Android package name.
    public var packageID: RuntimePackageID
    /// The package label known to the host.
    public var displayName: String
    /// Android's `longVersionCode`, or `nil` when package metadata is unreadable.
    public var versionCode: RuntimeVersionCode?
    /// The display-only version string, if present.
    public var versionName: String?
    /// The known store state.
    public var state: RuntimePackageState
    /// Whether APKRun has a managed package record.
    public var managed: Bool
    /// The authority responsible for future updates.
    public var updateAuthority: RuntimeUpdateAuthority

    /// Creates a package summary.
    public init(
        packageID: RuntimePackageID,
        displayName: String,
        versionCode: RuntimeVersionCode?,
        versionName: String? = nil,
        state: RuntimePackageState = .installed,
        managed: Bool = true,
        updateAuthority: RuntimeUpdateAuthority = .manual
    ) {
        self.packageID = packageID
        self.displayName = displayName
        self.versionCode = versionCode
        self.versionName = versionName
        self.state = state
        self.managed = managed
        self.updateAuthority = updateAuthority
    }
}

/// The inspection result for `packageInfo`.
public struct RuntimePackageDetails: Codable, Sendable, Equatable {
    /// The summary returned by `listPackages`.
    public var summary: RuntimePackageSummary
    /// The APK files in the current stored artifact set.
    public var files: [RuntimeArtifactFile]
    /// The total size of the stored APK files, in bytes.
    public var artifactBytes: Int64
    /// The last known Android app-data size, in bytes.
    public var androidDataBytes: Int64?

    /// Creates package details.
    public init(
        summary: RuntimePackageSummary,
        files: [RuntimeArtifactFile],
        artifactBytes: Int64,
        androidDataBytes: Int64? = nil
    ) {
        self.summary = summary
        self.files = files
        self.artifactBytes = artifactBytes
        self.androidDataBytes = androidDataBytes
    }
}

/// Selects managed packages only or all packages Android reports as installed.
public enum RuntimePackageFilter: String, Codable, Sendable, Equatable {
    case managed
    case all
}

/// The installation authority selected for a new package.
public struct RuntimeInstallOptions: Codable, Sendable, Equatable {
    /// The authority assigned to a newly installed package.
    public var authority: RuntimeUpdateAuthority
    /// Whether to request wrapper creation after installation.
    public var createWrapper: Bool
    /// Reserved for wire compatibility. RuntimeHost rejects lower-version imports regardless.
    public var allowDowngrade: Bool

    /// Creates installation options.
    public init(
        authority: RuntimeUpdateAuthority = .manual,
        createWrapper: Bool = false,
        allowDowngrade: Bool = false
    ) {
        self.authority = authority
        self.createWrapper = createWrapper
        self.allowDowngrade = allowDowngrade
    }

    private enum CodingKeys: String, CodingKey {
        case authority
        case createWrapper
        case allowDowngrade
    }

    /// Decodes older clients with downgrade approval disabled by default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authority = try container.decodeIfPresent(RuntimeUpdateAuthority.self, forKey: .authority) ?? .manual
        createWrapper = try container.decodeIfPresent(Bool.self, forKey: .createWrapper) ?? false
        allowDowngrade = try container.decodeIfPresent(Bool.self, forKey: .allowDowngrade) ?? false
    }

    /// Encodes all install options for newer clients.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authority, forKey: .authority)
        try container.encode(createWrapper, forKey: .createWrapper)
        try container.encode(allowDowngrade, forKey: .allowDowngrade)
    }
}

/// Installs an import that was previously previewed.
public struct RuntimeInstallImportedRequest: Codable, Sendable, Equatable {
    /// The import ticket returned by `importPackage`.
    public var ticket: RuntimeImportTicket
    /// Options to apply while installing the import.
    public var options: RuntimeInstallOptions

    /// Creates an install request.
    public init(ticket: RuntimeImportTicket, options: RuntimeInstallOptions = RuntimeInstallOptions()) {
        self.ticket = ticket
        self.options = options
    }
}

/// Uninstall policy for app data and the APKRun package record.
public struct RuntimeUninstallOptions: Codable, Sendable, Equatable {
    /// Whether to retain Android app data for a later reinstall.
    public var keepData: Bool
    /// Whether wrapper bundles should be moved to the Trash.
    public var trashWrappers: Bool
    /// Whether to forget a broken package without contacting Android.
    public var forget: Bool

    /// Creates uninstall options.
    public init(keepData: Bool = false, trashWrappers: Bool = true, forget: Bool = false) {
        self.keepData = keepData
        self.trashWrappers = trashWrappers
        self.forget = forget
    }
}

/// Removes a package from Android or forgets a broken package record.
public struct RuntimeUninstallPackageRequest: Codable, Sendable, Equatable {
    /// The package to uninstall or forget.
    public var packageID: RuntimePackageID
    /// Data and wrapper policies for the operation.
    public var options: RuntimeUninstallOptions

    /// Creates an uninstall request.
    public init(packageID: RuntimePackageID, options: RuntimeUninstallOptions = RuntimeUninstallOptions()) {
        self.packageID = packageID
        self.options = options
    }
}

/// Lists the selected set of packages.
public struct RuntimeListPackagesRequest: Codable, Sendable, Equatable {
    /// The packages to include.
    public var filter: RuntimePackageFilter

    /// Creates a list request.
    public init(filter: RuntimePackageFilter = .managed) {
        self.filter = filter
    }
}

/// Where the package inventory in a list result came from.
public enum RuntimePackageListSource: String, Codable, Sendable, Equatable {
    /// Only APKRun's local managed records were available.
    case managedRecords
    /// Android PackageManager was queried for this result.
    case liveAndroid
    /// The Android inventory is the most recent saved snapshot.
    case cachedAndroid
    /// No Android inventory has been observed yet.
    case noAndroidInventory
}

/// A package list and the freshness of its Android inventory.
public struct RuntimePackageListResult: Codable, Sendable, Equatable {
    /// The package rows selected by the request.
    public var packages: [RuntimePackageSummary]
    /// The source of Android package facts.
    public var source: RuntimePackageListSource
    /// When the Android inventory was observed, or `nil` if none is saved.
    public var observedAt: Date?

    /// Creates a package list result.
    public init(
        packages: [RuntimePackageSummary],
        source: RuntimePackageListSource,
        observedAt: Date? = nil
    ) {
        self.packages = packages
        self.source = source
        self.observedAt = observedAt
    }
}

/// Identifies one package query.
public struct RuntimePackageRequest: Codable, Sendable, Equatable {
    /// The package to inspect.
    public var packageID: RuntimePackageID

    /// Creates a package query.
    public init(packageID: RuntimePackageID) {
        self.packageID = packageID
    }
}

/// Starts an app session for an installed package.
public struct RuntimeLaunchRequest: Codable, Sendable, Equatable {
    /// The package to launch.
    public var packageID: RuntimePackageID

    /// Creates a launch request.
    public init(packageID: RuntimePackageID) {
        self.packageID = packageID
    }
}

/// The lifecycle state of a launched app session.
public enum RuntimeSessionPhase: String, Codable, Sendable, Equatable {
    case starting
    case booting
    case waitingForPackage
    case acquiringDisplay
    case launching
    case running
    case closing
    case ended
    case unknown

    /// Decodes a known phase, mapping unrecognized values to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    /// Encodes the phase's stable wire string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private struct RuntimeDynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    static func validated(_ stringValue: String, encoder: any Encoder) throws -> Self {
        guard let key = Self(stringValue: stringValue) else {
            throw EncodingError.invalidValue(
                stringValue,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Could not create a coding key for a package operation."
                )
            )
        }
        return key
    }
}

/// The session opened for a launch request.
public struct RuntimeLaunchResult: Codable, Sendable, Equatable {
    /// The app session opened by the runtime.
    public var sessionID: UUID
    /// The package being launched.
    public var packageID: RuntimePackageID
    /// The session state when this reply was produced.
    public var state: RuntimeSessionPhase

    /// Creates a launch result.
    public init(sessionID: UUID, packageID: RuntimePackageID, state: RuntimeSessionPhase) {
        self.sessionID = sessionID
        self.packageID = packageID
        self.state = state
    }
}

/// Ends the session or force-stops this package if no session exists.
public struct RuntimeTerminateRequest: Codable, Sendable, Equatable {
    /// The package whose session or Android tasks should stop.
    public var packageID: RuntimePackageID

    /// Creates a termination request.
    public init(packageID: RuntimePackageID) {
        self.packageID = packageID
    }
}

/// The outcome of an application termination request.
public struct RuntimeTerminateResult: Codable, Sendable, Equatable {
    /// The package that was stopped.
    public var packageID: RuntimePackageID
    /// Whether the runtime had an active session to close.
    public var hadSession: Bool

    /// Creates a termination result.
    public init(packageID: RuntimePackageID, hadSession: Bool) {
        self.packageID = packageID
        self.hadSession = hadSession
    }
}

/// A stable, transport-safe runtime failure with a user-facing fallback message.
public struct RuntimeWireError: Error, Codable, Sendable, Equatable {
    /// The error domain, such as `runtime` or `store`.
    public var domain: String
    /// Stable qualified error code, such as `store.packageNotFound`.
    public var code: String
    /// A user-facing fallback message.
    public var message: String
    /// An optional action the user can take to recover.
    public var remediation: String?

    /// Creates a transport-safe failure.
    public init(domain: String, code: String, message: String, remediation: String? = nil) {
        self.domain = domain
        self.code = code
        self.message = message
        self.remediation = remediation
    }

    /// Creates a runtime-domain error.
    public static func runtime(_ code: String, message: String, remediation: String? = nil) -> Self {
        Self(domain: "runtime", code: "runtime.\(code)", message: message, remediation: remediation)
    }

    /// Creates a package-store-domain error.
    public static func store(_ code: String, message: String, remediation: String? = nil) -> Self {
        Self(domain: "store", code: "store.\(code)", message: message, remediation: remediation)
    }
}
