import DiagnosticsCore

/// A typed failure raised while reading or validating an Android image manifest.
public enum ImageFailure: APKRunError, Equatable {
    /// The manifest is malformed or violates a schema or semantic rule.
    case manifestInvalid(path: String, reason: String)

    /// The stable error-code namespace owned by ImageCore.
    public static let domain: ErrorDomain = .image

    /// The stable catalog code for this failure.
    public var code: String {
        "manifestInvalid"
    }

    /// The manifest path and validation reason are logged by DiagnosticsCore.
    public var parameters: [String: ErrorParameter] {
        guard case .manifestInvalid(let path, let reason) = self else {
            return [:]
        }
        return [
            "path": .fileName(path),
            "reason": .text(reason),
        ]
    }
}
