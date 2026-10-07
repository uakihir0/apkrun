package struct VMStartupEventBuffer {
    private var isCollecting = false
    private var events: [VirtualMachineEvent] = []

    package init() {}

    package mutating func begin() {
        events.removeAll(keepingCapacity: true)
        isCollecting = true
    }

    /// Returns `true` when the event was buffered for the pending start operation.
    package mutating func append(_ event: VirtualMachineEvent) -> Bool {
        guard isCollecting else { return false }
        events.append(event)
        return true
    }

    package mutating func finish() -> [VirtualMachineEvent] {
        isCollecting = false
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    package mutating func discard() {
        isCollecting = false
        events.removeAll(keepingCapacity: true)
    }
}
