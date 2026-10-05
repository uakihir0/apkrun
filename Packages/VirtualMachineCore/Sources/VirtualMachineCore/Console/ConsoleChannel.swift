import Darwin
import Dispatch
import Foundation
import Virtualization

/// One independent bounded subscription to guest console output.
public struct ConsoleByteStream: Sendable {
    /// The bytes yielded to this subscriber.
    public let stream: AsyncStream<Data>

    private let dropCounter: ConsoleStreamDropCounter
    private let drainGate: ConsoleStreamDrainGate

    /// The number of bytes dropped from this subscriber's buffer.
    public var droppedByteCount: UInt64 {
        dropCounter.value
    }

    package var pendingByteCount: UInt64 {
        dropCounter.pendingValue
    }

    package var droppedAndPendingByteCount: UInt64 {
        dropCounter.droppedAndPendingValue
    }

    fileprivate init(
        stream: AsyncStream<Data>,
        dropCounter: ConsoleStreamDropCounter,
        drainGate: ConsoleStreamDrainGate
    ) {
        self.stream = stream
        self.dropCounter = dropCounter
        self.drainGate = drainGate
    }

    package func waitForDrain() async {
        await drainGate.waitForDrain()
    }

    package func acknowledgeDrainBarrier() {
        drainGate.acknowledgeBarrier()
    }

    package func acknowledgeConsumedBytes(_ count: Int) {
        guard count > 0 else { return }
        dropCounter.acknowledge(UInt64(count))
        drainGate.acknowledgeDataChunk()
    }

    package func acknowledgeStreamEnd() {
        drainGate.acknowledgeStreamEnd()
    }
}

private final class ConsoleStreamDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var droppedBytes: UInt64 = 0
    private var pendingBytes: UInt64 = 0

    var value: UInt64 {
        lock.withLock { droppedBytes }
    }

    var pendingValue: UInt64 {
        lock.withLock { pendingBytes }
    }

    var droppedAndPendingValue: UInt64 {
        lock.withLock { droppedBytes &+ pendingBytes }
    }

    func recordEnqueued(_ count: UInt64) {
        lock.withLock {
            pendingBytes &+= count
        }
    }

    func acknowledge(_ count: UInt64) {
        lock.withLock {
            pendingBytes = pendingBytes >= count ? pendingBytes - count : 0
        }
    }

    func recordDropped(_ count: UInt64, wasPending: Bool = false) {
        lock.withLock {
            droppedBytes &+= count
            if wasPending {
                pendingBytes = pendingBytes >= count ? pendingBytes - count : 0
            }
        }
    }
}

private final class ConsoleStreamDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private let producerLock: NSRecursiveLock
    private let continuation: AsyncStream<Data>.Continuation
    private let dropCounter: ConsoleStreamDropCounter
    private let recordChannelDrop: @Sendable (UInt64) -> Void
    private let drainQueue: DispatchQueue
    private let drainBeforeBarrier: @Sendable () -> Void
    private let reservedDataCapacity: Int?
    private var bufferedDataChunks = 0
    private var barrierIsQueued = false
    private var barrierYieldWasAccepted = false
    private var barrierConsumerAcknowledged = false
    private var enqueueTask: Task<Void, Never>?
    private var continuationIsTerminated = false
    private var consumerHasFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        continuation: AsyncStream<Data>.Continuation,
        producerLock: NSRecursiveLock,
        dropCounter: ConsoleStreamDropCounter,
        recordChannelDrop: @escaping @Sendable (UInt64) -> Void,
        drainQueue: DispatchQueue,
        drainBeforeBarrier: @escaping @Sendable () -> Void,
        reservedDataCapacity: Int? = nil
    ) {
        self.continuation = continuation
        self.producerLock = producerLock
        self.dropCounter = dropCounter
        self.recordChannelDrop = recordChannelDrop
        self.drainQueue = drainQueue
        self.drainBeforeBarrier = drainBeforeBarrier
        self.reservedDataCapacity = reservedDataCapacity
    }

    func reserveDataChunk() -> Bool {
        lock.withLock {
            guard let reservedDataCapacity else { return true }
            guard bufferedDataChunks < reservedDataCapacity else { return false }
            bufferedDataChunks += 1
            return true
        }
    }

    func releaseDataChunk() {
        lock.withLock {
            guard reservedDataCapacity != nil else { return }
            precondition(bufferedDataChunks > 0)
            bufferedDataChunks -= 1
        }
    }

    func acknowledgeDataChunk() {
        releaseDataChunk()
    }

    func waitForDrain() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if consumerHasFinished {
                lock.unlock()
                waiter.resume()
                return
            }
            if waiters.isEmpty, enqueueTask == nil {
                waiters.append(waiter)
            } else {
                pendingWaiters.append(waiter)
            }
            if !continuationIsTerminated, enqueueTask == nil, !waiters.isEmpty {
                enqueueTask = Task {
                    await self.enqueueBarrierUntilAccepted()
                }
            }
            lock.unlock()
        }
    }

    func acknowledgeStreamEnd() {
        let readyWaiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            continuationIsTerminated = true
            consumerHasFinished = true
            bufferedDataChunks = 0
            barrierIsQueued = false
            barrierYieldWasAccepted = false
            barrierConsumerAcknowledged = false
            enqueueTask = nil
            let readyWaiters = waiters + pendingWaiters
            waiters.removeAll()
            pendingWaiters.removeAll()
            return readyWaiters
        }
        for waiter in readyWaiters {
            waiter.resume()
        }
    }

    func acknowledgeBarrier() {
        let readyWaiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard barrierIsQueued else { return [] }
            barrierConsumerAcknowledged = true
            return takeReadyBarrierWaiters()
        }
        for waiter in readyWaiters {
            waiter.resume()
        }
    }

    private func enqueueBarrierUntilAccepted() async {
        var shouldDrainBeforeBarrier = true
        while !Task.isCancelled {
            let shouldAttempt = lock.withLock {
                guard !barrierIsQueued, !waiters.isEmpty else { return false }
                barrierIsQueued = true
                barrierYieldWasAccepted = false
                barrierConsumerAcknowledged = false
                return true
            }
            guard shouldAttempt else { return }

            let result = await yieldBarrier(drainingGuestOutput: shouldDrainBeforeBarrier)
            switch result {
            case .enqueued:
                completeBarrierYield()
                return
            case .dropped(let droppedChunk):
                if droppedChunk.isEmpty {
                    shouldDrainBeforeBarrier = false
                    lock.withLock {
                        barrierIsQueued = false
                        barrierYieldWasAccepted = false
                        barrierConsumerAcknowledged = false
                    }
                } else {
                    let count = UInt64(droppedChunk.count)
                    dropCounter.recordDropped(count, wasPending: true)
                    recordChannelDrop(count)
                    completeBarrierYield()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    clearPendingBarrierEnqueuer()
                    return
                }
            case .terminated:
                lock.withLock {
                    continuationIsTerminated = true
                    barrierIsQueued = false
                    barrierYieldWasAccepted = false
                    barrierConsumerAcknowledged = false
                    enqueueTask = nil
                }
                return
            @unknown default:
                lock.withLock {
                    continuationIsTerminated = true
                    barrierIsQueued = false
                    barrierYieldWasAccepted = false
                    barrierConsumerAcknowledged = false
                    enqueueTask = nil
                }
                return
            }
        }
        clearPendingBarrierEnqueuer()
    }

    private func yieldBarrier(
        drainingGuestOutput: Bool
    ) async -> AsyncStream<Data>.Continuation.YieldResult {
        return await withCheckedContinuation { resultContinuation in
            drainQueue.async {
                if drainingGuestOutput {
                    self.drainBeforeBarrier()
                }
                let result = self.producerLock.withLock {
                    self.continuation.yield(Data())
                }
                resultContinuation.resume(returning: result)
            }
        }
    }

    private func clearPendingBarrierEnqueuer() {
        lock.withLock {
            barrierIsQueued = false
            barrierYieldWasAccepted = false
            barrierConsumerAcknowledged = false
            enqueueTask = nil
        }
    }

    private func completeBarrierYield() {
        let readyWaiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            barrierYieldWasAccepted = true
            return takeReadyBarrierWaiters()
        }
        for waiter in readyWaiters {
            waiter.resume()
        }
    }

    /// The caller holds `lock`.
    private func takeReadyBarrierWaiters() -> [CheckedContinuation<Void, Never>] {
        guard barrierYieldWasAccepted, barrierConsumerAcknowledged else { return [] }
        barrierIsQueued = false
        barrierYieldWasAccepted = false
        barrierConsumerAcknowledged = false
        let readyWaiters = waiters
        waiters.removeAll()
        if pendingWaiters.isEmpty {
            enqueueTask = nil
        } else {
            waiters = pendingWaiters
            pendingWaiters.removeAll()
            enqueueTask = Task {
                await self.enqueueBarrierUntilAccepted()
            }
        }
        return readyWaiters
    }
}

// UNCHECKED-SENDABLE: closeLock guards attachment, input-write admission, drop-count, and close state; inputWriteLock serializes pipe writes, and outputReadQueue serializes dispatch-source reads.
/// A serial console port with an asynchronous guest-to-host byte stream.
public final class ConsoleChannel: @unchecked Sendable {
    /// The chunk retained when a subscriber's bounded buffer is full.
    public enum StreamBufferingPolicy: Sendable {
        /// Keep queued output and drop newly received chunks.
        case preserveOldest

        /// Drop queued output and keep newly received chunks.
        case preserveNewest
    }

    private struct Subscriber: Sendable {
        let continuation: AsyncStream<Data>.Continuation
        let dropCounter: ConsoleStreamDropCounter
        let drainGate: ConsoleStreamDrainGate
    }

    private let closeLock = NSCondition()
    private let inputWriteLock = NSLock()
    private let outputProducerLock = NSRecursiveLock()
    private let vmQueue: VMQueue
    private let guestOutputReadHandle: FileHandle
    private let guestOutputWriteHandle: FileHandle
    private let hostInputReadHandle: FileHandle
    private let hostInputWriteHandle: FileHandle
    private let outputReadQueue: DispatchQueue
    private let outputReadSource: DispatchSourceRead
    private var outputReaderHasFinished = false
    private var isClosed = false
    private var attachmentIsActive = false
    private var isDetached = false
    private var activeInputWriterCount = 0
    private var droppedBytes: UInt64 = 0
    private var hasStreamSubscriber = false
    private var initialChunks: [Data] = []
    private var subscribers: [UUID: Subscriber] = [:]
    private var reachedEOF = false

    private static let streamChunkSize = 64 * 1_024
    private static let maximumReadBytesPerEvent = 1 * 1_024 * 1_024
    private static let maximumFailureDrainBytes = 4 * 1_024 * 1_024
    private static let maximumFailureDrainDuration: Duration = .milliseconds(50)
    private let streamBufferCapacity: Int
    private var outputBytesDelivered: UInt64 = 0

    /// The host-side role of this guest serial port.
    public let role: ConsoleRole

    /// The total number of bytes dropped across all subscribers.
    public var droppedByteCount: UInt64 {
        closeLock.withLock { droppedBytes }
    }

    package var bufferedPrefixByteCount: Int {
        closeLock.withLock {
            initialChunks.reduce(into: 0) { count, chunk in
                count += chunk.count
            }
        }
    }

    /// Creates the paired pipes and starts reading guest output.
    package init(
        role: ConsoleRole,
        vmQueue: VMQueue,
        streamBufferCapacity: Int = 64
    ) {
        precondition(streamBufferCapacity > 0)
        self.role = role
        self.vmQueue = vmQueue
        self.streamBufferCapacity = streamBufferCapacity

        let guestOutput = Pipe()
        let hostInput = Pipe()
        guestOutputReadHandle = guestOutput.fileHandleForReading
        guestOutputWriteHandle = guestOutput.fileHandleForWriting
        hostInputReadHandle = hostInput.fileHandleForReading
        hostInputWriteHandle = hostInput.fileHandleForWriting
        precondition(
            fcntl(hostInputWriteHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
            "The console input pipe must suppress SIGPIPE."
        )

        let readQueue = DispatchQueue(
            label: "io.apkrun.vm.console.read",
            qos: .utility
        )
        outputReadQueue = readQueue
        let guestOutputReadHandle = guestOutputReadHandle
        let outputReadDescriptor = guestOutputReadHandle.fileDescriptor
        let outputReadFlags = fcntl(outputReadDescriptor, F_GETFL)
        precondition(
            outputReadFlags >= 0
                && fcntl(outputReadDescriptor, F_SETFL, outputReadFlags | O_NONBLOCK) == 0,
            "The console output pipe must use nonblocking reads."
        )
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: outputReadDescriptor,
            queue: readQueue
        )
        outputReadSource = readSource
        readSource.setEventHandler { [weak self] in
            _ = self?.receiveAvailableGuestOutput(
                maximumBytes: Self.maximumReadBytesPerEvent
            )
        }
        readSource.setCancelHandler {
            try? guestOutputReadHandle.close()
        }
        readSource.resume()
    }

    /// Drains a bounded snapshot of guest output on the serial read queue.
    package func drainPendingGuestOutput() async {
        await withCheckedContinuation { continuation in
            outputReadQueue.async { [weak self] in
                self?.drainGuestOutputForFailure()
                continuation.resume()
            }
        }
    }

    /// Drains guest output and queues the consumer barrier in one read-queue turn.
    package func drainPendingGuestOutputAndWait(for byteStream: ConsoleByteStream) async {
        await byteStream.waitForDrain()
    }

    /// Creates an independent bounded stream for one console consumer.
    ///
    /// Consumers that need the same output must each request a stream. Streams
    /// created before the first consumer starts receive the buffered prefix.
    /// Each stream reports its own dropped-byte count.
    public func makeByteStream(
        bufferingPolicy: StreamBufferingPolicy = .preserveOldest
    ) -> ConsoleByteStream {
        makeByteStream(bufferingPolicy: bufferingPolicy, reservesDrainSlot: false)
    }

    /// Creates a log stream with one buffer slot reserved for its drain marker.
    package func makeLogByteStream() -> ConsoleByteStream {
        makeByteStream(bufferingPolicy: .preserveOldest, reservesDrainSlot: true)
    }

    private func makeByteStream(
        bufferingPolicy: StreamBufferingPolicy,
        reservesDrainSlot: Bool
    ) -> ConsoleByteStream {
        let identifier = UUID()
        let dropCounter = ConsoleStreamDropCounter()
        if case .silent = role {
            let stream = AsyncStream<Data>.makeStream()
            stream.continuation.finish()
            let drainGate = ConsoleStreamDrainGate(
                continuation: stream.continuation,
                producerLock: outputProducerLock,
                dropCounter: dropCounter,
                recordChannelDrop: { [weak self] count in
                    self?.recordDroppedBytes(count)
                },
                drainQueue: outputReadQueue,
                drainBeforeBarrier: { [weak self] in
                    self?.drainGuestOutputForFailure()
                },
                reservedDataCapacity: reservesDrainSlot ? streamBufferCapacity : nil
            )
            drainGate.acknowledgeStreamEnd()
            return ConsoleByteStream(
                stream: stream.stream,
                dropCounter: dropCounter,
                drainGate: drainGate
            )
        }
        let streamBufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy
        let bufferCapacity = streamBufferCapacity + (reservesDrainSlot ? 1 : 0)
        switch bufferingPolicy {
        case .preserveOldest:
            streamBufferingPolicy = .bufferingOldest(bufferCapacity)
        case .preserveNewest:
            precondition(!reservesDrainSlot)
            streamBufferingPolicy = .bufferingNewest(bufferCapacity)
        }
        let stream = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: streamBufferingPolicy
        )
        let drainGate = ConsoleStreamDrainGate(
            continuation: stream.continuation,
            producerLock: outputProducerLock,
            dropCounter: dropCounter,
            recordChannelDrop: { [weak self] count in
                self?.recordDroppedBytes(count)
            },
            drainQueue: outputReadQueue,
            drainBeforeBarrier: { [weak self] in
                self?.drainGuestOutputForFailure()
            },
            reservedDataCapacity: reservesDrainSlot ? streamBufferCapacity : nil
        )
        stream.continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(identifier)
        }

        closeLock.lock()
        hasStreamSubscriber = true
        for chunk in initialChunks {
            guard drainGate.reserveDataChunk() else {
                recordDroppedSubscriberBytes(UInt64(chunk.count), for: dropCounter)
                continue
            }
            dropCounter.recordEnqueued(UInt64(chunk.count))
            switch stream.continuation.yield(chunk) {
            case .enqueued:
                break
            case .dropped(let droppedChunk):
                drainGate.releaseDataChunk()
                let count = UInt64(droppedChunk.count)
                recordDroppedSubscriberBytes(count, for: dropCounter, wasPending: true)
            case .terminated:
                drainGate.releaseDataChunk()
                recordDroppedSubscriberBytes(
                    UInt64(chunk.count),
                    for: dropCounter,
                    wasPending: true
                )
            @unknown default:
                drainGate.releaseDataChunk()
                recordDroppedSubscriberBytes(
                    UInt64(chunk.count),
                    for: dropCounter,
                    wasPending: true
                )
            }
        }
        if reachedEOF {
            closeLock.unlock()
            stream.continuation.finish()
        } else {
            subscribers[identifier] = Subscriber(
                continuation: stream.continuation,
                dropCounter: dropCounter,
                drainGate: drainGate
            )
            closeLock.unlock()
        }
        return ConsoleByteStream(
            stream: stream.stream,
            dropCounter: dropCounter,
            drainGate: drainGate
        )
    }

    /// Sends bytes from the host to a guest-readable console port.
    ///
    /// `.log` and `.silent` ports are intentionally receive-only. The system
    /// console is writable for the development console, and service ports are
    /// writable by their host-side service.
    public func writeHostInput(_ data: Data) throws(ConsoleChannelWriteFailure) {
        guard role.permitsHostInput else {
            throw .hostInputUnavailable
        }
        guard !data.isEmpty else { return }

        closeLock.lock()
        guard !isClosed, !isDetached else {
            closeLock.unlock()
            throw ConsoleChannelWriteFailure.closed
        }
        activeInputWriterCount += 1
        closeLock.unlock()

        defer {
            closeLock.lock()
            activeInputWriterCount -= 1
            closeLock.broadcast()
            closeLock.unlock()
        }

        do {
            inputWriteLock.lock()
            defer { inputWriteLock.unlock() }
            try hostInputWriteHandle.write(contentsOf: data)
        } catch let failure as ConsoleChannelWriteFailure {
            throw failure
        } catch {
            throw .writeFailed(code: Int32((error as NSError).code))
        }
    }

    /// Creates the VZ attachment on the VM's required serial queue.
    package func makeAttachment() throws(AttachmentFailure) -> VZSerialPortAttachment {
        dispatchPrecondition(condition: .onQueue(vmQueue.dispatchQueue))
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { throw AttachmentFailure.closed }
        guard !isDetached else { throw AttachmentFailure.detached }
        guard !attachmentIsActive else { throw AttachmentFailure.alreadyAttached }
        let attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: hostInputReadHandle,
            fileHandleForWriting: guestOutputWriteHandle
        )
        attachmentIsActive = true
        return attachment
    }

    /// Marks the attachment detached after the VM releases its VZ objects.
    package func detachAttachment() {
        dispatchPrecondition(condition: .onQueue(vmQueue.dispatchQueue))
        closeLock.lock()
        guard attachmentIsActive else {
            closeLock.unlock()
            return
        }
        isDetached = true
        closeLock.unlock()

        try? hostInputReadHandle.close()

        closeLock.lock()
        while activeInputWriterCount > 0 {
            closeLock.wait()
        }
        attachmentIsActive = false
        closeOutputAndInputWriterEndpoints()
        closeLock.unlock()
    }

    /// Closes a detached channel and lets the read source drain through EOF.
    package func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        precondition(!attachmentIsActive, "Release the VM driver before closing its console.")
        isClosed = true
        isDetached = true
        closeLock.unlock()

        try? hostInputReadHandle.close()

        closeLock.lock()
        while activeInputWriterCount > 0 {
            closeLock.wait()
        }
        closeOutputAndInputWriterEndpoints()
        closeLock.unlock()
    }

    private func closeOutputAndInputWriterEndpoints() {
        try? guestOutputWriteHandle.close()
        try? hostInputWriteHandle.close()
    }

    /// Returns true when a read budget was reached and more data may be waiting.
    private func receiveAvailableGuestOutput(
        maximumBytes: Int?,
        stoppingAt deadline: ContinuousClock.Instant? = nil
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(outputReadQueue))
        guard !outputReaderHasFinished else { return false }

        let clock = ContinuousClock()
        let descriptor = guestOutputReadHandle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: Self.streamChunkSize)
        var bytesDelivered = 0
        while true {
            if let deadline, clock.now >= deadline {
                return true
            }
            if let maximumBytes, bytesDelivered >= maximumBytes {
                return true
            }
            let readCount =
                maximumBytes.map { min(buffer.count, $0 - bytesDelivered) } ?? buffer.count
            let readResult = buffer.withUnsafeMutableBytes { rawBuffer -> Int? in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                return Darwin.read(descriptor, baseAddress, readCount)
            }
            guard let bytesRead = readResult else {
                finishOutputReader()
                return false
            }
            if bytesRead > 0 {
                receiveGuestOutput(Data(buffer.prefix(bytesRead)))
                bytesDelivered += bytesRead
                outputBytesDelivered &+= UInt64(bytesRead)
                continue
            }
            if bytesRead == 0 {
                finishOutputReader()
                return false
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            }
            finishOutputReader()
            return false
        }
    }

    private func drainGuestOutputForFailure() {
        dispatchPrecondition(condition: .onQueue(outputReadQueue))
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: Self.maximumFailureDrainDuration)
        var remainingBytes = Self.maximumFailureDrainBytes

        while remainingBytes > 0, clock.now < deadline {
            let bytesBeforeRead = outputBytesDelivered
            let readLimit = min(remainingBytes, Self.maximumReadBytesPerEvent)
            let mayHaveMore = receiveAvailableGuestOutput(
                maximumBytes: readLimit,
                stoppingAt: deadline
            )
            let bytesRead = Int(outputBytesDelivered - bytesBeforeRead)
            guard bytesRead > 0 else { return }
            remainingBytes -= bytesRead
            guard mayHaveMore else { return }
        }
    }

    private func finishOutputReader() {
        dispatchPrecondition(condition: .onQueue(outputReadQueue))
        guard !outputReaderHasFinished else { return }
        outputReaderHasFinished = true
        finishStreams()
        outputReadSource.cancel()
    }

    private func receiveGuestOutput(_ data: Data) {
        outputProducerLock.withLock {
            receiveGuestOutputInOrder(data)
        }
    }

    private func receiveGuestOutputInOrder(_ data: Data) {
        if case .silent = role {
            closeLock.withLock {
                droppedBytes &+= UInt64(data.count)
            }
            return
        }
        var start = data.startIndex
        while start < data.endIndex {
            let remaining = data.distance(from: start, to: data.endIndex)
            let length = min(remaining, Self.streamChunkSize)
            let end = data.index(start, offsetBy: length)
            let chunk = Data(data[start..<end])
            let destinations = closeLock.withLock { () -> [Subscriber] in
                guard hasStreamSubscriber else {
                    if initialChunks.count < streamBufferCapacity {
                        initialChunks.append(chunk)
                    } else {
                        droppedBytes &+= UInt64(chunk.count)
                    }
                    return []
                }
                return Array(subscribers.values)
            }
            for subscriber in destinations {
                guard subscriber.drainGate.reserveDataChunk() else {
                    recordDroppedSubscriberBytes(
                        UInt64(chunk.count),
                        for: subscriber.dropCounter
                    )
                    continue
                }
                subscriber.dropCounter.recordEnqueued(UInt64(chunk.count))
                switch subscriber.continuation.yield(chunk) {
                case .enqueued:
                    break
                case .dropped(let droppedChunk):
                    subscriber.drainGate.releaseDataChunk()
                    let count = UInt64(droppedChunk.count)
                    recordDroppedSubscriberBytes(
                        count,
                        for: subscriber.dropCounter,
                        wasPending: true
                    )
                case .terminated:
                    subscriber.drainGate.releaseDataChunk()
                    recordDroppedSubscriberBytes(
                        UInt64(chunk.count),
                        for: subscriber.dropCounter,
                        wasPending: true
                    )
                @unknown default:
                    subscriber.drainGate.releaseDataChunk()
                    recordDroppedSubscriberBytes(
                        UInt64(chunk.count),
                        for: subscriber.dropCounter,
                        wasPending: true
                    )
                }
            }
            start = end
        }
    }

    private func finishStreams() {
        let continuations = closeLock.withLock { () -> [AsyncStream<Data>.Continuation] in
            guard !reachedEOF else { return [] }
            reachedEOF = true
            let continuations = subscribers.values.map(\.continuation)
            subscribers.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func recordDroppedBytes(_ count: UInt64) {
        closeLock.withLock {
            droppedBytes &+= count
        }
    }

    private func recordDroppedSubscriberBytes(
        _ count: UInt64,
        for counter: ConsoleStreamDropCounter,
        wasPending: Bool = false
    ) {
        counter.recordDropped(count, wasPending: wasPending)
        closeLock.withLock {
            droppedBytes &+= count
        }
    }

    private func removeSubscriber(_ identifier: UUID) {
        _ = closeLock.withLock {
            subscribers.removeValue(forKey: identifier)
        }
    }

    package enum AttachmentFailure: Error, Equatable, Sendable {
        case closed
        case detached
        case alreadyAttached
    }
}

/// A failure to send host input through a serial console channel.
public enum ConsoleChannelWriteFailure: Error, Equatable, Sendable {
    /// The assigned role never accepts host input.
    case hostInputUnavailable

    /// The virtual machine released or detached the console pipes.
    case closed

    /// The host input pipe rejected the write.
    case writeFailed(code: Int32)
}

extension ConsoleRole {
    fileprivate var permitsHostInput: Bool {
        switch self {
        case .systemConsole, .service:
            true
        case .log, .silent:
            false
        }
    }
}
