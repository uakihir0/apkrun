/// The outcome of trying Guest Protocol `Shutdown` before platform-specific fallbacks.
enum GuestPowerOffAttempt: Equatable, Sendable {
    /// The Guest Agent acknowledged `Shutdown`.
    case accepted
    /// The Guest Agent explicitly rejected or could not send `Shutdown`.
    case rejected
    /// The connection failed after the request may have reached Android.
    case uncertain
}

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
            if await requestPowerOff() {
                // Android gets the full grace period after the shutdown request has returned. In particular, an
                // uncertain protocol reply must not consume the post-request deadline while the request is pending.
                let limit = ContinuousClock.now + deadline
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

    /// Sends the power-off request through Guest Protocol first, then developer-only ADB and serial fallbacks.
    /// A Guest Protocol request with an uncertain outcome gets the full deadline and is never resent over another
    /// channel, because Android may already be shutting down.
    static func sendPowerOff(
        guestAttempt: GuestPowerOffAttempt?,
        overADB adb: (@Sendable () async -> Bool)?,
        overShell shell: (@Sendable () async -> Bool)?
    ) async -> Bool {
        switch guestAttempt {
        case .accepted, .uncertain:
            return true
        case .rejected, nil:
            break
        }

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
