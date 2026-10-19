import Foundation

/// Enforces runtime-daemon.md §4.3 for one required Guest Agent.
///
/// The outage deadline begins with the first non-ready state, survives reconnect backoff states, and is reset only
/// after the agent has completed its handshake and snapshot synchronization.
actor RequiredAgentOutageMonitor {
    private let timeout: Duration
    private let onUnavailable: @Sendable () async -> Void

    private var watcher: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var didExpire = false
    private var isStopped = false

    init(timeout: Duration, onUnavailable: @escaping @Sendable () async -> Void) {
        self.timeout = timeout
        self.onUnavailable = onUnavailable
    }

    /// Starts observing the supervisor's state stream.
    func watch(_ updates: AsyncStream<GuestAgentSupervisor.State>) {
        guard !isStopped else { return }
        watcher?.cancel()
        watcher = Task { [weak self] in
            for await state in updates {
                guard !Task.isCancelled else { return }
                await self?.observe(state)
            }
        }
    }

    /// Stops observation and invalidates a pending deadline.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        generation &+= 1
        watcher?.cancel()
        watcher = nil
        deadline?.cancel()
        deadline = nil
    }

    func observe(_ state: GuestAgentSupervisor.State) {
        guard !isStopped else { return }
        if state == .ready {
            generation &+= 1
            didExpire = false
            deadline?.cancel()
            deadline = nil
            return
        }
        guard deadline == nil, !didExpire else { return }

        generation &+= 1
        let scheduledGeneration = generation
        let timeout = timeout
        deadline = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self.expire(generation: scheduledGeneration)
        }
    }

    private func expire(generation expectedGeneration: UInt64) async {
        guard !isStopped, !didExpire, generation == expectedGeneration, deadline != nil else { return }
        deadline = nil
        didExpire = true
        await onUnavailable()
    }
}
