import Darwin
import Foundation
import GuestProtocol
import Testing
import VirtualMachineCore

@testable import RuntimeCore

@Test(.timeLimit(.minutes(1)))
func vsockGuestTransportConnectsDocumentedEndpointsToTheirPorts() async throws {
    let connector = FakeVsockConnector()
    let timeout = Duration.seconds(9)
    let transport = VsockGuestTransport(connectTimeout: timeout) { port, connectTimeout in
        connector.record(port: port, timeout: connectTimeout)
        return try connector.makeConnection()
    }
    let endpoints: [(GuestEndpoint, UInt32)] = [
        (.guestControl, 6100),
        (.guestInput, 6101),
        (.guestBulk, 6102),
        (.storeControl, 6110),
        (.storeArtifacts, 6111),
    ]

    for (endpoint, _) in endpoints {
        let stream = try await transport.open(endpoint)
        await stream.close()
    }
    for connection in connector.connections {
        await connection.closed.value
    }

    #expect(connector.calls.map(\.port) == endpoints.map(\.1))
    #expect(connector.calls.map(\.timeout) == Array(repeating: timeout, count: endpoints.count))
}

@Test(.timeLimit(.minutes(1)))
func vsockGuestTransportMapsEmptyReadsToEOFAndPreservesBytes() async throws {
    let connector = FakeVsockConnector()
    let transport = VsockGuestTransport { port, timeout in
        connector.record(port: port, timeout: timeout)
        return try connector.makeConnection()
    }
    let stream = try await transport.open(.guestInput)
    let socketPair = try #require(connector.socketPairs.first)
    let payload = Data("guest input frame".utf8)
    let outgoing = Data("host input frame".utf8)

    try await stream.write(outgoing)
    #expect(try socketPair.readFromPeer(maximumLength: outgoing.count) == outgoing)
    try socketPair.writeToPeer(payload)
    #expect(try await stream.read() == payload)
    try #require(Darwin.shutdown(socketPair.peerDescriptor, SHUT_WR) == 0)
    #expect(try await stream.read() == nil)
    #expect(try await stream.read() == nil)

    await stream.close()
    for connection in connector.connections {
        await connection.closed.value
    }
}

@Test(.timeLimit(.minutes(1)))
func vsockGuestTransportRejectsDevelopmentIMEWithoutConnecting() async {
    let connector = FakeVsockConnector()
    let transport = VsockGuestTransport { port, timeout in
        connector.record(port: port, timeout: timeout)
        return try connector.makeConnection()
    }

    await #expect(throws: GuestTransportFailure.notServedByVsockTransport) {
        try await transport.open(.developmentIME)
    }
    #expect(connector.calls.isEmpty)
}

private struct VsockConnectCall {
    let port: UInt32
    let timeout: Duration
}

private final class FakeVsockConnector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [VsockConnectCall] = []
    private var storedConnections: [VsockConnection] = []
    private var storedSocketPairs: [TestSocketPair] = []

    var calls: [VsockConnectCall] {
        lock.withLock { storedCalls }
    }

    var connections: [VsockConnection] {
        lock.withLock { storedConnections }
    }

    var socketPairs: [TestSocketPair] {
        lock.withLock { storedSocketPairs }
    }

    func record(port: UInt32, timeout: Duration) {
        lock.withLock {
            storedCalls.append(VsockConnectCall(port: port, timeout: timeout))
        }
    }

    func makeConnection() throws -> VsockConnection {
        let socketPair = try TestSocketPair()
        let connection = VsockConnection(
            testFileDescriptor: socketPair.hostDescriptor,
            queue: VMQueue(label: "io.apkrun.runtime.vsock-guest-transport-test"),
            onClose: { socketPair.closeBoth() }
        )
        lock.withLock {
            storedConnections.append(connection)
            storedSocketPairs.append(socketPair)
        }
        return connection
    }
}

private final class TestSocketPair: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHostDescriptor: Int32
    private var storedPeerDescriptor: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        storedHostDescriptor = descriptors[0]
        storedPeerDescriptor = descriptors[1]
    }

    var hostDescriptor: Int32 {
        lock.withLock { storedHostDescriptor }
    }

    var peerDescriptor: Int32 {
        lock.withLock { storedPeerDescriptor }
    }

    func writeToPeer(_ bytes: Data) throws {
        let descriptor = peerDescriptor
        try bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }

    func readFromPeer(maximumLength: Int) throws -> Data {
        let descriptor = peerDescriptor
        var bytes = [UInt8](repeating: 0, count: maximumLength)
        let count = Darwin.read(descriptor, &bytes, maximumLength)
        guard count >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return Data(bytes.prefix(count))
    }

    func closeBoth() {
        lock.withLock {
            if storedHostDescriptor >= 0 {
                Darwin.close(storedHostDescriptor)
                storedHostDescriptor = -1
            }
            if storedPeerDescriptor >= 0 {
                Darwin.close(storedPeerDescriptor)
                storedPeerDescriptor = -1
            }
        }
    }
}
