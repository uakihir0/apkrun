import Foundation

/// `GetHealth`: reads the health of the Guest Agent and Android system (guest-protocol.md §7.1 #21).
public struct GuestGetHealth: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPHealth
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 21

    /// Creates the operation.
    public init() {}

    /// The name that errors report for the operation.
    public var operationName: String { "GetHealth" }
    /// The capability that the operation needs.
    public var capability: GuestCapability { .health }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(5) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op { .getHealth(GPGetHealth()) }

    /// Decodes the agent's answer.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPHealth? {
        if case .getHealth(let health) = result { return health }
        return nil
    }
}

/// `Shutdown`: asks the guest system to power off (guest-protocol.md §7.1 #70).
public struct GuestShutdown: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPEmpty
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 70
    /// The reason for the shutdown, for guest diagnostics.
    public let reason: String

    /// Creates the operation.
    public init(reason: String) {
        self.reason = reason
    }

    /// The name that errors report for the operation.
    public var operationName: String { "Shutdown" }
    /// The capability that the operation needs.
    public var capability: GuestCapability { .system }
    /// The time the agent has to answer before it powers off.
    public var timeout: Duration { .seconds(20) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op {
        var shutdown = GPShutdown()
        shutdown.reason = reason
        return .shutdown(shutdown)
    }

    /// Decodes the agent's answer.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .shutdown(let empty) = result { return empty }
        return nil
    }
}
