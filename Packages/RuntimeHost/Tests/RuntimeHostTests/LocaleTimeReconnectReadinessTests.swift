import RuntimeCore
import Testing

@testable import RuntimeHost

private actor ReconnectTriggerCount {
    private var value = 0

    func increment() {
        value += 1
    }

    func read() -> Int {
        value
    }
}

@Test func localeSyncWaitsUntilTheReconnectedAgentIsReady() async {
    let states = AsyncStream<GuestAgentSupervisor.State>.makeStream()
    let triggerCount = ReconnectTriggerCount()
    let waiter = Task {
        await LocaleTimeReconnectReadiness.waitForReady(states: states.stream) {
            await triggerCount.increment()
        }
    }

    states.continuation.yield(.reconnecting)
    states.continuation.yield(.ready)
    states.continuation.finish()
    await waiter.value

    #expect(await triggerCount.read() == 1)
}

@Test func localeSyncStopsWaitingWhenTheAgentBecomesUnavailable() async {
    let states = AsyncStream<GuestAgentSupervisor.State>.makeStream()
    let triggerCount = ReconnectTriggerCount()
    let waiter = Task {
        await LocaleTimeReconnectReadiness.waitForReady(states: states.stream) {
            await triggerCount.increment()
        }
    }

    states.continuation.yield(.reconnecting)
    states.continuation.yield(.unavailable)
    states.continuation.finish()
    await waiter.value

    #expect(await triggerCount.read() == 0)
}
