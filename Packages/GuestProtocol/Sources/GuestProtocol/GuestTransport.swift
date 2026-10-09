import Foundation

/// The endpoints of the guest, one per channel (guest-protocol.md §3, §13.1).
public enum GuestEndpoint: Sendable, Hashable, CaseIterable {
    /// The Guest Agent control channel (6100).
    case guestControl
    /// The Guest Agent input channel (6101).
    case guestInput
    /// The Guest Agent bulk channel (6102).
    case guestBulk
    /// The Store Agent control channel (6110). Custom images only.
    case storeControl
    /// The Store Agent artifact channel (6111). Custom images only.
    case storeArtifacts
    /// The development IME, which listens on `@apkrun-guest-ime` (input.md §5.6).
    case developmentIME

    /// The channel that the server of this endpoint speaks (guest-protocol.md §3).
    public var channel: GPChannelKind {
        switch self {
        case .guestControl: .guestControl
        case .guestInput: .guestInput
        case .guestBulk: .guestBulk
        case .storeControl: .storeControl
        case .storeArtifacts: .storeArtifacts
        case .developmentIME: .developmentIme
        }
    }

    /// The abstract socket name in the guest for the development transport (guest-components.md §3.2), or nil when the
    /// endpoint is not served over the development transport.
    public var developmentSocketName: String? {
        switch self {
        case .guestControl: "apkrun-guestd-control"
        case .guestInput: "apkrun-guestd-input"
        case .guestBulk: "apkrun-guestd-bulk"
        case .developmentIME: "apkrun-guest-ime"
        case .storeControl, .storeArtifacts: nil
        }
    }
}

/// A byte stream to one guest endpoint. Writes are whole frames, and they arrive in the order they were
/// written (guest-protocol.md §4).
public protocol GuestByteStream: Sendable {
    /// The next bytes that arrived. An empty value means nothing arrived yet, and nil means the peer closed.
    func read() async throws -> Data?

    /// Writes all of `bytes`.
    func write(_ bytes: Data) async throws

    /// Closes the stream and releases what it holds.
    func close() async
}

/// Opens byte streams to the guest endpoints (guest-protocol.md §13.1). The development transport opens them
/// through an ADB forward, and the vsock transport arrives with #034.
public protocol GuestTransport: Sendable {
    /// Opens one stream to `endpoint`. Each call opens a new connection.
    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream
}
