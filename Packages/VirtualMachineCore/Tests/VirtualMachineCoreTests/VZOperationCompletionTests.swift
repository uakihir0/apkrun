import Foundation
import Testing

@testable import VirtualMachineCore

@Test(.timeLimit(.minutes(1)))
func vzOperationCompletionWaitsForAnInFlightFrameworkCallAfterCancellation() async {
    let started = AsyncStream.makeStream(of: VZOperationCompletion.self)
    let taskState = VZOperationTaskState()
    let task = Task {
        var failure: VZErrorInfo?
        do {
            try await withVZOperationCompletion { completion in
                guard completion.markStarted() else { return }
                started.continuation.yield(completion)
            }
        } catch let error as VZErrorInfo {
            failure = error
        } catch {
            failure = VZErrorInfo(error as NSError)
        }
        await taskState.finish(with: failure)
    }
    var iterator = started.stream.makeAsyncIterator()
    let completion = await iterator.next()
    #expect(completion != nil)

    task.cancel()
    try? await Task.sleep(for: .milliseconds(25))
    #expect(await taskState.didFinish == false)
    completion?.complete()

    await task.value
    #expect(await taskState.didFinish)
    #expect(await taskState.failure?.domain == NSCocoaErrorDomain)
    #expect(await taskState.failure?.code == NSUserCancelledError)
}

private actor VZOperationTaskState {
    private(set) var didFinish = false
    private(set) var failure: VZErrorInfo?

    func finish(with failure: VZErrorInfo?) {
        self.failure = failure
        didFinish = true
    }
}
