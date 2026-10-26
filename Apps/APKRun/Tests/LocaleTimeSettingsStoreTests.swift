import Foundation
import XCTest

@MainActor
final class LocaleTimeSettingsStoreTests: XCTestCase {
    func testMissingValuesDefaultToTrueAndArePersisted() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LocaleTimeSettingsStore(
            defaults: defaults,
            postChangeNotification: { _ in
                XCTFail("Initializing defaults must not notify apkrund.")
            })

        XCTAssertTrue(store.isAvailable)
        XCTAssertTrue(store.syncLocale)
        XCTAssertTrue(store.syncTimeZone)
        XCTAssertTrue(store.syncClockFormat)
        XCTAssertEqual(defaults.object(forKey: LocaleTimeSettingsStore.Key.syncLocale) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: LocaleTimeSettingsStore.Key.syncTimeZone) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: LocaleTimeSettingsStore.Key.syncClockFormat) as? Bool, true)
    }

    func testEachChangedValuePersistsAndOnlyChangesNotify() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var notifications: [Notification.Name] = []

        let store = LocaleTimeSettingsStore(defaults: defaults) { name in
            notifications.append(name)
        }

        store.syncLocale = true
        store.syncLocale = false
        store.syncLocale = false
        store.syncTimeZone = false
        store.syncClockFormat = false

        XCTAssertEqual(defaults.bool(forKey: LocaleTimeSettingsStore.Key.syncLocale), false)
        XCTAssertEqual(defaults.bool(forKey: LocaleTimeSettingsStore.Key.syncTimeZone), false)
        XCTAssertEqual(defaults.bool(forKey: LocaleTimeSettingsStore.Key.syncClockFormat), false)
        XCTAssertEqual(
            notifications,
            Array(repeating: LocaleTimeSettingsStore.changedNotification, count: 3)
        )
    }

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suiteName = "io.apkrun.settings-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
