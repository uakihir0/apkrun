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

    /// Runs the sequence, and returns whether the VM had stopped by itself before the forced stop.
    ///
    /// - `requestPowerOff` sends the power-off request, and reports whether a channel was tried (`sendPowerOff`).
    ///   It is nil when no request is made. A request that no channel was tried for skips the wait.
    /// - `isStopped` reports whether the VM has stopped. It is polled during the wait.
    /// - `forceStop` stops the VM. It runs only when the VM is still running after the wait.
    ///
    /// The wait ignores the cancellation of the caller. A cancelled stop must not shorten the deadline (the VM still
    /// has to stop), and a cancelled sleep would return at once and spin until the deadline.
    @discardableResult
    func run(
        requestPowerOff: (@Sendable () async -> Bool)?,
        isStopped: @Sendable () async -> Bool,
        forceStop: @Sendable () async -> Void
    ) async -> Bool {
        if let requestPowerOff {
            let limit = ContinuousClock.now + deadline
            if await requestPowerOff() {
                while ContinuousClock.now < limit {
                    if await isStopped() {
                        break
                    }
                    await Self.pause(for: .milliseconds(250))
                }
            }
        }
        if await isStopped() {
            return true
        }
        await forceStop()
        return false
    }

    /// Sleeps in a task that the caller's cancellation does not reach.
    private static func pause(for duration: Duration) async {
        await Task.detached { _ = try? await Task.sleep(for: duration) }.value
    }

    /// Sends the power-off request over the first channel that takes it: ADB, then the serial shell. Each closure is
    /// nil when its channel does not exist, and each reports whether its request succeeded. Returns whether a channel
    /// was tried. A request that failed may still have reached Android (its reply can be lost), so a tried request
    /// gets the full deadline, and only a request that no channel could try skips the wait.
    static func sendPowerOff(
        overADB adb: (@Sendable () async -> Bool)?,
        overShell shell: (@Sendable () async -> Bool)?
    ) async -> Bool {
        var tried = false
        if let adb {
            tried = true
            if await adb() {
                return true
            }
        }
        guard let shell else {
            return tried
        }
        _ = await shell()
        return true
    }
}
