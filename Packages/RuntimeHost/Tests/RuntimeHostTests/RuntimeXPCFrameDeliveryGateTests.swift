import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func xpcFrameGateReleasesOnlyTheLatestFrameAfterAllRepliesAreSent() {
    let recorder = XPCFrameDeliveryRecorder()
    let gate = XPCFrameDeliveryGate(deliverFrame: { recorder.append($0) })
    let initial = FrameReady(generation: 1, surfaceIndex: 0, frameSeq: 1, presentationTime: 10)
    let stale = FrameReady(generation: 1, surfaceIndex: 1, frameSeq: 2, presentationTime: 20)
    let latest = FrameReady(generation: 2, surfaceIndex: 2, frameSeq: 3, presentationTime: 30)

    gate.deliver(initial)
    #expect(recorder.frames.isEmpty)
    gate.open()
    #expect(recorder.frames == [initial])

    gate.pause()
    gate.pause()
    gate.deliver(stale)
    gate.deliver(latest)
    gate.open()
    #expect(recorder.frames == [initial])
    gate.open()
    #expect(recorder.frames == [initial, latest])
}

private final class XPCFrameDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [FrameReady] = []

    var frames: [FrameReady] {
        lock.withLock { received }
    }

    func append(_ frame: FrameReady) {
        lock.withLock { received.append(frame) }
    }
}
