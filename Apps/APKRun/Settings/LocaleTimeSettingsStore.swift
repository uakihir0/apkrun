import Combine
import Foundation

@MainActor
final class LocaleTimeSettingsStore: ObservableObject {
    enum Key {
        static let syncLocale = "system.syncLocale"
        static let syncTimeZone = "system.syncTimeZone"
        static let syncClockFormat = "system.syncClockFormat"
    }

    static let suiteName = "io.apkrun"
    static let changedNotification = Notification.Name(
        "io.apkrun.system.localeTimeSettingsDidChange"
    )

    private let defaults: UserDefaults?
    private let postChangeNotification: (Notification.Name) -> Void

    @Published var syncLocale: Bool {
        didSet { persist(syncLocale, forKey: Key.syncLocale) }
    }

    @Published var syncTimeZone: Bool {
        didSet { persist(syncTimeZone, forKey: Key.syncTimeZone) }
    }

    @Published var syncClockFormat: Bool {
        didSet { persist(syncClockFormat, forKey: Key.syncClockFormat) }
    }

    var isAvailable: Bool { defaults != nil }

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: LocaleTimeSettingsStore.suiteName),
        postChangeNotification: ((Notification.Name) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.postChangeNotification =
            postChangeNotification ?? { name in
                DistributedNotificationCenter.default().postNotificationName(
                    name,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        syncLocale = defaults?.object(forKey: Key.syncLocale) as? Bool ?? true
        syncTimeZone = defaults?.object(forKey: Key.syncTimeZone) as? Bool ?? true
        syncClockFormat = defaults?.object(forKey: Key.syncClockFormat) as? Bool ?? true

        for key in [Key.syncLocale, Key.syncTimeZone, Key.syncClockFormat]
        where defaults?.object(forKey: key) == nil {
            defaults?.set(true, forKey: key)
        }
    }

    private func persist(_ value: Bool, forKey key: String) {
        guard let defaults else { return }
        let currentValue = defaults.object(forKey: key) as? Bool ?? true
        guard currentValue != value else { return }

        defaults.set(value, forKey: key)
        postChangeNotification(Self.changedNotification)
    }
}
