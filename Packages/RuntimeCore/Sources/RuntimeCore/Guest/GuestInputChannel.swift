import GuestProtocol

/// The production input channel: the batches go through an open connection to the input endpoint (input.md §8).
///
/// It opens nothing itself. ``DevelopmentGuestAgent/inputChannel()`` opens the connection, reuses it while it is
/// usable, and returns a channel over it.
public struct GuestInputChannel: InputChannel {
    /// The connection that carries the batches.
    public let connection: GuestConnection

    /// Wraps a connection that is open on the input endpoint.
    public init(connection: GuestConnection) {
        precondition(connection.endpoint == .guestInput, "A GuestInputChannel needs the input endpoint")
        self.connection = connection
    }

    /// Queues the batch on the connection. It fails with the connection's failure when the connection is not usable.
    public func send(_ batch: GPInputBatch) async throws {
        try await connection.sendInputBatch(batch)
    }

    /// The bytes that the connection holds and has not written yet.
    public var pendingBytes: Int {
        get async {
            await connection.pendingOutboundBytes
        }
    }

    /// The negotiated capabilities of the guest input connection.
    public var negotiatedCapabilities: Set<String>? {
        get async {
            guard let session = await connection.sessionInfo else {
                return nil
            }
            return Set(session.enabledCapabilities)
        }
    }

    /// The acks of the connection. The stream finishes when the connection closes.
    public var acks: AsyncStream<GPInputAck> {
        connection.inputAcks
    }
}
