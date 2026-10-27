import Darwin

/// Reads timestamps in the sleep-inclusive monotonic clock used by `ContinuousClock`.
public enum ContinuousClockTimestamp {
    /// Returns `mach_continuous_time` converted to nanoseconds.
    public static func nowNanoseconds() -> UInt64? {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            return nil
        }

        let denominator = UInt64(timebase.denom)
        let numerator = UInt64(timebase.numer)
        let ticks = mach_continuous_time()
        let wholeTicks = ticks / denominator
        let remainingTicks = ticks % denominator
        let (wholeNanoseconds, overflow) = wholeTicks.multipliedReportingOverflow(by: numerator)
        guard !overflow else { return nil }
        let fractionalNanoseconds = remainingTicks * numerator / denominator
        let (nanoseconds, additionOverflow) = wholeNanoseconds.addingReportingOverflow(fractionalNanoseconds)
        guard !additionOverflow else { return nil }
        return nanoseconds
    }
}
