import AppKit
import Foundation
import IntegrationCore
import Testing

@testable import RuntimeHost

private struct LocaleTimeClockSyncCall: Equatable, Sendable {
    let unixTimeMilliseconds: Int64
    let roundTripMilliseconds: UInt32
}

private actor LocaleTimeWakeChannel: LocaleTimeGuestChannel {
    let clockSyncCalls: AsyncStream<LocaleTimeClockSyncCall>
    private let clockSyncContinuation: AsyncStream<LocaleTimeClockSyncCall>.Continuation
    private var syncTimeCallCount = 0

    init() {
        let stream = AsyncStream.makeStream(of: LocaleTimeClockSyncCall.self)
        clockSyncCalls = stream.stream
        clockSyncContinuation = stream.continuation
    }

    func setLocale(_ languageTags: [String]) async throws {}

    func setTimeZone(_ identifier: String) async throws {}

    func setClockFormat(_ format: LocaleTimeSnapshot.ClockFormat) async throws {}

    func syncTime(unixTimeMilliseconds: Int64, roundTripMilliseconds: UInt32) async throws {
        syncTimeCallCount += 1
        clockSyncContinuation.yield(
            LocaleTimeClockSyncCall(
                unixTimeMilliseconds: unixTimeMilliseconds,
                roundTripMilliseconds: roundTripMilliseconds
            )
        )
    }

    func callCount() -> Int {
        syncTimeCallCount
    }
}

@Test(.timeLimit(.minutes(1)))
func wakeNotificationRoutesThroughLocaleTimeSynchronizerToGuestClockChannel() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let channel = LocaleTimeWakeChannel()
    let synchronizer = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en-US") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Etc/UTC" },
            dateFormatForHourCycle: { _ in "HH:mm" }
        ),
        currentDate: { now }
    )
    let notificationCenter = NotificationCenter()
    let wakeBinding = LocaleTimeNotificationRelay.workspaceWakeBinding(
        notificationCenter: notificationCenter
    )
    #expect(wakeBinding.name == NSWorkspace.didWakeNotification)
    #expect(wakeBinding.trigger == .wake)

    let relay = LocaleTimeNotificationRelay(
        bindings: [wakeBinding],
        onTrigger: { trigger in
            _ = await synchronizer.synchronize(
                trigger: trigger,
                settings: LocaleTimeSyncSettings(
                    syncLocale: false,
                    syncTimeZone: false,
                    syncClockFormat: false
                ),
                sessionIsRunning: true,
                roundTripMilliseconds: 42
            )
        }
    )
    relay.start()
    defer { relay.stop() }

    notificationCenter.post(name: wakeBinding.name, object: nil)

    var iterator = channel.clockSyncCalls.makeAsyncIterator()
    let call = await iterator.next()
    #expect(
        call
            == LocaleTimeClockSyncCall(
                unixTimeMilliseconds: 1_800_000_000_000,
                roundTripMilliseconds: 42
            )
    )
    #expect(await channel.callCount() == 1)
}
