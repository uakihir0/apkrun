import Foundation

/// One `BootPhaseDetector` shared by the console reader and the ADB poller of a boot (runtime-daemon.md §3.3).
///
/// The first signal wins, and the phases stay monotonic, so the two sources can run concurrently.
final class BootPhaseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = BootPhaseDetector()

    /// Consumes console bytes and returns the phases they entered.
    func consume(console bytes: Data) -> [BootPhaseDetector.Event] {
        lock.withLock { detector.consume(bytes) }
    }

    /// Applies one ADB poll and returns the phases it entered.
    func observe(adb state: AdbBootState) -> [BootPhaseDetector.Event] {
        lock.withLock { detector.observe(adb: state) }
    }
}
