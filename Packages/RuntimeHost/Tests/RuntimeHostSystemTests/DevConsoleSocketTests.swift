import Darwin
import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeHost

/// A console that records what the client sends and yields what the test pushes.
private final class FakeConsole: DevConsoleSource, @unchecked Sendable {
    let name: String
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var received = Data()

    init(name: String) {
        self.name = name
        let stream = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        output = stream.stream
        continuation = stream.continuation
    }

    func push(_ data: Data) {
        continuation.yield(data)
    }

    func send(_ data: Data) throws {
        lock.withLock { received.append(data) }
    }

    var sent: Data {
        lock.withLock { received }
    }
}

/// A short directory: a socket path must fit in `sockaddr_un`.
private func shortDirectory() -> URL {
    URL(fileURLWithPath: "/tmp/apkrun-dcs-\(UUID().uuidString.prefix(8))", isDirectory: true)
}

/// Reads from `descriptor` until `marker` appears or five seconds pass.
private func readUntil(_ descriptor: Int32, containing marker: String) -> String {
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, 100) > 0 else { continue }
        let count = read(descriptor, &buffer, buffer.count)
        if count <= 0 { break }
        collected.append(contentsOf: buffer[0..<count])
        if String(decoding: collected, as: UTF8.self).contains(marker) { break }
    }
    return String(decoding: collected, as: UTF8.self)
}

@Test
func devConsoleSocketIsOwnerOnlyAndRemovedAtStop() throws {
    let directory = shortDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = DevConsoleSocketServer(directory: directory)
    try server.serve(FakeConsole(name: "hvc1"))
    let socketPath = directory.appendingPathComponent("hvc1.sock").path

    let directoryMode = try #require(
        (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]) as? NSNumber
    )
    let socketMode = try #require(
        (try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions]) as? NSNumber
    )
    #expect(directoryMode.intValue == 0o700)
    #expect(socketMode.intValue == 0o600)

    server.stop()
    #expect(!FileManager.default.fileExists(atPath: socketPath))
}

@Test
func devConsoleSocketRelaysBothWaysAndRefusesASecondClient() throws {
    let directory = shortDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = DevConsoleSocketServer(directory: directory)
    let console = FakeConsole(name: "hvc1")
    try server.serve(console)
    defer { server.stop() }

    let client = try DevConsoleSocketClient.connect(console: "hvc1", directory: directory)
    defer { Darwin.close(client) }
    console.push(Data("guest output\n".utf8))
    #expect(readUntil(client, containing: "guest output").contains("guest output"))

    let input = Data("getprop sys.boot_completed\n".utf8)
    _ = input.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
    let deadline = Date().addingTimeInterval(5)
    while console.sent != input, Date() < deadline {
        usleep(20_000)
    }
    #expect(console.sent == input)

    let second = try DevConsoleSocketClient.connect(console: "hvc1", directory: directory)
    defer { Darwin.close(second) }
    var buffer = [UInt8](repeating: 0, count: 16)
    var pending = pollfd(fd: second, events: Int16(POLLIN), revents: 0)
    _ = poll(&pending, 1, 2_000)
    let received = read(second, &buffer, buffer.count)
    #expect(received == 0, "the server closes a second client")
}

@Test
func devConsoleClientReportsNotRunningWhenNoOwnerHasTheSocket() {
    let directory = shortDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: RuntimeFailure.devConsoleNotRunning(console: "hvc1")) {
        _ = try DevConsoleSocketClient.connect(console: "hvc1", directory: directory)
    }
}
