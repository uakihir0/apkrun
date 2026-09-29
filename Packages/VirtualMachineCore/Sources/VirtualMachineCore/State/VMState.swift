/// The explicit lifecycle state of a virtual machine.
public enum VMState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case failed(VMFailure)
}
