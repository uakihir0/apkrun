import Darwin
import DiagnosticsCore
import Dispatch
import Foundation
import RuntimeAPI
import RuntimeCore

/// A host power message injected by an embedded developer command.
public enum DevPowerAction: String, Sendable, Equatable {
    /// Simulate `kIOMessageSystemWillSleep`.
    case sleep
    /// Simulate `kIOMessageSystemHasPoweredOn`.
    case wake

    fileprivate var event: PowerObserverEvent {
        switch self {
        case .sleep: .systemWillSleep
        case .wake: .systemHasPoweredOn
        }
    }
}

/// Developer-only operations that are routed to the process owning `apkrun dev boot`.
public protocol DeveloperService: Sendable {
    /// Injects the same sleep or wake event handled by `PowerObserver`.
    func injectPower(_ action: DevPowerAction) async
}

/// Serializes real and injected power events for one embedded runtime.
///
/// A runtime suspended by this service for a host sleep is resumed at wake. A runtime already suspended
/// by another policy stays suspended, matching the daemon's host sleep rules.
public actor EmbeddedDeveloperService: DeveloperService {
    private struct PendingEvent {
        let event: PowerObserverEvent
        let completion: CheckedContinuation<Void, Never>
    }

    private let supervisor: RuntimeSupervisor
    private let report: @Sendable (String) -> Void
    private var resumeAfterWake = false
    private var pendingEvents: [PendingEvent] = []
    private var isDelivering = false

    /// Creates the developer power service for an embedded runtime.
    public init(
        supervisor: RuntimeSupervisor,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.supervisor = supervisor
        self.report = report
    }

    /// Injects one developer command through the same event path used by `PowerObserver`.
    public func injectPower(_ action: DevPowerAction) async {
        await enqueue(action.event)
    }

    /// Handles a host event delivered by `PowerObserver`.
    public func receivePowerObserverEvent(_ event: PowerObserverEvent) async {
        await enqueue(event)
    }

    private func enqueue(_ event: PowerObserverEvent) async {
        await withCheckedContinuation { completion in
            pendingEvents.append(PendingEvent(event: event, completion: completion))
            guard !isDelivering else { return }
            isDelivering = true
            Task { await deliverPendingEvents() }
        }
    }

    private func deliverPendingEvents() async {
        while !pendingEvents.isEmpty {
            let pending = pendingEvents.removeFirst()
            await apply(pending.event)
            pending.completion.resume()
        }
        isDelivering = false
    }

    private func apply(_ event: PowerObserverEvent) async {
        switch event {
        case .systemWillSleep:
            do {
                resumeAfterWake = try await supervisor.prepareForHostSleep()
            } catch {
                report("host sleep could not pause Android (\(error.qualifiedCode))")
            }
        case .systemWillNotSleep:
            await completeHostSleep(cancelled: true)
        case .systemHasPoweredOn:
            await completeHostSleep(cancelled: false)
        }
    }

    private func completeHostSleep(cancelled: Bool) async {
        guard resumeAfterWake else { return }
        defer { resumeAfterWake = false }
        do {
            try await supervisor.completeHostSleep(cancelled: cancelled)
        } catch {
            report("host wake could not resume Android (\(error.qualifiedCode))")
        }
    }
}

/// A request/reply Unix socket for `apkrun dev power`, separate from the HVC byte-stream sockets.
///
/// `control.sock` is created with mode 0600 inside the 0700 developer-console directory and removed
/// when the owning `apkrun dev boot` exits.
public final class DevControlSocketServer: @unchecked Sendable {
    private let directory: URL
    private let service: any DeveloperService
    private let lock = NSLock()
    private var listener: DevControlSocketListener?
    private var isStopped = false

    /// Creates the control endpoint for a running embedded runtime.
    public init(directory: URL, service: any DeveloperService) {
        self.directory = directory
        self.service = service
    }

    /// Creates and starts `control.sock`.
    public func start() throws(RuntimeFailure) {
        guard !lock.withLock({ isStopped || listener != nil }) else {
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
        guard chmod(directory.path, 0o700) == 0 else {
            throw .devConsoleSocketUnavailable
        }
        let path = directory.appendingPathComponent("control.sock").path
        guard path.utf8.count <= DevControlSocketListener.maximumPathBytes else {
            throw .devConsoleSocketUnavailable
        }
        if let existing = Self.fileType(at: path) {
            guard existing == S_IFSOCK, unlink(path) == 0 else {
                throw .devConsoleSocketUnavailable
            }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw .devConsoleSocketUnavailable
        }
        Self.preventSIGPIPE(on: descriptor)
        guard
            DevControlSocketListener.bindSocket(descriptor, to: path),
            chmod(path, 0o600) == 0,
            listen(descriptor, 4) == 0
        else {
            close(descriptor)
            unlink(path)
            throw .devConsoleSocketUnavailable
        }
        let newListener = DevControlSocketListener(
            path: path,
            descriptor: descriptor,
            service: service
        )
        let canStart = lock.withLock { () -> Bool in
            guard !isStopped, listener == nil else { return false }
            listener = newListener
            return true
        }
        guard canStart else {
            newListener.stop()
            throw .devConsoleSocketUnavailable
        }
        newListener.start()
    }

    /// Stops the listener and removes `control.sock`.
    public func stop() {
        let current = lock.withLock { () -> DevControlSocketListener? in
            isStopped = true
            let current = listener
            listener = nil
            return current
        }
        current?.stop()
    }

    private static func fileType(at path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    fileprivate static func preventSIGPIPE(on descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
}

/// The short-lived command-side client of `control.sock`.
public enum DevControlSocketClient {
    /// Sends one power action to the running `apkrun dev boot`.
    public static func injectPower(_ action: DevPowerAction, directory: URL) throws {
        let path = directory.appendingPathComponent("control.sock").path
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeFailure.devConsoleSocketUnavailable
        }
        defer { close(descriptor) }
        DevControlSocketServer.preventSIGPIPE(on: descriptor)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Self.notRunning(action)
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
            throw Self.notRunning(action)
        }

        let request = Data("\(action.rawValue)\n".utf8)
        guard Self.writeAll(request, to: descriptor) else {
            throw RuntimeWireError.runtime(
                "internal",
                message: "APKRun could not send the development power request.",
                remediation: "Restart `apkrun dev boot`, then try again."
            )
        }
        shutdown(descriptor, SHUT_WR)
        guard let response = Self.readLine(from: descriptor) else {
            throw RuntimeWireError.runtime(
                "internal",
                message: "APKRun did not receive a reply to the development power request.",
                remediation: "Check that `apkrun dev boot` is still running, then try again."
            )
        }
        guard response == "ok" else {
            throw RuntimeWireError.runtime(
                "internal",
                message: "APKRun received an invalid reply to the development power request.",
                remediation: "Restart `apkrun dev boot`, then try again."
            )
        }
    }

    private static func notRunning(_ action: DevPowerAction) -> RuntimeWireError {
        RuntimeWireError.runtime(
            "serviceUnavailable",
            message: "No `apkrun dev boot` owns the development runtime.",
            remediation:
                "Start `apkrun dev boot` in another terminal, then run `apkrun dev power \(action.rawValue)` again."
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset,
                    0
                )
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func readLine(from descriptor: Int32) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 64 {
            var byte: UInt8 = 0
            let count = read(descriptor, &byte, 1)
            guard count == 1 else { return nil }
            if byte == 0x0A {
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(byte)
        }
        return nil
    }
}

/// The listener's descriptor and accepted client are closed by their owning accept thread.
private final class DevControlSocketListener: @unchecked Sendable {
    static let maximumPathBytes = 103
    private static let maximumRequestBytes = 32

    private let path: String
    private let descriptor: Int32
    private let service: any DeveloperService
    private let lock = NSLock()
    private var activeClient: Int32?
    private var isStopped = false

    init(path: String, descriptor: Int32, service: any DeveloperService) {
        self.path = path
        self.descriptor = descriptor
        self.service = service
    }

    func start() {
        let thread = Thread { [self] in
            acceptRequests()
        }
        thread.name = "apkrun.dev-control"
        thread.start()
    }

    func stop() {
        let client = lock.withLock { () -> Int32? in
            isStopped = true
            return activeClient
        }
        if let client {
            shutdown(client, SHUT_RDWR)
        }
        shutdown(descriptor, SHUT_RDWR)
        unlink(path)
    }

    fileprivate static func bindSocket(_ descriptor: Int32, to path: String) -> Bool {
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

    private func acceptRequests() {
        defer { close(descriptor) }
        while !lock.withLock({ isStopped }) {
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else { return }
            Self.setReadTimeout(on: accepted)
            DevControlSocketServer.preventSIGPIPE(on: accepted)
            let shouldHandle = lock.withLock { () -> Bool in
                guard !isStopped else { return false }
                activeClient = accepted
                return true
            }
            guard shouldHandle else {
                close(accepted)
                return
            }
            handleRequest(accepted)
            lock.withLock {
                if activeClient == accepted {
                    activeClient = nil
                }
            }
            close(accepted)
        }
    }

    private func handleRequest(_ client: Int32) {
        guard let request = Self.readRequest(from: client),
            let action = DevPowerAction(rawValue: request)
        else {
            _ = Self.writeLine("invalid", to: client)
            return
        }

        let completion = DispatchSemaphore(value: 0)
        Task {
            await service.injectPower(action)
            completion.signal()
        }
        completion.wait()
        _ = Self.writeLine("ok", to: client)
    }

    private static func readRequest(from descriptor: Int32) -> String? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: maximumRequestBytes)
        while bytes.count < maximumRequestBytes {
            let count = read(descriptor, &buffer, min(buffer.count, maximumRequestBytes - bytes.count))
            guard count > 0 else {
                guard count == 0, let request = String(bytes: bytes, encoding: .utf8) else {
                    return nil
                }
                guard request.hasSuffix("\n"), !request.contains("\r") else { return nil }
                return String(request.dropLast())
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    private static func writeLine(_ value: String, to descriptor: Int32) -> Bool {
        let data = Data("\(value)\n".utf8)
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset,
                    0
                )
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func setReadTimeout(on descriptor: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
}
