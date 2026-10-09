import DiagnosticsCore
import Foundation
import VirtualMachineCore

/// Decides when a boot is complete or has failed (runtime-daemon.md §3.2; #014 step 1).
///
/// The watch holds no clock. The caller passes the instant of each input, so the whole-boot
/// timeout and the stall limit can be tested with a test clock. `RuntimeSupervisor` feeds it
/// the console phases, the VM state, and a one-second tick.
struct BootWatch: Sendable {
    /// One thing that happened during the boot wait.
    enum Input: Equatable, Sendable {
        /// The console detector entered a phase.
        case entered(BootPhase)
        /// The console detector saw a failure (a kernel panic or `VIRTUAL_DEVICE_BOOT_FAILED`).
        case detectorFailed(RuntimeBootFailure)
        /// The VM reported a failure.
        case vmFailed(VMFailure)
        /// The guest stopped while it was booting.
        case guestStopped
        /// `stop()` was called during the boot.
        case stopRequested
        /// A periodic check, which runs the timeouts when nothing else arrived.
        case tick
    }

    /// What the boot wait does next.
    enum Decision: Equatable, Sendable {
        /// Keep waiting for the next input.
        case keepWaiting
        /// Android reported boot completion.
        case bootCompleted
        /// The boot failed with this reason.
        case fail(RuntimeBootFailure)
    }

    /// The phase the boot is in.
    private(set) var phase: BootPhase = .kernel
    /// The instant of the last phase change, or of the start.
    private(set) var lastProgress: ContinuousClock.Instant
    private let started: ContinuousClock.Instant
    private let whole: Duration
    private let stall: Duration

    /// Creates a watch for a boot that started at `started`.
    init(started: ContinuousClock.Instant, whole: Duration, stall: Duration) {
        self.started = started
        lastProgress = started
        self.whole = whole
        self.stall = stall
    }

    /// Applies one input at `now` and returns the decision.
    mutating func receive(_ input: Input, at now: ContinuousClock.Instant) -> Decision {
        switch input {
        case .entered(let entered):
            phase = entered
            lastProgress = now
            if entered == .bootCompleted {
                return .bootCompleted
            }
        case .detectorFailed(let failure):
            return .fail(failure)
        case .vmFailed(let failure):
            return .fail(.vm(failure))
        case .guestStopped:
            if now - started > .milliseconds(1) {
                return .fail(.androidBootFailed(detail: "the guest stopped while booting"))
            }
        case .stopRequested:
            return .fail(.androidBootFailed(detail: "the runtime was stopped during boot"))
        case .tick:
            break
        }
        if now - started > whole {
            return .fail(.bootTimedOut(phase: phase))
        }
        if now - lastProgress > stall {
            return .fail(.bootStalled(phase: phase))
        }
        return .keepWaiting
    }
}
