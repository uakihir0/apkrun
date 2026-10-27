import DiagnosticsCore
import Foundation
import RuntimeAPI

enum WrapperLaunchTimingRecorder {
    private static let maximumProcessAgeNanoseconds: UInt64 = 600_000_000_000

    @discardableResult
    static func record(
        _ timing: LaunchTiming?,
        clientKind: RuntimeClientKind,
        timeline: PerfTimeline,
        continuousNanoseconds: UInt64? = nil,
        instant: ContinuousClock.Instant = .now
    ) -> Bool {
        guard clientKind == .wrapper,
            let timing,
            timing.processStart <= timing.requestSent,
            let nowNanoseconds = continuousNanoseconds ?? ContinuousClockTimestamp.nowNanoseconds(),
            timing.requestSent <= nowNanoseconds
        else {
            return false
        }

        let processAgeNanoseconds = nowNanoseconds - timing.processStart
        let requestAgeNanoseconds = nowNanoseconds - timing.requestSent
        guard processAgeNanoseconds <= maximumProcessAgeNanoseconds else { return false }

        Perf.mark(
            .wrapperProcessStart,
            at: instant.advanced(by: durationBeforeNow(nanoseconds: processAgeNanoseconds)),
            timeline: timeline
        )
        Perf.mark(
            .appLaunchRequest,
            at: instant.advanced(by: durationBeforeNow(nanoseconds: requestAgeNanoseconds)),
            ["xpcDelayMs": .double(Double(requestAgeNanoseconds) / 1_000_000)],
            timeline: timeline
        )
        return true
    }

    private static func durationBeforeNow(nanoseconds: UInt64) -> Duration {
        let wholeSeconds = Int64(nanoseconds / 1_000_000_000)
        let remainingNanoseconds = Int64(nanoseconds % 1_000_000_000)
        return Duration(
            secondsComponent: -wholeSeconds,
            attosecondsComponent: -remainingNanoseconds * 1_000_000_000
        )
    }
}
