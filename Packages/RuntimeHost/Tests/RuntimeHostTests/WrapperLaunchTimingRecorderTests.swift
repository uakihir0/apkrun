import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func wrapperLaunchTimingRecordsProcessStartAndXPCRequestMarkers() {
    let nowNanoseconds: UInt64 = 1_000_000_000_000
    let now = ContinuousClock.now
    let timeline = PerfTimeline()
    let timing = LaunchTiming(
        processStart: nowNanoseconds - 100_000_000,
        requestSent: nowNanoseconds - 20_000_000
    )

    #expect(
        WrapperLaunchTimingRecorder.record(
            timing,
            clientKind: .wrapper,
            timeline: timeline,
            continuousNanoseconds: nowNanoseconds,
            instant: now
        )
    )

    let events = timeline.snapshot()
    #expect(events.map(\.marker) == [.wrapperProcessStart, .appLaunchRequest])
    #expect(events[0].time.duration(to: events[1].time) == .milliseconds(80))
    #expect(events[1].time.duration(to: now) == .milliseconds(20))
    #expect(events[1].attributes["xpcDelayMs"] == .double(20))
}

@Test func wrapperLaunchTimingRejectsOtherClientsAndImplausibleTimestamps() {
    let nowNanoseconds: UInt64 = 1_000_000_000_000
    let timeline = PerfTimeline()
    let validTiming = LaunchTiming(
        processStart: nowNanoseconds - 100_000_000,
        requestSent: nowNanoseconds - 20_000_000
    )

    #expect(
        !WrapperLaunchTimingRecorder.record(
            validTiming,
            clientKind: .launcher,
            timeline: timeline,
            continuousNanoseconds: nowNanoseconds
        )
    )
    #expect(
        !WrapperLaunchTimingRecorder.record(
            LaunchTiming(
                processStart: nowNanoseconds - 100_000_000,
                requestSent: nowNanoseconds + 1
            ),
            clientKind: .wrapper,
            timeline: timeline,
            continuousNanoseconds: nowNanoseconds
        )
    )
    #expect(
        !WrapperLaunchTimingRecorder.record(
            LaunchTiming(
                processStart: 0,
                requestSent: nowNanoseconds - 20_000_000
            ),
            clientKind: .wrapper,
            timeline: timeline,
            continuousNanoseconds: nowNanoseconds
        )
    )
    #expect(timeline.snapshot().isEmpty)
}
