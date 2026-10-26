import Foundation
import Testing

@testable import IntegrationCore

private actor LocaleTimeChannelFake: LocaleTimeGuestChannel {
    var locales: [[String]] = []
    var timeZones: [String] = []
    var clockFormats: [LocaleTimeSnapshot.ClockFormat] = []
    var clockTimes: [(Int64, UInt32)] = []
    var rejectTimeZoneIdentifiers = Set<String>()

    func setLocale(_ languageTags: [String]) async throws {
        locales.append(languageTags)
    }

    func setTimeZone(_ identifier: String) async throws {
        if rejectTimeZoneIdentifiers.contains(identifier) {
            throw LocaleTimeChannelFailure.timeZoneNotFound
        }
        timeZones.append(identifier)
    }

    func setClockFormat(_ format: LocaleTimeSnapshot.ClockFormat) async throws {
        clockFormats.append(format)
    }

    func syncTime(unixTimeMilliseconds: Int64, roundTripMilliseconds: UInt32) async throws {
        clockTimes.append((unixTimeMilliseconds, roundTripMilliseconds))
    }

    func reject(_ identifiers: Set<String>) {
        rejectTimeZoneIdentifiers = identifiers
    }

    func counts() -> (Int, Int, Int, Int) {
        (locales.count, timeZones.count, clockFormats.count, clockTimes.count)
    }

    func timeZoneRequests() -> [String] {
        timeZones
    }

    func localeRequests() -> [[String]] {
        locales
    }

    func clockTimeRequests() -> [(Int64, UInt32)] {
        clockTimes
    }
}

private actor LocaleApplicationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private final class MutableDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func get() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.date = date
    }
}

@Test func waitsForRunningSessionAndSendsOnlyChangedPreferences() async {
    let channel = LocaleTimeChannelFake()
    let snapshotBuilder = LocaleTimeSnapshotBuilder(
        preferredLanguages: { ["ja-JP", "en-US"] },
        currentLocale: { Locale(identifier: "ja-JP") },
        resetTimeZone: {},
        currentTimeZoneIdentifier: { "Asia/Tokyo" },
        dateFormatForHourCycle: { _ in "HH:mm" }
    )
    let sync = LocaleTimeSynchronizer(channel: channel, snapshotBuilder: snapshotBuilder)
    let settings = LocaleTimeSyncSettings()

    _ = await sync.synchronizePreferences(settings: settings, sessionIsRunning: false)
    #expect(await channel.counts() == (0, 0, 0, 0))

    _ = await sync.synchronizePreferences(settings: settings, sessionIsRunning: true)
    #expect(await channel.counts() == (1, 1, 1, 0))

    _ = await sync.synchronizePreferences(settings: settings, sessionIsRunning: true)
    #expect(await channel.counts() == (1, 1, 1, 0))
}

@Test func localeApplicationCallbackRunsOnlyAfterAChangedLocaleIsApplied() async {
    let channel = LocaleTimeChannelFake()
    let callback = LocaleApplicationCounter()
    let sync = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["ja-JP"] },
            currentLocale: { Locale(identifier: "ja-JP") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Asia/Tokyo" },
            dateFormatForHourCycle: { _ in "HH:mm" }
        ),
        onLocaleApplied: {
            await callback.increment()
        }
    )

    _ = await sync.synchronizePreferences(settings: LocaleTimeSyncSettings(), sessionIsRunning: false)
    #expect(await callback.count == 0)

    _ = await sync.synchronizePreferences(settings: LocaleTimeSyncSettings(), sessionIsRunning: true)
    #expect(await callback.count == 1)

    _ = await sync.synchronizePreferences(settings: LocaleTimeSyncSettings(), sessionIsRunning: true)
    #expect(await callback.count == 1)

    await sync.guestDidReconnect()
    _ = await sync.synchronizePreferences(settings: LocaleTimeSyncSettings(), sessionIsRunning: true)
    #expect(await callback.count == 2)

    _ = await sync.synchronizePreferences(
        settings: LocaleTimeSyncSettings(syncLocale: false),
        sessionIsRunning: true
    )
    #expect(await callback.count == 2)
}

@Test func disabledPreferencesAreNotPushedAndAreResentWhenReenabled() async {
    let channel = LocaleTimeChannelFake()
    let sync = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["en-GB"] },
            currentLocale: { Locale(identifier: "en-GB") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Europe/London" },
            dateFormatForHourCycle: { _ in "HH:mm" }
        )
    )

    _ = await sync.synchronizePreferences(
        settings: LocaleTimeSyncSettings(syncLocale: false, syncTimeZone: false, syncClockFormat: false),
        sessionIsRunning: true
    )
    #expect(await channel.counts() == (0, 0, 0, 0))

    _ = await sync.synchronizePreferences(settings: LocaleTimeSyncSettings(), sessionIsRunning: true)
    #expect(await channel.counts() == (1, 1, 1, 0))
}

@Test func reconnectReplaysHostValues() async {
    let channel = LocaleTimeChannelFake()
    let sync = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en-US") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Etc/UTC" },
            dateFormatForHourCycle: { _ in "h:mm a" }
        )
    )

    _ = await sync.synchronizePreferences(settings: LocaleTimeSyncSettings(), sessionIsRunning: true)
    await sync.guestDidReconnect()
    _ = await sync.synchronizePreferences(settings: LocaleTimeSyncSettings(), sessionIsRunning: true)
    #expect(await channel.counts() == (2, 2, 2, 0))
}

@Test func fallsBackToFixedOffsetWhenGuestDoesNotKnowTheIanaZone() async {
    let channel = LocaleTimeChannelFake()
    await channel.reject(["Pacific/Kiritimati"])
    let sync = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en-US") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Pacific/Kiritimati" },
            dateFormatForHourCycle: { _ in "h:mm a" }
        ),
        currentDate: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let warnings = await sync.synchronizePreferences(
        settings: LocaleTimeSyncSettings(syncLocale: false, syncClockFormat: false),
        sessionIsRunning: true
    )

    #expect(await channel.timeZoneRequests() == ["Etc/GMT-14"])
    #expect(warnings == [.timeZoneFixedOffset])
}

@Test func keepsGuestZoneAndWarnsForNonWholeHourOffset() async {
    let channel = LocaleTimeChannelFake()
    await channel.reject(["Asia/Kathmandu"])
    let sync = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en-US") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Asia/Kathmandu" },
            dateFormatForHourCycle: { _ in "h:mm a" }
        )
    )

    let warnings = await sync.synchronizePreferences(
        settings: LocaleTimeSyncSettings(syncLocale: false, syncClockFormat: false),
        sessionIsRunning: true
    )

    #expect(await channel.timeZoneRequests().isEmpty)
    #expect(warnings == [.timeZoneOffsetUnsupported])
}

@Test func periodicRefreshUpdatesFixedOffsetFallbackAcrossDST() async {
    let channel = LocaleTimeChannelFake()
    await channel.reject(["America/New_York"])
    let date = MutableDate(Date(timeIntervalSince1970: 1_704_067_200))
    let sync = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en-US") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "America/New_York" },
            dateFormatForHourCycle: { _ in "h:mm a" }
        ),
        currentDate: { date.get() }
    )
    let settings = LocaleTimeSyncSettings(syncLocale: false, syncClockFormat: false)

    _ = await sync.synchronize(
        trigger: .postBoot,
        settings: settings,
        sessionIsRunning: true,
        roundTripMilliseconds: 0
    )
    #expect(await channel.timeZoneRequests() == ["Etc/GMT+5"])

    date.set(Date(timeIntervalSince1970: 1_719_792_000))
    _ = await sync.synchronize(
        trigger: .periodic,
        settings: settings,
        sessionIsRunning: true,
        roundTripMilliseconds: 0
    )
    #expect(await channel.timeZoneRequests() == ["Etc/GMT+5", "Etc/GMT+4"])

    _ = await sync.synchronize(
        trigger: .periodic,
        settings: settings,
        sessionIsRunning: true,
        roundTripMilliseconds: 0
    )
    #expect(await channel.timeZoneRequests() == ["Etc/GMT+5", "Etc/GMT+4"])
}

@Test func sendsWallClockWithMostRecentPingRoundTrip() async {
    let channel = LocaleTimeChannelFake()
    let date = Date(timeIntervalSince1970: 1_800_000_000.123)
    let sync = LocaleTimeSynchronizer(channel: channel, currentDate: { date })

    _ = await sync.synchronizeClock(roundTripMilliseconds: 42, sessionIsRunning: false)
    #expect(await channel.clockTimeRequests().isEmpty)

    _ = await sync.synchronizeClock(roundTripMilliseconds: 42, sessionIsRunning: true)
    let requests = await channel.clockTimeRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.0 == 1_800_000_000_123)
    #expect(requests.first?.1 == 42)
}

@Test func wakeSynchronizesClockWhileReconnectWaitsForTheDocumentedClockTriggers() async {
    let channel = LocaleTimeChannelFake()
    let sync = LocaleTimeSynchronizer(
        channel: channel,
        snapshotBuilder: LocaleTimeSnapshotBuilder(
            preferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en-US") },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Etc/UTC" },
            dateFormatForHourCycle: { _ in "h:mm a" }
        )
    )
    let settings = LocaleTimeSyncSettings(syncLocale: false, syncTimeZone: false, syncClockFormat: false)

    _ = await sync.synchronize(
        trigger: .wake,
        settings: settings,
        sessionIsRunning: true,
        roundTripMilliseconds: 17
    )
    #expect(await channel.clockTimeRequests().count == 1)

    _ = await sync.synchronize(
        trigger: .guestReconnected,
        settings: settings,
        sessionIsRunning: true,
        roundTripMilliseconds: 17
    )
    #expect(await channel.clockTimeRequests().count == 1)

    _ = await sync.synchronize(
        trigger: .periodic,
        settings: settings,
        sessionIsRunning: true,
        roundTripMilliseconds: 17
    )
    #expect(await channel.clockTimeRequests().count == 2)
}
