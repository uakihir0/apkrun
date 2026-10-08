/// Admits at most `maximumPerWindow` guest-error log lines in each one-second window.
///
/// Rejected lines are counted, and the next admitted line reports how many were
/// suppressed (graphics.md §4.2, §13.2). The limiter has no lock of its own; its
/// owner serializes access.
struct GuestErrorRateLimiter {
    /// The result of one ``admit(at:)`` call.
    enum Decision: Equatable {
        /// Log the line. `suppressedCount` lines were dropped since the last logged line.
        case log(suppressedCount: Int)
        /// Drop the line and count it.
        case suppress
    }

    static let windowNanoseconds: UInt64 = 1_000_000_000

    let maximumPerWindow: Int
    private var windowStart: UInt64?
    private var admittedInWindow = 0
    private var suppressedSinceLastLog = 0

    init(maximumPerWindow: Int = 10) {
        self.maximumPerWindow = maximumPerWindow
    }

    /// Decides whether a line at `now` (monotonic nanoseconds) is logged.
    mutating func admit(at now: UInt64) -> Decision {
        let isInCurrentWindow = windowStart.map { now &- $0 < Self.windowNanoseconds } ?? false
        if !isInCurrentWindow {
            windowStart = now
            admittedInWindow = 0
        }
        guard admittedInWindow < maximumPerWindow else {
            suppressedSinceLastLog += 1
            return .suppress
        }
        admittedInWindow += 1
        let suppressed = suppressedSinceLastLog
        suppressedSinceLastLog = 0
        return .log(suppressedCount: suppressed)
    }
}
