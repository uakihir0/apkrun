import Darwin
import Foundation
import Testing

@testable import VirtualMachineCore

@Test(.timeLimit(.minutes(1)))
func vsockConnectionReadsAndWritesOneMiBOverSocketpair() async throws {
    let owner = try SocketPairDescriptorOwner()
    let queue = VMQueue(label: "io.apkrun.vm.vsock.socketpair.echo-test")
    let connection = VsockConnection(
        testFileDescriptor: owner.hostDescriptor,
        queue: queue,
        onClose: { owner.closeBoth() }
    )
    defer {
        connection.close()
        owner.closePeer()
    }

    let payload = makeDeterministicPayload(byteCount: 1_048_576)
    let peerDescriptor = owner.peerDescriptor
    let peerTask = Task.detached {
        let received = try readExactly(1_048_576, from: peerDescriptor)
        try writeAll(received, to: peerDescriptor)
        return received
    }

    try await connection.write(payload)

    var echoed = Data()
    while echoed.count < payload.count {
        let bytes = try await connection.read(upTo: 64 * 1_024)
        guard !bytes.isEmpty else {
            throw VsockConnectionError.closed
        }
        echoed.append(bytes)
    }

    let receivedAtPeer = try await peerTask.value
    #expect(receivedAtPeer == payload)
    #expect(echoed == payload)

    connection.close()
    #expect(await waitForConnectionClose(connection, timeout: .seconds(1)))
    #expect(owner.closeCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func vsockConnectionDetectsPeerEOFWhileBufferedBytesRemain() async throws {
    let owner = try SocketPairDescriptorOwner()
    let queue = VMQueue(label: "io.apkrun.vm.vsock.socketpair.eof-test")
    let connection = VsockConnection(
        testFileDescriptor: owner.hostDescriptor,
        queue: queue,
        onClose: { owner.closeBoth() }
    )
    defer {
        connection.close()
        owner.closePeer()
    }

    let payload = Data(0..<32)
    try writeAll(payload, to: owner.peerDescriptor)
    #expect(Darwin.shutdown(owner.peerDescriptor, SHUT_WR) == 0)

    let firstRead = try await connection.read(upTo: 16)
    #expect(firstRead == Data(payload.prefix(16)))
    #expect(await waitForConnectionClose(connection, timeout: .seconds(1)))

    let remainingBytes = try await connection.read(upTo: 32)
    #expect(remainingBytes == Data(payload.suffix(16)))
    #expect(try await connection.read(upTo: 16).isEmpty)
    #expect(owner.closeCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func vsockConnectionDetectsPeerEOFAtTheBufferLimit() async throws {
    let owner = try SocketPairDescriptorOwner()
    let queue = VMQueue(label: "io.apkrun.vm.vsock.socketpair.full-buffer-eof-test")
    let connection = VsockConnection(
        testFileDescriptor: owner.hostDescriptor,
        queue: queue,
        onClose: { owner.closeBoth() }
    )
    defer {
        connection.close()
        owner.closePeer()
    }

    let payload = makeDeterministicPayload(byteCount: 1_048_576)
    try writeAll(payload, to: owner.peerDescriptor)
    #expect(Darwin.shutdown(owner.peerDescriptor, SHUT_WR) == 0)
    try #require(await waitForConnectionClose(connection, timeout: .seconds(1)))

    var received = Data()
    while received.count < payload.count {
        let bytes = try await connection.read(upTo: 64 * 1_024)
        guard !bytes.isEmpty else {
            throw VsockConnectionError.closed
        }
        received.append(bytes)
    }
    #expect(received == payload)
    #expect(try await connection.read(upTo: 1).isEmpty)
    #expect(owner.closeCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func vsockConnectionClosesWhenPeerExceedsTheBufferLimit() async throws {
    let owner = try SocketPairDescriptorOwner()
    let queue = VMQueue(label: "io.apkrun.vm.vsock.socketpair.overflow-test")
    let connection = VsockConnection(
        testFileDescriptor: owner.hostDescriptor,
        queue: queue,
        onClose: { owner.closeBoth() }
    )
    defer {
        connection.close()
        owner.closePeer()
    }

    let payload = makeDeterministicPayload(byteCount: 1_048_577)
    try writeAll(payload, to: owner.peerDescriptor)
    #expect(Darwin.shutdown(owner.peerDescriptor, SHUT_WR) == 0)
    try #require(await waitForConnectionClose(connection, timeout: .seconds(1)))

    var received = Data()
    while received.count < 1_048_576 {
        let bytes = try await connection.read(upTo: 64 * 1_024)
        guard !bytes.isEmpty else {
            throw VsockConnectionError.closed
        }
        received.append(bytes)
    }
    #expect(received == Data(payload.prefix(1_048_576)))
    await #expect(throws: VsockConnectionError.bufferedInputLimitExceeded) {
        try await connection.read(upTo: 1)
    }
    #expect(owner.closeCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func vsockConnectionCancellationDoesNotConsumeTheNextRead() async throws {
    let owner = try SocketPairDescriptorOwner()
    let queue = VMQueue(label: "io.apkrun.vm.vsock.socketpair.cancel-test")
    let readRegistration = AsyncTestLatch()
    let connection = VsockConnection(
        testFileDescriptor: owner.hostDescriptor,
        queue: queue,
        onClose: { owner.closeBoth() },
        onReadPending: {
            Task {
                await readRegistration.signal()
            }
        }
    )
    defer {
        connection.close()
        owner.closePeer()
    }

    let pendingRead = Task {
        try await connection.read(upTo: 8)
    }
    await readRegistration.wait()
    pendingRead.cancel()
    let payload = Data("preserved".utf8)
    try writeAll(payload, to: owner.peerDescriptor)
    await #expect(throws: CancellationError.self) {
        try await pendingRead.value
    }
    #expect(try await connection.read(upTo: payload.count) == payload)

    let bufferedPayload = Data("buffered".utf8)
    try writeAll(bufferedPayload, to: owner.peerDescriptor)
    #expect(Darwin.shutdown(owner.peerDescriptor, SHUT_WR) == 0)
    #expect(await waitForConnectionClose(connection, timeout: .seconds(1)))

    let readGate = AsyncTestGate()
    let alreadyCancelledRead = Task {
        await readGate.wait()
        try await connection.read(upTo: bufferedPayload.count)
    }
    alreadyCancelledRead.cancel()
    await readGate.open()
    await #expect(throws: CancellationError.self) {
        try await alreadyCancelledRead.value
    }
    #expect(try await connection.read(upTo: bufferedPayload.count) == bufferedPayload)

    connection.close()
    #expect(await waitForConnectionClose(connection, timeout: .seconds(1)))
    #expect(owner.closeCount == 2)
}

private final class SocketPairDescriptorOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var hostFD: Int32
    private var peerFD: Int32
    private var closedDescriptorCount = 0

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        hostFD = descriptors[0]
        peerFD = descriptors[1]
    }

    var hostDescriptor: Int32 {
        lock.withLock { hostFD }
    }

    var peerDescriptor: Int32 {
        lock.withLock { peerFD }
    }

    var closeCount: Int {
        lock.withLock { closedDescriptorCount }
    }

    func closePeer() {
        closeDescriptor(host: false)
    }

    func closeBoth() {
        closeDescriptor(host: true)
        closeDescriptor(host: false)
    }

    private func closeDescriptor(host: Bool) {
        let descriptor = lock.withLock { () -> Int32 in
            let descriptor = host ? hostFD : peerFD
            guard descriptor >= 0 else { return -1 }
            if host {
                hostFD = -1
            } else {
                peerFD = -1
            }
            closedDescriptorCount += 1
            return descriptor
        }
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}

private actor AsyncTestLatch {
    private var isSignaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func signal() {
        isSignaled = true
        waiter?.resume()
        waiter = nil
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class BooleanCompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let completedResult: Bool? = lock.withLock {
                guard let result else {
                    self.continuation = continuation
                    return nil
                }
                return result
            }
            if let completedResult {
                continuation.resume(returning: completedResult)
            }
        }
    }

    func resolve(_ result: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

private func waitForConnectionClose(
    _ connection: VsockConnection,
    timeout: Duration
) async -> Bool {
    let latch = BooleanCompletionLatch()
    let waiter = Task {
        await connection.closed.value
        latch.resolve(true)
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        latch.resolve(false)
    }
    let result = await latch.wait()
    waiter.cancel()
    timeoutTask.cancel()
    return result
}

private func makeDeterministicPayload(byteCount: Int) -> Data {
    var state: UInt32 = 0x9e37_79b9
    return Data(
        (0..<byteCount).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 16)
        }
    )
}

private func readExactly(_ byteCount: Int, from descriptor: Int32) throws -> Data {
    var result = Data(repeating: 0, count: byteCount)
    try result.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < byteCount {
            let bytesRead = Darwin.read(
                descriptor,
                baseAddress.advanced(by: offset),
                byteCount - offset
            )
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard bytesRead > 0 else {
                throw VsockConnectionError.closed
            }
            offset += bytesRead
        }
    }
    return result
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let bytesWritten = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if bytesWritten < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard bytesWritten > 0 else {
                throw VsockConnectionError.closed
            }
            offset += bytesWritten
        }
    }
}
