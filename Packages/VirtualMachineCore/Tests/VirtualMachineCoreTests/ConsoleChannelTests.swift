import Dispatch
import Foundation
import Testing
import Virtualization

@testable import VirtualMachineCore

@Test(.timeLimit(.minutes(1)))
func consoleChannelStreamsGuestOutputThroughPipeEOF() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.test")
    let channel = ConsoleChannel(role: .systemConsole, vmQueue: queue)
    let attachment = try #require(
        try queue.dispatchQueue.sync {
            try channel.makeAttachment() as? VZFileHandleSerialPortAttachment
        }
    )
    let firstStream = channel.makeByteStream()
    let secondStream = channel.makeByteStream()

    let expected = Data("boot line\n".utf8)
    try attachment.fileHandleForWriting?.write(contentsOf: Data(expected.prefix(4)))
    try attachment.fileHandleForWriting?.write(contentsOf: Data(expected.dropFirst(4)))
    queue.dispatchQueue.sync {
        channel.detachAttachment()
    }

    async let firstReceived = collect(firstStream.stream)
    async let secondReceived = collect(secondStream.stream)
    let (first, second) = await (firstReceived, secondReceived)
    #expect(first == expected)
    #expect(second == expected)

    let reattachFailure: ConsoleChannel.AttachmentFailure? = try queue.dispatchQueue.sync {
        do {
            _ = try channel.makeAttachment()
            return nil
        } catch let failure as ConsoleChannel.AttachmentFailure {
            return failure
        }
    }
    #expect(reattachFailure == .detached)

    channel.close()
    channel.close()
}

@Test(.timeLimit(.minutes(1)))
func consoleChannelReplaysBufferedPrefixToIndependentStreams() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.prefix-test")
    let channel = ConsoleChannel(role: .systemConsole, vmQueue: queue)
    let attachment = try #require(
        try queue.dispatchQueue.sync {
            try channel.makeAttachment() as? VZFileHandleSerialPortAttachment
        }
    )
    let expected = Data("early boot output\n".utf8)
    try attachment.fileHandleForWriting?.write(contentsOf: expected)
    #expect(await waitForBufferedPrefix(expected.count, on: channel))

    let firstStream = channel.makeByteStream()
    let secondStream = channel.makeByteStream()
    queue.dispatchQueue.sync {
        channel.detachAttachment()
    }
    channel.close()

    async let firstReceived = collect(firstStream.stream)
    async let secondReceived = collect(secondStream.stream)
    let (first, second) = await (firstReceived, secondReceived)
    #expect(first == expected)
    #expect(second == expected)
}

@Test(.timeLimit(.minutes(1)))
func consoleChannelBoundsBufferedBytesAndCountsDroppedOutput() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.overflow-test")
    let channel = ConsoleChannel(
        role: .systemConsole,
        vmQueue: queue,
        streamBufferCapacity: 1
    )
    let attachment = try #require(
        try queue.dispatchQueue.sync {
            try channel.makeAttachment() as? VZFileHandleSerialPortAttachment
        }
    )
    let stream = channel.makeByteStream()
    let expected = Data(repeating: 0x41, count: 128 * 1_024)
    try attachment.fileHandleForWriting?.write(contentsOf: expected)
    let didOverflow = await waitForDroppedBytes(on: channel)
    queue.dispatchQueue.sync {
        channel.detachAttachment()
    }
    channel.close()
    let received = await collect(stream.stream)

    #expect(!received.isEmpty)
    #expect(expected.starts(with: received))
    #expect(UInt64(received.count) + channel.droppedByteCount == UInt64(expected.count))
    #expect(stream.droppedByteCount == channel.droppedByteCount)
    #expect(didOverflow)
    #expect(channel.droppedByteCount > 0)
}

@Test(.timeLimit(.minutes(1)))
func consoleChannelCanRetainNewestChunksAndCountsDropsPerSubscriber() async throws {
    let queue = VMQueue(label: "io.apkrun.vm.console.newest-overflow-test")
    let channel = ConsoleChannel(
        role: .systemConsole,
        vmQueue: queue,
        streamBufferCapacity: 1
    )
    let attachment = try #require(
        try queue.dispatchQueue.sync {
            try channel.makeAttachment() as? VZFileHandleSerialPortAttachment
        }
    )
    let oldest = channel.makeByteStream()
    let newest = channel.makeByteStream(bufferingPolicy: .preserveNewest)
    let expected = Data(repeating: 0x42, count: 128 * 1_024)
    try attachment.fileHandleForWriting?.write(contentsOf: expected)
    let didOverflow = await waitForDroppedBytes(on: channel)
    queue.dispatchQueue.sync {
        channel.detachAttachment()
    }
    channel.close()

    async let oldestReceived = collect(oldest.stream)
    async let newestReceived = collect(newest.stream)
    let (oldestBytes, newestBytes) = await (oldestReceived, newestReceived)

    #expect(expected.starts(with: oldestBytes))
    #expect(expected.suffix(newestBytes.count) == newestBytes)
    #expect(oldest.droppedByteCount > 0)
    #expect(newest.droppedByteCount > 0)
    #expect(channel.droppedByteCount == oldest.droppedByteCount + newest.droppedByteCount)
    #expect(didOverflow)
}

private func waitForDroppedBytes(on channel: ConsoleChannel) async -> Bool {
    for _ in 0..<1_000 {
        if channel.droppedByteCount > 0 { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return channel.droppedByteCount > 0
}

private func waitForBufferedPrefix(_ count: Int, on channel: ConsoleChannel) async -> Bool {
    for _ in 0..<1_000 {
        if channel.bufferedPrefixByteCount >= count { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return channel.bufferedPrefixByteCount >= count
}

private func collect(_ stream: AsyncStream<Data>) async -> Data {
    var received = Data()
    for await chunk in stream {
        received.append(chunk)
    }
    return received
}
