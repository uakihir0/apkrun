import Foundation

/// One `BootPhaseDetector` shared by the console reader and the ADB poller of a boot (runtime-daemon.md §3.3).
///
/// The first signal wins, and the phases stay monotonic. Each phase is passed to `emit` while the lock is
/// held, so the console and ADB sources deliver their events in the order in which the phases were entered.
final class BootPhaseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = BootPhaseDetector()

    /// Consumes console bytes and passes each phase they enter to `emit`.
    func consume(console bytes: Data, emit: (BootPhaseDetector.Event) -> Void) {
        lock.withLock {
            for event in detector.consume(bytes) {
                emit(event)
            }
        }
    }

    /// Applies one ADB poll and passes each phase it enters to `emit`.
    func observe(adb state: AdbBootState, emit: (BootPhaseDetector.Event) -> Void) {
        lock.withLock {
            for event in detector.observe(adb: state) {
                emit(event)
            }
        }
    }
}
