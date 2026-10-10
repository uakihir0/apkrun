/// How Android stops (vm.md §9.3). With a power-off request, Android gets `deadline` after the request to power
/// itself off, and only a VM that is still running then is stopped by force. Without one, the VM is stopped at once.
struct AndroidStopSequence: Sendable {
    /// The time Android has to power itself off after the request (vm.md §9.3).
    static let standardDeadline: Duration = .seconds(20)

    /// The time after the request before the forced stop.
    let deadline: Duration

    /// Creates the sequence with the given deadline. The production deadline is `standardDeadline`.
    init(deadline: Duration = AndroidStopSequence.standardDeadline) {
        precondition(deadline > .zero)
        self.deadline = deadline
    }

    /// Runs the sequence and returns when the VM has stopped.
    ///
    /// - `requestPowerOff` sends the power-off request, and reports whether a channel accepted it. It is nil when
    ///   no request is made. A refused request skips the wait, and the VM is stopped at once.
    /// - `isStopped` reports whether the VM has stopped. It is polled during the wait.
    /// - `forceStop` stops the VM. It runs only when the VM is still running after the wait.
    func run(
        requestPowerOff: (@Sendable () async -> Bool)?,
        isStopped: @Sendable () async -> Bool,
        forceStop: @Sendable () async -> Void
    ) async {
        if let requestPowerOff {
            let limit = ContinuousClock.now + deadline
            if await requestPowerOff() {
                while ContinuousClock.now < limit {
                    if await isStopped() {
                        break
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        // The stop task was cancelled. Stop waiting, so the loop does not spin until the deadline.
                        break
                    }
                }
            }
        }
        if await !isStopped() {
            await forceStop()
        }
    }
}
