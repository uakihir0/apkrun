import Foundation
import VirtualMachineCore

/// A one-shot gate for keeping a fake VM operation pending in lifecycle tests.
public actor FakeVirtualMachineDriverGate {
    private var isOpen = false
    private var hasEntered = false
    private var openWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private let ignoresCancellation: Bool

    /// Creates a closed gate.
    ///
    /// - Parameter ignoresCancellation: Keep waiting after the scripted task is cancelled.
    public init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    /// Whether an operation is currently waiting for the gate to open.
    public var isOperationPending: Bool {
        !openWaiters.isEmpty
    }

    /// Waits until the scripted operation is allowed to return.
    public func waitUntilOpen() async {
        let waiterID = UUID()
        let ignoresCancellation = self.ignoresCancellation
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    openWaiters[waiterID] = continuation
                }

                hasEntered = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        } onCancel: {
            guard !ignoresCancellation else { return }
            Task {
                await self.cancelOpenWaiter(waiterID)
            }
        }
    }

    /// Waits until the scripted operation reaches this gate.
    public func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            entryWaiters.append(continuation)
        }
    }

    /// Opens the gate and resumes all pending operations.
    public func open() {
        isOpen = true
        let waiters = Array(openWaiters.values)
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelOpenWaiter(_ identifier: UUID) {
        openWaiters.removeValue(forKey: identifier)?.resume()
    }
}

/// A callback script used to emulate immediate and late vsock connects.
public typealias FakeVsockConnectHandler =
    @Sendable (
        UInt32,
        @escaping @Sendable (Result<VsockConnection, VirtualMachineDriverConnectFailure>) -> Void
    ) -> Void

/// Results returned by one scripted fake VM driver.
public struct FakeVirtualMachineDriverScript: Sendable {
    /// The result of starting the guest.
    public var start: Result<Void, VZErrorInfo>

    /// The result of force-stopping the guest.
    public var stop: Result<Void, VZErrorInfo>

    /// The result of requesting a guest shutdown.
    public var requestStop: Result<Void, VZErrorInfo>

    /// The result of pausing the guest.
    public var pause: Result<Void, VZErrorInfo>

    /// The result of resuming the guest.
    public var resume: Result<Void, VZErrorInfo>

    /// Optional gate that keeps `pause()` pending until explicitly opened.
    public var pauseGate: FakeVirtualMachineDriverGate?

    /// Optional gate that keeps `stop()` pending until explicitly opened.
    public var stopGate: FakeVirtualMachineDriverGate?

    /// Optional gate that keeps `start()` pending until explicitly opened.
    public var startGate: FakeVirtualMachineDriverGate?

    /// Optional gate that keeps `release()` pending until explicitly opened.
    public var releaseGate: FakeVirtualMachineDriverGate?

    /// Optional callback script used to emulate immediate and late vsock connects.
    public var connectHandler: FakeVsockConnectHandler?

    /// Creates a script whose operations succeed unless a failure is supplied.
    public init(
        start: Result<Void, VZErrorInfo> = .success(()),
        stop: Result<Void, VZErrorInfo> = .success(()),
        requestStop: Result<Void, VZErrorInfo> = .success(()),
        pause: Result<Void, VZErrorInfo> = .success(()),
        resume: Result<Void, VZErrorInfo> = .success(()),
        pauseGate: FakeVirtualMachineDriverGate? = nil,
        stopGate: FakeVirtualMachineDriverGate? = nil,
        startGate: FakeVirtualMachineDriverGate? = nil,
        releaseGate: FakeVirtualMachineDriverGate? = nil,
        connectHandler: FakeVsockConnectHandler? = nil
    ) {
        self.start = start
        self.stop = stop
        self.requestStop = requestStop
        self.pause = pause
        self.resume = resume
        self.pauseGate = pauseGate
        self.stopGate = stopGate
        self.startGate = startGate
        self.releaseGate = releaseGate
        self.connectHandler = connectHandler
    }
}

/// The operations recorded by `FakeVirtualMachineDriver`.
public enum FakeVirtualMachineDriverOperation: Equatable, Sendable {
    /// The guest was started.
    case start

    /// The guest was force-stopped.
    case stop

    /// A guest shutdown was requested.
    case requestStop

    /// The guest was paused.
    case pause

    /// The guest was resumed.
    case resume

    /// A host-to-guest vsock connection was requested.
    case connect(port: UInt32)

    /// Framework objects were released.
    case release
}

// UNCHECKED-SENDABLE: the lock protects recordedOperations; all other stored values are immutable and Sendable.
/// A thread-safe driver fake with scripted operation results and VM events.
public final class FakeVirtualMachineDriver: VirtualMachineDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOperations: [FakeVirtualMachineDriverOperation] = []
    private var recordedOperationsAfterRelease: [FakeVirtualMachineDriverOperation] = []
    private var didRelease = false
    private let eventContinuation: AsyncStream<VirtualMachineEvent>.Continuation
    private let script: FakeVirtualMachineDriverScript

    /// The event stream consumed by `VMController`.
    public let events: AsyncStream<VirtualMachineEvent>

    /// Creates a driver fake with the provided operation results.
    public init(script: FakeVirtualMachineDriverScript = FakeVirtualMachineDriverScript()) {
        let stream = AsyncStream.makeStream(of: VirtualMachineEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
        self.script = script
    }

    /// A snapshot of the operations received so far.
    public var operations: [FakeVirtualMachineDriverOperation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperations
    }

    /// A snapshot of invalid calls made after framework objects were released.
    public var operationsAfterRelease: [FakeVirtualMachineDriverOperation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperationsAfterRelease
    }

    /// Emits one asynchronous VM event.
    public func emit(_ event: VirtualMachineEvent) {
        eventContinuation.yield(event)
    }

    /// Finishes the event stream.
    public func finishEvents() {
        eventContinuation.finish()
    }

    /// Starts the fake guest or returns the scripted start failure.
    public func start() async throws(VZErrorInfo) {
        try await perform(.start, result: script.start, gate: script.startGate)
    }

    /// Force-stops the fake guest or returns the scripted stop failure.
    public func stop() async throws(VZErrorInfo) {
        try await perform(.stop, result: script.stop, gate: script.stopGate)
    }

    /// Requests a guest shutdown or returns the scripted request failure.
    public func requestStop() async throws(VZErrorInfo) {
        try await perform(.requestStop, result: script.requestStop)
    }

    /// Pauses the fake guest or returns the scripted pause failure.
    public func pause() async throws(VZErrorInfo) {
        try await perform(.pause, result: script.pause, gate: script.pauseGate)
    }

    /// Resumes the fake guest or returns the scripted resume failure.
    public func resume() async throws(VZErrorInfo) {
        try await perform(.resume, result: script.resume)
    }

    /// Emulates a host-to-guest vsock connection.
    public func connect(
        toPort port: UInt32,
        completion:
            @escaping @Sendable (
                Result<VsockConnection, VirtualMachineDriverConnectFailure>
            ) -> Void
    ) {
        let wasReleased = lock.withLock {
            if didRelease {
                recordedOperationsAfterRelease.append(.connect(port: port))
                return true
            }
            recordedOperations.append(.connect(port: port))
            return false
        }
        guard !wasReleased else {
            completion(
                .failure(
                    .virtualization(
                        VZErrorInfo(
                            domain: "FakeVirtualMachineDriver",
                            code: 2,
                            description: "Operation attempted after the fake driver was released."
                        )
                    )
                )
            )
            return
        }
        if let connectHandler = script.connectHandler {
            connectHandler(port, completion)
        } else {
            completion(
                .failure(
                    .virtualization(
                        VZErrorInfo(
                            domain: "FakeVirtualMachineDriver",
                            code: 1,
                            description: "No vsock connect handler was configured."
                        )
                    )
                )
            )
        }
    }

    /// Releases fake framework resources and finishes the event stream.
    public func release() async {
        lock.withLock {
            recordedOperations.append(.release)
        }
        if let releaseGate = script.releaseGate {
            await releaseGate.waitUntilOpen()
        }
        lock.withLock {
            didRelease = true
        }
        eventContinuation.finish()
    }

    private func perform(
        _ operation: FakeVirtualMachineDriverOperation,
        result: Result<Void, VZErrorInfo>,
        gate: FakeVirtualMachineDriverGate? = nil
    ) async throws(VZErrorInfo) {
        let wasReleased = lock.withLock {
            if didRelease {
                recordedOperationsAfterRelease.append(operation)
                return true
            }
            recordedOperations.append(operation)
            return false
        }
        guard !wasReleased else {
            throw VZErrorInfo(
                domain: "FakeVirtualMachineDriver",
                code: 1,
                description: "Operation attempted after the fake driver was released."
            )
        }

        if let gate {
            await gate.waitUntilOpen()
        }

        switch result {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}
