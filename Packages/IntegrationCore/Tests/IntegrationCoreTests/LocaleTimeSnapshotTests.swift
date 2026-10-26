import Foundation
import Testing

@testable import IntegrationCore

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    func append(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}

@Test func addsRegionAfterScriptWhenFirstPreferredLanguageHasNoRegion() {
    let builder = LocaleTimeSnapshotBuilder(
        preferredLanguages: { ["zh-Hans", "en"] },
        currentLocale: { Locale(identifier: "ja-JP") },
        resetTimeZone: {},
        currentTimeZoneIdentifier: { "Asia/Tokyo" },
        dateFormatForHourCycle: { _ in "HH:mm" }
    )

    let snapshot = builder.build()

    #expect(snapshot.languages == ["zh-Hans-JP", "en"])
}

@Test func insertsRegionBeforeLanguageExtensionsAndKeepsExistingRegion() {
    let builder = LocaleTimeSnapshotBuilder(
        preferredLanguages: { ["en-u-ca-gregory", "sr-Latn-RS", "fr"] },
        currentLocale: { Locale(identifier: "en-GB") },
        resetTimeZone: {},
        currentTimeZoneIdentifier: { "Europe/London" },
        dateFormatForHourCycle: { _ in "h:mm a" }
    )

    let snapshot = builder.build()

    #expect(snapshot.languages == ["en-GB-u-ca-gregory", "sr-Latn-RS", "fr"])
}

@Test func limitsPreferredLanguagesToEight() {
    let builder = LocaleTimeSnapshotBuilder(
        preferredLanguages: { ["en-GB", "fr", "de", "es", "it", "ja", "ko", "zh-Hans", "pt"] },
        currentLocale: { Locale(identifier: "ja-JP") },
        resetTimeZone: {},
        currentTimeZoneIdentifier: { "Asia/Tokyo" },
        dateFormatForHourCycle: { _ in nil }
    )

    let snapshot = builder.build()

    #expect(snapshot.languages == ["en-GB", "fr", "de", "es", "it", "ja", "ko", "zh-Hans"])
}

@Test func detectsClockFormatForSeveralLocales() {
    let cases: [(String, LocaleTimeSnapshot.ClockFormat)] = [
        ("en-US", .twelveHour),
        ("en-GB", .twentyFourHour),
        ("ja-JP", .twentyFourHour),
    ]

    for (identifier, expectedFormat) in cases {
        let locale = Locale(identifier: identifier)
        let builder = LocaleTimeSnapshotBuilder(
            preferredLanguages: { [identifier] },
            currentLocale: { locale },
            resetTimeZone: {},
            currentTimeZoneIdentifier: { "Etc/UTC" },
            dateFormatForHourCycle: {
                DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: $0)
            }
        )

        #expect(builder.build().clockFormat == expectedFormat)
    }
}

@Test func resetsSystemTimeZoneBeforeReadingCurrentZone() {
    let events = EventRecorder()
    let builder = LocaleTimeSnapshotBuilder(
        preferredLanguages: { ["en"] },
        currentLocale: { Locale(identifier: "en-US") },
        resetTimeZone: { events.append("reset") },
        currentTimeZoneIdentifier: {
            events.append("read")
            return "America/Los_Angeles"
        },
        dateFormatForHourCycle: { _ in "h:mm a" }
    )

    let snapshot = builder.build()

    #expect(events.events == ["reset", "read"])
    #expect(snapshot.timeZoneIdentifier == "America/Los_Angeles")
    #expect(snapshot.clockFormat == .twelveHour)
}
