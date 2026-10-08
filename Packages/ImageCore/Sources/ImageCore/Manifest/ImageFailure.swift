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
