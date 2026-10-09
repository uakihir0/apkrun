import Darwin
import DiagnosticsCore
import Foundation
import RuntimeCore

/// A developer console the socket serves: the guest's output and the host's input (#014).
///
/// `RuntimeCore.DevConsoleEndpoint` is the production source. Tests use their own source, which
/// keeps the socket code testable without a VM.
public protocol DevConsoleSource: Sendable {
    /// The console's device name in the guest (`hvc0` or `hvc1`).
    var name: String { get }
    /// The guest's bytes, in order. One consumer reads this stream.
    var output: AsyncStream<Data> { get }
    /// Writes host input to the guest.
    func send(_ data: Data) throws
}

extension DevConsoleEndpoint: DevConsoleSource {}

/// The Unix sockets that carry the developer consoles of a running `apkrun dev boot` (#014).
///
/// Each console has one socket, `<directory>/<name>.sock`, with mode 0600 in a 0700 directory.
/// One client at a time is attached; a second client is refused. A socket exists while its VM
/// runs, and `stop()` closes and removes it. The guest's output goes to the attached client, and
/// the client's input goes to the guest.
public final class DevConsoleSocketServer: @unchecked Sendable {
    /// The longest socket path `sockaddr_un` can hold, without its terminating NUL.
    private static let maximumPathBytes = 103

    private let directory: URL
    private let lock = NSLock()
    private var listeners: [Listener] = []

    /// Creates a server for the sockets in `directory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Creates the socket of `endpoint`, and relays the endpoint's output to its client.
    public func serve(_ endpoint: any DevConsoleSource) throws(RuntimeFailure) {
        let path = directory.appendingPathComponent("\(endpoint.name).sock").path
        guard path.utf8.count <= Self.maximumPathBytes else {
            throw .devConsoleSocketUnavailable
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .devConsoleSocketUnavailable
        }
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw .devConsoleSocketUnavailable
        }
        guard Self.bindSocket(descriptor, to: path), chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            try? FileManager.default.removeItem(atPath: path)
            throw .devConsoleSocketUnavailable
        }
        let listener = Listener(name: endpoint.name, path: path, descriptor: descriptor, endpoint: endpoint)
        lock.withLock { listeners.append(listener) }
        listener.start()
    }

    /// Closes every socket, detaches the clients, and removes the socket files.
    public func stop() {
        let closing = lock.withLock { () -> [Listener] in
            let current = listeners
            listeners = []
            return current
        }
        for listener in closing {
            listener.stop()
        }
    }

    private static func bindSocket(_ descriptor: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}

/// The client helper of `apkrun dev console --android-shell`.
public enum DevConsoleSocketClient {
    /// Connects to the socket of console `name` under `directory` and returns its file descriptor.
    ///
    /// The caller closes the descriptor. Without a socket (no `apkrun dev boot` owns the instance),
    /// this throws `devConsoleNotRunning`.
    public static func connect(console name: String, directory: URL) throws(RuntimeFailure) -> Int32 {
        let path = directory.appendingPathComponent("\(name).sock").path
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw .devConsoleSocketUnavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw .devConsoleNotRunning(console: name)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else {
            close(descriptor)
            throw .devConsoleNotRunning(console: name)
        }
        return descriptor
    }
}

/// One console's listening socket, its single client, and the relay between them.
private final class Listener: @unchecked Sendable {
    let name: String
    let path: String
    private let descriptor: Int32
    private let endpoint: any DevConsoleSource
    private let lock = NSLock()
    private var client: Int32?
    private var relayTask: Task<Void, Never>?
    private var acceptThread: Thread?
    private var isStopped = false

    init(name: String, path: String, descriptor: Int32, endpoint: any DevConsoleSource) {
        self.name = name
        self.path = path
        self.descriptor = descriptor
        self.endpoint = endpoint
    }

    func start() {
        let thread = Thread { [self] in
            acceptClients()
        }
        thread.name = "apkrun.dev-console.\(name)"
        lock.withLock { acceptThread = thread }
        thread.start()
        let endpoint = endpoint
        let task = Task { [weak self] in
            for await bytes in endpoint.output {
                self?.deliver(bytes)
            }
        }
        lock.withLock { relayTask = task }
    }

    func stop() {
        let clientToClose: Int32? = lock.withLock {
            isStopped = true
            let current = client
            client = nil
            return current
        }
        if let clientToClose {
            shutdown(clientToClose, SHUT_RDWR)
            close(clientToClose)
        }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
        lock.withLock { relayTask }?.cancel()
    }

    private func acceptClients() {
        while true {
            let accepted = accept(descriptor, nil, nil)
            if accepted < 0 {
                return
            }
            let refused = lock.withLock { () -> Bool in
                if isStopped || client != nil {
                    return true
                }
                client = accepted
                return false
            }
            if refused {
                close(accepted)
                continue
            }
            // The reader has its own thread, so that the accept loop can refuse the next client.
            let reader = Thread { [self] in
                readInput(from: accepted)
            }
            reader.name = "apkrun.dev-console.\(name).input"
            reader.start()
        }
    }

    /// Reads the client's input until it closes, and gives each chunk to the guest.
    private func readInput(from clientDescriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(clientDescriptor, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            do {
                try endpoint.send(Data(buffer[0..<count]))
            } catch {
                break
            }
        }
        lock.withLock {
            if client == clientDescriptor {
                client = nil
            }
        }
        close(clientDescriptor)
    }

    /// Writes one chunk of guest output to the attached client, if there is one.
    private func deliver(_ bytes: Data) {
        let current = lock.withLock { client }
        guard let current else {
            return
        }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var offset = 0
            while offset < raw.count {
                let written = send(current, base + offset, raw.count - offset, MSG_NOSIGNAL)
                if written <= 0 {
                    return
                }
                offset += written
            }
        }
    }
}
