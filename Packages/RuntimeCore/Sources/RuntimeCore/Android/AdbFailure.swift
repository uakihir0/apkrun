import DiagnosticsCore
import Foundation

/// Why a developer ADB command did not complete (error domain `runtime`; error-catalog.md §7.6).
///
/// The text of a command's output never goes into an error: it can carry app data or logcat lines.
/// Only the command name, exit status, and timeout are kept.
public enum AdbFailure: APKRunError, Equatable {
    /// No `adb` under `$ANDROID_HOME/platform-tools` and none on `PATH`.
    case executableMissing
    /// The `adb` executable exists but could not be started.
    case launchFailed
    /// The development endpoint did not reach the `device` state before the deadline.
    case connectionUnavailable
    /// The command exited with a nonzero status.
    case commandFailed(command: String, status: Int32)
    /// The command did not finish within its timeout, and the process was terminated.
    case commandTimedOut(command: String, seconds: Int)
    /// An argument that a helper refuses to put on a command line.
    case invalidArgument(command: String)

    /// The `runtime` error domain.
    public static let domain: ErrorDomain = .runtime

    /// The catalog code.
    public var code: String {
        switch self {
        case .executableMissing: "adbExecutableMissing"
        case .launchFailed: "adbLaunchFailed"
        case .connectionUnavailable: "adbConnectionUnavailable"
        case .commandFailed: "adbCommandFailed"
        case .commandTimedOut: "adbCommandTimedOut"
        case .invalidArgument: "adbInvalidArgument"
        }
    }

    /// The catalog parameters.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .commandFailed(let command, let status):
            ["command": .text(command), "status": .count(Int(status))]
        case .commandTimedOut(let command, let seconds):
            ["command": .text(command), "seconds": .count(seconds)]
        case .invalidArgument(let command):
            ["command": .text(command)]
        case .executableMissing, .launchFailed, .connectionUnavailable:
            [:]
        }
    }
}
