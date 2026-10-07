import Dispatch
import Testing

@testable import VirtualMachineCore

@Test func vmStartupEventBufferCapturesOnlyEventsDuringStartAndPreservesOrder() {
    let failure = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 74,
        description: "private"
    )
    let startupEvents: [VirtualMachineEvent] = [
        .guestDidStop,
        .didStopWithError(failure),
        .networkAttachmentDisconnected(failure),
    ]
    var buffer = VMStartupEventBuffer()

    let bufferedBeforeStart = buffer.append(.guestDidStop)
    #expect(!bufferedBeforeStart)
    buffer.begin()
    for event in startupEvents {
        let wasBuffered = buffer.append(event)
        #expect(wasBuffered)
    }
    let capturedEvents = buffer.finish()
    #expect(capturedEvents == startupEvents)
    let bufferedAfterStart = buffer.append(.guestDidStop)
    #expect(!bufferedAfterStart)
    let emptyAfterFinish = buffer.finish().isEmpty
    #expect(emptyAfterFinish)
}

@Test func vmStartupEventBufferDiscardsEventsWhenStartCompletionFails() {
    let failure = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 75,
        description: "private"
    )
    var buffer = VMStartupEventBuffer()

    buffer.begin()
    let wasBuffered = buffer.append(.didStopWithError(failure))
    #expect(wasBuffered)
    buffer.discard()

    let emptyAfterDiscard = buffer.finish().isEmpty
    #expect(emptyAfterDiscard)
    let bufferedAfterDiscard = buffer.append(.didStopWithError(failure))
    #expect(!bufferedAfterDiscard)
}

@Test func vzEventDelegateBuffersStartEventsAndPublishesEventsAfterCompletion() async {
    let queue = VMQueue(label: "io.apkrun.vm.startup-buffer-test")
    let (stream, continuation) = AsyncStream.makeStream(
        of: VirtualMachineEvent.self,
        bufferingPolicy: .unbounded
    )
    let delegate = VZVirtualMachineEventDelegate(
        queue: queue,
        continuation: continuation
    )
    let failure = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 76,
        description: "private"
    )
    let startupEvents: [VirtualMachineEvent] = [
        .didStopWithError(failure),
        .guestDidStop,
    ]
    let laterEvent = VirtualMachineEvent.networkAttachmentDisconnected(failure)

    let capturedEvents = await withCheckedContinuation {
        (completion: CheckedContinuation<[VirtualMachineEvent], Never>) in
        queue.dispatchQueue.async {
            delegate.beginStart()
            for event in startupEvents {
                delegate.publish(event)
            }
            let events = delegate.finishStart()
            delegate.publish(laterEvent)
            continuation.finish()
            completion.resume(returning: events)
        }
    }

    var iterator = stream.makeAsyncIterator()
    let eventAfterStart = await iterator.next()
    let endOfStream = await iterator.next()
    #expect(capturedEvents == startupEvents)
    #expect(eventAfterStart == laterEvent)
    #expect(endOfStream == nil)
}

@Test func vzEventDelegateDiscardsBufferedEventsWhenStartCompletionFails() async {
    let queue = VMQueue(label: "io.apkrun.vm.startup-discard-test")
    let (stream, continuation) = AsyncStream.makeStream(
        of: VirtualMachineEvent.self,
        bufferingPolicy: .unbounded
    )
    let delegate = VZVirtualMachineEventDelegate(
        queue: queue,
        continuation: continuation
    )
    let failure = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 77,
        description: "private"
    )

    await withCheckedContinuation {
        (completion: CheckedContinuation<Void, Never>) in
        queue.dispatchQueue.async {
            delegate.beginStart()
            delegate.publish(.didStopWithError(failure))
            delegate.discardStart()
            delegate.publish(.guestDidStop)
            continuation.finish()
            completion.resume()
        }
    }

    var iterator = stream.makeAsyncIterator()
    let streamEvent = await iterator.next()
    let endOfStream = await iterator.next()
    #expect(streamEvent == .guestDidStop)
    #expect(endOfStream == nil)
}
