import GuestProtocol

/// The development IME channel (input.md §5.1): commands go through an open connection to the
/// development IME endpoint, and the IME's editor reports come back on `states`.
///
/// It opens nothing itself. ``DevelopmentGuestAgent/imeChannel()`` opens the connection, reuses it
/// while it is usable, and returns a channel over it.
public struct GuestImeChannel: Sendable {
    /// The connection that carries the commands and reports.
    public let connection: GuestConnection

    /// Wraps a connection that is open on the development IME endpoint.
    public init(connection: GuestConnection) {
        precondition(connection.endpoint == .developmentIME, "A GuestImeChannel needs the IME endpoint")
        self.connection = connection
    }

    /// Queues the command on the connection. It fails with the connection's failure when the
    /// connection is not usable.
    public func send(_ command: GPImeCommand) async throws {
        try await connection.sendImeCommand(command)
    }

    /// The editor state reports of the IME. The stream finishes when the connection closes.
    public var states: AsyncStream<GPImeState> {
        connection.imeStates
    }
}
