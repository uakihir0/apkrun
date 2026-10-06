import Dispatch
import Foundation
import Virtualization

/// A failure while reading from or writing to a host-to-guest vsock connection.
public enum VsockConnectionError: Error, Equatable, Sendable {
    /// The connection was closed before the operation could complete.
    case closed

    /// The stream operation failed with this POSIX errno value.
    case io(Int32)

    /// The peer sent more unread input than the connection's buffer limit.
    case bufferedInputLimitExceeded

    /// A read size was negative.
    case invalidReadLength
}

/// Owns one host-to-guest virtio-vsock connection.
///
/// The file descriptor belongs to Virtualization.framework and remains valid
/// only while the framework connection is retained.
public final class VsockConnection: @unchecked Sendable {
    private let closeHandle: VsockConnectionCloseHandle
    private let ioState: VsockConnectionIOState

    package convenience init(
        virtualizationConnection: VZVirtioSocketConnection,
        queue: VMQueue
    ) {
        self.init(
            fileDescriptor: virtualizationConnection.fileDescriptor,
            owner: .virtualization(virtualizationConnection),
            queue: queue
        )
    }

    package convenience init(
        testFileDescriptor: Int32,
        queue: VMQueue,
        onClose: @escaping @Sendable () -> Void,
        onReadPending: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            fileDescriptor: testFileDescriptor,
            owner: .test(onClose),
            queue: queue,
            onReadPending: onReadPending
        )
    }

    private init(
        fileDescriptor: Int32,
        owner: VsockConnectionCloseHandle.DescriptorOwner,
        queue: VMQueue,
        onReadPending: @escaping @Sendable () -> Void = {}
    ) {
        let closedSignal = VsockClosedSignal()
        let closeHandle = VsockConnectionCloseHandle(
            owner: owner,
            queue: queue,
            closedSignal: closedSignal
        )
        let ioQueue = DispatchQueue(
            label: "io.apkrun.vm.vsock.\(UUID().uuidString)",
            qos: .utility
        )
        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: fileDescriptor,
            queue: ioQueue
        ) { _ in
            closeHandle.dispatchIOClosed()
        }
        channel.setLimit(lowWater: 1)
        closeHandle.attach(channel)

        self.fileDescriptor = fileDescriptor
        self.closeHandle = closeHandle
        ioState = VsockConnectionIOState(
            channel: channel,
            queue: ioQueue,
            closeHandle: closeHandle,
            onReadPending: onReadPending
        )
        closed = Task {
            await closedSignal.wait()
        }
        Task {
            await ioState.startReading()
        }
    }

    /// The framework-owned stream socket descriptor. Do not close it directly.
    package let fileDescriptor: Int32

    /// Completes after the peer closes or this endpoint is closed.
    public let closed: Task<Void, Never>

    /// Reads up to `maximumLength` bytes, returning as soon as data is available.
    ///
    /// Returns an empty value after peer EOF once all previously received bytes
    /// have been consumed.
    public func read(upTo maximumLength: Int) async throws -> Data {
        try await ioState.read(upTo: maximumLength)
    }

    /// Writes all bytes to the guest stream.
    public func write(_ data: Data) async throws {
        try await ioState.write(data)
    }

    /// Closes the stream and releases the framework connection.
    public func close() {
        let closeHandle = closeHandle
        let ioState = ioState
        closeHandle.close()
        Task {
            await ioState.closeLocally()
        }
    }

    deinit {
        closeHandle.close()
        let ioState = ioState
        Task {
            await ioState.closeLocally()
        }
    }
}

private actor VsockConnectionIOState {
    private struct ReadEvent: Sendable {
        let data: Data
        let done: Bool
        let error: Int32
    }

    private struct PendingRead {
        let identifier: UUID
        let maximumLength: Int
        let cancellation: VsockReadCancellation
        let continuation: CheckedContinuation<Data, any Error>
    }

    private static let readChunkSize = 64 * 1024
    private static let maximumBufferedBytes = 1024 * 1024

    private let channel: DispatchIO
    private let queue: DispatchQueue
    private let closeHandle: VsockConnectionCloseHandle
    private let onReadPending: @Sendable () -> Void
    private let readEventStream: AsyncStream<ReadEvent>
    private let readEventContinuation: AsyncStream<ReadEvent>.Continuation
    private var bufferedBytes = Data()
    private var pendingReads: [PendingRead] = []
    private var readEventTask: Task<Void, Never>?
    private var readInProgress = false
    private var peerDidClose = false
    private var localDidClose = false
    private var ioFailure: VsockConnectionError?

    init(
        channel: DispatchIO,
        queue: DispatchQueue,
        closeHandle: VsockConnectionCloseHandle,
        onReadPending: @escaping @Sendable () -> Void
    ) {
        self.channel = channel
        self.queue = queue
        self.closeHandle = closeHandle
        self.onReadPending = onReadPending
        let readEvents = AsyncStream.makeStream(
            of: ReadEvent.self,
            bufferingPolicy: .unbounded
        )
        readEventStream = readEvents.stream
        readEventContinuation = readEvents.continuation
    }

    func startReading() {
        readEventTask = Task { [weak self, readEventStream] in
            for await event in readEventStream {
                guard !Task.isCancelled else { return }
                await self?.receive(event.data, done: event.done, error: event.error)
            }
        }
        guard !closeHandle.isCloseRequested else {
            closeLocally()
            return
        }
        scheduleReadIfNeeded()
    }

    func read(upTo maximumLength: Int) async throws -> Data {
        guard maximumLength >= 0 else {
            throw VsockConnectionError.invalidReadLength
        }
        guard maximumLength > 0 else { return Data() }

        guard !Task.isCancelled else {
            throw CancellationError()
        }

        if closeHandle.isCloseRequested {
            closeLocally()
        }
        if !bufferedBytes.isEmpty {
            return consumeBufferedBytes(upTo: maximumLength)
        }
        if let ioFailure {
            throw ioFailure
        }
        if localDidClose {
            throw VsockConnectionError.closed
        }
        if peerDidClose {
            return Data()
        }

        let identifier = UUID()
        let cancellation = VsockReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingReads.append(
                    PendingRead(
                        identifier: identifier,
                        maximumLength: maximumLength,
                        cancellation: cancellation,
                        continuation: continuation
                    )
                )
                onReadPending()
                scheduleReadIfNeeded()
            }
        } onCancel: {
            cancellation.cancel()
            Task {
                await self.cancelRead(identifier: identifier)
            }
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if closeHandle.isCloseRequested {
            closeLocally()
        }
        if localDidClose || peerDidClose {
            throw VsockConnectionError.closed
        }
        if let ioFailure {
            throw ioFailure
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let dispatchData = data.withUnsafeBytes { bytes in
                DispatchData(bytes: bytes)
            }
            channel.write(offset: 0, data: dispatchData, queue: queue) { done, _, error in
                guard done else { return }
                if error == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VsockConnectionError.io(error))
                }
            }
        }
    }

    func closeLocally() {
        guard !localDidClose, !peerDidClose, ioFailure == nil else { return }
        localDidClose = true
        readInProgress = false
        readEventContinuation.finish()
        readEventTask?.cancel()
        readEventTask = nil
        resumePendingReads()
    }

    fileprivate func receive(_ data: Data, done: Bool, error: Int32) {
        if closeHandle.isCloseRequested {
            closeLocally()
            return
        }
        guard !localDidClose, !peerDidClose, ioFailure == nil else { return }

        if !data.isEmpty {
            let availableCapacity = Self.maximumBufferedBytes - bufferedBytes.count
            guard data.count <= availableCapacity else {
                ioFailure = .bufferedInputLimitExceeded
                readInProgress = false
                readEventContinuation.finish()
                closeHandle.close()
                resumePendingReads()
                return
            }
            bufferedBytes.append(data)
        }

        if error != 0 {
            ioFailure = .io(error)
            readInProgress = false
            readEventContinuation.finish()
            closeHandle.close()
        } else if done {
            readInProgress = false
            if data.isEmpty {
                peerDidClose = true
                readEventContinuation.finish()
                closeHandle.close()
            }
        }

        resumePendingReads()
        scheduleReadIfNeeded()
    }

    private func scheduleReadIfNeeded() {
        if closeHandle.isCloseRequested {
            closeLocally()
            return
        }
        guard
            !readInProgress,
            !localDidClose,
            !peerDidClose,
            ioFailure == nil
        else {
            return
        }

        let availableCapacity = Self.maximumBufferedBytes - bufferedBytes.count

        readInProgress = true
        let readLength =
            availableCapacity == 0
            ? 1
            : min(Self.readChunkSize, availableCapacity)
        let readEventContinuation = readEventContinuation
        channel.read(
            offset: 0,
            length: readLength,
            queue: queue
        ) { done, data, error in
            let bytes = data.map { Data($0) } ?? Data()
            readEventContinuation.yield(
                ReadEvent(data: bytes, done: done, error: error)
            )
        }
    }

    private func cancelRead(identifier: UUID) {
        guard let index = pendingReads.firstIndex(where: { $0.identifier == identifier }) else {
            return
        }
        let pendingRead = pendingReads.remove(at: index)
        pendingRead.continuation.resume(throwing: CancellationError())
    }

    private func resumePendingReads() {
        while let pendingRead = pendingReads.first {
            guard
                !bufferedBytes.isEmpty || ioFailure != nil || localDidClose || peerDidClose
            else {
                break
            }

            pendingReads.removeFirst()
            guard pendingRead.cancellation.claimDelivery() else {
                pendingRead.continuation.resume(throwing: CancellationError())
                continue
            }

            if !bufferedBytes.isEmpty {
                let bytes = consumeBufferedBytes(upTo: pendingRead.maximumLength)
                pendingRead.continuation.resume(returning: bytes)
            } else if let ioFailure {
                pendingRead.continuation.resume(throwing: ioFailure)
            } else if localDidClose {
                pendingRead.continuation.resume(throwing: VsockConnectionError.closed)
            } else if peerDidClose {
                pendingRead.continuation.resume(returning: Data())
            }
        }
    }

    private func consumeBufferedBytes(upTo maximumLength: Int) -> Data {
        let count = min(maximumLength, bufferedBytes.count)
        let result = Data(bufferedBytes.prefix(count))
        bufferedBytes.removeFirst(count)
        scheduleReadIfNeeded()
        return result
    }
}

private final class VsockReadCancellation: @unchecked Sendable {
    private enum State {
        case pending
        case cancelled
        case delivered
    }

    private let lock = NSLock()
    private var state = State.pending

    func cancel() {
        lock.withLock {
            guard case .pending = state else { return }
            state = .cancelled
        }
    }

    func claimDelivery() -> Bool {
        lock.withLock {
            guard case .pending = state else { return false }
            state = .delivered
            return true
        }
    }
}

private final class VsockConnectionCloseHandle: @unchecked Sendable {
    enum DescriptorOwner {
        case virtualization(VZVirtioSocketConnection)
        case test(@Sendable () -> Void)
    }

    private let owner: DescriptorOwner
    private let queue: VMQueue
    private let closedSignal: VsockClosedSignal
    private let lock = NSLock()
    private var channel: DispatchIO?
    private var closeWasRequested = false
    private var channelDidClose = false

    init(
        owner: DescriptorOwner,
        queue: VMQueue,
        closedSignal: VsockClosedSignal
    ) {
        self.owner = owner
        self.queue = queue
        self.closedSignal = closedSignal
    }

    var isCloseRequested: Bool {
        lock.withLock { closeWasRequested }
    }

    func attach(_ channel: DispatchIO) {
        lock.withLock {
            self.channel = channel
        }
    }

    func close() {
        let channel = lock.withLock { () -> DispatchIO? in
            guard !closeWasRequested else { return nil }
            closeWasRequested = true
            return self.channel
        }
        channel?.close(flags: .stop)
    }

    func dispatchIOClosed() {
        let shouldReleaseOwner = lock.withLock { () -> Bool in
            guard !channelDidClose else { return false }
            channelDidClose = true
            channel = nil
            return true
        }
        guard shouldReleaseOwner else { return }

        queue.dispatchQueue.async {
            switch self.owner {
            case .virtualization(let connection):
                connection.close()
            case .test(let onClose):
                onClose()
            }
            self.closedSignal.signal()
        }
    }
}

private final class VsockClosedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = lock.withLock {
                guard !isSignaled else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func signal() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isSignaled else { return [] }
            isSignaled = true
            let continuations = waiters
            waiters.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}
