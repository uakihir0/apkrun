import DiagnosticsCore
import Foundation

/// A value copy of the error details supplied by Virtualization.framework.
///
/// The description may contain paths or other host-specific details. Callers
/// should write it only to a private diagnostic log field; catalog errors use
/// `underlying` so their public representation contains only domain and code.
public struct VZErrorInfo: Equatable, Sendable {
    /// The system error namespace.
    public let domain: String

    /// The numeric system error code.
    public let code: Int

    /// The framework's diagnostic description, intended for private logs only.
    public let description: String

    /// Copies the stable values from an Objective-C error.
    public init(_ error: NSError) {
        domain = error.domain
        code = error.code
        description = error.localizedDescription
    }

    /// Creates a value copy from explicit details, useful for adapters and tests.
    public init(domain: String, code: Int, description: String) {
        self.domain = domain
        self.code = code
        self.description = description
    }

    /// The path-free error value exposed through the catalog API.
    public var underlying: UnderlyingError {
        UnderlyingError(domain: domain, code: code)
    }
}
