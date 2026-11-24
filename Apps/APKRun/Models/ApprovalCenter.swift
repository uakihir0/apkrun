import Foundation
import RuntimeAPI
import RuntimeClient

/// Drives the wrapper approval flow (wrapper.md §7.3, host-ui.md §10.1): it
/// subscribes to `approvalRequested`, answers prompts with `decideApproval`,
/// and refreshes the queue from `pendingApprovals` whenever it connects.
/// Requests queue in arrival order and one prompt is shown at a time.
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    /// The prompt the approval window shows, if any.
    @Published private(set) var current: ApprovalPrompt?

    private var queue: [ApprovalPrompt] = []
    /// The daemon client, shared with the Settings panes.
    private(set) var client: RuntimeControlClient?
    private var runTask: Task<Void, Never>?

    private init() {}

    /// Connects to the daemon and starts listening for approval requests.
    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Answers the current prompt (wrapper.md §7.3 step 5).
    func decide(allow: Bool) {
        guard let prompt = current else { return }
        current = nil
        showNextIfIdle()
        Task { [client] in
            try? await client?.decideApproval(approvalID: prompt.approvalID, allow: allow)
        }
    }

    private func run() async {
        do {
            let client = try RuntimeControlClient(clientKind: .app)
            self.client = client
            _ = try await client.connect()
            let stream = try await client.subscribe(to: .wrappers)
            await refreshQueue()
            for await envelope in stream {
                guard case .wrappers(let change) = envelope.payload else { continue }
                handle(change)
            }
        } catch {
            // The daemon was not reachable. A later --approve launch reconnects
            // and refreshes the queue from pendingApprovals.
        }
    }

    private func refreshQueue() async {
        guard let client,
            let pending = try? await client.pendingApprovals()
        else {
            return
        }
        var known = Set(queue.map(\.approvalID))
        if let current {
            known.insert(current.approvalID)
        }
        queue.append(contentsOf: pending.filter { !known.contains($0.approvalID) })
        showNextIfIdle()
    }

    private func handle(_ change: WrapperChange) {
        switch change {
        case .approvalRequested(let prompt):
            queue.append(prompt)
            showNextIfIdle()
        case .approvalResolved(let approvalID):
            queue.removeAll { $0.approvalID == approvalID }
            if current?.approvalID == approvalID {
                current = nil
                showNextIfIdle()
            }
        default:
            break
        }
    }

    private func showNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let prompt = queue.removeFirst()
        // An expired prompt was already resolved by the daemon; skip it.
        guard prompt.expiresAt > Date() else {
            showNextIfIdle()
            return
        }
        current = prompt
        // Close the prompt when it times out (host-ui.md §10.1); the daemon's
        // approvalResolved event also clears it.
        let approvalID = prompt.approvalID
        let remaining = prompt.expiresAt.timeIntervalSinceNow
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, self.current?.approvalID == approvalID else { return }
            self.current = nil
            self.showNextIfIdle()
        }
    }
}
