/// Rejects stale connection-count callbacks from replaced or stopped developer ADB forwarders.
struct ADBClientActivityTracker: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var connectionCount = 0

    /// Applies a callback only when it advances the active forwarder's ordered event stream.
    mutating func receive(generation: UInt64, revision: UInt64, connectionCount: Int) -> Bool {
        guard generation >= self.generation else { return false }
        if generation > self.generation {
            self.generation = generation
            self.revision = 0
            self.connectionCount = 0
        }
        guard revision > self.revision else { return false }
        self.revision = revision
        self.connectionCount = max(0, connectionCount)
        return true
    }

    /// Invalidates callbacks through the supervisor's latest forwarder generation.
    ///
    /// Repeated stops without a boot leave the supervisor generation unchanged. Using that source
    /// generation keeps the next forwarder eligible even when stop was called more than once.
    mutating func invalidate(afterGeneration sourceGeneration: UInt64) {
        let nextGeneration = sourceGeneration == .max ? .max : sourceGeneration + 1
        generation = max(generation, nextGeneration)
        revision = 0
        connectionCount = 0
    }

    /// Clears the local count when no supervisor could have emitted a callback.
    mutating func clearConnectionCount() {
        revision = 0
        connectionCount = 0
    }
}
