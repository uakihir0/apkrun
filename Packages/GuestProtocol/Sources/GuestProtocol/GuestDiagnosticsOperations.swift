import Foundation

/// CollectDiagnostics, guest protocol operation 73 (guest-protocol.md §7.1,
/// diagnostics.md §5). The answer names a bulk transfer per collected item; the
/// payloads arrive on the bulk channel (6102).
public struct GuestCollectDiagnostics: GuestOperation {
    /// The per-item results; `transferID` joins each to its bulk transfer.
    public typealias Result = GPCollectDiagnosticsResult
    /// The stable guest protocol operation number.
    public static let number = 73

    /// The items to collect.
    public let items: [GPDiagnosticsItem]
    /// The byte limit per item; longer payloads are truncated.
    public let maxBytes: UInt64
    /// The allowlisted properties of the GETPROP item.
    public let properties: [String]

    /// Creates a collect request.
    public init(
        items: [GPDiagnosticsItem],
        maxBytes: UInt64 = 16 * 1024 * 1024,
        properties: [String] = []
    ) {
        self.items = items
        self.maxBytes = maxBytes
        self.properties = properties
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "CollectDiagnostics" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .diagnostics }
    /// The per-call timeout (diagnostics.md §6); the agent caps it too.
    public var timeout: Duration { .seconds(60) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var collect = GPCollectDiagnostics()
        collect.items = items
        collect.maxBytes = maxBytes
        collect.properties = properties
        return .collectDiagnostics(collect)
    }

    /// Extracts the per-item results.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPCollectDiagnosticsResult? {
        if case .collectDiagnostics(let collected) = result { return collected }
        return nil
    }
}
