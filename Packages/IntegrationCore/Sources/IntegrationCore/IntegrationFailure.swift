import Foundation
import RuntimeAPI

/// The `integration` error domain of error-catalog.md §13.
public enum IntegrationFailure: Error, Sendable, Equatable {
    /// `IntegrationPolicy` denied the request (§13.1).
    case disabled(IntegrationKind, IntegrationDenial)
    /// The running image lacks the capability the operation needs (§13.1).
    case notSupportedOnImage(capability: String)
    /// The Guest Agent is not connected (§13.1).
    case guestUnavailable
    /// A clip above its size limit; long text is truncated instead (§13.2).
    case clipboardTooLarge(bytes: Int64, limit: Int64)
}
