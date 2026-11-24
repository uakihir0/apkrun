import Foundation
import Testing

@testable import RuntimeCore

private final class FakePowerEventSource: PowerEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (PowerSystemMessage) -> Void)?
    private var startCountStorage = 0
    private var stopCountStorage = 0

    var startCount: Int { lock.withLock { startCountStorage } }
    var stopCount: Int { lock.withLock { stopCountStorage } }

    func start(handler: @escaping @Sendable (PowerSystemMessage) -> Void) throws(PowerObserverFailure) {
        lock.withLock {
            startCountStorage += 1
            receiver = handler
        }
    }

    func stop() {
        lock.withLock {
            stopCountStorage += 1
            receiver = nil
        }
    }

    func sendCanSystemSleep(acknowledge: @escaping @Sendable () -> Void) {
        send(.canSystemSleep(acknowledge: acknowledge))
    }

    func sendSystemWillSleep(acknowledge: @escaping @Sendable () -> Void) {
        send(.systemWillSleep(acknowledge: acknowledge))
    }

    func sendSystemWillNotSleep() {
        send(.systemWillNotSleep)
    }

    func sendSystemHasPoweredOn() {
        send(.systemHasPoweredOn)
    }

    private func send(_ message: PowerSystemMessage) {
        let currentReceiver = lock.withLock { receiver }
        currentReceiver?(message)
    }
}

private final class PowerAcknowledgementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int { lock.withLock { countStorage } }

    func increment() {
        lock.withLock { countStorage += 1 }
    }
}

private actor PowerEventRecorder {
    private(set) var events: [PowerObserverEvent] = []
    private var willSleepContinuation: CheckedContinuation<Void, Never>?

    func handle(_ event: PowerObserverEvent) async {
        events.append(event)
        guard event == .systemWillSleep else { return }
        await withCheckedContinuation { continuation in
            willSleepContinuation = continuation
        }
    }

    func releaseWillSleep() {
        willSleepContinuation?.resume()
        willSleepContinuation = nil
    }
}

@Test func powerObserverAllowsCanSystemSleepWithoutCallingLifecycleHandler() async throws {
    let source = FakePowerEventSource()
    let recorder = PowerEventRecorder()
    let acknowledgements = PowerAcknowledgementCounter()
    let observer = PowerObserver(source: source) { event in
        await recorder.handle(event)
    }

    try observer.start()
    source.sendCanSystemSleep { acknowledgements.increment() }

    #expect(acknowledgements.count == 1)
    #expect(await recorder.events.isEmpty)
}

@Test func powerObserverAcknowledgesWillSleepAfterTheAsyncHandlerAndKeepsWakeOrder() async throws {
    let source = FakePowerEventSource()
    let recorder = PowerEventRecorder()
    let acknowledgements = PowerAcknowledgementCounter()
    let observer = PowerObserver(source: source) { event in
        await recorder.handle(event)
    }

    try observer.start()
    source.sendSystemWillSleep { acknowledgements.increment() }
    #expect(await eventually { await recorder.events == [.systemWillSleep] })
    #expect(acknowledgements.count == 0)

    source.sendSystemHasPoweredOn()
    await Task.yield()
    #expect(await recorder.events == [.systemWillSleep])
    #expect(acknowledgements.count == 0)

    await recorder.releaseWillSleep()
    #expect(
        await eventually {
            await recorder.events == [.systemWillSleep, .systemHasPoweredOn] && acknowledgements.count == 1
        }
    )
}

@Test func powerObserverAcknowledgesLateSleepAndStillDeliversWake() async throws {
    let source = FakePowerEventSource()
    let recorder = PowerEventRecorder()
    let acknowledgements = PowerAcknowledgementCounter()
    let observer = PowerObserver(
        source: source,
        willSleepAcknowledgementDeadline: .milliseconds(1)
    ) { event in
        await recorder.handle(event)
    }

    try observer.start()
    source.sendSystemWillSleep { acknowledgements.increment() }
    #expect(await eventually { await recorder.events == [.systemWillSleep] })
    #expect(await eventually { acknowledgements.count == 1 })

    source.sendSystemHasPoweredOn()
    #expect(
        await eventually {
            await recorder.events == [.systemWillSleep, .systemHasPoweredOn]
        }
    )

    await recorder.releaseWillSleep()
}

@Test func powerObserverDeliversCancelledSleepThenWake() async throws {
    let source = FakePowerEventSource()
    let recorder = PowerEventRecorder()
    let observer = PowerObserver(source: source) { event in
        await recorder.handle(event)
    }

    try observer.start()
    source.sendSystemWillNotSleep()
    source.sendSystemHasPoweredOn()

    #expect(
        await eventually {
            await recorder.events == [.systemWillNotSleep, .systemHasPoweredOn]
        }
    )
}

@Test func powerObserverStartAndStopAreIdempotent() throws {
    let source = FakePowerEventSource()
    let observer = PowerObserver(source: source) { _ in }

    try observer.start()
    try observer.start()
    #expect(source.startCount == 1)

    observer.stop()
    observer.stop()
    #expect(source.stopCount == 1)
}

private func eventually(
    attempts: Int = 1_000,
    condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return await condition()
}
