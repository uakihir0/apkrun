import Foundation

/// Reassembles frames from a byte stream (guest-protocol.md §4).
///
/// Append the bytes as they arrive, and take each body when it is complete. A bad length fails
/// as soon as its 4 prefix bytes are present, so the decoder never waits for or buffers a body
/// that is above the limit.
///
/// The decoder keeps a read offset instead of removing each frame from the front of the buffer.
/// The consumed bytes are dropped once they are at least half of the buffer, so reading many
/// frames from one buffer costs time proportional to the number of bytes, not its square.
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    /// The index of the first byte that has not been returned as part of a body.
    private var readOffset = 0

    /// Creates an empty decoder.
    public init() {}

    /// Bytes that have arrived but are not yet returned as a body. A connection that closes
    /// while this is not zero has lost a frame in the middle.
    public var pendingByteCount: Int {
        buffer.count - readOffset
    }

    /// Adds bytes from the connection.
    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the body of the next complete frame, or nil when more bytes are needed.
    /// Throws ``GuestProtocolFailure/frameTooLarge`` or ``GuestProtocolFailure/malformedFrame``
    /// when the length of the next frame is invalid.
    public mutating func nextBody() throws(GuestProtocolFailure) -> Data? {
        guard pendingByteCount >= FrameCodec.lengthPrefixSize else {
            return nil
        }
        let prefixEnd = readOffset + FrameCodec.lengthPrefixSize
        let length = try FrameCodec.bodyLength(prefix: buffer[readOffset..<prefixEnd])
        let frameEnd = prefixEnd + length
        guard buffer.count >= frameEnd else {
            return nil
        }
        let body = Data(buffer[prefixEnd..<frameEnd])
        readOffset = frameEnd
        dropConsumedBytesIfTheyAreHalfTheBuffer()
        return body
    }

    /// Removes the consumed bytes once they are at least as many as the pending ones. A compaction
    /// moves no more bytes than were consumed since the previous one, so the total cost is linear.
    private mutating func dropConsumedBytesIfTheyAreHalfTheBuffer() {
        if readOffset > 0 && readOffset >= pendingByteCount {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
    }
}
