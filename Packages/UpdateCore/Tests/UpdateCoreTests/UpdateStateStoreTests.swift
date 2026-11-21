import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

// T0 of #38: Updates/state.json and Updates/history.jsonl (update-system.md §10).

private func makeStateRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateStateStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func stateRoundTripsAcrossStoreInstances() async throws {
    let root = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.helloupdate"))

    let store = UpdateStateStore(directory: root)
    await store.update(packageID) { state in
        state.lastCheckAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.nextCheckAt = Date(timeIntervalSince1970: 1_700_100_000)
        state.consecutiveFailures = 2
        state.cursor = ProviderCursor(type: .local, value: "42")
        state.phase = "available"
        state.candidate = PackageUpdateState.CandidateSummary(
            versionCode: 2, versionName: "2.0", provider: .local)
    }
    await store.flush()

    let reopened = UpdateStateStore(directory: root)
    let row = try #require(await reopened.state(for: packageID))
    #expect(row.phase == "available")
    #expect(row.consecutiveFailures == 2)
    #expect(row.cursor?.value == "42")
    #expect(row.candidate?.versionCode == 2)
    #expect(row.nextCheckAt == Date(timeIntervalSince1970: 1_700_100_000))
}

@Test func historyAppendsFiltersAndLimits() async throws {
    let root = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageA = try #require(PackageID(rawValue: "io.apkrun.fixture.helloupdate"))
    let packageB = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let store = UpdateStateStore(directory: root)

    let base = Date()
    for index in 0..<3 {
        try await store.appendHistory(
            UpdateHistoryEntry(
                time: base.addingTimeInterval(Double(index)),
                packageID: index == 1 ? packageB : packageA,
                from: 1,
                to: 2,
                provider: .local,
                trigger: .userInitiated,
                outcome: "available",
                failure: nil,
                phaseDurationsMs: [:]))
    }

    let all = try await store.history()
    #expect(all.count == 3)
    let onlyA = try await store.history(packageID: packageA)
    #expect(onlyA.count == 2)
    let newest = try await store.history(packageID: packageA, limit: 1)
    // JSONL round-trips at sub-second precision.
    #expect(
        try abs(#require(newest.first?.time).timeIntervalSince(base)) - 2 < 0.5)
}

@Test func deletingStateFileMakesPackageUntracked() async throws {
    let root = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.helloupdate"))

    let store = UpdateStateStore(directory: root)
    await store.update(packageID) { $0.lastCheckAt = Date() }
    await store.flush()
    #expect(await store.state(for: packageID) != nil)

    try FileManager.default.removeItem(at: root.appendingPathComponent("state.json"))
    let reopened = UpdateStateStore(directory: root)
    // Done-when: deleting state.json makes the package due again — no state row.
    #expect(await reopened.state(for: packageID) == nil)
}
