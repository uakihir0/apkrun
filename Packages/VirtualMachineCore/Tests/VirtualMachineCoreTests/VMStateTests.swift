import Testing

@testable import VirtualMachineCore

@Test func vmStateTransitionsMatchEveryDocumentedEdge() {
    let stopped = VMState.stopped
    let starting = VMState.starting
    let running = VMState.running
    let paused = VMState.paused
    let stopping = VMState.stopping
    let failed = VMState.failed(.stopTimedOut)
    let states = [stopped, starting, running, paused, stopping, failed]
    let allowedTransitions: [(VMState, VMState)] = [
        (stopped, starting),
        (starting, running),
        (starting, failed),
        (running, paused),
        (paused, running),
        (running, stopping),
        (paused, stopping),
        (stopping, stopped),
        (stopping, failed),
        (running, failed),
        (paused, failed),
        (running, stopped),
        (paused, stopped),
        (failed, stopped),
    ]

    for from in states {
        for to in states {
            let expected = allowedTransitions.contains { $0.0 == from && $0.1 == to }
            #expect(VMStateTransitions.isAllowed(from: from, to: to) == expected)
        }
    }
}
