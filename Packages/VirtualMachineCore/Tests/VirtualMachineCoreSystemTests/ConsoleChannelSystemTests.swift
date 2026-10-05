import Darwin
import DiagnosticsCore
import Foundation
import Testing
import VirtualMachineCore
import Virtualization

private actor DrainWaiterCompletionCounter {
    private(set) var count = 0

    func recordCompletion() {
        count += 1
    }
}

private final class ConsoleOutputTestWriter: @unchecked Sendable {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }
}

@Test(.timeLimit(.minutes(1)))
func consoleChannelWritesSystemAndServiceInputButRejectsLogAndSilentRoles() throws {
    let cases: [(ConsoleRole, Data)] = [
        (.systemConsole, Data("interactive input\n".utf8)),
        (.service(name: "test"), Data("service input\n".utf8)),
    ]

    for (index, testCase) in cases.enumerated() {
        let queue = VMQueue(label: "io.apkrun.vm.console.write.\(index)")
        let channel = ConsoleChannel(role: testCase.0, vmQueue: queue)
        let attachment = try #require(
            try queue.dispatchQueue.sync {
                try channel.makeAttachment() as? VZFileHandleSerialPortAttachment
            }
        )

        try channel.writeHostInput(testCase.1)
        let received = try attachment.fileHandleForReading?.read(upToCount: testCase.1.count)
        #expect(received == testCase.1)

        queue.dispatchQueue.sync {
            channel.detachAttachment()
        }
        channel.close()
    }

    for role in [ConsoleRole.log(name: "logcat"), .silent(name: "discard")] {
        let queue = VMQueue(label: "io.apkrun.vm.console.read-only.\(String(describing: role))")
        let channel = ConsoleChannel(role: role, vmQueue: queue)
        let attachment = try #require(
            try queue.dispatchQueue.sync {
                try channel.makeAttachment() as? VZFileHandleSerialPortAttachment
            }
        )

        #expect(throws: ConsoleChannelWriteFailure.hostInputUnavailable) {
            try channel.writeHostInput(Data("must not be sent\n".utf8))
        }
        #expect(guestInputPipeIsOpenAndEmpty(attachment))

        queue.dispatchQueue.sync {
            channel.detachAttachment()
        }
        channel.close()
    }
}

@Test(.timeLimit(.minutes(1)))
func closingConsoleChannelUnblocksAWaitingHostInputWriter() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.blocked-input-test")
    let channel = ConsoleChannel(role: .systemConsole, vmQueue: queue)
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let inputDescriptor = try #require(attachment.fileHandleForReading?.fileDescriptor)
    let started = AsyncStream.makeStream(of: Bool.self)
    let writeTask = Task.detached {
        started.continuation.yield(true)
        do {
            try channel.writeHostInput(Data(repeating: 0x41, count: 8 * 1_024 * 1_024))
            return false
        } catch {
            return true
        }
    }

    var startedIterator = started.stream.makeAsyncIterator()
    #expect(await startedIterator.next() == true)
    let inputBecameReadable = Task.detached {
        var descriptor = pollfd(
            fd: inputDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        return Darwin.poll(&descriptor, 1, 5_000) > 0
    }
    #expect(await inputBecameReadable.value)
    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()

    #expect(await writeTask.value)
}

@Test(.timeLimit(.minutes(1)))
func consoleStreamDrainWaitsForTheConsumerToFinishPriorBytes() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.drain-barrier-test")
    let channel = ConsoleChannel(
        role: .systemConsole,
        vmQueue: queue,
        streamBufferCapacity: 1
    )
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let byteStream = channel.makeByteStream()
    let firstChunk = AsyncStream.makeStream(of: Bool.self)
    let consumerTask = Task {
        var consumed = Data()
        for await chunk in byteStream.stream {
            if chunk.isEmpty {
                byteStream.acknowledgeDrainBarrier()
                return consumed
            }
            consumed.append(chunk)
            firstChunk.continuation.yield(true)
            try? await Task.sleep(for: .milliseconds(100))
        }
        return consumed
    }
    let output = Data(repeating: 0x42, count: 16 * 1_024)
    try attachment.fileHandleForWriting?.write(contentsOf: output)
    var firstChunkIterator = firstChunk.stream.makeAsyncIterator()
    #expect(await firstChunkIterator.next() == true)

    let clock = ContinuousClock()
    let start = clock.now
    await byteStream.waitForDrain()
    #expect(start.duration(to: clock.now) >= .milliseconds(50))
    #expect(await consumerTask.value == output)

    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()
}

@Test(.timeLimit(.minutes(1)))
func consoleStreamTracksBufferedBytesUntilConsumerAcknowledgesThem() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.pending-byte-count-test")
    let channel = ConsoleChannel(
        role: .systemConsole,
        vmQueue: queue,
        streamBufferCapacity: 2
    )
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let byteStream = channel.makeByteStream()
    let output = Data("buffered console output".utf8)
    try attachment.fileHandleForWriting?.write(contentsOf: output)
    await channel.drainPendingGuestOutput()

    #expect(byteStream.pendingByteCount == UInt64(output.count))
    #expect(byteStream.droppedAndPendingByteCount == UInt64(output.count))
    var iterator = byteStream.stream.makeAsyncIterator()
    var consumed = Data()
    while consumed.count < output.count, let chunk = await iterator.next() {
        consumed.append(chunk)
    }
    #expect(consumed == output)
    #expect(byteStream.pendingByteCount == UInt64(output.count))

    byteStream.acknowledgeConsumedBytes(consumed.count)
    #expect(byteStream.pendingByteCount == 0)
    #expect(byteStream.droppedAndPendingByteCount == 0)

    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()
}

@Test(.timeLimit(.minutes(1)))
func consoleDrainFenceDeliversBytesAlreadyWaitingInThePipe() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.pending-output-test")
    let channel = ConsoleChannel(role: .systemConsole, vmQueue: queue)
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let byteStream = channel.makeByteStream()
    let consumerTask = Task {
        var consumed = Data()
        for await chunk in byteStream.stream {
            if chunk.isEmpty {
                byteStream.acknowledgeDrainBarrier()
                break
            } else {
                consumed.append(chunk)
            }
        }
        byteStream.acknowledgeStreamEnd()
        return consumed
    }
    let output = Data(repeating: 0x5A, count: 2 * 1_024 * 1_024 + 17)
    try attachment.fileHandleForWriting?.write(contentsOf: output)

    await channel.drainPendingGuestOutputAndWait(for: byteStream)
    #expect(await consumerTask.value == output)

    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()
}

@Test(.timeLimit(.minutes(1)))
func consoleFailureDrainReturnsWhileGuestKeepsWriting() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.continuous-output-test")
    let channel = ConsoleChannel(role: .systemConsole, vmQueue: queue)
    let created: (VZFileHandleSerialPortAttachment, ConsoleOutputTestWriter) =
        try queue.dispatchQueue.sync {
            guard
                let attachment = try channel.makeAttachment()
                    as? VZFileHandleSerialPortAttachment,
                let outputHandle = attachment.fileHandleForWriting
            else {
                throw ConsoleChannelWriteFailure.closed
            }
            return (
                attachment,
                ConsoleOutputTestWriter(handle: outputHandle)
            )
        }
    let writer = created.1
    let output = Data(repeating: 0x53, count: 64 * 1_024)
    let writerTask = Task.detached {
        while !Task.isCancelled {
            do {
                try writer.write(output)
            } catch {
                return
            }
        }
    }
    try await Task.sleep(for: .milliseconds(20))

    let clock = ContinuousClock()
    let start = clock.now
    await channel.drainPendingGuestOutput()
    #expect(start.duration(to: clock.now) < .seconds(1))
    #expect(!writerTask.isCancelled)

    writerTask.cancel()
    await writerTask.value
    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()
    withExtendedLifetime(created.0) {}
}

@Test(.timeLimit(.minutes(1)))
func newestConsoleDrainBarrierCountsTheQueuedBytesItDisplaces() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.newest-drain-test")
    let channel = ConsoleChannel(
        role: .systemConsole,
        vmQueue: queue,
        streamBufferCapacity: 1
    )
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let byteStream = channel.makeByteStream(bufferingPolicy: .preserveNewest)
    let output = Data(repeating: 0x5A, count: 8 * 1_024)
    try attachment.fileHandleForWriting?.write(contentsOf: output)
    await channel.drainPendingGuestOutput()

    let drainTask = Task {
        await byteStream.waitForDrain()
    }
    for _ in 0..<100 where byteStream.droppedByteCount == 0 {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(byteStream.droppedByteCount == UInt64(output.count))
    #expect(byteStream.pendingByteCount == 0)
    #expect(byteStream.droppedAndPendingByteCount == UInt64(output.count))
    let consumerTask = Task {
        var consumed = Data()
        for await chunk in byteStream.stream {
            guard !chunk.isEmpty else {
                byteStream.acknowledgeDrainBarrier()
                break
            }
            consumed.append(chunk)
        }
        return consumed
    }
    #expect(await consumerTask.value.isEmpty)
    await drainTask.value
    #expect(byteStream.droppedByteCount == UInt64(output.count))
    #expect(channel.droppedByteCount == UInt64(output.count))

    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()
}

@Test(.timeLimit(.minutes(1)))
func logDrainMarkerUsesItsReservedSlotWhenTheDataBufferIsFull() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.reserved-barrier-test")
    let channel = ConsoleChannel(
        role: .systemConsole,
        vmQueue: queue,
        streamBufferCapacity: 1
    )
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let byteStream = channel.makeLogByteStream()
    let retainedOutput = Data(repeating: 0x41, count: 8 * 1_024)
    let droppedOutput = Data(repeating: 0x42, count: 8 * 1_024)
    try attachment.fileHandleForWriting?.write(contentsOf: retainedOutput)
    await channel.drainPendingGuestOutput()
    try attachment.fileHandleForWriting?.write(contentsOf: droppedOutput)
    await channel.drainPendingGuestOutput()

    let drainTask = Task {
        await byteStream.waitForDrain()
    }
    let consumerTask = Task {
        var consumed = Data()
        for await chunk in byteStream.stream {
            if chunk.isEmpty {
                byteStream.acknowledgeDrainBarrier()
                break
            }
            consumed.append(chunk)
            byteStream.acknowledgeConsumedBytes(chunk.count)
        }
        byteStream.acknowledgeStreamEnd()
        return consumed
    }

    #expect(await consumerTask.value == retainedOutput)
    await drainTask.value
    #expect(byteStream.droppedByteCount == UInt64(droppedOutput.count))
    #expect(channel.droppedByteCount == UInt64(droppedOutput.count))

    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()
}

@Test(.timeLimit(.minutes(1)))
func failureDrainUsesAFreshBarrierAfterAnEarlierWaiter() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.fresh-failure-drain-test")
    let channel = ConsoleChannel(
        role: .systemConsole,
        vmQueue: queue,
        streamBufferCapacity: 4
    )
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let byteStream = channel.makeLogByteStream()
    let firstBarrierDequeued = AsyncStream.makeStream(of: Bool.self)
    let releaseFirstBarrier = AsyncStream.makeStream(of: Bool.self)
    let consumerTask = Task {
        var consumed = Data()
        var barrierCount = 0
        for await chunk in byteStream.stream {
            if chunk.isEmpty {
                barrierCount += 1
                if barrierCount == 1 {
                    firstBarrierDequeued.continuation.yield(true)
                    var releaseIterator = releaseFirstBarrier.stream.makeAsyncIterator()
                    _ = await releaseIterator.next()
                }
                byteStream.acknowledgeDrainBarrier()
                if barrierCount == 2 {
                    break
                }
            } else {
                consumed.append(chunk)
                byteStream.acknowledgeConsumedBytes(chunk.count)
            }
        }
        byteStream.acknowledgeStreamEnd()
        return consumed
    }
    let firstOutput = Data(repeating: 0x31, count: 4 * 1_024)
    let secondOutput = Data(repeating: 0x32, count: 4 * 1_024)
    try attachment.fileHandleForWriting?.write(contentsOf: firstOutput)
    await channel.drainPendingGuestOutput()

    let earlierWaiter = Task {
        await byteStream.waitForDrain()
    }
    var firstBarrierIterator = firstBarrierDequeued.stream.makeAsyncIterator()
    #expect(await firstBarrierIterator.next() == true)

    try attachment.fileHandleForWriting?.write(contentsOf: secondOutput)
    await channel.drainPendingGuestOutput()
    let failureWaiter = Task {
        await channel.drainPendingGuestOutputAndWait(for: byteStream)
    }
    try await Task.sleep(for: .milliseconds(10))
    releaseFirstBarrier.continuation.yield(true)

    await earlierWaiter.value
    await failureWaiter.value
    #expect(await consumerTask.value == firstOutput + secondOutput)

    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()
}

@Test(.timeLimit(.minutes(1)))
func terminatedConsoleStreamKeepsEveryDrainWaiterUntilTheConsumerFinishes() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.terminated-drain-test")
    let channel = ConsoleChannel(role: .systemConsole, vmQueue: queue)
    let attachment: VZFileHandleSerialPortAttachment = try await withCheckedThrowingContinuation {
        continuation in
        queue.dispatchQueue.async {
            do {
                guard
                    let attachment = try channel.makeAttachment()
                        as? VZFileHandleSerialPortAttachment
                else {
                    throw ConsoleChannelWriteFailure.closed
                }
                continuation.resume(returning: attachment)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    let byteStream = channel.makeByteStream()
    let firstChunk = AsyncStream.makeStream(of: Bool.self)
    let releaseConsumer = AsyncStream.makeStream(of: Bool.self)
    let consumerTask = Task {
        var consumed = Data()
        var isFirstChunk = true
        for await chunk in byteStream.stream {
            consumed.append(chunk)
            if isFirstChunk {
                isFirstChunk = false
                firstChunk.continuation.yield(true)
                var releaseIterator = releaseConsumer.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
            }
        }
        byteStream.acknowledgeStreamEnd()
        return consumed
    }
    let output = Data(repeating: 0x42, count: 16 * 1_024)
    try attachment.fileHandleForWriting?.write(contentsOf: output)
    await withCheckedContinuation { continuation in
        queue.dispatchQueue.async {
            channel.detachAttachment()
            continuation.resume()
        }
    }
    channel.close()

    var firstChunkIterator = firstChunk.stream.makeAsyncIterator()
    #expect(await firstChunkIterator.next() == true)

    let completionCounter = DrainWaiterCompletionCounter()
    let firstWaiter = Task {
        await byteStream.waitForDrain()
        await completionCounter.recordCompletion()
    }
    let secondWaiter = Task {
        await byteStream.waitForDrain()
        await completionCounter.recordCompletion()
    }
    try await Task.sleep(for: .milliseconds(25))
    #expect(await completionCounter.count == 0)

    releaseConsumer.continuation.yield(true)
    #expect(await consumerTask.value == output)
    await firstWaiter.value
    await secondWaiter.value
    #expect(await completionCounter.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func silentConsoleChannelDiscardsAndCountsGuestOutput() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.silent-test")
    let channel = ConsoleChannel(role: .silent(name: "discard"), vmQueue: queue)
    let attachment = try #require(
        try queue.dispatchQueue.sync {
            try channel.makeAttachment() as? VZFileHandleSerialPortAttachment
        }
    )
    let stream = channel.makeByteStream()
    let output = Data(repeating: 0x5A, count: 8_192)
    try attachment.fileHandleForWriting?.write(contentsOf: output)

    for _ in 0..<1_000 {
        if channel.droppedByteCount >= output.count { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    queue.dispatchQueue.sync {
        channel.detachAttachment()
    }
    channel.close()

    var delivered = Data()
    for await chunk in stream.stream {
        delivered.append(chunk)
    }
    #expect(delivered.isEmpty)
    #expect(channel.droppedByteCount == output.count)
}

@Test(.timeLimit(.minutes(1)))
func consoleLogWriterUsesPrivateFilesAndRotatesOnDisk() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-console-system-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("vm", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let writer = ConsoleLogWriter(
        directoryURL: directory,
        logger: APKLogger(category: VMLogCategory.console),
        rotationLimit: 600
    )
    await writer.start()
    for index in 0..<60 {
        await writer.append(Data("system-record-\(index)\n".utf8))
    }
    await writer.finish()

    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
    )
    let logFiles = files.filter { $0.lastPathComponent.hasSuffix(".log") }
    #expect(logFiles.count <= 6)
    #expect(logFiles.contains { $0.lastPathComponent == "console.log" })
    #expect(logFiles.contains { $0.lastPathComponent.hasPrefix("boot-") })

    for file in logFiles {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    let currentLog = try Data(contentsOf: directory.appendingPathComponent("console.log"))
    #expect(currentLog.range(of: Data("system-record-59\n".utf8)) != nil)
}

private func guestInputPipeIsOpenAndEmpty(
    _ attachment: VZFileHandleSerialPortAttachment
) -> Bool {
    guard let descriptor = attachment.fileHandleForReading?.fileDescriptor else {
        return false
    }
    var pollDescriptor = pollfd(
        fd: descriptor,
        events: Int16(POLLIN | POLLHUP | POLLERR),
        revents: 0
    )
    return Darwin.poll(&pollDescriptor, 1, 50) == 0
}
