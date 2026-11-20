import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

// T1 of #75: UpdateScheduler — §3.3 triggers (start, wake delay, launch),
// §3.4 network suppression, earliestWakeAt for the §2.4 exit rule.

private final class CountingProvider: UpdateProvider, @unchecked Sendable {
    var checked: [PackageID] = []
    var candidate: UpdateCandidate?

    var ref: UpdateProviderRef {
        UpdateProviderRef(
            type: .local, configuration: .local(path: "scheduler-test", bookmark: ""))
    }

    func check(_ package: InstalledPackage, context _: ProviderContext)
        async throws(UpdateFailure) -> UpdateCandidate?
    {
        checked.append(package.id)
        return candidate
    }

    func download(
        _: UpdateCandidate, to _: DownloadDestination, context _: ProviderContext,
        progress _: @Sendable (DownloadProgress) -> Void
    ) async throws(UpdateFailure) -> PackageArtifact {
        throw .providerUnreachable(reason: "not used by these tests")
    }
}

private struct IdleHTTP: UpdateHTTPClient {
    func get(_: URL, headers _: [String: String]) async throws(UpdateFailure) -> HTTPResponse {
        throw UpdateFailure.providerUnreachable(reason: "no network in tests")
    }

    func download(
        _: URL, headers _: [String: String], into file: URL, byteLimit _: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse {
        throw UpdateFailure.providerUnreachable(reason: "no network in tests")
    }
}

private struct SchedulerCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct SchedulerCredentials: ProviderCredentials {
    func token(for _: String) -> String? { nil }
    func setToken(_: String?, for _: String) throws {}
}

private final class Sleeps: @unchecked Sendable {
    var targets: [Date] = []
}

/// A fixture: store with V1 installed under the `apkrun` authority and the
/// local provider attached, plus the pieces a scheduler needs.
private struct SchedulerFixture {
    let root: URL
    let store: PackageStore
    let stateStore: UpdateStateStore
    let provider: CountingProvider
    let sleeps: Sleeps
    let scheduler: UpdateScheduler
    let record: PackageRecord

    static func make(
        networkSatisfied: Bool = true
    ) async throws -> SchedulerFixture {
        let root = try makeTemporaryRoot()
        let store = PackageStore(
            packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
            runtimeAccess: CoordinatorRuntime(channel: CoordinatorChannel()),
            inspector: { _ in
                APKFacts(
                    packageID: helloUpdateID,
                    versionCode: 1,
                    versionName: "1.0",
                    splitName: nil,
                    displayName: "HelloUpdate",
                    minSDK: 29,
                    targetSDK: 37,
                    nativeABIs: ["arm64-v8a"])
            },
            importVerifier: PackageStore.legacyImportVerifier)
        try await store.open()
        let repo = fixtureRepo()
        let apk = repo.appendingPathComponent("io.apkrun.fixture.helloupdate/1/app.apk")
        let preview = try await store.importPackage(files: [apk])
        let record = try await store.installImported(ticket: preview.ticket)
        let bookmark = try repo.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await store.setUpdatePolicy(
            for: record.packageId, authority: .apkrun,
            provider: UpdateProviderRef(
                type: .local,
                configuration: .local(
                    path: repo.path, bookmark: bookmark.base64EncodedString())))

        let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
        let provider = CountingProvider()
        let coordinator = UpdateCoordinator(
            store: store, stateStore: stateStore,
            developerModeEnabled: { true },
            providerFactory: { _ in provider })
        let sleeps = Sleeps()
        let scheduler = UpdateScheduler(
            coordinator: coordinator,
            stateStore: stateStore,
            store: store,
            contextProvider: {
                ProviderContext(
                    http: IdleHTTP(),
                    cache: SchedulerCache(
                        root: root.appendingPathComponent("cache")),
                    credentials: SchedulerCredentials())
            },
            runtimeProvider: { nil },
            gateProvider: { nil },
            sleepUntil: { target in sleeps.targets.append(target) },
            networkSatisfied: { networkSatisfied })
        return SchedulerFixture(
            root: root, store: store, stateStore: stateStore,
            provider: provider, sleeps: sleeps, scheduler: scheduler, record: record)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Polls a predicate — scheduled checks run on unstructured Tasks.
private func waitUntil(
    _ body: @escaping @Sendable () -> Bool, timeout: Duration = .seconds(5)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if body() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return body()
}

@Test func schedulerRunsDueCheckOnStart() async throws {
    let fixture = try await SchedulerFixture.make()
    defer { fixture.cleanup() }
    let past = Date().addingTimeInterval(-60)
    await fixture.stateStore.update(fixture.record.packageId) {
        $0.lastCheckAt = past
        $0.nextCheckAt = past
    }

    await fixture.scheduler.start()
    defer { Task { await fixture.scheduler.stop() } }

    #expect(await waitUntil { fixture.provider.checked.count >= 1 })
    // The run completed: the due entry advanced to a future nextCheckAt.
    let state = await fixture.stateStore.state(for: fixture.record.packageId)
    #expect(state?.nextCheckAt != nil && state!.nextCheckAt! > past)
}

@Test func earliestWakeAtPicksEarliestDuePackage() async throws {
    let fixture = try await SchedulerFixture.make()
    defer { fixture.cleanup() }
    #expect(await fixture.scheduler.earliestWakeAt() == nil)

    let due = Date().addingTimeInterval(600)
    await fixture.stateStore.update(fixture.record.packageId) {
        $0.nextCheckAt = due
    }
    #expect(await fixture.scheduler.earliestWakeAt() == due)
}

@Test func unsatisfiedNetworkSuppressesDueChecks() async throws {
    let fixture = try await SchedulerFixture.make(networkSatisfied: false)
    defer { fixture.cleanup() }
    let past = Date().addingTimeInterval(-60)
    await fixture.stateStore.update(fixture.record.packageId) {
        $0.nextCheckAt = past
    }

    #expect(await fixture.scheduler.runDueChecks(trigger: .scheduled) == 0)
    #expect(fixture.provider.checked.isEmpty)
}

@Test func launchedPackageSchedulesCheckOnlyWhenDue() async throws {
    let fixture = try await SchedulerFixture.make()
    defer { fixture.cleanup() }

    // Not due (nextCheckAt in the future): the 30 s delay fires, then
    // nothing runs.
    await fixture.stateStore.update(fixture.record.packageId) {
        $0.nextCheckAt = Date().addingTimeInterval(3600)
    }
    await fixture.scheduler.noteLaunched(fixture.record.packageId)
    #expect(await waitUntil { fixture.sleeps.targets.count == 1 })
    #expect(
        await waitUntil(
            { fixture.provider.checked.isEmpty },
            timeout: .milliseconds(300)))

    // Due: the same path runs the check.
    let past = Date().addingTimeInterval(-60)
    await fixture.stateStore.update(fixture.record.packageId) {
        $0.nextCheckAt = past
    }
    await fixture.scheduler.noteLaunched(fixture.record.packageId)
    #expect(await waitUntil { fixture.provider.checked.count >= 1 })
}

@Test func systemWakeDelaysDueChecksByWakeDelay() async throws {
    let fixture = try await SchedulerFixture.make()
    defer { fixture.cleanup() }
    let before = Date()
    await fixture.scheduler.noteSystemWake()
    #expect(await waitUntil { fixture.sleeps.targets.count >= 1 })
    // §3.3: the due sweep waits for the network to come back up.
    let target = try #require(fixture.sleeps.targets.first)
    #expect(target.timeIntervalSince(before) >= 110)
}
