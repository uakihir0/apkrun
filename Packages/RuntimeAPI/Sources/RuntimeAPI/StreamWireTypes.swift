import Foundation

/// The stream wire types of runtime-api.md §16.4.
///
/// A stream is opened by an `S`-kind operation (`notificationRelay`,
/// `hostNotifications`, `guestLog`), which returns a `StreamHandle`. Events
/// then arrive on the client's exported event sink as `StreamEnvelope` values
/// until the stream ends or the connection is invalidated.

/// A stream identifier: lowercase UUID (runtime-api.md §4.3).
public struct StreamID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// The raw identifier string.
    public var rawValue: String

    /// Creates a stream identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fresh random identifier.
    public init() {
        rawValue = UUID().uuidString.lowercased()
    }
}

/// The handle a stream operation returns (runtime-api.md §16.4).
public struct StreamHandle: Codable, Equatable, Sendable {
    /// The opened stream's identifier.
    public var streamID: StreamID

    /// Creates a stream handle.
    public init(streamID: StreamID) {
        self.streamID = streamID
    }
}

/// One sequenced event on a stream (runtime-api.md §16.4).
public struct StreamEnvelope: Codable, Equatable, Sendable {
    /// The stream the event belongs to.
    public var streamID: StreamID
    /// The per-stream sequence number, assigned from 1 when sent.
    public var seq: UInt64
    /// The event data.
    public var event: StreamEvent

    /// Creates a stream envelope.
    public init(streamID: StreamID, seq: UInt64, event: StreamEvent) {
        self.streamID = streamID
        self.seq = seq
        self.event = event
    }
}

/// Why a stream ended (runtime-api.md §16.4). `ended` is always the last
/// event; a stream may also end silently when the connection is invalidated.
public enum StreamEndReason: Codable, Equatable, Sendable {
    /// The client called `closeStream`.
    case closed
    /// Another stream of the same kind replaced this one.
    case replaced
    /// The source finished (`guestLog` with `follow = false`).
    case finished
    /// The stream failed.
    case error(WireError)
    /// An end reason this build does not know.
    case unknown
}

/// One event on a stream (runtime-api.md §16.4).
public enum StreamEvent: Codable, Equatable, Sendable {
    /// A `notificationRelay` message.
    case relay(RelayMessage)
    /// A `hostNotifications` message.
    case hostNotification(HostNotificationMessage)
    /// A `guestLog` chunk.
    case guestLog(GuestLogChunk)
    /// The stream's final event.
    case ended(StreamEndReason)
    /// An event this build does not know.
    case unknown
}

/// A `guestLog` chunk (runtime-api.md §13.1).
public struct GuestLogChunk: Codable, Equatable, Sendable {
    /// Buffered log lines.
    public var lines: [String]
    /// Lines dropped while the unacknowledged-event limit applied.
    public var dropped: Int

    /// Creates a guest log chunk.
    public init(lines: [String], dropped: Int = 0) {
        self.lines = lines
        self.dropped = dropped
    }
}

/// `closeStream` (runtime-api.md §16.4). Idempotent: an unknown, ended, or
/// foreign stream returns `RuntimeEmpty` and changes nothing.
public struct CloseStreamRequest: Codable, Equatable, Sendable {
    /// The stream to close.
    public var streamID: StreamID

    /// Creates a close-stream request.
    public init(streamID: StreamID) {
        self.streamID = streamID
    }
}
