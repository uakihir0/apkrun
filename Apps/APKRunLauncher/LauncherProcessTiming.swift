import Darwin
import DiagnosticsCore
import Foundation
import RuntimeAPI

enum LauncherProcessTiming {
    static func recoveryRequest(from request: OpenSessionRequest) -> OpenSessionRequest {
        var recoveryRequest = request
        recoveryRequest.launchTiming = nil
        return recoveryRequest
    }

    static func processStartContinuousNanoseconds() -> UInt64? {
        guard let processStartUnixNanoseconds = processStartUnixNanoseconds(),
            let wallNowUnixNanoseconds = wallClockUnixNanoseconds(),
            let continuousNowNanoseconds = ContinuousClockTimestamp.nowNanoseconds()
        else {
            return nil
        }
        return continuousStartNanoseconds(
            processStartUnixNanoseconds: processStartUnixNanoseconds,
            wallNowUnixNanoseconds: wallNowUnixNanoseconds,
            continuousNowNanoseconds: continuousNowNanoseconds
        )
    }

    static func continuousStartNanoseconds(
        processStartUnixNanoseconds: UInt64,
        wallNowUnixNanoseconds: UInt64,
        continuousNowNanoseconds: UInt64
    ) -> UInt64? {
        guard wallNowUnixNanoseconds >= processStartUnixNanoseconds else { return nil }
        let processAgeNanoseconds = wallNowUnixNanoseconds - processStartUnixNanoseconds
        guard processAgeNanoseconds <= continuousNowNanoseconds else { return nil }
        return continuousNowNanoseconds - processAgeNanoseconds
    }

    private static func processStartUnixNanoseconds() -> UInt64? {
        var processInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &processInfo, infoSize) == infoSize else {
            return nil
        }
        return unixNanoseconds(
            seconds: processInfo.pbi_start_tvsec,
            microseconds: processInfo.pbi_start_tvusec
        )
    }

    private static func wallClockUnixNanoseconds() -> UInt64? {
        var wallClock = timeval()
        guard gettimeofday(&wallClock, nil) == 0 else { return nil }
        return unixNanoseconds(seconds: wallClock.tv_sec, microseconds: wallClock.tv_usec)
    }

    private static func unixNanoseconds<Seconds: BinaryInteger, Microseconds: BinaryInteger>(
        seconds: Seconds,
        microseconds: Microseconds
    ) -> UInt64? {
        guard let seconds = UInt64(exactly: seconds),
            let microseconds = UInt64(exactly: microseconds),
            microseconds < 1_000_000
        else {
            return nil
        }
        let (wholeNanoseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (timestamp, additionOverflow) = wholeNanoseconds.addingReportingOverflow(microseconds * 1_000)
        guard !additionOverflow else { return nil }
        return timestamp
    }
}
