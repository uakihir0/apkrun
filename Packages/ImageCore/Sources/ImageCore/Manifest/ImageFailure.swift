import DiagnosticsCore

/// A typed failure raised by ImageCore (android-image.md §14.1).
public enum ImageFailure: APKRunError, Equatable {
    /// The manifest is malformed or violates a schema or semantic rule.
    case manifestInvalid(path: String, reason: String)

    /// Provisioning would leave less than the free-space margin (android-image.md §5.2).
    case insufficientSpace(required: Int64, available: Int64)

    /// The instance directory is not on APFS, so disks cannot be cloned (§5.1).
    case cloneUnsupported(volume: String)

    /// `clonefile(2)`, `ftruncate`, or `fsync` of an instance disk failed.
    case cloneFailed(underlying: UnderlyingError)

    /// An instance disk or the instance record is inconsistent.
    case instanceCorrupt(reason: String)

    /// The instance record exists but a disk is missing (android-image.md §9.3 step 2).
    case instanceMissing

    /// A file that the manifest lists is missing.
    case missingFile(file: String)

    /// A file's size (quick check) or SHA-256 (full check) differs from the manifest.
    case hashMismatch(file: String)

    /// Two bootconfig layers set one key, and the later one has no override (§6.1).
    case bootconfigConflict(key: String, layerA: String, layerB: String)

    /// The serialized bootconfig exceeds the kernel's limit (§6.3).
    case bootconfigTooLarge(size: Int)

    /// The kernel command line exceeds 2048 bytes (§6.4).
    case cmdlineTooLong(length: Int)

    /// The key ID in `manifest.sig` is not in the trust list (runtime-image-manifest.md §6.1).
    case untrustedKey(keyID: String)

    /// The signature does not verify under the trusted key with that ID (§6.1).
    case signatureInvalid(keyID: String)

    /// The stable error-code namespace owned by ImageCore.
    public static let domain: ErrorDomain = .image

    /// The stable catalog code for this failure.
    public var code: String {
        switch self {
        case .manifestInvalid: "manifestInvalid"
        case .insufficientSpace: "insufficientSpace"
        case .cloneUnsupported: "cloneUnsupported"
        case .cloneFailed: "cloneFailed"
        case .instanceCorrupt: "instanceCorrupt"
        case .instanceMissing: "instanceMissing"
        case .missingFile: "missingFile"
        case .hashMismatch: "hashMismatch"
        case .bootconfigConflict: "bootconfigConflict"
        case .bootconfigTooLarge: "bootconfigTooLarge"
        case .cmdlineTooLong: "cmdlineTooLong"
        case .untrustedKey: "untrustedKey"
        case .signatureInvalid: "signatureInvalid"
        }
    }

    /// Catalog parameters. Paths are reduced to file names, and reasons are logged only.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .manifestInvalid(let path, let reason):
            ["path": .fileName(path), "reason": .text(reason)]
        case .insufficientSpace(let required, let available):
            ["needed": .bytes(required), "available": .bytes(available)]
        case .cloneUnsupported(let volume):
            ["volume": .text(volume)]
        case .cloneFailed:
            [:]
        case .instanceCorrupt(let reason):
            ["reason": .text(reason)]
        case .instanceMissing:
            [:]
        case .missingFile(let file), .hashMismatch(let file):
            ["file": .fileName(file)]
        case .bootconfigConflict(let key, let layerA, let layerB):
            ["key": .text(key), "layerA": .text(layerA), "layerB": .text(layerB)]
        case .bootconfigTooLarge(let size):
            ["size": .bytes(Int64(size))]
        case .cmdlineTooLong(let length):
            ["length": .count(length)]
        case .untrustedKey(let keyID), .signatureInvalid(let keyID):
            ["keyID": .text(keyID)]
        }
    }

    /// The system error behind `cloneFailed`.
    public var underlying: UnderlyingError? {
        guard case .cloneFailed(let underlying) = self else {
            return nil
        }
        return underlying
    }
}
