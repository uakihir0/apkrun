import Foundation
import Testing

@testable import RuntimeHost

@Test func workspaceApprovalOpenGateCompletesAfterTheWorkspaceReply() async throws {
    let probe = WorkspaceApprovalOpenGateProbe()

    try await WorkspaceApprovalOpenGate().perform { completion in
        probe.markStarted()
        completion(.success(()))
    }

    #expect(probe.didStart)
}

@Test func workspaceApprovalOpenGateSuppressesAQueuedOpenAfterCancellation() async throws {
    let probe = WorkspaceApprovalOpenGateProbe()
    let gate = WorkspaceApprovalOpenGate()

    let task = await MainActor.run {
        let task = Task {
            try? await gate.perform { completion in
                probe.markStarted()
                completion(.success(()))
            }
        }
        task.cancel()
        return task
    }
    await task.value

    #expect(!probe.didStart)
}

private final class WorkspaceApprovalOpenGateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStartValue = false

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStartValue
    }

    func markStarted() {
        lock.lock()
        didStartValue = true
        lock.unlock()
    }
}
