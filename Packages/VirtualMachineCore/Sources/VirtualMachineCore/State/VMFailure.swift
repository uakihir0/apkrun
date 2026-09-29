import DiagnosticsCore
import Foundation

/// Lifecycle and health failures owned by VirtualMachineCore.
public enum VMFailure: APKRunError, Equatable {
    indirect case invalidTransition(from: VMState, to: VMState)
    case startFailed(underlying: VZErrorInfo)
    case stoppedWithError(underlying: VZErrorInfo)
    case pauseFailed(underlying: VZErrorInfo)
    case resumeFailed(underlying: VZErrorInfo)
    case stopTimedOut
    case vsockConnectFailed(port: UInt32, underlying: VZErrorInfo)
    case vsockPortNotListening(port: UInt32)
    case vsockConnectTimedOut(port: UInt32)
    case virtualizationUnavailable
    case networkAttachmentLost
    case consoleLogWriteFailed

    /// The error catalog domain owned by VirtualMachineCore.
    public static let domain: ErrorDomain = .vm

    /// The stable catalog code for this failure.
    public var code: String {
        switch self {
        case .invalidTransition:
            "invalidTransition"
        case .startFailed:
            "startFailed"
        case .stoppedWithError:
            "stoppedWithError"
        case .pauseFailed:
            "pauseFailed"
        case .resumeFailed:
            "resumeFailed"
        case .stopTimedOut:
            "stopTimedOut"
        case .vsockConnectFailed:
            "vsockConnectFailed"
        case .vsockPortNotListening:
            "vsockPortNotListening"
        case .vsockConnectTimedOut:
            "vsockConnectTimedOut"
        case .virtualizationUnavailable:
            "virtualizationUnavailable"
        case .networkAttachmentLost:
            "networkAttachmentLost"
        case .consoleLogWriteFailed:
            "consoleLogWriteFailed"
        }
    }

    /// Safe values associated with the error code.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .invalidTransition(let from, let to):
            [
                "from": .text(from.diagnosticName),
                "to": .text(to.diagnosticName),
            ]
        case .vsockConnectFailed(let port, _),
            .vsockPortNotListening(let port),
            .vsockConnectTimedOut(let port):
            ["port": .count(Int(port))]
        case .startFailed,
            .stoppedWithError,
            .pauseFailed,
            .resumeFailed,
            .stopTimedOut,
            .virtualizationUnavailable,
            .networkAttachmentLost,
            .consoleLogWriteFailed:
            [:]
        }
    }

    /// The path-free system error, when Virtualization.framework supplied one.
    public var underlying: UnderlyingError? {
        switch self {
        case .startFailed(let error),
            .stoppedWithError(let error),
            .pauseFailed(let error),
            .resumeFailed(let error),
            .vsockConnectFailed(_, let error):
            error.underlying
        case .invalidTransition,
            .stopTimedOut,
            .vsockPortNotListening,
            .vsockConnectTimedOut,
            .virtualizationUnavailable,
            .networkAttachmentLost,
            .consoleLogWriteFailed:
            nil
        }
    }
}

extension VMState {
    fileprivate var diagnosticName: String {
        switch self {
        case .stopped:
            "stopped"
        case .starting:
            "starting"
        case .running:
            "running"
        case .paused:
            "paused"
        case .stopping:
            "stopping"
        case .failed:
            "failed"
        }
    }
}
