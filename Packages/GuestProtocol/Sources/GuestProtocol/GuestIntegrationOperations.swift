import Foundation

/// SetClipboard, guest protocol operation 40 (guest-protocol.md §7.1,
/// desktop-integration.md §4.2). The guest answers `Empty`; the ClipAck the
/// window waits for carries the seq the host coordinator allocated.
public struct GuestSetClipboard: GuestOperation {
    /// The guest acknowledges the write with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 40

    /// The clip to set on the Android clipboard.
    public let clip: GPClipData

    /// Creates a set-clipboard request.
    public init(clip: GPClipData) {
        self.clip = clip
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetClipboard" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .clipboardText }
    /// The per-call timeout; paste waits on the ClipAck for 500 ms (§4.5).
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        .setClipboard(clip)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setClipboard(let empty) = result { return empty }
        return nil
    }
}
