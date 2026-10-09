import Darwin
import DiagnosticsCore
import Dispatch
import Foundation

/// Forwards one host loopback TCP port to one guest vsock port (vm.md §8, android-image.md §7.3).
///
/// Developer mode uses it for ADB: `127.0.0.1:6520` to guest vsock `5555`. The listener is an
/// IPv4 socket bound to `127.0.0.1` and nothing else, so no other address of the Mac reaches the
/// guest (NFR-SEC-06). Network.framework cannot do this on macOS 27: `requiredLocalEndpoint`
/// makes `NWListener` fail with `EINVAL`, and `requiredInterfaceType` still leaves the socket
/// bound to every address.
///
/// Each accepted TCP connection opens one guest connection, then copies bytes both ways until
/// either side ends. When the guest connection cannot be opened, the TCP connection is closed at
/// once, so the client sees a closed connection instead of a hang.
public final class VsockLoopbackForwarder: @unchecked Sendable {
    /// The TCP port requested at init. `0` asks the kernel for a free port, and `port` reports it.
    public let requestedPort: UInt16
    /// The guest vsock port that every accepted connection opens.
    public let guestPort: UInt32

    private static let chunkSize = 64 * 1_024
    private static let backlog: Int32 = 8

    private let connectGuest: @Sendable (UInt32) async throws -> VsockConnection
    private let logger: APKLogger
    private let acceptQueue = DispatchQueue(label: "io.apkrun.vm.vsock.loopback.accept")
    private let lock = NSLock()
    private var acceptSource: DispatchSourceRead?
    private var sessions: [UUID: LoopbackSession] = [:]
    private var hasStarted = false
    private var isStopped = false
    private var boundPort: UInt16?

    /// The bound TCP port once `start` has succeeded.
    public var port: UInt16? {
        lock.withLock { boundPort }
    }

    /// Creates a forwarder. Nothing listens until `start`.
    ///
    /// - Parameters:
    ///   - requestedPort: the loopback TCP port; `0` picks a free one.
    ///   - guestPort: the guest vsock port to open for each connection.
    ///   - logSink: where the forwarder's log entries go.
    ///   - connectGuest: opens a host-to-guest connection to a vsock port, normally `VMController.connect`.
    public init(
        requestedPort: UInt16,
        guestPort: UInt32,
        logSink: (any LogSink)?,
        connectGuest: @escaping @Sendable (UInt32) async throws -> VsockConnection
    ) {
        self.requestedPort = requestedPort
        self.guestPort = guestPort
        self.connectGuest = connectGuest
        logger = APKLogger(category: VMLogCategory.vsock, sink: logSink)
    }

    /// Binds `127.0.0.1` and starts accepting connections. Calling it again after a successful start does nothing.
    ///
    /// Throws `loopbackPortInUse` when another process already listens on the port, and
    /// `loopbackListenFailed` for any other socket error. Nothing is left open on failure.
    public func start() throws(VMFailure) {
        let shouldOpen = lock.withLock { () -> Bool in
            if hasStarted || isStopped {
                return false
            }
            hasStarted = true
            return true
        }
        guard shouldOpen else {
            return
        }
        let listener: (descriptor: Int32, port: UInt16)
        do {
            listener = try Self.openLoopbackListener(port: requestedPort)
        } catch {
            lock.withLock { hasStarted = false }
            logger.error(
                "Could not open the loopback forwarder on port \(requestedPort, .public)",
                errorCode: error.qualifiedCode
            )
            throw error
        }
        let descriptor = listener.descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(from: descriptor)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        lock.withLock {
            boundPort = listener.port
            acceptSource = source
        }
        source.resume()
        logger.notice(
            "Forwarding 127.0.0.1:\(listener.port, .public) to guest vsock \(guestPort, .public)"
        )
    }

    /// Stops accepting connections and closes the open ones. The forwarder cannot be started again.
    public func stop() {
        let (source, open) = lock.withLock { () -> (DispatchSourceRead?, [LoopbackSession]) in
            isStopped = true
            let source = acceptSource
            acceptSource = nil
            let open = Array(sessions.values)
            sessions.removeAll()
            return (source, open)
        }
        source?.cancel()
        for session in open {
            session.finish()
        }
        if source != nil {
            logger.notice("Stopped the loopback forwarder on port \(requestedPort, .public)")
        }
    }

    private func acceptConnection(from listenerDescriptor: Int32) {
        let client = Darwin.accept(listenerDescriptor, nil, nil)
        guard client >= 0 else {
            return
        }
        Self.configureAcceptedSocket(client)
        let session = LoopbackSession(descriptor: client)
        let identifier = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard !isStopped else {
                return false
            }
            sessions[identifier] = session
            return true
        }
        guard accepted else {
            session.finish()
            session.closeDescriptor()
            return
        }
        Task {
            await self.serve(session: session, identifier: identifier)
        }
    }

    private func serve(session: LoopbackSession, identifier: UUID) async {
        defer {
            _ = lock.withLock { sessions.removeValue(forKey: identifier) }
            session.closeDescriptor()
        }
        let guest: VsockConnection
        do {
            guest = try await connectGuest(guestPort)
        } catch {
            logger.warning(
                "A loopback connection could not reach guest vsock \(guestPort, .public)",
                errorCode: (error as? APKRunError)?.qualifiedCode
            )
            session.finish()
            return
        }
        session.attach(guest)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.pumpHostToGuest(session: session, guest: guest)
            }
            group.addTask {
                await Self.pumpGuestToHost(session: session, guest: guest)
            }
        }
        guest.close()
    }

    /// Copies bytes from the TCP client to the guest until the client ends or a write fails.
    private static func pumpHostToGuest(session: LoopbackSession, guest: VsockConnection) async {
        while let bytes = await readFromHost(session.descriptor) {
            do {
                try await guest.write(bytes)
            } catch {
                break
            }
        }
        session.finish()
    }

    /// Copies bytes from the guest to the TCP client until the guest closes or a write fails.
    private static func pumpGuestToHost(session: LoopbackSession, guest: VsockConnection) async {
        while true {
            let bytes: Data
            do {
                bytes = try await guest.read(upTo: chunkSize)
            } catch {
                break
            }
            guard !bytes.isEmpty else {
                break
            }
            guard await writeToHost(session.descriptor, bytes) else {
                break
            }
        }
        session.finish()
    }

    /// Reads one chunk from a blocking socket on a utility queue. Returns `nil` at end of stream or on error.
    private static func readFromHost(_ descriptor: Int32) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while true {
                    let count = Darwin.recv(descriptor, &buffer, chunkSize, 0)
                    if count > 0 {
                        continuation.resume(returning: Data(buffer[0..<count]))
                        return
                    }
                    if count < 0 && errno == EINTR {
                        continue
                    }
                    continuation.resume(returning: nil)
                    return
                }
            }
        }
    }

    /// Writes all of `bytes` to a blocking socket on a utility queue. Returns `false` on error.
    private static func writeToHost(_ descriptor: Int32, _ bytes: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let written = bytes.withUnsafeBytes { buffer -> Bool in
                    guard let base = buffer.baseAddress else {
                        return true
                    }
                    var offset = 0
                    while offset < buffer.count {
                        let count = Darwin.send(descriptor, base + offset, buffer.count - offset, 0)
                        if count > 0 {
                            offset += count
                        } else if count < 0 && errno == EINTR {
                            continue
                        } else {
                            return false
                        }
                    }
                    return true
                }
                continuation.resume(returning: written)
            }
        }
    }

    /// Opens the listener. `port` 0 asks for an ephemeral port; a fixed port is first probed so that
    /// a listener on another address of the same port is still reported as in use.
    private static func openLoopbackListener(port: UInt16) throws(VMFailure) -> (descriptor: Int32, port: UInt16) {
        if port != 0, isAcceptingConnections(on: port) {
            throw .loopbackPortInUse(port: port)
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw .loopbackListenFailed(port: port, underlying: systemError(errno))
        }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = loopbackAddress(port: port)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EADDRINUSE {
                throw .loopbackPortInUse(port: port)
            }
            throw .loopbackListenFailed(port: port, underlying: systemError(code))
        }
        guard Darwin.listen(descriptor, backlog) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw .loopbackListenFailed(port: port, underlying: systemError(code))
        }
        var bindAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw .loopbackListenFailed(port: port, underlying: systemError(code))
        }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        return (descriptor, UInt16(bigEndian: bindAddress.sin_port))
    }

    /// Returns whether something accepts a connection on `127.0.0.1:port`, waiting at most half a second.
    private static func isAcceptingConnections(on port: UInt16) -> Bool {
        let probe = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else {
            return false
        }
        defer {
            Darwin.close(probe)
        }
        let flags = fcntl(probe, F_GETFL)
        _ = fcntl(probe, F_SETFL, flags | O_NONBLOCK)
        var address = loopbackAddress(port: port)
        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 {
            return true
        }
        let code = errno
        if code == ECONNREFUSED {
            return false
        }
        guard code == EINPROGRESS else {
            return false
        }
        var pending = pollfd(fd: probe, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&pending, 1, 500) > 0 else {
            // A listener whose backlog is full does not refuse, so the port is taken.
            return true
        }
        var status: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(probe, SOL_SOCKET, SO_ERROR, &status, &length)
        return status == 0
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        return address
    }

    private static func configureAcceptedSocket(_ descriptor: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
    }

    private static func systemError(_ code: Int32) -> UnderlyingError {
        UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

/// One accepted TCP connection and the guest connection it is spliced to.
private final class LoopbackSession: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var guest: VsockConnection?
    private var isFinished = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Stores the guest connection, or closes it at once when the session has already finished.
    func attach(_ connection: VsockConnection) {
        let finished = lock.withLock { () -> Bool in
            guest = connection
            return isFinished
        }
        if finished {
            connection.close()
        }
    }

    /// Shuts the TCP side down and closes the guest side. Blocked reads and writes return.
    func finish() {
        let connection = lock.withLock { () -> VsockConnection? in
            isFinished = true
            return guest
        }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        connection?.close()
    }

    /// Closes the descriptor. Call only after both pumps have returned.
    func closeDescriptor() {
        Darwin.close(descriptor)
    }
}
