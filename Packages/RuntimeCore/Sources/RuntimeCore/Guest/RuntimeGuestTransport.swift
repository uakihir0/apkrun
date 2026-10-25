import Foundation
import GuestProtocol

/// The guest endpoints needed by RuntimeCore's Store Agent client.
public enum RuntimeGuestEndpoint: Sendable, Equatable {
    case storeControl
    case storeArtifacts
}

/// A runtime-owned byte stream that carries one guest connection.
public protocol RuntimeGuestByteStream: Sendable {
    func read() async throws -> Data?
    func write(_ bytes: Data) async throws
    func close() async
}

/// Opens Store Agent connections without exposing GuestProtocol transport types to RuntimeHost.
public protocol RuntimeGuestTransport: Sendable {
    func open(_ endpoint: RuntimeGuestEndpoint) async throws -> any RuntimeGuestByteStream
}

/// Adapts RuntimeCore's transport boundary to GuestProtocol's connection engine.
struct StoreAgentProtocolTransport: GuestTransport {
    private let transport: any RuntimeGuestTransport

    init(transport: any RuntimeGuestTransport) {
        self.transport = transport
    }

    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        let runtimeEndpoint: RuntimeGuestEndpoint
        switch endpoint {
        case .storeControl:
            runtimeEndpoint = .storeControl
        case .storeArtifacts:
            runtimeEndpoint = .storeArtifacts
        case .guestControl, .guestInput, .guestBulk, .developmentIME:
            throw StoreAgentProtocolTransportFailure.unsupportedEndpoint
        }
        return RuntimeGuestByteStreamAdapter(stream: try await transport.open(runtimeEndpoint))
    }
}

private struct RuntimeGuestByteStreamAdapter: GuestByteStream {
    let stream: any RuntimeGuestByteStream

    func read() async throws -> Data? {
        try await stream.read()
    }

    func write(_ bytes: Data) async throws {
        try await stream.write(bytes)
    }

    func close() async {
        await stream.close()
    }
}

private enum StoreAgentProtocolTransportFailure: Error {
    case unsupportedEndpoint
}
