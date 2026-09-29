/// The allowed edges in the VM lifecycle state machine.
public enum VMStateTransitions {
    /// Returns whether the state-machine specification permits this edge.
    public static func isAllowed(from: VMState, to: VMState) -> Bool {
        switch (from, to) {
        case (.stopped, .starting),
            (.starting, .running),
            (.running, .paused),
            (.running, .stopping),
            (.running, .stopped),
            (.paused, .running),
            (.paused, .stopping),
            (.paused, .stopped),
            (.stopping, .stopped),
            (.failed, .stopped):
            true
        case (.starting, .failed),
            (.running, .failed),
            (.paused, .failed),
            (.stopping, .failed):
            true
        default:
            false
        }
    }
}
