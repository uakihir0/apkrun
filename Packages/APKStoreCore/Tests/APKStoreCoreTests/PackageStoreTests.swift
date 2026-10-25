import Darwin
import Foundation
import Testing

@testable import APKStoreCore

private struct InjectedStoreCrash: Error {}
private enum SimulatedGuestFailure: Error {
    case installFailedAfterCommit
    case installFailedBeforeCommit
    case uninstallFailed
    case queryUnavailable
}

private actor UninstallBoundaryProbe {
    private(set) var observedGuestRequest = false
    private(set) var wasEntered = false
    private(set) var sessionEndWasEntered = false

    func record(guestRequestPresent: Bool) {
        wasEntered = true
        observedGuestRequest = guestRequestPresent
    }

    func recordSessionEnd() {
        sessionEndWasEntered = true
    }
}

private actor MutationBoundaryProbe {
    private(set) var wasEntered = false
    private(set) var sawTransactionBegin = false
    private(set) var sawGuestRequest = false
    private(set) var packageInfoQueryCount = 0

    func record(
        sawTransactionBegin: Bool = false,
        sawGuestRequest: Bool = false,
        packageInfoQueryCount: Int = 0
    ) {
        wasEntered = true
        self.sawTransactionBegin = sawTransactionBegin
        self.sawGuestRequest = sawGuestRequest
        self.packageInfoQueryCount = packageInfoQueryCount
    }
}

private actor FakeStoreChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata, .downgradeReinstall]

    private var packages: [PackageID: StorePackageInfo] = [:]
    private(set) var lastKeepData: Bool?
    private(set) var installCallCount = 0
    private(set) var lastInstallRequest: StoreInstallRequest?
    private(set) var packageInfoCallCount = 0
    private var installThrowsAfterCommit = false
    private var installThrowsBeforeCommit = false
    private var queryThrows = false
    private var queryUnavailableAfterInstall = false
    private var uninstallThrowsAfterRemoval = false
    private var pauseNextUninstall = false
    private var uninstallStarted = false
    private var uninstallStartWaiter: CheckedContinuation<Void, Never>?
    private var uninstallReleaseWaiter: CheckedContinuation<Void, Never>?

    func configureInstallFailureAfterCommit(queryUnavailable: Bool) {
        installThrowsAfterCommit = true
        queryUnavailableAfterInstall = queryUnavailable
    }

    func seed(_ info: StorePackageInfo) {
        packages[info.packageID] = info
    }

    func configureInstallFailureBeforeCommit() {
        installThrowsBeforeCommit = true
    }

    func resetInstallCallCount() {
        installCallCount = 0
    }

    func resetPackageInfoCallCount() {
        packageInfoCallCount = 0
    }

    func makeQueriesAvailable() {
        queryThrows = false
    }

    func configureInstallSuccess() {
        installThrowsAfterCommit = false
        installThrowsBeforeCommit = false
        queryUnavailableAfterInstall = false
        queryThrows = false
    }

    func configureUninstallFailureAfterRemoval() {
        uninstallThrowsAfterRemoval = true
    }

    func pauseUninstall() {
        pauseNextUninstall = true
        uninstallStarted = false
    }

    func waitForUninstallStart() async {
        guard !uninstallStarted else { return }
        await withCheckedContinuation { continuation in
            uninstallStartWaiter = continuation
        }
    }

    func continueUninstall() {
        uninstallReleaseWaiter?.resume()
        uninstallReleaseWaiter = nil
    }

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        installCallCount += 1
        lastInstallRequest = request
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        if installThrowsBeforeCommit {
            throw SimulatedGuestFailure.installFailedBeforeCommit
        }
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "Example",
            versionCode: request.versionCode,
            versionName: "1.0",
            enabled: true,
            launchableComponent: "\(request.packageID.rawValue)/.MainActivity",
            installerPackage: PackageID(rawValue: "io.apkrun.store"),
            firstInstallTime: Date(timeIntervalSince1970: 100),
            lastUpdateTime: Date(timeIntervalSince1970: 200),
            targetSDK: 35,
            minSDK: 24
        )
        packages[request.packageID] = info
        if installThrowsAfterCommit {
            queryThrows = queryUnavailableAfterInstall
            throw SimulatedGuestFailure.installFailedAfterCommit
        }
        return info
    }

    func uninstall(_ package: PackageID, keepData: Bool) async throws {
        lastKeepData = keepData
        if pauseNextUninstall {
            pauseNextUninstall = false
            uninstallStarted = true
            uninstallStartWaiter?.resume()
            uninstallStartWaiter = nil
            await withCheckedContinuation { continuation in
                uninstallReleaseWaiter = continuation
            }
        }
        packages[package] = nil
        if uninstallThrowsAfterRemoval {
            throw SimulatedGuestFailure.uninstallFailed
        }
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        packageInfoCallCount += 1
        if queryThrows {
            throw SimulatedGuestFailure.queryUnavailable
        }
        return packages[package]
    }

    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        packages.values.map {
            StorePackageSummary(
                packageID: $0.packageID,
                displayName: $0.displayName,
                versionCode: $0.versionCode,
                launchable: $0.launchableComponent != nil,
                userInstalled: true
            )
        }
    }
}

private actor FakeStoreRuntime: StoreRuntimeAccess {
    private let channel: FakeStoreChannel
    private var generation: UUID
    private let acquisitionGate: StoreAgentAcquisitionGate?

    init(
        channel: FakeStoreChannel,
        generation: UUID = UUID(),
        acquisitionGate: StoreAgentAcquisitionGate? = nil
    ) {
        self.channel = channel
        self.generation = generation
        self.acquisitionGate = acquisitionGate
    }

    func setGeneration(_ generation: UUID) {
        self.generation = generation
    }

    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        await acquisitionGate?.beforeChannelAcquisition()
        try Task.checkCancellation()
        return try await body(channel)
    }

    func userdataGeneration() async -> UUID? {
        generation
    }
}

private actor StoreAgentAcquisitionGate {
    private var callsUntilPause: Int?
    private var isPaused = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?

    func pause(after calls: Int) {
        callsUntilPause = calls
    }

    func beforeChannelAcquisition() async {
        guard let callsUntilPause else { return }
        if callsUntilPause > 1 {
            self.callsUntilPause = callsUntilPause - 1
            return
        }

        self.callsUntilPause = nil
        isPaused = true
        pauseWaiter?.resume()
        pauseWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
        isPaused = false
    }
}

private actor CompletionFlag {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

@Test func packageStoreImportsPrivateCopiesAndComputesCanonicalDigest() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)

    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        inspector: { _ in facts() }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])

    #expect(try await store.packageIDForImportTicket(preview.ticket) == preview.packageID)
    let packages = try await store.listManagedPackages()
    #expect(packages.isEmpty)
    #expect(preview.packageID.rawValue == "io.apkrun.fixture.hellotext")
    #expect(preview.versionCode == 7)
    #expect(preview.artifactSet.files.map(\.name) == ["base.apk"])
    #expect(
        preview.artifactSet.setDigest
            == (try ArtifactSet.computeSetDigest(for: preview.artifactSet.files))
    )

    let storedAPK =
        temporary
        .appendingPathComponent("Packages/io.apkrun.fixture.hellotext/incoming/\(preview.ticket.uuidString)/base.apk")
    #expect(try Data(contentsOf: storedAPK) == Data("base apk bytes".utf8))
    #expect(storedAPK != input)
}

@Test func packageStoreDiscardsUnusedImportTicketAndPrivateAPKCopy() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)

    let store = PackageStore(packagesDirectory: packages, inspector: { _ in facts() })
    try await store.open()
    let preview = try await store.importPackage(files: [input])
    let ticketDirectory =
        packages
        .appendingPathComponent("io.apkrun.fixture.hellotext/incoming", isDirectory: true)
        .appendingPathComponent(preview.ticket.uuidString, isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: ticketDirectory.path))

    try await store.discardImport(ticket: preview.ticket)

    #expect(!FileManager.default.fileExists(atPath: ticketDirectory.path))
    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("A discarded import ticket must not be installable.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .importTicketNotFound)
    }
}

@Test func packageStoreKeepsUnreadableRecordsVisibleAndProtectsOnlyThosePackages() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let corruptPackageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let futurePackageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellocompose"))
    let missingPackageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellogl"))
    let mismatchDirectoryID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellonotification"))
    let mismatchMetadataID = try #require(PackageID(rawValue: "com.example.identityclaim"))
    let healthyPackageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellowebview"))

    let corruptDirectory = packages.appendingPathComponent(corruptPackageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
    try Data("{invalid".utf8).write(to: corruptDirectory.appendingPathComponent("metadata.json"))
    let futureDirectory = packages.appendingPathComponent(futurePackageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
    try Data(
        """
        {"packageId":"\(futurePackageID.rawValue)","schemaVersion":2}
        """.utf8
    ).write(to: futureDirectory.appendingPathComponent("metadata.json"))
    let missingDirectory = packages.appendingPathComponent(missingPackageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(
        at: missingDirectory.appendingPathComponent("current", isDirectory: true),
        withIntermediateDirectories: true
    )
    let mismatchDirectory = packages.appendingPathComponent(mismatchDirectoryID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: mismatchDirectory, withIntermediateDirectories: true)
    try Data(
        """
        {"packageId":"\(mismatchMetadataID.rawValue)","schemaVersion":"invalid"}
        """.utf8
    ).write(to: mismatchDirectory.appendingPathComponent("metadata.json"))

    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { apk in
            let contents = try Data(contentsOf: apk)
            let packageID: PackageID
            switch contents {
            case Data("healthy".utf8):
                packageID = healthyPackageID
            case Data("unblocked".utf8):
                packageID = mismatchMetadataID
            default:
                packageID = corruptPackageID
            }
            return APKFacts(
                packageID: packageID,
                versionCode: 1,
                versionName: "1.0",
                splitName: nil,
                displayName: packageID.rawValue,
                minSDK: 24,
                targetSDK: 35,
                nativeABIs: []
            )
        }
    )
    try await store.open()

    let issues = try await store.listPackageRecordIssues()
    #expect(
        issues
            == [
                PackageRecordIssue(packageID: futurePackageID, detail: "unsupportedSchemaVersion"),
                PackageRecordIssue(packageID: corruptPackageID, detail: "invalidMetadata"),
                PackageRecordIssue(packageID: missingPackageID, detail: "missingMetadata"),
                PackageRecordIssue(packageID: mismatchDirectoryID, detail: "identityMismatch"),
            ].sorted { $0.packageID < $1.packageID })
    #expect(try await store.listManagedPackages().isEmpty)
    #expect(try await store.packageRecordIssue(for: corruptPackageID)?.detail == "invalidMetadata")

    let corruptAPK = temporary.appendingPathComponent("corrupt.apk")
    try Data("corrupt".utf8).write(to: corruptAPK)
    await #expect(
        throws: PackageStoreFailure.metadataUnreadable(corruptPackageID, detail: "invalidMetadata")
    ) {
        try await store.importPackage(files: [corruptAPK])
    }
    await #expect(
        throws: PackageStoreFailure.metadataUnreadable(corruptPackageID, detail: "invalidMetadata")
    ) {
        try await store.uninstall(packageID: corruptPackageID)
    }
    await #expect(
        throws: PackageStoreFailure.metadataUnreadable(corruptPackageID, detail: "invalidMetadata")
    ) {
        try await store.forget(packageID: corruptPackageID)
    }

    let healthyAPK = temporary.appendingPathComponent("healthy.apk")
    try Data("healthy".utf8).write(to: healthyAPK)
    let preview = try await store.importPackage(files: [healthyAPK])
    let installed = try await store.installImported(ticket: preview.ticket)
    #expect(installed.packageId == healthyPackageID)
    #expect(try await store.listPackageRecordIssues() == issues)

    let unblockedAPK = temporary.appendingPathComponent("unblocked.apk")
    try Data("unblocked".utf8).write(to: unblockedAPK)
    let unblockedPreview = try await store.importPackage(files: [unblockedAPK])
    let unblockedRecord = try await store.installImported(ticket: unblockedPreview.ticket)
    #expect(unblockedRecord.packageId == mismatchMetadataID)
}

@Test func packageStoresOpenedBeforeAnotherWriteKeepJournalSequencesMonotonic() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let firstStore = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await firstStore.open()
    let preview = try await firstStore.importPackage(files: [input])
    _ = try await firstStore.installImported(ticket: preview.ticket)

    let secondStore = PackageStore(
        packagesDirectory: packagesDirectory,
        inspector: { _ in facts() }
    )
    try await secondStore.open()
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    try await firstStore.forget(packageID: packageID)
    await #expect(throws: PackageStoreFailure.packageNotFound) {
        try await secondStore.forget(packageID: packageID)
    }

    let reopened = PackageStore(
        packagesDirectory: packagesDirectory,
        inspector: { _ in facts() }
    )
    try await reopened.open()
    #expect(await reopened.journalIssue == nil)
    #expect(try await reopened.listManagedPackages().isEmpty)

    let journalURL = packagesDirectory.appendingPathComponent("journal.jsonl")
    let journalText = try String(contentsOf: journalURL, encoding: .utf8)
    let sequences =
        try journalText
        .split(separator: "\n")
        .map { line -> Int in
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(object["seq"] as? Int)
        }
    #expect(sequences == Array(1...sequences.count))
}

@Test func packageStoreDoesNotClaimDataOutcomeWhenUninstallFailedAndPackageIsAbsent() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])
    let installed = try await store.installImported(ticket: preview.ticket)
    await channel.configureUninstallFailureAfterRemoval()

    await #expect(
        throws: PackageStoreFailure.uninstallDataUnverified(installed.packageId)
    ) {
        try await store.uninstall(packageID: installed.packageId, keepData: true)
    }

    let records = try await store.listManagedPackages()
    #expect(records.first?.state == .installed)
    #expect(await channel.lastKeepData == true)
}

@Test func packageStoreDoesNotClaimDataWasDeletedWhenUninstallFailedAndPackageIsAbsent() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])
    let installed = try await store.installImported(ticket: preview.ticket)
    await channel.configureUninstallFailureAfterRemoval()

    await #expect(
        throws: PackageStoreFailure.uninstallDataUnverified(installed.packageId)
    ) {
        try await store.uninstall(packageID: installed.packageId, keepData: false)
    }

    let records = try await store.listManagedPackages()
    #expect(records.first?.state == .installed)
    #expect(await channel.lastKeepData == false)
}

@Test func packageStoreLeavesAmbiguousUninstallInspectableAndForgetResolvesItWithoutClaimingDataOutcome() async throws {
    for keepData in [true, false] {
        for forgetCrashStep in ["begin", "uninstallOutcomesResolved", "filesRemoved", "recordRemoved"] {
            let temporary = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let channel = FakeStoreChannel()
            let runtime = FakeStoreRuntime(channel: channel)
            let input = temporary.appendingPathComponent("HelloText.apk")
            try Data("base apk bytes".utf8).write(to: input)
            let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
            let forgettingStore = PackageStore(
                packagesDirectory: packages,
                inspector: { _ in facts() },
                faultInjector: { kind, step in
                    if kind == "forget", step == forgetCrashStep {
                        throw InjectedStoreCrash()
                    }
                }
            )
            try await forgettingStore.open()
            let crashingStore = PackageStore(
                packagesDirectory: packages,
                runtimeAccess: runtime,
                inspector: { _ in facts() },
                faultInjector: { kind, step in
                    if kind == "uninstall", step == "guestUninstallRequested" {
                        throw InjectedStoreCrash()
                    }
                }
            )
            try await crashingStore.open()
            let preview = try await crashingStore.importPackage(files: [input])
            let installed = try await crashingStore.installImported(ticket: preview.ticket)
            do {
                try await crashingStore.uninstall(packageID: installed.packageId, keepData: keepData)
                Issue.record("Expected an interruption after the guest uninstall request.")
            } catch is InjectedStoreCrash {
                // The guest removed the package, but the host did not record its result.
            }

            let recoveredStore = PackageStore(
                packagesDirectory: packages,
                runtimeAccess: runtime,
                inspector: { _ in facts() }
            )
            try await recoveredStore.open()
            try await recoveredStore.recoverPendingTransactions()

            let record = try #require(try await recoveredStore.listManagedPackages().first)
            #expect(record.state == .installed)
            #expect(try await channel.listPackages(.all).allSatisfy { $0.packageID != installed.packageId })
            #expect(
                FileManager.default.fileExists(
                    atPath: packages.appendingPathComponent("\(installed.packageId.rawValue)/current/base.apk").path
                )
            )
            let journal = try String(contentsOf: packages.appendingPathComponent("journal.jsonl"), encoding: .utf8)
            let entries =
                try journal
                .split(separator: "\n")
                .map { line -> [String: Any] in
                    try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
            let uninstallBegin = try #require(
                entries.first { $0["kind"] as? String == "uninstall" && $0["op"] as? String == "begin" }
            )
            let uninstallTransaction = try #require(uninstallBegin["txn"] as? String)
            #expect(
                !entries.contains {
                    $0["txn"] as? String == uninstallTransaction
                        && ["commit", "abort"].contains($0["op"] as? String ?? "")
                }
            )
            #expect(
                !entries.contains {
                    $0["txn"] as? String == uninstallTransaction && $0["step"] as? String == "guestUninstalled"
                }
            )

            do {
                try await forgettingStore.forget(packageID: installed.packageId)
                Issue.record("Expected an interruption during the host-side forget.")
            } catch is InjectedStoreCrash {
                // The persisted forget intent must finish on the next open.
            }

            let finalStore = PackageStore(
                packagesDirectory: packages,
                inspector: { _ in facts() }
            )
            try await finalStore.open()
            #expect(try await finalStore.listManagedPackages().isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: packages.appendingPathComponent("\(installed.packageId.rawValue)/current/base.apk").path
                )
            )

            let resolvedJournal = try String(
                contentsOf: packages.appendingPathComponent("journal.jsonl"),
                encoding: .utf8
            )
            let resolvedEntries =
                try resolvedJournal
                .split(separator: "\n")
                .map { line -> [String: Any] in
                    try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
            let resolvedUninstall = try #require(
                resolvedEntries.first {
                    $0["txn"] as? String == uninstallTransaction && $0["op"] as? String == "abort"
                }
            )
            #expect(resolvedUninstall["reason"] as? String == "userChoseForgetWithUnverifiedUninstallOutcome")
            let resolvedForgetBegin = try #require(
                resolvedEntries.first { $0["kind"] as? String == "forget" && $0["op"] as? String == "begin" }
            )
            #expect(resolvedForgetBegin["reason"] as? String == "resolvesUnverifiedUninstall")
            let forgetTransaction = try #require(resolvedForgetBegin["txn"] as? String)
            #expect(
                resolvedEntries.contains {
                    $0["txn"] as? String == forgetTransaction && $0["op"] as? String == "commit"
                }
            )
        }
    }
}

@Test func packageStoreSerializesForgetAgainstAnUninstallInAnotherStore() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let firstStore = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await firstStore.open()
    let preview = try await firstStore.importPackage(files: [input])
    let installed = try await firstStore.installImported(ticket: preview.ticket)

    let secondStore = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await secondStore.open()
    await channel.pauseUninstall()
    let uninstallTask = Task {
        try await firstStore.uninstall(packageID: installed.packageId, keepData: true)
    }
    await channel.waitForUninstallStart()

    let completion = CompletionFlag()
    let forgetTask = Task {
        try await secondStore.forget(packageID: installed.packageId)
        await completion.complete()
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await completion.isComplete))
    await channel.continueUninstall()
    try await uninstallTask.value
    try await forgetTask.value

    #expect(await completion.isComplete)
    #expect(try await firstStore.listManagedPackages().isEmpty)
    #expect(try await secondStore.listManagedPackages().isEmpty)
}

@Test func packageStoreKeepsAmbiguousFirstInstallPendingUntilSameSetRetry() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let expiredAt = createdAt.addingTimeInterval(2 * 60 * 60)
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { createdAt }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input], origin: .cli)
    await channel.configureInstallFailureAfterCommit(queryUnavailable: true)

    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("Expected an install error while PackageManager was unavailable.")
    } catch is SimulatedGuestFailure {
        // The first request may have committed even though both calls failed.
    }

    let incoming =
        packages
        .appendingPathComponent("io.apkrun.fixture.hellotext/incoming/\(preview.ticket.uuidString)")
    #expect(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("base.apk").path))
    let journal = try String(contentsOf: packages.appendingPathComponent("journal.jsonl"), encoding: .utf8)
    #expect(!journal.contains("\"op\":\"abort\""))

    await channel.makeQueriesAvailable()
    let recoveredStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { expiredAt }
    )
    try await recoveredStore.open()
    try await recoveredStore.recoverPendingTransactions()
    #expect(try await recoveredStore.listManagedPackages().isEmpty)
    #expect(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("base.apk").path))

    // PackageManager has no transaction receipt, so a matching package after an uncertain
    // first-install error remains ambiguous. Retrying the same ticket gives the channel a
    // successful install result that can safely promote the artifact set.
    await channel.configureInstallSuccess()
    let record = try await recoveredStore.installImported(ticket: preview.ticket)
    #expect(record.versionCode == preview.versionCode)
    #expect(record.source.origin == .cli)
    #expect(try await recoveredStore.listManagedPackages().count == 1)
    try await recoveredStore.recoverPendingTransactions()
    #expect(try await recoveredStore.listManagedPackages().count == 1)
}

@Test func packageStoreDoesNotClaimAnUnchangedUnmanagedPackageAfterInstallFailure() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = PackageID(rawValue: "io.apkrun.fixture.hellotext")!
    let channel = FakeStoreChannel()
    let unmanaged = StorePackageInfo(
        packageID: packageID,
        displayName: "Unmanaged HelloText",
        versionCode: 7,
        versionName: "1.0",
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        firstInstallTime: Date(timeIntervalSince1970: 100),
        lastUpdateTime: Date(timeIntervalSince1970: 200),
        targetSDK: 35,
        minSDK: 24
    )
    await channel.seed(unmanaged)
    await channel.configureInstallFailureBeforeCommit()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("different apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])

    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("Expected the install error.")
    } catch is SimulatedGuestFailure {
        // The guest still has the same unmanaged package and the channel did not install.
    }

    #expect(try await store.listManagedPackages().isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk").path
        )
    )
    try await store.recoverPendingTransactions()
    #expect(try await store.listManagedPackages().isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk").path
        )
    )
}

@Test func packageStoreRecoversPromotedArtifactsAfterTicketAgeExpires() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let expiredAt = createdAt.addingTimeInterval(2 * 60 * 60)
    let crashingStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { createdAt },
        faultInjector: { kind, step in
            if kind == "firstInstall", step == "filesPromoted" {
                throw InjectedStoreCrash()
            }
        }
    )
    try await crashingStore.open()
    let preview = try await crashingStore.importPackage(files: [input])
    do {
        _ = try await crashingStore.installImported(ticket: preview.ticket)
        Issue.record("Expected the injected interruption after promotion.")
    } catch is InjectedStoreCrash {
        // The APK set is in current/, but the record and commit are still pending.
    }

    let recoveredStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { expiredAt }
    )
    try await recoveredStore.open()
    try await recoveredStore.recoverPendingTransactions()

    let recovered = try #require(try await recoveredStore.listManagedPackages().first)
    #expect(recovered.packageId == preview.packageID)
    #expect(recovered.versionCode == preview.versionCode)
    #expect(
        FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk").path
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/ticket.json").path
        )
    )
}

@Test func packageStoreChecksImportLimitsAndAvailableSpaceBeforeCopying() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("tiny.apk")
    try Data("apk".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packages,
        inspector: { _ in facts() },
        hostFreeSpace: { _ in 64 }
    )
    try await store.open()

    do {
        _ = try await store.importPackage(files: [input])
        Issue.record("Expected the insufficient-space guard to reject the import.")
    } catch let failure as PackageStoreFailure {
        guard case .insufficientHostSpace(let needed, let available) = failure else {
            Issue.record("Unexpected package-store failure: \(failure)")
            return
        }
        #expect(needed > available)
    }

    do {
        _ = try await store.importPackage(files: Array(repeating: input, count: 257))
        Issue.record("Expected the APK-count limit to reject the import.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .tooManyImportFiles)
    }
}

@Test func packageStoreAcceptsImportWhenSpaceMatchesItsPreflightEstimate() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    let bytes = Data(repeating: 0xA5, count: 1_100_000)
    try bytes.write(to: input)
    let reserve: Int64 = 2 * 1_024 * 1_024 * 1_024
    let required = Int64(bytes.count) * 2 + reserve
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        inspector: { _ in facts() },
        hostFreeSpace: { _ in required }
    )
    try await store.open()

    let preview = try await store.importPackage(files: [input])
    #expect(preview.artifactSet.files.first?.size == Int64(bytes.count))
}

@Test func packageStoreInstallsAndUninstallsWithOrWithoutKeptData() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await store.open()

    let preview = try await store.importPackage(files: [input])
    let firstInstall = try await store.installImportedWithOutcome(ticket: preview.ticket)
    let record = firstInstall.record
    #expect(firstInstall.previousVersionCode == nil)
    #expect(!firstInstall.restoredRetainedData)
    #expect(record.state == .installed)
    #expect(record.versionCode == 7)
    #expect(record.updateAuthority == .manual)
    let firstInstallRequest = try #require(await channel.lastInstallRequest)
    #expect(firstInstallRequest.mode == .installNew)
    #expect(firstInstallRequest.expectedSignerDigests == preview.artifactSet.signerDigests)
    #expect(
        firstInstallRequest.artifacts
            == preview.artifactSet.files.map {
                StoreArtifactSpec(name: $0.splitName ?? "base", size: UInt64($0.size), sha256: $0.sha256)
            })

    let reinstallPreview = try await store.importPackage(files: [input])
    let reinstall = try await store.reinstallWithOutcome(ticket: reinstallPreview.ticket)
    #expect(reinstall.previousVersionCode == 7)
    #expect(!reinstall.restoredRetainedData)
    #expect(await channel.lastInstallRequest?.mode == .reinstall)

    let packageDirectory = temporary.appendingPathComponent("Packages/io.apkrun.fixture.hellotext")
    let current = packageDirectory.appendingPathComponent("current", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("base.apk").path))
    #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("artifact.json").path))
    #expect(FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("metadata.json").path))

    let retainedOutcome = try await store.uninstallWithOutcome(packageID: record.packageId, keepData: true)
    #expect(retainedOutcome.keptData)
    #expect(!retainedOutcome.cleanupDeferred)
    let retained = try #require(try await store.listManagedPackages().first)
    #expect(retained.state == .uninstalledKeepingData)
    #expect(!FileManager.default.fileExists(atPath: current.path))
    #expect(await channel.lastKeepData == true)

    let secondPreview = try await store.importPackage(files: [input])
    let restore = try await store.installImportedWithOutcome(ticket: secondPreview.ticket)
    let reinstalled = restore.record
    #expect(restore.previousVersionCode == 7)
    #expect(restore.restoredRetainedData)
    #expect(reinstalled.state == .installed)
    let removedOutcome = try await store.uninstallWithOutcome(packageID: record.packageId)
    #expect(!removedOutcome.keptData)
    #expect(!removedOutcome.cleanupDeferred)
    #expect(try await store.listManagedPackages().isEmpty)
    #expect(await channel.lastKeepData == false)
    #expect(!FileManager.default.fileExists(atPath: packageDirectory.path))
}

@Test func packageStoreReturnsCommittedUninstallWhenTrashCleanupFails() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        faultInjector: { kind, step in
            guard kind == "uninstall", step == "trashCleanup" else { return }
            throw SimulatedGuestFailure.installFailedBeforeCommit
        }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    let installed = try await store.installImportedWithOutcome(ticket: preview.ticket)

    let outcome = try await store.uninstallWithOutcome(
        packageID: installed.record.packageId,
        keepData: true
    )

    #expect(outcome.keptData)
    #expect(outcome.cleanupDeferred)
    #expect(try await store.listManagedPackages().first?.state == .uninstalledKeepingData)
}

@Test func packageStoreCallsInstallBoundaryAfterChannelSetupImmediatelyBeforeGuestCall() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: FakeStoreRuntime(channel: channel),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    let journalURL = packagesDirectory.appendingPathComponent("journal.jsonl")
    let boundary = MutationBoundaryProbe()
    await channel.resetPackageInfoCallCount()

    do {
        _ = try await store.installImportedWithOutcome(
            ticket: preview.ticket,
            beforeGuestInstall: {
                let journal = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
                await boundary.record(
                    sawTransactionBegin: journal.contains("\"kind\":\"firstInstall\""),
                    sawGuestRequest: journal.contains("guestCommitRequested"),
                    packageInfoQueryCount: await channel.packageInfoCallCount
                )
                throw SimulatedGuestFailure.installFailedBeforeCommit
            }
        )
        Issue.record("The test boundary must stop the guest install.")
    } catch {
        #expect(error is SimulatedGuestFailure)
    }

    #expect(await boundary.wasEntered)
    #expect(await boundary.sawTransactionBegin)
    #expect(await boundary.sawGuestRequest)
    #expect(await boundary.packageInfoQueryCount == 1)
    #expect(await channel.installCallCount == 0)
    #expect(try await store.listManagedPackages().isEmpty)
    let journal = try String(contentsOf: journalURL, encoding: .utf8)
    #expect(journal.contains("installNotStarted"))
}

@Test func packageStoreDoesNotCallInstallBoundaryWhenCancelledWaitingForMutationLock() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: FakeStoreRuntime(channel: channel),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    let lockURL = packagesDirectory.appendingPathComponent(".mutation.lock")
    var lock = Darwin.open(
        lockURL.path,
        O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK,
        mode_t(0o600)
    )
    #expect(lock >= 0)
    guard lock >= 0 else { return }
    defer {
        if lock >= 0 {
            _ = Darwin.close(lock)
        }
    }

    let boundary = MutationBoundaryProbe()
    let install = Task {
        try await store.installImportedWithOutcome(
            ticket: preview.ticket,
            beforeGuestInstall: { await boundary.record() }
        )
    }
    try await Task.sleep(for: .milliseconds(50))
    install.cancel()
    do {
        _ = try await install.value
        Issue.record("A cancelled mutation-lock waiter must not start install.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .operationInProgress)
    }

    _ = Darwin.close(lock)
    lock = -1
    #expect(!(await boundary.wasEntered))
    #expect(await channel.installCallCount == 0)
    #expect(try await store.listManagedPackages().isEmpty)

    let installed = try await store.installImportedWithOutcome(ticket: preview.ticket)
    #expect(installed.record.state == .installed)
}

@Test func packageStoreKeepsInstallCancellableUntilStoreAgentChannelIsReady() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let acquisitionGate = StoreAgentAcquisitionGate()
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: FakeStoreRuntime(channel: channel, acquisitionGate: acquisitionGate),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    await acquisitionGate.pause(after: 2)
    let boundary = MutationBoundaryProbe()
    let install = Task {
        try await store.installImportedWithOutcome(
            ticket: preview.ticket,
            beforeGuestInstall: { await boundary.record() }
        )
    }

    await acquisitionGate.waitUntilPaused()
    install.cancel()
    await acquisitionGate.release()
    do {
        _ = try await install.value
        Issue.record("Cancellation during channel setup must stop before the guest call.")
    } catch {
        #expect(error is CancellationError)
    }

    #expect(!(await boundary.wasEntered))
    #expect(await channel.installCallCount == 0)
    #expect(try await store.listManagedPackages().isEmpty)
    let journalURL = packagesDirectory.appendingPathComponent("journal.jsonl")
    let journal = try String(contentsOf: journalURL, encoding: .utf8)
    #expect(journal.contains("guestInstallNotStarted"))

    let installed = try await store.installImportedWithOutcome(ticket: preview.ticket)
    #expect(installed.record.state == .installed)
}

@Test func packageStoreDoesNotCallForgetBoundaryWhenCancelledWaitingForMutationLock() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: FakeStoreRuntime(channel: channel),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    let installed = try await store.installImportedWithOutcome(ticket: preview.ticket)
    let lockURL = packagesDirectory.appendingPathComponent(".mutation.lock")
    var lock = Darwin.open(
        lockURL.path,
        O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK,
        mode_t(0o600)
    )
    #expect(lock >= 0)
    guard lock >= 0 else { return }
    defer {
        if lock >= 0 {
            _ = Darwin.close(lock)
        }
    }

    let boundary = MutationBoundaryProbe()
    let forget = Task {
        try await store.forget(
            packageID: installed.record.packageId,
            beforeForget: { await boundary.record() }
        )
    }
    try await Task.sleep(for: .milliseconds(50))
    forget.cancel()
    do {
        _ = try await forget.value
        Issue.record("A cancelled mutation-lock waiter must not start forget.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .operationInProgress)
    }

    _ = Darwin.close(lock)
    lock = -1
    #expect(!(await boundary.wasEntered))
    #expect(try await store.listManagedPackages().first?.state == .installed)
}

@Test func packageStoreCallsUninstallBoundaryAfterPreparingTheGuestTransaction() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: FakeStoreRuntime(channel: channel),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    let installed = try await store.installImportedWithOutcome(ticket: preview.ticket)
    let packageDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let journalURL = packageDirectory.appendingPathComponent("journal.jsonl")
    let boundary = UninstallBoundaryProbe()

    do {
        _ = try await store.uninstallWithOutcome(
            packageID: installed.record.packageId,
            beforeUninstall: {
                await boundary.recordSessionEnd()
            },
            beforeGuestUninstall: {
                let journal = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
                await boundary.record(guestRequestPresent: journal.contains("guestUninstallRequested"))
                throw SimulatedGuestFailure.uninstallFailed
            }
        )
        Issue.record("The test boundary must stop the guest uninstall.")
    } catch {
        #expect(error is SimulatedGuestFailure)
    }

    #expect(await boundary.wasEntered)
    #expect(await boundary.sessionEndWasEntered)
    #expect(await boundary.observedGuestRequest)
    #expect(await channel.lastKeepData == nil)
    #expect(try await store.listManagedPackages().first?.state == .installed)
    let journal = try String(contentsOf: journalURL, encoding: .utf8)
    #expect(journal.contains("uninstallNotStarted"))
}

@Test func packageStoreDoesNotCallUninstallBoundaryWhenCancelledWaitingForMutationLock() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: FakeStoreRuntime(channel: channel),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    let installed = try await store.installImportedWithOutcome(ticket: preview.ticket)
    let lockURL = packagesDirectory.appendingPathComponent(".mutation.lock")
    var lock = Darwin.open(
        lockURL.path,
        O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK,
        mode_t(0o600)
    )
    #expect(lock >= 0)
    guard lock >= 0 else { return }
    defer {
        if lock >= 0 {
            _ = Darwin.close(lock)
        }
    }

    let boundary = UninstallBoundaryProbe()
    let uninstall = Task {
        try await store.uninstallWithOutcome(
            packageID: installed.record.packageId,
            beforeUninstall: {
                await boundary.recordSessionEnd()
            },
            beforeGuestUninstall: {
                await boundary.record(guestRequestPresent: false)
            }
        )
    }
    try await Task.sleep(for: .milliseconds(50))
    uninstall.cancel()
    do {
        _ = try await uninstall.value
        Issue.record("A cancelled mutation-lock waiter must not start uninstall.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .operationInProgress)
    }

    _ = Darwin.close(lock)
    lock = -1
    #expect(!(await boundary.wasEntered))
    #expect(!(await boundary.sessionEndWasEntered))
    #expect(try await store.listManagedPackages().first?.state == .installed)
}

@Test func packageStoreUsesLiveAndroidVersionForInstallOutcomeAndDowngradeChecks() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { apk in
            let versionCode = try #require(Int64(String(contentsOf: apk, encoding: .utf8)))
            return facts(versionCode: versionCode)
        }
    )
    try await store.open()

    let version7 = temporary.appendingPathComponent("version-7.apk")
    try Data("7".utf8).write(to: version7)
    let firstPreview = try await store.importPackage(files: [version7])
    _ = try await store.installImported(ticket: firstPreview.ticket)

    await channel.seed(storePackageInfo(packageID: packageID, versionCode: 9))
    let version10 = temporary.appendingPathComponent("version-10.apk")
    try Data("10".utf8).write(to: version10)
    let replacementPreview = try await store.importPackage(files: [version10])
    let replacement = try await store.reinstallWithOutcome(ticket: replacementPreview.ticket)
    #expect(replacement.previousVersionCode == 9)
    #expect(!replacement.restoredRetainedData)

    await channel.seed(storePackageInfo(packageID: packageID, versionCode: 12))
    let version11 = temporary.appendingPathComponent("version-11.apk")
    try Data("11".utf8).write(to: version11)
    let downgradePreview = try await store.importPackage(files: [version11])
    await #expect(
        throws: PackageStoreFailure.downgradeRefused(installed: 12, candidate: 11)
    ) {
        try await store.reinstallWithOutcome(ticket: downgradePreview.ticket)
    }
    #expect(try await store.listManagedPackages().first?.versionCode == 10)
}

@Test func packageStoreDoesNotTreatAnExternallyReinstalledRetainedPackageAsNew() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { apk in
            let versionCode = try #require(Int64(String(contentsOf: apk, encoding: .utf8)))
            return facts(versionCode: versionCode)
        }
    )
    try await store.open()

    let version7 = temporary.appendingPathComponent("version-7.apk")
    try Data("7".utf8).write(to: version7)
    let firstPreview = try await store.importPackage(files: [version7])
    let installed = try await store.installImported(ticket: firstPreview.ticket)
    try await store.uninstall(packageID: installed.packageId, keepData: true)

    await channel.seed(storePackageInfo(packageID: packageID, versionCode: 9))
    let version10 = temporary.appendingPathComponent("version-10.apk")
    try Data("10".utf8).write(to: version10)
    let restorePreview = try await store.importPackage(files: [version10])
    let replacement = try await store.installImportedWithOutcome(ticket: restorePreview.ticket)

    #expect(replacement.previousVersionCode == 9)
    #expect(!replacement.restoredRetainedData)
}

@Test func packageStoreReturnsCommittedInstallWhenTrashCleanupFails() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let firstStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await firstStore.open()

    let version7 = temporary.appendingPathComponent("version-7.apk")
    try Data("base apk bytes".utf8).write(to: version7)
    let firstPreview = try await firstStore.importPackage(files: [version7])
    _ = try await firstStore.installImported(ticket: firstPreview.ticket)

    let version8 = temporary.appendingPathComponent("version-8.apk")
    try Data("replacement apk bytes".utf8).write(to: version8)
    let trash = packages.appendingPathComponent(".trash", isDirectory: true)
    let replacementStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts(versionCode: 8) },
        faultInjector: { kind, step in
            guard kind == "reinstall", step == "commit" else { return }
            try FileManager.default.removeItem(at: trash)
            try Data("blocks directory cleanup".utf8).write(to: trash)
        }
    )
    try await replacementStore.open()
    let replacementPreview = try await replacementStore.importPackage(files: [version8])
    let outcome = try await replacementStore.reinstallWithOutcome(ticket: replacementPreview.ticket)

    #expect(outcome.record.versionCode == 8)
    #expect(outcome.previousVersionCode == 7)
    #expect(outcome.cleanupDeferred)
    #expect(try await replacementStore.listManagedPackages().first?.versionCode == 8)
    #expect(FileManager.default.fileExists(atPath: trash.path))
}

@Test func packageStoreRecoversInstallInterruptedAfterGuestCommit() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)

    let crashingStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        faultInjector: { kind, step in
            if kind == "firstInstall", step == "guestInstalled" {
                throw InjectedStoreCrash()
            }
        }
    )
    try await crashingStore.open()
    let preview = try await crashingStore.importPackage(files: [input])
    do {
        _ = try await crashingStore.installImported(ticket: preview.ticket)
        Issue.record("Expected the injected interruption.")
    } catch is InjectedStoreCrash {
        // The guest has the package while the host still has a journaled incoming set.
    }

    let recoveredStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await recoveredStore.open()
    try await recoveredStore.recoverPendingTransactions()

    let recovered = try #require(try await recoveredStore.listManagedPackages().first)
    #expect(recovered.packageId == preview.packageID)
    #expect(recovered.versionCode == preview.versionCode)
    #expect(
        FileManager.default.fileExists(
            atPath:
                packages
                .appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk")
                .path
        )
    )
}

@Test func packageStoreTruncatesTornJournalTailAndContinuesRecovery() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let runtime = FakeStoreRuntime(channel: FakeStoreChannel())
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        faultInjector: { kind, step in
            if kind == "firstInstall", step == "begin" {
                throw InjectedStoreCrash()
            }
        }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])
    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("Expected interruption after the begin record.")
    } catch is InjectedStoreCrash {
        // The durable journal now contains an unfinished begin record.
    }

    let journal = packages.appendingPathComponent("journal.jsonl")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{torn".utf8))
    try handle.close()

    let reopened = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await reopened.open()
    #expect(await reopened.journalIssue != nil)
    #expect(try await reopened.listManagedPackages().isEmpty)
    #expect(try Data(contentsOf: journal).last == 0x0A)
}

@Test func packageStoreKeepsMiddleJournalCorruptionReadOnly() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    let journal = packages.appendingPathComponent("journal.jsonl")
    let corruptJournal = Data("{invalid}\n{\"seq\":2}\n".utf8)
    try corruptJournal.write(to: journal)

    let store = PackageStore(packagesDirectory: packages, inspector: { _ in facts() })
    try await store.open()

    #expect(await store.journalIssue == "invalid journal line")
    #expect(try await store.listManagedPackages().isEmpty)
    #expect(try Data(contentsOf: journal) == corruptJournal)

    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    do {
        _ = try await store.importPackage(files: [input])
        Issue.record("A store with a corrupt journal must reject writes.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .journalUnreadable)
    }
    #expect(try Data(contentsOf: journal) == corruptJournal)
}

@Test func packageStoreImportTicketsExpireWithTheStoreProcess() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let originalStore = PackageStore(packagesDirectory: packages, inspector: { _ in facts() })
    try await originalStore.open()
    let preview = try await originalStore.importPackage(files: [input])

    let restartedStore = PackageStore(packagesDirectory: packages, inspector: { _ in facts() })
    try await restartedStore.open()
    do {
        _ = try await restartedStore.installImported(ticket: preview.ticket)
        Issue.record("An import ticket must not survive the store process.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .importTicketNotFound)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath:
                packages
                .appendingPathComponent("io.apkrun.fixture.hellotext/incoming/\(preview.ticket.uuidString)")
                .path
        )
    )
}

@Test func packageStoreReconcilesAndroidMetadataAndPackageChanges() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let channel = FakeStoreChannel()
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: FakeStoreRuntime(channel: channel),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    _ = try await store.installImported(ticket: preview.ticket)

    let generation = UUID()
    let externalUpdate = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText updated",
        versionCode: 9,
        versionName: "2.0",
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        targetSDK: 36,
        minSDK: 24,
        updateOwner: PackageID(rawValue: "io.apkrun.store"),
        nativeABIs: ["arm64-v8a", "x86_64"]
    )
    let inventory = try await store.reconcileAndroidPackages(
        [externalUpdate],
        userdataGeneration: generation
    )
    #expect(inventory.first?.versionCode == 9)
    var record = try #require(try await store.listManagedPackages().first)
    #expect(record.versionCode == 9)
    #expect(record.displayName == "HelloText updated")
    #expect(!record.artifacts.currentMatchesAndroid)
    #expect(record.android.updateOwner == PackageID(rawValue: "io.apkrun.store"))
    #expect(record.android.nativeAbis == ["arm64-v8a", "x86_64"])
    #expect(record.android.userdataGeneration == generation)

    try await store.reconcileAndroidPackage(
        packageID: packageID,
        info: nil,
        userdataGeneration: generation
    )
    record = try #require(try await store.listManagedPackages().first)
    #expect(record.state == .broken(.removedInAndroid))

    try await store.reconcileAndroidPackage(
        packageID: packageID,
        info: externalUpdate,
        userdataGeneration: generation
    )
    record = try #require(try await store.listManagedPackages().first)
    #expect(record.state == .installed)
}

@Test func packageStoreDetectsSameVersionAndroidReplacement() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let channel = FakeStoreChannel()
    let generation = UUID()
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: FakeStoreRuntime(channel: channel, generation: generation),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    let installed = try await store.installImported(ticket: preview.ticket)
    let signer = try #require(SHA256Digest(hex: String(repeating: "a", count: 64)))

    let originalInstall = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText",
        versionCode: installed.versionCode,
        versionName: "1.0",
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        lastUpdateTime: Date(timeIntervalSince1970: 200),
        targetSDK: 35,
        minSDK: 24,
        signingDigests: [signer]
    )
    try await store.reconcileAndroidPackage(
        packageID: packageID,
        info: originalInstall,
        userdataGeneration: generation
    )
    var record = try #require(try await store.listManagedPackages().first)
    #expect(record.artifacts.currentMatchesAndroid)
    #expect(record.signingCertificates == [signer])

    let sameVersionReplacement = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText",
        versionCode: installed.versionCode,
        versionName: "1.0",
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        lastUpdateTime: Date(timeIntervalSince1970: 300),
        targetSDK: 35,
        minSDK: 24,
        signingDigests: [signer]
    )
    try await store.reconcileAndroidPackage(
        packageID: packageID,
        info: sameVersionReplacement,
        userdataGeneration: generation
    )

    record = try #require(try await store.listManagedPackages().first)
    #expect(record.state == .installed)
    #expect(record.versionCode == installed.versionCode)
    #expect(record.signingCertificates == [signer])
    #expect(!record.artifacts.currentMatchesAndroid)
}

@Test func packageStorePreservesUserdataResetAndRecoveryReconciliation() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let channel = FakeStoreChannel()
    let originalGeneration = UUID()
    let runtime = FakeStoreRuntime(channel: channel, generation: originalGeneration)
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let initialPreview = try await store.importPackage(files: [input])
    _ = try await store.installImported(ticket: initialPreview.ticket)

    let resetGeneration = UUID()
    await runtime.setGeneration(resetGeneration)
    _ = try await store.reconcileAndroidPackages([], userdataGeneration: resetGeneration)
    var record = try #require(try await store.listManagedPackages().first)
    #expect(record.state == .needsReinstall(.userdataReset))
    #expect(record.android.userdataGeneration == originalGeneration)

    let restoredInfo = storePackageInfo(packageID: packageID, versionCode: 6)
    await channel.seed(restoredInfo)
    try await store.reconcileAndroidPackage(
        packageID: packageID,
        info: restoredInfo,
        userdataGeneration: resetGeneration
    )
    record = try #require(try await store.listManagedPackages().first)
    #expect(record.state == .needsReinstall(.userdataRestored))
    #expect(record.versionCode == 6)
    #expect(!record.artifacts.currentMatchesAndroid)
    #expect(record.android.userdataGeneration == originalGeneration)

    let reinstallPreview = try await store.importPackage(files: [input])
    let reinstall = try await store.reinstallWithOutcome(ticket: reinstallPreview.ticket)
    #expect(await channel.lastInstallRequest?.mode == .update)
    #expect(reinstall.record.state == .installed)
    #expect(reinstall.record.versionCode == 7)
    #expect(reinstall.record.android.userdataGeneration == resetGeneration)
}

@Test func packageStoreResolvesUserdataResetWhenAndroidReportsSameOrNewerVersion() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let installerPackage = try #require(PackageID(rawValue: "com.android.packageinstaller"))
    let updateOwner = try #require(PackageID(rawValue: "io.apkrun.store"))
    let channel = FakeStoreChannel()
    let originalGeneration = UUID()
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: FakeStoreRuntime(channel: channel, generation: originalGeneration),
        inspector: { _ in facts() }
    )
    try await store.open()
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let preview = try await store.importPackage(files: [input])
    _ = try await store.installImported(ticket: preview.ticket)

    let resetGeneration = UUID()
    _ = try await store.reconcileAndroidPackages([], userdataGeneration: resetGeneration)
    #expect(try await store.listManagedPackages().first?.state == .needsReinstall(.userdataReset))

    let sameVersion = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText after reset",
        versionCode: preview.versionCode,
        versionName: "1.0-reset",
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        installerPackage: installerPackage,
        firstInstallTime: Date(timeIntervalSince1970: 100),
        lastUpdateTime: Date(timeIntervalSince1970: 300),
        targetSDK: 36,
        minSDK: 25,
        updateOwner: updateOwner,
        nativeABIs: ["arm64-v8a", "x86_64"]
    )
    try await store.reconcileAndroidPackage(
        packageID: packageID,
        info: sameVersion,
        userdataGeneration: resetGeneration
    )

    var record = try #require(try await store.listManagedPackages().first)
    #expect(record.state == .installed)
    #expect(record.versionCode == preview.versionCode)
    #expect(record.versionName == "1.0-reset")
    #expect(record.displayName == "HelloText after reset")
    #expect(record.android.updateOwner == updateOwner)
    #expect(record.android.installerOfRecord == installerPackage)
    #expect(record.android.lastUpdateTime == Date(timeIntervalSince1970: 300))
    #expect(record.android.targetSdk == 36)
    #expect(record.android.nativeAbis == ["arm64-v8a", "x86_64"])
    #expect(record.android.userdataGeneration == resetGeneration)

    let newerGeneration = UUID()
    _ = try await store.reconcileAndroidPackages([], userdataGeneration: newerGeneration)
    #expect(try await store.listManagedPackages().first?.state == .needsReinstall(.userdataReset))

    let newerVersion = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText newer install",
        versionCode: preview.versionCode + 2,
        versionName: "1.2",
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        installerPackage: installerPackage,
        firstInstallTime: Date(timeIntervalSince1970: 100),
        lastUpdateTime: Date(timeIntervalSince1970: 400),
        targetSDK: 37,
        minSDK: 26,
        updateOwner: updateOwner,
        nativeABIs: ["arm64-v8a"]
    )
    _ = try await store.reconcileAndroidPackages(
        [newerVersion],
        userdataGeneration: newerGeneration
    )

    record = try #require(try await store.listManagedPackages().first)
    #expect(record.state == .installed)
    #expect(record.versionCode == newerVersion.versionCode)
    #expect(record.versionName == "1.2")
    #expect(record.displayName == "HelloText newer install")
    #expect(record.android.lastUpdateTime == Date(timeIntervalSince1970: 400))
    #expect(record.android.targetSdk == 37)
    #expect(record.android.nativeAbis == ["arm64-v8a"])
    #expect(record.android.userdataGeneration == newerGeneration)
}

private func facts(versionCode: VersionCode = 7) -> APKFacts {
    APKFacts(
        packageID: PackageID(rawValue: "io.apkrun.fixture.hellotext")!,
        versionCode: versionCode,
        versionName: "1.0",
        splitName: nil,
        displayName: "HelloText",
        minSDK: 24,
        targetSDK: 35,
        nativeABIs: ["arm64-v8a"]
    )
}

private func storePackageInfo(packageID: PackageID, versionCode: VersionCode) -> StorePackageInfo {
    StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText",
        versionCode: versionCode,
        enabled: true,
        targetSDK: 35,
        minSDK: 24
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PackageStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
