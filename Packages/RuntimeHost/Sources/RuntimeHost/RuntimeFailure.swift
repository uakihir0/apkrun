import DiagnosticsCore
import Foundation
import RuntimeCore

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

    /// `apkrun dev console --android-shell` found no dev console socket, so no `apkrun dev boot` owns the instance.
    case devConsoleNotRunning(console: String)

    /// `apkrun dev boot` cannot create the developer console socket.
    case devConsoleSocketUnavailable

    /// The development window's input is not bound to the Guest Agent's input channel (#25). `cause` is the agent
    /// failure, or nil when the boot has no running Guest Agent to bind to. A warning: the boot goes on.
    case inputNotBound(cause: GuestAgentFailure?)

    /// First-run provisioning has not completed, so Android is not available (runtime-daemon.md §9.2).
    case notProvisioned

    /// One or more host requirements of §9.1 failed.
    case hostRequirementsNotMet([HostRequirement])

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
        case .devConsoleNotRunning: "devConsoleNotRunning"
        case .devConsoleSocketUnavailable: "devConsoleSocketUnavailable"
        case .inputNotBound: "inputNotBound"
        case .notProvisioned: "notProvisioned"
        case .hostRequirementsNotMet: "hostRequirementsNotMet"
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
        case .devConsoleCleanupPending, .devConsoleSocketUnavailable:
            [:]
        case .devConsoleNotRunning(let console):
            ["console": .text(console)]
        case .inputNotBound(let cause):
            // Without a cause, the catalog's variant for a boot with no running Guest Agent is used.
            cause == nil ? ["reason": .text("guestAgentNotRunning")] : [:]
        case .notProvisioned:
            [:]
        case .hostRequirementsNotMet(let requirements):
            ["items": .text(requirements.map(\.itemName).joined(separator: ","))]
        }
    }

    /// The path-free POSIX cause of a lock I/O error.
    public var underlying: UnderlyingError? {
        guard case .instanceLockFailed(let underlying) = self else { return nil }
        return underlying
    }

    /// The Guest Agent failure behind an input binding that failed, when there is one.
    public var cause: (any APKRunError)? {
        guard case .inputNotBound(let cause?) = self else { return nil }
        return cause
    }

    /// The failed host requirements, as ordered list items for multi-item rendering.
    public var listItems: [ErrorListItem] {
        guard case .hostRequirementsNotMet(let requirements) = self else { return [] }
        return requirements.map { requirement in
            var parameters: [String: ErrorParameter] = [:]
            if case .freeDiskSpace(let needed) = requirement {
                parameters["needed"] = .text(
                    ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                )
            }
            return ErrorListItem(
                selector: .variant(code: "runtime.hostRequirementsNotMet", key: requirement.itemName),
                parameters: parameters
            )
        }
    }
}

/// A host requirement from runtime-daemon.md §9.1. Memory is a warning, not a requirement.
public enum HostRequirement: Sendable, Codable, Equatable {
    case appleSilicon
    case macOSVersion
    case virtualization
    case apfsVolume
    case freeDiskSpace(needed: Int64)

    /// The stable variant key used by the error catalog and wire list items.
    public var itemName: String {
        switch self {
        case .appleSilicon: "appleSilicon"
        case .macOSVersion: "macOSVersion"
        case .virtualization: "virtualization"
        case .apfsVolume: "apfsVolume"
        case .freeDiskSpace: "freeDiskSpace"
        }
    }
}
