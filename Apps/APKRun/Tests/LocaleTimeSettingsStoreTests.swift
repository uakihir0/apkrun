import Combine
import Foundation
import RuntimeAPI
import XCTest

@MainActor
final class LocaleTimeSettingsStoreTests: XCTestCase {
    func testSettingsLoadFromRuntimeConfiguration() async {
        let store = LocaleTimeSettingsStore(
            readConfiguration: { Self.snapshot(syncLocale: false, syncTimeZone: true, syncClockFormat: false) },
            updateConfiguration: { _ in
                Self.snapshot(syncLocale: false, syncTimeZone: true, syncClockFormat: false)
            }
        )

        await store.refresh()

        XCTAssertTrue(store.isAvailable)
        XCTAssertFalse(store.syncLocale)
        XCTAssertTrue(store.syncTimeZone)
        XCTAssertFalse(store.syncClockFormat)
    }

    func testChangedToggleUsesRuntimeConfigurationMergePatch() async throws {
        let recorder = ConfigurationPatchRecorder()
        let store = LocaleTimeSettingsStore(
            readConfiguration: { Self.snapshot(syncLocale: true, syncTimeZone: true, syncClockFormat: true) },
            updateConfiguration: { patch in
                recorder.record(patch)
                return Self.snapshot(syncLocale: false, syncTimeZone: true, syncClockFormat: true)
            }
        )
        await store.refresh()

        store.syncLocale = false
        await store.waitForPendingUpdates()

        XCTAssertTrue(store.isAvailable)
        XCTAssertFalse(store.syncLocale)
        let patch = try XCTUnwrap(recorder.patch)
        guard case .object(let root) = patch.patch,
            case .object(let system)? = root["system"]
        else {
            XCTFail("Expected a nested system configuration patch.")
            return
        }
        XCTAssertEqual(system["syncLocale"], .bool(false))
    }

    func testUnavailableRuntimeDisablesSettings() async {
        let store = LocaleTimeSettingsStore(readConfiguration: nil, updateConfiguration: nil)

        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(store.isLoading)
    }

    func testConfigurationChangeEventRefreshesSettingsFromOtherClients() async {
        let source = ConfigurationSnapshotSource(
            snapshot: Self.snapshot(syncLocale: true, syncTimeZone: true, syncClockFormat: true)
        )
        let (events, continuation) = AsyncStream<EventEnvelope>.makeStream()
        let store = LocaleTimeSettingsStore(
            readConfiguration: { await source.read() },
            updateConfiguration: { _ in await source.read() },
            observeConfigurationChanges: { events }
        )
        await source.waitForReadCount(1)

        let changed = expectation(description: "Configuration event refreshes the locale setting")
        let subscription = store.$syncLocale
            .dropFirst()
            .sink { value in
                if !value {
                    changed.fulfill()
                }
            }
        await source.setSnapshot(
            Self.snapshot(syncLocale: false, syncTimeZone: true, syncClockFormat: true)
        )
        continuation.yield(
            EventEnvelope(
                topic: .runtime,
                seq: 1,
                time: Date(),
                payload: .runtime(.configurationChanged(keys: [LocaleTimeSettingsStore.Key.syncLocale]))
            )
        )

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertFalse(store.syncLocale)
        XCTAssertTrue(store.isAvailable)
        continuation.finish()
        withExtendedLifetime(subscription) {}
    }

    func testInitialReadStartsAfterConfigurationSubscription() async {
        let source = ConfigurationSnapshotSource(
            snapshot: Self.snapshot(syncLocale: true, syncTimeZone: true, syncClockFormat: true)
        )
        let sequence = ConfigurationReadSequence()
        let (events, continuation) = AsyncStream<EventEnvelope>.makeStream()
        let store = LocaleTimeSettingsStore(
            readConfiguration: {
                sequence.record("read")
                return await source.read()
            },
            updateConfiguration: { _ in await source.read() },
            observeConfigurationChanges: {
                sequence.record("subscribe")
                await source.setSnapshot(
                    Self.snapshot(syncLocale: false, syncTimeZone: true, syncClockFormat: true)
                )
                return events
            }
        )
        await source.waitForReadCount(1)

        XCTAssertEqual(sequence.events, ["subscribe", "read"])
        XCTAssertFalse(store.syncLocale)
        XCTAssertTrue(store.isAvailable)
        continuation.finish()
    }

    nonisolated private static func snapshot(
        syncLocale: Bool,
        syncTimeZone: Bool,
        syncClockFormat: Bool
    ) -> ConfigurationSnapshot {
        ConfigurationSnapshot(entries: [
            entry("system.syncLocale", value: syncLocale),
            entry("system.syncTimeZone", value: syncTimeZone),
            entry("system.syncClockFormat", value: syncClockFormat),
        ])
    }

    nonisolated private static func entry(_ key: String, value: Bool) -> ConfigurationEntry {
        ConfigurationEntry(
            key: key,
            value: .bool(value),
            defaultValue: .bool(true),
            isSet: value != true,
            applies: .live
        )
    }
}

private final class ConfigurationPatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPatch: ConfigurationPatch?

    var patch: ConfigurationPatch? {
        lock.lock()
        defer { lock.unlock() }
        return storedPatch
    }

    func record(_ patch: ConfigurationPatch) {
        lock.lock()
        storedPatch = patch
        lock.unlock()
    }
}

private final class ConfigurationReadSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }
}

private actor ConfigurationSnapshotSource {
    private var snapshot: ConfigurationSnapshot
    private var readCount = 0
    private var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(snapshot: ConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func read() -> ConfigurationSnapshot {
        readCount += 1
        let ready = readWaiters.filter { $0.count <= readCount }
        readWaiters.removeAll { $0.count <= readCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
        return snapshot
    }

    func setSnapshot(_ snapshot: ConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func waitForReadCount(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append((count, continuation))
        }
    }
}
