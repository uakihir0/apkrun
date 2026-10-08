import Foundation

/// Reassembles frames from a byte stream (guest-protocol.md §4).
///
/// Append the bytes as they arrive, and take each body when it is complete. A bad length fails
/// as soon as its 4 prefix bytes are present, so the decoder never waits for or buffers a body
/// that is above the limit.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    /// Creates an empty decoder.
    public init() {}

    /// Bytes that have arrived but are not yet returned as a body. A connection that closes
    /// while this is not zero has lost a frame in the middle.
    public var pendingByteCount: Int {
        buffer.count
    }

    /// Adds bytes from the connection.
    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the body of the next complete frame, or nil when more bytes are needed.
    /// Throws ``GuestProtocolFailure/frameTooLarge`` or ``GuestProtocolFailure/malformedFrame``
    /// when the length of the next frame is invalid.
    public mutating func nextBody() throws(GuestProtocolFailure) -> Data? {
        guard buffer.count >= FrameCodec.lengthPrefixSize else {
            return nil
        }
        let length = try FrameCodec.bodyLength(prefix: buffer.prefix(FrameCodec.lengthPrefixSize))
        let frameSize = FrameCodec.lengthPrefixSize + length
        guard buffer.count >= frameSize else {
            return nil
        }
        let body = Data(buffer[FrameCodec.lengthPrefixSize..<frameSize])
        buffer.removeSubrange(0..<frameSize)
        return body
    }
}
