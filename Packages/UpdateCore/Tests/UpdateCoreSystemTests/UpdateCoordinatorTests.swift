import APKStoreCore
import Foundation
import RuntimeAPI
import Testing

@testable import UpdateCore

// T1 of #38: the coordinator end to end over the committed local fixture repo
// (update-system.md §4.2, §5, §10; "up to date" with only 1, 0 never a
// candidate, notifyOnly posts once, state survives a restart).

actor CoordinatorChannel: StoreAgentChannel {
    nonisolated(unsafe) var capabilities: StoreCapabilities = [.install, .metadata]
    /// When set, `packageInfo` reports this versionCode instead of the
    /// installed one — an Android that has not caught up, for H1 tests.
    var reportedVersionCode: VersionCode?
    private var packages: [PackageID: StorePackageInfo] = [:]

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloUpdate",
            versionCode: request.versionCode,
            enabled: true,
            targetSDK: 37,
            minSDK: 29,
            signingDigests: request.signerDigests)
        packages[request.packageID] = info
        return info
    }

    func uninstall(_ package: PackageID, keepData _: Bool) async throws {
        packages[package] = nil
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        guard var info = packages[package] else { return nil }
        if let reportedVersionCode { info.versionCode = reportedVersionCode }
        return info
    }

    func listPackages(_: StorePackageFilter) async throws -> [StorePackageSummary] {
        []
    }

    /// §7.3 mechanism: RollbackManager. Only reachable while `.rollback` is
    /// in `capabilities`.
    func rollback(
        _ package: PackageID, from _: VersionCode, to: VersionCode
    ) async throws -> StoreRollbackResult {
        guard var info = packages[package] else { return .unavailable }
        info.versionCode = to
        packages[package] = info
        reportedVersionCode = nil
        return .rolledBack
    }
}

struct CoordinatorRuntime: StoreRuntimeAccess {
    let channel: CoordinatorChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private struct FailingHTTP: UpdateHTTPClient {
    func get(_: URL, headers _: [String: String]) async throws(UpdateFailure) -> HTTPResponse {
        throw UpdateFailure.providerUnreachable(reason: "no network in tests")
    }
}

private struct MemoryCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct NoCredentials: ProviderCredentials {
    func token(for _: String) -> String? { nil }
    func setToken(_: String?, for _: String) throws {}
}

actor RecordingNotifier: HostNotificationSink {
    private(set) var sent: [UpdateNotification] = []
    private(set) var waitingSent: [UpdateNotification] = []
    private(set) var refusedSent: [UpdateNotification] = []
    private(set) var rolledBackSent: [UpdateNotification] = []
    private(set) var keptSent: [UpdateNotification] = []
    func notifyUpdateAvailable(_ notification: UpdateNotification) async {
        sent.append(notification)
    }

    func notifyUpdateWaiting(_ notification: UpdateNotification) async {
        waitingSent.append(notification)
    }

    func notifyUpdateRefused(_ notification: UpdateNotification) async {
        refusedSent.append(notification)
    }

    func notifyUpdateRolledBack(_ notification: UpdateNotification) async {
        rolledBackSent.append(notification)
    }

    func notifyUpdateKeptAfterFailedHealthCheck(_ notification: UpdateNotification) async {
        keptSent.append(notification)
    }
}

let helloUpdateID = PackageID(rawValue: "io.apkrun.fixture.helloupdate")!

func fixtureRepo() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // UpdateCoreSystemTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UpdateCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Tests/Fixtures/update-repos/local")
}

private func makeContext(at root: URL) -> ProviderContext {
    ProviderContext(
        http: FailingHTTP(),
        cache: MemoryCache(root: root.appendingPathComponent("cache")),
        credentials: NoCredentials(),
        userInitiated: true)
}

private func makeStore(at root: URL, versionCode: VersionCode) -> PackageStore {
    PackageStore(
        packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: CoordinatorRuntime(channel: CoordinatorChannel()),
        inspector: { _ in
            APKFacts(
                packageID: helloUpdateID,
                versionCode: versionCode,
                versionName: "\(versionCode).0",
                splitName: nil,
                displayName: "HelloUpdate",
                minSDK: 29,
                targetSDK: 37,
                nativeABIs: ["arm64-v8a"])
        },
        importVerifier: PackageStore.legacyImportVerifier)
}

func makeTemporaryRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func localProviderRef(repo: URL) throws -> UpdateProviderRef {
    let bookmark = try repo.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    return UpdateProviderRef(
        type: .local,
        configuration: .local(path: repo.path, bookmark: bookmark.base64EncodedString()))
}

/// Installs V1 and attaches the local provider rooted at `repo`.
private func installV1(store: PackageStore, repo: URL) async throws -> PackageRecord {
    let apk = repo.appendingPathComponent("io.apkrun.fixture.helloupdate/1/app.apk")
    let preview = try await store.importPackage(files: [apk])
    let record = try await store.installImported(ticket: preview.ticket)
    try await store.setUpdatePolicy(
        for: record.packageId, authority: .apkrun, provider: localProviderRef(repo: repo))
    return record
}

@Test func coordinatorReportsV2AvailableFromLocalRepo() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())

    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    let coordinator = UpdateCoordinator(
        store: store, stateStore: stateStore, developerModeEnabled: { true })
    let outcome = await coordinator.check(
        record.packageId, trigger: .userInitiated, context: makeContext(at: root))

    guard case .available(let candidate) = outcome else {
        Issue.record("expected .available, got \(outcome)")
        return
    }
    #expect(candidate.declaredVersionCode == 2)
    // The local provider has no manifest; the version name stays undeclared.
    #expect(candidate.declaredVersionName == nil)
    #expect(candidate.artifacts.count == 1)
    #expect(await coordinator.phase(for: record.packageId) != nil)

    // The available phase survives a coordinator restart (state.json §10.1).
    let state = try #require(await stateStore.state(for: record.packageId))
    #expect(state.phase == "available")
    #expect(state.candidate?.versionCode == 2)
    let history = try await stateStore.history(packageID: record.packageId)
    #expect(history.last?.outcome == "available")
}

@Test func coordinatorReportsUpToDateWithOnlyV1() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A repo that holds version 1 only (and a bogus "0" directory that must
    // never become a candidate).
    let repo = root.appendingPathComponent("repo/io.apkrun.fixture.helloupdate")
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("1"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("0"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: fixtureRepo().appendingPathComponent("io.apkrun.fixture.helloupdate/1/app.apk"),
        to: repo.appendingPathComponent("1/app.apk"))
    try Data("not an apk".utf8).write(to: repo.appendingPathComponent("0/app.apk"))

    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: root.appendingPathComponent("repo"))

    let coordinator = UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        developerModeEnabled: { true })
    let outcome = await coordinator.check(
        record.packageId, trigger: .userInitiated, context: makeContext(at: root))
    #expect(outcome == .upToDate)
}

@Test func notifyOnlyPostsOneNotificationPerCandidate() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    try await store.setUpdateMode(for: record.packageId, mode: "notifyOnly")

    let notifier = RecordingNotifier()
    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    let coordinator = UpdateCoordinator(
        store: store, stateStore: stateStore,
        notifier: notifier, developerModeEnabled: { true })

    let first = await coordinator.check(
        record.packageId, trigger: .userInitiated, context: makeContext(at: root))
    guard case .available = first else {
        Issue.record("expected .available, got \(first)")
        return
    }
    #expect(await notifier.sent.count == 1)
    #expect(await notifier.sent.first?.versionCode == 2)

    // A second check on the same candidate does not notify again.
    _ = await coordinator.check(
        record.packageId, trigger: .scheduled, context: makeContext(at: root))
    #expect(await notifier.sent.count == 1)
}

// MARK: - #39 step 2: downloading

/// A provider whose `download` plays back a canned script, for retry tests.
actor ScriptedProvider: UpdateProvider {
    enum Step: Sendable {
        case copy(URL)
        case fail(UpdateFailure)
    }

    nonisolated let ref: UpdateProviderRef
    private var steps: [Step]
    private(set) var checkCalls = 0
    private(set) var downloadCalls = 0

    init(ref: UpdateProviderRef, steps: [Step]) {
        self.ref = ref
        self.steps = steps
    }

    func check(
        _: InstalledPackage, context _: ProviderContext
    ) async throws(UpdateFailure) -> UpdateCandidate? {
        checkCalls += 1
        return nil
    }

    func download(
        _ candidate: UpdateCandidate,
        to destination: DownloadDestination,
        context _: ProviderContext,
        progress _: @Sendable (DownloadProgress) -> Void
    ) async throws(UpdateFailure) -> PackageArtifact {
        downloadCalls += 1
        guard !steps.isEmpty else {
            throw UpdateFailure.downloadFailed(reason: "script exhausted")
        }
        switch steps.removeFirst() {
        case .fail(let failure):
            throw failure
        case .copy(let source):
            let target = destination.directory.appendingPathComponent(
                candidate.artifacts[0].url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                throw UpdateFailure.downloadFailed(reason: error.localizedDescription)
            }
            return .apk(target)
        }
    }
}

private actor SleepLog {
    private(set) var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { values.append(value) }
}

private func makeV2Candidate(record: PackageRecord, repo: URL) throws -> UpdateCandidate {
    let apk = repo.appendingPathComponent("io.apkrun.fixture.helloupdate/2/app.apk")
    return UpdateCandidate(
        packageID: record.packageId,
        provider: try localProviderRef(repo: repo),
        declaredVersionCode: 2,
        artifacts: [RemoteArtifact(url: apk, kind: .apk)],
        cursor: ProviderCursor(type: .local, value: "2"))
}

@Test func downloadWritesIncomingAndInspectVerifiesIt() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    let coordinator = UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        developerModeEnabled: { true },
        downloadRetrySleep: { _ in })

    let check = await coordinator.check(
        record.packageId, trigger: .userInitiated, context: makeContext(at: root))
    guard case .available(let candidate) = check else {
        Issue.record("expected .available, got \(check)")
        return
    }

    let outcome = await coordinator.download(
        record.packageId, candidate: candidate,
        context: makeContext(at: root), trigger: .userInitiated)
    guard case .downloaded(let downloaded) = outcome else {
        Issue.record("expected .downloaded, got \(outcome)")
        return
    }
    let incoming = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent(
            "Packages/io.apkrun.fixture.helloupdate/incoming/\(downloaded.ticket.uuidString)"),
        includingPropertiesForKeys: nil)
    #expect(incoming.map(\.lastPathComponent) == ["app.apk"])

    // inspect turns the raw download into a verified ticket (canonical names +
    // ticket.json + artifact.json); the verifier stub keeps the store's
    // versionCode, so the package ID and file list are what matter here.
    let preview = try await store.inspect(ticket: downloaded.ticket)
    #expect(preview.packageID == record.packageId)
    #expect(preview.artifactSet.files.map(\.name) == ["base.apk"])
    try await store.discardImport(ticket: downloaded.ticket)
}

@Test func downloadHashMismatchRetriesOnceThenFails() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    let repo = fixtureRepo()
    let candidate = try makeV2Candidate(record: record, repo: repo)
    var mismatched = candidate
    mismatched.artifacts = [
        RemoteArtifact(
            url: candidate.artifacts[0].url, kind: .apk,
            sha256: SHA256Digest(data: Data("not the apk".utf8)))
    ]
    let v2 = repo.appendingPathComponent("io.apkrun.fixture.helloupdate/2/app.apk")
    let provider = ScriptedProvider(
        ref: candidate.provider, steps: [.copy(v2), .copy(v2)])
    let sleeps = SleepLog()
    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    let coordinator = UpdateCoordinator(
        store: store, stateStore: stateStore,
        developerModeEnabled: { true },
        downloadRetrySleep: { await sleeps.add($0) },
        providerFactory: { _ in provider })

    let outcome = await coordinator.download(
        record.packageId, candidate: mismatched,
        context: makeContext(at: root), trigger: .userInitiated)
    guard case .failed(.hashMismatch) = outcome else {
        Issue.record("expected .failed(.hashMismatch), got \(outcome)")
        return
    }
    #expect(await provider.downloadCalls == 2)
    #expect(await sleeps.values.isEmpty)
    #expect(
        await coordinator.phase(for: record.packageId)
            == .completed(.skipped(.downloadFailed(.hashMismatch(artifact: "app.apk")))))
    let history = try await stateStore.history(packageID: record.packageId)
    #expect(history.last?.outcome == "skipped.downloadFailed")
    #expect(history.last?.failure == "update.hashMismatch")
    // The discarded download leaves no incoming set behind.
    let incomingRoot = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate/incoming")
    let leftovers =
        (try? FileManager.default.contentsOfDirectory(
            at: incomingRoot, includingPropertiesForKeys: nil)) ?? []
    #expect(leftovers.isEmpty)
}

@Test func downloadRetriesNetworkFailuresWithBackoff() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    let repo = fixtureRepo()
    let candidate = try makeV2Candidate(record: record, repo: repo)
    let v2 = repo.appendingPathComponent("io.apkrun.fixture.helloupdate/2/app.apk")
    let provider = ScriptedProvider(
        ref: candidate.provider,
        steps: [
            .fail(.providerUnreachable(reason: "down")),
            .fail(.downloadFailed(reason: "reset")),
            .copy(v2),
        ])
    let sleeps = SleepLog()
    let coordinator = UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        developerModeEnabled: { true },
        downloadRetrySleep: { await sleeps.add($0) },
        providerFactory: { _ in provider })

    let outcome = await coordinator.download(
        record.packageId, candidate: candidate,
        context: makeContext(at: root), trigger: .userInitiated)
    guard case .downloaded = outcome else {
        Issue.record("expected .downloaded, got \(outcome)")
        return
    }
    #expect(await provider.downloadCalls == 3)
    #expect(await sleeps.values == [10, 60])
}

@Test func downloadTooLargeRefusedBeforeDownload() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    var candidate = try makeV2Candidate(record: record, repo: fixtureRepo())
    candidate.artifacts[0].size = 9 * 1_024 * 1_024 * 1_024
    let provider = ScriptedProvider(ref: candidate.provider, steps: [])
    let coordinator = UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        developerModeEnabled: { true },
        downloadRetrySleep: { _ in },
        providerFactory: { _ in provider })

    let outcome = await coordinator.download(
        record.packageId, candidate: candidate,
        context: makeContext(at: root), trigger: .userInitiated)
    guard case .failed(.tooLarge) = outcome else {
        Issue.record("expected .failed(.tooLarge), got \(outcome)")
        return
    }
    #expect(await provider.downloadCalls == 0)
}

// MARK: - #39 step 3: validating

/// Knobs for a store whose inspector and verifier report scripted facts: the
/// versionCode an inspection returns and the signer digests the import
/// pipeline reports, so V1–V3 refusals are exercised deterministically.
private final class InspectKnobs: @unchecked Sendable {
    var versionCode: VersionCode = 1
    var signerDigests: [SHA256Digest] = []
}

private func makeKnobbedStore(
    at root: URL, knobs: InspectKnobs,
    channel: CoordinatorChannel = CoordinatorChannel()
) -> PackageStore {
    PackageStore(
        packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: CoordinatorRuntime(channel: channel),
        inspector: { _ in
            APKFacts(
                packageID: helloUpdateID,
                versionCode: knobs.versionCode,
                versionName: "\(knobs.versionCode).0",
                splitName: nil,
                displayName: "HelloUpdate",
                minSDK: 29,
                targetSDK: 37,
                nativeABIs: ["arm64-v8a"])
        },
        importVerifier: { staged, scratch, inspect in
            var verified = try await PackageStore.legacyImportVerifier(
                staged, scratch, inspect)
            verified.signerDigests = knobs.signerDigests
            return verified
        })
}

/// Downloads the v2 artifact through a scripted provider and returns the
/// `Downloaded` payload.
private func downloadV2(
    coordinator: UpdateCoordinator, record: PackageRecord
) async throws -> UpdateDownloadOutcome.Downloaded {
    let candidate = try makeV2Candidate(record: record, repo: fixtureRepo())
    let outcome = await coordinator.download(
        record.packageId, candidate: candidate,
        context: makeContext(at: fixtureRepo()), trigger: .userInitiated)
    guard case .downloaded(let downloaded) = outcome else {
        throw UpdateFailure.downloadFailed(reason: "expected .downloaded, got \(outcome)")
    }
    return downloaded
}

private func makeV2Coordinator(
    store: PackageStore, root: URL, provider: ScriptedProvider,
    notifier: (any HostNotificationSink)? = nil
) -> UpdateCoordinator {
    UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        notifier: notifier,
        developerModeEnabled: { true },
        downloadRetrySleep: { _ in },
        providerFactory: { _ in provider })
}

private func v2Provider(for record: PackageRecord) throws -> ScriptedProvider {
    let candidate = try makeV2Candidate(record: record, repo: fixtureRepo())
    return ScriptedProvider(
        ref: candidate.provider,
        steps: [.copy(candidate.artifacts[0].url)])
}

@Test func validateAcceptsV2AndWritesValidationJSON() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record))
    let downloaded = try await downloadV2(coordinator: coordinator, record: record)
    let candidate = try makeV2Candidate(record: record, repo: fixtureRepo())

    let outcome = await coordinator.validate(
        record.packageId, ticket: downloaded.ticket, candidate: candidate,
        trigger: .userInitiated)
    guard case .validated(let validated) = outcome else {
        Issue.record("expected .validated, got \(outcome)")
        return
    }
    let report = validated.report
    #expect(report.outcome == "accepted")
    #expect(report.checks.map(\.id) == ["V0", "V1", "V2", "V3", "V4", "V5", "V6"])
    #expect(report.checks.allSatisfy { $0.verdict == "passed" })
    // validation.json sits in the ticket's incoming set so `stage` carries it.
    let incoming = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate/incoming/\(downloaded.ticket.uuidString)/validation.json")
    #expect(FileManager.default.fileExists(atPath: incoming.path))
    try await store.discardImport(ticket: downloaded.ticket)
}

@Test func validateNotNewerRefusesAndDiscardsTicket() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()  // inspect reports the installed versionCode.
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record))
    let downloaded = try await downloadV2(coordinator: coordinator, record: record)
    let candidate = try makeV2Candidate(record: record, repo: fixtureRepo())

    let outcome = await coordinator.validate(
        record.packageId, ticket: downloaded.ticket, candidate: candidate,
        trigger: .userInitiated)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "notNewer(1)"))
    #expect(
        await coordinator.phase(for: record.packageId)
            == .completed(.skipped(.validationFailed(failure))))
    let incoming = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate/incoming/\(downloaded.ticket.uuidString)")
    #expect(!FileManager.default.fileExists(atPath: incoming.path))
}

@Test func validateDowngradeRefuses() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    knobs.versionCode = 2  // install "v1" reporting versionCode 2
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 1  // the download inspects as lower
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record))
    let downloaded = try await downloadV2(coordinator: coordinator, record: record)
    let candidate = try makeV2Candidate(record: record, repo: fixtureRepo())

    let outcome = await coordinator.validate(
        record.packageId, ticket: downloaded.ticket, candidate: candidate,
        trigger: .userInitiated)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "downgrade(installed: 2, candidate: 1)"))
}

@Test func validateSignerMismatchRefuses() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let installed = SHA256Digest(data: Data("installed-signer".utf8))
    knobs.signerDigests = [installed]
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.signerDigests = [SHA256Digest(data: Data("other-signer".utf8))]
    knobs.versionCode = 2
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record))
    let downloaded = try await downloadV2(coordinator: coordinator, record: record)
    let candidate = try makeV2Candidate(record: record, repo: fixtureRepo())

    let outcome = await coordinator.validate(
        record.packageId, ticket: downloaded.ticket, candidate: candidate,
        trigger: .userInitiated)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "signerMismatch(installed:1,candidate:1)"))
}

// MARK: - #39 step 4: stage → install → H1

/// A fake §7.5 runtime: reports whether the package is in use and counts the
/// times the coordinator brought the runtime up for an update.
/// A gate wired to the fake runtime (the second install test relies on
/// `inUse` blocking through GU2/3).
private func testGate(_ runtime: FakeUpdateRuntime) -> GentleUpdateGate {
    GentleUpdateGate(
        runtime: runtime,
        storeBusy: { _ in false },
        requiresDisplaySlot: { _ in false })
}

private final class FakeUpdateRuntime: UpdateRuntimeAccess, @unchecked Sendable {
    var inUse = false
    var ensureReadyCalls = 0
    var ensureReadyError: Error?

    var endedSessions: [(PackageID, UpdateSessionEndReason)] = []
    var reopened: [PackageID] = []

    var runtimeState: WireRuntimeState { .ready }
    func hasActiveUse(_: PackageID) async -> Bool { inUse }
    func ensureReady(_: UpdateStartReason) async throws {
        ensureReadyCalls += 1
        if let ensureReadyError { throw ensureReadyError }
    }
    func endSessions(for package: PackageID, reason: UpdateSessionEndReason) async {
        endedSessions.append((package, reason))
        inUse = false
    }
    func reopen(_ package: PackageID) async {
        reopened.append(package)
    }
}

/// Runs download → validate and returns the `Validated` payload plus the
/// candidate.
private func validatedV2(
    coordinator: UpdateCoordinator, record: PackageRecord
) async throws -> (UpdateCoordinator.UpdateValidationOutcome.Validated, UpdateCandidate) {
    let candidate = try makeV2Candidate(record: record, repo: fixtureRepo())
    let downloaded = try await downloadV2(coordinator: coordinator, record: record)
    let outcome = await coordinator.validate(
        record.packageId, ticket: downloaded.ticket, candidate: candidate,
        trigger: .userInitiated)
    guard case .validated(let validated) = outcome else {
        throw UpdateFailure.downloadFailed(reason: "expected .validated, got \(outcome)")
    }
    return (validated, candidate)
}

extension CoordinatorChannel {
    fileprivate func set(reportedVersionCode: VersionCode) {
        self.reportedVersionCode = reportedVersionCode
    }

    fileprivate func set(capabilities: StoreCapabilities) {
        self.capabilities = capabilities
    }
}

@Test func installStagesInstallsAndConfirmsH1() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record))
    let (validated, candidate) = try await validatedV2(
        coordinator: coordinator, record: record)
    let runtime = FakeUpdateRuntime()

    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .userInitiated, runtime: runtime, gate: testGate(runtime))
    guard case .installed(let from, let to) = outcome else {
        Issue.record("expected .installed, got \(outcome)")
        return
    }
    #expect(from == 1 && to == 2)
    #expect(runtime.ensureReadyCalls == 1)
    #expect(
        await coordinator.phase(for: record.packageId)
            == .completed(.updated(from: 1, to: 2)))
    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    let history = try await stateStore.history(packageID: record.packageId)
    #expect(history.last?.outcome == "updated")
    // The promotion emptied staged/ and the record moved to versionCode 2.
    let staged = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate/staged/artifact.json")
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    let current = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate/current/artifact.json")
    #expect(FileManager.default.fileExists(atPath: current.path))
    let records = try await store.listManagedPackages()
    #expect(records.first?.versionCode == 2)
    #expect(records.first?.artifacts.previous?.versionCode == 1)
}

@Test func installStaysStagedWhileInUse() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record))
    let (validated, candidate) = try await validatedV2(
        coordinator: coordinator, record: record)
    let runtime = FakeUpdateRuntime()
    runtime.inUse = true

    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .userInitiated, runtime: runtime, gate: testGate(runtime))
    guard case .staged = outcome else {
        Issue.record("expected .staged, got \(outcome)")
        return
    }
    #expect(runtime.ensureReadyCalls == 0)
    #expect(await coordinator.phase(for: record.packageId) == .staged)
    // The set stays in staged/, validation.json riding along.
    let staged = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate/staged")
    #expect(
        FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("artifact.json").path))
    #expect(
        FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("validation.json").path))
    #expect(
        FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("base.apk").path))
    try await store.discardStaged(packageID: record.packageId)
}

@Test func installH1TimeoutKeepsUpdate() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let channel = CoordinatorChannel()
    let store = makeKnobbedStore(at: root, knobs: knobs, channel: channel)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let coordinator = UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        developerModeEnabled: { true },
        downloadRetrySleep: { _ in },
        providerFactory: { ref in ScriptedProvider(ref: ref, steps: []) },
        healthCheckBudget: .milliseconds(1),
        healthCheckTickSleep: {})
    // The provider download goes through the coordinator's download only in
    // the helper; drive the ticket by hand here to keep Android's report stale.
    let (validated, candidate) = try await {
        let ticket = try await store.beginDownloadTicket(for: record.packageId)
        let v2 = fixtureRepo().appendingPathComponent(
            "io.apkrun.fixture.helloupdate/2/app.apk")
        try FileManager.default.copyItem(
            at: v2,
            to: ticket.directory.appendingPathComponent("app.apk"))
        let outcome = await coordinator.validate(
            record.packageId, ticket: ticket.ticket,
            candidate: try makeV2Candidate(record: record, repo: fixtureRepo()),
            trigger: .userInitiated)
        guard case .validated(let validated) = outcome else {
            throw UpdateFailure.downloadFailed(
                reason: "expected .validated, got \(outcome)")
        }
        return (validated, try makeV2Candidate(record: record, repo: fixtureRepo()))
    }()
    // Android keeps reporting the old versionCode (a lagging PackageManager).
    await channel.set(reportedVersionCode: 1)

    let runtime = FakeUpdateRuntime()
    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .userInitiated, runtime: runtime, gate: testGate(runtime))
    guard case .keptAfterFailedHealthCheck(let failure) = outcome else {
        Issue.record("expected .keptAfterFailedHealthCheck, got \(outcome)")
        return
    }
    #expect(failure.errorCode == "update.healthCheckFailed")
    #expect(
        await coordinator.phase(for: record.packageId)
            == .completed(
                .keptAfterFailedHealthCheck(reason: .healthCheckFailed(failure))))
    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    let history = try await stateStore.history(packageID: record.packageId)
    #expect(history.last?.outcome == "keptAfterFailedHealthCheck")
}

@Test func checkOnManualPackageNeverCallsTheProvider() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    // A plain install keeps the `manual` authority (installV1 would
    // re-author it .apkrun via setUpdatePolicy).
    let apk = fixtureRepo().appendingPathComponent("io.apkrun.fixture.helloupdate/1/app.apk")
    let preview = try await store.importPackage(files: [apk])
    let record = try await store.installImported(ticket: preview.ticket)
    #expect(record.updateAuthority == .manual)

    let provider = ScriptedProvider(
        ref: try #require(record.updateProvider ?? localRef()), steps: [])
    let coordinator = makeV2Coordinator(store: store, root: root, provider: provider)
    let outcome = await coordinator.check(
        record.packageId, trigger: .scheduled, context: makeContext(at: fixtureRepo()))

    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure.errorCode == "update.authorityDoesNotAllowUpdates")
    #expect(await provider.checkCalls == 0)
}

private func localRef() -> UpdateProviderRef? {
    UpdateProviderRef(
        type: .local, configuration: .local(path: "/tmp/repo", bookmark: ""))
}

// MARK: - #41 §7.3 Update Now, §7.4 seven-day notice

@Test func updateNowEndsTheSessionInstallsAndReopens() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record))
    let (validated, candidate) = try await validatedV2(
        coordinator: coordinator, record: record)
    let runtime = FakeUpdateRuntime()
    runtime.inUse = true

    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .userInitiated, runtime: runtime, gate: testGate(runtime),
        closeRunningApp: true)
    guard case .installed = outcome else {
        Issue.record("expected .installed, got \(outcome)")
        return
    }
    // §7.3: the open session ended with `.updating` before the gate
    // evaluated (GU2/GU3 saw it closed), and the app reopened after the
    // successful install.
    #expect(runtime.endedSessions.map(\.1) == [.updating])
    #expect(runtime.reopened == [record.packageId])
}

@Test func overdueStagedUpdateNotifiesOnce() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let notifier = RecordingNotifier()
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record),
        notifier: notifier)
    let (validated, candidate) = try await validatedV2(
        coordinator: coordinator, record: record)
    let runtime = FakeUpdateRuntime()
    runtime.inUse = true

    // Stage the update while the app stays open (gate closed).
    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .scheduled, runtime: runtime, gate: testGate(runtime))
    guard case .staged = outcome else {
        Issue.record("expected .staged, got \(outcome)")
        return
    }

    // §7.4: under 7 days no notice; past it, exactly one.
    let now = Date()
    await coordinator.notifyOverdueStagedUpdates(now: now)
    #expect(await notifier.waitingSent.isEmpty)
    let weekLater = now.addingTimeInterval(8 * 24 * 3600)
    await coordinator.notifyOverdueStagedUpdates(now: weekLater)
    let waiting = await notifier.waitingSent
    #expect(waiting.count == 1)
    #expect(waiting.first?.packageID == record.packageId)
    #expect(waiting.first?.versionCode == 2)
    await coordinator.notifyOverdueStagedUpdates(
        now: weekLater.addingTimeInterval(3600))
    #expect(await notifier.waitingSent.count == 1)
}

// MARK: - #44 §8.3 health-check outcomes, §8.4 skipped versions

// §8.3 fail+autoRollback: the store rolls back to `previous/`, the failed
// version lands in `failed/2/`, §8.4 adds it to `skippedVersions`, and the
// rolledBack notification fires.
@Test func failedHealthCheckRollsBackAndSkipsVersion() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = CoordinatorChannel()
    await channel.set(capabilities: [.install, .metadata, .rollback])
    let notifier = RecordingNotifier()
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs, channel: channel)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record),
        notifier: notifier)
    let (validated, candidate) = try await validatedV2(
        coordinator: coordinator, record: record)
    await channel.set(reportedVersionCode: 1)
    let runtime = FakeUpdateRuntime()

    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .userInitiated, runtime: runtime, gate: testGate(runtime))
    guard case .rolledBack = outcome else {
        Issue.record("expected .rolledBack, got \(outcome)")
        return
    }

    let restored = try #require(
        await store.listManagedPackages().first(where: { $0.packageId == record.packageId }))
    #expect(restored.versionCode == 1)
    let directory = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate")
    #expect(
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("failed/2/artifact.json").path))
    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    #expect(try await stateStore.state(for: record.packageId)?.skippedVersions == [2])
    let history = try await stateStore.history(packageID: record.packageId)
    #expect(history.last?.outcome == "rolledBack")
    #expect(await notifier.rolledBackSent.count == 1)
}

// §8.3 fail+no mechanism: keeps the broken update installed and posts the
// kept notification instead of rolling back.
@Test func failedHealthCheckWithoutMechanismKeeps() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = CoordinatorChannel()
    let notifier = RecordingNotifier()
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs, channel: channel)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record),
        notifier: notifier)
    let (validated, candidate) = try await validatedV2(
        coordinator: coordinator, record: record)
    await channel.set(reportedVersionCode: 1)
    let runtime = FakeUpdateRuntime()

    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .userInitiated, runtime: runtime, gate: testGate(runtime))
    guard case .keptAfterFailedHealthCheck = outcome else {
        Issue.record("expected .keptAfterFailedHealthCheck, got \(outcome)")
        return
    }
    #expect(await notifier.keptSent.count == 1)
    let history = try await UpdateStateStore(
        directory: root.appendingPathComponent("Updates")
    )
    .history(packageID: record.packageId)
    #expect(history.last?.outcome == "keptAfterFailedHealthCheck")
    let records = try await store.listManagedPackages()
    #expect(records.first?.versionCode == 2)
}

// §8.3 fail+autoRollback off: even with a working rollback mechanism the
// update stays installed and the notification offers the Roll Back action.
@Test func failedHealthCheckAutoRollbackOffKeeps() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = CoordinatorChannel()
    await channel.set(capabilities: [.install, .metadata, .rollback])
    let notifier = RecordingNotifier()
    let knobs = InspectKnobs()
    let store = makeKnobbedStore(at: root, knobs: knobs, channel: channel)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    knobs.versionCode = 2
    // update.autoRollback=false (§8.3).
    let directory = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate")
    try Data(#"{"update":{"autoRollback":"false"}}"#.utf8)
        .write(to: directory.appendingPathComponent("settings.json"))
    let coordinator = makeV2Coordinator(
        store: store, root: root, provider: try v2Provider(for: record),
        notifier: notifier)
    let (validated, candidate) = try await validatedV2(
        coordinator: coordinator, record: record)
    await channel.set(reportedVersionCode: 1)
    let runtime = FakeUpdateRuntime()

    let outcome = await coordinator.install(
        record.packageId, validated: validated, candidate: candidate,
        trigger: .userInitiated, runtime: runtime, gate: testGate(runtime))
    guard case .keptAfterFailedHealthCheck = outcome else {
        Issue.record("expected .keptAfterFailedHealthCheck, got \(outcome)")
        return
    }
    #expect(await notifier.keptSent.count == 1)
    let records = try await store.listManagedPackages()
    #expect(records.first?.versionCode == 2)
}
