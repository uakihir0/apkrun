import Foundation

/// A refinement of `RuntimeState.booting` for progress (state-machines.md §2).
public enum BootPhase: Int, Comparable, Codable, Sendable, CustomStringConvertible {
    /// The kernel prints on the console.
    case kernel
    /// Android init runs.
    case `init`
    /// Zygote, and then `system_server`, start.
    case systemServer
    /// Android reports boot completion.
    case bootCompleted
    /// The host waits for the required agents (M3+).
    case agentsConnecting

    /// Orders phases in boot order.
    public static func < (lhs: BootPhase, rhs: BootPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The phase name used in logs and error text.
    public var description: String {
        switch self {
        case .kernel: "kernel"
        case .`init`: "init"
        case .systemServer: "systemServer"
        case .bootCompleted: "bootCompleted"
        case .agentsConnecting: "agentsConnecting"
        }
    }
}
