import Foundation
import SwiftProtobuf

/// Encodes and decodes the frames of the guest protocol (guest-protocol.md §4).
///
/// A frame is a 4-byte big-endian length followed by one serialized ``GPEnvelope``. The length
/// must be at least 1 and at most ``maximumBodySize``. The codec is a pure function over bytes.
/// Its Kotlin counterpart shares the golden frames in `testdata/frames` (§16).
public enum FrameCodec {
    /// The number of bytes in the length prefix.
    public static let lengthPrefixSize = 4

    /// The largest body that a frame can carry: 4 MiB.
    public static let maximumBodySize = 4_194_304

    /// Encodes one envelope as a complete frame.
    public static func encode(_ envelope: GPEnvelope) throws(GuestProtocolFailure) -> Data {
        let body: Data
        do {
            body = try envelope.serializedData()
        } catch {
            throw .malformedFrame
        }
        return try frame(body: body)
    }

    /// Wraps a serialized body in a frame. The body must be between 1 and ``maximumBodySize`` bytes.
    public static func frame(body: Data) throws(GuestProtocolFailure) -> Data {
        try validateBodyLength(body.count)
        var frame = Data(capacity: lengthPrefixSize + body.count)
        let length = UInt32(body.count)
        frame.append(contentsOf: [
            UInt8(length >> 24), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        ])
        frame.append(body)
        return frame
    }

    /// Decodes exactly one complete frame. Missing, extra, or undecodable bytes are
    /// ``GuestProtocolFailure/malformedFrame``.
    public static func decode(_ frame: Data) throws(GuestProtocolFailure) -> GPEnvelope {
        guard frame.count >= lengthPrefixSize else {
            throw .malformedFrame
        }
        let length = try bodyLength(prefix: frame.prefix(lengthPrefixSize))
        guard frame.count == lengthPrefixSize + length else {
            throw .malformedFrame
        }
        return try decodeBody(frame.dropFirst(lengthPrefixSize))
    }

    /// Reads the body length from the 4-byte prefix. A length of 0 or above ``maximumBodySize``
    /// is rejected here, before any body is read or allocated.
    public static func bodyLength(prefix: Data) throws(GuestProtocolFailure) -> Int {
        guard prefix.count == lengthPrefixSize else {
            throw .malformedFrame
        }
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        try validateBodyLength(length)
        return length
    }

    /// Parses a serialized body. Bytes that do not decode are ``GuestProtocolFailure/malformedFrame``.
    public static func decodeBody(_ body: Data) throws(GuestProtocolFailure) -> GPEnvelope {
        do {
            return try GPEnvelope(serializedBytes: body)
        } catch {
            throw .malformedFrame
        }
    }

    /// Checks a body length against the limits of §4.
    static func validateBodyLength(_ length: Int) throws(GuestProtocolFailure) {
        if length == 0 {
            throw .malformedFrame
        }
        if length > maximumBodySize {
            throw .frameTooLarge
        }
    }
}
