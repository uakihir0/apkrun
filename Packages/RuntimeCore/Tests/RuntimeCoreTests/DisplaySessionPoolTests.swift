import Foundation
import GraphicsCore
import Testing

@testable import RuntimeCore

@Test
func displaySessionPoolForwardsFramesAndAcknowledgements() async throws {
    let (sourceFrames, sourceContinuation) = AsyncStream.makeStream(of: ScanoutFrame.self)
    let acknowledgements = FrameAcknowledgements()
    let displayPool = DisplaySessionPool(
        scanoutPool: ScanoutPoolHandle(
            generation: 7,
            surfaces: [],
            frames: sourceFrames,
            acknowledgeFrame: { sequence in acknowledgements.append(sequence) }
        )
    )
    let stream = displayPool.makeFrameStream()
    let nextFrame = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    sourceContinuation.yield(
        .frameReady(generation: 7, bufferIndex: 1, sequence: 42, presentationTime: 99)
    )

    #expect(
        await nextFrame.value
            == DisplaySessionFrame(generation: 7, bufferIndex: 1, sequence: 42, presentationTime: 99)
    )
    displayPool.frameDisplayed(sequence: 42)
    #expect(acknowledgements.values == [42])
    sourceContinuation.finish()
}

private final class FrameAcknowledgements: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [UInt64] = []

    var values: [UInt64] {
        lock.withLock { storedValues }
    }

    func append(_ sequence: UInt64) {
        lock.withLock { storedValues.append(sequence) }
    }
}
