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
    /// The link prompt got no answer in 60 s, or names an unknown prompt (§13.1).
    case promptTimedOut
    /// A link was dropped (§13.2); logged and counted, never shown.
    case linkRejected(reason: LinkRejection)
}

/// Why LinkForwarder dropped a link (desktop-integration.md §7.2).
public enum LinkRejection: String, Sendable, Equatable {
    /// The scheme is not http, https, or mailto, or an http(s) link has no host.
    case scheme
    /// Longer than 8 KiB.
    case tooLong
    /// The window is not key and had no input in the last 5 s.
    case notFocused
    /// More than 3 links in 10 s.
    case rateLimited
}
