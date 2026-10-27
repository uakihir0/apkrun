import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func disconnectResolvesWrapperApprovalWhileGUIOpeningIsSuspended() async {
    let opener = SuspendedApprovalUIOpen()
    let approval = ApprovalEndpointLifecycleProbe(hasIndependentCLIConfirmation: false)
    let publication = ApprovalPublicationProbe()
    let result = ApprovalEndpointResult()
    let cancellation = RuntimeXPCConnectionTaskCancellation()
    let handle = cancellation.makeHandle()
    let request = Task {
        defer {
            handle.finish()
            cancellation.remove(handle)
        }
        await result.record(
            waitForWrapperApproval(
                publishApprovalRequested: { publication.publish() },
                openApprovalUI: { await opener.open() },
                waitForDecision: { onWaiterRegistered in
                    await approval.waitForDecision {
                        publication.markWaiterRegistered()
                        onWaiterRegistered()
                    }
                }
            )
        )
    }
    handle.install(request)

    await opener.waitUntilStarted()
    #expect(publication.wasPublishedAfterWaiterRegistration)
    cancellation.cancel()
    await approval.waitUntilWrapperWaitFinishes()

    #expect(await approval.hasPendingChallenge == false)
    #expect(await opener.isSuspended)
    #expect(await approval.approveIfPending() == false)
    await request.value
    #expect(await result.outcome == .timedOut)

    await opener.release()
}

@Test func disconnectPreservesWrapperApprovalPreparedForCLIConfirmationWhileGUIOpeningIsSuspended() async {
    let opener = SuspendedApprovalUIOpen()
    let approval = ApprovalEndpointLifecycleProbe(hasIndependentCLIConfirmation: true)
    let publication = ApprovalPublicationProbe()
    let result = ApprovalEndpointResult()
    let cancellation = RuntimeXPCConnectionTaskCancellation()
    let handle = cancellation.makeHandle()
    let request = Task {
        defer {
            handle.finish()
            cancellation.remove(handle)
        }
        await result.record(
            waitForWrapperApproval(
                publishApprovalRequested: { publication.publish() },
                openApprovalUI: { await opener.open() },
                waitForDecision: { onWaiterRegistered in
                    await approval.waitForDecision {
                        publication.markWaiterRegistered()
                        onWaiterRegistered()
                    }
                }
            )
        )
    }
    handle.install(request)

    await opener.waitUntilStarted()
    #expect(publication.wasPublishedAfterWaiterRegistration)
    cancellation.cancel()
    await approval.waitUntilWrapperWaitFinishes()

    #expect(await approval.hasPendingChallenge)
    #expect(await opener.isSuspended)
    #expect(await approval.approveIfPending())
    await request.value
    #expect(await result.outcome == .timedOut)

    await opener.release()
}

private actor ApprovalEndpointResult {
    private(set) var outcome: RuntimeWrapperApprovalOutcome?

    func record(_ outcome: RuntimeWrapperApprovalOutcome) {
        self.outcome = outcome
    }
}

private final class ApprovalPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var waiterRegistered = false
    private var publishedAfterWaiterRegistration = false

    var wasPublishedAfterWaiterRegistration: Bool {
        lock.lock()
        defer { lock.unlock() }
        return publishedAfterWaiterRegistration
    }

    func markWaiterRegistered() {
        lock.lock()
        waiterRegistered = true
        lock.unlock()
    }

    func publish() {
        lock.lock()
        publishedAfterWaiterRegistration = waiterRegistered
        lock.unlock()
    }
}

private actor ApprovalEndpointLifecycleProbe {
    private let hasIndependentCLIConfirmation: Bool
    private var pendingChallenge = true
    private var wrapperWaitFinished = false
    private var wasCancelled = false
    private var waitContinuation: CheckedContinuation<RuntimeWrapperApprovalOutcome, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(hasIndependentCLIConfirmation: Bool) {
        self.hasIndependentCLIConfirmation = hasIndependentCLIConfirmation
    }

    var hasPendingChallenge: Bool {
        pendingChallenge
    }

    func waitForDecision(
        onWaiterRegistered: @escaping @Sendable () -> Void
    ) async -> RuntimeWrapperApprovalOutcome {
        await withTaskCancellationHandler {
            if Task.isCancelled {
                cancelWrapperWaiter()
                return .timedOut
            }
            return await withCheckedContinuation { continuation in
                if wasCancelled {
                    continuation.resume(returning: .timedOut)
                } else if !pendingChallenge {
                    continuation.resume(returning: .unknown)
                } else {
                    waitContinuation = continuation
                    onWaiterRegistered()
                }
            }
        } onCancel: {
            Task {
                await self.cancelWrapperWaiter()
            }
        }
    }

    func waitUntilWrapperWaitFinishes() async {
        guard !wrapperWaitFinished else {
            return
        }
        await withCheckedContinuation { continuation in
            if wrapperWaitFinished {
                continuation.resume()
            } else {
                finishWaiters.append(continuation)
            }
        }
    }

    func approveIfPending() -> Bool {
        guard pendingChallenge else {
            return false
        }
        pendingChallenge = false
        return true
    }

    private func cancelWrapperWaiter() {
        guard !wrapperWaitFinished else {
            return
        }
        wasCancelled = true
        wrapperWaitFinished = true
        if !hasIndependentCLIConfirmation {
            pendingChallenge = false
        }
        waitContinuation?.resume(returning: .timedOut)
        waitContinuation = nil
        let continuations = finishWaiters
        finishWaiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor SuspendedApprovalUIOpen {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool {
        started && !released
    }

    func open() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else {
            return
        }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
