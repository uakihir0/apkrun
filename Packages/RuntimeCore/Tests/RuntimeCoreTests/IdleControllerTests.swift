import Foundation
import Testing

@testable import RuntimeCore

private actor IdleActionRecorder {
    private(set) var actions: [IdleControllerAction] = []

    func append(_ action: IdleControllerAction) {
        actions.append(action)
    }
}

private actor AssertionCompletionRecorder {
    private(set) var completedKinds: [ActivityKind] = []

    func markCompleted(_ kind: ActivityKind) {
        completedKinds.append(kind)
    }
}

private actor GatedIdleActionHandler {
    private let blockedAction: IdleControllerAction
    private(set) var actions: [IdleControllerAction] = []
    private var blockedActionContinuation: CheckedContinuation<Void, Never>?

    init(blockedAction: IdleControllerAction) {
        self.blockedAction = blockedAction
    }

    func handle(_ action: IdleControllerAction) async {
        actions.append(action)
        guard action == blockedAction else {
            return
        }
        await withCheckedContinuation { continuation in
            blockedActionContinuation = continuation
        }
    }

    func releaseBlockedAction() {
        blockedActionContinuation?.resume()
        blockedActionContinuation = nil
    }
}

private final class ManualSuspendingClock: RuntimeIdleClock, @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let id = UUID()
        let deadline: Duration
        var continuation: CheckedContinuation<Void, any Error>?
        var isCancelled = false

        init(deadline: Duration) {
            self.deadline = deadline
        }
    }

    private let lock = NSLock()
    private var instant: Duration = .zero
    private var simulatedHostSleep: Duration = .zero
    private var sleepCalls = 0
    private var waiters: [UUID: Waiter] = [:]

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    var hostSleepDuration: Duration {
        lock.lock()
        defer { lock.unlock() }
        return simulatedHostSleep
    }

    var sleepCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepCalls
    }

    func sleep(until deadline: Duration) async throws {
        let waiter = Waiter(deadline: deadline)
        lock.withLock {
            sleepCalls += 1
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                var result: Result<Void, any Error>?
                lock.lock()
                if waiter.isCancelled {
                    result = .failure(CancellationError())
                } else if instant >= deadline {
                    result = .success(())
                } else {
                    waiter.continuation = continuation
                    waiters[waiter.id] = waiter
                }
                lock.unlock()

                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancel(waiter)
        }
    }

    func advanceAwakeTime(by duration: Duration) {
        lock.lock()
        instant += duration
        let dueWaiters = waiters.values.filter { instant >= $0.deadline }
        for waiter in dueWaiters {
            waiters.removeValue(forKey: waiter.id)
        }
        let continuations = dueWaiters.compactMap { waiter -> CheckedContinuation<Void, any Error>? in
            let continuation = waiter.continuation
            waiter.continuation = nil
            return continuation
        }
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func simulateHostSleep(by duration: Duration) {
        lock.lock()
        simulatedHostSleep += duration
        lock.unlock()
    }

    private func cancel(_ waiter: Waiter) {
        lock.lock()
        waiter.isCancelled = true
        let continuation = waiter.continuation
        waiter.continuation = nil
        waiters.removeValue(forKey: waiter.id)
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }
}

@Test func idleControllerUsesDocumentedDefaultsAndValidatesTimerRanges() throws {
    let settings = try RuntimeIdleSettings()

    #expect(settings.idleSuspendMinutes == 10)
    #expect(settings.idleStopMinutes == 60)
    #expect(settings.startPolicy == .onDemand)
    #expect(throws: RuntimeIdleSettings.ValidationError.self) {
        try RuntimeIdleSettings(idleSuspendMinutes: -1)
    }
    #expect(throws: RuntimeIdleSettings.ValidationError.self) {
        try RuntimeIdleSettings(idleStopMinutes: 1441)
    }
}

@Test func idleControllerEmitsSuspendThenStopAtTheirDeadlines() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 2)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await recorder.actions.contains(.suspend) })
    #expect(await recorder.actions.filter { $0 == .suspend }.count == 1)

    clock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await recorder.actions.contains(.stop) })
    #expect(await recorder.actions.filter { $0 == .stop }.count == 1)
}

@Test func everyRuntimeActivitySourceHoldsTheRuntimeAndReleaseRestartsIdleTime() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 2)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    for kind in ActivityKind.runtimeSources {
        let assertion = await controller.assertActivity(kind)
        #expect(await controller.activeAssertionCount == 1)
        #expect(await controller.hasActivity(of: kind))
        #expect(await recorder.actions.last == .activityBegan(kind))
        assertion.release()
        #expect(await eventually { await controller.activeAssertionCount == 0 })
        #expect(!(await controller.hasActivity(of: kind)))
    }

    clock.advanceAwakeTime(by: .seconds(59))
    await Task.yield()
    #expect(!(await recorder.actions.contains(.suspend)))
    clock.advanceAwakeTime(by: .seconds(1))
    #expect(await eventually { await recorder.actions.contains(.suspend) })
}

@Test func idleControllerCanRebaseTheIdlePeriodAfterRuntimeLifecycleChanges() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 2)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(30))
    await controller.resetIdlePeriod()
    clock.advanceAwakeTime(by: .seconds(59))
    await Task.yield()
    #expect(!(await recorder.actions.contains(.suspend)))

    clock.advanceAwakeTime(by: .seconds(1))
    #expect(await eventually { await recorder.actions.contains(.suspend) })

    let assertion = await controller.assertActivity(.session)
    await controller.resetIdlePeriod()
    #expect(await controller.hasActivity(of: .session))
    assertion.release()
    #expect(await eventually { await controller.activeAssertionCount == 0 })
}

@Test func zeroDisablesEachIdleDeadline() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 0, idleStopMinutes: 0)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(86_400))
    await Task.yield()

    #expect(!(await recorder.actions.contains(.suspend)))
    #expect(!(await recorder.actions.contains(.stop)))
}

@Test func zeroDisablesOnlyItsOwnIdleDeadline() async throws {
    let suspendDisabledClock = ManualSuspendingClock()
    let suspendDisabledRecorder = IdleActionRecorder()
    let suspendDisabledSettings = try RuntimeIdleSettings(idleSuspendMinutes: 0, idleStopMinutes: 1)
    let suspendDisabledController = IdleController(
        settings: suspendDisabledSettings,
        clock: suspendDisabledClock
    ) { action in
        await suspendDisabledRecorder.append(action)
    }
    await suspendDisabledController.start()
    suspendDisabledClock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await suspendDisabledRecorder.actions.contains(.stop) })
    #expect(!(await suspendDisabledRecorder.actions.contains(.suspend)))

    let stopDisabledClock = ManualSuspendingClock()
    let stopDisabledRecorder = IdleActionRecorder()
    let stopDisabledSettings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 0)
    let stopDisabledController = IdleController(
        settings: stopDisabledSettings,
        clock: stopDisabledClock
    ) { action in
        await stopDisabledRecorder.append(action)
    }
    await stopDisabledController.start()
    stopDisabledClock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await stopDisabledRecorder.actions.contains(.suspend) })
    stopDisabledClock.advanceAwakeTime(by: .seconds(60))
    await Task.yield()
    #expect(!(await stopDisabledRecorder.actions.contains(.stop)))
}

@Test func activityAssertionReleasesOnDeinitialization() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let controller = IdleController(clock: clock) { action in
        await recorder.append(action)
    }
    await controller.start()
    var assertion: RuntimeActivityAssertion? = await controller.assertActivity(.session)

    #expect(assertion?.kind == .session)
    #expect(await controller.activeAssertionCount == 1)
    assertion = nil
    #expect(await eventually { await controller.activeAssertionCount == 0 })
}

@Test func activityActionIsQueuedBehindAnInFlightIdleAction() async throws {
    try await activityActionIsQueuedBehindInFlightIdleAction(.suspend)
    try await activityActionIsQueuedBehindInFlightIdleAction(.stop)
}

@Test func simultaneousActivityAssertionsWaitForTheSameActivityAction() async throws {
    let recorder = GatedIdleActionHandler(blockedAction: .activityBegan(.session))
    let controller = IdleController { action in
        await recorder.handle(action)
    }
    let completedAssertions = AssertionCompletionRecorder()
    await controller.start()

    let firstTask = Task {
        let assertion = await controller.assertActivity(.session)
        await completedAssertions.markCompleted(.session)
        return assertion
    }
    #expect(await eventually { await controller.activeAssertionCount == 1 })
    #expect(await eventually { await recorder.actions == [.activityBegan(.session)] })

    let secondTask = Task {
        let assertion = await controller.assertActivity(.storeOperation)
        await completedAssertions.markCompleted(.storeOperation)
        return assertion
    }
    #expect(await eventually { await controller.activeAssertionCount == 2 })
    #expect(await completedAssertions.completedKinds.isEmpty)

    await recorder.releaseBlockedAction()
    let firstAssertion = await firstTask.value
    let secondAssertion = await secondTask.value
    #expect(
        Set(await completedAssertions.completedKinds) == Set([.session, .storeOperation])
    )
    #expect(await recorder.actions == [.activityBegan(.session)])
    firstAssertion.release()
    secondAssertion.release()
}

@Test func activityCancelsAQueuedStopBehindAnInFlightSuspend() async throws {
    let clock = ManualSuspendingClock()
    let recorder = GatedIdleActionHandler(blockedAction: .suspend)
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 2)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.handle(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(120))
    #expect(await eventually { await recorder.actions.contains(.suspend) })
    #expect(await eventually { clock.sleepCallCount >= 2 })
    for _ in 0..<100 {
        await Task.yield()
    }

    let completedAssertions = AssertionCompletionRecorder()
    let activityTask = Task {
        let assertion = await controller.assertActivity(.session)
        await completedAssertions.markCompleted(.session)
        return assertion
    }
    #expect(await eventually { await controller.activeAssertionCount == 1 })
    #expect(await completedAssertions.completedKinds.isEmpty)
    await recorder.releaseBlockedAction()
    let assertion = await activityTask.value

    #expect(await recorder.actions == [.suspend, .activityBegan(.session)])
    assertion.release()
}

@Test func matchingSuspendAndStopDeadlinesSuspendBeforeStopping() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 1)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await recorder.actions.contains(.stop) })

    #expect(await recorder.actions == [.suspend, .stop])
}

@Test func idleStopBeforeSuspendStopsWithoutSuspending() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 10, idleStopMinutes: 2)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(120))
    #expect(await eventually { await recorder.actions.contains(.stop) })
    #expect(!(await recorder.actions.contains(.suspend)))
}

@Test func settingsChangesRecomputeDeadlinesWithoutResettingIdleStart() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let initialSettings = try RuntimeIdleSettings(idleSuspendMinutes: 10, idleStopMinutes: 60)
    let updatedSettings = try RuntimeIdleSettings(
        idleSuspendMinutes: 4,
        idleStopMinutes: 5,
        startPolicy: .atLogin
    )
    let controller = IdleController(settings: initialSettings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(180))
    await controller.update(settings: updatedSettings)
    #expect(await controller.currentSettings == updatedSettings)

    clock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await recorder.actions.contains(.suspend) })
    clock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await recorder.actions.contains(.stop) })
}

@Test func simulatedHostSleepDoesNotAdvanceTheIdleClock() async throws {
    let clock = ManualSuspendingClock()
    let recorder = IdleActionRecorder()
    let settings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 2)
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.append(action)
    }

    await controller.start()
    let awakeTimeBeforeSleep = clock.now
    clock.simulateHostSleep(by: .seconds(28_800))

    #expect(clock.hostSleepDuration == .seconds(28_800))
    #expect(clock.now == awakeTimeBeforeSleep)
    await Task.yield()
    #expect(!(await recorder.actions.contains(.suspend)))

    clock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await recorder.actions.contains(.suspend) })
}

private func eventually(
    attempts: Int = 1_000,
    condition: () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return await condition()
}

private func activityActionIsQueuedBehindInFlightIdleAction(
    _ idleAction: IdleControllerAction
) async throws {
    let clock = ManualSuspendingClock()
    let recorder = GatedIdleActionHandler(blockedAction: idleAction)
    let settings: RuntimeIdleSettings
    if idleAction == .suspend {
        settings = try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 2)
    } else {
        settings = try RuntimeIdleSettings(idleSuspendMinutes: 2, idleStopMinutes: 1)
    }
    let controller = IdleController(settings: settings, clock: clock) { action in
        await recorder.handle(action)
    }

    await controller.start()
    clock.advanceAwakeTime(by: .seconds(60))
    #expect(await eventually { await recorder.actions.contains(idleAction) })

    let completedAssertions = AssertionCompletionRecorder()
    let activityTask = Task {
        let assertion = await controller.assertActivity(.session)
        await completedAssertions.markCompleted(.session)
        return assertion
    }
    #expect(await eventually { await controller.activeAssertionCount == 1 })
    #expect(await completedAssertions.completedKinds.isEmpty)
    #expect(await recorder.actions.last == idleAction)

    await recorder.releaseBlockedAction()
    let assertion = await activityTask.value
    #expect(await eventually { await recorder.actions.last == .activityBegan(.session) })
    assertion.release()
}
