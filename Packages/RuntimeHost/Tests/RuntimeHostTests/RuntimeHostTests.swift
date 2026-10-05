import Darwin
import Dispatch
import Foundation
import Testing

@testable import RuntimeHost

@Test func placeholderCanBeConstructed() {
    _ = RuntimeHostPlaceholder()
}

@Test(.timeLimit(.minutes(1)))
func consoleInputWriterKeepsEnqueueResponsiveDuringBlockedGuestWrite() async {
    let firstWriteStarted = AsyncStream.makeStream(of: Bool.self)
    let releaseFirstWrite = DispatchSemaphore(value: 0)
    let secondWriteStarted = AsyncStream.makeStream(of: Bool.self)
    let writer = DevConsoleInputWriter(
        capacity: 1,
        write: { bytes in
            if bytes == Data([1]) {
                firstWriteStarted.continuation.yield(true)
                releaseFirstWrite.wait()
            } else {
                secondWriteStarted.continuation.yield(true)
            }
        },
        onFailure: {}
    )

    #expect(writer.enqueue(Data([1])))
    var firstWriteIterator = firstWriteStarted.stream.makeAsyncIterator()
    #expect(await firstWriteIterator.next() == true)
    #expect(writer.enqueue(Data([2])))
    writer.cancel()
    releaseFirstWrite.signal()
    await writer.waitForCompletion()
    secondWriteStarted.continuation.finish()
    var secondWriteIterator = secondWriteStarted.stream.makeAsyncIterator()
    #expect(await secondWriteIterator.next() == nil)
}

@Test func consoleDetachIsLatchedBeforeItsBufferedInputEventIsConsumed() async throws {
    let input = DevConsoleInputChannel()
    defer { input.finish() }
    input.yield(.bytes(Data([0x65, 0x63, 0x68, 0x6f])))
    input.yield(.detach)

    #expect(input.detachWasRequested)
    var iterator = input.stream.makeAsyncIterator()
    guard case .bytes(let bytes)? = try await iterator.next() else {
        Issue.record("Expected the buffered guest input before detach.")
        return
    }
    #expect(bytes == Data([0x65, 0x63, 0x68, 0x6f]))
    guard case .detach? = try await iterator.next() else {
        Issue.record("Expected the buffered detach event.")
        return
    }
}

@Test(.timeLimit(.minutes(1)))
func consoleOutputWriterCancelsBlockedWritesAndRestoresDescriptorFlags() async throws {
    var descriptors: [Int32] = [0, 0]
    #expect(Darwin.pipe(&descriptors) == 0)
    defer {
        _ = Darwin.close(descriptors[0])
        _ = Darwin.close(descriptors[1])
    }

    let originalFlags = fcntl(descriptors[1], F_GETFL)
    #expect(originalFlags >= 0)
    let writer = try DevConsoleOutputWriter(fileDescriptor: descriptors[1])
    defer { writer.restore() }
    #expect(fcntl(descriptors[1], F_GETFL) & O_NONBLOCK != 0)

    let prefix = Data([0x41, 0x42, 0x43])
    writer.write(prefix)
    var received = [UInt8](repeating: 0, count: prefix.count)
    let receivedCount = received.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptors[0], bytes.baseAddress, bytes.count)
    }
    #expect(receivedCount == prefix.count)
    #expect(Data(received) == prefix)

    let fillBuffer = [UInt8](repeating: 0x58, count: 4_096)
    while true {
        let writeResult = fillBuffer.withUnsafeBytes { bytes in
            Darwin.write(descriptors[1], bytes.baseAddress, bytes.count)
        }
        if writeResult > 0 {
            continue
        }
        if writeResult < 0, errno == EINTR {
            continue
        }
        #expect(writeResult < 0)
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)
        break
    }

    let blockedBytes = Data(repeating: 0x59, count: 4_096)
    let blockedWriteTask = Task.detached {
        writer.write(blockedBytes)
    }
    try await Task.sleep(for: .milliseconds(20))
    writer.cancelPendingWrites()
    writer.restore()
    await blockedWriteTask.value
    #expect(writer.droppedByteCount == UInt64(blockedBytes.count))
    writer.write(Data([0x61, 0x62]))
    #expect(writer.droppedByteCount == UInt64(blockedBytes.count + 2))

    #expect(
        fcntl(descriptors[1], F_GETFL) & O_NONBLOCK
            == originalFlags & O_NONBLOCK
    )
}
