import Combine
import Foundation
import RuntimeAPI
import RuntimeClient

@MainActor
final class LocaleTimeSettingsStore: ObservableObject {
    enum Key {
        static let syncLocale = "system.syncLocale"
        static let syncTimeZone = "system.syncTimeZone"
        static let syncClockFormat = "system.syncClockFormat"
    }

    @Published var syncLocale = true {
        didSet {
            persist(syncLocale, previousValue: oldValue, key: Key.syncLocale)
        }
    }

    @Published var syncTimeZone = true {
        didSet {
            persist(syncTimeZone, previousValue: oldValue, key: Key.syncTimeZone)
        }
    }

    @Published var syncClockFormat = true {
        didSet {
            persist(syncClockFormat, previousValue: oldValue, key: Key.syncClockFormat)
        }
    }

    @Published private(set) var isAvailable = false
    @Published private(set) var isLoading = true

    private let readConfiguration: (@Sendable () async throws -> ConfigurationSnapshot)?
    private let updateConfiguration: (@Sendable (ConfigurationPatch) async throws -> ConfigurationSnapshot)?
    private let observeConfigurationChanges: (@Sendable () async throws -> AsyncStream<EventEnvelope>)?
    private var isApplyingSnapshot = false
    private var pendingUpdate: Task<Void, Never>?
    private var configurationEventTask: Task<Void, Never>?

    convenience init() {
        guard let client = try? RuntimeControlClient(clientKind: .app) else {
            self.init(
                readConfiguration: nil,
                updateConfiguration: nil,
                observeConfigurationChanges: nil
            )
            return
        }
        self.init(
            readConfiguration: { try await client.configuration() },
            updateConfiguration: { try await client.updateConfiguration($0) },
            observeConfigurationChanges: { try await client.subscribe(to: .runtime) }
        )
    }

    init(
        readConfiguration: (@Sendable () async throws -> ConfigurationSnapshot)?,
        updateConfiguration: (@Sendable (ConfigurationPatch) async throws -> ConfigurationSnapshot)?,
        observeConfigurationChanges: (@Sendable () async throws -> AsyncStream<EventEnvelope>)? = nil
    ) {
        self.readConfiguration = readConfiguration
        self.updateConfiguration = updateConfiguration
        self.observeConfigurationChanges = observeConfigurationChanges
        guard readConfiguration != nil, updateConfiguration != nil else {
            isLoading = false
            return
        }
        configurationEventTask = Task { [weak self] in
            await self?.subscribeThenRefreshAndObserve()
        }
    }

    deinit {
        configurationEventTask?.cancel()
    }

    func refresh() async {
        guard let readConfiguration else {
            isLoading = false
            isAvailable = false
            return
        }
        isLoading = true
        do {
            let snapshot = try await readConfiguration()
            guard let values = Self.localeTimeValues(from: snapshot) else {
                isAvailable = false
                isLoading = false
                return
            }
            apply(values)
            isAvailable = true
        } catch {
            isAvailable = false
        }
        isLoading = false
    }

    func waitForPendingUpdates() async {
        await pendingUpdate?.value
    }

    private func subscribeThenRefreshAndObserve() async {
        let events: AsyncStream<EventEnvelope>?
        if let observeConfigurationChanges {
            do {
                events = try await observeConfigurationChanges()
            } catch {
                events = nil
            }
        } else {
            events = nil
        }
        await refresh()

        guard let events else { return }
        for await event in events {
            guard !Task.isCancelled else { return }
            switch event.payload {
            case .runtime(.configurationChanged(let keys))
            where keys.contains(where: Self.localeTimeKeys.contains):
                await refresh()
            case .resyncRequired(.runtime):
                await refresh()
            default:
                break
            }
        }
    }

    private func persist(_ value: Bool, previousValue: Bool, key: String) {
        guard !isApplyingSnapshot, value != previousValue,
            let updateConfiguration
        else {
            return
        }
        let previous = pendingUpdate
        pendingUpdate = Task { [weak self] in
            await previous?.value
            do {
                let snapshot = try await updateConfiguration(
                    ConfigurationPatch(
                        patch: .object([
                            "system": .object([String(key.dropFirst("system.".count)): .bool(value)])
                        ])
                    )
                )
                guard let self, let values = Self.localeTimeValues(from: snapshot) else { return }
                self.apply(values)
                self.isAvailable = true
            } catch {
                guard let self else { return }
                self.restore(previousValue, for: key)
                self.isAvailable = false
            }
        }
    }

    private func restore(_ value: Bool, for key: String) {
        isApplyingSnapshot = true
        switch key {
        case Key.syncLocale: syncLocale = value
        case Key.syncTimeZone: syncTimeZone = value
        case Key.syncClockFormat: syncClockFormat = value
        default: break
        }
        isApplyingSnapshot = false
    }

    private func apply(_ values: (syncLocale: Bool, syncTimeZone: Bool, syncClockFormat: Bool)) {
        isApplyingSnapshot = true
        syncLocale = values.syncLocale
        syncTimeZone = values.syncTimeZone
        syncClockFormat = values.syncClockFormat
        isApplyingSnapshot = false
    }

    private static func localeTimeValues(
        from snapshot: ConfigurationSnapshot
    ) -> (syncLocale: Bool, syncTimeZone: Bool, syncClockFormat: Bool)? {
        var values: [String: Bool] = [:]
        for entry in snapshot.entries where Self.localeTimeKeys.contains(entry.key) {
            guard case .bool(let value) = entry.value else { return nil }
            values[entry.key] = value
        }
        guard let syncLocale = values[Key.syncLocale],
            let syncTimeZone = values[Key.syncTimeZone],
            let syncClockFormat = values[Key.syncClockFormat]
        else {
            return nil
        }
        return (syncLocale, syncTimeZone, syncClockFormat)
    }

    private static let localeTimeKeys: Set<String> = [
        Key.syncLocale,
        Key.syncTimeZone,
        Key.syncClockFormat,
    ]
}
