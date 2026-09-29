import Foundation
import Testing
@testable import DiagnosticsCore

@Test func perfMarkerCatalogueHasStableUniqueNames() {
    let names = Set(PerfMarker.allCases.map(\.rawValue))

    #expect(names.count == PerfMarker.allCases.count)
    #expect(names == [
        "DAEMON_READY",
        "VM_START",
        "KERNEL_START",
        "ANDROID_INIT",
        "SYSTEM_SERVER_READY",
        "BOOT_COMPLETED",
        "AGENT_CONNECTED",
        "RUNTIME_READY",
        "VM_PAUSED",
        "VM_RESUMED",
        "WRAPPER_PROCESS_START",
        "APP_LAUNCH_REQUEST",
        "DISPLAY_ATTACHED",
        "ACTIVITY_STARTED",
        "FIRST_FRAME",
        "FIRST_FRAME_DISPLAYED",
        "WRAPPER_GENERATE_START",
        "WRAPPER_GENERATE_END",
        "WRAPPER_REFRESH_END",
        "WRAPPER_APPROVAL_END",
        "PACKAGE_IMPORT_START",
        "PACKAGE_INSPECTED",
        "PACKAGE_INSTALL_START",
        "PACKAGE_INSTALL_COMPLETE",
        "PACKAGE_ROLLBACK_COMPLETE",
        "UPDATE_CHECK_START",
        "UPDATE_CHECK_END",
        "UPDATE_DOWNLOAD_START",
        "UPDATE_DOWNLOAD_END",
        "UPDATE_INSTALL_START",
        "UPDATE_INSTALL_END",
        "UPDATE_HEALTH_END",
        "UPDATE_ROLLBACK_END",
        "CLIPBOARD_PUSH",
        "NOTIFICATION_DELIVERED",
        "FILE_TRANSFER",
        "SELF_UPDATE_CHECK_END",
        "HOST_UPDATE_PREPARE_START",
        "HOST_UPDATE_PREPARED",
        "HOST_UPDATED",
        "IMAGE_CHECK_END",
        "IMAGE_DOWNLOAD_START",
        "IMAGE_DOWNLOAD_END",
        "IMAGE_INSTALL_END",
        "IMAGE_MIGRATION_START",
        "IMAGE_MIGRATION_END",
        "IMAGE_ROLLBACK_END",
    ])
}

@Test func performanceSignpostsUseTheirCatalogueSubsystems() {
    #expect(PerfMarker.vmStart.subsystem == .vm)
    #expect(PerfMarker.firstFrame.subsystem == .runtime)
    #expect(Perf.intervalSubsystem(for: "gpu.flush") == .graphics)
    #expect(Perf.intervalSubsystem(for: "gpu.upload") == .graphics)
    #expect(Perf.intervalSubsystem(for: "input.route") == .input)
    #expect(Perf.intervalSubsystem(for: "input.dispatch") == .input)
    #expect(Perf.intervalSubsystem(for: "provider.request") == .diagnostics)
}

@Test func perfTimelineRetainsOnlyTheNewestTwoThousandEvents() throws {
    let timeline = PerfTimeline()
    let clock = ContinuousClock()
    for index in 0..<(PerfTimeline.capacity + 5) {
        timeline.append(
            PerfEvent(
                marker: PerfMarker(rawValue: "TEST_\(index)"),
                time: clock.now,
                attributes: ["sequence": .integer(Int64(index))],
                operationContext: nil
            )
        )
    }

    let events = timeline.snapshot()
    #expect(events.count == PerfTimeline.capacity)
    #expect(events.first?.marker.rawValue == "TEST_5")
    #expect(events.last?.marker.rawValue == "TEST_\(PerfTimeline.capacity + 4)")
    #expect(events.first?.attributes["sequence"] == .integer(5))
}

@Test func perfMarkCapturesTimeAttributesAndOperationContext() throws {
    let timeline = PerfTimeline()
    let marker = PerfMarker.displayAttached
    let time = ContinuousClock().now
    let context = OperationContext(
        operationID: OperationID(),
        parent: OperationID()
    )

    OperationContext.$current.withValue(context) {
        Perf.mark(
            marker,
            at: time,
            [
                "slot": .integer(3),
                "displayID": .string("display-2"),
                "reused": .boolean(false),
            ],
            timeline: timeline
        )
    }

    let event = try #require(timeline.snapshot().last)
    #expect(event.marker == marker)
    #expect(event.time == time)
    #expect(event.attributes["slot"] == .integer(3))
    #expect(event.attributes["displayID"] == .string("display-2"))
    #expect(event.attributes["reused"] == .boolean(false))
    #expect(event.operationContext == context)

    let signpostTime = time.advanced(by: .seconds(2))
    let fields = Perf.signpostFields(for: event, emittedAt: signpostTime)
    #expect(fields.contains("sourceTimeOffsetMsAtSample=2000"))
}

@Test func perfMarkBoundsAttributesAndHidesUnapprovedStringsFromSignposts() throws {
    let timeline = PerfTimeline()
    let sensitiveValue = "/Users/alice/Documents/private-token"
    Perf.mark(
        .updateCheckStart,
        [
            "provider": .string(sensitiveValue),
            "bytes": .integer(42),
        ],
        timeline: timeline
    )

    let event = try #require(timeline.snapshot().last)
    #expect(event.attributes["provider"] == .string(sensitiveValue))

    let fields = Perf.signpostFields(for: event, emittedAt: ContinuousClock().now)
    #expect(fields.contains("marker=UPDATE_CHECK_START"))
    #expect(fields.contains("bytes=42"))
    #expect(!fields.contains(sensitiveValue))

    let mismatchedScalarTimeline = PerfTimeline()
    let scalarSentinel: Int64 = 9_007_199_254_740_993
    Perf.mark(
        .vmStart,
        ["bytes": .integer(scalarSentinel), "bootKind": .string("cold")],
        timeline: mismatchedScalarTimeline
    )
    let mismatchedEvent = try #require(mismatchedScalarTimeline.snapshot().last)
    #expect(mismatchedEvent.attributes["bytes"] == nil)
    #expect(mismatchedEvent.attributes["bootKind"] == .string("cold"))
    #expect(!Perf.signpostFields(for: mismatchedEvent).contains(String(scalarSentinel)))

    let oversizedValueTimeline = PerfTimeline()
    Perf.mark(
        .imageCheckEnd,
        ["imageVersion": .string(String(repeating: "v", count: 257))],
        timeline: oversizedValueTimeline
    )
    #expect(try #require(oversizedValueTimeline.snapshot().last).attributes.isEmpty)

    let allowedKeys = [
        "agent", "bootKind", "bootMs", "bytes", "displayID", "durationMs",
        "fromBuild", "imageVersion", "kind", "pausedMs", "processStarted",
        "provider", "recoverySteps", "reused", "result", "slot", "splits",
        "startupMs", "status", "toBuild", "xpcDelayMs",
    ]
    let tooManyAttributes = Dictionary(
        uniqueKeysWithValues: allowedKeys.prefix(17).enumerated().map { index, key in
            (key, PerfValue.integer(Int64(index)))
        }
    )
    let boundedTimeline = PerfTimeline()
    Perf.mark(.daemonReady, tooManyAttributes, timeline: boundedTimeline)
    #expect(try #require(boundedTimeline.snapshot().last).attributes.isEmpty)

    let unknownMarkerTimeline = PerfTimeline()
    Perf.mark(
        PerfMarker(rawValue: sensitiveValue),
        ["startupMs": .integer(1)],
        timeline: unknownMarkerTimeline
    )
    let unknownMarkerEvent = try #require(unknownMarkerTimeline.snapshot().last)
    #expect(unknownMarkerEvent.marker.rawValue == "UNKNOWN")
    #expect(!Perf.signpostFields(for: unknownMarkerEvent, emittedAt: .now).contains(sensitiveValue))
}

@Test func perfMarkEnforcesMarkerSpecificTypesAndRanges() throws {
    let timeline = PerfTimeline()
    Perf.mark(
        .vmStart,
        [
            "bootKind": .integer(1),
            "bytes": .integer(9_007_199_254_740_993),
        ],
        timeline: timeline
    )

    let event = try #require(timeline.snapshot().last)
    #expect(event.attributes.isEmpty)

    let countTimeline = PerfTimeline()
    Perf.mark(
        .updateDownloadEnd,
        ["bytes": .integer(1_000_000_000_000_001)],
        timeline: countTimeline
    )
    #expect(try #require(countTimeline.snapshot().last).attributes.isEmpty)

    let invalidDurationTimeline = PerfTimeline()
    Perf.mark(
        .wrapperGenerateEnd,
        ["durationMs": .double(-0.5)],
        timeline: invalidDurationTimeline
    )
    #expect(try #require(invalidDurationTimeline.snapshot().last).attributes.isEmpty)
}

@Test func perfIntervalReturnsResultsAndPropagatesErrors() async throws {
    let timelineBefore = Perf.timeline.snapshot()
    let value = await Perf.interval("gpu.flush") {
        "flushed"
    }
    #expect(value == "flushed")

    do {
        _ = try await Perf.interval("input.route") {
            throw PerfFixtureError.failed
        } as String
        Issue.record("The interval should preserve the body's error.")
    } catch PerfFixtureError.failed {
        #expect(true)
    } catch {
        Issue.record("The interval threw an unexpected error: \(error).")
    }
    #expect(Perf.timeline.snapshot() == timelineBefore)
}

private enum PerfFixtureError: Error {
    case failed
}
