import Foundation
import Testing
import VirtualMachineCore

@Test
func rebootObserverFailsPromptlyWhenAGuestCheckFailsBeforeTheRebootMarker() async {
    await #expect(
        throws: LinuxGuestHarness.HarnessFailure.guestCheckFailed(
            name: "rng",
            detail: "virtio_rng.0 was not registered"
        )
    ) {
        try await observeGuestRebootEvents([
            .record(
                .check(
                    name: "rng",
                    result: .fail,
                    detail: "virtio_rng.0 was not registered"
                )
            ),
            .record(.done),
        ])
    }
}

@Test
func rebootObserverFailsPromptlyWhenTheGuestFinishesBeforeTheRebootMarker() async {
    await #expect(throws: LinuxGuestHarness.HarnessFailure.guestFinishedBeforeRestartMarker) {
        try await observeGuestRebootEvents([
            .record(.bootOK),
            .record(.done),
        ])
    }
}

@Test
func rebootObserverFailsPromptlyWhenTheVMStopsBeforeTheRebootMarker() async {
    await #expect(throws: LinuxGuestHarness.HarnessFailure.guestStoppedBeforeRestartMarker) {
        try await observeGuestRebootEvents([
            .state(.running),
            .state(.stopped),
        ])
    }
}

@Test
func rebootObserverFailsWhenTheVMEntersFailedStateAfterTheRebootMarker() async {
    await #expect(
        throws: LinuxGuestHarness.HarnessFailure.guestVMFailedDuringRebootObservation
    ) {
        try await observeGuestRebootEvents([
            .state(.running),
            .record(
                .check(
                    name: "rng-reboot",
                    result: .ok,
                    detail: "reboot requested after first read"
                )
            ),
            .state(.failed(.stopTimedOut)),
        ])
    }
}

@Test
func rebootObserverRecognizesASecondBoot() async throws {
    let result = try await observeGuestRebootEvents([
        .record(.bootOK),
        .record(
            .check(
                name: "rng-reboot",
                result: .ok,
                detail: "reboot requested after first read"
            )
        ),
        .record(.bootOK),
    ])

    #expect(result.outcome == .guestRestarted)
    #expect(result.records.last == .bootOK)
}

private func observeGuestRebootEvents(
    _ events: [LinuxGuestHarness.HarnessEvent]
) async throws -> (records: [TestGuestRecord], outcome: LinuxGuestHarness.RebootObservation) {
    let (stream, continuation) = AsyncStream<LinuxGuestHarness.HarnessEvent>.makeStream(
        bufferingPolicy: .unbounded
    )
    let observer = Task {
        try await LinuxGuestHarness.observeGuestReboot(
            events: stream,
            continuation: continuation
        )
    }
    for event in events {
        continuation.yield(event)
    }
    continuation.finish()
    return try await observer.value
}
