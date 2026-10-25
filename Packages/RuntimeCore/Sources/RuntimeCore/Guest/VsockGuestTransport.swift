import Foundation
import GuestProtocol
import VirtualMachineCore

/// Opens Guest Agent and Store Agent channels over the VM's host-to-guest vsock connection.
public struct VsockGuestTransport: GuestTransport, RuntimeGuestTransport {
    /// Connects to a guest port with a timeout and returns its byte stream.
    public typealias Connector = @Sendable (UInt32, Duration) async throws -> VsockConnection

    private let connect: Connector
    private let connectTimeout: Duration

    /// Creates a transport using a connector owned by the runtime.
    ///
    /// - Parameters:
    ///   - connectTimeout: The deadline for establishing each vsock connection.
    ///   - connect: Opens a connection to the requested guest port.
    public init(
        connectTimeout: Duration = .seconds(5),
        connect: @escaping Connector
    ) {
        self.connectTimeout = connectTimeout
        self.connect = connect
    }

    /// Opens a new stream for the endpoint.
    ///
    /// The development IME is available only through the ADB-forward transport.
    public func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        guard let port = Self.port(for: endpoint) else {
            throw GuestTransportFailure.notServedByVsockTransport
        }
        return VsockGuestByteStream(connection: try await connect(port, connectTimeout))
    }

    /// Opens one Store Agent endpoint through the same vsock bridge as the Guest Agent transport.
    public func open(_ endpoint: RuntimeGuestEndpoint) async throws -> any RuntimeGuestByteStream {
        let port: UInt32
        switch endpoint {
        case .storeControl: port = 6110
        case .storeArtifacts: port = 6111
        }
        return VsockGuestByteStream(connection: try await connect(port, connectTimeout))
    }

    private static func port(for endpoint: GuestEndpoint) -> UInt32? {
        switch endpoint {
        case .guestControl: 6100
        case .guestInput: 6101
        case .guestBulk: 6102
        case .storeControl: 6110
        case .storeArtifacts: 6111
        case .developmentIME: nil
        }
    }
}

/// Adapts the vsock stream's empty EOF value to the GuestByteStream nil EOF value.
private actor VsockGuestByteStream: GuestByteStream, RuntimeGuestByteStream {
    private let connection: VsockConnection
    private var reachedEOF = false

    init(connection: VsockConnection) {
        self.connection = connection
    }

    func read() async throws -> Data? {
        guard !reachedEOF else { return nil }
        let bytes = try await connection.read(upTo: 64 * 1_024)
        guard !bytes.isEmpty else {
            reachedEOF = true
            return nil
        }
        return bytes
    }

    func write(_ bytes: Data) async throws {
        try await connection.write(bytes)
    }

    func close() async {
        connection.close()
        await connection.closed.value
    }
}
