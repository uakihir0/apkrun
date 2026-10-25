import DiagnosticsCore
import Foundation

/// A file integration operation could not proceed.
public enum IntegrationFailure: APKRunError, Equatable {
    /// A file drop exceeded its item-count limit.
    case tooManyFiles(count: Int, limit: Int)

    /// One dropped file or the total drop exceeded its byte limit.
    case fileTooLarge(name: String, bytes: UInt64)

    /// The stable error-code namespace owned by IntegrationCore.
    public static let domain: ErrorDomain = .integration

    /// The stable catalog code for this failure.
    public var code: String {
        switch self {
        case .tooManyFiles:
            "tooManyFiles"
        case .fileTooLarge:
            "fileTooLarge"
        }
    }

    /// Safe catalog parameters. File names are reduced to their final path component.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .tooManyFiles(let count, let limit):
            ["count": .count(count), "limit": .count(limit)]
        case .fileTooLarge(let name, let bytes):
            ["file": .fileName(URL(fileURLWithPath: name).lastPathComponent), "bytes": .bytes(Int64(clamping: bytes))]
        }
    }
}
