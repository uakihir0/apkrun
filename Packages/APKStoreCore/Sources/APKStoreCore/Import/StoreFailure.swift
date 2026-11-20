import Foundation

/// Refused container kinds of `StoreFailure.unsupportedContainer` (package-store.md §4.2, §10).
public enum ContainerKind: String, Codable, Sendable, Equatable {
    /// An Android App Bundle (.aab): converting would re-sign the bundle.
    case appBundle
    /// An encrypted or unreadable .apkm.
    case encryptedAPKM
    /// Content matching none of the supported formats.
    case unknown
}

/// The violated extraction limit of `StoreFailure.archiveLimitExceeded` (package-store.md §4.2).
public enum ArchiveLimit: String, Codable, Sendable, Equatable {
    case entryCount
    case apkCount
    case fileSize
    case totalSize
    case compressionRatio
    case unsafeName
}

/// The field that differs between APKs of one set (package-store.md §10).
public enum InconsistentField: String, Codable, Sendable, Equatable {
    case `package`
    case versionCode
    case signer
}

/// Failures of the host-side import and inspection pipeline (package-store.md §12, error-catalog §10).
///
/// The wire code of each failure is `store.<case>`; the enum's name feeds the error catalog's
/// `store` domain (error-catalog.md §2.1).
public enum StoreFailure: Error, Equatable, Sendable {
    /// The container kind is not supported (`.appBundle`, `.encryptedAPKM`, `.unknown`).
    case unsupportedContainer(ContainerKind)
    /// The ZIP structure cannot be read at all.
    case unreadableArchive(detail: String)
    /// An extraction limit of package-store.md §4.2 was violated.
    case archiveLimitExceeded(ArchiveLimit)
    /// An `.xapk` carries expansion (OBB) files, which v1 refuses.
    case expansionFilesNotSupported
    /// A file is not an APK with a manifest.
    case notAnAPK(file: String)
    /// The set has no base APK.
    case missingBase
    /// The set has more than one base APK.
    case multipleBases
    /// A split name appears twice.
    case duplicateSplit(String)
    /// The APKs differ in package, versionCode, or signer set.
    case inconsistentSplits(InconsistentField, file: String)
    /// `requiredSplitTypes` or `isSplitRequired` is not satisfied after selection.
    case incompleteSplitSet(missing: [String])
    /// An APK carries no signature.
    case unsignedAPK(file: String)
    /// A content digest or a signer signature does not verify.
    case invalidSignature(file: String, reason: String)
    /// v1 (JAR) signature only and `targetSdk >= 30`.
    case legacySignatureNotAllowed(targetSdk: Int)
    /// Native code for none of the guest ABIs.
    case unsupportedABI(found: [String], supported: [String])
    /// `minSdkVersion` above the guest SDK.
    case minSdkTooHigh(required: Int, guest: Int)
    /// `targetSdkVersion` below the install floor.
    case targetSdkTooLow(target: Int, floor: Int)
    /// An APKRun agent or image platform package.
    case reservedPackage(PackageID)
    /// A file above 2 GiB or the set above 8 GiB.
    case tooLarge(bytes: Int64, limit: Int64)
    /// `resources.arsc` compressed or not 4-byte aligned at `targetSdk >= 30`.
    case resourcesArscNotAligned(file: String)
    /// An I/O failure during extraction or verification.
    case io
}

extension StoreFailure {
    /// The `store.*` qualified code from error-catalog.md §10.
    public var errorCode: String {
        switch self {
        case .unsupportedContainer: "store.unsupportedContainer"
        case .unreadableArchive: "store.unreadableArchive"
        case .archiveLimitExceeded: "store.archiveLimitExceeded"
        case .expansionFilesNotSupported: "store.expansionFilesNotSupported"
        case .notAnAPK: "store.notAnAPK"
        case .missingBase: "store.missingBase"
        case .multipleBases: "store.multipleBases"
        case .duplicateSplit: "store.duplicateSplit"
        case .inconsistentSplits: "store.inconsistentSplits"
        case .incompleteSplitSet: "store.incompleteSplitSet"
        case .unsignedAPK: "store.unsignedAPK"
        case .invalidSignature: "store.invalidSignature"
        case .legacySignatureNotAllowed: "store.legacySignatureNotAllowed"
        case .unsupportedABI: "store.unsupportedABI"
        case .minSdkTooHigh: "store.minSdkTooHigh"
        case .targetSdkTooLow: "store.targetSdkTooLow"
        case .reservedPackage: "store.reservedPackage"
        case .tooLarge: "store.tooLarge"
        case .resourcesArscNotAligned: "store.resourcesArscNotAligned"
        case .io: "store.unreadableArchive"
        }
    }

    /// The sub-case variant of error-catalog.md §10, when the failure has one.
    public var errorVariant: String? {
        switch self {
        case .unsupportedContainer(let kind): kind.rawValue
        case .archiveLimitExceeded(let limit): limit.rawValue
        case .inconsistentSplits(let field, _): field.rawValue
        default: nil
        }
    }
}
