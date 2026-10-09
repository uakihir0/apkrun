import Foundation
import GuestProtocol

/// A transport whose open does not return within a test, so that only the handshake deadline can end the attempt.
struct StalledTransport: GuestTransport {
    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

/// A transport that opens its streams of `inner` only after `delay`.
struct DelayedTransport: GuestTransport {
    let inner: InMemoryTransport
    let delay: Duration

    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        try await Task.sleep(for: delay)
        return try await inner.open(endpoint)
    }
}
