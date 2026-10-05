import DiagnosticsCore
import Foundation

/// The process that owns `Runtime/instance.lock`.
public enum InstanceLockOwner: String, Codable, Equatable, Sendable {
    /// The background service owns the instance.
    case apkrund

    /// A developer CLI session owns the instance.
    case apkrunDev

    /// The lock is held, but its owner record is absent or unreadable.
    case unknown

    var lockFileValue: String {
        switch self {
        case .apkrund: "apkrund"
        case .apkrunDev: "apkrun-dev"
        case .unknown: "unknown"
        }
    }

    init(lockFileValue: String) {
        switch lockFileValue {
        case "apkrund": self = .apkrund
        case "apkrun-dev", "apkrunDev": self = .apkrunDev
        default: self = .unknown
        }
    }
}

/// Runtime host errors needed before the full runtime supervisor is introduced.
public enum RuntimeFailure: APKRunError, Equatable {
    /// Another process holds the one-instance lock.
    case instanceLocked(owner: InstanceLockOwner)

    /// The lock directory or file could not be created or updated.
    case instanceLockFailed(underlying: UnderlyingError)

    /// The development guest did not finish before its configured deadline.
    case devLinuxTimedOut(seconds: Int)

    /// The development guest options are malformed or outside supported limits.
    case devLinuxInvalidOptions

    /// The development guest artifact directory must be an absolute path.
    case devLinuxArtifactDirectoryMustBeAbsolute

    /// A requested development guest check reported failure.
    case devLinuxCheckFailed

    /// The development guest console closed before its done marker.
    case devLinuxDidNotFinish

    /// A guest failed while attached to the interactive development console.
    case devConsoleGuestFailed

    /// Console input could not be delivered during an interactive session.
    case devConsoleInputFailed

    /// Interactive console output was dropped before it reached the terminal.
    case devConsoleOutputDropped(bytes: UInt64)

    /// VM cleanup failed and the session must retain ownership until release.
    case devConsoleCleanupPending

    /// The stable error catalog namespace for the runtime host.
    public static let domain: ErrorDomain = .runtime

    /// The catalog code for this error.
    public var code: String {
        switch self {
        case .instanceLocked: "instanceLocked"
        case .instanceLockFailed: "instanceLockFailed"
        case .devLinuxTimedOut: "devLinuxTimedOut"
        case .devLinuxInvalidOptions: "devLinuxInvalidOptions"
        case .devLinuxArtifactDirectoryMustBeAbsolute: "devLinuxArtifactDirectoryMustBeAbsolute"
        case .devLinuxCheckFailed: "devLinuxCheckFailed"
        case .devLinuxDidNotFinish: "devLinuxDidNotFinish"
        case .devConsoleGuestFailed: "devConsoleGuestFailed"
        case .devConsoleInputFailed: "devConsoleInputFailed"
        case .devConsoleOutputDropped: "devConsoleOutputDropped"
        case .devConsoleCleanupPending: "devConsoleCleanupPending"
        }
    }

    /// Safe values used by the catalog's messages and variants.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .instanceLocked(let owner):
            ["reason": .text(owner.rawValue)]
        case .devLinuxTimedOut(let seconds):
            ["seconds": .count(seconds)]
        case .instanceLockFailed,
            .devLinuxInvalidOptions,
            .devLinuxArtifactDirectoryMustBeAbsolute,
            .devLinuxCheckFailed,
            .devLinuxDidNotFinish,
            .devConsoleGuestFailed,
            .devConsoleInputFailed:
            [:]
        case .devConsoleOutputDropped(let bytes):
            ["bytes": .count(Int(clamping: bytes))]
        case .devConsoleCleanupPending:
            [:]
        }
    }

    /// The path-free POSIX cause of a lock I/O error.
    public var underlying: UnderlyingError? {
        guard case .instanceLockFailed(let underlying) = self else { return nil }
        return underlying
    }
}
