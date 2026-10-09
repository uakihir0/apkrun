import DiagnosticsCore
import Foundation
import GuestProtocol
import Network

/// The development transport (guest-protocol.md §13.2): each connection makes one ADB forward from a loopback TCP
/// port to the agent's abstract socket, and removes it when the connection closes. The socket is reached only on
/// the host's loopback address (NFR-SEC-06).
public actor ADBForwardGuestTransport: GuestTransport {
    private let adb: AdbClient

    /// Creates the transport over the developer's ADB client.
    public init(adb: AdbClient) {
        self.adb = adb
    }

    public func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        guard let name = endpoint.developmentSocketName else {
            throw GuestTransportFailure.notServedByDevelopmentTransport
        }
        let port = try await adb.forward(remote: "localabstract:\(name)")
        do {
            let socket = try await LoopbackSocket.connect(port: port)
            return ForwardedGuestStream(socket: socket, port: port, adb: adb)
        } catch {
            try? await adb.forwardRemove(port: port)
            throw error
        }
    }
}

/// The development transport has no socket for the endpoint.
enum GuestTransportFailure: Error, Equatable {
    /// The endpoint is served by the vsock transport (#034) or the Store Agent, not by the development agent.
    case notServedByDevelopmentTransport
}

/// A stream that owns its forward. Closing it removes the forward too.
private final class ForwardedGuestStream: GuestByteStream, @unchecked Sendable {
    private let socket: LoopbackSocket
    private let port: UInt16
    private let adb: AdbClient

    init(socket: LoopbackSocket, port: UInt16, adb: AdbClient) {
        self.socket = socket
        self.port = port
        self.adb = adb
    }

    func read() async throws -> Data? {
        try await socket.read()
    }

    func write(_ bytes: Data) async throws {
        try await socket.write(bytes)
    }

    func close() async {
        await socket.close()
        try? await adb.forwardRemove(port: port)
    }
}

/// A TCP connection to 127.0.0.1 on a port that ADB forwards.
private final class LoopbackSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.apkrun.guest.loopback")

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(port: UInt16) async throws -> LoopbackSocket {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw GuestTransportFailure.notServedByDevelopmentTransport
        }
        let socket = LoopbackSocket(
            connection: NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce(continuation)
            socket.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    socket.connection.stateUpdateHandler = nil
                    gate.resume()
                case .failed(let error):
                    socket.connection.stateUpdateHandler = nil
                    gate.fail(error)
                case .cancelled:
                    gate.fail(GuestTransportFailure.notServedByDevelopmentTransport)
                default:
                    break
                }
            }
            socket.connection.start(queue: socket.queue)
        }
        return socket
    }

    /// Returns the next bytes. An empty value means nothing arrived yet, and nil means the peer closed.
    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: bytes,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func close() async {
        connection.cancel()
    }
}

/// Resumes a continuation once, whichever callback comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        take()?.resume()
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            let taken = continuation
            continuation = nil
            return taken
        }
    }
}
