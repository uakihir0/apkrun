import Testing

@testable import RuntimeHost

@Test func invalidatingConnectionCancelsActiveAndLateRequestTasks() async {
    let cancellation = RuntimeXPCConnectionTaskCancellation()
    let activeGate = XPCRequestTaskGate()
    let activeResult = XPCRequestTaskResult()
    let activeHandle = cancellation.makeHandle()
    let activeTask = Task {
        await activeGate.pause()
        await activeResult.record(Task.isCancelled)
    }
    activeHandle.install(activeTask)
    await activeGate.waitUntilStarted()

    cancellation.cancel()
    await activeGate.release()
    await activeTask.value
    #expect(await activeResult.wasCancelled == true)

    let lateGate = XPCRequestTaskGate()
    let lateResult = XPCRequestTaskResult()
    let lateHandle = cancellation.makeHandle()
    let lateTask = Task {
        await lateGate.pause()
        await lateResult.record(Task.isCancelled)
    }
    lateHandle.install(lateTask)
    await lateGate.waitUntilStarted()
    await lateGate.release()
    await lateTask.value
    #expect(await lateResult.wasCancelled == true)
}

private actor XPCRequestTaskGate {
    private var hasStarted = false
    private var hasReleased = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        hasStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            if hasReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        hasReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor XPCRequestTaskResult {
    private(set) var wasCancelled: Bool?

    func record(_ cancelled: Bool) {
        wasCancelled = cancelled
    }
}
