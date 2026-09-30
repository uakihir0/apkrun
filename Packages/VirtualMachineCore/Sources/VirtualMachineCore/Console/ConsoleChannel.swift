import Dispatch
import Foundation
import Virtualization

/// One independent bounded subscription to guest console output.
public struct ConsoleByteStream: Sendable {
    /// The bytes yielded to this subscriber.
    public let stream: AsyncStream<Data>

    private let dropCounter: ConsoleStreamDropCounter

    /// The number of bytes dropped from this subscriber's buffer.
    public var droppedByteCount: UInt64 {
        dropCounter.value
    }

    fileprivate init(
        stream: AsyncStream<Data>,
        dropCounter: ConsoleStreamDropCounter
    ) {
        self.stream = stream
        self.dropCounter = dropCounter
    }
}

private final class ConsoleStreamDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var droppedBytes: UInt64 = 0

    var value: UInt64 {
        lock.withLock { droppedBytes }
    }

    func record(_ count: UInt64) {
        lock.withLock {
            droppedBytes &+= count
        }
    }
}

// UNCHECKED-SENDABLE: closeLock guards attachment, drop-count, and close state; DispatchIO serializes all pipe reads on its private queue.
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
    }

    private let closeLock = NSLock()
    private let vmQueue: VMQueue
    private let guestOutputReadHandle: FileHandle
    private let guestOutputWriteHandle: FileHandle
    private let hostInputReadHandle: FileHandle
    private let hostInputWriteHandle: FileHandle
    private let readChannel: DispatchIO
    private var isClosed = false
    private var attachmentIsActive = false
    private var isDetached = false
    private var droppedBytes: UInt64 = 0
    private var hasStreamSubscriber = false
    private var initialChunks: [Data] = []
    private var subscribers: [UUID: Subscriber] = [:]
    private var reachedEOF = false

    private static let streamChunkSize = 64 * 1_024
    private let streamBufferCapacity: Int

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

        let readQueue = DispatchQueue(
            label: "io.apkrun.vm.console.read",
            qos: .utility
        )
        let guestOutputReadHandle = guestOutputReadHandle
        readChannel = DispatchIO(
            type: .stream,
            fileDescriptor: guestOutputReadHandle.fileDescriptor,
            queue: readQueue
        ) { _ in
            try? guestOutputReadHandle.close()
        }
        readChannel.setLimit(lowWater: 1)
        readChannel.setLimit(highWater: Self.streamChunkSize)
        readChannel.read(
            offset: 0,
            length: Int.max,
            queue: readQueue
        ) { [weak self] done, data, error in
            if let data, !data.isEmpty {
                self?.receiveGuestOutput(Data(data))
            }
            if error != 0 || done {
                self?.finishStreams()
                self?.readChannel.close(flags: .stop)
            }
        }
    }

    /// Creates an independent bounded stream for one console consumer.
    ///
    /// Consumers that need the same output must each request a stream. Streams
    /// created before the first consumer starts receive the buffered prefix.
    /// Each stream reports its own dropped-byte count.
    public func makeByteStream(
        bufferingPolicy: StreamBufferingPolicy = .preserveOldest
    ) -> ConsoleByteStream {
        let identifier = UUID()
        let dropCounter = ConsoleStreamDropCounter()
        let streamBufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy
        switch bufferingPolicy {
        case .preserveOldest:
            streamBufferingPolicy = .bufferingOldest(streamBufferCapacity)
        case .preserveNewest:
            streamBufferingPolicy = .bufferingNewest(streamBufferCapacity)
        }
        let stream = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: streamBufferingPolicy
        )
        stream.continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(identifier)
        }

        closeLock.lock()
        hasStreamSubscriber = true
        for chunk in initialChunks {
            if case .dropped(let droppedChunk) = stream.continuation.yield(chunk) {
                let count = UInt64(droppedChunk.count)
                dropCounter.record(count)
                droppedBytes &+= count
            }
        }
        if reachedEOF {
            closeLock.unlock()
            stream.continuation.finish()
        } else {
            subscribers[identifier] = Subscriber(
                continuation: stream.continuation,
                dropCounter: dropCounter
            )
            closeLock.unlock()
        }
        return ConsoleByteStream(stream: stream.stream, dropCounter: dropCounter)
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
        closeLock.withLock {
            guard attachmentIsActive else { return }
            attachmentIsActive = false
            isDetached = true
            closePipeEndpoints()
        }
    }

    /// Closes a detached channel and lets DispatchIO drain through EOF.
    package func close() {
        closeLock.withLock {
            guard !isClosed else { return }
            precondition(!attachmentIsActive, "Release the VM driver before closing its console.")
            isClosed = true
            isDetached = true
            closePipeEndpoints()
        }
    }

    private func closePipeEndpoints() {
        try? guestOutputWriteHandle.close()
        try? hostInputReadHandle.close()
        try? hostInputWriteHandle.close()
    }

    private func receiveGuestOutput(_ data: Data) {
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
                if case .dropped(let droppedChunk) = subscriber.continuation.yield(chunk) {
                    let count = UInt64(droppedChunk.count)
                    subscriber.dropCounter.record(count)
                    closeLock.withLock {
                        droppedBytes &+= count
                    }
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
