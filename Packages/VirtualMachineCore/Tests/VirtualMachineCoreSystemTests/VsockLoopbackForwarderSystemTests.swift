import Darwin
import DiagnosticsCore
import Foundation
import Testing

@testable import VirtualMachineCore

/// Host-only checks of `VsockLoopbackForwarder` over real loopback sockets (#015 T1). The guest end
/// is a socketpair, so no VM is needed.
@Test(.timeLimit(.minutes(1)))
func loopbackForwarderCarriesBytesInBothDirections() async throws {
    let guest = try GuestStandIn()
    let forwarder = VsockLoopbackForwarder(requestedPort: 0, guestPort: 5555, logSink: nil) { port in
        #expect(port == 5555)
        return guest.connection()
    }
    try forwarder.start()
    defer { forwarder.stop() }
    let port = try #require(forwarder.port)

    let client = try connectToLoopback(port: port)
    defer { Darwin.close(client) }
    try writeAll(Data("ping".utf8), to: client)
    let atGuest = try await readExactly(4, from: guest.peerDescriptor)
    #expect(atGuest == Data("ping".utf8))

    try writeAll(Data("pong".utf8), to: guest.peerDescriptor)
    let atClient = try await readExactly(4, from: client)
    #expect(atClient == Data("pong".utf8))
}

@Test(.timeLimit(.minutes(1)))
func loopbackForwarderClosesTheClientWhenTheGuestCannotBeReached() async throws {
    let forwarder = VsockLoopbackForwarder(requestedPort: 0, guestPort: 5555, logSink: nil) { _ in
        throw VMFailure.vsockPortNotListening(port: 5555)
    }
    try forwarder.start()
    defer { forwarder.stop() }
    let client = try connectToLoopback(port: try #require(forwarder.port))
    defer { Darwin.close(client) }

    let bytes = try await readExactly(1, from: client, expectingEnd: true)
    #expect(bytes.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func loopbackForwarderClosesOpenConnectionsOnStop() async throws {
    let guest = try GuestStandIn()
    let forwarder = VsockLoopbackForwarder(requestedPort: 0, guestPort: 5555, logSink: nil) { _ in
        guest.connection()
    }
    try forwarder.start()
    let client = try connectToLoopback(port: try #require(forwarder.port))
    defer { Darwin.close(client) }
    try writeAll(Data("hi".utf8), to: client)
    _ = try await readExactly(2, from: guest.peerDescriptor)

    forwarder.stop()

    let bytes = try await readExactly(1, from: client, expectingEnd: true)
    #expect(bytes.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func loopbackForwarderReportsAPortThatAnotherProcessListensOn() async throws {
    let wildcard = try makeListener(port: 0)
    defer { Darwin.close(wildcard.descriptor) }
    let forwarder = VsockLoopbackForwarder(requestedPort: wildcard.port, guestPort: 5555, logSink: nil) { _ in
        throw VMFailure.vsockPortNotListening(port: 5555)
    }

    #expect(throws: VMFailure.loopbackPortInUse(port: wildcard.port)) {
        try forwarder.start()
    }
    #expect(forwarder.port == nil)
}

@Test(.timeLimit(.minutes(1)))
func loopbackForwarderCanRestartOnThePortAfterTimeWait() async throws {
    let guest = try GuestStandIn()
    let first = VsockLoopbackForwarder(requestedPort: 0, guestPort: 5555, logSink: nil) { _ in
        guest.connection()
    }
    try first.start()
    let port = try #require(first.port)
    let client = try connectToLoopback(port: port)
    try writeAll(Data("a".utf8), to: client)
    _ = try await readExactly(1, from: guest.peerDescriptor)
    // The guest closes first, so the forwarder side is the active closer and its port enters TIME_WAIT.
    guest.closePeer()
    _ = try await readExactly(1, from: client, expectingEnd: true)
    Darwin.close(client)
    first.stop()

    let second = VsockLoopbackForwarder(requestedPort: port, guestPort: 5555, logSink: nil) { _ in
        throw VMFailure.vsockPortNotListening(port: 5555)
    }
    try second.start()
    defer { second.stop() }
    #expect(second.port == port)
}

@Test(.timeLimit(.minutes(1)))
func loopbackForwarderListensOnlyOnTheLoopbackAddress() async throws {
    let forwarder = VsockLoopbackForwarder(requestedPort: 0, guestPort: 5555, logSink: nil) { _ in
        throw VMFailure.vsockPortNotListening(port: 5555)
    }
    try forwarder.start()
    defer { forwarder.stop() }
    let port = try #require(forwarder.port)

    // The acceptance check of #015: lsof reports the listener on 127.0.0.1 only.
    let addresses = try listeningAddresses(port: port)
    #expect(addresses == ["127.0.0.1:\(port)"])
}

/// A socketpair whose host end is handed to `VsockConnection` and whose peer end stands in for the guest.
private final class GuestStandIn: @unchecked Sendable {
    let hostDescriptor: Int32
    let peerDescriptor: Int32
    private let lock = NSLock()
    private var hostOpen = true
    private var peerOpen = true

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        hostDescriptor = descriptors[0]
        peerDescriptor = descriptors[1]
    }

    func connection() -> VsockConnection {
        VsockConnection(
            testFileDescriptor: hostDescriptor,
            queue: VMQueue(label: "io.apkrun.vm.vsock.loopback-test"),
            onClose: { [self] in
                lock.withLock {
                    guard hostOpen else { return }
                    hostOpen = false
                    Darwin.close(hostDescriptor)
                }
            }
        )
    }

    /// Closes the peer end once, as the guest would when it hangs up.
    func closePeer() {
        lock.withLock {
            guard peerOpen else { return }
            peerOpen = false
            Darwin.close(peerDescriptor)
        }
    }

    deinit {
        lock.withLock {
            if hostOpen {
                Darwin.close(hostDescriptor)
            }
            if peerOpen {
                Darwin.close(peerDescriptor)
            }
        }
    }
}

private func connectToLoopback(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(.EIO)
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }
    return descriptor
}

private func makeListener(port: UInt16) throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(.EIO)
    }
    var wildcard = sockaddr_in()
    wildcard.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    wildcard.sin_family = sa_family_t(AF_INET)
    wildcard.sin_port = port.bigEndian
    wildcard.sin_addr = in_addr(s_addr: INADDR_ANY)
    let bound = withUnsafePointer(to: &wildcard) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
        Darwin.close(descriptor)
        throw POSIXError(.EADDRINUSE)
    }
    var named = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &named) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &length)
        }
    }
    return (descriptor, UInt16(bigEndian: named.sin_port))
}

/// The addresses that `lsof` reports as listening on TCP `port`, as `host:port` strings.
private func listeningAddresses(port: UInt16) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("n") else {
            return nil
        }
        return String(line.dropFirst())
    }
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.send(descriptor, buffer.baseAddress! + offset, buffer.count - offset, 0)
            guard count > 0 else {
                throw POSIXError(.EIO)
            }
            offset += count
        }
    }
}

/// Reads exactly `count` bytes on a detached task. With `expectingEnd`, returns the bytes read
/// before end of stream, which is empty when the peer closes at once.
private func readExactly(_ count: Int, from descriptor: Int32, expectingEnd: Bool = false) async throws -> Data {
    try await Task.detached {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while collected.count < count {
            let received = Darwin.recv(descriptor, &buffer, count - collected.count, 0)
            if received == 0 {
                if expectingEnd {
                    return collected
                }
                throw POSIXError(.ECONNRESET)
            }
            guard received > 0 else {
                throw POSIXError(.EIO)
            }
            collected.append(contentsOf: buffer[0..<received])
        }
        return collected
    }.value
}
