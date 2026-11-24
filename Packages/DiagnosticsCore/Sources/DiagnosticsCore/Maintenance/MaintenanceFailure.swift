import Foundation

/// A typed failure raised by the maintenance machinery (runtime-maintenance.md §11).
public enum MaintenanceFailure: APKRunError, Equatable {
    /// A file carries a schema version newer than this build understands (§5). The
    /// file is never written; the owning component starts degraded.
    case dataCreatedByNewerVersion(file: String, schema: Int, supported: Int)

    /// A migration step `from → to` failed (§5).
    case schemaMigrationFailed(file: String, from: Int, to: Int, detail: String)

    /// A maintenance operation was cancelled (§11).
    case cancelled

    /// The stable error-code namespace owned by maintenance.
    public static let domain: ErrorDomain = .maintenance

    /// The stable catalog code for this failure.
    public var code: String {
        switch self {
        case .dataCreatedByNewerVersion: "dataCreatedByNewerVersion"
        case .schemaMigrationFailed: "schemaMigrationFailed"
        case .cancelled: "cancelled"
        }
    }

    /// Catalog parameters. File paths are reduced to file names.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .dataCreatedByNewerVersion(let file, let schema, let supported):
            ["file": .fileName(file), "schema": .count(schema), "supported": .count(supported)]
        case .schemaMigrationFailed(let file, let from, let to, let detail):
            [
                "file": .fileName(file), "from": .count(from), "to": .count(to),
                "detail": .text(detail),
            ]
        case .cancelled:
            [:]
        }
    }
}
