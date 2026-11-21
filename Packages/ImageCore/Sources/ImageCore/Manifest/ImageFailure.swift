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

    /// The bundle holds a file its manifest does not list, or an installed image of the same
    /// name has a different manifest (runtime-image-manifest.md §7.1 step 7, §8.3 step 5).
    case unexpectedFile(file: String)

    /// An install or activation would move back to an older image version (§2.3).
    case downgradeRejected(from: String, to: String)

    /// The named image version is not installed (android-image.md §10.3).
    case imageNotInstalled(version: String)

    /// No image is current yet, so there is nothing to boot (android-image.md §9.3).
    case noCurrentImage

    /// The image needs a newer APKRun than the one running (§12.1).
    case incompatibleRuntime(minimum: String, found: String)

    /// The image's guest protocol range does not intersect the host's (§12.1).
    case incompatibleProtocol(minimum: Int, maximum: Int, hostMinimum: Int, hostMaximum: Int)

    /// The image cannot boot the instance's userdata schema (§12.1).
    case userdataSchemaUnsupported(schema: Int, supported: [Int])

    /// The current image is older than the target's `compatibility.upgradeFrom` floor (§12.1).
    case migrationSourceTooOld(source: String, minimum: String)

    /// An archive entry is not a plain relative file or directory (§12.4, manifest §8.3).
    case imageArchiveUnsafeEntry(path: String)

    /// apkrund found a `migration` record with no VM running (§12.3 crash safety).
    case migrationInterrupted

    /// A rollback or restore was requested but no recovery point exists (§4.8).
    case noRecoveryPoint

    /// The migrated image failed its health check and A was restored (§12.3 step 6b).
    case migrationHealthFailed(report: String)

    /// The version is on the image rejection list (runtime-maintenance.md §4.8).
    case imageRejected(version: String, reason: String)

    /// An image apply is already running.
    case imageUpdateBusy(detail: String)

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
        case .unexpectedFile: "unexpectedFile"
        case .downgradeRejected: "downgradeRejected"
        case .imageNotInstalled: "imageNotInstalled"
        case .noCurrentImage: "noCurrentImage"
        case .incompatibleRuntime: "incompatibleRuntime"
        case .incompatibleProtocol: "incompatibleProtocol"
        case .userdataSchemaUnsupported: "userdataSchemaUnsupported"
        case .migrationSourceTooOld: "migrationSourceTooOld"
        case .imageArchiveUnsafeEntry: "imageArchiveUnsafeEntry"
        case .migrationInterrupted: "migrationInterrupted"
        case .noRecoveryPoint: "noRecoveryPoint"
        case .migrationHealthFailed: "migrationHealthFailed"
        case .imageRejected: "imageRejected"
        case .imageUpdateBusy: "imageUpdateBusy"
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
        case .unexpectedFile(let file):
            ["file": .fileName(file)]
        case .downgradeRejected(let from, let to):
            ["from": .text(from), "to": .text(to)]
        case .imageNotInstalled(let version):
            ["version": .text(version)]
        case .noCurrentImage:
            [:]
        case .incompatibleRuntime(let minimum, let found):
            ["minimum": .text(minimum), "found": .text(found)]
        case .incompatibleProtocol(let minimum, let maximum, let hostMinimum, let hostMaximum):
            [
                "minimum": .count(minimum), "maximum": .count(maximum),
                "hostMinimum": .count(hostMinimum), "hostMaximum": .count(hostMaximum),
            ]
        case .userdataSchemaUnsupported(let schema, let supported):
            ["schema": .count(schema), "supported": .text(supported.map(String.init).joined(separator: ","))]
        case .migrationSourceTooOld(let source, let minimum):
            ["source": .text(source), "minimum": .text(minimum)]
        case .imageArchiveUnsafeEntry(let path):
            ["path": .fileName(path)]
        case .migrationInterrupted, .noRecoveryPoint:
            [:]
        case .migrationHealthFailed(let report):
            ["report": .text(report)]
        case .imageRejected(let version, let reason):
            ["version": .text(version), "reason": .text(reason)]
        case .imageUpdateBusy(let detail):
            ["detail": .text(detail)]
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
