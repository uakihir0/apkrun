import DiagnosticsCore
import Foundation
import GuestProtocol

/// Why the development Guest Agent could not be installed, started, or reached (error domain `runtime`).
///
/// Codes and remediations are in error-catalog.md (the `runtime.guestAgent*` and `runtime.requiredAgentUnavailable`
/// entries). The ADB failure behind an install or a start is kept as the cause.
public enum GuestAgentFailure: APKRunError, Equatable {
    /// The bundle of the agent (`apkrun-guest.apk` and `apkrun-guest.json`) is missing or unreadable.
    case bundleMissing
    /// Android refused the install, and the reason is its code, such as `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
    case installFailed(reason: String)
    /// The agent process did not start.
    case startFailed
    /// The agent did not answer its Hello within 5 seconds after `sys.boot_completed`.
    case connectTimedOut
    /// The handshake failed with the named protocol failure (guest-protocol.md §12.3).
    case handshakeFailed(reason: String)
    /// The agent died more often than the restart budget allows, so the host stops restarting it.
    case requiredAgentUnavailable
    /// An ADB command for the agent failed.
    case adb(AdbFailure)
    /// A request to the agent failed, and `reason` is the protocol failure's catalog name (guest-protocol.md §12.3).
    case operationFailed(reason: String)

    /// The `runtime` error domain.
    public static let domain: ErrorDomain = .runtime

    /// The catalog code.
    public var code: String {
        switch self {
        case .bundleMissing: "guestAgentBundleMissing"
        case .installFailed: "guestAgentInstallFailed"
        case .startFailed: "guestAgentStartFailed"
        case .connectTimedOut: "guestAgentConnectTimedOut"
        case .handshakeFailed: "guestAgentHandshakeFailed"
        case .requiredAgentUnavailable: "requiredAgentUnavailable"
        case .adb: "adb"
        case .operationFailed: "guestAgentOperationFailed"
        }
    }

    /// The catalog parameters. They carry the reason names only, never output text.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .installFailed(let reason), .handshakeFailed(let reason), .operationFailed(let reason):
            ["reason": .text(reason)]
        default:
            [:]
        }
    }

    /// The ADB failure behind the case, when there is one.
    public var cause: (any APKRunError)? {
        switch self {
        case .adb(let failure): failure
        default: nil
        }
    }
}

extension GuestAgentFailure {
    /// The failure of a request to the agent, named by its protocol failure.
    public static func operation(_ failure: GuestProtocolFailure) -> GuestAgentFailure {
        .operationFailed(reason: failure.catalogName)
    }
}

extension GuestProtocolFailure {
    /// The name of the failure in the error catalog (guest-protocol.md §12.3). It carries no message text, because
    /// a remote message is the agent's own and is never shown.
    var catalogName: String {
        switch self {
        case .incompatibleVersion: "incompatibleVersion"
        case .handshakeFailed(let reason): "handshakeFailed.\(reason)"
        case .handshakeTimedOut: "handshakeTimedOut"
        case .disconnected: "disconnected"
        case .timeout(let operation): "timeout.\(operation)"
        case .remote(let code, _, let operation): "remote.\(operation).\(code)"
        case .frameTooLarge: "frameTooLarge"
        case .malformedFrame: "malformedFrame"
        case .capabilityMissing(let capability): "capabilityMissing.\(capability)"
        case .agentUnavailable(let kind): "agentUnavailable.\(kind)"
        }
    }
}
